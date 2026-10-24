/// Platform services the engine needs; implemented per platform in lib/platform/.
abstract class Host {
  Future<String> downloadDir();
  Future<int?> freeBytes(String dir);

  /// After a received file is renamed into place: media scan (Android), Mark of the Web (Windows).
  Future<void> onFileSaved(String path);

  /// Wake lock + Wi-Fi lock (Android), prevent sleep (Windows).
  Future<void> setTransferActive(bool active);

  void notifyIncoming(String transferId, String title, String body);
  void cancelIncoming(String transferId);
  void notifyMessage(String personId, String title, String body);
  void notifyInfo(String title, String body);
  void notifyProgress(String transferId, String title, int percent);
  void cancelProgress(String transferId);

  /// Rings loudly (Android: alarm stream, so it plays on silent) until [stopBuzz] or 30 s.
  void buzz(String from);
  void stopBuzz();

  bool get appVisible;
  String? get openConversation;
}

class NullHost implements Host {
  final String dir;
  NullHost(this.dir);
  @override
  Future<String> downloadDir() async => dir;
  @override
  Future<int?> freeBytes(String dir) async => null;
  @override
  Future<void> onFileSaved(String path) async {}
  @override
  Future<void> setTransferActive(bool active) async {}
  @override
  void notifyIncoming(String transferId, String title, String body) {}
  @override
  void cancelIncoming(String transferId) {}
  @override
  void notifyMessage(String personId, String title, String body) {}
  @override
  void notifyInfo(String title, String body) {}
  @override
  void notifyProgress(String transferId, String title, int percent) {}
  @override
  void cancelProgress(String transferId) {}
  @override
  void buzz(String from) {}
  @override
  void stopBuzz() {}
  @override
  bool get appVisible => true;
  @override
  String? get openConversation => null;
}
