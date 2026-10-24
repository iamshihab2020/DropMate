import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/crypto.dart';
import '../core/roster.dart';
import 'discovery.dart';
import 'engine.dart';
import 'net.dart';

enum PairMode { contact, link }

enum PairStage { showing, confirm, waiting, done, failed }

/// State of one pairing attempt, on either side. UI listens to it.
class PairSession extends ChangeNotifier {
  final PairMode mode;
  final bool displayer;
  final String code;
  final Uint8List key;
  final int expiresAt;
  String qr = '';
  PairStage stage = PairStage.showing;
  String? error;
  List<String> emojis = const [];
  Roster? peer;
  String? peerSecret;
  bool _used = false;
  Completer<bool>? _localConfirm;
  // scanner side
  PeerClient? _client;
  String _macKey = '';
  (String, int)? _peerAt;

  PairSession(this.mode, this.displayer, this.code, this.key)
    : expiresAt = DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch;

  bool get expired => DateTime.now().millisecondsSinceEpoch > expiresAt;

  void _set(PairStage s, {String? err}) {
    stage = s;
    error = err;
    notifyListeners();
  }
}

String _mac(List<int> key, List<String> parts) => b64(hmacSha256(key, utf8.encode(parts.join('|'))));

/// QR / 6-digit pairing for contacts and own devices (PRD §11.5).
class Pairing {
  final Engine e;
  PairSession? current;
  final _pairSeen = <String, (String, int)>{};

  Pairing(this.e);

  void onSighting(Sighting s) {
    if (s.pairHint != null) _pairSeen[s.pairHint!] = (s.ip, s.port);
  }

  // ------------------------------------------------ displayer (shows QR + code)

  Future<PairSession> show(PairMode mode) async {
    cancel();
    final code = (Random.secure().nextInt(900000) + 100000).toString();
    final s = PairSession(mode, true, code, randomBytes(16));
    final ips = await localIps();
    s.qr = Uri(
      scheme: 'dropmate',
      host: 'pair',
      queryParameters: {
        'v': '1',
        'ip': ips.isEmpty ? '' : ips.first,
        'port': '${e.server.port}',
        'fp': e.id.certFp,
        'k': b64(s.key),
        'm': mode.name,
      },
    ).toString();
    current = s;
    await e.discovery.update(pairHint: pairCodeHint(code));
    Timer(const Duration(minutes: 2), () {
      if (current == s && s.stage == PairStage.showing) {
        s._set(PairStage.failed, err: 'Code expired');
        cancel();
      }
    });
    return s;
  }

  void cancel() {
    final s = current;
    current = null;
    s?._localConfirm?.complete(false);
    s?._client?.close();
    unawaited(e.discovery.update(clearPair: true));
  }

