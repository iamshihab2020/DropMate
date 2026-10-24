import 'dart:io';
import 'dart:typed_data';

/// Something we can send: a file path (Windows, Android app storage) or an Android content URI.
abstract class Source {
  String get relPath; // "movie.mp4" or "Folder/sub/a.jpg"
  int get size;
  String? get mime;
  int get mtime;
  String get ref; // persisted so a transfer can resume after restart
  Future<Uint8List> read(int offset, int length);
  Future<void> close();
}

class FileSource implements Source {
  final File file;
  @override
  final String relPath;
  @override
  final int size;
  @override
  final int mtime;
  RandomAccessFile? _raf;

  FileSource(this.file, this.relPath)
    : size = file.lengthSync(),
      mtime = file.lastModifiedSync().millisecondsSinceEpoch;

  @override
  String? get mime => null;
  @override
  String get ref => 'file:${file.path}';

  @override
  Future<Uint8List> read(int offset, int length) async {
    final raf = _raf ??= await file.open();
    await raf.setPosition(offset);
    return raf.read(length);
  }

  @override
  Future<void> close() async {
    await _raf?.close();
    _raf = null;
  }

  /// Expands a folder into its files, keeping paths relative to the folder's parent (PRD F9).
  static List<FileSource> expand(String path) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.file) return [FileSource(File(path), path.split(RegExp(r'[/\\]')).last)];
    if (type != FileSystemEntityType.directory) return [];
    final root = Directory(path);
    final parent = root.parent.path;
    return [
      for (final f in root.listSync(recursive: true, followLinks: false).whereType<File>())
        FileSource(f, f.path.substring(parent.length + 1).replaceAll('\\', '/')),
    ];
  }
}

/// Resolves a persisted [Source.ref] after restart; content URIs are handled by the Android host.
typedef SourceResolver = Future<Source?> Function(String ref, String relPath);

Future<Source?> resolveFileRef(String ref, String relPath) async {
  if (!ref.startsWith('file:')) return null;
  final f = File(ref.substring(5));
  return f.existsSync() ? FileSource(f, relPath) : null;
}
