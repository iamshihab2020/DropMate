@Tags(['perf'])
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dropmate/services/identity.dart';
import 'package:flutter_test/flutter_test.dart';

// Server in its own isolate, like a separate device.
Future<void> _serve(List args) async {
  final port = args[0] as SendPort;
  final ctx = args[1] == null ? null : (SecurityContext()..useCertificateChainBytes(args[1])..usePrivateKeyBytes(args[2]));
  final srv = ctx == null ? await HttpServer.bind('127.0.0.1', 0) : await HttpServer.bindSecure('127.0.0.1', 0, ctx);
  srv.listen((r) async {
    await r.drain<void>();
    r.response.close();
  });
  port.send(srv.port);
}

Future<void> run(String label, List<int>? cert, List<int>? key, int par) async {
  final rp = ReceivePort();
  final iso = await Isolate.spawn(_serve, [rp.sendPort, cert, key]);
  final port = await rp.first as int;
  final c = HttpClient()..badCertificateCallback = (_, _, _) => true;
  final data = Uint8List(4 << 20);
  final sw = Stopwatch()..start();
  final jobs = <Future>[];
  for (var n = 0; n < 60; n++) {
    jobs.add(() async {
      final q = await c.putUrl(Uri.parse('${cert == null ? 'http' : 'https'}://127.0.0.1:$port/x'));
      q.contentLength = data.length;
      q.add(data);
      await (await q.close()).drain<void>();
    }());
    if (jobs.length >= par) await jobs.removeAt(0);
  }
  await Future.wait(jobs);
  print('$label par$par: ${(240 * 1000 / sw.elapsedMilliseconds).toStringAsFixed(0)} MB/s');
  c.close(force: true);
  iso.kill();
}

void main() {
  test('tls vs plain, server in another isolate', () async {
    final id = await Identity.loadOrCreate(MemorySecretStore());
    await run('plain', null, null, 1);
    for (final p in [1, 4]) {
      await run('tls', id.certPem.codeUnits, id.keyPem.codeUnits, p);
    }
  });
}
