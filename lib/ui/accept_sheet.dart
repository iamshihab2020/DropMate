import 'package:flutter/material.dart';

import '../core/sanitize.dart';
import '../core/trust.dart';
import '../services/transfers.dart';
import 'app.dart';
import 'i18n.dart';
import 'files.dart';
import 'theme.dart';

/// Incoming request: sender, files, size, free space; Accept / Decline / Accept to folder (PRD §10).
class AcceptSheet extends StatefulWidget {
  final Incoming inc;
  const AcceptSheet({super.key, required this.inc});

  @override
  State<AcceptSheet> createState() => _AcceptSheetState();
}

class _AcceptSheetState extends State<AcceptSheet> {
  bool _trustNext = false;

  void _decide(bool ok, {String? folder}) async {
    final e = context.engine;
    final inc = widget.inc;
    e.transfers.decide(inc.transferId, ok, folder: folder);
    if (ok && _trustNext) await e.trustPropose(inc.from.id, const Limits());
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final inc = widget.inc;
    final t = Theme.of(context);
    final noSpace = inc.freeBytes != null && inc.freeBytes! < inc.total;
    final exe = inc.files.any((f) => isExecutable(f.name));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Avatar(id: inc.from.id, name: inc.from.name, photo: inc.from.roster.avatar, online: true),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(tr('{name} wants to send', {'name': inc.from.name}), style: t.textTheme.titleLarge),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final f in inc.files.take(50))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(iconFor(f.name)),
                      title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Text(formatBytes(f.size)),
                    ),
                  if (inc.files.length > 50) Text('…and ${inc.files.length - 50} more'),
                ],
              ),
            ),
            const Divider(),
            Text(
              'Total ${formatBytes(inc.total)}'
              '${inc.freeBytes == null ? '' : ' · ${tr('{size} free', {'size': formatBytes(inc.freeBytes!)})}'}',
              style: t.textTheme.bodyMedium,
            ),
            if (noSpace)
              _Warn(
                icon: Icons.sd_card_alert_outlined,
                text: 'Not enough free space on this device.',
                color: t.colorScheme.error,
              ),
            if (exe)
              _Warn(
                icon: Icons.warning_amber_rounded,
                text: tr('Contains apps or scripts. Only open them if you trust {name}.', {'name': inc.from.name}),
                color: t.colorScheme.tertiary,
              ),
            if (inc.suggestTrust)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _trustNext,
                onChanged: (v) => setState(() => _trustNext = v ?? false),
                title: Text(tr('Skip approval with {name} next time?', {'name': inc.from.name})),
                subtitle: Text(tr('They must agree too. You can turn it off any time.')),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: () => _decide(false), child: Text(tr('Decline'))),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(onPressed: noSpace ? null : () => _decide(true), child: Text(tr('Accept'))),
                ),
              ],
            ),
            TextButton(
              onPressed: noSpace
                  ? null
                  : () async {
                      final dir = await pickDirectory(context);
                      if (dir != null) _decide(true, folder: dir);
                    },
              child: Text(tr('Accept to folder…')),
            ),
          ],
        ),
      ),
    );
  }
}

class _Warn extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _Warn({required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(color: color)),
        ),
      ],
    ),
  );
}
