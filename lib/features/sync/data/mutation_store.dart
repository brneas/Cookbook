import 'dart:convert';
import 'dart:math';
import 'package:sqflite/sqflite.dart';
import '../../../core/database/app_database.dart';
import '../../../core/database/library_guard.dart';
import '../../../core/errors/app_failure.dart';
import '../../recipes/domain/recipe.dart';
import '../domain/recipe_comparison.dart';

String localRecipeId() =>
    'local:${base64UrlEncode(List.generate(24, (_) => Random.secure().nextInt(256)))}';

/// All local changes and their queue entries commit together, including conflict decisions.
class MutationStore {
  MutationStore(this.database, this.accountId);
  final AppDatabase database;
  final String accountId;
  Future<String> queueImport(Uri url) async {
    if (!['https', 'http'].contains(url.scheme) ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty) {
      throw const AppFailure(FailureKind.invalidUrl);
    }
    final id = localRecipeId();
    final placeholder = {
      'id': id,
      'name': 'Import from ${url.host}',
      'url': url.toString(),
    };
    await database.db.transaction((tx) async {
      await ensureLibraryWritable(tx, accountId);
      await tx.insert('recipes', {
        'account_id': accountId,
        'id': id,
        'name': placeholder['name'],
        'stub_json': jsonEncode(placeholder),
        'detail_json': jsonEncode(placeholder),
        'dirty': 1,
        'sync_state': 'queued',
      });
      await tx.insert('pending_operations', {
        'account_id': accountId,
        'recipe_id': id,
        'kind': 'import',
        'payload_json': jsonEncode({'url': url.toString()}),
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
    return id;
  }

  Future<void> retryFailed(int operationId) =>
      database.withSyncLock(() => _retryFailed(operationId));
  Future<void> _retryFailed(int operationId) async {
    await database.db.transaction((tx) async {
      await ensureLibraryWritable(tx, accountId);
      final rows = await tx.query(
        'pending_operations',
        where: "account_id=? AND id=? AND state='failed'",
        whereArgs: [accountId, operationId],
      );
      if (rows.isEmpty) throw const AppFailure(FailureKind.conflict);
      await tx.update(
        'pending_operations',
        {'state': 'queued', 'error_kind': null},
        where: 'id=?',
        whereArgs: [operationId],
      );
      await tx.update(
        'recipes',
        {'sync_state': 'queued'},
        where: 'account_id=? AND id=?',
        whereArgs: [accountId, rows.single['recipe_id']],
      );
    });
  }

  Future<String> save(
    Recipe recipe, {
    bool create = false,
    Recipe? expectedRecipe,
  }) async {
    if (recipe.name.trim().isEmpty) {
      throw const AppFailure(FailureKind.malformedResponse);
    }
    var id = create ? localRecipeId() : recipe.id;
    await database.db.transaction((tx) async {
      await ensureLibraryWritable(tx, accountId);
      if (!create) {
        final aliases = await tx.query(
          'recipe_aliases',
          where: 'account_id=? AND local_id=?',
          whereArgs: [accountId, id],
        );
        if (aliases.isNotEmpty) id = aliases.single['server_id'] as String;
      }
      final rows = await tx.query(
        'recipes',
        where: 'account_id=? AND id=?',
        whereArgs: [accountId, id],
      );
      if (!create && rows.isEmpty) throw const AppFailure(FailureKind.notFound);
      final row = rows.isEmpty ? null : rows.single;
      if (expectedRecipe != null &&
          row != null &&
          !sameRecipe(
            expectedRecipe.toJson(),
            decodeRecipe(row['detail_json']),
          )) {
        throw const AppFailure(FailureKind.conflict);
      }
      if (row != null &&
          (row['local_deleted'] == 1 ||
              row['remote_state'] == 'deleted' ||
              ['conflict', 'unknownOutcome'].contains(row['sync_state']))) {
        throw const AppFailure(FailureKind.conflict);
      }
      final prior = await tx.query(
        'pending_operations',
        where: "account_id=? AND recipe_id=? AND state!='applied'",
        whereArgs: [accountId, id],
        orderBy: 'id DESC',
        limit: 1,
      );
      if (prior.any((op) => op['kind'] == 'import')) {
        throw const AppFailure(FailureKind.conflict);
      }
      final base = prior.isNotEmpty
          ? prior.first['payload_json']
          : row?['server_json'] ?? row?['base_json'] ?? row?['detail_json'];
      final json = recipe.patch({'id': id}).toJson();
      final values = {
        'name': recipe.name,
        'category': recipe.category,
        'keywords': recipe.keywords.join(','),
        'detail_json': jsonEncode(json),
        'stub_json': jsonEncode(json),
        'dirty': 1,
        'sync_state': 'queued',
        'local_deleted': 0,
      };
      if (create) {
        await tx.insert('recipes', {
          'account_id': accountId,
          'id': id,
          ...values,
        });
      } else {
        await tx.update(
          'recipes',
          values,
          where: 'account_id=? AND id=?',
          whereArgs: [accountId, id],
        );
      }
      await tx.insert('pending_operations', {
        'account_id': accountId,
        'recipe_id': id,
        'kind': create ? 'create' : 'update',
        'base_json': base,
        'payload_json': jsonEncode(json),
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
    return id;
  }

  Future<void> delete(String id) async {
    await database.db.transaction((tx) async {
      await ensureLibraryWritable(tx, accountId);
      final rows = await tx.query(
        'recipes',
        where: 'account_id=? AND id=?',
        whereArgs: [accountId, id],
      );
      if (rows.isEmpty) throw const AppFailure(FailureKind.notFound);
      final row = rows.single;
      if (['conflict', 'unknownOutcome'].contains(row['sync_state'])) {
        throw const AppFailure(FailureKind.conflict);
      }
      if (row['local_deleted'] == 1) return;
      final prior = await tx.query(
        'pending_operations',
        where: "account_id=? AND recipe_id=? AND state!='applied'",
        whereArgs: [accountId, id],
        orderBy: 'id DESC',
        limit: 1,
      );
      await tx.insert('pending_operations', {
        'account_id': accountId,
        'recipe_id': id,
        'kind': 'delete',
        'base_json': prior.isNotEmpty
            ? prior.first['payload_json']
            : row['server_json'] ?? row['base_json'] ?? row['detail_json'],
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      await tx.update(
        'recipes',
        {'dirty': 1, 'sync_state': 'queued', 'local_deleted': 1},
        where: 'account_id=? AND id=?',
        whereArgs: [accountId, id],
      );
    });
  }

  Future<void> undoDelete(String id) =>
      database.withSyncLock(() => _undoDelete(id));
  Future<void> _undoDelete(String id) async {
    await database.db.transaction((tx) async {
      await ensureLibraryWritable(tx, accountId);
      final rows = await tx.query(
        'pending_operations',
        where:
            "account_id=? AND recipe_id=? AND kind='delete' AND state='queued'",
        whereArgs: [accountId, id],
      );
      if (rows.isEmpty) throw const AppFailure(FailureKind.conflict);
      await tx.delete(
        'pending_operations',
        where:
            "account_id=? AND recipe_id=? AND kind='delete' AND state='queued'",
        whereArgs: [accountId, id],
      );
      final pending = await tx.query(
        'pending_operations',
        where: "account_id=? AND recipe_id=? AND state!='applied'",
        whereArgs: [accountId, id],
      );
      await tx.update(
        'recipes',
        {
          'local_deleted': 0,
          'dirty': pending.isEmpty ? 0 : 1,
          'sync_state': pending.isEmpty ? 'clean' : pending.first['state'],
        },
        where: 'account_id=? AND id=?',
        whereArgs: [accountId, id],
      );
    });
  }

  Future<void> resolve(String id, {required bool keepLocal}) =>
      database.withSyncLock(() => _resolve(id, keepLocal: keepLocal));
  Future<void> _resolve(String id, {required bool keepLocal}) async {
    await database.db.transaction((tx) async {
      await ensureLibraryWritable(tx, accountId);
      final conflicts = await tx.query(
        'conflicts',
        where: 'account_id=? AND recipe_id=?',
        whereArgs: [accountId, id],
      );
      if (conflicts.isEmpty) return;
      final conflict = conflicts.single;
      final server = decodeRecipe(conflict['server_json']);
      final rows = await tx.query(
        'recipes',
        where: 'account_id=? AND id=?',
        whereArgs: [accountId, id],
      );
      final local = decodeRecipe(rows.single['detail_json']);
      final deleting = rows.single['local_deleted'] == 1;
      await tx.update(
        'pending_operations',
        {'state': 'applied', 'error_kind': 'resolved'},
        where: "account_id=? AND recipe_id=? AND state!='applied'",
        whereArgs: [accountId, id],
      );
      await tx.delete(
        'conflicts',
        where: 'account_id=? AND recipe_id=?',
        whereArgs: [accountId, id],
      );
      if (!keepLocal) {
        if (server == null) {
          await tx.update(
            'recipes',
            {
              'remote_state': 'deleted',
              'local_deleted': 0,
              'sync_state': 'clean',
              'dirty': 0,
            },
            where: 'account_id=? AND id=?',
            whereArgs: [accountId, id],
          );
        } else {
          await writeServer(tx, accountId, id, server);
        }
      } else if (deleting && server == null) {
        await tx.update(
          'recipes',
          {'remote_state': 'deleted', 'sync_state': 'clean', 'dirty': 0},
          where: 'account_id=? AND id=?',
          whereArgs: [accountId, id],
        );
      } else {
        await tx.insert('pending_operations', {
          'account_id': accountId,
          'recipe_id': id,
          'kind': deleting
              ? 'delete'
              : server == null
              ? 'create'
              : 'update',
          'base_json': server == null ? null : jsonEncode(server),
          'payload_json': local == null ? null : jsonEncode(local),
          'created_at': DateTime.now().toUtc().toIso8601String(),
        });
        await tx.update(
          'recipes',
          {
            'dirty': 1,
            'sync_state': 'queued',
            'remote_state': 'present',
            'server_json': server == null ? null : jsonEncode(server),
          },
          where: 'account_id=? AND id=?',
          whereArgs: [accountId, id],
        );
      }
    });
  }
}

Future<void> writeServer(
  DatabaseExecutor tx,
  String account,
  String id,
  JsonMap json,
) async {
  final recipe = Recipe.fromJson(json);
  await tx.update(
    'recipes',
    {
      'name': recipe.name,
      'category': recipe.category,
      'keywords': recipe.keywords.join(','),
      'detail_json': jsonEncode(json),
      'stub_json': jsonEncode(json),
      'server_json': jsonEncode(json),
      'base_json': jsonEncode(json),
      'server_modified': recipe.modified?.toIso8601String(),
      'dirty': 0,
      'sync_state': 'clean',
      'remote_state': 'present',
      'local_deleted': 0,
      'missing': 0,
    },
    where: 'account_id=? AND id=?',
    whereArgs: [account, id],
  );
}
