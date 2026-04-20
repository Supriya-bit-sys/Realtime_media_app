import 'dart:typed_data';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseService {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  static Future<Database> _initDB() async {
    final path = join(await getDatabasesPath(), 'messages.db');

    return openDatabase(
      path,
      version: 5,
      onCreate: (db, version) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 3) {
          await db.execute(
            'CREATE TABLE IF NOT EXISTS identity(pub BLOB, priv BLOB)',
          );
          await db.execute('''
            CREATE TABLE IF NOT EXISTS contacts(
              id TEXT PRIMARY KEY,
              pub_key BLOB,
              shared_secret BLOB
            )
          ''');
        }
        if (oldVersion < 4) {
          // Security model changed (DH identity/session format). Reset crypto state.
          await db.execute('DELETE FROM identity');
          await db.execute('DELETE FROM contacts');
        }
        if (oldVersion < 5) {
          await db.execute(
            'ALTER TABLE messages ADD COLUMN conversationId TEXT DEFAULT ""',
          );
        }
      },
    );
  }

  static Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS messages(
        id TEXT PRIMARY KEY,
        text TEXT,
        timestamp INTEGER,
        status TEXT,
        fromUser TEXT,
        isImage INTEGER DEFAULT 0,
        conversationId TEXT DEFAULT '',
        retryCount INTEGER DEFAULT 0,
        lastAttempt INTEGER DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE TABLE IF NOT EXISTS identity(pub BLOB, priv BLOB)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS contacts(
        id TEXT PRIMARY KEY,
        pub_key BLOB,
        shared_secret BLOB
      )
    ''');
  }

  static Future<List<Map<String, dynamic>>> getPendingMessages() async {
    final db = await database;
    return db.query(
      'messages',
      where: 'status = ?',
      whereArgs: ['pending'],
      orderBy: 'timestamp ASC',
    );
  }

  static Future<List<Map<String, dynamic>>> getPendingMessagesForConversation(
    String conversationId,
  ) async {
    final db = await database;
    return db.query(
      'messages',
      where: 'status = ? AND conversationId = ?',
      whereArgs: ['pending', conversationId],
      orderBy: 'timestamp ASC',
    );
  }

  static Future<void> saveIdentity(Uint8List pub, Uint8List priv) async {
    final db = await database;
    await db.delete('identity');
    await db.insert('identity', {'pub': pub, 'priv': priv});
  }

  static Future<Map<String, dynamic>?> getIdentity() async {
    final db = await database;
    final res = await db.query('identity', limit: 1);
    return res.isNotEmpty ? res.first : null;
  }

  static Future<void> saveContact(String id, Uint8List pubKey) async {
    final db = await database;
    await db.insert(
      'contacts',
      {'id': id, 'pub_key': pubKey},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> saveContactSharedSecret(
    String id,
    Uint8List sharedSecret,
  ) async {
    final db = await database;
    await db.insert(
      'contacts',
      {'id': id, 'shared_secret': sharedSecret},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await db.update(
      'contacts',
      {'shared_secret': sharedSecret},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<Uint8List?> getContactPubKey(String id) async {
    final db = await database;
    final res = await db.query('contacts', where: 'id = ?', whereArgs: [id]);
    return res.isNotEmpty ? res.first['pub_key'] as Uint8List : null;
  }

  static Future<Uint8List?> getContactSharedSecret(String id) async {
    final db = await database;
    final res = await db.query('contacts', where: 'id = ?', whereArgs: [id]);
    if (res.isEmpty) return null;
    final value = res.first['shared_secret'];
    return value is Uint8List ? value : null;
  }

  static Future<void> deleteContact(String id) async {
    final db = await database;
    await db.delete('contacts', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> insertMessage(Map<String, dynamic> message) async {
    final db = await database;
    await db.insert(
      'messages',
      message,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<void> updateStatus(String id, String status) async {
    final db = await database;
    await db.update(
      'messages',
      {'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<List<Map<String, dynamic>>> getAllMessages() async {
    final db = await database;
    return db.query('messages', orderBy: 'timestamp DESC');
  }

  static Future<List<Map<String, dynamic>>> getMessagesForConversation(
    String conversationId,
  ) async {
    final db = await database;
    return db.query(
      'messages',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
      orderBy: 'timestamp DESC',
    );
  }

  static Future<void> deleteMessage(String id) async {
    final db = await database;
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> incrementRetry(String id) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE messages SET retryCount = retryCount + 1 WHERE id = ?',
      [id],
    );
  }

  static Future<bool> messageExists(String id) async {
    final db = await database;
    final result = await db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [id],
    );
    return result.isNotEmpty;
  }

  static Future<Map<String, dynamic>?> getMessageById(String id) async {
    final db = await database;
    final result = await db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [id],
    );
    return result.isNotEmpty ? result.first : null;
  }

  static Future<void> markAttempt(String id) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE messages SET retryCount = retryCount + 1, lastAttempt = ? WHERE id = ?',
      [DateTime.now().millisecondsSinceEpoch, id],
    );
  }
}
