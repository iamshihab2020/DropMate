import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/sanitize.dart';
import '../platform/clipboard_win.dart';
import '../core/trust.dart';
import '../data/repo.dart';
import '../services/engine.dart';
import '../services/sources.dart';
import '../services/transfers.dart';
import 'app.dart';
import 'i18n.dart';
import 'files.dart';
import 'home.dart';
import 'media.dart';
import 'person.dart';
import 'theme.dart';

class ChatScreen extends StatefulWidget {
  final String personId;
  final List<Source>? initialFiles;
  final bool embedded; // right pane of the wide layout: no back button, no hero
  const ChatScreen({super.key, required this.personId, this.initialFiles, this.embedded = false});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  bool _dragging = false;
  String? _toDevice; // Me chat: which of my devices

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final s = Scope.of(context);
      s.host.openConversation = widget.personId;
      s.engine.markRead(widget.personId);
      if (widget.initialFiles != null) _send(widget.initialFiles!);
    });
  }

  @override
  void deactivate() {
    final s = Scope.of(context);
    if (s.host.openConversation == widget.personId) s.host.openConversation = null;
    super.deactivate();
  }

  bool get _isMe => context.engine.me.id == widget.personId;

  Future<void> _send(List<Source> files) async {
    if (files.isEmpty) return;
    final e = context.engine;
    if (_isMe) {
      final target = _toDevice ?? (await e.onlineDevices(e.me.id)).firstOrNull?.id;
      if (target == null) {
        _snack(tr('None of your other devices are online.'));
        return;
      }
      await e.transfers.send(e.me.id, files, toDevice: target);
    } else {
      await e.transfers.send(widget.personId, files);
    }
  }

  void _snack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _sendText() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _text.clear();
    await context.engine.sendText(widget.personId, t);
  }

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([e, e.transfers]),
      builder: (context, _) {
        final person = _isMe ? e.me : e.contacts.where((c) => c.id == widget.personId).firstOrNull;
        if (person == null) {
          return Scaffold(
            appBar: AppBar(automaticallyImplyLeading: !widget.embedded),
            body: Center(child: Text(tr('This person was unpaired.'))),
          );
        }
        final name = _isMe ? tr('My devices') : person.displayName;
        final body = Column(
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              child: person.trust.state == TrustState.proposedByThem
                  ? _TrustInvite(person: person)
                  : const SizedBox(width: double.infinity),
            ),
            Expanded(child: _Timeline(person: person)),
            _Composer(
              controller: _text,
              onSend: _sendText,
              onFiles: () async => _send(await pickFiles()),
              onMedia: () async => _send(await pickMedia()),
              onFolder: () async => _send(await pickFolder()),
              onPastePaths: (paths) => _send([for (final p in paths) ...FileSource.expand(p)]),
              meTarget: _isMe ? _MeTarget(value: _toDevice, onChanged: (v) => setState(() => _toDevice = v)) : null,
            ),
          ],
        );
        final avatar = _isMe
            ? Icon(Icons.devices_rounded, color: t.colorScheme.primary, size: 30)
            : Avatar(
                id: person.id,
                name: person.name,
                photo: person.roster.avatar,
                online: e.personOnline(person.id),
                size: 42,
              );
        return Scaffold(
          backgroundColor: t.colorScheme.surfaceContainerLowest,
          appBar: AppBar(
            automaticallyImplyLeading: !widget.embedded,
            backgroundColor: t.colorScheme.surfaceContainerLowest,
            toolbarHeight: 68,
            titleSpacing: widget.embedded ? 20 : 0,
            shape: Border(bottom: BorderSide(color: t.colorScheme.outlineVariant)),
            title: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _isMe
                  ? null
                  : () => Navigator.push(context, MaterialPageRoute(builder: (_) => PersonScreen(personId: person.id))),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    widget.embedded || _isMe ? avatar : Hero(tag: 'avatar-${person.id}', child: avatar),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleLarge),
                          _Presence(person: person),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              if (e.personOnline(person.id)) _BuzzButton(personId: person.id, name: name),
              if (person.trust.state == TrustState.active)
                Tooltip(
                  message: tr('Auto-accept on'),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.bolt_rounded, color: t.colorScheme.secondary),
                  ),
                ),
              if (!_isMe)
                IconButton(
                  tooltip: tr('Details'),
                  icon: const Icon(Icons.more_horiz_rounded),
                  onPressed: () =>
                      Navigator.push(context, MaterialPageRoute(builder: (_) => PersonScreen(personId: person.id))),
                ),
              const SizedBox(width: 8),
            ],
          ),
          body: Platform.isWindows
              ? DropTarget(
                  onDragEntered: (_) => setState(() => _dragging = true),
                  onDragExited: (_) => setState(() => _dragging = false),
                  onDragDone: (d) {
                    setState(() => _dragging = false);
                    _send([for (final f in d.files) ...FileSource.expand(f.path)]);
                  },
                  child: Stack(
                    children: [
                      body,
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            opacity: _dragging ? 1 : 0,
                            duration: const Duration(milliseconds: 160),
                            child: _DropOverlay(name: name),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : body,
        );
      },
    );
  }
}

