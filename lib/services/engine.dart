import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/crypto.dart';
import '../core/roster.dart';
import '../core/trust.dart';
import '../data/repo.dart';
import 'discovery.dart';
import 'host.dart';
import 'identity.dart';
import 'net.dart';
import 'pairing.dart';
import 'transfers.dart';

class Endpoint {
  final String ip;
  final int port;
  final int seenAt;
  Endpoint(this.ip, this.port, this.seenAt);
  bool get fresh => nowMs() - seenAt < 45000;
}

/// Central coordinator: presence, messaging, rosters, own-device sync, auto-accept (PRD §11).
class Engine extends ChangeNotifier {
  final Identity id;
  final Repo repo;
  final Host host;
  final Discovery discovery;
  late final Server server;
  late final Pairing pairing;
  late final Transfers transfers;

  late Person me;
  List<Person> contacts = [];
  final _live = <String, Endpoint>{};
  var _pks = <String, List<int>>{}; // device id → sign pk, for every non-removed device of me + contacts
  var _deviceOwner = <String, String>{}; // device id → person id
  final _lastPing = <String, int>{};
  Timer? _tick;
  bool _foreground = true;

  Engine({required this.id, required this.repo, required this.host, Discovery? discovery})
    : discovery = discovery ?? Discovery() {
    server = Server(id, (d) => _pks[d]);
    pairing = Pairing(this);
    transfers = Transfers(this);
  }

  // ---------------------------------------------------------------- lifecycle

  Future<void> start({String? deviceName, int port = 47823, bool withDiscovery = true}) async {
    var m = await repo.me();
    if (m == null) {
      final name = await repo.setting('my_name') ?? 'Me';
      final r = await Roster(
        personId: newId(),
        name: name,
        version: 1,
        devices: [
          RosterDevice(
            id: id.deviceId,
            name: deviceName ?? platformName(),
            platform: platformName(),
            signPk: id.signPkB64,
            certFp: id.certFp,
            addedAt: nowMs(),
          ),
        ],
      ).signedBy(id.deviceId, id.sign);
      await repo.saveRoster(r, isMe: true, secret: b64(randomBytes(32)));
      m = await repo.me();
    }
    await reload();
    speedLimit = int.tryParse(await repo.setting('speed_limit') ?? '') ?? 0;
    _routes();
    await server.start(port: port);
    if (withDiscovery) {
      discovery.sightings.listen(_onSighting);
      await discovery.start(server.port, personHint(me.secret));
    }
    _tick = Timer.periodic(const Duration(seconds: 15), (_) => _heartbeat());
    unawaited(_heartbeat());
  }

  Future<void> stop() async {
    _tick?.cancel();
    await discovery.stop();
    await server.stop();
  }

  void setForeground(bool fg) {
    _foreground = fg;
    discovery.setForeground(fg);
    if (fg) unawaited(_heartbeat(force: true));
  }

  Future<void> reload() async {
    me = (await repo.me())!;
    contacts = await repo.contacts();
    final pks = <String, List<int>>{};
    final owner = <String, String>{};
    for (final d in await repo.devices()) {
      pks[d.id] = unb64(d.signPk);
      owner[d.id] = d.personId;
    }
    pks.remove(id.deviceId);
    _pks = pks;
    _deviceOwner = owner;
    notifyListeners();
  }

  Person? personOfDevice(String deviceId) {
    final pid = _deviceOwner[deviceId];
    if (pid == me.id) return me;
    return contacts.where((c) => c.id == pid).firstOrNull;
  }

  bool isOwnDevice(String deviceId) => _deviceOwner[deviceId] == me.id && deviceId != id.deviceId;

  // ---------------------------------------------------------------- presence

  bool deviceOnline(String deviceId) => _live[deviceId]?.fresh ?? false;

  Future<List<Device>> onlineDevices(String personId) async {
    final ds = (await repo.devices(personId: personId))
        .where((d) => d.id != id.deviceId && deviceOnline(d.id))
        .toList();
    ds.sort((a, b) => _live[b.id]!.seenAt.compareTo(_live[a.id]!.seenAt));
    return ds;
  }

  /// Records an address learned outside discovery (pairing), so we can talk right away.
  void noteEndpoint(String deviceId, String ip, int port) {
    _live[deviceId] = Endpoint(ip, port, nowMs());
    unawaited(repo.seen(deviceId, ip, port));
    notifyListeners();
  }

