import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nsd/nsd.dart' as nsd;

import '../core/crypto.dart';
import '../core/protocol.dart';

class Sighting {
  final String ip;
  final int port;
  final String hint; // person hint, or '' while only pairing
  final String? pairHint; // set while the device shows a pairing code
  Sighting(this.ip, this.port, this.hint, this.pairHint);
}

/// Rotating, contacts-only person hint (PRD §11.2): HMAC(person_secret, utc day).
String personHint(String secretB64, {int dayOffset = 0}) {
  final day = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 86400000 + dayOffset;
  return sha256Hex(hmacSha256(unb64(secretB64), utf8.encode('hint:$day'))).substring(0, 16);
}

String pairCodeHint(String code) => sha256Hex(hmacSha256(utf8.encode(code), utf8.encode('find'))).substring(0, 12);

/// mDNS + UDP multicast. Emits every sighting; the engine decides who it is.
class Discovery {
  final _out = StreamController<Sighting>.broadcast();
  Stream<Sighting> get sightings => _out.stream;

  RawDatagramSocket? _udp;
  nsd.Registration? _reg;
  nsd.Discovery? _disc;
  Timer? _timer;
  int _port = 0;
  String _hint = '';
  String? _pairHint;
  Duration _interval = const Duration(seconds: 5);
  final _ownIps = <String>{};

  Future<void> start(int port, String hint) async {
    _port = port;
    _hint = hint;
    await _refreshOwnIps();
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, defaultPort, reuseAddress: true);
      _udp!.multicastLoopback = false;
      _udp!.joinMulticast(InternetAddress(multicastGroup));
      _udp!.listen((e) {
        if (e != RawSocketEvent.read) return;
        final d = _udp!.receive();
        if (d != null) _onPacket(d.address.address, d.data);
      });
    } catch (_) {
      // Port taken (e.g. second instance) — mDNS still works.
    }
    _announce(query: true);
    _schedule();
    unawaited(_startMdns());
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => _announce());
  }

  /// 5 s while foreground, 30 s in background (PRD §11.2).
  void setForeground(bool fg) {
    _interval = Duration(seconds: fg ? 5 : 30);
    _schedule();
    if (fg) _announce(query: true);
  }

  Future<void> update({String? hint, String? pairHint, bool clearPair = false}) async {
    _hint = hint ?? _hint;
    _pairHint = clearPair ? null : (pairHint ?? _pairHint);
    _announce();
    await _restartMdnsRegistration();
  }

  void _announce({bool query = false}) {
    final msg = utf8.encode(
      jsonEncode({
        'dm': protoVersion,
        'port': _port,
        'h': _hint,
        if (_pairHint != null) 'pair': _pairHint,
        if (query) 'q': 1,
      }),
    );
    try {
      _udp?.send(msg, InternetAddress(multicastGroup), defaultPort);
    } catch (_) {}
  }

  void _onPacket(String ip, Uint8List data) {
    if (_ownIps.contains(ip)) return;
    try {
      final j = jsonDecode(utf8.decode(data)) as Map;
      if (j['dm'] == null || j['port'] is! int) return;
      if (j['q'] == 1) _announce();
      _out.add(Sighting(ip, j['port'], '${j['h'] ?? ''}', j['pair'] as String?));
    } catch (_) {}
  }

  Future<void> _startMdns() async {
    try {
      await _restartMdnsRegistration();
      _disc = await nsd.startDiscovery(mdnsType, ipLookupType: nsd.IpLookupType.v4);
      _disc!.addServiceListener((s, status) {
        if (status != nsd.ServiceStatus.found) return;
        final ip = s.addresses?.firstOrNull?.address;
        if (ip == null || s.port == null || _ownIps.contains(ip)) return;
        String? txt(String k) {
          final v = s.txt?[k];
          return v == null ? null : utf8.decode(v);
        }

        _out.add(Sighting(ip, s.port!, txt('h') ?? '', txt('pair')));
      });
    } catch (_) {
      // mDNS unavailable on this network/OS — UDP and last-known IPs still work.
    }
  }

  Future<void> _restartMdnsRegistration() async {
    try {
      if (_reg != null) await nsd.unregister(_reg!);
      _reg = await nsd.register(
        nsd.Service(
          name: 'dropmate-${randomBytes(3).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
          type: mdnsType,
          port: _port,
          txt: {
            'v': utf8.encode('$protoVersion'),
            'h': utf8.encode(_hint),
            if (_pairHint != null) 'pair': utf8.encode(_pairHint!),
          },
        ),
      );
    } catch (_) {}
  }

  Future<void> _refreshOwnIps() async {
    try {
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        _ownIps.addAll(i.addresses.map((a) => a.address));
      }
    } catch (_) {}
  }

  Future<void> stop() async {
    _timer?.cancel();
    _udp?.close();
    if (_reg != null) await nsd.unregister(_reg!).catchError((_) {});
    if (_disc != null) await nsd.stopDiscovery(_disc!).catchError((_) {});
  }
}

/// Local IPv4 addresses for the QR code; prefers private LAN ranges.
Future<List<String>> localIps() async {
  final ips = <String>[];
  for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in i.addresses) {
      if (!a.isLoopback && !a.isLinkLocal) ips.add(a.address);
    }
  }
  int rank(String ip) => ip.startsWith('192.168.')
      ? 0
      : ip.startsWith('10.')
      ? 1
      : ip.startsWith('172.')
      ? 2
      : 3;
  ips.sort((a, b) => rank(a).compareTo(rank(b)));
  return ips;
}
