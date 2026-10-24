import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../core/roster.dart';
import '../core/trust.dart';

const _uuid = Uuid();
String newId() => _uuid.v7();
int nowMs() => DateTime.now().millisecondsSinceEpoch;

class Person {
  final String id;
  final String displayName;
  final String? nickname;
  final bool isMe, favorite, blocked;
  final Roster roster;
  final String secret;
  final String? folder;
  final Trust trust;
  final int acceptedCount;

  Person(Map<String, Object?> r)
    : id = r['id'] as String,
      displayName = r['display_name'] as String,
      nickname = r['nickname'] as String?,
      isMe = r['is_me'] == 1,
      favorite = r['favorite'] == 1,
      blocked = r['blocked'] == 1,
      roster = Roster.fromJson(jsonDecode(r['roster_json'] as String)),
      secret = r['person_secret'] as String,
      folder = r['folder'] as String?,
      trust = Trust.fromJson(r['trust_json'] == null ? null : jsonDecode(r['trust_json'] as String)),
      acceptedCount = r['auto_accept_hint'] as int;

  String get name => (nickname?.isNotEmpty ?? false) ? nickname! : displayName;
}

class Device {
  final String id, personId, name, platform, signPk, certFp;
  final int? lastSeen, lastPort;
  final String? lastIp;
  final bool removed;

  Device(Map<String, Object?> r)
    : id = r['id'] as String,
      personId = r['person_id'] as String,
      name = r['name'] as String,
      platform = r['platform'] as String,
      signPk = r['sign_pk'] as String,
      certFp = r['cert_fp'] as String,
      lastSeen = r['last_seen'] as int?,
      lastIp = r['last_ip'] as String?,
      lastPort = r['last_port'] as int?,
      removed = r['removed'] == 1;
}

class Message {
  final Map<String, Object?> row;
  Message(this.row);
  String get id => row['id'] as String;
  String get conversation => row['conversation_id'] as String;
  String get author => row['author_person'] as String;
  String get type => row['type'] as String;
  String get status => row['status'] as String;
  int get createdAt => row['created_at'] as int;
  bool get deleted => row['deleted'] == 1;
  Map<String, dynamic> get body => jsonDecode(row['body_json'] as String);
}

class Repo {
  final Database db;
  Repo(this.db);

