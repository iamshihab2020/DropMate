import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';

import '../core/crypto.dart';

abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class MemorySecretStore implements SecretStore {
  final _m = <String, String>{};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
}

/// This device's keys and TLS certificate (PRD §11.1). Private material lives in [SecretStore].
class Identity {
  final String deviceId;
  final SignKeys sign;
  final String certPem;
  final String keyPem;
  final String certFp;

  Identity._(this.deviceId, this.sign, this.certPem, this.keyPem, this.certFp);

  static Future<Identity> loadOrCreate(SecretStore store) async {
    var seed = await store.read('sign_seed');
    var cert = await store.read('tls_cert');
    var key = await store.read('tls_key');
    if (seed == null) {
      final k = await SignKeys.generate();
      seed = b64(await k.seed());
      await store.write('sign_seed', seed);
    }
    if (cert == null || key == null) {
      final pair = CryptoUtils.generateEcKeyPair();
      final priv = pair.privateKey as ECPrivateKey;
      final pub = pair.publicKey as ECPublicKey;
      final csr = X509Utils.generateEccCsrPem({'CN': 'dropmate'}, priv, pub);
      cert = X509Utils.generateSelfSignedCertificate(priv, csr, 3650);
      key = CryptoUtils.encodeEcPrivateKeyToPem(priv);
      await store.write('tls_cert', cert);
      await store.write('tls_key', key);
    }
    final sign = await SignKeys.fromSeed(unb64(seed));
    return Identity._(deviceIdFor(sign.publicKey), sign, cert, key, certFingerprintPem(cert));
  }

  String get signPkB64 => b64(sign.publicKey);

  SecurityContext serverContext() => SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));
}

String certFingerprintPem(String pem) => sha256Hex(CryptoUtils.getBytesFromPEMString(pem));
String certFingerprintDer(List<int> der) => sha256Hex(der);

String platformName() => Platform.isAndroid
    ? 'android'
    : Platform.isWindows
    ? 'windows'
    : Platform.operatingSystem;
