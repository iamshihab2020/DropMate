import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../services/sources.dart';

/// Android bridge (android/app/src/main/kotlin/.../Bridge.kt). All calls are no-ops elsewhere.
class Native {
  static const _c = MethodChannel('dropmate/platform');
  static final _shared = StreamController<List<Source>>.broadcast();
  static String? _downloadOverride;
  static bool _listening = false;

  /// The user tapped Stop on the buzz notification.
  static void Function()? onBuzzStopped;

  /// Files shared into DropMate from other apps (Android share sheet).
  static Stream<List<Source>> get shared {
    if (!_listening && Platform.isAndroid) {
      _listening = true;
      _c.setMethodCallHandler((call) async {
        if (call.method == 'shared') {
          final list = await _toSources((call.arguments as List).cast<Map>());
          if (list.isNotEmpty) _shared.add(list);
        } else if (call.method == 'buzzStopped') {
          onBuzzStopped?.call();
        }
      });
      _c.invokeMethod('readyForShares');
    }
    return _shared.stream;
  }

  static void setDownloadDirOverride(String? dir) => _downloadOverride = dir;
  static Future<String?> downloadDirOverride() async => _downloadOverride;

  static Future<int?> freeBytes(String dir) => _c.invokeMethod<int>('freeBytes', {'path': dir});
  static Future<void> scanFile(String path) => _c.invokeMethod('scanFile', {'path': path});
  static Future<void> setTransferActive(bool on) => _c.invokeMethod('transferActive', {'on': on});
  static Future<void> startService() async {
    if (Platform.isAndroid) await _c.invokeMethod('startService');
  }

  static Future<void> multicastLock(bool on) async {
    if (Platform.isAndroid) await _c.invokeMethod('multicastLock', {'on': on});
  }

  static Future<bool> isIgnoringBatteryOptimizations() async =>
      !Platform.isAndroid || (await _c.invokeMethod<bool>('ignoringBattery') ?? true);
  static Future<void> requestIgnoreBatteryOptimizations() => _c.invokeMethod('requestIgnoreBattery');
  static Future<void> openFile(String path) => _c.invokeMethod('openFile', {'path': path});
  static Future<void> shareFile(String path) => _c.invokeMethod('shareFile', {'path': path});
  static Future<String> manufacturer() async => await _c.invokeMethod<String>('manufacturer') ?? '';
  static Future<String> deviceModel() async => await _c.invokeMethod<String>('model') ?? 'Android';
  static Future<bool> needsStoragePermission() async => await _c.invokeMethod<bool>('needsStorage') ?? false;
  static Future<bool> requestStoragePermission() async => await _c.invokeMethod<bool>('requestStorage') ?? false;
  static Future<bool> requestCameraPermission() async => await _c.invokeMethod<bool>('requestCamera') ?? false;
  static Future<bool> vpnActive() async => await _c.invokeMethod<bool>('vpnActive') ?? false;

  /// System picker (ACTION_OPEN_DOCUMENT). Content URIs are read in place — no copy into app storage.
  static Future<List<Source>> pickFiles() async {
    final r = await _c.invokeMethod<List>('pickFiles');
    return _toSources((r ?? const []).cast<Map>());
  }

  /// Gallery: Android's photo picker, or the system picker limited to photos and videos.
  static Future<List<Source>> pickMedia() async {
    final r = await _c.invokeMethod<List>('pickMedia');
    return _toSources((r ?? const []).cast<Map>());
  }

  /// JPEG preview of a photo or video (file: or content: ref), or null.
  static Future<Uint8List?> thumb(String ref, int px) => _c.invokeMethod<Uint8List>('thumb', {'ref': ref, 'size': px});

  static Future<void> buzz(String from) => _c.invokeMethod('buzz', {'from': from});
  static Future<void> stopBuzz() => _c.invokeMethod('stopBuzz');

  /// Folder picker (SAF tree); expands to every file with its relative path.
  static Future<List<Source>> pickFolder() async {
    final r = await _c.invokeMethod<List>('pickFolder');
    return _toSources((r ?? const []).cast<Map>());
  }

  static Future<String?> pickDirectory() => _c.invokeMethod<String>('pickDirectory');

  static Future<List<Source>> _toSources(List<Map> items) async => [
    for (final m in items)
      UriSource(
        m['uri'] as String,
        m['rel'] as String,
        m['size'] as int,
        m['mime'] as String?,
        m['mtime'] as int? ?? 0,
      ),
  ];

  static Future<Source?> resolveRef(String ref, String relPath) async {
    if (ref.startsWith('file:')) return resolveFileRef(ref, relPath);
    if (!ref.startsWith('content:')) return null;
    final m = await _c.invokeMethod<Map>('stat', {'uri': ref});
    if (m == null) return null;
    return UriSource(ref, relPath, m['size'] as int, m['mime'] as String?, m['mtime'] as int? ?? 0);
  }
}

class UriSource implements Source {
  final String uri;
  @override
  final String relPath;
  @override
  final int size;
  @override
  final String? mime;
  @override
  final int mtime;
  int? _handle;

  UriSource(this.uri, this.relPath, this.size, this.mime, this.mtime);

  @override
  String get ref => uri;

  @override
  Future<Uint8List> read(int offset, int length) async {
    _handle ??= await Native._c.invokeMethod<int>('open', {'uri': uri});
    final r = await Native._c.invokeMethod<Uint8List>('read', {'h': _handle, 'offset': offset, 'length': length});
    if (r == null || r.length != length) throw const FileSystemException('Short read');
    return r;
  }

  @override
  Future<void> close() async {
    if (_handle != null) await Native._c.invokeMethod('close', {'h': _handle});
    _handle = null;
  }
}