class _DropOverlay extends StatelessWidget {
  final String name;
  const _DropOverlay({required this.name});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      margin: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerLowest.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: t.colorScheme.primary, width: 2.5),
      ),
      alignment: Alignment.center,
      child: LiquidFill(
        value: 0.35,
        radius: BorderRadius.circular(26),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.water_drop_rounded, size: 56, color: t.colorScheme.primary),
              const SizedBox(height: 12),
              Text(tr('Drop to send to {name}', {'name': name}), style: t.textTheme.headlineMedium),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rings their phone even on silent ("find my phone" in the My devices chat). The icon shakes as it goes.
class _BuzzButton extends StatefulWidget {
  final String personId;
  final String name;
  const _BuzzButton({required this.personId, required this.name});

  @override
  State<_BuzzButton> createState() => _BuzzButtonState();
}

class _BuzzButtonState extends State<_BuzzButton> with SingleTickerProviderStateMixin {
  late final _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  Future<void> _buzz() async {
    final e = context.engine;
    final m = ScaffoldMessenger.of(context);
    if (!reducedMotion(context)) _shake.forward(from: 0);
    final n = await e.buzz(widget.personId);
    m.hideCurrentSnackBar();
    m.showSnackBar(
      SnackBar(
        content: Text(
          n == 0
              ? tr('Couldn\'t reach {name}.', {'name': widget.name})
              : tr('Buzzing {name} for 30 seconds…', {'name': widget.name}),
        ),
        duration: const Duration(seconds: 30),
        action: n == 0 ? null : SnackBarAction(label: tr('Stop'), onPressed: () => e.buzz(widget.personId, stop: true)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: context.engine.me.id == widget.personId ? tr('Ring my devices') : tr('Buzz {name}', {'name': widget.name}),
    onPressed: _buzz,
    icon: AnimatedBuilder(
      animation: _shake,
      builder: (_, child) => Transform.rotate(
        angle: _shake.isAnimating ? 0.35 * (1 - _shake.value) * math.sin(_shake.value * math.pi * 10) : 0,
        child: child,
      ),
      child: const Icon(Icons.vibration_rounded),
    ),
  );
}

/// Waiting → Received → Seen. Seen is the only one in colour.
class _Ticks extends StatelessWidget {
  final Message m;
  final bool onBlue; // inside my blue text bubble
  const _Ticks({required this.m, this.onBlue = false});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final received = m.type == 'file' ? m.body['state'] == 'done' : m.status == 'delivered';
    final (icon, label) = switch (m.status) {
      'read' => (Icons.done_all_rounded, tr('Seen')),
      _ when received => (Icons.done_all_rounded, tr('Received')),
      'queued' => (Icons.schedule_rounded, tr('Waiting')),
      _ => (Icons.done_rounded, tr('Sent')),
    };
    final seen = m.status == 'read';
    final color = onBlue
        ? (seen ? const Color(0xFF9AF7EA) : s.onPrimary.withValues(alpha: 0.8))
        : (seen ? const Color(0xFF00A592) : s.onSurfaceVariant);
    return Tooltip(
      message: label,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
        child: Icon(icon, key: ValueKey('$icon$seen'), size: 15, color: color, semanticLabel: label),
      ),
    );
  }
}

/// "1.2 GB in 38 s · 32 MB/s" for a finished transfer, or null if it predates timing.
String? speedLine(Map b, {bool withSize = true}) {
  final took = b['took_ms'] as int?, moved = b['moved'] as int?;
  if (took == null || moved == null || moved <= 0) return null;
  final time = took < 1000 ? tr('under 1 s') : _dur(Duration(milliseconds: took));
  final speed = '${formatBytes(moved * 1000 ~/ (took < 1 ? 1 : took))}/s';
  return withSize
      ? tr('{size} in {time} · {speed}', {'size': formatBytes(b['total'] as int? ?? moved), 'time': time, 'speed': speed})
      : '$time · $speed';
}

class _Presence extends StatelessWidget {
  final Person person;
  const _Presence({required this.person});

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    final t = Theme.of(context);
    return FutureBuilder(
      future: e.repo.devices(personId: person.id),
      builder: (context, snap) {
        final ds = (snap.data ?? const <Device>[]).where((d) => d.id != e.id.deviceId).toList();
        final on = ds.where((d) => e.deviceOnline(d.id)).map((d) => d.name).toList();
        final lastSeen = ds.map((d) => d.lastSeen ?? 0).fold(0, (a, b) => a > b ? a : b);
        final text = on.isNotEmpty
            ? tr('Online on {devices}', {'devices': on.join(', ')})
            : tr('Offline · last seen {ago}', {'ago': ago(lastSeen == 0 ? null : lastSeen)});
        return Text(
          text,
          style: t.textTheme.bodySmall?.copyWith(color: on.isNotEmpty ? const Color(0xFF00A592) : null),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}

class _MeTarget extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;
  const _MeTarget({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    final others = e.me.roster.devices.where((d) => d.id != e.id.deviceId).toList();
    if (others.length < 2) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      children: [
        ChoiceChip(
          label: Text(tr('Any online device')),
          selected: value == null,
          onSelected: (_) => onChanged(null),
        ),
        for (final d in others)
          ChoiceChip(
            avatar: Icon(d.platform == 'windows' ? Icons.laptop_rounded : Icons.smartphone_rounded, size: 16),
            label: Text(d.name),
            selected: value == d.id,
            onSelected: (_) => onChanged(d.id),
          ),
      ],
    );
  }
}

class _TrustInvite extends StatelessWidget {
  final Person person;
  const _TrustInvite({required this.person});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(
        color: t.colorScheme.secondary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(Icons.bolt_rounded, color: t.colorScheme.secondary),
          const SizedBox(width: 12),
          Expanded(child: Text(tr('{name} wants to skip approval for files between you.', {'name': person.name}))),
          TextButton(onPressed: () => context.engine.trustRevoke(person.id), child: Text(tr('Not now'))),
          FilledButton.tonal(
            onPressed: () async {
              final l = await pickLimits(context);
              if (l != null && context.mounted) await context.engine.trustAccept(person.id, l);
            },
            child: Text(tr('Agree')),
          ),
        ],
      ),
    );
  }
}

