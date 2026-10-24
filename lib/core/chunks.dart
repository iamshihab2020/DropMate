import 'dart:typed_data';

import 'crypto.dart';
import 'protocol.dart';

int chunkCount(int size) => size == 0 ? 1 : (size + chunkSize - 1) ~/ chunkSize;

/// Which chunks of a file have arrived; persisted as b64 for resume (PRD §11.9).
class ChunkBitmap {
  final int count;
  final Uint8List bits;

  ChunkBitmap(this.count) : bits = Uint8List((count + 7) ~/ 8);
  ChunkBitmap._(this.count, this.bits);

  factory ChunkBitmap.decode(int count, String? s) {
    if (s == null || s.isEmpty) return ChunkBitmap(count);
    final b = unb64(s);
    return b.length == (count + 7) ~/ 8 ? ChunkBitmap._(count, b) : ChunkBitmap(count);
  }

  String encode() => b64(bits);

  bool has(int n) => (bits[n >> 3] & (1 << (n & 7))) != 0;
  void set(int n) => bits[n >> 3] |= 1 << (n & 7);

  int get done {
    var c = 0;
    for (var i = 0; i < count; i++) {
      if (has(i)) c++;
    }
    return c;
  }

  bool get complete => done == count;
  List<int> missing() => [
    for (var i = 0; i < count; i++)
      if (!has(i)) i,
  ];
}
