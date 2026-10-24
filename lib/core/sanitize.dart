import 'dart:io';

const _reserved = {
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};

final _bad = RegExp(r'[<>:"/\\|?*\x00-\x1f]');

/// Makes one path segment safe on Windows and Android (PRD §11.9).
String sanitizeSegment(String name) {
  var s = name.replaceAll(_bad, '_').trim();
  s = s.replaceAll(RegExp(r'[. ]+$'), '');
  if (s.isEmpty || s == '.' || s == '..') s = 'file';
  final stem = s.split('.').first.toUpperCase();
  if (_reserved.contains(stem)) s = '_$s';
  if (s.length > 200) {
    final dot = s.lastIndexOf('.');
    final ext = (dot > 0 && s.length - dot <= 16) ? s.substring(dot) : '';
    s = s.substring(0, 200 - ext.length) + ext;
  }
  return s;
}

/// Sanitizes a sender-supplied relative path ("a/b/c.txt"); drops `..` and empty parts.
List<String> sanitizeRelPath(String rel) =>
    rel.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty && p != '.' && p != '..').map(sanitizeSegment).toList();

/// Returns a path inside [dir] that does not exist yet: "name (1).ext", "name (2).ext"…
String uniquePath(String dir, String name) {
  final sep = Platform.pathSeparator;
  var candidate = '$dir$sep$name';
  if (!_exists(candidate)) return candidate;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var i = 1; ; i++) {
    candidate = '$dir$sep$stem ($i)$ext';
    if (!_exists(candidate)) return candidate;
  }
}

bool _exists(String p) => File(p).existsSync() || Directory(p).existsSync() || File('$p.dropmate-part').existsSync();

const executableExts = {'exe', 'msi', 'bat', 'cmd', 'ps1', 'apk', 'sh', 'com', 'scr', 'vbs', 'jar'};

bool isExecutable(String name) {
  final dot = name.lastIndexOf('.');
  return dot >= 0 && executableExts.contains(name.substring(dot + 1).toLowerCase());
}
