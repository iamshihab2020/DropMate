import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'data/db.dart';
import 'data/repo.dart';
import 'platform/host_impl.dart';
import 'platform/native.dart';
import 'services/engine.dart';
import 'services/identity.dart';
import 'services/sources.dart';
import 'ui/app.dart';

const _controlPort = 47824; // localhost only: second instance hands its files to the running one

class _SecureStore implements SecretStore {
  final _s = const FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _s.read(key: 'dm_$key');
  @override
  Future<void> write(String key, String value) => _s.write(key: 'dm_$key', value: value);
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final shares = StreamController<List<Source>>.broadcast();

  if (Platform.isWindows) {
    if (await _forwardToRunningInstance(args)) exit(0);
    await _windowsShell(args, shares);
  }

  final dir = (await getApplicationSupportDirectory()).path;
  final repo = Repo(await openAppDb(dir));
  final host = AppHost();
  await host.init();
  final custom = await repo.setting('download_dir');
  if (custom != null) Native.setDownloadDirOverride(custom);

  final id = await Identity.loadOrCreate(_SecureStore());
  final engine = Engine(id: id, repo: repo, host: host);
  if (Platform.isAndroid) {
    engine.transfers.resolve = Native.resolveRef;
    await Native.multicastLock(true);
    await Native.startService();
    Native.shared.listen(shares.add);
  }
  final pc = Platform.environment['COMPUTERNAME'] ?? '';
  final defaultName = Platform.isAndroid
      ? await Native.deviceModel()
      : pc.isEmpty
      ? 'Laptop'
      : '${pc[0]}${pc.substring(1).toLowerCase()} PC';
  await engine.start(deviceName: defaultName);
  unawaited(engine.transfers.cleanupStale());

  if (Platform.isWindows) {
    final files = [for (final a in args.where((a) => !a.startsWith('--'))) ...FileSource.expand(a)];
    if (files.isNotEmpty) Timer(const Duration(milliseconds: 600), () => shares.add(files));
  }

  runApp(
    DropMateApp(
      engine: engine,
      host: host,
      onboarded: await repo.setting('onboarded') == '1',
      incomingShares: shares.stream,
    ),
  );
}

/// Explorer "Send with DropMate" starts a new process per file; pass paths to the running app and quit.
Future<bool> _forwardToRunningInstance(List<String> args) async {
  try {
    final s = await Socket.connect(
      InternetAddress.loopbackIPv4,
      _controlPort,
      timeout: const Duration(milliseconds: 300),
    );
    s.write(jsonEncode(args.where((a) => !a.startsWith('--')).toList()));
    await s.flush();
    await s.close();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _windowsShell(List<String> args, StreamController<List<Source>> shares) async {
  // Single-instance control socket; batch paths that arrive together into one share.
  final pending = <String>[];
  Timer? flush;
  try {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, _controlPort);
    server.listen((sock) async {
      final text = await utf8.decoder.bind(sock).join();
      final paths = (jsonDecode(text) as List).cast<String>();
      await windowManager.show();
      await windowManager.focus();
      if (paths.isEmpty) return;
      pending.addAll(paths);
      flush?.cancel();
      flush = Timer(const Duration(milliseconds: 500), () {
        shares.add([for (final p in pending) ...FileSource.expand(p)]);
        pending.clear();
      });
    });
  } catch (_) {}

  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(size: Size(1000, 720), minimumSize: Size(420, 520), center: true, title: 'DropMate'),
    () async {
      if (!args.contains('--hidden')) {
        await windowManager.show();
        await windowManager.focus();
      }
    },
  );
  await windowManager.setPreventClose(true);
  windowManager.addListener(_WinListener());

  await trayManager.setIcon('assets/tray.ico');
  await trayManager.setToolTip('DropMate');
  await trayManager.setContextMenu(
    Menu(
      items: [
        MenuItem(key: 'open', label: 'Open DropMate'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit'),
      ],
    ),
  );
  trayManager.addListener(_TrayListener());

  final exe = Platform.resolvedExecutable;
  launchAtStartup.setup(appName: 'DropMate', appPath: exe, args: ['--hidden']);
  final marker = File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}.shell_v1');
  final firstRun = !marker.existsSync();
  // Re-register when the exe moved (e.g. debug build first, installed build later).
  if (firstRun || marker.readAsStringSync() != exe) {
    if (firstRun || await launchAtStartup.isEnabled()) await launchAtStartup.enable(); // default on (PRD §14.2)
    await _registerContextMenu(exe);
    marker
      ..createSync(recursive: true)
      ..writeAsStringSync(exe);
  }
}

/// Explorer right-click "Send with DropMate" for files and folders (current user only, no admin).
Future<void> _registerContextMenu(String exe) async {
  for (final cls in [r'*', 'Directory']) {
    final key = 'HKCU\\Software\\Classes\\$cls\\shell\\DropMate';
    await Process.run('reg', ['add', key, '/ve', '/d', 'Send with DropMate', '/f']);
    await Process.run('reg', ['add', key, '/v', 'Icon', '/d', exe, '/f']);
    await Process.run('reg', ['add', '$key\\command', '/ve', '/d', '"$exe" "%1"', '/f']);
  }
}

class _WinListener with WindowListener {
  @override
  void onWindowClose() => windowManager.hide(); // close-to-tray
}

class _TrayListener with TrayListener {
  @override
  void onTrayIconMouseDown() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) async {
    if (item.key == 'open') {
      await windowManager.show();
      await windowManager.focus();
    } else if (item.key == 'quit') {
      await trayManager.destroy();
      exit(0);
    }
  }
}
