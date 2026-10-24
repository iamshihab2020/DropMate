import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/trust.dart';
import '../platform/native.dart';
import '../platform/thumbs.dart';
import '../services/sources.dart';
import 'app.dart';
import 'files.dart';
import 'i18n.dart';

bool isMedia(String name) => const {'image', 'video'}.contains(kindOf(name));

class MediaItem {
  final String messageId;
  final String ref; // file:… or content:…
  final String name;
  const MediaItem(this.messageId, this.ref, this.name);
  bool get isVideo => kindOf(name) == 'video';
  String get heroTag => 'media|$messageId|$ref';
  String get path => ref.startsWith('file:') ? ref.substring(5) : ref;
}

/// Every photo and video in [personId]'s chat that is on this device, oldest first; opens on [tapped].
Future<void> openMediaViewer(BuildContext context, String personId, MediaItem tapped) async {
  final e = context.engine;
  final items = <MediaItem>[];
  for (final m in await e.repo.messages(personId)) {
    if (m.type != 'file' || m.body['state'] != 'done') continue;
    for (final (ref, rel) in await e.transfers.localFiles(m.id)) {
      if (isMedia(rel)) items.add(MediaItem(m.id, ref, rel));
    }
  }
  final i = items.indexWhere((x) => x.heroTag == tapped.heroTag);
  if (i < 0) items.add(tapped);
  if (!context.mounted) return;
  await Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, a, _) => FadeTransition(
        opacity: a,
        child: MediaViewer(items: items, initial: i < 0 ? items.length - 1 : i),
      ),
    ),
  );
}

