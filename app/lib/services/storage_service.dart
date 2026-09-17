import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/models.dart';

/// SQLite persistence for identity, settings, contacts, conversations and
/// messages. On desktop (Windows/Linux) it uses the FFI factory; on mobile it
/// uses the platform sqflite implementation.
class StorageService {
  StorageService({this.fileName = 'chat1190.sqlite'});

  /// Database file name (allows multiple isolated stores, e.g. in tests).
  final String fileName;
  Database? _db;

  bool get isOpen => _db != null;

  Future<void> open() async {
    if (_db != null) return;
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, fileName);
    _db = await openDatabase(
      path,
      version: 1,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)
        ''');
        await db.execute('''
          CREATE TABLE contacts (
            id TEXT PRIMARY KEY,
            displayName TEXT NOT NULL,
            publicKey BLOB NOT NULL,
            lastSeen INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE conversations (
            id TEXT PRIMARY KEY,
            memberIds TEXT NOT NULL,
            title TEXT,
            isGroup INTEGER NOT NULL DEFAULT 0,
            lastMessagePreview TEXT NOT NULL DEFAULT '',
            lastMessageAt INTEGER NOT NULL DEFAULT 0,
            unread INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            conversationId TEXT NOT NULL,
            senderId TEXT NOT NULL,
            kind TEXT NOT NULL,
            text TEXT NOT NULL DEFAULT '',
            fileName TEXT,
            fileSize INTEGER,
            mimeType TEXT,
            fileId TEXT,
            localPath TEXT,
            createdAt INTEGER NOT NULL,
            state TEXT NOT NULL,
            outgoing INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_messages_conv ON messages(conversationId, createdAt)',
        );
      },
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Database get db {
    final d = _db;
    if (d == null) throw StateError('StorageService not opened');
    return d;
  }

  // ---- key/value ----
  Future<void> setKV(String k, String v) =>
      db.insert('kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<String?> getKV(String k) async {
    final rows = await db.query('kv', where: 'k = ?', whereArgs: [k], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['v'] as String?;
  }

  Future<void> deleteKV(String k) => db.delete('kv', where: 'k = ?', whereArgs: [k]);

  // ---- identity ----
  Future<void> saveIdentity({
    required String userId,
    required String displayName,
    required Uint8List seed,
  }) async {
    await setKV('identity.userId', userId);
    await setKV('identity.displayName', displayName);
    await setKV('identity.seed', base64Encode(seed));
  }

  Future<({String userId, String displayName, Uint8List seed})?>
      loadIdentity() async {
    final userId = await getKV('identity.userId');
    final seedB64 = await getKV('identity.seed');
    if (userId == null || seedB64 == null) return null;
    final displayName = await getKV('identity.displayName') ?? userId;
    return (
      userId: userId,
      displayName: displayName,
      seed: base64Decode(seedB64),
    );
  }

  Future<void> clearIdentity() async {
    await deleteKV('identity.userId');
    await deleteKV('identity.displayName');
    await deleteKV('identity.seed');
  }

  // ---- settings ----
  Future<void> setSetting(String k, String v) => setKV('setting.$k', v);
  Future<String?> getSetting(String k) => getKV('setting.$k');

  // ---- contacts ----
  Future<void> upsertContact(Contact c) =>
      db.insert('contacts', c.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<Contact>> allContacts() async {
    final rows = await db.query('contacts');
    return rows.map(Contact.fromRow).toList();
  }

  Future<Contact?> contact(String id) async {
    final rows = await db.query('contacts', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Contact.fromRow(rows.first);
  }

  // ---- conversations ----
  Future<void> upsertConversation(Conversation c) =>
      db.insert('conversations', c.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<Conversation>> allConversations() async {
    final rows = await db.query('conversations', orderBy: 'lastMessageAt DESC');
    return rows.map(Conversation.fromRow).toList();
  }

  Future<Conversation?> conversation(String id) async {
    final rows = await db.query('conversations', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Conversation.fromRow(rows.first);
  }

  // ---- messages ----
  Future<void> insertMessage(Message m) =>
      db.insert('messages', m.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<Message>> messagesFor(String conversationId, {int limit = 500}) async {
    final rows = await db.query(
      'messages',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
      orderBy: 'createdAt ASC',
      limit: limit,
    );
    return rows.map(Message.fromRow).toList();
  }

  Future<void> updateMessageState(String id, DeliveryState state) =>
      db.update('messages', {'state': state.name}, where: 'id = ?', whereArgs: [id]);

  Future<void> updateMessageLocalPath(String id, String path) =>
      db.update('messages', {'localPath': path}, where: 'id = ?', whereArgs: [id]);

  Future<void> wipe() async {
    for (final t in ['messages', 'conversations', 'contacts', 'kv']) {
      await db.delete(t);
    }
  }

  /// Path where received/sent files are stored.
  Future<Directory> filesDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'chat1190_files'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> tempDir() async {
    final t = await getTemporaryDirectory();
    final dir = Directory(p.join(t.path, 'chat1190_tmp'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}

/// Small helper to encode a string list for storage.
String encodeList(List<String> xs) => jsonEncode(xs);