class _Timeline extends StatefulWidget {
  final Person person;
  const _Timeline({required this.person});

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  Set<String>? _seen; // ids already on screen; anything new rises in

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    final person = widget.person;
    final t = Theme.of(context);
    return FutureBuilder(
      future: e.repo.messages(person.id),
      builder: (context, snap) {
        final ms = snap.data ?? const <Message>[];
        if (snap.hasData) _seen ??= {for (final m in ms) m.id};
        if (snap.hasData && ms.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset('assets/icon.png', width: 72),
                  const SizedBox(height: 16),
                  Text(
                    e.me.id == person.id
                        ? tr('Send files between your own devices. They arrive without asking.')
                        : tr('Send {name} a file or a message.', {'name': person.name}),
                    textAlign: TextAlign.center,
                    style: t.textTheme.titleMedium,
                  ),
                  if (Platform.isWindows) ...[
                    const SizedBox(height: 6),
                    Text(tr('You can also drag files here.'), style: t.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          );
        }
        return ListView.builder(
          reverse: true,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          itemCount: ms.length,
          itemBuilder: (context, i) {
            final m = ms[ms.length - 1 - i];
            final prev = i + 1 < ms.length ? ms[ms.length - 2 - i] : null; // the message above
            final grouped = prev != null && prev.author == m.author && m.createdAt - prev.createdAt < 120000;
            final fresh = _seen != null && _seen!.add(m.id);
            final bubble = _Bubble(m: m, person: person, grouped: grouped);
            return fresh ? _RiseIn(mine: m.author == e.me.id, child: bubble) : bubble;
          },
        );
      },
    );
  }
}

