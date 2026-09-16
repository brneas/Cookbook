import 'dart:convert';
import '../../../core/runtime_diagnostics.dart';
import 'package:sqflite/sqflite.dart';
import '../../../core/api/cookbook_api.dart';
import '../../../core/database/app_database.dart';
import '../../../core/errors/app_failure.dart';
import '../../recipes/domain/recipe.dart';
import 'sync_engine.dart';

/// Conservative, progressive read sync. No server writes and no local mass deletion.
final class ReadSync {
  ReadSync(this.database, this.api, this.accountId);
  final AppDatabase database;
  final CookbookApi api;
  final String accountId;
  Future<void> run({
    void Function(int completed, int total)? onProgress,
    bool Function()? shouldCancel,
    void Function(Set<String> imageIds)? onChanged,
  }) async {
    final db = database.db;
    final timer = Stopwatch()..start();
    var inserted = 0, updated = 0, removed = 0, requests = 0, listingMs = 0;
    final imageIds = <String>{};
    var summariesChanged = false;
    await db.insert('sync_metadata', {
      'account_id': accountId,
      'status': 'syncing',
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.update(
      'sync_metadata',
      {
        'status': 'syncing',
        'last_error': null,
        'last_attempt': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
    try {
      final listingTimer = Stopwatch()..start();
      requests++;
      final stubs = await api.listRecipes();
      listingMs = listingTimer.elapsedMilliseconds;
      validateListing(stubs);
      if (shouldCancel?.call() == true) {
        throw const AppFailure(FailureKind.cancelled);
      }
      if (stubs.any((r) => r.id.isEmpty) ||
          stubs.map((r) => r.id).toSet().length != stubs.length) {
        throw const AppFailure(FailureKind.malformedResponse);
      }
      final prior = {
        for (final row in await db.query(
          'recipes',
          where: 'account_id = ?',
          whereArgs: [accountId],
        ))
          row['id'] as String: row,
      };
      // Entire listing has been parsed before changing any membership metadata.
      await db.transaction((tx) async {
        final presentIds = stubs.map((s) => s.id).toSet();
        for (final old in prior.values) {
          if (!presentIds.contains(old['id']) &&
              !(old['id'] as String).startsWith('local:') &&
              old['remote_state'] == 'present') {
            await tx.update(
              'recipes',
              {'missing': 1, 'remote_state': 'suspected'},
              where: 'account_id=? AND id=?',
              whereArgs: [accountId, old['id']],
            );
            summariesChanged = true;
          }
        }
        for (final stub in stubs) {
          final old = prior[stub.id];
          if (old != null &&
              (old['remote_state'] != 'present' || old['missing'] != 0)) {
            await tx.update(
              'recipes',
              {'missing': 0, 'remote_state': 'present'},
              where: 'account_id=? AND id=?',
              whereArgs: [accountId, stub.id],
            );
            summariesChanged = true;
          }
          if (old?['dirty'] == 1) continue;
          final values = <String, Object?>{
            'name': stub.name,
            'keywords': stub.keywords.join(','),
            if (stub.toJson().containsKey('recipeCategory'))
              'category': stub.category,
            'stub_json': jsonEncode(stub.toJson()),
            'missing': 0,
          };
          if (old == null) {
            inserted++;
            summariesChanged = true;
            await tx.insert('recipes', {
              'account_id': accountId,
              'id': stub.id,
              ...values,
            });
          } else if (values.entries.any(
            (entry) => old[entry.key] != entry.value,
          )) {
            summariesChanged = true;
            await tx.update(
              'recipes',
              values,
              where: 'account_id = ? AND id = ?',
              whereArgs: [accountId, stub.id],
            );
          }
        }
      });
      if (summariesChanged) onChanged?.call({});
      onProgress?.call(0, stubs.length);
      final ids = stubs.map((r) => r.id).toSet();
      for (final old in prior.values.where(
        (r) =>
            !ids.contains(r['id']) &&
            r['remote_state'] == 'suspected' &&
            !(r['id'] as String).startsWith('local:'),
      )) {
        try {
          requests++;
          await api.recipe(old['id'] as String);
        } on AppFailure catch (error) {
          if (error.kind != FailureKind.notFound) rethrow;
          if (old['dirty'] == 1) {
            final ops = await db.query(
              'pending_operations',
              where: "account_id=? AND recipe_id=? AND state!='applied'",
              whereArgs: [accountId, old['id']],
              orderBy: 'id',
              limit: 1,
            );
            if (ops.isNotEmpty) {
              await SyncEngine(
                database,
                api,
                accountId,
              ).conflict(ops.first, null);
            }
          } else {
            removed++;
            imageIds.add(old['id'] as String);
            await db.transaction((tx) async {
              await tx.update(
                'recipes',
                {'remote_state': 'deleted'},
                where: 'account_id=? AND id=? AND dirty=0',
                whereArgs: [accountId, old['id']],
              );
              await tx.delete(
                'image_cache',
                where: 'account_id=? AND recipe_id=?',
                whereArgs: [accountId, old['id']],
              );
            });
          }
        }
      }
      var completed = 0;
      for (final stub in stubs) {
        if (shouldCancel?.call() == true) {
          throw const AppFailure(FailureKind.cancelled);
        }
        final old = prior[stub.id];
        final oldModified = parseRecipeDate(old?['server_modified']);
        final changed =
            old?['detail_json'] == null ||
            oldModified == null ||
            stub.modified == null ||
            oldModified != stub.modified;
        if (old?['dirty'] != 1 && changed) {
          requests++;
          final detail = await api.recipe(stub.id);
          final encoded = jsonEncode(detail.toJson());
          final detailChanged = old?['detail_json'] != encoded;
          if (!detailChanged &&
              old?['server_modified'] == stub.modified?.toIso8601String()) {
            completed++;
            continue;
          }
          if (detailChanged) {
            updated++;
            imageIds.add(stub.id);
          }
          await db.transaction((tx) async {
            await tx.update(
              'recipes',
              {
                'name': detail.name,
                'category': detail.category,
                'keywords': detail.keywords.join(','),
                'detail_json': jsonEncode(detail.toJson()),
                'base_json': jsonEncode(detail.toJson()),
                'server_json': jsonEncode(detail.toJson()),
                'server_modified': stub.modified?.toIso8601String(),
              },
              where: 'account_id = ? AND id = ? AND dirty = 0',
              whereArgs: [accountId, stub.id],
            );
            if (detailChanged) {
              await tx.delete(
                'image_cache',
                where: 'account_id = ? AND recipe_id = ?',
                whereArgs: [accountId, stub.id],
              );
            }
          });
        }
        completed++;
        if (completed % 25 == 0 || completed == stubs.length) {
          if (imageIds.isNotEmpty) {
            onChanged?.call(Set.of(imageIds));
            imageIds.clear();
          }
          onProgress?.call(completed, stubs.length);
        }
      }
      if (imageIds.isNotEmpty) {
        onChanged?.call(Set.of(imageIds));
        imageIds.clear();
      }
      requests += 2;
      final categories = await api.categories();
      final keywords = await api.keywords();
      for (final item in [...categories, ...keywords]) {
        if (item['name'] is! String || item['recipe_count'] is! int) {
          throw const AppFailure(FailureKind.malformedResponse);
        }
      }
      await db.transaction((tx) async {
        for (final entry in {
          'categories': categories,
          'keywords': keywords,
        }.entries) {
          await tx.delete(
            entry.key,
            where: 'account_id = ?',
            whereArgs: [accountId],
          );
          for (final item in entry.value) {
            await tx.insert(entry.key, {
              'account_id': accountId,
              'name': item['name'],
              'count': item['recipe_count'],
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
        await tx.update(
          'sync_metadata',
          {
            'status': 'ready',
            'last_success': DateTime.now().toUtc().toIso8601String(),
            'last_error': null,
            'server_count': stubs.length,
          },
          where: 'account_id = ?',
          whereArgs: [accountId],
        );
      });
      RuntimeDiagnostics.event('read sync', {
        'durationMs': timer.elapsedMilliseconds,
        'listingMs': listingMs,
        'inserted': inserted,
        'updated': updated,
        'removed': removed,
        'thumbnailInvalidations': updated + removed,
        'requests': requests,
      });
    } catch (error) {
      if (imageIds.isNotEmpty) onChanged?.call(Set.of(imageIds));
      final failure = safeFailure(error);
      await db.update(
        'sync_metadata',
        {'status': 'failed', 'last_error': failure.kind.name},
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
      throw failure;
    }
  }
}