  bool personOnline(String personId) =>
      _deviceOwner.entries.any((e) => e.value == personId && e.key != id.deviceId && deviceOnline(e.key));

  PeerClient? client(Device d) {
    final e = _live[d.id] ?? (d.lastIp != null ? Endpoint(d.lastIp!, d.lastPort ?? 47823, 0) : null);
    return e == null ? null : PeerClient(id, e.ip, e.port, {d.certFp});
  }

  Future<void> _onSighting(Sighting s) async {
    pairing.onSighting(s);
    if (s.hint.isEmpty) return;
    for (final p in [me, ...contacts]) {
      if (s.hint == personHint(p.secret) || s.hint == personHint(p.secret, dayOffset: -1)) {
        await _ping(p, s.ip, s.port, fromDiscovery: true);
        return;
      }
    }
  }

  /// Signed ping to an address believed to belong to [p]. Learns which device it is from the pinned cert.
  Future<void> _ping(Person p, String ip, int port, {bool force = false, bool fromDiscovery = false}) async {
    final key = '$ip:$port';
    final last = _lastPing[key] ?? 0;
    if (!force && nowMs() - last < 10000) return;
    _lastPing[key] = nowMs();
    final devices = await repo.devices(personId: p.id);
    final pins = {for (final d in devices) d.certFp};
    if (pins.isEmpty) return;
    final c = PeerClient(id, ip, port, pins);
    try {
      final r = await c.call(
        'POST',
        '/v1/ping',
        body: {'have': p.roster.version, 'mine': me.roster.version, 'port': server.port},
      );
      final dev = devices.firstWhere((d) => d.certFp == c.seenFp && d.id == r['device']);
      final wasOnline = deviceOnline(dev.id);
      _live[dev.id] = Endpoint(ip, port, nowMs());
      _isolationAt = 0;
      await repo.seen(dev.id, ip, port);
      if (r['roster'] != null) await acceptRoster(Roster.fromJson(r['roster']), fromDevice: dev.id);
      if (r['want_mine'] == true) unawaited(_pushRoster(dev));
      if (!wasOnline) {
        notifyListeners();
        unawaited(_onDeviceOnline(dev));
      }
    } on PeerError catch (e) {
      if (e.status == 401 && e.code == 'unknownDevice') await _theyForgotUs(p);
    } on SocketException {
      // We can hear them announce but can't connect: classic router client isolation (PRD §15).
      if (fromDiscovery) {
        _isolationAt = nowMs();
        notifyListeners();
      }
    } catch (_) {
      // Unreachable or wrong pin — ignore.
    } finally {
      c.close();
    }
  }

  int _isolationAt = 0;

  /// True when a known device announces itself but no connection gets through.
  bool get isolationSuspected => nowMs() - _isolationAt < 120000 && !_live.values.any((e) => e.fresh);

  Future<void> _heartbeat({bool force = false}) async {
    final interval = _foreground ? 15000 : 60000;
    for (final p in [me, ...contacts]) {
      for (final d in await repo.devices(personId: p.id)) {
        if (d.id == id.deviceId) continue;
        final e = _live[d.id] ?? (d.lastIp != null ? Endpoint(d.lastIp!, d.lastPort ?? 47823, 0) : null);
        if (e == null) continue;
        if (force || nowMs() - e.seenAt > interval - 1000) await _ping(p, e.ip, e.port, force: force);
      }
    }
    var changed = false;
    _live.removeWhere((k, e) {
      final stale = nowMs() - e.seenAt > 120000;
      changed |= stale;
      return stale;
    });
    if (changed) notifyListeners();
  }

  Future<void> _onDeviceOnline(Device d) async {
    if (d.personId == me.id) {
      await syncWith(d);
    } else {
      await flushOutbox(d.personId);
    }
    await transfers.onDeviceOnline(d);
  }

  /// A pinned device of [p] says it doesn't know us: they unpaired us (or removed this device).
  Future<void> _theyForgotUs(Person p) async {
    if (p.isMe) {
      host.notifyInfo('This device was removed', 'Another of your devices removed this one.');
      return;
    }
    await repo.deletePerson(p.id);
    await reload();
    host.notifyInfo('${p.name} unpaired', 'You are no longer connected to ${p.name}.');
  }

  // ---------------------------------------------------------------- rosters

