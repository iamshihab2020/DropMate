import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sq;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _schema = [
  '''CREATE TABLE person(
    id TEXT PRIMARY KEY, display_name TEXT NOT NULL, nickname TEXT, avatar_path TEXT,
    is_me INTEGER NOT NULL DEFAULT 0, favorite INTEGER NOT NULL DEFAULT 0, blocked INTEGER NOT NULL DEFAULT 0,
    roster_json TEXT NOT NULL, roster_version INTEGER NOT NULL, folder TEXT, person_secret TEXT NOT NULL,
    trust_json TEXT, auto_accept_hint INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL,
    meta_updated_at INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE device(
    id TEXT PRIMARY KEY, person_id TEXT NOT NULL, name TEXT NOT NULL, platform TEXT NOT NULL,
    sign_pk TEXT NOT NULL, cert_fp TEXT NOT NULL, last_seen INTEGER, last_ip TEXT, last_port INTEGER,
    removed INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE conversation(
    person_id TEXT PRIMARY KEY, last_message_at INTEGER, unread_count INTEGER NOT NULL DEFAULT 0,
    read_marker INTEGER NOT NULL DEFAULT 0)''',
  '''CREATE TABLE message(
    id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, origin_device TEXT NOT NULL, origin_seq INTEGER NOT NULL,
    author_person TEXT NOT NULL, type TEXT NOT NULL, body_json TEXT NOT NULL, status TEXT NOT NULL,
    created_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL,
    log_seq INTEGER NOT NULL)''',
  'CREATE INDEX message_conv ON message(conversation_id, created_at)',
  'CREATE INDEX message_log ON message(log_seq)',
  '''CREATE TABLE transfer(
    id TEXT PRIMARY KEY, message_id TEXT NOT NULL, direction TEXT NOT NULL, peer_device TEXT,
    person_id TEXT NOT NULL, state TEXT NOT NULL, total_bytes INTEGER NOT NULL, done_bytes INTEGER NOT NULL DEFAULT 0,
    folder TEXT, error TEXT, stored_on_device TEXT, created_at INTEGER NOT NULL)''',
  '''CREATE TABLE transfer_file(
    transfer_id TEXT NOT NULL, f INTEGER NOT NULL, rel_path TEXT NOT NULL, size INTEGER NOT NULL, mime TEXT,
    sha256 TEXT, local_path TEXT, part_path TEXT, chunks TEXT, mtime INTEGER,
    PRIMARY KEY(transfer_id, f))''',
  '''CREATE TABLE outbox(
    id TEXT PRIMARY KEY, person_id TEXT NOT NULL, kind TEXT NOT NULL, payload_json TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0, next_try_at INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)''',
  // Own-device sync: highest log_seq pulled from each of my other devices (PRD §11.7).
  'CREATE TABLE sync_cursor(peer_device TEXT PRIMARY KEY, last_log_seq INTEGER NOT NULL)',
  'CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)',
];

Future<Database> openAppDb(String dir, {bool inMemory = false}) async {
  final factory = (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
      ? _ffi()
      : sq.databaseFactorySqflitePlugin;
  return factory.openDatabase(
    inMemory ? inMemoryDatabasePath : p.join(dir, 'dropmate.db'),
    options: OpenDatabaseOptions(
      version: 1,
      onConfigure: (db) => db.rawQuery('PRAGMA journal_mode=WAL'),
      onCreate: (db, _) async {
        for (final s in _schema) {
          await db.execute(s);
        }
      },
    ),
  );
}

DatabaseFactory _ffi() {
  sqfliteFfiInit();
  return databaseFactoryFfi;
}
