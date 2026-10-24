import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dropmate/core/trust.dart';
import 'package:dropmate/data/db.dart';
import 'package:dropmate/data/repo.dart';
import 'package:dropmate/services/engine.dart';
import 'package:dropmate/services/host.dart';
import 'package:dropmate/services/identity.dart';
import 'package:dropmate/services/pairing.dart';
import 'package:dropmate/services/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Future<Engine> engine(String name, Directory root) async {
  final dir = Directory(p.join(root.path, name))..createSync();
  final repo = Repo(await openAppDb(dir.path));
  await repo.setSetting('my_name', name);
  final e = Engine(id: await Identity.loadOrCreate(MemorySecretStore()), repo: repo, host: NullHost(dir.path));
  await e.start(deviceName: '$name-device', port: 0, withDiscovery: false);
  return e;
}

Future<void> until(FutureOr<bool> Function() cond, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (!await cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future.delayed(const Duration(milliseconds: 50));
  }
}

String loopback(String qr) => qr.replaceFirst(RegExp(r'ip=[^&]*'), 'ip=127.0.0.1');

Future<void> pair(Engine a, Engine b, PairMode mode) async {
  final shown = await a.pairing.show(mode);
  final joined = await b.pairing.join(qr: loopback(shown.qr));
  expect(joined.emojis, shown.emojis);
  expect(joined.mode, mode);
  await until(() => shown.stage == PairStage.confirm);
  unawaited(a.pairing.confirm(shown, true));
  await b.pairing.confirm(joined, true);
  expect(joined.stage, PairStage.done, reason: joined.error);
  await until(() => shown.stage == PairStage.done);
}

