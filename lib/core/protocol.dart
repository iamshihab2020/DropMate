import 'dart:convert';

import 'crypto.dart';

const protoVersion = 1;
const defaultPort = 47823;
const mdnsType = '_dropmate._tcp';
const multicastGroup = '224.0.0.199';
const chunkSize = 4 * 1024 * 1024;
const requestTimeout = Duration(seconds: 60);
const maxSkew = Duration(minutes: 10);

const hDevice = 'x-dm-device';
const hTime = 'x-dm-time';
const hNonce = 'x-dm-nonce';
const hSig = 'x-dm-sig';
const hProto = 'x-dm-proto';
const hChunkHash = 'x-dm-chunk-hash';

/// Bytes covered by the request signature (PRD §11.3).
List<int> signingInput(String method, String path, int time, String nonce, String bodyHash) =>
    utf8.encode('$method\n$path\n$time\n$nonce\n$bodyHash');

Future<Map<String, String>> signRequest(
  SignKeys keys,
  String deviceId,
  String method,
  String path,
  String bodyHash,
) async {
  final time = DateTime.now().millisecondsSinceEpoch;
  final nonce = b64(randomBytes(16));
  final sig = await keys.sign(signingInput(method, path, time, nonce, bodyHash));
  return {hDevice: deviceId, hTime: '$time', hNonce: nonce, hSig: b64(sig), hProto: '$protoVersion'};
}

/// Remembers nonces for 2× the allowed skew so a captured request can't be replayed.
class NonceCache {
  final _seen = <String, int>{};

  bool checkAndAdd(String nonce, int now) {
    _seen.removeWhere((_, t) => now - t > maxSkew.inMilliseconds * 2);
    if (_seen.containsKey(nonce)) return false;
    _seen[nonce] = now;
    return true;
  }
}

enum AuthError { missing, unknownDevice, skew, replay, badSig }

/// Verifies signed request headers; [pkFor] returns the sign key of a known, non-removed device.
Future<AuthError?> verifyRequest({
  required String method,
  required String path,
  required String bodyHash,
  required String? Function(String name) header,
  required List<int>? Function(String deviceId) pkFor,
  required NonceCache nonces,
  int? now,
}) async {
  final dev = header(hDevice), t = header(hTime), n = header(hNonce), s = header(hSig);
  if (dev == null || t == null || n == null || s == null) return AuthError.missing;
  final pk = pkFor(dev);
  if (pk == null) return AuthError.unknownDevice;
  final time = int.tryParse(t);
  final nowMs = now ?? DateTime.now().millisecondsSinceEpoch;
  if (time == null || (nowMs - time).abs() > maxSkew.inMilliseconds) return AuthError.skew;
  final List<int> sig;
  try {
    sig = unb64(s);
  } catch (_) {
    return AuthError.badSig;
  }
  if (!await verifySig(signingInput(method, path, time, n, bodyHash), sig, pk)) return AuthError.badSig;
  // Replay check after the signature, so junk requests can't fill the cache.
  if (!nonces.checkAndAdd(n, nowMs)) return AuthError.replay;
  return null;
}