  /// Verifies and stores a roster for a person we already know. Own-device rosters may also arrive via sync.
  Future<bool> acceptRoster(Roster r, {required String fromDevice}) async {
    final known = await repo.person(r.personId);
    if (known == null) return false;
    if (_deviceOwner[fromDevice] != r.personId && !isOwnDevice(fromDevice)) return false;
    if (!await r.verify(trusted: known.roster)) return false;
    final before = known.roster.devices.map((d) => d.id).toSet();
    await repo.saveRoster(r, isMe: known.isMe);
    await reload();
    final added = r.devices.where((d) => !before.contains(d.id));
    for (final d in added) {
      host.notifyInfo(
        known.isMe ? 'New device linked' : '${known.name} added a device',
        known.isMe ? '${d.name} is now one of your devices.' : '${d.name} can now reach you.',
      );
    }
    if (known.isMe && r.device(id.deviceId) == null) await _theyForgotUs(known);
    return true;
  }

  Future<void> _pushRoster(Device d) async {
    final c = client(d);
    if (c == null) return;
    try {
      await c.call('POST', '/v1/roster', body: me.roster.toJson());
    } catch (_) {
    } finally {
      c.close();
    }
  }

  /// Signs and stores a new version of my roster, then tells everyone.
  Future<void> updateMyRoster(Roster next) async {
    final signed = await next.signedBy(id.deviceId, id.sign);
    await repo.saveRoster(signed, isMe: true);
    await reload();
    for (final c in contacts) {
      await repo.enqueue(c.id, 'roster', {});
      for (final d in await onlineDevices(c.id)) {
        unawaited(flushOutbox(d.personId));
      }
    }
    for (final d in await onlineDevices(me.id)) {
      unawaited(_pushRoster(d));
    }
  }

  /// [pngB64] is a small PNG (UI crops to 192 px) or '' to remove.
  Future<void> setMyAvatar(String pngB64) => updateMyRoster(me.roster.copyWith(avatar: pngB64));

  /// Speed limit for sending, in bytes per second; 0 = no limit (PRD F18).
  int speedLimit = 0;

  Future<void> setSpeedLimit(int bytesPerSecond) async {
    speedLimit = bytesPerSecond;
    await repo.setSetting('speed_limit', '$bytesPerSecond');
    notifyListeners();
  }

  Future<void> unpairAll() async {
    for (final c in List.of(contacts)) {
      await unpair(c.id);
    }
  }

  /// Every conversation as JSON, for "Export history".
  Future<String> exportHistory() async {
    final out = <Map<String, Object?>>[];
    for (final p in [me, ...contacts]) {
      out.add({
        'person': p.isMe ? 'My devices' : p.name,
        'messages': [
          for (final m in await repo.messages(p.id, limit: 1 << 30))
            {
              'at': DateTime.fromMillisecondsSinceEpoch(m.createdAt).toIso8601String(),
              'from': m.author == me.id ? me.roster.name : p.name,
              'type': m.type,
              ...m.body,
            },
        ],
      });
    }
    return const JsonEncoder.withIndent('  ').convert(out);
  }

  Future<void> renameMe(String name) async {
    await repo.setSetting('my_name', name);
    await updateMyRoster(me.roster.copyWith(name: name));
  }

  Future<void> renameThisDevice(String name) async {
    await updateMyRoster(
      me.roster.copyWith(
        devices: [
          for (final d in me.roster.devices)
            d.id == id.deviceId
                ? RosterDevice(
                    id: d.id,
                    name: name,
                    platform: d.platform,
                    signPk: d.signPk,
                    certFp: d.certFp,
                    addedAt: d.addedAt,
                  )
                : d,
        ],
      ),
    );
  }

  Future<void> removeMyDevice(String deviceId) async {
    if (deviceId == id.deviceId) return;
    await updateMyRoster(me.roster.copyWith(devices: me.roster.devices.where((d) => d.id != deviceId).toList()));
  }

  // ---------------------------------------------------------------- messages

  Map<String, Object?> _wire(Message m) => Map.of(m.row)..remove('log_seq');

  Future<void> sendText(String personId, String text) async {
    final m = await repo.addLocalMessage(
      personId,
      me.id,
      'text',
      {'text': text},
      deviceId: id.deviceId,
      status: personId == me.id ? 'sent' : 'queued',
    );
    notifyListeners();
    if (personId != me.id) await _deliver(m);
    _syncOwnSoon();
  }