void main() {
  late Directory root;
  late Engine shihab, wife, shihabPhone;

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('dm_e2e');
    shihab = await engine('Shihab', root);
    wife = await engine('Wife', root);
    shihabPhone = await engine('Fresh', root);
  });

  tearDownAll(() async {
    for (final e in [shihab, wife, shihabPhone]) {
      await e.stop();
    }
  });

  test('pair, chat, transfer, auto-accept, link own device, first device wins', () async {
    // --- pair contacts
    await pair(shihab, wife, PairMode.contact);
    expect(shihab.contacts.single.displayName, 'Wife');
    expect(wife.contacts.single.displayName, 'Shihab');
    final wifeId = wife.me.id, shihabId = shihab.me.id;

    // --- a used code can't be reused
    final s = await shihab.pairing.show(PairMode.contact);
    final first = await wife.pairing.join(qr: loopback(s.qr)).then((_) => 'ok', onError: (e) => '$e');
    expect(first, contains('already connected'));
    await expectLater(wife.pairing.join(qr: loopback(s.qr)), throwsA(anything));
    shihab.pairing.cancel();

    // --- text
    await shihab.sendText(wifeId, 'hello');
    await until(() async => (await wife.repo.messages(shihabId)).any((m) => m.body['text'] == 'hello'));
    expect((await shihab.repo.messages(wifeId)).last.status, 'delivered');

    // --- Wife opens the chat: Shihab's message turns "Seen"
    await wife.markRead(shihabId);
    await until(() async => (await shihab.repo.messages(wifeId)).last.status == 'read');

    // --- buzz rings her device until stopped
    expect(await shihab.buzz(wifeId), 1);
    expect(wife.buzzing.value?.name, 'Shihab');
    expect(await shihab.buzz(wifeId, stop: true), 1);
    expect(wife.buzzing.value, isNull);

    // --- file transfer with approval (3 chunks + a nested folder)
    final src = Directory(p.join(root.path, 'src', 'Album'))..createSync(recursive: true);
    final rnd = Random(1);
    final big = File(p.join(src.path, 'movie.mp4'))
      ..writeAsBytesSync(List.generate(9 * 1024 * 1024 + 123, (_) => rnd.nextInt(256)));
    Directory(p.join(src.path, 'sub')).createSync();
    File(p.join(src.path, 'sub', 'empty.txt')).writeAsBytesSync([]);
    final sources = FileSource.expand(src.path);
    expect(sources.map((s) => s.relPath).toSet(), {'Album/movie.mp4', 'Album/sub/empty.txt'});

    final tid = await shihab.transfers.send(wifeId, sources);
    await until(() => wife.transfers.pending.containsKey(tid));
    wife.transfers.decide(tid, true);
    await until(() async => (await shihab.repo.message(tid))!.body['state'] == 'done');
    final got = File(p.join(root.path, 'Wife', 'Album', 'movie.mp4'));
    expect(got.readAsBytesSync(), big.readAsBytesSync());
    expect(File(p.join(root.path, 'Wife', 'Album', 'sub', 'empty.txt')).existsSync(), isTrue);
    expect((await wife.repo.message(tid))!.body['state'], 'done');
    // timing for "9 MB in 1 s · 30 MB/s"
    final sent = (await shihab.repo.message(tid))!.body;
    expect(sent['moved'], big.lengthSync());
    expect(sent['took_ms'], isNonNegative);
    expect((await wife.repo.message(tid))!.body['moved'], greaterThan(0));

    // --- same name again never overwrites
    final t2 = await shihab.transfers.send(wifeId, [FileSource(big, 'movie.mp4')]);
    await until(() => wife.transfers.pending.containsKey(t2));
    wife.transfers.decide(t2, true);
    await until(() async => (await shihab.repo.message(t2))!.body['state'] == 'done');
    final t3 = await shihab.transfers.send(wifeId, [FileSource(big, 'movie.mp4')]);
    await until(() => wife.transfers.pending.containsKey(t3));
    wife.transfers.decide(t3, false);
    await until(() async => (await shihab.repo.message(t3))!.body['state'] == 'declined');
    expect(File(p.join(root.path, 'Wife', 'movie.mp4')).existsSync(), isTrue);

    // --- mutual auto-accept: needs both sides
    await shihab.trustPropose(wifeId, const Limits(maxBytes: 100 << 20));
    await until(() async => (await wife.repo.person(shihabId))!.trust.state == TrustState.proposedByThem);
    await wife.trustAccept(shihabId, const Limits(maxBytes: 100 << 20));
    await until(() async => (await shihab.repo.person(wifeId))!.trust.state == TrustState.active);
    final t4 = await shihab.transfers.send(wifeId, [FileSource(big, 'auto.bin')]);
    await until(() async => (await shihab.repo.message(t4))!.body['state'] == 'done');
    expect(wife.transfers.pending, isEmpty);
    // executables still ask
    final exe = File(p.join(root.path, 'src', 'setup.exe'))..writeAsBytesSync([1, 2, 3]);
    final t5 = await shihab.transfers.send(wifeId, [FileSource(exe, 'setup.exe')]);
    await until(() => wife.transfers.pending.containsKey(t5));
    wife.transfers.decide(t5, false);

    // --- link a fresh phone as Shihab's own device
    await pair(shihab, shihabPhone, PairMode.link);
    expect(shihabPhone.me.id, shihabId);
    expect(shihab.me.roster.devices, hasLength(2));
    await until(() => shihabPhone.me.roster.devices.length == 2);
    await until(() => shihabPhone.contacts.any((c) => c.id == wifeId));
    await until(() async => (await shihabPhone.repo.messages(wifeId)).any((m) => m.body['text'] == 'hello'));
    // Wife learns the new device without re-pairing.
    await until(() async => (await wife.repo.devices(personId: shihabId)).length == 2);
    // Trust state synced to the new device.
    expect(shihabPhone.contacts.firstWhere((c) => c.id == wifeId).trust.state, TrustState.active);

    // --- Wife sends: both of Shihab's devices ring, the first to accept wins
    wife.noteEndpoint(shihabPhone.id.deviceId, '127.0.0.1', shihabPhone.server.port);
    await wife.trustRevoke(shihabId);
    await until(() async => (await shihab.repo.person(wifeId))!.trust.state == TrustState.none);
    final pic = File(p.join(root.path, 'src', 'pic.jpg'))..writeAsBytesSync(List.filled(1000, 7));
    final t6 = await wife.transfers.send(shihabId, [FileSource(pic, 'pic.jpg')]);
    await until(() => shihab.transfers.pending.containsKey(t6) && shihabPhone.transfers.pending.containsKey(t6));
    shihabPhone.transfers.decide(t6, true);
    await until(() async => (await wife.repo.message(t6))!.body['state'] == 'done');
    expect((await wife.repo.message(t6))!.body['stored_on'], shihabPhone.id.deviceId);
    await until(() => !shihab.transfers.pending.containsKey(t6));
    expect(File(p.join(root.path, 'Fresh', 'pic.jpg')).existsSync(), isTrue);
    expect(File(p.join(root.path, 'Shihab', 'pic.jpg')).existsSync(), isFalse);

    // --- fetch it to the laptop from the phone
    expect(await shihab.transfers.fetch(t6, shihabPhone.id.deviceId), isTrue);
    await until(() => File(p.join(root.path, 'Shihab', 'pic.jpg')).existsSync());
    await until(() async => (await shihab.transfers.localFiles(t6)).isNotEmpty);

    // --- strangers are rejected
    final stranger = await engine('Stranger', root);
    final shown = await shihab.pairing.show(PairMode.contact);
    shihab.pairing.cancel();
    await expectLater(stranger.pairing.join(qr: loopback(shown.qr)), throwsA(anything));
    await stranger.stop();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('pause mid-transfer, then resume sends only the rest (speed limit on)', () async {
    final rnd = Random(2);
    final f = File(p.join(root.path, 'src', 'resume.bin'))
      ..writeAsBytesSync(List.generate(20 * 1024 * 1024, (_) => rnd.nextInt(256)));
    await shihab.setSpeedLimit(6 << 20); // ~3 s for 20 MB, so we can pause in the middle
    final tid = await shihab.transfers.send(wife.me.id, [FileSource(f, 'resume.bin')]);
    await until(() => wife.transfers.pending.containsKey(tid));
    wife.transfers.decide(tid, true);
    await until(() => (shihab.transfers.progress[tid]?.done ?? 0) >= 8 << 20);
    await shihab.transfers.pause(tid);
    await until(() async => (await shihab.repo.message(tid))!.body['state'] == 'paused');
    final got = File(p.join(root.path, 'Wife', 'resume.bin'));
    expect(got.existsSync(), isFalse, reason: 'still a .dropmate-part while paused');

    await shihab.setSpeedLimit(0);
    await shihab.transfers.resume(tid);
    await until(() async => (await shihab.repo.message(tid))!.body['state'] == 'done');
    expect(got.readAsBytesSync(), f.readAsBytesSync());
  }, timeout: const Timeout(Duration(minutes: 2)));
}
