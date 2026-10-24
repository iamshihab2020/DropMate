import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/chunks.dart';
import '../core/crypto.dart';
import '../core/hash_worker.dart';
import '../core/protocol.dart';
import '../core/sanitize.dart';
import '../data/repo.dart';
import 'engine.dart';
import 'net.dart';
import 'sources.dart';

/// Live numbers for one transfer, shown inside the bubble.
class Progress {
  int done;
  final int total;
  double speed = 0; // bytes/s
  final _samples = <(int, int)>[];
  final int _startDone;
  final int _startAt = nowMs();
  Progress(this.done, this.total) : _startDone = done;

  /// Stored on the finished message: "1.2 GB in 38 s · 32 MB/s". Counts only bytes moved in this run.
  Map<String, int> summary() => {'took_ms': nowMs() - _startAt, 'moved': done - _startDone};

  void add(int bytes) {
    done += bytes;
    final now = nowMs();
    _samples.add((now, done));
    _samples.removeWhere((s) => now - s.$1 > 3000);
    if (_samples.length > 1) {
      final dt = (_samples.last.$1 - _samples.first.$1) / 1000;
      if (dt > 0) speed = (_samples.last.$2 - _samples.first.$2) / dt;
    }
  }

  Duration? get eta => speed <= 0 ? null : Duration(seconds: ((total - done) / speed).ceil());
}

/// An incoming request waiting for the user (in-app sheet or notification).
class Incoming {
  final String transferId;
  final Person from;
  final String fromDevice;
  final List<({String name, int size})> files;
  final int total;
  final int? freeBytes;
  final bool suggestTrust;
  final _decision = Completer<(String, String?)>(); // (accept|decline|taken, folder)
  Incoming(this.transferId, this.from, this.fromDevice, this.files, this.total, this.freeBytes, this.suggestTrust);
}

class _Part {
  final int f;
  final String relPath;
  final int size;
  final String partPath;
  final ChunkBitmap bits;
  RandomAccessFile? raf;
  RandomAccessFile? hashes;
  Future<void> writing = Future.value(); // chunks arrive concurrently; a file handle allows one op at a time
  _Part(this.f, this.relPath, this.size, this.partPath, this.bits);
}

/// Request → accept → chunked stream → verify → done, with resume (PRD §11.9).
class Transfers extends ChangeNotifier {
  final Engine e;
  SourceResolver resolve = resolveFileRef;
  final progress = <String, Progress>{};
  final pending = <String, Incoming>{};
  final _incomingCtl = StreamController<Incoming>.broadcast();
  Stream<Incoming> get incoming => _incomingCtl.stream;

  final _running = <String>{};
  final _cancel = <String>{};
  final _pause = <String>{};
  final _personChain = <String, Future<void>>{};
  final _parts = <String, Map<int, _Part>>{}; // receiver: transfer → open part files
  final _sources = <String, List<Source>>{}; // sender: live sources for this session
  final _lastNotify = <String, int>{};
  Timer? _retry;

