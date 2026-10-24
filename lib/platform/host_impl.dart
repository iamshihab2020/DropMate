import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart' as w;

import '../services/host.dart';
import 'native.dart';

const _portName = 'dropmate_notification_actions';

// Allocated once and never freed: PlaySound with SND_ASYNC may read the name after returning.
final _alarm = r'C:\Windows\Media\Alarm01.wav'.toNativeUtf16();

/// Notification actions tapped while the UI isolate is not the one handling them (Android background).
@pragma('vm:entry-point')
void notificationBackground(NotificationResponse r) {
  IsolateNameServer.lookupPortByName(_portName)?.send([r.actionId, r.payload]);
}

class AppHost implements Host {
  final _n = FlutterLocalNotificationsPlugin();
  final _actions = ReceivePort();
  void Function(String transferId, bool accept)? onDecision;
  void Function(String? personId)? onOpen;
  void Function(String transferId)? onCancel;
  @override
  bool appVisible = true;
  @override
  String? openConversation;
  final _ids = <String, int>{};
  var _nextId = 100;

  Future<void> init() async {
    IsolateNameServer.removePortNameMapping(_portName);
    IsolateNameServer.registerPortWithName(_actions.sendPort, _portName);
    _actions.listen((m) => _handle((m as List)[0] as String?, m[1] as String?));
    await _n.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_notification'),
        windows: WindowsInitializationSettings(
          appName: 'DropMate',
          appUserModelId: 'com.dropmate.app',
          guid: '6f5b8c1e-2c4a-4d7e-9b1f-0d3a7e5c9a21',
        ),
      ),
      onDidReceiveNotificationResponse: (r) => _handle(r.actionId, r.payload),
      onDidReceiveBackgroundNotificationResponse: notificationBackground,
    );
    if (Platform.isAndroid) {
      final a = _n.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await a?.createNotificationChannel(
        const AndroidNotificationChannel(
          'requests',
          'Incoming files',
          description: 'Someone wants to send you files',
          importance: Importance.max,
        ),
      );
      await a?.createNotificationChannel(
        const AndroidNotificationChannel('messages', 'Messages', importance: Importance.high),
      );
      await a?.createNotificationChannel(
        const AndroidNotificationChannel('progress', 'Transfers in progress', importance: Importance.low),
      );
      await a?.createNotificationChannel(
        const AndroidNotificationChannel('info', 'Updates', importance: Importance.defaultImportance),
      );
    }
  }

  Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    return await _n
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission() ??
        false;
  }

  void _handle(String? action, String? payload) {
    if (payload == null) return;
    if (payload.startsWith('tx:')) {
      final tid = payload.substring(3);
      if (action == 'accept') return onDecision?.call(tid, true);
      if (action == 'decline') return onDecision?.call(tid, false);
      if (action == 'cancel') return onCancel?.call(tid);
      onOpen?.call(null);
    } else if (payload.startsWith('p:')) {
      onOpen?.call(payload.substring(2));
    }
  }

  int _id(String key) => _ids[key] ??= _nextId++;

  @override
  void notifyIncoming(String transferId, String title, String body) {
    _n.show(
      id: _id('tx:$transferId'),
      title: title,
      body: body,
      payload: 'tx:$transferId',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'requests',
          'Incoming files',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.public,
          timeoutAfter: 60000,
          actions: [AndroidNotificationAction('accept', 'Accept'), AndroidNotificationAction('decline', 'Decline')],
        ),
        windows: WindowsNotificationDetails(
          actions: [
            WindowsAction(content: 'Accept', arguments: 'accept'),
            WindowsAction(content: 'Decline', arguments: 'decline'),
          ],
          scenario: WindowsNotificationScenario.incomingCall,
        ),
      ),
    );
  }

  @override
  void cancelIncoming(String transferId) => _n.cancel(id: _id('tx:$transferId'));

  @override
  void notifyMessage(String personId, String title, String body) {
    if (appVisible && openConversation == personId) return;
    _n.show(
      id: _id('p:$personId'),
      title: title,
      body: body,
      payload: 'p:$personId',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'messages',
          'Messages',
          importance: Importance.high,
          priority: Priority.high,
        ),
        windows: WindowsNotificationDetails(),
      ),
    );
  }

  @override
  void notifyProgress(String transferId, String title, int percent) {
    // Windows shows progress in the chat bubble; a toast per update would be noise.
    if (!Platform.isAndroid) return;
    _n.show(
      id: _id('pg:$transferId'),
      title: title,
      body: '$percent%',
      payload: 'tx:$transferId',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'progress',
          'Transfers in progress',
          importance: Importance.low,
          priority: Priority.low,
          onlyAlertOnce: true,
          ongoing: true,
          showProgress: true,
          maxProgress: 100,
          progress: percent,
          actions: const [AndroidNotificationAction('cancel', 'Cancel')],
        ),
      ),
    );
  }

  @override
  void cancelProgress(String transferId) {
    if (Platform.isAndroid) _n.cancel(id: _id('pg:$transferId'));
  }

  @override
  void buzz(String from) {
    if (Platform.isAndroid) {
      Native.buzz(from);
      return;
    }
    if (!Platform.isWindows) return;
    w.PlaySound(_alarm, 0, w.SND_FILENAME | w.SND_ASYNC | w.SND_LOOP);
    notifyInfo('$from is buzzing you', 'Open DropMate to stop it.');
  }

  @override
  void stopBuzz() {
    if (Platform.isAndroid) Native.stopBuzz();
    if (Platform.isWindows) w.PlaySound(nullptr, 0, 0);
  }

  @override
  void notifyInfo(String title, String body) => _n.show(
    id: _nextId++,
    title: title,
    body: body,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails('info', 'Updates'),
      windows: WindowsNotificationDetails(),
    ),
  );

  // ---------------------------------------------------------------- files & power

  @override
  Future<String> downloadDir() async {
    final custom = await Native.downloadDirOverride();
    if (custom != null) return custom;
    if (Platform.isAndroid) return '/storage/emulated/0/Download/DropMate';
    return p.join(Platform.environment['USERPROFILE'] ?? '.', 'Downloads', 'DropMate');
  }

  @override
  Future<int?> freeBytes(String dir) async {
    Directory(dir).createSync(recursive: true);
    if (Platform.isAndroid) return Native.freeBytes(dir);
    if (!Platform.isWindows) return null;
    return using((arena) {
      final free = arena<Uint64>();
      final ok = w.GetDiskFreeSpaceEx(dir.toNativeUtf16(allocator: arena), free, nullptr, nullptr);
      return ok == 0 ? null : free.value;
    });
  }

  @override
  Future<void> onFileSaved(String path) async {
    if (Platform.isAndroid) return Native.scanFile(path);
    if (Platform.isWindows) {
      // Mark of the Web, so SmartScreen/Office treat it as downloaded (PRD §11.9).
      try {
        File('$path:Zone.Identifier').writeAsStringSync('[ZoneTransfer]\r\nZoneId=3\r\n');
      } catch (_) {}
    }
  }

  @override
  Future<void> setTransferActive(bool active) async {
    if (Platform.isAndroid) return Native.setTransferActive(active);
    if (Platform.isWindows) {
      const esContinuous = 0x80000000, esSystemRequired = 0x00000001;
      w.SetThreadExecutionState(active ? esContinuous | esSystemRequired : esContinuous);
    }
  }
}
