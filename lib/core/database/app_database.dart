import 'dart:convert';
import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../../features/recipes/domain/recipe.dart';
import 'migrations.dart';

/// Account deletion cascades to every account-owned row. Credentials never enter SQL.
final class AppDatabase {
  AppDatabase(this.db);
  final Database db;
  Future<void> _syncTail = Future.value();
  Future<T> withSyncLock<T>(Future<T> Function() action) async {
    final previous = _syncTail;
    final done = Completer<void>();
    _syncTail = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
    }
  }

  static Future<AppDatabase> open({
    DatabaseFactory? factory,
    String? path,
  }) async {
    final f = factory ?? databaseFactory;
    final location =
        path ?? p.join(await f.getDatabasesPath(), 'cookbook.sqlite');
    final db = await f.openDatabase(
      location,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) async {
          for (final statement in schema) {
            await db.execute(statement);
          }
          await migrateDatabase(db, 1, schemaVersion);
        },
        onUpgrade: migrateDatabase,
        onDowngrade: (db, oldVersion, newVersion) async =>
            throw StateError('Database downgrade is not supported'),
      ),
    );
    return AppDatabase(db);
  }

  static const schemaVersion = 6;
  Future<String> resolveId(String account, String id) async {
    final rows = await db.query(
      'recipe_aliases',
      where: 'account_id=? AND local_id=?',
      whereArgs: [account, id],
    );
    return rows.isEmpty ? id : rows.single['server_id'] as String;
  }

  static const schema = [
    'CREATE TABLE accounts (id TEXT PRIMARY KEY, server TEXT NOT NULL, login_name TEXT NOT NULL, capabilities TEXT NOT NULL, removing INTEGER NOT NULL DEFAULT 0)',
    '''CREATE TABLE recipes (account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      id TEXT NOT NULL, name TEXT NOT NULL, category TEXT NOT NULL DEFAULT '', keywords TEXT NOT NULL DEFAULT '',
      stub_json TEXT NOT NULL, detail_json TEXT, server_modified TEXT, base_json TEXT,
      dirty INTEGER NOT NULL DEFAULT 0, missing INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (account_id, id))''',
    'CREATE INDEX recipe_name ON recipes(account_id, name COLLATE NOCASE)',
    'CREATE INDEX recipe_category ON recipes(account_id, category)',
    'CREATE TABLE categories (account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, name TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY(account_id,name))',
    'CREATE TABLE keywords (account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, name TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY(account_id,name))',
    'CREATE TABLE image_cache (account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, recipe_id TEXT NOT NULL, size TEXT NOT NULL, modified TEXT, bytes BLOB NOT NULL, PRIMARY KEY(account_id,recipe_id,size))',
    '''CREATE TABLE pending_operations (id INTEGER PRIMARY KEY AUTOINCREMENT, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      recipe_id TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('create','update','delete')), base_json TEXT, payload_json TEXT,
      state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','sending','uncertain','conflict')), created_at TEXT NOT NULL)''',
    'CREATE TABLE conflicts (account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, recipe_id TEXT NOT NULL, local_json TEXT, server_json TEXT, PRIMARY KEY(account_id,recipe_id))',
    'CREATE TABLE sync_metadata (account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE, last_success TEXT, status TEXT NOT NULL, last_error TEXT)',
    'CREATE TABLE cooking_sessions (account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, recipe_id TEXT NOT NULL, state_json TEXT NOT NULL, PRIMARY KEY(account_id,recipe_id))',
    'CREATE TABLE timers (id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, state_json TEXT NOT NULL)',
    'CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  ];
  Future<List<Recipe>> recipes(
    String accountId, {
    String query = '',
    String? category,
  }) async {
    final escaped = query
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    final rows = await db.query(
      'recipes',
      where:
          "account_id = ? AND local_deleted = 0 AND remote_state != 'deleted' AND (name LIKE ? ESCAPE '\\' OR keywords LIKE ? ESCAPE '\\')${category == null ? '' : ' AND category = ?'}",
      whereArgs: [accountId, '%$escaped%', '%$escaped%', ?category],
      orderBy: 'name COLLATE NOCASE',
    );
    return rows
        .map(
          (r) => Recipe.fromJson(
            (jsonDecode((r['detail_json'] ?? r['stub_json']) as String) as Map)
                .cast<String, Object?>(),
          ),
        )
        .toList();
  }

  Future<void> removeAccount(String accountId) => withSyncLock(() async {
    await db.transaction((tx) async {
      await tx.delete(
        'preferences',
        where: 'key=?',
        whereArgs: ['imageLimit.$accountId'],
      );
      await tx.delete('accounts', where: 'id = ?', whereArgs: [accountId]);
    });
  });

  Future<void> close() => db.close();
}
