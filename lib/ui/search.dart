import 'package:flutter/material.dart';

import '../data/repo.dart';
import 'app.dart';
import 'i18n.dart';
import 'chat.dart';
import 'theme.dart';

/// Search across messages and file names (PRD F15).
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  List<Message> _results = const [];

  Future<void> _run(String q) async {
    final r = q.trim().length < 2 ? <Message>[] : await context.engine.repo.search(q.trim());
    if (mounted) setState(() => _results = r);
  }

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    String who(String conv) =>
        conv == e.me.id ? 'My devices' : e.contacts.where((c) => c.id == conv).firstOrNull?.name ?? '';
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          decoration: InputDecoration(
            hintText: tr('Search messages and files'),
            filled: false,
            border: InputBorder.none,
          ),
          onChanged: _run,
        ),
      ),
      body: ListView(
        children: [
          for (final m in _results.where((m) => m.type != 'system'))
            ListTile(
              leading: Icon(m.type == 'file' ? Icons.insert_drive_file_outlined : Icons.chat_bubble_outline),
              title: Text(
                m.type == 'file' ? (m.body['files'] as List).map((f) => f['name']).join(', ') : '${m.body['text']}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('${who(m.conversation)} · ${clock(m.createdAt)}'),
              onTap: () =>
                  Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(personId: m.conversation))),
            ),
        ],
      ),
    );
  }
}
