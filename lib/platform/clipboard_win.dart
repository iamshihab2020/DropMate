import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

const _cfHdrop = 15;
const _cfDib = 8;

/// Files copied in Explorer, or a copied image saved to a temp .bmp. Empty when the clipboard holds neither.
/// Synchronous so the chat composer can decide whether to swallow Ctrl+V.
List<String> clipboardFiles() {
  if (!Platform.isWindows || OpenClipboard(NULL) == 0) return const [];
  try {
    if (IsClipboardFormatAvailable(_cfHdrop) != 0) {
      final h = GetClipboardData(_cfHdrop);
      if (h == 0) return const [];
      final count = DragQueryFile(h, 0xFFFFFFFF, nullptr, 0);
      final out = <String>[];
      for (var i = 0; i < count; i++) {
        final len = DragQueryFile(h, i, nullptr, 0) + 1;
        final buf = wsalloc(len);
        DragQueryFile(h, i, buf, len);
        out.add(buf.toDartString());
        free(buf);
      }
      return out;
    }
    if (IsClipboardFormatAvailable(_cfDib) != 0) {
      final h = GetClipboardData(_cfDib);
      final ptr = GlobalLock(Pointer.fromAddress(h));
      if (ptr == nullptr) return const [];
      try {
        final dib = Uint8List.fromList(ptr.cast<Uint8>().asTypedList(GlobalSize(Pointer.fromAddress(h))));
        final path = p.join(Directory.systemTemp.path, 'Pasted image ${DateTime.now().millisecondsSinceEpoch}.bmp');
        File(path).writeAsBytesSync(_bmp(dib));
        return [path];
      } finally {
        GlobalUnlock(Pointer.fromAddress(h));
      }
    }
    return const [];
  } finally {
    CloseClipboard();
  }
}

/// CF_DIB is a BMP without its 14-byte file header; add one.
Uint8List _bmp(Uint8List dib) {
  final d = ByteData.sublistView(dib);
  final headerSize = d.getUint32(0, Endian.little);
  final bitCount = d.getUint16(14, Endian.little);
  final compression = d.getUint32(16, Endian.little);
  var colors = d.getUint32(32, Endian.little);
  if (colors == 0 && bitCount <= 8) colors = 1 << bitCount;
  final masks = (compression == 3 && headerSize == 40) ? 12 : 0; // BI_BITFIELDS
  final offset = 14 + headerSize + masks + colors * 4;
  final out = ByteData(14 + dib.length)
    ..setUint8(0, 0x42)
    ..setUint8(1, 0x4D)
    ..setUint32(2, 14 + dib.length, Endian.little)
    ..setUint32(10, offset, Endian.little);
  final bytes = out.buffer.asUint8List();
  bytes.setRange(14, bytes.length, dib);
  return bytes;
}
