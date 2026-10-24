import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';

final _ed = Ed25519();
final _rand = Random.secure();

Uint8List randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => _rand.nextInt(256)));

String sha256Hex(List<int> bytes) => c.sha256.convert(bytes).toString();
Uint8List sha256Bytes(List<int> bytes) => Uint8List.fromList(c.sha256.convert(bytes).bytes);

Uint8List hmacSha256(List<int> key, List<int> data) => Uint8List.fromList(c.Hmac(c.sha256, key).convert(data).bytes);

/// Constant-time compare for MACs.
bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a[i] ^ b[i];
  }
  return r == 0;
}

const _b32 = 'abcdefghijklmnopqrstuvwxyz234567';

String base32(List<int> data) {
  final out = StringBuffer();
  var buffer = 0, bits = 0;
  for (final b in data) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out.write(_b32[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
  }
  if (bits > 0) out.write(_b32[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

String b64(List<int> d) => base64Url.encode(d).replaceAll('=', '');
Uint8List unb64(String s) => base64Url.decode(base64Url.normalize(s));

/// Device ID = base32(first 16 bytes of SHA-256(sign public key)) — PRD §11.1.
String deviceIdFor(List<int> signPk) => base32(sha256Bytes(signPk).sublist(0, 16));

class SignKeys {
  final SimpleKeyPair pair;
  final Uint8List publicKey;
  SignKeys(this.pair, this.publicKey);

  static Future<SignKeys> generate() async {
    final p = await _ed.newKeyPair();
    final pk = Uint8List.fromList((await p.extractPublicKey()).bytes);
    return SignKeys(p, pk);
  }

  static Future<SignKeys> fromSeed(List<int> seed) async {
    final p = await _ed.newKeyPairFromSeed(seed);
    final pk = Uint8List.fromList((await p.extractPublicKey()).bytes);
    return SignKeys(p, pk);
  }

  Future<Uint8List> seed() async => Uint8List.fromList(await pair.extractPrivateKeyBytes());

  Future<Uint8List> sign(List<int> msg) async => Uint8List.fromList((await _ed.sign(msg, keyPair: pair)).bytes);
}

Future<bool> verifySig(List<int> msg, List<int> sig, List<int> pk) async {
  if (sig.length != 64 || pk.length != 32) return false;
  return _ed.verify(
    msg,
    signature: Signature(sig, publicKey: SimplePublicKey(pk, type: KeyPairType.ed25519)),
  );
}

const _emojis = [
  '🐶',
  '🐱',
  '🦊',
  '🐻',
  '🐼',
  '🐨',
  '🐯',
  '🦁',
  '🐮',
  '🐷',
  '🐸',
  '🐵',
  '🐔',
  '🐧',
  '🐦',
  '🦉',
  '🐴',
  '🦄',
  '🐝',
  '🦋',
  '🐢',
  '🐙',
  '🐬',
  '🐳',
  '🌵',
  '🌲',
  '🌻',
  '🍎',
  '🍋',
  '🍉',
  '🍇',
  '🍓',
  '🥕',
  '🌽',
  '🍄',
  '🍕',
  '🍩',
  '🎂',
  '☕',
  '⚽',
  '🏀',
  '🎸',
  '🎲',
  '🚗',
  '🚲',
  '✈️',
  '🚀',
  '⛵',
  '🏠',
  '⏰',
  '💡',
  '🔑',
  '🎁',
  '📚',
  '✏️',
  '🔔',
  '🌙',
  '⭐',
  '☀️',
  '🌈',
  '❄️',
  '🔥',
  '💧',
  '🍀',
];

/// 4-emoji check shown on both pairing screens (PRD §11.5). Order-independent.
List<String> emojiCheck(String fpA, String fpB) {
  final pair = [fpA, fpB]..sort();
  final h = sha256Bytes(utf8.encode(pair.join('|')));
  return List.generate(4, (i) => _emojis[h[i] % _emojis.length]);
}