  Future<Res> handle(Req r) async {
    final s = current;
    final b = r.body;
    if (s == null || !s.displayer || s.expired) return const Res(410, {'error': 'no_session'});
    switch (b['stage']) {
      case 'offer':
        if (s._used) return const Res(410, {'error': 'used'});
        s._used = true; // burns after one attempt, right or wrong
        unawaited(e.discovery.update(clearPair: true));
        final key = b['via'] == 'qr' ? s.key : utf8.encode(s.code);
        final roster = Roster.fromJson(b['roster']);
        final rosterJson = jsonEncode(b['roster']);
        if (b['fp_seen'] != e.id.certFp ||
            !bytesEqual(utf8.encode(b['mac']), utf8.encode(_mac(key, ['B', b['fp_seen'], rosterJson, b['secret']])))) {
          s._set(PairStage.failed, err: 'Wrong code');
          return const Res(403, {'error': 'bad_mac'});
        }
        if (!await roster.verify() || roster.devices.isEmpty) return const Res(400, {'error': 'bad_roster'});
        if (s.mode == PairMode.link && roster.devices.length != 1) {
          s._set(PairStage.failed, err: 'That device already belongs to someone');
          return const Res(409, {'error': 'not_fresh'});
        }
        if (s.mode == PairMode.contact &&
            (roster.personId == e.me.id || await e.repo.person(roster.personId) != null)) {
          s._set(PairStage.failed, err: 'Already connected');
          return const Res(409, {'error': 'already_paired'});
        }
        s.peer = roster;
        s.peerSecret = b['secret'];
        s._peerAt = (r.remoteIp, b['port'] as int? ?? 47823);
        s._macKey = b64(key);
        s.emojis = emojiCheck(e.id.certFp, roster.devices.first.certFp);
        s._set(PairStage.confirm);
        final mine = jsonEncode(e.me.roster.toJson());
        return Res.ok({
          'mode': s.mode.name,
          'roster': e.me.roster.toJson(),
          'secret': e.me.secret,
          'mac': _mac(key, ['A', e.id.certFp, mine, rosterJson, e.me.secret]),
        });
      case 'confirm':
        if (s.peer == null || b['mac'] != _mac(unb64(s._macKey), ['confirm']))
          return const Res(403, {'error': 'bad_mac'});
        s._localConfirm ??= Completer();
        final ok = await s._localConfirm!.future.timeout(const Duration(seconds: 60), onTimeout: () => false);
        if (ok) await _finishDisplayer(s);
        return Res.ok({'ok': ok});
      case 'cancel':
        s._set(PairStage.failed, err: 'Canceled on the other device');
        s._localConfirm?.complete(false);
        return Res.ok();
    }
    return const Res(400, {'error': 'bad_stage'});
  }

  Future<void> _finishDisplayer(PairSession s) async {
    final peer = s.peer!;
    if (s._peerAt != null) e.noteEndpoint(peer.devices.first.id, s._peerAt!.$1, s._peerAt!.$2);
    if (s.mode == PairMode.contact) {
      await e.repo.saveRoster(peer, isMe: false, secret: s.peerSecret);
      await e.reload();
    } else {
      final d = peer.devices.first;
      await e.updateMyRoster(e.me.roster.copyWith(devices: [...e.me.roster.devices, d]));
    }
    s._set(PairStage.done);
    current = null;
  }

  // ------------------------------------------------ scanner (scans QR / enters code)

  /// [qr] is a dropmate://pair URI, or [code] is the 6 digits.
  Future<PairSession> join({String? qr, String? code}) async {
    cancel();
    String host;
    int port;
    Set<String>? pins;
    List<int> key;
    String via;
    PairMode mode;
    if (qr != null) {
      final u = Uri.parse(qr);
      if (u.scheme != 'dropmate' || u.host != 'pair') throw const FormatException('Not a DropMate code');
      host = u.queryParameters['ip']!;
      port = int.parse(u.queryParameters['port']!);
      pins = {u.queryParameters['fp']!};
      key = unb64(u.queryParameters['k']!);
      via = 'qr';
      mode = PairMode.values.byName(u.queryParameters['m'] ?? 'contact');
    } else {
      final hint = pairCodeHint(code!);
      unawaited(e.discovery.update()); // re-announce so the displayer answers quickly
      (String, int)? at;
      for (var i = 0; i < 40 && at == null; i++) {
        at = _pairSeen[hint];
        if (at == null) await Future.delayed(const Duration(milliseconds: 250));
      }
      if (at == null) throw const FormatException('No device showing that code on this Wi-Fi');
      (host, port) = at;
      key = utf8.encode(code);
      via = 'code';
      mode = PairMode.contact; // corrected by the displayer's reply
    }
    final s = PairSession(mode, false, code ?? '', Uint8List(0));
    current = s;
    final c = PeerClient(e.id, host, port, pins);
    s._client = c;
    try {
      await c.call('GET', '/v1/hello', signed: false);
      final fpA = c.seenFp!;
      final mine = e.me.roster.toJson();
      final r = await c.call(
        'POST',
        '/v1/pair',
        signed: false,
        body: {
          'stage': 'offer',
          'via': via,
          'roster': mine,
          'secret': e.me.secret,
          'fp_seen': fpA,
          'port': e.server.port,
          'mac': _mac(key, ['B', fpA, jsonEncode(mine), e.me.secret]),
        },
      );
      final peer = Roster.fromJson(r['roster']);
      if (r['mac'] != _mac(key, ['A', fpA, jsonEncode(r['roster']), jsonEncode(mine), r['secret']]) ||
          !await peer.verify() ||
          !peer.devices.any((d) => d.certFp == fpA)) {
        throw const FormatException('The other device could not prove the code');
      }
      final real = PairSession(PairMode.values.byName(r['mode']), false, s.code, Uint8List(0))
        .._client = c
        .._macKey = b64(key)
        ..peer = peer
        ..peerSecret = r['secret']
        .._peerAt = (host, port)
        ..emojis = emojiCheck(fpA, e.id.certFp)
        ..stage = PairStage.confirm;
      current = real;
      return real;
    } on PeerError catch (err) {
      c.close();
      throw FormatException(switch (err.code) {
        'bad_mac' => 'Wrong code',
        'used' || 'no_session' => 'That code expired. Ask for a new one.',
        'already_paired' => 'You are already connected',
        'not_fresh' => 'This device already has contacts. Unpair them first to link it.',
        _ => 'Pairing failed (${err.code})',
      });
    } catch (_) {
      c.close();
      rethrow;
    }
  }