  Transfers(this.e) {
    _retry = Timer.periodic(const Duration(seconds: 10), (_) => _retryWaiting());
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  void _changed(String tid, {bool force = false}) {
    final now = nowMs();
    if (!force && now - (_lastNotify[tid] ?? 0) < 250) return;
    _lastNotify[tid] = now;
    notifyListeners();
    final p = progress[tid];
    if (p != null && now - (_lastProgressNote[tid] ?? 0) > 1000) {
      _lastProgressNote[tid] = now;
      unawaited(_progressNote(tid, p));
    }
  }

  final _lastProgressNote = <String, int>{};

  /// Persistent "Sending/Receiving … 34%" notification with Cancel (PRD F14).
  Future<void> _progressNote(String tid, Progress p) async {
    final t = await _transfer(tid);
    final m = await e.repo.message(t?['message_id'] as String? ?? tid);
    final files = (m?.body['files'] as List?) ?? const [];
    final what = files.length == 1 ? '${files.first['name']}'.split('/').last : '${files.length} files';
    final pct = p.total == 0 ? 0 : p.done * 100 ~/ p.total;
    e.host.notifyProgress(tid, '${t?['direction'] == 'in' ? 'Receiving' : 'Sending'} $what', pct);
  }

  Future<void> _active() => e.host.setTransferActive(_running.isNotEmpty || _parts.isNotEmpty);

  // ================================================================ sender

  /// Sends [sources] to a person (all their online devices ring), or to one of my devices.
  Future<String> send(String personId, List<Source> sources, {String? toDevice, String? fetchOf}) async {
    final fetch = fetchOf != null;
    final tid = newId();
    final total = sources.fold<int>(0, (a, s) => a + s.size);
    final body = {
      'transfer_id': tid,
      'files': [
        for (final s in sources) {'name': s.relPath, 'size': s.size},
      ],
      'total': total,
      'state': 'requesting',
      'to_device': toDevice,
      if (fetch) 'fetch_of': fetchOf,
    };
    final now = nowMs();
    await e.repo.db.transaction((t) async {
      await t.insert('transfer', {
        'id': tid,
        'message_id': fetchOf ?? tid,
        'direction': 'out',
        'peer_device': toDevice,
        'person_id': personId,
        'state': 'requesting',
        'total_bytes': total,
        'created_at': now,
      });
      for (var i = 0; i < sources.length; i++) {
        await t.insert('transfer_file', {
          'transfer_id': tid,
          'f': i,
          'rel_path': sources[i].relPath,
          'size': sources[i].size,
          'mime': sources[i].mime,
          'local_path': sources[i].ref,
          'mtime': sources[i].mtime,
        });
      }
    });
    _sources[tid] = sources;
    if (!fetch) {
      await e.repo.addLocalMessage(personId, e.me.id, 'file', body, deviceId: e.id.deviceId, status: 'sent', id: tid);
    }
    notifyListeners();
    e.notifyListeners();
    unawaited(_runOut(tid));
    return tid;
  }

  Future<Map<String, Object?>?> _transfer(String tid) async =>
      (await e.repo.db.query('transfer', where: 'id=?', whereArgs: [tid])).firstOrNull;

  Future<void> _setState(String tid, String state, {Map<String, dynamic>? extra, String? error}) async {
    if (state != 'transferring') e.host.cancelProgress(tid);
    await e.repo.db.update(
      'transfer',
      {'state': state, if (error != null) 'error': error},
      where: 'id=?',
      whereArgs: [tid],
    );
    final m = await e.repo.message(tid);
    if (m != null) {
      await e.repo.updateMessage(tid, body: {...m.body, 'state': state, if (error != null) 'error': error, ...?extra});
    }
    _changed(tid, force: true);
    e.notifyListeners();
  }

  Future<List<Source>?> _loadSources(String tid) async {
    if (_sources[tid] != null) return _sources[tid];
    final rows = await e.repo.db.query('transfer_file', where: 'transfer_id=?', whereArgs: [tid], orderBy: 'f');
    final out = <Source>[];
    for (final r in rows) {
      final s = await resolve(r['local_path'] as String, r['rel_path'] as String);
      if (s == null || s.size != r['size'] || s.mtime != r['mtime']) return null;
      out.add(s);
    }
    return _sources[tid] = out;
  }

  /// Serializes transfers per person so each pair has one active transfer (PRD §11.9).
  Future<void> _runOut(String tid) async {
    final t = await _transfer(tid);
    if (t == null) return;
    final person = t['person_id'] as String;
    final prev = _personChain[person] ?? Future.value();
    final next = prev.then((_) => _doRunOut(tid)).catchError((_) {});
    _personChain[person] = next;
    await next;
  }

  Future<void> _doRunOut(String tid) async {
    if (!_running.add(tid)) return;
    await _active();
    try {
      var t = (await _transfer(tid))!;
      final state = t['state'] as String;
      if (const {'done', 'declined', 'canceled', 'failed', 'no_response'}.contains(state)) return;
      final sources = await _loadSources(tid);
      if (sources == null) {
        await _setState(tid, 'failed', error: 'File changed or missing');
        return;
      }
      if (state == 'requesting' || state == 'queued') {
        final ok = await _request(tid, t, sources);
        if (!ok) return;
        t = (await _transfer(tid))!;
      }
      await _stream(tid, t, sources);
    } finally {
      _running.remove(tid);
      await _active();
    }
  }

  Future<bool> _request(String tid, Map<String, Object?> t, List<Source> sources) async {
    final person = t['person_id'] as String;
    final to = t['peer_device'] as String?;
    var targets = await e.onlineDevices(person);
    if (to != null) targets = targets.where((d) => d.id == to).toList();
    if (targets.isEmpty) {
      await _setState(tid, 'queued');
      return false;
    }
    await _setState(tid, 'requesting');
    final m = await e.repo.message(tid);
    final req = {
      'transfer_id': tid,
      'person_id': person,
      'message': m == null ? null : (Map.of(m.row)..remove('log_seq')),
      'files': [
        for (var i = 0; i < sources.length; i++)
          {'f': i, 'rel_path': sources[i].relPath, 'size': sources[i].size, 'mime': sources[i].mime},
      ],
      'total': t['total_bytes'],
      'fetch_of': t['message_id'] == tid ? null : t['message_id'],
    };
    final winner = Completer<Device?>();
    final results = <String>[];
    var left = targets.length;
    for (final d in targets) {
      final c = e.client(d)!;
      unawaited(
        c
            .call('POST', '/v1/transfer/request', body: req, timeout: requestTimeout + const Duration(seconds: 8))
            .then((r) => r['decision'] as String, onError: (_) => 'error')
            .then((decision) {
              c.close();
              results.add(decision);
              if (decision == 'accept' && !winner.isCompleted) winner.complete(d);
              if (--left == 0 && !winner.isCompleted) winner.complete(null);
            }),
      );
    }
    final w = await winner.future;
    if (_cancel.remove(tid)) {
      await _setState(tid, 'canceled');
      return false;
    }
    if (w == null) {
      final s = results.contains('decline')
          ? 'declined'
          : results.contains('timeout')
          ? 'no_response'
          : 'queued';
      await _setState(tid, s);
      return false;
    }
    for (final d in targets.where((d) => d.id != w.id)) {
      final c = e.client(d)!;
      unawaited(
        c
            .call('POST', '/v1/transfer/$tid/cancel', body: {'reason': 'taken', 'by': w.name})
            .catchError((_) => <String, dynamic>{})
            .whenComplete(c.close),
      );
    }
    await e.repo.db.update('transfer', {'peer_device': w.id}, where: 'id=?', whereArgs: [tid]);
    await _setState(tid, 'transferring', extra: {'stored_on': w.id, 'stored_on_name': w.name});
    return true;
  }

  Future<void> _stream(String tid, Map<String, Object?> t, List<Source> sources) async {
    final d = await e.repo.device(t['peer_device'] as String);
    if (d == null || !e.deviceOnline(d.id)) {
      await _setState(tid, 'paused', extra: {'reason': 'connection'});
      return;
    }
    final c = e.client(d)!;
    final hasher = await HashWorker.get();
    try {
      await _setState(tid, 'transferring');
      final status = await c.call('POST', '/v1/transfer/$tid/status');
      final have = (status['files'] as Map).cast<String, String>();
      final total = t['total_bytes'] as int;
      final prog = progress[tid] = Progress(0, total);
      final roots = <String, String>{};
      for (var i = 0; i < sources.length; i++) {
        final s = sources[i];
        final count = chunkCount(s.size);
        final bits = ChunkBitmap.decode(count, have['$i']);
        prog.done += bits.done == count ? s.size : bits.done * chunkSize;
        final hashes = List<String?>.filled(count, null);
        final inFlight = <Future<void>>[];
        // Reads stay in order; hashing (isolate pool) and uploads overlap across a window of chunks.
        final window = e.speedLimit > 0 ? 1 : 6;
        for (var n = 0; n < count; n++) {
          if (_cancel.contains(tid)) throw const _Stop('canceled');
          if (_pause.contains(tid)) throw const _Stop('paused');
          final len = n == count - 1 ? s.size - n * chunkSize : chunkSize;
          if (!bits.has(n)) await _throttle(prog, len);
          final data = s.size == 0 ? Uint8List(0) : await s.read(n * chunkSize, len);
          final job = hasher.sha256Hex(data).then((h) async {
            hashes[n] = h;
            if (bits.has(n)) return;
            await _putWithRetry(c, '/v1/transfer/$tid/file/$i/chunk/$n', data, h);
            prog.add(data.length);
            _changed(tid);
          });
          inFlight.add(job..ignore()); // errors still surface where the job is awaited
          if (inFlight.length >= window) await inFlight.removeAt(0);
        }
        await Future.wait(inFlight);
        roots['$i'] = sha256Hex(utf8.encode(hashes.join()));
      }
      final r = await c.call(
        'POST',
        '/v1/transfer/$tid/finish',
        body: {'roots': roots},
        timeout: const Duration(minutes: 2),
      );
      if (r['ok'] == true) {
        await _setState(tid, 'done', extra: prog.summary());
        await _closeSources(tid);
      } else {
        final retries = (await e.repo.message(tid))?.body['retries'] as int? ?? 0;
        if (retries >= 1) {
          await _setState(tid, 'failed', error: 'File was corrupted in transit');
        } else {
          await _setState(tid, 'transferring', extra: {'retries': retries + 1});
          _running.remove(tid);
          unawaited(Future.microtask(() => _runOut(tid)));
        }
      }
    } on _Stop catch (s) {
      if (s.why == 'canceled') {
        _cancel.remove(tid);
        unawaited(
          c
              .call('POST', '/v1/transfer/$tid/cancel', body: {'reason': 'canceled'})
              .catchError((_) => <String, dynamic>{}),
        );
        await _setState(tid, 'canceled');
        await _closeSources(tid);
      } else {
        await _setState(tid, 'paused', extra: {'reason': 'user'});
      }
    } on PeerError catch (err) {
      if (err.code == 'canceled') {
        await _setState(tid, 'canceled');
      } else {
        await _setState(tid, 'paused', extra: {'reason': 'connection'});
      }
    } catch (_) {
      await _setState(tid, 'paused', extra: {'reason': 'connection'});
    } finally {
      c.close();
    }
  }

  /// A failed chunk is retried up to 3 times before the transfer pauses (PRD §11.9).
  Future<void> _putWithRetry(PeerClient c, String path, Uint8List data, String hash) async {
    for (var attempt = 1; ; attempt++) {
      try {
        await c.putChunk(path, data, hash);
        return;
      } on PeerError catch (err) {
        if (err.status != 422 || attempt >= 3) rethrow;
      } on SocketException {
        if (attempt >= 3) rethrow;
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
  }

  final _paceStart = <Progress, (int, int)>{};

  /// Keeps the average send rate under the user's speed limit (PRD F18).
  Future<void> _throttle(Progress prog, int next) async {
    final limit = e.speedLimit;
    if (limit <= 0) return;
    final (t0, b0) = _paceStart[prog] ??= (nowMs(), prog.done);
    final due = t0 + ((prog.done + next - b0) * 1000 ~/ limit);
    final wait = due - nowMs();
    if (wait > 0) await Future.delayed(Duration(milliseconds: wait));
  }

  Future<void> _closeSources(String tid) async {
    for (final s in _sources.remove(tid) ?? const <Source>[]) {
      await s.close();
    }
    progress.remove(tid);
  }

  Future<void> cancel(String tid) async {
    final t = await _transfer(tid);
    if (t == null) return;
    if (t['direction'] == 'in') {
      await _onCancel(tid, 'canceled', notifyPeer: true);
      return;
    }
    if (_running.contains(tid)) {
      _cancel.add(tid);
    } else {
      await _setState(tid, 'canceled');
      final d = t['peer_device'] == null ? null : await e.repo.device(t['peer_device'] as String);
      final c = d == null ? null : e.client(d);
      unawaited(
        c
            ?.call('POST', '/v1/transfer/$tid/cancel', body: {'reason': 'canceled'})
            .catchError((_) => <String, dynamic>{})
            .whenComplete(c.close),
      );
      await _closeSources(tid);
    }
  }

  Future<void> pause(String tid) async {
    if (_running.contains(tid)) _pause.add(tid);
  }

  Future<void> resume(String tid) async {
    _pause.remove(tid);
    final t = await _transfer(tid);
    if (t == null) return;
    if (t['direction'] == 'out') {
      if (const {'declined', 'no_response', 'failed', 'canceled'}.contains(t['state'])) {
        await e.repo.db.update(
          'transfer',
          {'state': 'requesting', 'peer_device': null},
          where: 'id=?',
          whereArgs: [tid],
        );
      }
      unawaited(_runOut(tid));
    }
  }

  Future<void> onDeviceOnline(Device d) async => _retryWaiting(personId: d.personId);

  Future<void> _retryWaiting({String? personId}) async {
    final rows = await e.repo.db.query(
      'transfer',
      where: "direction='out' AND state IN ('queued','paused')${personId == null ? '' : ' AND person_id=?'}",
      whereArgs: [if (personId != null) personId],
    );
    for (final t in rows) {
      final m = await e.repo.message(t['id'] as String);
      if (m?.body['reason'] == 'user') continue;
      if (e.personOnline(t['person_id'] as String)) unawaited(_runOut(t['id'] as String));
    }
  }

  /// Ask another of my devices to send me a file it holds (PRD F19).
  Future<bool> fetch(String messageId, String holderDevice) async {
    final d = await e.repo.device(holderDevice);
    final c = d == null ? null : e.client(d);
    if (c == null) return false;
    try {
      await c.call('POST', '/v1/fetch', body: {'message_id': messageId, 'port': e.server.port});
      return true;
    } catch (_) {
      return false;
    } finally {
      c.close();
    }
  }

  // ================================================================ receiver

  void routes(Server s) {
    s.on('POST', '/v1/transfer/request', _onRequest);
    s.on('POST', '/v1/transfer/{id}/status', _onStatus);
    s.on('PUT', '/v1/transfer/{id}/file/{f}/chunk/{n}', _onChunk, streamBody: true);
    s.on('POST', '/v1/transfer/{id}/finish', _onFinish);
    s.on('POST', '/v1/transfer/{id}/cancel', (r) async {
      await _onCancel(
        r.params['id']!,
        r.body['reason'] as String? ?? 'canceled',
        by: r.body['by'] as String?,
        from: r.device,
      );
      return Res.ok();
    });
    s.on('POST', '/v1/fetch', _onFetch);
  }

  Future<Res> _onRequest(Req r) async {
    final from = e.personOfDevice(r.device!);
    if (from == null) return const Res(403, {'error': 'unknown'});
    if (from.blocked) return Res.ok({'decision': 'decline'});
    final b = r.body;
    final tid = b['transfer_id'] as String;
    final existing = await _transfer(tid);
    if (existing != null) {
      // Sender retried the request (e.g. after a drop): stay consistent.
      return Res.ok({'decision': existing['state'] == 'canceled' ? 'decline' : 'accept'});
    }
    final own = from.isMe;
    final conv = own ? e.me.id : from.id;
    final files = [
      for (final f in (b['files'] as List).cast<Map<String, dynamic>>())
        (f: f['f'] as int, rel: sanitizeRelPath(f['rel_path'] as String).join('/'), size: f['size'] as int),
    ];
    if (files.isEmpty || files.any((f) => f.rel.isEmpty || f.size < 0)) return const Res(400, {'error': 'bad_files'});
    final total = files.fold<int>(0, (a, f) => a + f.size);

    if (b['message'] != null) {
      final m = Map<String, Object?>.from(b['message']);
      if (m['id'] != tid || m['author_person'] != from.id) return const Res(400, {'error': 'bad_message'});
      m['conversation_id'] = conv;
      await e.repo.upsertMessage(m, countUnread: !own);
      e.notifyListeners();
      if (!own) e.seenIfOpen(from.id);
    }

    final dir = from.folder ?? await e.host.downloadDir();
    final free = await e.host.freeBytes(dir);
    final enoughSpace = free == null || free > total + 50 * 1024 * 1024;
    final list = [for (final f in files) (name: f.rel, size: f.size)];

    String decision;
    String? folder;
    if (own || (from.trust.allows(list) && enoughSpace)) {
      decision = 'accept';
    } else {
      final inc = Incoming(
        tid,
        from,
        r.device!,
        list,
        total,
        free,
        from.acceptedCount >= 2 && from.trust.state.name == 'none',
      );
      pending[tid] = inc;
      _incomingCtl.add(inc);
      notifyListeners();
      final names = files.length == 1 ? files.first.rel : '${files.length} files';
      e.host.notifyIncoming(tid, '${from.name} wants to send', '$names (${formatBytes(total)})');
      final res = await inc._decision.future.timeout(requestTimeout, onTimeout: () => ('timeout', null));
      pending.remove(tid);
      e.host.cancelIncoming(tid);
      notifyListeners();
      decision = res.$1;
      folder = res.$2;
      if (decision == 'accept') {
        await e.repo.updatePerson(from.id, {'auto_accept_hint': from.acceptedCount + 1});
        await e.reload();
      }
      if (decision == 'timeout') {
        final m = await e.repo.message(tid);
        if (m != null) await e.repo.updateMessage(tid, body: {...m.body, 'state': 'missed'});
        e.notifyListeners();
      }
      if (decision == 'taken') return Res.ok({'decision': 'decline'});
    }
    if (decision != 'accept') {
      final m = await e.repo.message(tid);
      if (m != null && decision == 'decline') await e.repo.updateMessage(tid, body: {...m.body, 'state': 'declined'});
      e.notifyListeners();
      return Res.ok({'decision': decision});
    }

    final base = folder ?? dir;
    await e.repo.db.transaction((t) async {
      await t.insert('transfer', {
        'id': tid,
        'message_id': b['fetch_of'] as String? ?? tid,
        'direction': 'in',
        'peer_device': r.device,
        'person_id': conv,
        'state': 'transferring',
        'total_bytes': total,
        'folder': base,
        'stored_on_device': e.id.deviceId,
        'created_at': nowMs(),
      });
      for (final f in files) {
        final part = '${p.joinAll([base, ...f.rel.split('/')])}.${tid.substring(0, 8)}.dropmate-part';
        Directory(p.dirname(part)).createSync(recursive: true);
        await t.insert('transfer_file', {
          'transfer_id': tid,
          'f': f.f,
          'rel_path': f.rel,
          'size': f.size,
          'part_path': part,
          'chunks': ChunkBitmap(chunkCount(f.size)).encode(),
        });
      }
    });
    progress[tid] = Progress(0, total);
    final m = await e.repo.message(tid);
    if (m != null) {
      await e.repo.updateMessage(
        tid,
        body: {...m.body, 'state': 'transferring', 'stored_on': e.id.deviceId, 'stored_on_name': _myName()},
      );
    }
    e.notifyListeners();
    return Res.ok({'decision': 'accept'});
  }

  String _myName() => e.me.roster.device(e.id.deviceId)?.name ?? 'this device';

  /// Called by the UI sheet or a notification action.
  void decide(String tid, bool accept, {String? folder}) {
    final inc = pending[tid];
    if (inc != null && !inc._decision.isCompleted) inc._decision.complete((accept ? 'accept' : 'decline', folder));
  }

  Future<Map<int, _Part>?> _openParts(String tid, String device) async {
    if (_parts[tid] != null) return _parts[tid];
    final t = await _transfer(tid);
    if (t == null || t['direction'] != 'in' || t['peer_device'] != device) return null;
    if (const {'done', 'canceled', 'failed'}.contains(t['state'])) return null;
    final rows = await e.repo.db.query('transfer_file', where: 'transfer_id=?', whereArgs: [tid]);
    final parts = <int, _Part>{};
    for (final r in rows) {
      final size = r['size'] as int;
      parts[r['f'] as int] = _Part(
        r['f'] as int,
        r['rel_path'] as String,
        size,
        r['part_path'] as String,
        ChunkBitmap.decode(chunkCount(size), r['chunks'] as String?),
      );
    }
    progress[tid] ??= Progress(parts.values.fold(0, (a, x) => a + x.bits.done * chunkSize), t['total_bytes'] as int);
    await _active();
    return _parts[tid] = parts;
  }

  Future<Res> _onStatus(Req r) async {
    final parts = await _openParts(r.params['id']!, r.device!);
    if (parts == null) return const Res(404, {'error': 'canceled'});
    if ((await _transfer(r.params['id']!))!['state'] != 'transferring') {
      await _setState(r.params['id']!, 'transferring');
    }
    return Res.ok({
      'files': {for (final x in parts.values) '${x.f}': x.bits.encode()},
    });
  }

  Future<Res> _onChunk(Req r) async {
    final tid = r.params['id']!;
    final parts = await _openParts(tid, r.device!);
    if (parts == null) {
      await r.raw.drain<void>();
      return const Res(404, {'error': 'canceled'});
    }
    final part = parts[int.parse(r.params['f']!)];
    final n = int.parse(r.params['n']!);
    if (part == null || n >= part.bits.count) {
      await r.raw.drain<void>();
      return const Res(400, {'error': 'bad_chunk'});
    }
    final expectedLen = n == part.bits.count - 1 ? part.size - n * chunkSize : chunkSize;
    final b = BytesBuilder(copy: false);
    await for (final c in r.raw) {
      b.add(c);
      if (b.length > expectedLen) return const Res(400, {'error': 'too_long'});
    }
    final data = b.takeBytes();
    final hash = r.raw.headers.value(hChunkHash) ?? '';
    if (data.length != expectedLen) return const Res(400, {'error': 'bad_length'});
    if (await (await HashWorker.get()).sha256Hex(data) != hash) return const Res(422, {'error': 'hash_mismatch'});
    final write = part.writing.then((_) async {
      part.raf ??= await File(part.partPath).open(mode: FileMode.append);
      part.hashes ??= await File('${part.partPath}.dmh').open(mode: FileMode.append);
      await part.raf!.setPosition(n * chunkSize);
      await part.raf!.writeFrom(data);
      await part.hashes!.setPosition(n * 32);
      await part.hashes!.writeFrom(_hexToBytes(hash));
    });
    part.writing = write.catchError((_) {});
    await write;
    if (!part.bits.has(n)) {
      part.bits.set(n);
      progress[tid]?.add(data.length);
    }
    if (n % 8 == 0 || part.bits.complete) {
      await e.repo.db.update(
        'transfer_file',
        {'chunks': part.bits.encode()},
        where: 'transfer_id=? AND f=?',
        whereArgs: [tid, part.f],
      );
    }
    _changed(tid);
    return Res.ok();
  }

  Future<Res> _onFinish(Req r) async {
    final tid = r.params['id']!;
    final parts = await _openParts(tid, r.device!);
    if (parts == null) return const Res(404, {'error': 'canceled'});
    final roots = (r.body['roots'] as Map).cast<String, String>();
    final t = (await _transfer(tid))!;
    var ok = true;
    for (final part in parts.values) {
      await part.writing;
      await part.raf?.flush();
      await part.raf?.close();
      await part.hashes?.close();
      part.raf = part.hashes = null;
      await e.repo.db.update(
        'transfer_file',
        {'chunks': part.bits.encode()},
        where: 'transfer_id=? AND f=?',
        whereArgs: [tid, part.f],
      );
      final hf = File('${part.partPath}.dmh');
      final hb = hf.existsSync() ? hf.readAsBytesSync() : Uint8List(0);
      final hex = [
        for (var n = 0; n < part.bits.count; n++)
          if (hb.length >= (n + 1) * 32) _bytesToHex(hb.sublist(n * 32, (n + 1) * 32)) else '',
      ].join();
      if (!part.bits.complete || roots['${part.f}'] != sha256Hex(utf8.encode(hex))) {
        ok = false;
        // Corrupt: drop this file's chunks so the retry sends it again.
        part.bits.bits.fillRange(0, part.bits.bits.length, 0);
        for (final f in [File(part.partPath), hf]) {
          if (f.existsSync()) f.deleteSync();
        }
        await e.repo.db.update(
          'transfer_file',
          {'chunks': part.bits.encode()},
          where: 'transfer_id=? AND f=?',
          whereArgs: [tid, part.f],
        );
      }
    }
    if (!ok) return Res.ok({'ok': false});
    final saved = <String>[];
    for (final part in parts.values) {
      final segs = part.relPath.split('/');
      final dir = p.joinAll([t['folder'] as String, ...segs.sublist(0, segs.length - 1)]);
      Directory(dir).createSync(recursive: true);
      final dest = uniquePath(dir, segs.last);
      final pf = File(part.partPath);
      if (!pf.existsSync()) pf.createSync(); // zero-byte file
      pf.renameSync(dest);
      File('${part.partPath}.dmh').deleteSyncIfExists();
      await e.repo.db.update(
        'transfer_file',
        {'local_path': dest},
        where: 'transfer_id=? AND f=?',
        whereArgs: [tid, part.f],
      );
      await e.host.onFileSaved(dest);
      saved.add(dest);
    }
    _parts.remove(tid);
    final prog = progress.remove(tid);
    await _setState(tid, 'done', extra: {'paths': saved, ...?prog?.summary()});
    await _active();
    final from = e.personOfDevice(r.device!);
    if (from != null && !from.isMe) {
      e.host.notifyMessage(
        from.id,
        'Received from ${from.name}',
        saved.length == 1 ? p.basename(saved.first) : '${saved.length} files',
      );
    }
    return Res.ok({'ok': true});
  }

  Future<void> _onCancel(String tid, String reason, {String? by, String? from, bool notifyPeer = false}) async {
    final inc = pending[tid];
    if (inc != null && (from == null || inc.fromDevice == from)) {
      if (!inc._decision.isCompleted) inc._decision.complete((reason == 'taken' ? 'taken' : 'decline', null));
      final m = await e.repo.message(tid);
      if (m != null && reason == 'taken')
        await e.repo.updateMessage(tid, body: {...m.body, 'state': 'taken', 'taken_by': by});
      e.notifyListeners();
      return;
    }
    final t = await _transfer(tid);
    if (t == null) return;
    if (from != null && t['peer_device'] != from) return;
    if (t['direction'] == 'out') {
      // The receiver canceled.
      _running.contains(tid) ? _cancel.add(tid) : await _setState(tid, 'canceled');
      return;
    }
    final parts = _parts.remove(tid) ?? await _openParts(tid, t['peer_device'] as String) ?? {};
    _parts.remove(tid);
    for (final part in parts.values) {
      await part.writing;
      await part.raf?.close();
      await part.hashes?.close();
      for (final f in [File(part.partPath), File('${part.partPath}.dmh')]) {
        f.deleteSyncIfExists();
      }
    }
    progress.remove(tid);
    await _setState(tid, 'canceled');
    await _active();
    if (notifyPeer) {
      final d = await e.repo.device(t['peer_device'] as String);
      final c = d == null ? null : e.client(d);
      unawaited(
        c
            ?.call('POST', '/v1/transfer/$tid/cancel', body: {'reason': 'canceled'})
            .catchError((_) => <String, dynamic>{})
            .whenComplete(c.close),
      );
    }
  }

  Future<Res> _onFetch(Req r) async {
    if (!e.isOwnDevice(r.device!)) return const Res(403, {'error': 'not_own_device'});
    final mid = r.body['message_id'] as String;
    final paths = await localFiles(mid);
    final sources = <Source>[];
    for (final (ref, rel) in paths) {
      final s = await resolve(ref, rel);
      if (s != null) sources.add(s);
    }
    if (sources.isEmpty) return const Res(404, {'error': 'not_here'});
    final port = r.body['port'] as int?;
    if (port != null) e.noteEndpoint(r.device!, r.remoteIp, port);
    unawaited(send(e.me.id, sources, toDevice: r.device, fetchOf: mid));
    return Res.ok();
  }

  /// Files of a message that exist on this device, as (source ref, relative path).
  Future<List<(String, String)>> localFiles(String messageId) async {
    final ts = await e.repo.db.query(
      'transfer',
      where: "message_id=? AND (direction='out' OR state='done')",
      whereArgs: [messageId],
      orderBy: 'created_at DESC',
    );
    for (final t in ts) {
      final rows = await e.repo.db.query('transfer_file', where: 'transfer_id=?', whereArgs: [t['id']], orderBy: 'f');
      final out = <(String, String)>[];
      for (final r in rows) {
        final lp = r['local_path'] as String?;
        if (lp == null) continue;
        final ref = lp.startsWith('file:') || lp.startsWith('content:') ? lp : 'file:$lp';
        if (ref.startsWith('file:') && !File(ref.substring(5)).existsSync()) continue;
        out.add((ref, r['rel_path'] as String));
      }
      if (out.isNotEmpty) return out;
    }
    return const [];
  }

  /// Deletes `.dropmate-part` files older than 7 days (PRD §11.9).
  Future<void> cleanupStale() async {
    final cutoff = nowMs() - 7 * 86400000;
    final rows = await e.repo.db.query(
      'transfer',
      where: "direction='in' AND state NOT IN ('done','canceled','failed') AND created_at<?",
      whereArgs: [cutoff],
    );
    for (final t in rows) {
      await _onCancel(t['id'] as String, 'expired');
    }
  }
}

class _Stop implements Exception {
  final String why;
  const _Stop(this.why);
}

Uint8List _hexToBytes(String h) =>
    Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
String _bytesToHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

extension on File {
  void deleteSyncIfExists() {
    if (existsSync()) deleteSync();
  }
}

String formatBytes(num b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = 0;
  var v = b.toDouble();
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 && i > 0 ? 1 : 0)} ${u[i]}';
}
