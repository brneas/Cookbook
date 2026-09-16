import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../../../core/api/cookbook_api.dart';
import '../../../core/database/app_database.dart';
import '../../../core/errors/app_failure.dart';
import '../../recipes/domain/recipe.dart';
import '../domain/recipe_comparison.dart';
import 'mutation_store.dart';

/// Dispatches one operation at a time under the database-scoped coordinator lock.
/// A durable sending marker precedes each HTTP mutation; restart means unknown outcome.
class SyncEngine {
  SyncEngine(this.database, this.api, this.accountId, {this.onChanged});
  final void Function()? onChanged;
  final AppDatabase database;
  final CookbookApi api;
  final String accountId;
  Future<void> run({
    Future<void> Function()? readSync,
    bool Function()? shouldCancel,
  }) => database.withSyncLock(() async {
    await database.db.transaction((tx) async {
      await tx.update(
        'pending_operations',
        {'state': 'unknownOutcome'},
        where: "account_id=? AND state='sending'",
        whereArgs: [accountId],
      );
      await tx.rawUpdate(
        "UPDATE recipes SET sync_state='unknownOutcome' WHERE account_id=? AND EXISTS (SELECT 1 FROM pending_operations p WHERE p.account_id=recipes.account_id AND p.recipe_id=recipes.id AND p.state='unknownOutcome')",
        [accountId],
      );
    });
    List<Recipe>? listing;
    final blocked = <String>{};
    while (shouldCancel?.call() != true) {
      final operations = await database.db.query(
        'pending_operations',
        where: "account_id=? AND state!='applied'",
        whereArgs: [accountId],
        orderBy: 'id',
      );
      Map<String, Object?>? op;
      for (final candidate in operations) {
        final id = candidate['recipe_id'] as String;
        if (blocked.contains(id)) continue;
        if (['conflict', 'failed'].contains(candidate['state'])) {
          blocked.add(id);
          continue;
        }
        op = candidate;
        break;
      }
      if (op == null) break;
      final id = op['recipe_id'] as String;
      if (listing == null) {
        listing = await api.listRecipes();
        validateListing(listing);
      }
      final applied = await _process(op, listing);
      if (!applied) blocked.add(id);
    }
    if (shouldCancel?.call() != true) await readSync?.call();
  });

  Future<JsonMap?> _remote(String id) async {
    try {
      return (await api.recipe(id)).toJson();
    } on AppFailure catch (e) {
      if (e.kind == FailureKind.notFound) return null;
      rethrow;
    }
  }

  Future<bool> _process(Map<String, Object?> op, List<Recipe> listing) async {
    final id = op['recipe_id'] as String;
    final kind = op['kind'] as String;
    final base = decodeRecipe(op['base_json']);
    final payload = decodeRecipe(op['payload_json']);
    if (op['state'] == 'unknownOutcome') {
      if (kind == 'create' || kind == 'import') {
        if (kind == 'import' || op['before_ids_json'] == null) return false;
        final before = (jsonDecode(op['before_ids_json'] as String) as List)
            .cast<String>()
            .toSet();
        final matches = <JsonMap>[];
        for (final stub in listing.where(
          (r) => !before.contains(r.id) && r.name == payload?['name'],
        )) {
          final remote = await _remote(stub.id);
          if (remote != null && sameRecipe(remote, payload)) {
            matches.add(remote);
          }
        }
        if (matches.length != 1) return false;
        await _applied(op, matches.single);
        return true;
      }
      final remote = await _remote(id);
      if (kind == 'delete' && remote == null ||
          kind == 'update' && sameRecipe(remote, payload)) {
        await _applied(op, remote);
        return true;
      }
      if (sameRecipe(remote, base)) {
        await _state(op, 'failed', error: 'notApplied');
        return false;
      }
      await conflict(op, remote);
      return false;
    }
    if (kind == 'update' || kind == 'delete') {
      final remote = await _remote(id);
      if (remote == null && kind == 'delete') {
        await _applied(op, null);
        return true;
      }
      if (remote == null || !sameRecipe(base, remote)) {
        await conflict(op, remote);
        return false;
      }
    }
    // Snapshot the entire current ID set immediately before CREATE/import.
    final before = (kind == 'create' || kind == 'import')
        ? await api.listRecipes()
        : null;
    if (before != null) validateListing(before);
    await database.db.transaction((tx) async {
      await tx.update(
        'pending_operations',
        {
          'state': 'sending',
          if (before != null)
            'before_ids_json': jsonEncode(before.map((r) => r.id).toList()),
        },
        where: 'id=?',
        whereArgs: [op['id']],
      );
      await tx.update(
        'recipes',
        {'sync_state': 'sending'},
        where: 'account_id=? AND id=?',
        whereArgs: [accountId, id],
      );
    });
    JsonMap? result;
    onChanged?.call();
    try {
      if (kind == 'create') {
        final assigned = await api.create(Recipe.fromJson(payload!));
        // Persist the assigned identity before fetching a canonical server snapshot.
        result = {...payload, 'id': assigned};
      } else if (kind == 'update') {
        await api.update(id, Recipe.fromJson(payload!));
        result = {...payload, 'id': id};
      } else if (kind == 'delete') {
        await api.delete(id);
      } else {
        result = (await api.importUrl(
          Uri.parse(payload!['url'] as String),
        )).toJson();
      }
      await _applied(op, result);
      return true;
    } catch (error) {
      final failure = safeFailure(error);
      final rejected =
          error is AppFailure &&
          [400, 401, 403, 404, 409, 422].contains(error.status);
      await _state(
        op,
        rejected ? 'failed' : 'unknownOutcome',
        error: failure.kind.name,
      );
      return false;
    }
  }

