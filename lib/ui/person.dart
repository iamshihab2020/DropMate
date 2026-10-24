import 'package:flutter/material.dart';

import '../core/trust.dart';
import '../data/repo.dart';
import '../services/transfers.dart';
import 'app.dart';
import 'i18n.dart';
import 'chat.dart';
import 'files.dart';
import 'theme.dart';

class PersonScreen extends StatelessWidget {
  final String personId;
  const PersonScreen({super.key, required this.personId});

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    return ListenableBuilder(
      listenable: e,
      builder: (context, _) {
        final p = e.contacts.where((c) => c.id == personId).firstOrNull;
        if (p == null)
          return Scaffold(
            appBar: AppBar(),
            body: Center(child: Text(tr('Unpaired'))),
          );
        final t = Theme.of(context);
        return Scaffold(
          appBar: AppBar(),
          body: ListView(
            padding: EdgeInsets.symmetric(horizontal: ((MediaQuery.sizeOf(context).width - 680) / 2).clamp(0, 9999)),
            children: [
              const SizedBox(height: 16),
              Center(
                child: Hero(
                  tag: 'avatar-${p.id}',
                  child: Avatar(id: p.id, name: p.name, photo: p.roster.avatar, online: e.personOnline(p.id), size: 120),
                ),
              ),
              const SizedBox(height: 8),
              const SizedBox(height: 8),
              Center(child: Text(p.displayName, style: t.textTheme.headlineLarge)),
              if (p.nickname != null && p.nickname!.isNotEmpty)
                Center(child: Text(tr('Shown to you as "{nick}"', {'nick': p.nickname}), style: t.textTheme.bodySmall)),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(tr('Nickname')),
                subtitle: Text(p.nickname ?? tr('None')),
                onTap: () async {
                  final v = await _prompt(context, 'Nickname', p.nickname ?? '');
                  if (v != null) await e.setNickname(p.id, v.isEmpty ? null : v);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.star_outline),
                title: Text(tr('Favorite')),
                value: p.favorite,
                onChanged: (v) => e.setFavorite(p.id, v),
              ),
              const Divider(),
              _TrustSection(p: p),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(tr('Save their files to')),
                subtitle: Text(p.folder ?? tr('Default download folder')),
                trailing: p.folder == null
                    ? null
                    : IconButton(icon: const Icon(Icons.clear), onPressed: () => e.setFolder(p.id, null)),
                onTap: () async {
                  final d = await pickDirectory(context);
                  if (d != null) await e.setFolder(p.id, d);
                },
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(tr('Their devices'), style: t.textTheme.titleSmall),
              ),
              FutureBuilder(
                future: e.repo.devices(personId: p.id),
                builder: (context, snap) => Column(
                  children: [
                    for (final d in snap.data ?? const <Device>[])
                      ListTile(
                        leading: Icon(d.platform == 'windows' ? Icons.laptop_windows : Icons.smartphone),
                        title: Text(d.name),
                        subtitle: Text(
                          e.deviceOnline(d.id) ? tr('Online') : tr('Last seen {ago}', {'ago': ago(d.lastSeen)}),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(),
              SwitchListTile(
                secondary: const Icon(Icons.block),
                title: Text(tr('Block')),
                subtitle: Text(tr('Ignore their messages and files without telling them')),
                value: p.blocked,
                onChanged: (v) => e.setBlocked(p.id, v),
              ),
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: Text(tr('Clear chat history')),
                onTap: () async {
                  if (await _sure(
                    context,
                    'Clear history with ${p.name}?',
                    'Files already saved stay on your device.',
                  )) {
                    await e.clearHistory(p.id);
                  }
                },
              ),
              ListTile(
                leading: Icon(Icons.link_off, color: t.colorScheme.error),
                title: Text(tr('Unpair'), style: TextStyle(color: t.colorScheme.error)),
                subtitle: Text(tr('You will need to pair again to send files')),
                onTap: () async {
                  if (await _sure(context, 'Unpair ${p.name}?', 'This removes them from all your devices.')) {
                    await e.unpair(p.id);
                    if (context.mounted) Navigator.popUntil(context, (r) => r.isFirst);
                  }
                },
              ),
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }
}

class _TrustSection extends StatelessWidget {
  final Person p;
  const _TrustSection({required this.p});

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    final trust = p.trust;
    final (subtitle, action) = switch (trust.state) {
      TrustState.none => (tr('Every file asks you first'), tr('Ask {name}', {'name': p.name})),
      TrustState.proposedByMe => (tr('Waiting for {name} to agree', {'name': p.name}), tr('Cancel')),
      TrustState.proposedByThem => (tr('{name} asked to skip approval', {'name': p.name}), tr('Agree')),
      TrustState.active => (
        tr('On · files up to {size} arrive without asking', {'size': _size(trust.mine.maxBytes)}),
        tr('Turn off'),
      ),
    };
    return ListTile(
      leading: const Icon(Icons.bolt),
      title: Text(tr('Skip approval between you')),
      subtitle: Text('$subtitle\n${tr('Both of you must agree. Either can turn it off.')}'),
      isThreeLine: true,
      trailing: FilledButton.tonal(
        onPressed: () async {
          switch (trust.state) {
            case TrustState.none:
              final l = await pickLimits(context);
              if (l != null) await e.trustPropose(p.id, l);
            case TrustState.proposedByThem:
              final l = await pickLimits(context);
              if (l != null) await e.trustAccept(p.id, l);
            case TrustState.proposedByMe || TrustState.active:
              await e.trustRevoke(p.id);
          }
        },
        child: Text(action),
      ),
    );
  }
}

String _size(int b) => b >= 1 << 50 ? 'any size' : formatBytes(b);

Future<String?> _prompt(BuildContext context, String title, String initial) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v.trim())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(tr('Save'))),
      ],
    ),
  );
}

Future<String?> prompt(BuildContext context, String title, String initial) => _prompt(context, title, initial);

Future<bool> _sure(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Yes'))),
        ],
      ),
    ) ??
    false;

Future<bool> sure(BuildContext context, String title, String body) => _sure(context, title, body);