/// New messages rise from the composer into place; history never animates (DESIGN.md "Motion").
class _RiseIn extends StatelessWidget {
  final bool mine;
  final Widget child;
  const _RiseIn({required this.mine, required this.child});

  @override
  Widget build(BuildContext context) {
    if (reducedMotion(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      builder: (_, v, c) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, (1 - v) * 28),
          child: Transform.scale(
            scale: 0.92 + 0.08 * v,
            alignment: mine ? Alignment.bottomRight : Alignment.bottomLeft,
            child: c,
          ),
        ),
      ),
      child: child,
    );
  }
}

class _Bubble extends StatelessWidget {
  final Message m;
  final Person person;
  final bool grouped; // same author as the message above, shortly before
  const _Bubble({required this.m, required this.person, required this.grouped});

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    final t = Theme.of(context);
    final s = t.colorScheme;
    if (m.type == 'system') {
      return Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          margin: const EdgeInsets.symmetric(vertical: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: s.surfaceContainerHigh, borderRadius: BorderRadius.circular(14)),
          child: Text(systemText(m.body, person.name), style: t.textTheme.bodySmall, textAlign: TextAlign.center),
        ),
      );
    }
    final mine = m.author == e.me.id && (m.row['origin_device'] == e.id.deviceId || person.id != e.me.id);
    final maxW = (MediaQuery.sizeOf(context).width >= wideBreakpoint ? 520.0 : MediaQuery.sizeOf(context).width * 0.8);
    final Widget content;
    if (m.type == 'file') {
      content = _FileCard(m: m, mine: mine, person: person);
    } else {
      const big = Radius.circular(22), small = Radius.circular(6);
      content = Container(
        padding: const EdgeInsets.fromLTRB(14, 9, 12, 7),
        decoration: BoxDecoration(
          color: mine ? Brand.drop : s.surfaceContainer, // fixed shade keeps white text at 4.5:1 in both themes
          border: mine ? null : Border.all(color: s.outlineVariant),
          borderRadius: BorderRadius.only(
            topLeft: mine || !grouped ? big : small,
            topRight: !mine || !grouped ? big : small,
            bottomLeft: mine ? big : small,
            bottomRight: mine ? small : big,
          ),
        ),
        child: Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: 10,
          children: [
            SelectableText(
              '${m.body['text']}',
              style: t.textTheme.bodyLarge?.copyWith(color: mine ? s.onPrimary : s.onSurface),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 1),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    clock(m.createdAt),
                    style: t.textTheme.labelSmall?.copyWith(
                      color: mine ? s.onPrimary.withValues(alpha: 0.75) : s.onSurfaceVariant,
                    ),
                  ),
                  if (mine && person.id != e.me.id) ...[const SizedBox(width: 3), _Ticks(m: m, onBlue: true)],
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _menu(context),
        onSecondaryTap: () => _menu(context),
        child: Padding(
          padding: EdgeInsets.only(top: grouped ? 2 : 10),
          child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxW), child: content),
        ),
      ),
    );
  }

  void _menu(BuildContext context) {
    final e = context.engine;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (m.type == 'text')
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: Text(tr('Copy')),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: '${m.body['text']}'));
                  Navigator.pop(context);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: Text(tr('Delete for me')),
              onTap: () {
                e.deleteForMe(m.id);
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// A file message: the card fills with water while bytes move (DESIGN.md signature).
class _FileCard extends StatelessWidget {
  final Message m;
  final bool mine;
  final Person person;
  const _FileCard({required this.m, required this.mine, required this.person});

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    final b = m.body;
    final files = (b['files'] as List).cast<Map>();
    final state = b['state'] as String? ?? 'requesting';
    final total = b['total'] as int? ?? 0;
    final prog = e.transfers.progress[m.id];
    final title = files.length == 1 ? '${files.first['name']}'.split('/').last : '${files.length} files';
    final first = '${files.first['name']}';
    final folderName = first.contains('/') && files.length > 1 ? first.split('/').first : null;
    final moving = prog != null && state == 'transferring';
    final level = switch (state) {
      'done' => 1.0,
      'transferring' || 'paused' => prog == null || prog.total == 0 ? null : prog.done / prog.total,
      _ => 0.0,
    };
    final bad = _bad(state);
    final radius = BorderRadius.circular(22);
    final card = _card(context, files, state, total, prog, title, first, folderName, moving, level, bad, radius);
    if (state != 'done' || !files.every((f) => isMedia('${f['name']}'))) return card;
    // Finished photos and videos show as pictures; the water card stays for files kept on another device.
    return FutureBuilder(
      future: e.transfers.localFiles(m.id),
      builder: (context, snap) {
        final local = [
          for (final (ref, rel) in snap.data ?? const <(String, String)>[])
            if (isMedia(rel)) MediaItem(m.id, ref, rel),
        ];
        if (snap.data == null) return const SizedBox(width: 280, height: 210);
        if (local.isEmpty) return card;
        return _MediaCard(m: m, items: local, mine: mine, person: person);
      },
    );
  }

  Widget _card(
    BuildContext context,
    List<Map> files,
    String state,
    int total,
    Progress? prog,
    String title,
    String first,
    String? folderName,
    bool moving,
    double? level,
    bool bad,
    BorderRadius radius,
  ) {
    final e = context.engine;
    final t = Theme.of(context);
    final s = t.colorScheme;
    final b = m.body;
    return SizedBox(
      width: 320,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: s.surfaceContainer,
          borderRadius: radius,
          border: Border.all(color: mine ? s.primary.withValues(alpha: 0.45) : s.outlineVariant, width: 1.2),
        ),
        child: LiquidFill(
          value: state == 'done' ? 0 : level, // the water drains away once it's safely saved
          radius: radius,
          color: bad ? s.error : Brand.lagoon,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _FileIcon(icon: folderName != null ? Icons.folder_rounded : iconFor(first), state: state),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(folderName ?? title, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall),
                          const SizedBox(height: 2),
                          Text(
                            '${formatBytes(total)}${files.length > 1 ? ' · ${files.length} files' : ''}${isExecutable(first) ? ' · app' : ''}',
                            style: t.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (moving)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          '${prog!.total == 0 ? 0 : prog.done * 100 ~/ prog.total}%',
                          style: display(24).copyWith(color: s.primary),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    key: ValueKey(moving ? 'moving' : state),
                    moving
                        ? '${formatBytes(prog!.speed.round())}/s${prog.eta == null ? '' : ' · ${tr('{time} left', {'time': _dur(prog.eta!)})}'}'
                        : _label(state, b, e),
                    style: t.textTheme.bodySmall?.copyWith(
                      color: bad ? s.error : (state == 'done' ? const Color(0xFF00A592) : null),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(child: _Actions(m: m, mine: mine, state: state, person: person)),
                    Text(clock(m.createdAt), style: t.textTheme.labelSmall?.copyWith(color: s.onSurfaceVariant)),
                    if (mine && person.id != e.me.id) ...[const SizedBox(width: 3), _Ticks(m: m)],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _bad(String s) => const {'failed', 'declined', 'no_response', 'canceled', 'missed'}.contains(s);

  String _label(String s, Map b, Engine e) {
    final name = person.id == e.me.id ? 'your device' : person.name;
    final on = b['stored_on_name'] as String?;
    final speed = s == 'done' ? speedLine(b, withSize: false) : null;
    final base = _state(s, b, e, name, on);
    return speed == null ? base : '$base · $speed';
  }

  String _state(String s, Map b, Engine e, String name, String? on) {
    return switch (s) {
      'queued' => mine ? tr('Waiting for {name} to come online', {'name': name}) : tr('Waiting'),
      'requesting' => mine ? tr('Waiting for {name} to accept', {'name': name}) : tr('Waiting for you'),
      'transferring' => tr('Starting…'),
      'paused' => b['reason'] == 'user' ? tr('Paused') : tr('Paused, waiting for connection'),
      'done' =>
        mine
            ? (on != null && person.id != e.me.id ? tr('Sent to {device}', {'device': on}) : tr('Sent'))
            : (on != null ? tr('Received on {device}', {'device': on}) : tr('Received')),
      'declined' => mine ? tr('Declined') : tr('You declined'),
      'no_response' => tr('No response'),
      'missed' => tr('Missed — you didn\'t answer in time'),
      'taken' => tr('Accepted on {device}', {'device': b['taken_by'] ?? '…'}),
      'failed' => '${tr('Failed')}${b['error'] != null ? ': ${b['error']}' : ''}',
      'canceled' => tr('Canceled'),
      _ => s,
    };
  }
}

/// Finished photos/videos: the pictures themselves, tap to open the swipeable viewer.
class _MediaCard extends StatelessWidget {
  final Message m;
  final List<MediaItem> items;
  final bool mine;
  final Person person;
  const _MediaCard({required this.m, required this.items, required this.mine, required this.person});

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    final t = Theme.of(context);
    final width = math.min(300.0, MediaQuery.sizeOf(context).width * 0.72);
    Widget tile(int i, {String? more}) => Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => openMediaViewer(context, person.id, items[i]),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Hero(tag: items[i].heroTag, child: MediaThumb(item: items[i])),
            if (more != null)
              Container(
                color: const Color(0x88000000),
                alignment: Alignment.center,
                child: Text(more, style: display(28).copyWith(color: Colors.white)),
              ),
          ],
        ),
      ),
    );
    final n = items.length;
    final Widget grid = switch (n) {
      1 => MediaAspect(item: items.first, child: tile(0)),
      2 || 3 => AspectRatio(
        aspectRatio: n.toDouble(),
        child: Row(
          children: [
            for (var i = 0; i < n; i++) ...[if (i > 0) const SizedBox(width: 3), Expanded(child: tile(i))],
          ],
        ),
      ),
      _ => AspectRatio(
        aspectRatio: 1,
        child: Column(
          children: [
            for (final row in [0, 2]) ...[
              if (row > 0) const SizedBox(height: 3),
              Expanded(
                child: Row(
                  children: [
                    Expanded(child: tile(row)),
                    const SizedBox(width: 3),
                    Expanded(child: tile(row + 1, more: row == 2 && n > 4 ? '+${n - 4}' : null)),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    };
    final speed = speedLine(m.body);
    return Column(
      crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: width,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Stack(
              children: [
                grid,
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: const Color(0x8C000000), borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(clock(m.createdAt), style: t.textTheme.labelSmall?.copyWith(color: Colors.white)),
                        if (mine && person.id != e.me.id) ...[
                          const SizedBox(width: 3),
                          _Ticks(m: m, onBlue: true),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (speed != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
            child: Text(speed, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
      ],
    );
  }
}

/// File-type tile; a check pops in when the transfer completes.
class _FileIcon extends StatelessWidget {
  final IconData icon;
  final String state;
  const _FileIcon({required this.icon, required this.state});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final done = state == 'done';
    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            decoration: BoxDecoration(color: s.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
            child: Center(child: Icon(icon, color: s.primary, size: 26)),
          ),
          if (done)
            Positioned(
              right: -5,
              bottom: -5,
              child: PopIn(
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(color: s.surfaceContainer, shape: BoxShape.circle),
                  child: const Icon(Icons.check_circle_rounded, size: 20, color: Color(0xFF00B39E)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _dur(Duration d) => d.inHours > 0
    ? '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')} h'
    : d.inMinutes > 0
    ? '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}'
    : '${d.inSeconds} s';

class _Actions extends StatelessWidget {
  final Message m;
  final bool mine;
  final String state;
  final Person person;
  const _Actions({required this.m, required this.mine, required this.state, required this.person});

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    final tx = e.transfers;
    Widget btn(String label, VoidCallback f, {IconData? icon}) => TextButton.icon(
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      onPressed: f,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
    final buttons = <Widget>[];
    switch (state) {
      case 'queued' || 'requesting':
        if (mine) buttons.add(btn(tr('Cancel'), () => tx.cancel(m.id), icon: Icons.close_rounded));
      case 'transferring':
        if (mine) buttons.add(btn(tr('Pause'), () => tx.pause(m.id), icon: Icons.pause_rounded));
        buttons.add(btn(tr('Cancel'), () => tx.cancel(m.id), icon: Icons.close_rounded));
      case 'paused':
        if (mine) buttons.add(btn(tr('Resume'), () => tx.resume(m.id), icon: Icons.play_arrow_rounded));
        buttons.add(btn(tr('Cancel'), () => tx.cancel(m.id), icon: Icons.close_rounded));
      case 'declined' || 'no_response' || 'failed' || 'canceled':
        if (mine) buttons.add(btn(tr('Send again'), () => tx.resume(m.id), icon: Icons.refresh_rounded));
      case 'missed':
        if (!mine) {
          buttons.add(
            btn(tr('Ask to resend'), () {
              final f = (m.body['files'] as List).first['name'];
              e.sendText(person.id, 'Can you send ${'$f'.split('/').last} again?');
            }, icon: Icons.reply_rounded),
          );
        }
    }
    if (state == 'done' || mine) {
      return FutureBuilder(
        future: tx.localFiles(m.id),
        builder: (context, snap) {
          final local = snap.data ?? const [];
          final extra = <Widget>[];
          final path = local.isEmpty ? null : local.first.$1;
          if (path != null && path.startsWith('file:') && state == 'done') {
            final p = path.substring(5);
            extra.add(
              btn(tr('Open'), () => openPath(local.length == 1 ? p : File(p).parent.path), icon: Icons.open_in_new_rounded),
            );
            extra.add(
              btn(
                Platform.isAndroid ? tr('Share') : tr('Show in folder'),
                () => showInFolder(p),
                icon: Platform.isAndroid ? Icons.share_rounded : Icons.folder_open_rounded,
              ),
            );
          } else if (state == 'done' && local.isEmpty && !mine) {
            final holder = m.body['stored_on'] as String?;
            if (holder != null && holder != e.id.deviceId && e.isOwnDevice(holder)) {
              extra.add(
                btn(
                  e.deviceOnline(holder)
                      ? tr('Fetch to this device')
                      : 'On ${m.body['stored_on_name'] ?? 'another device'}',
                  e.deviceOnline(holder) ? () => tx.fetch(m.id, holder) : () {},
                  icon: Icons.download_rounded,
                ),
              );
            }
          }
          final all = [...buttons, ...extra];
          return all.isEmpty ? const SizedBox(height: 36) : Wrap(children: all);
        },
      );
    }
    return buttons.isEmpty ? const SizedBox(height: 36) : Wrap(children: buttons);
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onFiles;
  final VoidCallback onMedia;
  final VoidCallback onFolder;
  final void Function(List<String> paths) onPastePaths;
  final Widget? meTarget;
  const _Composer({
    required this.controller,
    required this.onSend,
    required this.onFiles,
    required this.onMedia,
    required this.onFolder,
    required this.onPastePaths,
    this.meTarget,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: s.surfaceContainerLowest,
        border: Border(top: BorderSide(color: s.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (meTarget != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(padding: const EdgeInsets.only(bottom: 6, left: 4), child: meTarget!),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _AttachButton(onFiles: onFiles, onFolder: onFolder),
                  IconButton(
                    tooltip: tr('Photos & videos'),
                    style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: onMedia,
                    icon: Icon(Icons.photo_library_rounded, color: s.primary),
                  ),
                  Expanded(
                    child: Focus(
                      onKeyEvent: (_, ev) {
                        if (ev is! KeyDownEvent) return KeyEventResult.ignored;
                        final k = HardwareKeyboard.instance;
                        if (ev.logicalKey == LogicalKeyboardKey.enter && !k.isShiftPressed) {
                          onSend();
                          return KeyEventResult.handled;
                        }
                        // Ctrl+V with files or an image on the clipboard sends them; text pastes as usual.
                        if (Platform.isWindows && k.isControlPressed && ev.logicalKey == LogicalKeyboardKey.keyV) {
                          final paths = clipboardFiles();
                          if (paths.isNotEmpty) {
                            onPastePaths(paths);
                            return KeyEventResult.handled;
                          }
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: controller,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => onSend(),
                        decoration: InputDecoration(
                          hintText: tr('Message'),
                          fillColor: s.surfaceContainer,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide(color: s.primary.withValues(alpha: 0.6), width: 1.5),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ListenableBuilder(
                    listenable: controller,
                    builder: (_, _) {
                      final ready = controller.text.trim().isNotEmpty;
                      return AnimatedScale(
                        scale: ready ? 1 : 0.86,
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutBack,
                        child: IconButton.filled(
                          tooltip: tr('Send'),
                          onPressed: ready ? onSend : null,
                          style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                          icon: const Icon(Icons.arrow_upward_rounded),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttachButton extends StatelessWidget {
  final VoidCallback onFiles;
  final VoidCallback onFolder;
  const _AttachButton({required this.onFiles, required this.onFolder});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return MenuAnchor(
      builder: (context, c, _) => IconButton.filledTonal(
        tooltip: tr('Attach'),
        style: IconButton.styleFrom(minimumSize: const Size(48, 48), backgroundColor: s.primary.withValues(alpha: 0.12)),
        onPressed: () => c.isOpen ? c.close() : c.open(),
        icon: Icon(Icons.add_rounded, color: s.primary),
      ),
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.insert_drive_file_outlined),
          onPressed: onFiles,
          child: Text(tr('Files')),
        ),
        MenuItemButton(leadingIcon: const Icon(Icons.folder_outlined), onPressed: onFolder, child: Text(tr('Folder'))),
      ],
    );
  }
}

/// Auto-accept limits picker, used when proposing or agreeing.
Future<Limits?> pickLimits(BuildContext context) {
  final sizes = {'100 MB': 100 << 20, '1 GB': 1 << 30, '5 GB': 5 << 30, '20 GB': 20 << 30, tr('No limit'): 1 << 50};
  var max = 5 << 30;
  return showDialog<Limits>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text(tr('Skip approval')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Files you receive up to this size arrive without asking. Apps and scripts always ask.')),
            const SizedBox(height: 12),
            for (final s in sizes.entries)
              RadioListTile<int>(
                contentPadding: EdgeInsets.zero,
                title: Text(s.key),
                value: s.value,
                groupValue: max,
                onChanged: (v) => set(() => max = v!),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('Cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(c, Limits(maxBytes: max)),
            child: Text(tr('OK')),
          ),
        ],
      ),
    ),
  );
}
