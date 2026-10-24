import 'dart:convert';

import 'crypto.dart';

class RosterDevice {
  final String id;
  final String name;
  final String platform;
  final String signPk; // b64
  final String certFp; // sha256 hex of TLS cert DER
  final int addedAt;

  RosterDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.signPk,
    required this.certFp,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'platform': platform,
    'sign_pk': signPk,
    'cert_fp': certFp,
    'added_at': addedAt,
  };

  factory RosterDevice.fromJson(Map<String, dynamic> j) => RosterDevice(
    id: j['id'],
    name: j['name'],
    platform: j['platform'],
    signPk: j['sign_pk'],
    certFp: j['cert_fp'],
    addedAt: j['added_at'],
  );
}

/// Signed list of one person's devices (PRD §11.6).
class Roster {
  final String personId;
  final String name;
  final int version;
  final List<RosterDevice> devices;
  final String signer;
  final String sig;
  final String avatar; // b64 PNG, 192 px, '' when none

  Roster({
    required this.personId,
    required this.name,
    required this.version,
    required this.devices,
    this.signer = '',
    this.sig = '',
    this.avatar = '',
  });

  Map<String, dynamic> _body() => {
    'person_id': personId,
    'name': name,
    'version': version,
    'devices': [for (final d in devices) d.toJson()],
    'signer': signer,
    if (avatar.isNotEmpty) 'avatar': avatar,
  };

  List<int> _signedBytes() => utf8.encode(jsonEncode(_body()));

  Map<String, dynamic> toJson() => {..._body(), 'sig': sig};

  factory Roster.fromJson(Map<String, dynamic> j) => Roster(
    personId: j['person_id'],
    name: j['name'],
    version: j['version'],
    devices: [for (final d in j['devices']) RosterDevice.fromJson(d)],
    signer: j['signer'],
    sig: j['sig'],
    avatar: j['avatar'] ?? '',
  );

  RosterDevice? device(String id) {
    for (final d in devices) {
      if (d.id == id) return d;
    }
    return null;
  }

  Future<Roster> signedBy(String deviceId, SignKeys keys) async {
    final r = Roster(
      personId: personId,
      name: name,
      version: version,
      devices: devices,
      signer: deviceId,
      avatar: avatar,
    );
    return Roster(
      personId: personId,
      name: name,
      version: version,
      devices: devices,
      signer: deviceId,
      avatar: avatar,
      sig: b64(await keys.sign(r._signedBytes())),
    );
  }

  /// A roster is valid if signed by a device that is in [trusted] (the previous roster),
  /// or — for a first-seen roster during pairing — by one of its own devices.
  Future<bool> verify({Roster? trusted}) async {
    final anchor = trusted ?? this;
    final s = anchor.device(signer);
    if (s == null) return false;
    if (trusted != null && (trusted.personId != personId || version <= trusted.version)) return false;
    // Device IDs must match their keys, or a roster could smuggle in a mislabeled key.
    for (final d in devices) {
      if (deviceIdFor(unb64(d.signPk)) != d.id) return false;
    }
    try {
      return await verifySig(_signedBytes(), unb64(sig), unb64(s.signPk));
    } catch (_) {
      return false;
    }
  }

  Roster copyWith({String? name, List<RosterDevice>? devices, String? avatar}) => Roster(
    personId: personId,
    name: name ?? this.name,
    version: version + 1,
    devices: devices ?? this.devices,
    avatar: avatar ?? this.avatar,
  );
}
