@Tags(['perf'])
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dropmate/core/trust.dart';
import 'package:dropmate/services/pairing.dart';
import 'package:dropmate/services/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'e2e_test.dart' show engine, pair, until;

void main() {
  test('sha256 speed', () {
    final d = Uint8List(64 << 20);
    final sw = Stopwatch()..start();
    sha256.convert(d);
    print('sha256: ${(64 * 1000 / sw.elapsedMilliseconds).toStringAsFixed(0)} MB/s');
  });

  test('loopback transfer speed', () async {
    final root = Directory.systemTemp.createTempSync('dm_perf');
    final a = await engine('A', root), b = await engine('B', root);
    await pair(a, b, PairMode.contact);
    await a.trustPropose(b.me.id, const Limits(maxBytes: 1 << 40));
    await until(() async => (await b.repo.person(a.me.id))!.trust.state == TrustState.proposedByThem);
    await b.trustAccept(a.me.id, const Limits(maxBytes: 1 << 40));
    await until(() async => (await a.repo.person(b.me.id))!.trust.state == TrustState.active);
    final rnd = Random(3);
    final size = 300 << 20;
    final f = File(p.join(root.path, 'big.bin'))..writeAsBytesSync(Uint8List.fromList(List.generate(size, (_) => rnd.nextInt(256))));
    final sw = Stopwatch()..start();
    final tid = await a.transfers.send(b.me.id, [FileSource(f, 'big.bin')]);
    await until(() async => (await a.repo.message(tid))!.body['state'] == 'done', timeout: const Duration(minutes: 5));
    print('transfer: ${(300 * 1000 / sw.elapsedMilliseconds).toStringAsFixed(0)} MB/s');
    await a.stop();
    await b.stop();
  }, timeout: const Timeout(Duration(minutes: 6)));
}
