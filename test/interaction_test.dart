import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cookbook/core/database/app_database.dart';
import 'package:cookbook/features/cooking/data/cooking_repository.dart';
import 'package:cookbook/features/cooking/domain/quantities.dart';
import 'package:cookbook/features/editor/domain/recipe_draft.dart';
import 'package:cookbook/features/recipes/data/ingredient_check_store.dart';
import 'package:cookbook/features/recipes/domain/recipe.dart';
import 'package:cookbook/features/sync/data/mutation_store.dart';

void main() {
  sqfliteFfiInit();
  late AppDatabase db;
  late CookingRepository cooking;
  late IngredientCheckStore checks;
  final recipe = Recipe.fromJson({
    'id': '42',
    'name': 'Soup',
    'recipeYield': '4 servings',
    'recipeIngredient': ['## Sauce', '1 cup milk', 'salt', 'salt'],
    'recipeInstructions': ['Prepare', 'Mix', 'Simmer', 'Serve'],
    'custom': {'retained': true},
  });
  setUp(() async {
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
    cooking = CookingRepository(db, 'a');
    checks = IngredientCheckStore(db, 'a');
  });
  tearDown(() async => db.close());
  test('completion advances and persists through repository restart', () async {
    final session = await cooking.start(recipe);
    await cooking.check(session.id, 'steps', 0);
    final restored = (await CookingRepository(db, 'a').sessions()).single;
    expect(restored.current, 1);
    expect(restored.checks('steps'), {0});
    expect(restored.active, true);
  });
  test('completion skips already completed following instructions', () async {
    final s = await cooking.start(recipe);
    await cooking.updateSession(
      s.id,
      (_) => {
        'steps': [1, 2],
      },
    );
    await cooking.check(s.id, 'steps', 0);
    expect((await cooking.sessions()).single.current, 3);
  });
  test('final completion never wraps or finishes and is obvious', () async {
    final s = await cooking.start(recipe);
    for (var i = 0; i < 4; i++) {
      await cooking.check(s.id, 'steps', i);
    }
    final done = (await cooking.sessions()).single;
    expect(done.current, 3);
    expect(done.allStepsComplete, true);
    expect(done.active, true);
  });
  test('out of order final completion does not claim all steps done', () async {
    final s = await cooking.start(recipe);
    await cooking.check(s.id, 'steps', 3);
    final result = (await cooking.sessions()).single;
    expect(result.current, 3);
    expect(result.allStepsComplete, false);
  });
  test('unchecking never steals manually selected current step', () async {
    final s = await cooking.start(recipe);
    await cooking.check(s.id, 'steps', 0);
    await cooking.updateSession(s.id, (_) => {'current': 3});
    await cooking.check(s.id, 'steps', 0);
    expect((await cooking.sessions()).single.current, 3);
    expect((await cooking.sessions()).single.checks('steps'), isEmpty);
  });
  test(
    'reset clears checks and preserves servings snapshot and timers',
    () async {
      final s = await cooking.start(recipe);
      await cooking.check(s.id, 'steps', 0);
      await cooking.check(s.id, 'ingredients', 1);
      await cooking.scale(s.id, Rational(2));
      final timer = await cooking.createTimer(
        const Duration(minutes: 5),
        'Soup',
        session: s,
      );
      await cooking.reset(s.id);
      final reset = (await cooking.sessions()).single;
      expect(reset.current, 0);
      expect(reset.checks('ingredients'), isEmpty);
      expect(reset.checks('steps'), isEmpty);
      expect(reset.multiplier.wire, '2/1');
      expect(reset.recipe.toJson(), recipe.toJson());
      expect((await cooking.timers()).single.id, timer.id);
      expect((await cooking.timers()).single.running, true);
    },
  );
  test(
    'updated restart replaces snapshot and resets servings without losing timers',
    () async {
      final s = await cooking.start(recipe);
      await cooking.scale(s.id, Rational(2));
      await cooking.check(s.id, 'steps', 0);
      final timer = await cooking.createTimer(
        const Duration(minutes: 5),
        'Soup',
        session: s,
      );
      final updated = recipe.patch({
        'recipeInstructions': ['New step'],
      });
      final restarted = await cooking.start(updated, over: true);
      expect(restarted.recipe.toJson(), updated.toJson());
      expect(restarted.checks('steps'), isEmpty);
      expect(restarted.multiplier.wire, '1/1');
      expect((await cooking.timers()).single.id, timer.id);
      expect((await cooking.timers()).single.running, true);
    },
  );
  test(
    'detail check toggle persists locally without touching JSON or queue',
    () async {
      final key = ingredientKeys(recipe.ingredients)[1]!;
      expect(await checks.update(recipe, toggle: key), {key});
      expect(await IngredientCheckStore(db, 'a').update(recipe), {key});
      expect(await checks.update(recipe, toggle: key), isEmpty);
      expect(await db.db.query('pending_operations'), isEmpty);
      expect(await db.db.query('recipes'), isEmpty);
    },
  );
  test('headings and blank lines are not checkable', () async {
    expect(ingredientKeys(['## Sauce', '  ### Dough', '', 'salt']), [
      null,
      null,
      null,
      jsonEncode(['salt', 0]),
    ]);
    expect(await checks.update(recipe, toggle: '## Sauce'), isEmpty);
  });
  test(
    'duplicates have separate occurrences and ambiguous removal discards checks',
    () async {
      final keys = ingredientKeys(recipe.ingredients);
      expect(await checks.update(recipe, toggle: keys[3]), {keys[3]});
      expect(await checks.update(recipe, toggle: keys[2]), {keys[2], keys[3]});
      expect(
        await checks.update(
          recipe.patch({
            'recipeIngredient': ['salt'],
          }),
        ),
        isEmpty,
      );
    },
  );
  test(
    'edits prune orphans and reordering preserves clearly unchanged lines',
    () async {
      final key = ingredientKeys(recipe.ingredients)[1]!;
      await checks.update(recipe, toggle: key);
      final reordered = recipe.patch({
        'recipeIngredient': ['salt', '1 cup milk', 'salt'],
      });
      expect(await checks.update(reordered), {key});
      expect(
        await checks.update(
          recipe.patch({
            'recipeIngredient': ['1 cup cream', 'salt', 'salt'],
          }),
        ),
        isEmpty,
      );
      expect(await checks.update(recipe), isEmpty);
    },
  );
  test(
    'whitespace normalization is stable and case changes conservative',
    () async {
      final key = ingredientKeys(recipe.ingredients)[1]!;
      await checks.update(recipe, toggle: key);
      expect(
        await checks.update(
          recipe.patch({
            'recipeIngredient': ['  1  cup milk '],
          }),
        ),
        {key},
      );
      expect(
        await checks.update(
          recipe.patch({
            'recipeIngredient': ['1 cup Milk'],
          }),
        ),
        isEmpty,
      );
    },
  );
  test(
    'detail checks and Cooking state are separate; clear preserves Cooking',
    () async {
      final key = ingredientKeys(recipe.ingredients)[1]!;
      await checks.update(recipe, toggle: key);
      final s = await cooking.start(recipe);
      expect(s.checks('ingredients'), isEmpty);
      await cooking.check(s.id, 'ingredients', 1);
      await checks.update(recipe, clear: true);
      expect((await cooking.sessions()).single.checks('ingredients'), {1});
      expect(await checks.update(recipe), isEmpty);
    },
  );
  test('account removal cascades presentation state', () async {
    await checks.update(recipe, toggle: ingredientKeys(recipe.ingredients)[1]);
    await db.removeAccount('a');
    expect(await db.db.query('account_metadata'), isEmpty);
  });
  test('offline ID alias carries checks to canonical recipe ID', () async {
    final local = recipe.patch({'id': 'local-one'});
    final key = ingredientKeys(recipe.ingredients)[1]!;
    await checks.update(local, toggle: key);
    await db.db.insert('recipe_aliases', {
      'account_id': 'a',
      'local_id': 'local-one',
      'server_id': '42',
    });
    expect(await checks.update(recipe), {key});
    expect(await checks.update(recipe), {key});
    expect(
      (await db.db.query('account_metadata')).single['key'],
      checks.key('42'),
    );
  });
  test(
    'structured reorder preserves nodes and opaque data without crossing sections',
    () {
      final tree = InstructionTree([
        {
          '@type': 'HowToSection',
          'name': 'Sauce',
          'extra': 7,
          'itemListElement': [
            {
              '@type': 'HowToStep',
              'text': 'A',
              'url': 'https://example.test/a',
            },
            'B',
          ],
        },
        {
          '@type': 'HowToSection',
          'name': 'Serve',
          'itemListElement': ['C', 'D'],
        },
        {
          'opaque': {'preserve': true},
        },
      ]);
      expect(tree.reorderGroups.length, 2);
      tree.moveWithin(tree.reorderGroups.first.path, 0, 1);
      final values = tree.value as List;
      final section = values.first as Map;
      expect(section['extra'], 7);
      expect((section['itemListElement'] as List).first, 'B');
      expect((section['itemListElement'] as List).last, {
        '@type': 'HowToStep',
        'text': 'A',
        'url': 'https://example.test/a',
      });
      expect(values.last, {
        'opaque': {'preserve': true},
      });
      expect(() => tree.moveWithin([], 0, 1), throwsStateError);
    },
  );
  test('flat instruction reorder preserves HowToStep unknown fields', () {
    final tree = InstructionTree([
      {'@type': 'HowToStep', 'text': 'A', 'extra': 9},
      'B',
    ]);
    tree.move(0, 1);
    expect(tree.value, [
      'B',
      {'@type': 'HowToStep', 'text': 'A', 'extra': 9},
    ]);
  });
  test(
    'offline save queues canonical reordered arrays and reopen keeps order',
    () async {
      final reordered = recipe.patch({
        'recipeIngredient': ['salt', '## Sauce', '1 cup milk', 'salt'],
        'recipeInstructions': ['Mix', 'Prepare', 'Simmer', 'Serve'],
      });
      final id = await MutationStore(db, 'a').save(reordered, create: true);
      final operation = (await db.db.query('pending_operations')).single;
      final payload = jsonDecode(operation['payload_json'] as String) as Map;
      expect(payload['recipeIngredient'], reordered.ingredients);
      expect(
        payload['recipeInstructions'],
        reordered.toJson()['recipeInstructions'],
      );
      expect(payload['custom'], {'retained': true});
      final saved = (await db.db.query(
        'recipes',
        where: 'id=?',
        whereArgs: [id],
      )).single;
      expect(
        (jsonDecode(saved['detail_json'] as String) as Map)['recipeIngredient'],
        reordered.ingredients,
      );
      expect(operation['state'], 'queued');
    },
  );
  test(
    'reordered stale editor cannot overwrite newer downloaded JSON',
    () async {
      final latest = recipe.patch({'name': 'Updated on server'});
      await db.db.insert('recipes', {
        'account_id': 'a',
        'id': recipe.id,
        'name': latest.name,
        'stub_json': jsonEncode(latest.toJson()),
        'detail_json': jsonEncode(latest.toJson()),
        'sync_state': 'clean',
      });
      await expectLater(
        MutationStore(db, 'a').save(
          recipe.patch({
            'recipeIngredient': recipe.ingredients.reversed.toList(),
          }),
          expectedRecipe: recipe,
        ),
        throwsA(isA<Exception>()),
      );
      expect(await db.db.query('pending_operations'), isEmpty);
      expect(
        (await db.db.query('recipes')).single['detail_json'],
        jsonEncode(latest.toJson()),
      );
    },
  );
}
