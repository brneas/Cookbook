import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../../../core/api/cookbook_api.dart';
import '../../../core/database/app_database.dart';
import '../../../core/database/library_guard.dart';
import '../../../core/errors/app_failure.dart';
import '../../recipes/domain/recipe.dart';
import '../../sync/data/read_sync.dart';

const infoBlocks = {
  'preparation-time': 'Preparation time',
  'cooking-time': 'Cooking time',
  'total-time': 'Total time',
  'nutrition-information': 'Nutrition information',
  'tools': 'Equipment',
};

class ServerCookbookSettings {
  const ServerCookbookSettings(this.data);
  final JsonMap data;
  String get folder => data['folder'] as String? ?? '';
  int get interval => data['update_interval'] is num
      ? (data['update_interval'] as num).toInt()
      : 5;
  bool get printImage =>
      data['print_image'] == true || data['print_image'] == 1;
  bool visible(String key) =>
      data['visibleInfoBlocks'] is! Map ||
      (data['visibleInfoBlocks'] as Map)[key] != false;
  JsonMap blockChange(String key, bool enabled) => {
    'visibleInfoBlocks': {
      if (data['visibleInfoBlocks'] is Map)
        ...(data['visibleInfoBlocks'] as Map).cast<String, Object?>(),
      key: enabled,
    },
  };
}

class ServerCookbookService {
  ServerCookbookService(this.database, this.api, this.account);
  final AppDatabase database;
  final CookbookApi api;
  final String account;
  Future<ServerCookbookSettings> cached() async {
    final rows = await database.db.query(
      'account_metadata',
      where: 'account_id=? AND key=?',
      whereArgs: [account, 'cookbook_config'],
    );
    return ServerCookbookSettings(
      rows.isEmpty
          ? {}
          : (jsonDecode(rows.single['value'] as String) as Map)
                .cast<String, Object?>(),
    );
  }

  Future<void> _cache(JsonMap value) async => database.db
      .insert('account_metadata', {
        'account_id': account,
        'key': 'cookbook_config',
        'value': jsonEncode(value),
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});
  Future<void> _begin(JsonMap operation) async {
    await database.db.transaction((tx) async {
      await ensureLibraryWritable(tx, account);
      if ((await tx.query(
        'pending_operations',
        where: "account_id=? AND state!='applied'",
        whereArgs: [account],
        limit: 1,
      )).isNotEmpty) {
        throw const AppFailure(FailureKind.libraryBusy);
      }
      await tx.insert('account_metadata', {
        'account_id': account,
        'key': 'library_operation',
        'value': jsonEncode(operation),
      });
    });
  }

  Future<ServerCookbookSettings> reload() => database.withSyncLock(_reload);
  Future<ServerCookbookSettings> _reload() async {
    final value = await api.configuration();
    if (value['folder'] is! String || value['update_interval'] is! num) {
      throw const AppFailure(FailureKind.malformedResponse);
    }
    final journal = await database.db.query(
      'account_metadata',
      where: 'account_id=? AND key=?',
      whereArgs: [account, 'library_operation'],
    );
    final old = await cached();
    final operation = journal.isEmpty
        ? null
        : jsonDecode(journal.single['value'] as String) as Map;
    final previousFolder = old.folder.isNotEmpty
        ? old.folder
        : operation?['old'];
    final folderChanged =
        previousFolder != null && previousFolder != value['folder'];
    if (folderChanged) {
      // A different recipe directory is a different namespace. Never upload an
      // old cached recipe to it; keep cooking snapshots independently.
      await database.db.transaction((tx) async {
        if ((await tx.query(
          'pending_operations',
          where: "account_id=? AND state!='applied'",
          whereArgs: [account],
          limit: 1,
        )).isNotEmpty) {
          throw const AppFailure(FailureKind.libraryBusy);
        }
        final prefix =
            'previous-folder:${DateTime.now().microsecondsSinceEpoch}:';
        for (final row in await tx.query(
          'cooking_sessions',
          where: 'account_id=?',
          whereArgs: [account],
        )) {
          final id = '$prefix${row['recipe_id']}';
          final data = (jsonDecode(row['state_json'] as String) as Map)
              .cast<String, Object?>();
          if (data['v'] == 1) data['recipeId'] = id;
          await tx.update(
            'cooking_sessions',
            {'recipe_id': id, 'state_json': jsonEncode(data)},
            where: 'account_id=? AND recipe_id=?',
            whereArgs: [account, row['recipe_id']],
          );
        }
        for (final table in [
          'pending_operations',
          'conflicts',
          'recipe_aliases',
          'image_cache',
          'recipes',
          'categories',
          'keywords',
        ]) {
          await tx.delete(table, where: 'account_id=?', whereArgs: [account]);
        }
      });
    }
    await _cache(value);
    if (operation != null || folderChanged) {
      await ReadSync(database, api, account).run();
    }
    await _cache(value);
    await database.db.delete(
      'account_metadata',
      where: 'account_id=? AND key=?',
      whereArgs: [account, 'library_operation'],
    );
    return ServerCookbookSettings(value);
  }

  Future<ServerCookbookSettings> update(JsonMap patch) =>
      database.withSyncLock(() async {
        await ensureLibraryWritable(database.db, account);
        if (patch.containsKey('update_interval') &&
            (patch['update_interval'] is! int ||
                (patch['update_interval'] as int) < 1)) {
          throw const AppFailure(FailureKind.malformedResponse);
        }
        if (patch.containsKey('folder')) {
          final old = await api.configuration();
          final folder = patch['folder'];
          if (folder is! String ||
              !folder.startsWith('/') ||
              folder.split('/').contains('..')) {
            throw const AppFailure(FailureKind.malformedResponse);
          }
          await _begin({
            'type': 'folder',
            'old': old['folder'],
            'requested': folder,
          });
        }
        await api.configure(patch);
        return _reload();
      });
  Future<void> rescan() => database.withSyncLock(() async {
    await ensureLibraryWritable(database.db, account);
    await api.reindex();
    await ReadSync(database, api, account).run();
  });
  Future<void> rename(String old, String name) =>
      database.withSyncLock(() async {
        if (old.isEmpty ||
            name.trim().isEmpty ||
            ['*', '_'].contains(name.trim())) {
          throw const AppFailure(FailureKind.malformedResponse);
        }
        await _begin({'type': 'rename', 'old': old, 'requested': name.trim()});
        await api.renameCategory(old, name.trim());
        await _reload();
      });
}
