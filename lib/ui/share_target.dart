import 'package:flutter/material.dart';

import '../services/sources.dart';
import '../services/transfers.dart';
import 'app.dart';
import 'i18n.dart';
import 'chat.dart';
import 'theme.dart';

/// "Send to…" after sharing from another app or Explorer's "Send with DropMate" (PRD F11).
class ShareTargetScreen extends StatelessWidget {
  final List<Source> files;
  const ShareTargetScreen({super.key, required this.files});

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    final total = files.fold<int>(0, (a, f) => a + f.size);
    void go(String personId) => Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(personId: personId, initialFiles: files),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text('Send ${files.length == 1 ? files.first.relPath.split('/').last : '${files.length} files'}'),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('${formatBytes(total)} · ${tr('choose who gets it')}'),
          ),
          for (final c in e.contacts.where((c) => !c.blocked))
            ListTile(
              leading: Avatar(id: c.id, name: c.name, photo: c.roster.avatar, online: e.personOnline(c.id)),
              title: Text(c.name),
              subtitle: Text(
                e.personOnline(c.id) ? tr('Online') : '${tr('Offline')} · ${tr('will send when they\'re back')}',
              ),
              onTap: () => go(c.id),
            ),
          if (e.me.roster.devices.length > 1)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.devices_outlined)),
              title: Text(tr('My devices')),
              onTap: () => go(e.me.id),
            ),
          if (e.contacts.isEmpty) Padding(padding: EdgeInsets.all(24), child: Text(tr('Pair with someone first.'))),
        ],
      ),
    );
  }
}