  /// Adds a system bubble (missed request, trust invite, …) to a conversation.
  Future<Message> addSystem(String personId, Map<String, dynamic> body, {String? id}) async {
    final m = await repo.addLocalMessage(
      personId,
      me.id,
      'system',
      body,
      deviceId: this.id.deviceId,
      status: 'sent',
      id: id,
    );
    notifyListeners();
    _syncOwnSoon();
    return m;
  }

  /// Delivers to one online device of the contact; its own devices sync among themselves (PRD §11.7).
  Future<bool> _deliver(Message m) async {
    for (final d in await onlineDevices(m.conversation)) {
      final c = client(d)!;
      try {
        await c.call('POST', '/v1/message', body: _wire(m));
        await repo.updateMessage(m.id, status: 'delivered');
        notifyListeners();
        _syncOwnSoon();
        return true;
      } catch (_) {
      } finally {
        c.close();
      }
    }
    return false;
  }

  Future<void> flushOutbox(String personId) async {
    for (final m in await repo.messages(personId)) {
      if (m.status == 'queued' && m.type == 'text' && m.author == me.id) await _deliver(m);
    }
    for (final o in await repo.outboxFor(personId)) {
      final ok = await _sendOutbox(personId, o['kind'] as String, jsonDecode(o['payload_json'] as String));
      ok
          ? await repo.outboxDone(o['id'] as String)
          : await repo.outboxRetryLater(o['id'] as String, o['attempts'] as int);
    }
  }

  Future<bool> _sendOutbox(String personId, String kind, Map<String, dynamic> payload) async {
    for (final d in await onlineDevices(personId)) {
      final c = client(d)!;
      try {
        if (kind == 'roster') {
          await c.call('POST', '/v1/roster', body: me.roster.toJson());
        } else if (kind == 'trust') {
          await c.call('POST', '/v1/trust', body: payload);
        } else if (kind == 'read') {
          await c.call('POST', '/v1/read', body: payload);
        }
        return true;
      } catch (_) {
      } finally {
        c.close();
      }
    }
    return false;
  }

  Future<void> markRead(String personId) async {
    await repo.markRead(personId);
    notifyListeners();
    _sendReadSoon(personId);
  }

  /// A message from [personId] just landed; if their chat is on screen, they get a "seen".
  void seenIfOpen(String personId) {
    if (host.appVisible && host.openConversation == personId) _sendReadSoon(personId);
  }

  final _readTimers = <String, Timer>{};
  final _readSent = <String, String>{};

  /// Read receipt: ids of their newest messages here. They map ids to their own timestamps, so clocks don't matter.
  void _sendReadSoon(String personId) {
    if (personId == me.id) return;
    _readTimers[personId]?.cancel();
    _readTimers[personId] = Timer(const Duration(milliseconds: 500), () async {
      final ids = [
        for (final m in await repo.messages(personId, limit: 40))
          if (m.author == personId) m.id,
      ];
      if (ids.isEmpty || _readSent[personId] == ids.last) return;
      _readSent[personId] = ids.last;
      final body = {'ids': ids.length > 20 ? ids.sublist(ids.length - 20) : ids};
      if (!await _sendOutbox(personId, 'read', body)) await repo.enqueue(personId, 'read', body);
    });
  }

