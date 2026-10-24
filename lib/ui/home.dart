import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../services/sources.dart';
import 'app.dart';
import 'i18n.dart';
import 'chat.dart';
import 'pair.dart';
import 'search.dart';
import 'settings.dart';
import 'theme.dart';

/// Wide windows show people and the open chat side by side (DESIGN.md "Layout").
const wideBreakpoint = 840.0;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _open; // wide layout: the chat in the right pane
  List<Source>? _dropped; // files dropped on a name, handed to that chat once
  int _drops = 0;

  void _openChat(BuildContext context, String personId, {List<Source>? files}) {
    if (MediaQuery.sizeOf(context).width >= wideBreakpoint) {
      setState(() {
        _open = personId;
        _dropped = files;
        if (files != null) _drops++; // a fresh chat state sends them
      });
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(personId: personId, initialFiles: files)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
    final people = _People(
      selected: wide ? _open : null,
      hero: !wide,
      onOpen: (id, {files}) => _openChat(context, id, files: files),
    );
    if (!wide) return Scaffold(body: people);
    final e = context.engine;
    final open = _open != null && (_open == e.me.id || e.contacts.any((c) => c.id == _open)) ? _open : null;
    return Scaffold(
      body: Row(
        children: [
          SizedBox(width: 340, child: people),
          const VerticalDivider(width: 1),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: open == null
                  ? const _Welcome(key: ValueKey('welcome'))
                  : ChatScreen(
                      key: ValueKey('$open/$_drops'),
                      personId: open,
                      embedded: true,
                      initialFiles: _dropped,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

typedef _Open = void Function(String personId, {List<Source>? files});

class _People extends StatelessWidget {
  final String? selected;
  final bool hero;
  final _Open onOpen;
  const _People({required this.selected, required this.hero, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([e, e.transfers]),
      builder: (context, _) {
        final here = e.contacts.where((c) => e.personOnline(c.id)).toList();
        final mine = e.me.roster.devices.where((d) => d.id != e.id.deviceId && e.deviceOnline(d.id)).toList();
        return CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              toolbarHeight: 64,
              titleSpacing: 20,
              title: const Wordmark(size: 22),
              actions: [
                IconButton(
                  tooltip: tr('Search'),
                  icon: const Icon(Icons.search_rounded),
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchScreen())),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12, left: 4),
                  child: Tooltip(
                    message: tr('Settings'),
                    child: InkResponse(
                      radius: 24,
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
                      child: Avatar(
                        id: e.me.id,
                        name: e.me.roster.name,
                        photo: e.me.roster.avatar,
                        online: true,
                        size: 38,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (e.isolationSuspected)
              SliverToBoxAdapter(
                child: _Notice(
                  icon: Icons.router_outlined,
                  text: tr(
                    'Your router may be blocking devices from talking to each other (client isolation). Try another Wi-Fi or turn off "AP isolation" in the router.',
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                child: Text(tr('Here now'), style: t.textTheme.headlineSmall),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 112,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  children: [
                    for (final c in here)
                      _HereBubble(
                        label: c.displayName,
                        avatar: Avatar(id: c.id, name: c.name, photo: c.roster.avatar, online: true, pulse: true, size: 62),
                        onTap: () => onOpen(c.id),
                        onDrop: (files) => onOpen(c.id, files: files),
                      ),
                    if (mine.isNotEmpty)
                      _HereBubble(
                        label: mine.length == 1 ? mine.first.name : tr('My devices'),
                        avatar: _DevicesFace(online: true, size: 62),
                        onTap: () => onOpen(e.me.id),
                        onDrop: null,
                      ),
                    _HereBubble(
                      label: tr('Add'),
                      avatar: _AddFace(size: 62),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PairScreen())),
                      onDrop: null,
                    ),
                    if (here.isEmpty && mine.isEmpty)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8, right: 20, bottom: 22),
                          child: SizedBox(
                            width: 200,
                            child: Text(
                              tr('No one else is on this Wi-Fi right now.'),
                              style: t.textTheme.bodySmall,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
                child: Text(tr('Chats'), style: t.textTheme.headlineSmall),
              ),
            ),
            SliverList.list(
              children: [
                _MeTile(selected: selected == e.me.id, onOpen: onOpen),
                for (final c in e.contacts)
                  _PersonTile(person: c, selected: selected == c.id, hero: hero, onOpen: onOpen),
                if (e.contacts.isEmpty) const _FirstPerson(),
                const SizedBox(height: 32),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// A file drop target on Windows; a plain child elsewhere.
class _DropZone extends StatefulWidget {
  final void Function(List<Source> files)? onDrop;
  final Widget Function(bool hovering) builder;
  const _DropZone({required this.onDrop, required this.builder});

  @override
  State<_DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<_DropZone> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows || widget.onDrop == null) return widget.builder(false);
    return DropTarget(
      onDragEntered: (_) => setState(() => _hover = true),
      onDragExited: (_) => setState(() => _hover = false),
      onDragDone: (d) {
        setState(() => _hover = false);
        widget.onDrop!([for (final f in d.files) ...FileSource.expand(f.path)]);
      },
      child: widget.builder(_hover),
    );
  }
}

class _HereBubble extends StatelessWidget {
  final String label;
  final Widget avatar;
  final VoidCallback onTap;
  final void Function(List<Source>)? onDrop;
  const _HereBubble({required this.label, required this.avatar, required this.onTap, required this.onDrop});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return _DropZone(
      onDrop: onDrop,
      builder: (hover) => AnimatedScale(
        scale: hover ? 1.12 : 1,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutBack,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(
            width: 84,
            child: Column(
              children: [
                const SizedBox(height: 6),
                avatar,
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.labelMedium,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DevicesFace extends StatelessWidget {
  final bool online;
  final double size;
  const _DevicesFace({required this.online, required this.size});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.06 + 1),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: online ? Brand.gradient : null,
        color: online ? null : s.outlineVariant,
      ),
      child: Container(
        decoration: BoxDecoration(shape: BoxShape.circle, color: s.surfaceContainerHigh),
        child: Icon(Icons.devices_rounded, size: size * 0.42, color: s.primary),
      ),
    );
  }
}

class _AddFace extends StatelessWidget {
  final double size;
  const _AddFace({required this.size});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: s.outlineVariant, width: 2),
      ),
      child: Icon(Icons.add_rounded, size: size * 0.45, color: s.primary),
    );
  }
}

class _PersonTile extends StatelessWidget {
  final Person person;
  final bool selected;
  final bool hero;
  final _Open onOpen;
  const _PersonTile({required this.person, required this.selected, required this.hero, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    final t = Theme.of(context);
    return FutureBuilder(
      future: Future.wait([e.repo.messages(person.id, limit: 1), e.repo.conversation(person.id)]),
      builder: (context, snap) {
        final last = (snap.data?[0] as List<Message>?)?.firstOrNull;
        final conv = snap.data?[1] as Map<String, Object?>?;
        final unread = conv?['unread_count'] as int? ?? 0;
        final prog = last?.type == 'file' ? e.transfers.progress[last!.id] : null;
        final avatar = Avatar(
          id: person.id,
          name: person.name,
          photo: person.roster.avatar,
          online: e.personOnline(person.id),
          size: 52,
        );
        return _ChatRow(
          selected: selected,
          onTap: () => onOpen(person.id),
          onDrop: person.blocked ? null : (files) => onOpen(person.id, files: files),
          leading: hero ? Hero(tag: 'avatar-${person.id}', child: avatar) : avatar,
          title: person.displayName,
          badges: [
            if (person.favorite) Icon(Icons.star_rounded, size: 16, color: t.colorScheme.primary),
            if (person.blocked) Icon(Icons.block, size: 15, color: t.colorScheme.error),
          ],
          subtitle: prog != null
              ? tr('Transferring… {pct}%', {'pct': '${prog.total == 0 ? 0 : prog.done * 100 ~/ prog.total}'})
              : _preview(last, e.me.id),
          strong: unread > 0 || prog != null,
          time: last == null ? null : clock(last.createdAt),
          unread: unread,
        );
      },
    );
  }
}

class _ChatRow extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final void Function(List<Source>)? onDrop;
  final Widget leading;
  final String title;
  final List<Widget> badges;
  final String subtitle;
  final bool strong;
  final String? time;
  final int unread;
  const _ChatRow({
    required this.selected,
    required this.onTap,
    required this.onDrop,
    required this.leading,
    required this.title,
    this.badges = const [],
    required this.subtitle,
    this.strong = false,
    this.time,
    this.unread = 0,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    return _DropZone(
      onDrop: onDrop,
      builder: (hover) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: hover
                ? s.primary.withValues(alpha: 0.12)
                : selected
                ? s.surfaceContainerLow
                : Colors.transparent,
            border: Border.all(color: hover ? s.primary : Colors.transparent, width: 1.5),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Row(
                children: [
                  leading,
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.textTheme.titleMedium,
                              ),
                            ),
                            for (final b in badges) Padding(padding: const EdgeInsets.only(left: 5), child: b),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          hover ? tr('Drop to send') : subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.textTheme.bodySmall?.copyWith(
                            fontSize: 13.5,
                            color: hover || strong ? s.onSurface : null,
                            fontWeight: strong ? FontWeight.w600 : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (time != null)
                        Text(
                          time!,
                          style: t.textTheme.labelSmall?.copyWith(
                            color: unread > 0 ? s.primary : s.onSurfaceVariant,
                          ),
                        ),
                      const SizedBox(height: 6),
                      AnimatedScale(
                        scale: unread > 0 ? 1 : 0,
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutBack,
                        child: Container(
                          constraints: const BoxConstraints(minWidth: 22),
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(color: s.primary, borderRadius: BorderRadius.circular(11)),
                          child: Text(
                            '$unread',
                            textAlign: TextAlign.center,
                            style: t.textTheme.labelSmall?.copyWith(color: s.onPrimary),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _preview(Message? m, String meId) {
  if (m == null) return tr('Say hi or send a file');
  final mine = m.author == meId ? tr('You: ') : '';
  return switch (m.type) {
    'text' => '$mine${m.body['text']}',
    'file' =>
      '$mine${(m.body['files'] as List).length == 1 ? (m.body['files'] as List).first['name'] : '${(m.body['files'] as List).length} files'}',
    _ => systemText(m.body, ''),
  };
}

class _MeTile extends StatelessWidget {
  final bool selected;
  final _Open onOpen;
  const _MeTile({required this.selected, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    final others = e.me.roster.devices.where((d) => d.id != e.id.deviceId).toList();
    final anyOnline = others.any((d) => e.deviceOnline(d.id));
    return _ChatRow(
      selected: selected,
      onTap: others.isEmpty
          ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PairScreen(link: true)))
          : () => onOpen(e.me.id),
      onDrop: others.isEmpty ? null : (files) => onOpen(e.me.id, files: files),
      leading: _DevicesFace(online: anyOnline, size: 52),
      title: tr('My devices'),
      subtitle: others.isEmpty
          ? tr('Link your laptop or phone to send between them')
          : others.map((d) => '${d.name}${e.deviceOnline(d.id) ? ' · ${tr('online')}' : ''}').join(', '),
    );
  }
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Notice({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.colorScheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: t.colorScheme.error),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: t.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _FirstPerson extends StatelessWidget {
  const _FirstPerson();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('Pair once with the people you share with. After that, they show up whenever you\'re on the same Wi-Fi.'),
            style: t.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PairScreen())),
            icon: const Icon(Icons.qr_code_2_rounded),
            label: Text(tr('Add a person')),
          ),
        ],
      ),
    );
  }
}

/// Right pane before a chat is chosen (wide layout).
class _Welcome extends StatelessWidget {
  const _Welcome({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ColoredBox(
      color: t.colorScheme.surfaceContainerLowest,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/icon.png', width: 112),
              const SizedBox(height: 20),
              Text(tr('Pick a chat, or drag files onto a name.'), style: t.textTheme.headlineMedium, textAlign: TextAlign.center),
              const SizedBox(height: 10),
              Text(
                tr('Everything stays on this Wi-Fi. No internet, no cloud, no account.'),
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Text for system bubbles (PRD §10).
String systemText(Map<String, dynamic> b, String name) => switch (b['kind']) {
  'trust_proposed_by_me' => tr('You asked to skip approval for files. Waiting for {name} to agree.', {'name': name}),
  'trust_proposed_by_them' => tr('{name} wants to skip approval for files between you.', {'name': name}),
  'trust_on' => tr('Auto-accept is on. Files between you no longer need approval.'),
  'trust_off_by_me' => tr('You turned off auto-accept.'),
  'trust_off_by_them' => tr('{name} turned off auto-accept.', {'name': name}),
  _ => jsonEncode(b),
};
