import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/crypto.dart';
import '../core/protocol.dart';
import 'identity.dart';

class Req {
  final HttpRequest raw;
  final String path;
  final Map<String, String> params;
  final String? device; // verified sender device ID, null for public routes
  final Object? json;

  Req(this.raw, this.path, this.params, this.device, this.json);
  Map<String, dynamic> get body => (json as Map).cast<String, dynamic>();
  String get remoteIp => raw.connectionInfo?.remoteAddress.address ?? '';
}

class Res {
  final int status;
  final Object? json;
  const Res(this.status, [this.json]);
  static Res ok([Object? j]) => Res(200, j ?? const {});
}

typedef Handler = Future<Res> Function(Req r);

class _Route {
  final String method;
  final RegExp pattern;
  final List<String> names;
  final bool public;
  final bool streamBody; // handler reads the body itself (chunk upload)
  final Handler handler;
  _Route(this.method, this.pattern, this.names, this.public, this.streamBody, this.handler);
}

/// HTTPS server with signed-request auth on every non-public route (PRD §11.3).
class Server {
  final Identity id;
  final List<int>? Function(String deviceId) pkFor;
  final _routes = <_Route>[];
  final _nonces = NonceCache();
  HttpServer? _http;

  Server(this.id, this.pkFor);

  int get port => _http?.port ?? 0;

  void on(String method, String path, Handler h, {bool public = false, bool streamBody = false}) {
    final names = <String>[];
    final re = path.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
      names.add(m[1]!);
      return '([^/]+)';
    });
    _routes.add(_Route(method, RegExp('^$re\$'), names, public, streamBody, h));
  }

  Future<void> start({int port = defaultPort}) async {
    for (var p = port; p < port + 20; p++) {
      try {
        _http = await HttpServer.bindSecure(InternetAddress.anyIPv4, p, id.serverContext());
        break;
      } on SocketException {
        if (p == port + 19) rethrow;
      }
    }
    _http!.listen(_handle, onError: (_) {});
  }

  Future<void> stop() async => _http?.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      _Route? route;
      RegExpMatch? m;
      for (final r in _routes) {
        if (r.method != req.method) continue;
        m = r.pattern.firstMatch(path);
        if (m != null) {
          route = r;
          break;
        }
      }
      if (route == null) return _send(res, const Res(404, {'error': 'not_found'}));
      final proto = int.tryParse(req.headers.value(hProto) ?? '$protoVersion') ?? protoVersion;
      if (proto > protoVersion) return _send(res, const Res(426, {'error': 'update_needed'}));
      final params = {for (var i = 0; i < route.names.length; i++) route.names[i]: m!.group(i + 1)!};

      Object? json;
      String bodyHash;
      if (route.streamBody) {
        bodyHash = req.headers.value(hChunkHash) ?? '';
      } else {
        final bytes = await _readLimited(req, 4 * 1024 * 1024);
        bodyHash = sha256Hex(bytes);
        json = bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
      }

      String? device;
      if (!route.public) {
        final err = await verifyRequest(
          method: req.method,
          path: path,
          bodyHash: bodyHash,
          header: req.headers.value,
          pkFor: pkFor,
          nonces: _nonces,
        );
        if (err != null) return _send(res, Res(401, {'error': err.name}));
        device = req.headers.value(hDevice);
      }
      _send(res, await route.handler(Req(req, path, params, device, json)));
    } catch (e) {
      _send(res, Res(500, {'error': '$e'}));
    }
  }

  Future<List<int>> _readLimited(HttpRequest req, int max) async {
    final b = BytesBuilder(copy: false);
    await for (final c in req) {
      b.add(c);
      if (b.length > max) throw const HttpException('body too large');
    }
    return b.takeBytes();
  }

  void _send(HttpResponse res, Res r) {
    res.statusCode = r.status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(r.json ?? const {}));
    res.close();
  }
}

class PeerError implements Exception {
  final int status;
  final String code;
  PeerError(this.status, this.code);
  @override
  String toString() => 'PeerError($status, $code)';
}

/// Signed HTTPS calls to one device, pinned to its certificate fingerprint.
class PeerClient {
  final Identity me;
  final String host;
  final int port;
  final Set<String>? pins; // allowed cert fingerprints; null only for pairing, where the caller checks [seenFp]
  late final HttpClient _http;
  String? seenFp;

  PeerClient(this.me, this.host, this.port, this.pins) {
    _http = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..idleTimeout = const Duration(seconds: 30)
      ..badCertificateCallback = (cert, _, _) {
        seenFp = certFingerprintDer(cert.der);
        return pins == null || pins!.contains(seenFp);
      };
  }

  void close() => _http.close(force: true);

  Future<Map<String, dynamic>> call(
    String method,
    String path, {
    Object? body,
    bool signed = true,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final bytes = body == null ? <int>[] : utf8.encode(jsonEncode(body));
    final req = await _http.openUrl(method, Uri(scheme: 'https', host: host, port: port, path: path));
    req.headers.contentType = ContentType.json;
    req.headers.set(hProto, '$protoVersion');
    if (signed) {
      (await signRequest(me.sign, me.deviceId, method, path, sha256Hex(bytes))).forEach(req.headers.set);
    }
    req.contentLength = bytes.length;
    req.add(bytes);
    return _read(await req.close().timeout(timeout));
  }

  /// Streams one chunk; [hash] is the hex SHA-256 of [data], signed in place of the body hash.
  Future<Map<String, dynamic>> putChunk(String path, List<int> data, String hash) async {
    final req = await _http.openUrl('PUT', Uri(scheme: 'https', host: host, port: port, path: path));
    (await signRequest(me.sign, me.deviceId, 'PUT', path, hash)).forEach(req.headers.set);
    req.headers.set(hChunkHash, hash);
    req.headers.contentType = ContentType.binary;
    req.contentLength = data.length;
    req.add(data);
    return _read(await req.close().timeout(const Duration(seconds: 60)));
  }

  Future<Map<String, dynamic>> _read(HttpClientResponse res) async {
    final text = await res.transform(utf8.decoder).join();
    final j = text.isEmpty ? <String, dynamic>{} : (jsonDecode(text) as Map).cast<String, dynamic>();
    if (res.statusCode != 200) throw PeerError(res.statusCode, '${j['error'] ?? 'http_${res.statusCode}'}');
    return j;
  }
}