  /// Both sides tap Confirm; the displayer's reply decides.
  Future<void> confirm(PairSession s, bool ok) async {
    if (s.displayer) {
      s._localConfirm ??= Completer();
      if (!s._localConfirm!.isCompleted) s._localConfirm!.complete(ok);
      if (!ok) s._set(PairStage.failed, err: 'Canceled');
      if (ok && s.stage == PairStage.confirm) s._set(PairStage.waiting);
      return;
    }
    final c = s._client!;
    try {
      if (!ok) {
        await c.call('POST', '/v1/pair', signed: false, body: {'stage': 'cancel'});
        s._set(PairStage.failed, err: 'Canceled');
        return;
      }
      s._set(PairStage.waiting);
      final r = await c.call(
        'POST',
        '/v1/pair',
        signed: false,
        body: {
          'stage': 'confirm',
          'mac': _mac(unb64(s._macKey), ['confirm']),
        },
        timeout: const Duration(seconds: 70),
      );
      if (r['ok'] != true) {
        s._set(PairStage.failed, err: 'The other device did not confirm');
        return;
      }
      await _finishScanner(s);
      s._set(PairStage.done);
    } catch (err) {
      s._set(PairStage.failed, err: 'Connection lost');
    } finally {
      c.close();
      if (current == s) current = null;
    }
  }

  Future<void> _finishScanner(PairSession s) async {
    final peer = s.peer!;
    final at = s._peerAt!;
    final peerDevice = peer.devices.firstWhere((d) => d.certFp == s._client!.seenFp);
    if (s.mode == PairMode.contact) {
      await e.repo.saveRoster(peer, isMe: false, secret: s.peerSecret);
      await e.reload();
      e.noteEndpoint(peerDevice.id, at.$1, at.$2);
      return;
    }
    // Link: this fresh device drops its own person and joins the displayer's.
    final old = e.me.id;
    await e.repo.deletePerson(old);
    await e.repo.saveRoster(peer, isMe: true, secret: s.peerSecret);
    await e.repo.setSetting('my_name', peer.name);
    await e.reload();
    e.noteEndpoint(peerDevice.id, at.$1, at.$2);
    await e.discovery.update(hint: personHint(s.peerSecret!)); // our hint is now the shared person's
    // The displayer already added us to its roster; sync brings that roster, contacts and history.
    final d = (await e.repo.device(peerDevice.id))!;
    for (var i = 0; i < 5 && e.me.roster.device(e.id.deviceId) == null; i++) {
      await e.syncWith(d);
      if (e.me.roster.device(e.id.deviceId) == null) await Future.delayed(const Duration(seconds: 1));
    }
  }
}
