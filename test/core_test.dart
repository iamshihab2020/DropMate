import 'dart:io';

import 'package:dropmate/core/chunks.dart';
import 'package:dropmate/core/crypto.dart';
import 'package:dropmate/core/protocol.dart';
import 'package:dropmate/core/roster.dart';
import 'package:dropmate/core/sanitize.dart';
import 'package:dropmate/core/trust.dart';
import 'package:dropmate/services/identity.dart';
import 'package:dropmate/services/net.dart';
import 'package:flutter_test/flutter_test.dart';

RosterDevice rd(Identity i, String name) =>
    RosterDevice(id: i.deviceId, name: name, platform: 'test', signPk: i.signPkB64, certFp: i.certFp, addedAt: 0);

void main() {
  group('sanitize', () {
    test('strips path tricks and reserved names', () {
      expect(sanitizeRelPath(r'..\..\Windows\evil.exe'), ['Windows', 'evil.exe']);
      expect(sanitizeSegment('CON.txt'), '_CON.txt');
      expect(sanitizeSegment('a:b?c*.mp4'), 'a_b_c_.mp4');
      expect(sanitizeSegment('trail. . '), 'trail');
      expect(sanitizeSegment('..'), 'file');
      expect(sanitizeSegment('${'x' * 300}.mkv').length, 200);
      expect(sanitizeSegment('${'x' * 300}.mkv'), endsWith('.mkv'));
    });

    test('unique path never overwrites', () {
      final dir = Directory.systemTemp.createTempSync('dm');
      File('${dir.path}${Platform.pathSeparator}a.txt').writeAsStringSync('x');
      expect(uniquePath(dir.path, 'a.txt'), endsWith('a (1).txt'));
      dir.deleteSync(recursive: true);
    });
  });

  test('chunk bitmap round trip', () {
    final b = ChunkBitmap(10)
      ..set(0)
      ..set(9);
    final c = ChunkBitmap.decode(10, b.encode());
    expect(c.done, 2);
    expect(c.missing(), [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(chunkCount(0), 1);
    expect(chunkCount(4 * 1024 * 1024 + 1), 2);
  });

  group('trust', () {
    test('needs both sides, revoke is unilateral', () {
      var me = const Trust();
      var them = const Trust();
      me = me.propose(const Limits(maxBytes: 100));
      expect(me.state, TrustState.proposedByMe);
      them = them.onTheirPropose(me.mine, me.rev);
      expect(them.state, TrustState.proposedByThem);
      expect(them.allows([(name: 'a.jpg', size: 1)]), isFalse);
      them = them.accept(const Limits(maxBytes: 1000));
      me = me.onTheirAccept(them.mine, them.rev);
      expect(me.state, TrustState.active);
      expect(them.state, TrustState.active);
      expect(me.allows([(name: 'a.jpg', size: 50)]), isTrue);
      expect(me.allows([(name: 'a.jpg', size: 500)]), isFalse); // my limit
      expect(them.allows([(name: 'a.jpg', size: 500)]), isTrue);
      expect(them.allows([(name: 'setup.exe', size: 1)]), isFalse); // executables always ask
      them = them.revoke();
      me = me.onTheirRevoke(them.rev);
      expect(me.state, TrustState.none);
    });

    test('simultaneous proposals become active', () {
      final a = const Trust().propose(const Limits());
      final b = const Trust().propose(const Limits());
      expect(a.onTheirPropose(b.mine, b.rev).state, TrustState.active);
    });

    test('stale propose after revoke is ignored', () {
      var a = const Trust().propose(const Limits()); // rev 1
      a = a.onTheirAccept(const Limits(), 1).revoke();
      expect(a.onTheirPropose(const Limits(), 1).state, TrustState.none);
    });
  });

  group('identity, roster, signed TLS', () {
    late Identity a, b, stranger;
    setUpAll(() async {
      a = await Identity.loadOrCreate(MemorySecretStore());
      b = await Identity.loadOrCreate(MemorySecretStore());
      stranger = await Identity.loadOrCreate(MemorySecretStore());
    });

    test('identity is stable across reloads', () async {
      final s = MemorySecretStore();
      final x = await Identity.loadOrCreate(s);
      final y = await Identity.loadOrCreate(s);
      expect(y.deviceId, x.deviceId);
      expect(y.certFp, x.certFp);
    });

    test('roster signatures', () async {
      final r = await Roster(
        personId: 'p',
        name: 'Shihab',
        version: 1,
        devices: [rd(a, 'laptop')],
      ).signedBy(a.deviceId, a.sign);
      expect(await r.verify(), isTrue);
      final r2 = await r.copyWith(devices: [...r.devices, rd(b, 'phone')]).signedBy(a.deviceId, a.sign);
      expect(await r2.verify(trusted: r), isTrue);
      // A device not in the trusted roster cannot add itself.
      final forged = await r
          .copyWith(devices: [...r.devices, rd(stranger, 'x')])
          .signedBy(stranger.deviceId, stranger.sign);
      expect(await forged.verify(trusted: r), isFalse);
      // Version must go up.
      expect(await r.verify(trusted: r), isFalse);
    });

    test('pinned TLS + signed requests; strangers, replays and wrong pins rejected', () async {
      final server = Server(a, (id) => id == b.deviceId ? b.sign.publicKey : null);
      server.on('POST', '/v1/echo', (r) async => Res.ok({'from': r.device, 'got': r.body['x']}));
      server.on('GET', '/v1/hello', (r) async => Res.ok({'ok': true}), public: true);
      await server.start(port: 0);

      final c = PeerClient(b, '127.0.0.1', server.port, {a.certFp});
      final res = await c.call('POST', '/v1/echo', body: {'x': 42});
      expect(res, {'from': b.deviceId, 'got': 42});

      final s = PeerClient(stranger, '127.0.0.1', server.port, {a.certFp});
      await expectLater(
        s.call('POST', '/v1/echo', body: {'x': 1}),
        throwsA(isA<PeerError>().having((e) => e.status, 'status', 401)),
      );
      expect(await s.call('GET', '/v1/hello', signed: false), {'ok': true});

      final wrongPin = PeerClient(b, '127.0.0.1', server.port, {stranger.certFp});
      await expectLater(wrongPin.call('GET', '/v1/hello', signed: false), throwsA(isA<HandshakeException>()));

      c.close();
      s.close();
      wrongPin.close();
      await server.stop();
    });
  });

  test('signed request: replay, skew and tampering rejected', () async {
    final k = await SignKeys.generate();
    final h = await signRequest(k, 'dev', 'POST', '/v1/message', 'abc');
    final nonces = NonceCache();
    Future<AuthError?> check({String path = '/v1/message', int? now}) => verifyRequest(
      method: 'POST',
      path: path,
      bodyHash: 'abc',
      header: (n) => h[n],
      pkFor: (d) => d == 'dev' ? k.publicKey : null,
      nonces: nonces,
      now: now,
    );
    expect(await check(path: '/v1/other'), AuthError.badSig);
    expect(await check(now: int.parse(h[hTime]!) + 11 * 60 * 1000), AuthError.skew);
    expect(await check(), isNull);
    expect(await check(), AuthError.replay);
  });

  test('emoji check is symmetric', () {
    expect(emojiCheck('aa', 'bb'), emojiCheck('bb', 'aa'));
    expect(emojiCheck('aa', 'bb'), hasLength(4));
  });
}
