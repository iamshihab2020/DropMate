import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/crypto.dart';
import '../core/sanitize.dart';
import '../core/trust.dart';
import '../platform/native.dart';
import '../services/sources.dart';
import 'i18n.dart';

Future<List<Source>> pickFiles() async {
  if (Platform.isAndroid) return Native.pickFiles();
  final r = await FilePicker.platform.pickFiles(allowMultiple: true, lockParentWindow: true);
  return [
    for (final f in r?.files ?? const <PlatformFile>[])
      if (f.path != null) ...FileSource.expand(f.path!),
  ];
}

/// Photos and videos: the phone's gallery picker, or a file dialog filtered to media on Windows.
Future<List<Source>> pickMedia() async {
  if (Platform.isAndroid) return Native.pickMedia();
  final r = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.media, lockParentWindow: true);
  return [
    for (final f in r?.files ?? const <PlatformFile>[])
      if (f.path != null) ...FileSource.expand(f.path!),
  ];
}

Future<List<Source>> pickFolder() async {
  if (Platform.isAndroid) return Native.pickFolder();
  final dir = await FilePicker.platform.getDirectoryPath(lockParentWindow: true);
  return dir == null ? const [] : FileSource.expand(dir);
}

const androidDownloads = '/storage/emulated/0/Download';

/// Windows: system folder picker. Android: a folder inside Downloads, because folders picked through the
/// system picker can't be written with file APIs (PRD §14.1).
Future<String?> pickDirectory(BuildContext context) async {
  if (!Platform.isAndroid) return FilePicker.platform.getDirectoryPath(lockParentWindow: true);
  final existing = <String>[];
  try {
    existing.addAll(
      Directory(androidDownloads)
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path.split('/').last)
          .where((n) => !n.startsWith('.')),
    );
  } catch (_) {}
  existing.sort();
  final name = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(tr('Save to')),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: InputDecoration(labelText: tr('New folder in Downloads')),
              onSubmitted: (v) =>
                  Navigator.pop(c, v.trim().isEmpty ? null : '$androidDownloads/${sanitizeSegment(v.trim())}'),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final n in existing)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(n),
                      onTap: () => Navigator.pop(c, '$androidDownloads/$n'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('Cancel'))),
        FilledButton(
          onPressed: () => Navigator.pop(
            c,
            name.text.trim().isEmpty ? null : '$androidDownloads/${sanitizeSegment(name.text.trim())}',
          ),
          child: Text(tr('Create')),
        ),
      ],
    ),
  );
}

Future<void> openPath(String path) async {
  if (Platform.isAndroid) return Native.openFile(path);
  await Process.run('explorer', [path]);
}

Future<void> showInFolder(String path) async {
  if (Platform.isAndroid) return Native.shareFile(path);
  await Process.run('explorer', ['/select,', path]);
}

IconData iconFor(String name) => switch (kindOf(name)) {
  'image' => Icons.image_outlined,
  'video' => Icons.movie_outlined,
  'audio' => Icons.music_note_outlined,
  'document' => Icons.description_outlined,
  'archive' => Icons.folder_zip_outlined,
  _ => Icons.insert_drive_file_outlined,
};

/// Picks an image, centre-crops it square and shrinks it to a 192 px PNG for the roster (b64url), or null.
Future<String?> pickPhoto() async {
  final files = await pickFiles();
  final img = files.where((f) => kindOf(f.relPath) == 'image' && f.size < 30 << 20).firstOrNull;
  if (img == null) return null;
  try {
    final bytes = await img.read(0, img.size);
    await img.close();
    final frame = await (await ui.instantiateImageCodec(bytes)).getNextFrame();
    final src = frame.image;
    final side = src.width < src.height ? src.width : src.height;
    const out = 192.0;
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawImageRect(
      src,
      ui.Rect.fromLTWH((src.width - side) / 2, (src.height - side) / 2, side.toDouble(), side.toDouble()),
      const ui.Rect.fromLTWH(0, 0, out, out),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final square = await rec.endRecording().toImage(out.toInt(), out.toInt());
    final png = await square.toByteData(format: ui.ImageByteFormat.png);
    return png == null ? null : b64(png.buffer.asUint8List());
  } catch (_) {
    return null;
  }
}