  // ---------- settings ----------
  Future<String?> setting(String k) async =>
      (await db.query('settings', where: 'key=?', whereArgs: [k])).firstOrNull?['value'] as String?;
  Future<void> setSetting(String k, String? v) =>
      db.insert('settings', {'key': k, 'value': v}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<int> _nextCounter(Transaction t, String k) async {
    final r = await t.query('settings', where: 'key=?', whereArgs: [k]);
    final n = (int.tryParse(r.firstOrNull?['value'] as String? ?? '') ?? 0) + 1;
    await t.insert('settings', {'key': k, 'value': '$n'}, conflictAlgorithm: ConflictAlgorithm.replace);
    return n;
  }

  // ---------- persons & devices ----------
  Future<Person?> me() async => (await db.query('person', where: 'is_me=1')).map(Person.new).firstOrNull;
  Future<Person?> person(String id) async =>
      (await db.query('person', where: 'id=?', whereArgs: [id])).map(Person.new).firstOrNull;
  Future<List<Person>> contacts() async =>
      (await db.query('person', where: 'is_me=0', orderBy: 'favorite DESC, display_name')).map(Person.new).toList();

  /// Saves a verified roster: person row + device rows. Devices missing from the roster are marked removed.
  Future<void> saveRoster(Roster r, {required bool isMe, String? secret}) async {
    await db.transaction((t) async {
      final existing = await t.query('person', where: 'id=?', whereArgs: [r.personId]);
      if (existing.isEmpty) {
        await t.insert('person', {
          'id': r.personId,
          'display_name': r.name,
          'is_me': isMe ? 1 : 0,
          'roster_json': jsonEncode(r.toJson()),
          'roster_version': r.version,
          'person_secret': secret ?? '',
          'created_at': nowMs(),
        });
        if (!isMe) await t.insert('conversation', {'person_id': r.personId, 'last_message_at': nowMs()});
      } else {
        await t.update(
          'person',
          {
            'display_name': r.name,
            'roster_json': jsonEncode(r.toJson()),
            'roster_version': r.version,
            if (secret != null) 'person_secret': secret,
          },
          where: 'id=?',
          whereArgs: [r.personId],
        );
      }
      await t.update('device', {'removed': 1}, where: 'person_id=?', whereArgs: [r.personId]);
      for (final d in r.devices) {
        final n = await t.update(
          'device',
          {'name': d.name, 'platform': d.platform, 'sign_pk': d.signPk, 'cert_fp': d.certFp, 'removed': 0},
          where: 'id=? AND person_id=?',
          whereArgs: [d.id, r.personId],
        );
        if (n == 0) {
          await t.insert('device', {
            'id': d.id,
            'person_id': r.personId,
            'name': d.name,
            'platform': d.platform,
            'sign_pk': d.signPk,
            'cert_fp': d.certFp,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
  }

  Future<void> deletePerson(String id) async {
    await db.delete('device', where: 'person_id=?', whereArgs: [id]);
    await db.delete('person', where: 'id=?', whereArgs: [id]);
    await db.delete('outbox', where: 'person_id=?', whereArgs: [id]);
  }

  Future<void> updatePerson(String id, Map<String, Object?> v) =>
      db.update('person', v, where: 'id=?', whereArgs: [id]);

  Future<void> saveTrust(String personId, Trust t) => updatePerson(personId, {'trust_json': jsonEncode(t.toJson())});

  Future<List<Device>> devices({String? personId, bool includeRemoved = false}) async => (await db.query(
    'device',
    where: [if (personId != null) 'person_id=?', if (!includeRemoved) 'removed=0'].join(' AND ').ifEmpty,
    whereArgs: [if (personId != null) personId],
  )).map(Device.new).toList();

  Future<Device?> device(String id) async =>
      (await db.query('device', where: 'id=?', whereArgs: [id])).map(Device.new).firstOrNull;

  Future<void> seen(String deviceId, String ip, int port) => db.update(
    'device',
    {'last_seen': nowMs(), 'last_ip': ip, 'last_port': port},
    where: 'id=?',
    whereArgs: [deviceId],
  );

  // ---------- messages ----------
  Future<Message> addLocalMessage(
    String conversation,
    String author,
    String type,
    Map<String, dynamic> body, {
    required String deviceId,
    String status = 'queued',
    String? id,
  }) async {
    late Map<String, Object?> row;
    await db.transaction((t) async {
      final now = nowMs();
      row = {
        'id': id ?? newId(),
        'conversation_id': conversation,
        'origin_device': deviceId,
        'origin_seq': await _nextCounter(t, 'origin_seq'),
        'author_person': author,
        'type': type,
        'body_json': jsonEncode(body),
        'status': status,
        'created_at': now,
        'updated_at': now,
        'log_seq': await _nextCounter(t, 'log_seq'),
      };
      await t.insert('message', row);
      await t.update('conversation', {'last_message_at': now}, where: 'person_id=?', whereArgs: [conversation]);
    });
    return Message(row);
  }

  /// Inserts or merges a message from a contact or an own device. Last writer (updated_at) wins.
  /// Returns true if it was new to this device.
  Future<bool> upsertMessage(Map<String, Object?> m, {bool countUnread = false}) async {
    var isNew = false;
    await db.transaction((t) async {
      final cur = await t.query('message', where: 'id=?', whereArgs: [m['id']]);
      final row = Map<String, Object?>.from(m)..['log_seq'] = await _nextCounter(t, 'log_seq');
      if (cur.isEmpty) {
        isNew = true;
        await t.insert('message', row);
        await t.update(
          'conversation',
          {
            'last_message_at': m['created_at'],
            if (countUnread) 'unread_count': await _unread(t, m['conversation_id'] as String) + 1,
          },
          where: 'person_id=?',
          whereArgs: [m['conversation_id']],
        );
      } else if ((cur.first['updated_at'] as int) < (m['updated_at'] as int)) {
        await t.update('message', row, where: 'id=?', whereArgs: [m['id']]);
      }
    });
    return isNew;
  }

  Future<int> _unread(Transaction t, String conv) async =>
      (await t.query(
            'conversation',
            columns: ['unread_count'],
            where: 'person_id=?',
            whereArgs: [conv],
          )).firstOrNull?['unread_count']
          as int? ??
      0;

  Future<void> updateMessage(String id, {String? status, Map<String, dynamic>? body, bool? deleted}) async {
    await db.transaction((t) async {
      await t.update(
        'message',
        {
          if (status != null) 'status': status,
          if (body != null) 'body_json': jsonEncode(body),
          if (deleted != null) 'deleted': deleted ? 1 : 0,
          'updated_at': nowMs(),
          'log_seq': await _nextCounter(t, 'log_seq'),
        },
        where: 'id=?',
        whereArgs: [id],
      );
    });
  }

  Future<Message?> message(String id) async =>
      (await db.query('message', where: 'id=?', whereArgs: [id])).map(Message.new).firstOrNull;

  Future<List<Message>> messages(String conversation, {int limit = 500}) async => (await db.query(
    'message',
    where: 'conversation_id=? AND deleted=0',
    whereArgs: [conversation],
    orderBy: 'created_at DESC',
    limit: limit,
  )).map(Message.new).toList().reversed.toList();

  Future<List<Message>> search(String q) async => (await db.query(
    'message',
    where: 'deleted=0 AND body_json LIKE ?',
    whereArgs: ['%${q.replaceAll('%', '')}%'],
    orderBy: 'created_at DESC',
    limit: 200,
  )).map(Message.new).toList();

  Future<List<Map<String, Object?>>> messagesSince(int logSeq, {int limit = 500}) =>
      db.query('message', where: 'log_seq>?', whereArgs: [logSeq], orderBy: 'log_seq', limit: limit);

  Future<Map<String, Object?>?> conversation(String personId) async =>
      (await db.query('conversation', where: 'person_id=?', whereArgs: [personId])).firstOrNull;

  Future<void> markRead(String personId) => db.update(
    'conversation',
    {'unread_count': 0, 'read_marker': nowMs()},
    where: 'person_id=?',
    whereArgs: [personId],
  );

  Future<void> clearHistory(String personId) =>
      db.update('message', {'deleted': 1, 'updated_at': nowMs()}, where: 'conversation_id=?', whereArgs: [personId]);

  // ---------- sync cursors ----------
  Future<int> cursor(String peer) async =>
      (await db.query('sync_cursor', where: 'peer_device=?', whereArgs: [peer])).firstOrNull?['last_log_seq'] as int? ??
      0;
  Future<void> setCursor(String peer, int v) =>
      db.insert('sync_cursor', {'peer_device': peer, 'last_log_seq': v}, conflictAlgorithm: ConflictAlgorithm.replace);

  // ---------- outbox ----------
  Future<void> enqueue(String personId, String kind, Map<String, dynamic> payload) => db.insert('outbox', {
    'id': newId(),
    'person_id': personId,
    'kind': kind,
    'payload_json': jsonEncode(payload),
    'created_at': nowMs(),
  });

  Future<List<Map<String, Object?>>> outboxFor(String personId) => db.query(
    'outbox',
    where: 'person_id=? AND next_try_at<=?',
    whereArgs: [personId, nowMs()],
    orderBy: 'created_at',
  );

  Future<void> outboxDone(String id) => db.delete('outbox', where: 'id=?', whereArgs: [id]);

  Future<void> outboxRetryLater(String id, int attempts) => db.update(
    'outbox',
    {'attempts': attempts + 1, 'next_try_at': nowMs() + (attempts.clamp(0, 6) + 1) * 10000},
    where: 'id=?',
    whereArgs: [id],
  );
}

extension on String {
  String? get ifEmpty => isEmpty ? null : this;
}