  Future<Res> _onRead(Req r) async {
    final p = personOfDevice(r.device!);
    if (p == null || p.isMe) return const Res(403, {'error': 'not_contact'});
    var upto = 0;
    for (final id in (r.body['ids'] as List).cast<String>()) {
      final m = await repo.message(id);
      if (m != null && m.conversation == p.id && m.author == me.id && m.createdAt > upto) upto = m.createdAt;
    }
    var changed = false;
    for (final m in await repo.messages(p.id)) {
      if (m.author == me.id && m.type != 'system' && m.createdAt <= upto && !const {'read', 'queued'}.contains(m.status)) {
        await repo.updateMessage(m.id, status: 'read');
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      _syncOwnSoon();
    }
    return Res.ok();
  }

  // ---------------------------------------------------------------- buzz (find my phone)

  /// Who is ringing this device right now, or null. The UI shows a full-screen card while set.
  final buzzing = ValueNotifier<({String id, String name, String photo})?>(null);
  Timer? _buzzEnd;

  /// Rings every online device of [personId] (mine too: "find my phone"), even on silent.
  /// Returns how many devices answered.
  Future<int> buzz(String personId, {bool stop = false}) async {
    final rs = await Future.wait([
      for (final d in await onlineDevices(personId))
        () async {
          final c = client(d)!;
          try {
            await c.call('POST', '/v1/buzz', body: {'stop': stop});
            return true;
          } catch (_) {
            return false;
          } finally {
            c.close();
          }
        }(),
    ]);
    return rs.where((ok) => ok).length;
  }

  void stopBuzz() {
    _buzzEnd?.cancel();
    if (buzzing.value == null) return;
    buzzing.value = null;
    host.stopBuzz();
  }

  Future<Res> _onBuzz(Req r) async {
    final p = personOfDevice(r.device!);
    if (p == null) return const Res(403, {'error': 'not_contact'});
    if (p.blocked) return Res.ok();
    if (r.body['stop'] == true) {
      stopBuzz();
      return Res.ok();
    }
    final who = p.isMe ? (await repo.device(r.device!))?.name ?? 'Your other device' : p.name;
    buzzing.value = (id: p.id, name: who, photo: p.roster.avatar);
    host.buzz(who);
    _buzzEnd?.cancel();
    _buzzEnd = Timer(const Duration(seconds: 30), stopBuzz);
    return Res.ok();
  }

  Future<void> clearHistory(String personId) async {
    await repo.clearHistory(personId);
    notifyListeners();
  }

  Future<void> deleteForMe(String messageId) async {
    await repo.updateMessage(messageId, deleted: true);
    notifyListeners();
    _syncOwnSoon();
  }

  // ---------------------------------------------------------------- contacts

  Future<void> setNickname(String personId, String? nick) => _meta(personId, {'nickname': nick});
  Future<void> setFavorite(String personId, bool v) => _meta(personId, {'favorite': v ? 1 : 0});
  Future<void> setBlocked(String personId, bool v) => _meta(personId, {'blocked': v ? 1 : 0});
  Future<void> setFolder(String personId, String? folder) async {
    await repo.updatePerson(personId, {'folder': folder}); // per device, not synced
    await reload();
  }

  Future<void> _meta(String personId, Map<String, Object?> v) async {
    await repo.updatePerson(personId, {...v, 'meta_updated_at': nowMs()});
    await reload();
    _syncOwnSoon();
  }

  Future<void> unpair(String personId) async {
    final p = await repo.person(personId);
    if (p == null || p.isMe) return;
    final tomb = await _tombstones();
    tomb[personId] = nowMs();
    await repo.setSetting('tombstones', jsonEncode(tomb));
    await repo.deletePerson(personId);
    await reload();
    _syncOwnSoon();
    // Their next request gets 401 unknownDevice and they drop us too.
  }

  Future<Map<String, int>> _tombstones() async =>
      ((jsonDecode(await repo.setting('tombstones') ?? '{}') as Map).cast<String, int>());

  // ---------------------------------------------------------------- auto-accept (PRD §11.8)

  Future<void> trustPropose(String personId, Limits mine) async {
    final p = (await repo.person(personId))!;
    final t = p.trust.propose(mine);
    await _saveTrust(personId, t);
    await _trustSend(personId, {
      'op': t.state == TrustState.active ? 'accept' : 'propose',
      'limits': mine.toJson(),
      'rev': t.rev,
    });
    await addSystem(personId, {'kind': t.state == TrustState.active ? 'trust_on' : 'trust_proposed_by_me'});
  }

  Future<void> trustAccept(String personId, Limits mine) async {
    final p = (await repo.person(personId))!;
    final t = p.trust.accept(mine);
    if (t.state != TrustState.active) return;
    await _saveTrust(personId, t);
    await _trustSend(personId, {'op': 'accept', 'limits': mine.toJson(), 'rev': t.rev});
    await addSystem(personId, {'kind': 'trust_on'});
  }

  Future<void> trustRevoke(String personId) async {
    final p = (await repo.person(personId))!;
    if (p.trust.state == TrustState.none) return;
    final t = p.trust.revoke();
    await _saveTrust(personId, t);
    await _trustSend(personId, {'op': 'revoke', 'rev': t.rev});
    await addSystem(personId, {'kind': 'trust_off_by_me'});
  }

  Future<void> _saveTrust(String personId, Trust t) async {
    await repo.saveTrust(personId, t);
    await reload();
    _syncOwnSoon();
  }

  Future<void> _trustSend(String personId, Map<String, dynamic> body) async {
    if (!await _sendOutbox(personId, 'trust', body)) await repo.enqueue(personId, 'trust', body);
  }

  Future<Res> _onTrust(Req r) async {
    final p = personOfDevice(r.device!);
    if (p == null || p.isMe) return const Res(403, {'error': 'not_contact'});
    final b = r.body;
    final rev = b['rev'] as int;
    final before = p.trust;
    final t = switch (b['op']) {
      'propose' => before.onTheirPropose(Limits.fromJson(b['limits']), rev),
      'accept' =>
        before.state == TrustState.proposedByMe
            ? before.onTheirAccept(Limits.fromJson(b['limits']), rev)
            : before.onTheirPropose(Limits.fromJson(b['limits']), rev),
      'revoke' => before.onTheirRevoke(rev),
      _ => before,
    };
    if (t.state != before.state) {
      await _saveTrust(p.id, t);
      await addSystem(p.id, {
        'kind': switch (t.state) {
          TrustState.proposedByThem => 'trust_proposed_by_them',
          TrustState.active => 'trust_on',
          _ => 'trust_off_by_them',
        },
      });
      if (t.state == TrustState.proposedByThem) {
        host.notifyMessage(p.id, p.name, '${p.name} wants to skip approval for files between you.');
      }
    }
    return Res.ok();
  }

  // ---------------------------------------------------------------- own-device sync (PRD §11.7)

  Timer? _syncDebounce;
  void _syncOwnSoon() {
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 400), () async {
      for (final d in await onlineDevices(me.id)) {
        unawaited(syncWith(d));
      }
    });
  }

  Future<Map<String, dynamic>> _syncState() async => {
    'me': me.roster.toJson(),
    'my_secret': me.secret,
    'tombstones': await _tombstones(),
    'contacts': [
      for (final c in await repo.contacts())
        {
          'roster': c.roster.toJson(),
          'secret': c.secret,
          'created_at': (await repo.db.query(
            'person',
            columns: ['created_at'],
            where: 'id=?',
            whereArgs: [c.id],
          )).first['created_at'],
          'nickname': c.nickname,
          'favorite': c.favorite,
          'blocked': c.blocked,
          'meta_updated_at': (await repo.db.query(
            'person',
            columns: ['meta_updated_at'],
            where: 'id=?',
            whereArgs: [c.id],
          )).first['meta_updated_at'],
          'trust': c.trust.toJson(),
        },
    ],
  };

  Future<void> _mergeState(Map<String, dynamic> s, String fromDevice) async {
    final myRoster = Roster.fromJson(s['me']);
    if (myRoster.version > me.roster.version) await acceptRoster(myRoster, fromDevice: fromDevice);
    final tomb = await _tombstones();
    (s['tombstones'] as Map).cast<String, int>().forEach((k, v) {
      if ((tomb[k] ?? 0) < v) tomb[k] = v;
    });
    await repo.setSetting('tombstones', jsonEncode(tomb));
    for (final c in (s['contacts'] as List).cast<Map<String, dynamic>>()) {
      final r = Roster.fromJson(c['roster']);
      final createdAt = c['created_at'] as int;
      if ((tomb[r.personId] ?? 0) > createdAt) continue;
      final local = await repo.person(r.personId);
      if (local == null) {
        if (!await r.verify()) continue;
        await repo.saveRoster(r, isMe: false, secret: c['secret']);
        await repo.updatePerson(r.personId, {'created_at': createdAt});
      } else if (r.version > local.roster.version && await r.verify(trusted: local.roster)) {
        await repo.saveRoster(r, isMe: false);
      }
      final lp = (await repo.db.query('person', where: 'id=?', whereArgs: [r.personId])).first;
      if ((c['meta_updated_at'] as int) > (lp['meta_updated_at'] as int)) {
        await repo.updatePerson(r.personId, {
          'nickname': c['nickname'],
          'favorite': c['favorite'] == true ? 1 : 0,
          'blocked': c['blocked'] == true ? 1 : 0,
          'meta_updated_at': c['meta_updated_at'],
        });
      }
      final t = Trust.fromJson(c['trust']);
      if (t.rev > Person(lp).trust.rev) await repo.saveTrust(r.personId, t);
    }
    for (final entry in tomb.entries) {
      final p = await repo.person(entry.key);
      if (p != null && !p.isMe) {
        final created =
            (await repo.db.query(
                  'person',
                  columns: ['created_at'],
                  where: 'id=?',
                  whereArgs: [p.id],
                )).first['created_at']
                as int;
        if (created < entry.value) await repo.deletePerson(p.id);
      }
    }
    await reload();
  }

  final _syncing = <String>{};

  /// Pulls everything [d] has that I don't, in pages of 500.
  Future<void> syncWith(Device d) async {
    if (!_syncing.add(d.id)) return;
    final c = client(d);
    try {
      if (c == null) return;
      var more = true;
      while (more) {
        final cursor = await repo.cursor(d.id);
        final r = await c.call('POST', '/v1/sync', body: {'cursor': cursor, 'state': await _syncState()});
        await _mergeState((r['state'] as Map).cast(), d.id);
        for (final m in (r['messages'] as List).cast<Map<String, dynamic>>()) {
          await repo.upsertMessage(m, countUnread: m['author_person'] != me.id);
        }
        await repo.setCursor(d.id, r['max'] as int);
        more = r['more'] == true;
      }
      notifyListeners();
    } catch (_) {
    } finally {
      c?.close();
      _syncing.remove(d.id);
    }
  }

  Future<Res> _onSync(Req r) async {
    if (!isOwnDevice(r.device!)) return const Res(403, {'error': 'not_own_device'});
    await _mergeState((r.body['state'] as Map).cast(), r.device!);
    final rows = await repo.messagesSince(r.body['cursor'] as int);
    final max = rows.isEmpty ? r.body['cursor'] as int : rows.last['log_seq'] as int;
    final out = Res.ok({
      'state': await _syncState(),
      'messages': [for (final m in rows) Map.of(m)..remove('log_seq')],
      'max': max,
      'more': rows.length == 500,
    });
    // They just sent us their state; pull their messages too.
    final d = await repo.device(r.device!);
    if (d != null) unawaited(Future.delayed(const Duration(milliseconds: 50), () => syncWith(d)));
    return out;
  }

  // ---------------------------------------------------------------- routes

  void _routes() {
    server.on('GET', '/v1/hello', (r) async => Res.ok({'proto': 1}), public: true);
    server.on('POST', '/v1/pair', pairing.handle, public: true);
    server.on('POST', '/v1/ping', (r) async {
      final p = personOfDevice(r.device!);
      if (p == null) return const Res(401, {'error': 'unknownDevice'});
      final port = r.body['port'] as int? ?? 47823;
      final wasOnline = deviceOnline(r.device!);
      _live[r.device!] = Endpoint(r.remoteIp, port, nowMs());
      await repo.seen(r.device!, r.remoteIp, port);
      if (!wasOnline) {
        notifyListeners();
        final d = await repo.device(r.device!);
        if (d != null) unawaited(_onDeviceOnline(d));
      }
      final have = r.body['have'] as int;
      final theirs = r.body['mine'] as int;
      return Res.ok({
        'device': id.deviceId,
        if (have < me.roster.version) 'roster': me.roster.toJson(),
        'want_mine': theirs > p.roster.version,
      });
    });
    server.on('POST', '/v1/roster', (r) async {
      final ok = await acceptRoster(Roster.fromJson(r.body), fromDevice: r.device!);
      return ok ? Res.ok() : const Res(409, {'error': 'roster_rejected'});
    });
    server.on('POST', '/v1/message', (r) async {
      final p = personOfDevice(r.device!);
      if (p == null || p.isMe) return const Res(403, {'error': 'not_contact'});
      if (p.blocked) return Res.ok(); // silently dropped
      final m = Map<String, Object?>.from(r.body);
      if (m['author_person'] != p.id || m['origin_device'] != r.device) return const Res(400, {'error': 'bad_author'});
      m['conversation_id'] = p.id;
      m['status'] = 'delivered';
      final visible = host.appVisible && host.openConversation == p.id;
      if (await repo.upsertMessage(m, countUnread: !visible)) {
        notifyListeners();
        _syncOwnSoon();
        final body = jsonDecode(m['body_json'] as String) as Map;
        if (!visible && m['type'] == 'text') host.notifyMessage(p.id, p.name, '${body['text']}');
        seenIfOpen(p.id);
      }
      return Res.ok();
    });
    server.on('POST', '/v1/sync', _onSync);
    server.on('POST', '/v1/trust', _onTrust);
    server.on('POST', '/v1/read', _onRead);
    server.on('POST', '/v1/buzz', _onBuzz);
    transfers.routes(server);
  }
}
