import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cookbook/core/database/app_database.dart';
import 'package:cookbook/core/database/migrations.dart';
import 'package:cookbook/features/cooking/data/cooking_repository.dart';
import 'package:cookbook/features/cooking/domain/quantities.dart';
import 'package:cookbook/features/recipes/domain/recipe.dart';

void main() {
  sqfliteFfiInit();
  late AppDatabase db;
  late CookingRepository repo;
  late DateTime now;
  final recipe = Recipe.fromJson({
    'id': '42',
    'name': 'Bread',
    'recipeYield': '4 servings',
    'recipeIngredient': ['1 cup milk', 'salt to taste'],
    'recipeInstructions': [
      {
        '@type': 'HowToSection',
        'name': 'Dough',
        'itemListElement': [
          {'@type': 'HowToStep', 'text': 'Mix.'},
          'Rest 20 minutes.',
        ],
      },
    ],
  });
  setUp(() async {
    now = DateTime.utc(2026);
    db = await AppDatabase.open(
      factory: databaseFactoryFfiNoIsolate,
      path: inMemoryDatabasePath,
    );
    await db.db.insert('accounts', {
      'id': 'a',
      'server': 'https://cloud.test',
      'login_name': 'cook',
      'capabilities': '{}',
    });
    repo = CookingRepository(db, 'a', now: () => now);
  });
  tearDown(() async => db.close());
  test(
    'create resume persist checks steps servings and reset without touching recipe or queue',
    () async {
      final original = jsonEncode(recipe.toJson());
      final s = await repo.start(recipe);
      await repo.check(s.id, 'ingredients', 0);
      await repo.check(s.id, 'steps', 0);
      await repo.updateSession(s.id, (_) => {'current': 1});
      await repo.scale(s.id, Rational(3, 2));
      repo = CookingRepository(db, 'a', now: () => now);
      final restored = await repo.start(recipe);
      expect(restored.id, s.id);
      expect(restored.current, 1);
      expect(restored.checks('ingredients'), {0});
      expect(restored.checks('steps'), {0});
      expect(restored.multiplier.wire, '3/2');
      expect(restored.steps.first.sections, ['Dough']);
      await repo.reset(s.id);
      final reset = (await repo.sessions()).single;
      expect(reset.current, 0);
      expect(reset.checks('steps'), isEmpty);
      expect(reset.multiplier.wire, '3/2');
      expect(jsonEncode(recipe.toJson()), original);
      expect(await db.db.query('pending_operations'), isEmpty);
    },
  );
  test(
    'snapshot survives updates, deletion and multiple sessions; start over takes new version',
    () async {
      final first = await repo.start(recipe);
      final changed = recipe.patch({
        'name': 'Updated',
        'recipeInstructions': ['New instructions'],
      });
      expect((await repo.start(changed)).recipe.name, 'Bread');
      await db.db.delete('recipes');
      expect((await repo.sessions()).single.steps.length, 2);
      await repo.start(recipe.patch({'id': '43', 'name': 'Sauce'}));
      expect((await repo.sessions()).length, 2);
      await repo.updateSession(first.id, (_) => {'status': 'completed'});
      expect((await repo.sessions()).where((s) => s.active).length, 1);
      final restarted = await repo.start(changed);
      expect(restarted.id, isNot(first.id));
      expect(restarted.recipe.name, 'Updated');
    },
  );
  test(
    'timer start multiple step association and repository recreation',
    () async {
      final session = await repo.start(recipe);
      final timer = await repo.createTimer(
        const Duration(minutes: 10),
        'Bread',
        session: session,
        step: 1,
      );
      await repo.createTimer(const Duration(minutes: 2), 'Manual');
      now = now.add(const Duration(minutes: 5));
      repo = CookingRepository(db, 'a', now: () => now);
      final all = await repo.timers();
      expect(all.length, 2);
      expect(all.first.remaining(now).inMinutes, 5);
      expect(all.first.sessionId, session.id);
      expect(all.first.data['step'], 1);
      expect(all.last.sessionId, null);
      expect(all.map((t) => t.notificationId).toSet().length, 2);
      expect(timer.duration.inMinutes, 10);
    },
  );
  test(
    'pause survives an hour, resume sets new target, add rename restart cancel dismiss',
    () async {
      final timer = await repo.createTimer(const Duration(minutes: 20), 'Bake');
      now = now.add(const Duration(minutes: 10));
      await repo.control(timer.id, 'pause');
      now = now.add(const Duration(hours: 1));
      var t = (await repo.timers()).single;
      expect(t.remaining(now).inMinutes, 10);
      t = await repo.control(t.id, 'resume');
      expect(t.target, now.add(const Duration(minutes: 10)));
      t = await repo.control(t.id, 'add', add: const Duration(minutes: 5));
      expect(t.remaining(now).inMinutes, 15);
      t = await repo.control(t.id, 'rename', label: 'New');
      expect(t.label, 'New');
      t = await repo.control(t.id, 'restart');
      expect(t.remaining(now).inMinutes, 25);
      t = await repo.control(t.id, 'cancel');
      expect(t.status, 'cancelled');
      t = await repo.control(t.id, 'dismiss');
      expect(t.status, 'dismissed');
    },
  );
  test(
    'completed timer reconciles after process recreation, clock backwards clamps duration',
    () async {
      final timer = await repo.createTimer(const Duration(minutes: 1), 'Tea');
      expect(
        timer.remaining(now.subtract(const Duration(hours: 1))).inMinutes,
        1,
      );
      now = now.add(const Duration(minutes: 3));
      repo = CookingRepository(db, 'a', now: () => now);
      await repo.reconcile();
      expect((await repo.timers()).single.status, 'completed');
      expect((await repo.timers()).single.remaining(now), Duration.zero);
    },
  );
  test(
    'v3 to v4 preserves legacy session, timer, account metadata and canonical rows',
    () async {
      final old = await databaseFactoryFfiNoIsolate.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      for (final sql in AppDatabase.schema) {
        await old.execute(sql);
      }
      await migrateDatabase(old, 1, 3);
      await old.insert('accounts', {
        'id': 'b',
        'server': 'https://cloud.test',
        'login_name': 'cook',
        'capabilities': '{}',
      });
      const legacy = '{"checked":[0,2],"unknown":true}';
      await old.insert('cooking_sessions', {
        'account_id': 'b',
        'recipe_id': '1',
        'state_json': legacy,
      });
      await old.insert('timers', {
        'account_id': 'b',
        'id': 'legacy',
        'state_json': legacy,
      });
      await old.insert('account_metadata', {
        'account_id': 'b',
        'key': 'theme',
        'value': '#123456',
      });
      await old.insert('recipes', {
        'account_id': 'b',
        'id': '1',
        'name': 'Offline edit',
        'stub_json': legacy,
        'detail_json': legacy,
        'dirty': 1,
      });
      await old.insert('pending_operations', {
        'account_id': 'b',
        'recipe_id': '1',
        'kind': 'update',
        'payload_json': legacy,
        'created_at': '2026-01-01',
      });
      await old.insert('conflicts', {
        'account_id': 'b',
        'recipe_id': '1',
        'local_json': legacy,
      });
      await old.insert('recipe_aliases', {
        'account_id': 'b',
        'local_id': 'local-1',
        'server_id': '1',
      });
      await old.insert('image_cache', {
        'account_id': 'b',
        'recipe_id': '1',
        'size': 'thumb',
        'bytes': Uint8List.fromList([1, 2, 3]),
      });
      final unchanged = <String, List<Map<String, Object?>>>{};
      for (final table in [
        'accounts',
        'recipes',
        'pending_operations',
        'conflicts',
        'recipe_aliases',
        'image_cache',
        'account_metadata',
      ]) {
        unchanged[table] = await old.query(table);
      }
      await migrateDatabase(old, 3, 4);
      for (final entry in unchanged.entries) {
        expect(await old.query(entry.key), entry.value, reason: entry.key);
      }
      expect(
        (await old.query('cooking_sessions')).single['state_json'],
        legacy,
      );
      expect((await old.query('timers')).single['state_json'], legacy);
      expect((await old.query('account_metadata')).single['value'], '#123456');
      await old.close();
    },
  );
}
