import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A small pool of long-lived isolates that hash chunks in parallel, so 4 MiB SHA-256 never blocks
/// the UI and several chunks hash at once (PRD §11.9).
/// shortcut: pure-Dart SHA-256 (~70–200 MB/s per core); move to native CNG/MessageDigest if a core-bound phone limits speed.
class HashWorker {
  static Future<HashWorker>? _instance;
  static Future<HashWorker> get() => _instance ??= _spawn(max(2, min(4, Platform.numberOfProcessors - 1)));

  final List<SendPort> _to;
  final _pending = <int, Completer<String>>{};
  var _next = 0;

  static Future<HashWorker> _spawn(int n) async {
    final from = ReceivePort();
    final ports = <SendPort>[];
    final ready = Completer<void>();
    late final HashWorker w;
    from.listen((m) {
      if (m is SendPort) {
        ports.add(m);
        if (ports.length == n) ready.complete();
      } else {
        final (id, hex) = m as (int, String);
        w._pending.remove(id)?.complete(hex);
      }
    });
    for (var i = 0; i < n; i++) {
      await Isolate.spawn(_main, from.sendPort);
    }
    await ready.future;
    return w = HashWorker._raw(ports);
  }

  HashWorker._raw(this._to);

  Future<String> sha256Hex(Uint8List data) {
    final id = _next++;
    final c = Completer<String>();
    _pending[id] = c;
    _to[id % _to.length].send((id, TransferableTypedData.fromList([data])));
    return c.future;
  }

  static void _main(SendPort reply) {
    final inbox = ReceivePort();
    reply.send(inbox.sendPort);
    inbox.listen((m) {
      final (id, t) = m as (int, TransferableTypedData);
      reply.send((id, sha256.convert(t.materialize().asUint8List()).toString()));
    });
  }
}
