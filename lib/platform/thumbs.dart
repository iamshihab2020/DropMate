import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as w;

import 'native.dart';

final _cache = <String, Future<ui.Image?>>{};

/// A preview of a photo or video about [px] on its long side, or null when the platform can't make one.
/// Android: MediaStore/ThumbnailUtils. Windows: the same shell thumbnails Explorer shows.
Future<ui.Image?> thumbnail(String ref, {int px = 720}) {
  final key = '$px|$ref';
  final hit = _cache.remove(key);
  if (hit != null) return _cache[key] = hit; // re-insert so eviction drops the least recently used
  if (_cache.length >= 80) _cache.remove(_cache.keys.first);
  return _cache[key] = _load(ref, px).catchError((_) => null);
}

Future<ui.Image?> _load(String ref, int px) async {
  if (Platform.isAndroid) {
    final jpg = await Native.thumb(ref, px);
    if (jpg == null) return null;
    return (await (await ui.instantiateImageCodec(jpg)).getNextFrame()).image;
  }
  if (Platform.isWindows && ref.startsWith('file:')) {
    final path = ref.substring(5);
    final r = await Isolate.run(() => _shellThumb(path, px));
    if (r == null) return null;
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(r.$3, r.$1, r.$2, ui.PixelFormat.bgra8888, c.complete);
    return c.future;
  }
  return null;
}

/// IShellItemImageFactory → HBITMAP → top-down BGRA. Runs in its own isolate (and COM apartment) to keep the UI smooth.
(int, int, Uint8List)? _shellThumb(String path, int side) {
  w.CoInitializeEx(nullptr, w.COINIT_APARTMENTTHREADED);
  final name = path.toNativeUtf16();
  final riid = w.GUIDFromString(w.IID_IShellItemImageFactory);
  final ppv = calloc<w.COMObject>();
  final size = calloc<w.SIZE>()
    ..ref.cx = side
    ..ref.cy = side;
  final hbm = calloc<IntPtr>();
  final bm = calloc<w.BITMAP>();
  final info = calloc<w.BITMAPINFO>();
  try {
    if (w.SHCreateItemFromParsingName(name, nullptr, riid, ppv.cast()) != w.S_OK) return null;
    final f = w.IShellItemImageFactory(ppv);
    try {
      if (f.getImage(size.ref, w.SIIGBF_THUMBNAILONLY | w.SIIGBF_BIGGERSIZEOK, hbm) != w.S_OK) return null;
    } finally {
      f.release();
    }
    try {
      w.GetObject(hbm.value, sizeOf<w.BITMAP>(), bm);
      final width = bm.ref.bmWidth, height = bm.ref.bmHeight;
      if (width <= 0 || height <= 0) return null;
      info.ref.bmiHeader
        ..biSize = sizeOf<w.BITMAPINFOHEADER>()
        ..biWidth = width
        ..biHeight = -height // negative: rows top to bottom
        ..biPlanes = 1
        ..biBitCount = 32
        ..biCompression = w.BI_RGB;
      final buf = calloc<Uint8>(width * height * 4);
      try {
        final dc = w.GetDC(0);
        final lines = w.GetDIBits(dc, hbm.value, 0, height, buf, info, w.DIB_RGB_COLORS);
        w.ReleaseDC(0, dc);
        if (lines == 0) return null;
        final pixels = Uint8List.fromList(buf.asTypedList(width * height * 4));
        // Opaque photos often come back with every alpha byte 0; treat that as fully opaque.
        var hasAlpha = false;
        for (var i = 3; i < pixels.length && !hasAlpha; i += 4) {
          hasAlpha = pixels[i] != 0;
        }
        if (!hasAlpha) {
          for (var i = 3; i < pixels.length; i += 4) {
            pixels[i] = 255;
          }
        }
        return (width, height, pixels);
      } finally {
        calloc.free(buf);
      }
    } finally {
      w.DeleteObject(hbm.value);
    }
  } finally {
    for (final p in <Pointer>[name, riid, ppv, size, hbm, bm, info]) {
      calloc.free(p);
    }
    w.CoUninitialize();
  }
}
