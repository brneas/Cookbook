import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/providers.dart';
import '../../../core/errors/app_failure.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/data/image_cache.dart';
import '../data/mutation_store.dart';
import '../../recipes/data/library_repository.dart';

final mutationStoreProvider = FutureProvider<MutationStore>((ref) async {
  final account = await ref.watch(accountProvider.future);
  if (account == null) throw const AppFailure(FailureKind.authentication);
  return MutationStore(await ref.watch(databaseProvider.future), account.id);
});
final recipeRecordProvider = FutureProvider.autoDispose
    .family<Map<String, Object?>?, String>((ref, id) async {
      final account = await ref.watch(accountProvider.future);
      ref.watch(syncProvider.select((s) => s.revision));
      if (account == null) return null;
      final db = await ref.watch(databaseProvider.future);
      final realId = await db.resolveId(account.id, id);
      final rows = await db.db.query(
        'recipes',
        where: 'account_id=? AND id=?',
        whereArgs: [account.id, realId],
      );
      if (rows.isEmpty) return null;
      final importing = await db.db.query(
        'pending_operations',
        columns: ['id'],
        where:
            "account_id=? AND recipe_id=? AND kind='import' AND state!='applied'",
        whereArgs: [account.id, realId],
        limit: 1,
      );
      return {...rows.single, 'import_pending': importing.isNotEmpty};
    });
final conflictProvider = FutureProvider.autoDispose
    .family<Map<String, Object?>?, String>((ref, id) async {
      final account = await ref.watch(accountProvider.future);
      ref.watch(syncProvider.select((s) => s.revision));
      if (account == null) return null;
      final db = await ref.watch(databaseProvider.future);
      final rows = await db.db.query(
        'conflicts',
        where: 'account_id=? AND recipe_id=?',
        whereArgs: [account.id, id],
      );
      return rows.isEmpty ? null : rows.single;
    });
final operationsProvider = FutureProvider.autoDispose<List<Map<String, Object?>>>((
  ref,
) async {
  final account = await ref.watch(accountProvider.future);
  ref.watch(syncProvider.select((s) => s.revision));
  if (account == null) return [];
  final db = await ref.watch(databaseProvider.future);
  return db.db.rawQuery(
    "SELECT p.*,r.name FROM pending_operations p LEFT JOIN recipes r ON p.account_id=r.account_id AND p.recipe_id=r.id WHERE p.account_id=? AND p.state!='applied' ORDER BY p.id",
    [account.id],
  );
});
final taxonomyProvider = FutureProvider<Map<String, List<String>>>((ref) async {
  final account = await ref.watch(accountProvider.future);
  ref.watch(syncProvider.select((s) => s.revision));
  if (account == null) return {};
  final db = await ref.watch(databaseProvider.future);
  return LibraryRepository(db, account.id).taxonomy();
});
final diagnosticsProvider = FutureProvider.autoDispose<Map<String, Object?>>((
  ref,
) async {
  final account = await ref.watch(accountProvider.future);
  ref.watch(syncProvider.select((s) => s.revision));
  if (account == null) return {};
  final db = await ref.watch(databaseProvider.future);
  Future<int> count(String table, String suffix) async =>
      (await db.db.rawQuery(
            'SELECT COUNT(*) AS n FROM $table WHERE account_id=? $suffix',
            [account.id],
          )).single['n']
          as int;
  final metadata = await db.db.query(
    'sync_metadata',
    where: 'account_id=?',
    whereArgs: [account.id],
  );
  final accounts = await db.db.query(
    'accounts',
    where: 'id=?',
    whereArgs: [account.id],
  );
  final caps = jsonDecode(accounts.single['capabilities'] as String) as Map;
  final connection = await db.db.query(
    'account_metadata',
    where: 'account_id=?',
    whereArgs: [account.id],
  );
  return {
    for (final item in connection) item['key'] as String: item['value'],
    ...?metadata.firstOrNull,
    'local_count': await count('recipes', "AND remote_state!='deleted'"),
    'pending_count': await count(
      'pending_operations',
      "AND state IN ('queued','sending','failed')",
    ),
    'conflict_count': await count('conflicts', ''),
    'uncertain_count': await count(
      'pending_operations',
      "AND state='unknownOutcome'",
    ),
    'cache_bytes': await ImageCacheStore(db, account.id).size(),
    'cache_limit': await ImageCacheStore(db, account.id).limit(),
    'detected': caps.isNotEmpty,
    'app_version': caps['appVersion'],
    'api_version': caps.isEmpty
        ? 'Not verified'
        : '${caps['epoch']}.${caps['major']}.${caps['minor']}',
    'capabilities': caps.isEmpty
        ? 'Unavailable'
        : 'External recipes, categories, keywords, config, import',
  };
});
String syncLabel(Map<String, Object?> row) => switch (row['sync_state']) {
  'queued' => 'Saved locally · waiting for sync',
  'sending' => 'Uploading…',
  'unknownOutcome' => 'Upload outcome uncertain · review in Settings',
  'conflict' => 'Conflict · review versions',
  'failed' => 'Sync failed · review in Settings',
  _ =>
    row['remote_state'] == 'deleted'
        ? 'Removed on server'
        : row['remote_state'] == 'suspected'
        ? 'Not in last server listing · retained offline'
        : 'Synced',
};
Recipe recipeFromRow(Map<String, Object?> row) => Recipe.fromJson(
  (jsonDecode((row['detail_json'] ?? row['stub_json']) as String) as Map)
      .cast<String, Object?>(),
);