/// Shell/MediaStore preview of one photo or video, fading in over a quiet placeholder.
class MediaThumb extends StatelessWidget {
  final MediaItem item;
  final BoxFit fit;
  final bool playBadge;
  const MediaThumb({super.key, required this.item, this.fit = BoxFit.cover, this.playBadge = true});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return FutureBuilder<ui.Image?>(
      future: thumbnail(item.ref),
      builder: (context, snap) {
        final img = snap.data;
        final Widget base = img != null
            ? RawImage(key: const ValueKey('img'), image: img, fit: fit, width: double.infinity, height: double.infinity)
            : Container(
                key: const ValueKey('ph'),
                color: s.surfaceContainerHigh,
                alignment: Alignment.center,
                child: snap.connectionState == ConnectionState.done
                    ? Icon(iconFor(item.name), color: s.onSurfaceVariant, size: 36)
                    : null,
              );
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(duration: const Duration(milliseconds: 220), child: base),
            if (item.isVideo && playBadge)
              Center(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
                  child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 30),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Aspect ratio of a single photo bubble, from its preview once it has loaded.
class MediaAspect extends StatelessWidget {
  final MediaItem item;
  final Widget child;
  const MediaAspect({super.key, required this.item, required this.child});

  @override
  Widget build(BuildContext context) => FutureBuilder<ui.Image?>(
    future: thumbnail(item.ref),
    builder: (_, snap) {
      final img = snap.data;
      final r = img == null ? 4 / 3 : (img.width / img.height).clamp(0.66, 1.6);
      return AspectRatio(aspectRatio: r, child: child);
    },
  );
}

class MediaViewer extends StatefulWidget {
  final List<MediaItem> items;
  final int initial;
  const MediaViewer({super.key, required this.items, required this.initial});

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> {
  late final _pages = PageController(initialPage: widget.initial);
  late int _i = widget.initial;
  bool _zoomed = false;

  void _go(int d) {
    final n = (_i + d).clamp(0, widget.items.length - 1);
    if (n != _i) _pages.animateToPage(n, duration: const Duration(milliseconds: 240), curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_i];
    final many = widget.items.length > 1;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              PageView.builder(
                controller: _pages,
                physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
                itemCount: widget.items.length,
                onPageChanged: (i) => setState(() {
                  _i = i;
                  _zoomed = false;
                }),
                itemBuilder: (_, i) => _Page(
                  item: widget.items[i],
                  onZoom: (z) {
                    if (z != _zoomed) setState(() => _zoomed = z);
                  },
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xAA000000), Color(0x00000000)],
                    ),
                  ),
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 8, 20),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: tr('Close'),
                            color: Colors.white,
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => Navigator.pop(context),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.name.split('/').last,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                                ),
                                if (many)
                                  Text(
                                    tr('{n} of {total}', {'n': _i + 1, 'total': widget.items.length}),
                                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                                  ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: tr('Open'),
                            color: Colors.white,
                            icon: const Icon(Icons.open_in_new_rounded),
                            onPressed: () => openPath(item.path),
                          ),
                          IconButton(
                            tooltip: Platform.isAndroid ? tr('Share') : tr('Show in folder'),
                            color: Colors.white,
                            icon: Icon(Platform.isAndroid ? Icons.share_rounded : Icons.folder_open_rounded),
                            onPressed: () => showInFolder(item.path),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // Desktop has no swipe; arrows sit at the edges.
              if (many && !Platform.isAndroid) ...[
                if (_i > 0)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _Arrow(icon: Icons.chevron_left_rounded, onTap: () => _go(-1), tip: tr('Previous')),
                  ),
                if (_i < widget.items.length - 1)
                  Align(
                    alignment: Alignment.centerRight,
                    child: _Arrow(icon: Icons.chevron_right_rounded, onTap: () => _go(1), tip: tr('Next')),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tip;
  const _Arrow({required this.icon, required this.onTap, required this.tip});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: IconButton.filled(
      tooltip: tip,
      style: IconButton.styleFrom(backgroundColor: const Color(0x66000000), minimumSize: const Size(52, 52)),
      color: Colors.white,
      icon: Icon(icon, size: 32),
      onPressed: onTap,
    ),
  );
}

class _Page extends StatefulWidget {
  final MediaItem item;
  final ValueChanged<bool> onZoom;
  const _Page({required this.item, required this.onZoom});

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  final _zoom = TransformationController();
  Future<Uint8List?>? _bytes; // content: URIs (Android sender side) can't be opened as files

  @override
  void initState() {
    super.initState();
    _zoom.addListener(() => widget.onZoom(_zoom.value.getMaxScaleOnAxis() > 1.01));
    final it = widget.item;
    if (!it.isVideo && !it.ref.startsWith('file:')) _bytes = _read(it);
  }

  static Future<Uint8List?> _read(MediaItem it) async {
    final Source? s = await Native.resolveRef(it.ref, it.name);
    if (s == null || s.size > 80 << 20) return null;
    try {
      return await s.read(0, s.size);
    } finally {
      await s.close();
    }
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final thumb = MediaThumb(item: it, fit: BoxFit.contain, playBadge: false);
    if (it.isVideo) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Hero(tag: it.heroTag, child: thumb),
          Center(
            child: IconButton.filled(
              tooltip: tr('Play'),
              iconSize: 44,
              style: IconButton.styleFrom(backgroundColor: const Color(0x99000000), minimumSize: const Size(84, 84)),
              color: Colors.white,
              icon: const Icon(Icons.play_arrow_rounded),
              onPressed: () => openPath(it.path),
            ),
          ),
        ],
      );
    }
    Widget full(ImageProvider p) => Image(
      image: p,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      frameBuilder: (_, child, frame, sync) => frame == null && !sync ? thumb : child,
      errorBuilder: (_, _, _) => thumb,
    );
    final image = it.ref.startsWith('file:')
        ? full(FileImage(File(it.path)))
        : FutureBuilder(
            future: _bytes,
            builder: (_, s) => s.data == null ? thumb : full(MemoryImage(s.data!)),
          );
    return InteractiveViewer(
      transformationController: _zoom,
      maxScale: 5,
      child: SizedBox.expand(child: Hero(tag: it.heroTag, child: image)),
    );
  }
}