  Future<void> _state(
    Map<String, Object?> op,
    String state, {
    String? error,
  }) async {
    await database.db.transaction((tx) async {
      await tx.update(
        'pending_operations',
        {'state': state, 'error_kind': error},
        where: 'id=?',
        whereArgs: [op['id']],
      );
      await tx.update(
        'recipes',
        {'sync_state': state},
        where: 'account_id=? AND id=?',
        whereArgs: [accountId, op['recipe_id']],
      );
    });
    onChanged?.call();
  }

  Future<void> conflict(Map<String, Object?> op, JsonMap? remote) async {
    await database.db.transaction((tx) async {
      final row = (await tx.query(
        'recipes',
        where: 'account_id=? AND id=?',
        whereArgs: [accountId, op['recipe_id']],
      )).single;
      await tx.insert('conflicts', {
        'account_id': accountId,
        'recipe_id': op['recipe_id'],
        'operation_id': op['id'],
        'kind': op['kind'],
        'base_json': op['base_json'],
        'local_json': row['detail_json'],
        'server_json': remote == null ? null : jsonEncode(remote),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await tx.update(
        'pending_operations',
        {'state': 'conflict'},
        where: 'id=?',
        whereArgs: [op['id']],
      );
      await tx.update(
        'recipes',
        {
          'sync_state': 'conflict',
          'server_json': remote == null ? null : jsonEncode(remote),
        },
        where: 'account_id=? AND id=?',
        whereArgs: [accountId, op['recipe_id']],
      );
    });
    onChanged?.call();
  }

  Future<void> _applied(Map<String, Object?> op, JsonMap? result) async {
    await database.db.transaction((tx) async {
      final oldId = op['recipe_id'] as String;
      final id = result == null ? oldId : '${result['id']}';
      if (id.isEmpty || id == 'null') {
        throw const AppFailure(FailureKind.malformedResponse);
      }
      if (id != oldId) {
        await tx.update(
          'recipe_aliases',
          {'server_id': id},
          where: 'account_id=? AND server_id=?',
          whereArgs: [accountId, oldId],
        );
        await tx.insert('recipe_aliases', {
          'account_id': accountId,
          'local_id': oldId,
          'server_id': id,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        // A server ID collision must never overwrite another cached recipe.
        final collision = await tx.query(
          'recipes',
          where: 'account_id=? AND id=?',
          whereArgs: [accountId, id],
        );
        if (collision.isNotEmpty) {
          if (collision.single['dirty'] != 0 ||
              !sameRecipe(
                decodeRecipe(collision.single['detail_json']),
                result,
              )) {
            throw const AppFailure(FailureKind.conflict);
          }
          // A read-sync may already have cached this exact newly created server recipe.
          // Retain it if it has local cooking state rather than discarding that state.
          final sessions = await tx.query(
            'cooking_sessions',
            where: 'account_id=? AND recipe_id=?',
            whereArgs: [accountId, id],
          );
          if (sessions.isNotEmpty) throw const AppFailure(FailureKind.conflict);
          await tx.delete(
            'recipes',
            where: 'account_id=? AND id=? AND dirty=0',
            whereArgs: [accountId, id],
          );
          await tx.delete(
            'image_cache',
            where: 'account_id=? AND recipe_id=?',
            whereArgs: [accountId, id],
          );
        }
        await tx.update(
          'recipes',
          {'id': id},
          where: 'account_id=? AND id=?',
          whereArgs: [accountId, oldId],
        );
        for (final table in [
          'pending_operations',
          'conflicts',
          'cooking_sessions',
          'image_cache',
        ]) {
          await tx.update(
            table,
            {'recipe_id': id},
            where: 'account_id=? AND recipe_id=?',
            whereArgs: [accountId, oldId],
          );
        }
        final pending = await tx.query(
          'pending_operations',
          where: 'account_id=? AND recipe_id=?',
          whereArgs: [accountId, id],
        );
        for (final next in pending) {
          for (final field in ['payload_json', 'base_json']) {
            final json = decodeRecipe(next[field]);
            if (json != null && json['id'] == oldId) {
              await tx.update(
                'pending_operations',
                {
                  field: jsonEncode({...json, 'id': id}),
                },
                where: 'id=?',
                whereArgs: [next['id']],
              );
            }
          }
        }
        final rows = await tx.query(
          'recipes',
          where: 'account_id=? AND id=?',
          whereArgs: [accountId, id],
        );
        final local = decodeRecipe(rows.single['detail_json']);
        if (local != null) {
          await tx.update(
            'recipes',
            {
              'detail_json': jsonEncode({...local, 'id': id}),
            },
            where: 'account_id=? AND id=?',
            whereArgs: [accountId, id],
          );
        }
        // Existing session/timer snapshots retain all fields while remapping explicit ID keys.
        Object? remap(Object? value) {
          if (value is Map) {
            return {
              for (final e in value.entries)
                e.key: e.key == 'snapshot'
                    ? e.value
                    : ({'recipeId', 'recipe_id', 'id'}.contains(e.key) &&
                          e.value == oldId)
                    ? id
                    : remap(e.value),
            };
          }
          if (value is List) return value.map(remap).toList();
          return value;
        }

        for (final table in ['cooking_sessions', 'timers']) {
          for (final row in await tx.query(
            table,
            where: 'account_id=?',
            whereArgs: [accountId],
          )) {
            await tx.update(
              table,
              {
                'state_json': jsonEncode(
                  remap(jsonDecode(row['state_json'] as String)),
                ),
              },
              where: table == 'timers'
                  ? 'account_id=? AND id=?'
                  : 'account_id=? AND recipe_id=?',
              whereArgs: [
                accountId,
                row[table == 'timers' ? 'id' : 'recipe_id'],
              ],
            );
          }
        }
      }
      await tx.update(
        'pending_operations',
        {
          'state': 'applied',
          'result_json': result == null ? null : jsonEncode(result),
          'error_kind': null,
        },
        where: 'id=?',
        whereArgs: [op['id']],
      );
      final remaining = await tx.query(
        'pending_operations',
        where: "account_id=? AND recipe_id=? AND state!='applied'",
        whereArgs: [accountId, id],
        orderBy: 'id',
      );
      if (result == null) {
        await tx.update(
          'recipes',
          {'remote_state': 'deleted', 'sync_state': 'clean', 'dirty': 0},
          where: 'account_id=? AND id=?',
          whereArgs: [accountId, id],
        );
      } else if (remaining.isEmpty) {
        await writeServer(tx, accountId, id, result);
      } else {
        await tx.update(
          'recipes',
          {
            'server_json': jsonEncode(result),
            'base_json': jsonEncode(result),
            'sync_state': remaining.first['state'],
          },
          where: 'account_id=? AND id=?',
          whereArgs: [accountId, id],
        );
        // The next edit was based on the just-applied intent; carry its confirmed base forward.
        await tx.update(
          'pending_operations',
          {'base_json': jsonEncode(result)},
          where: 'id=?',
          whereArgs: [remaining.first['id']],
        );
      }
      await tx.delete(
        'image_cache',
        where: 'account_id=? AND recipe_id=?',
        whereArgs: [accountId, id],
      );
    });
    onChanged?.call();
  }

  Future<void> attachUnknown(
    int operationId,
    String serverId, {
    Recipe? inspectedRecipe,
  }) => database.withSyncLock(() async {
    final op = (await database.db.query(
      'pending_operations',
      where:
          "account_id=? AND id=? AND state='unknownOutcome' AND kind IN ('create','import')",
      whereArgs: [accountId, operationId],
    )).single;
    final remote = await api.recipe(serverId);
    if (inspectedRecipe != null &&
        !sameRecipe(inspectedRecipe.toJson(), remote.toJson())) {
      throw const AppFailure(FailureKind.conflict);
    }
    await _applied(op, remote.toJson());
  });
}

void validateListing(List<Recipe> listing) {
  if (listing.any((r) => r.id.isEmpty || r.name.isEmpty) ||
      listing.map((r) => r.id).toSet().length != listing.length) {
    throw const AppFailure(FailureKind.malformedResponse);
  }
}
