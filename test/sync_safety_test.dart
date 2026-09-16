import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cookbook/core/api/cookbook_api.dart';
import 'package:cookbook/core/database/app_database.dart';
import 'package:cookbook/core/errors/app_failure.dart';
import 'package:cookbook/features/recipes/domain/recipe.dart';
import 'package:cookbook/features/recipes/data/image_cache.dart';
import 'package:cookbook/features/sync/data/mutation_store.dart';
import 'package:cookbook/features/sync/data/read_sync.dart';
import 'package:cookbook/features/sync/data/sync_engine.dart';

class ServerApi implements CookbookApi {
  final recipes = <String, Recipe>{};
  final calls = <String>[];
  String? uncertain;
  AppFailure? listFailure;
  Completer<void>? gate;
  int _id = 100;
  @override
  Future<List<Recipe>> listRecipes() async {
    if (listFailure != null) throw listFailure!;
    return recipes.values.toList();
  }

  @override
  Future<Recipe> recipe(String id) async =>
      recipes[id] ??
      (throw const AppFailure(FailureKind.notFound, status: 404));
  @override
  Future<String> create(Recipe recipe) async {
    calls.add('create');
    final id = '${++_id}';
    recipes[id] = recipe.patch({'id': id});
    if (uncertain == 'create') throw const AppFailure(FailureKind.timeout);
    return id;
  }

  @override
  Future<void> update(String id, Recipe recipe) async {
    calls.add('update:${recipe.name}');
    await gate?.future;
    recipes[id] = recipe.patch({'id': id});
    if (uncertain == 'update') throw const AppFailure(FailureKind.timeout);
  }

  @override
  Future<void> delete(String id) async {
    calls.add('delete');
    recipes.remove(id);
    if (uncertain == 'delete') throw const AppFailure(FailureKind.timeout);
  }

  @override
  Future<Recipe> importUrl(Uri url) async {
    calls.add('import');
    final id = '${++_id}';
    final result = Recipe.fromJson({
      'id': id,
      'name': 'Imported recipe',
      'url': url.toString(),
      'custom': {'retained': true},
    });
    recipes[id] = result;
    if (uncertain == 'import') throw const AppFailure(FailureKind.timeout);
    return result;
  }

  @override
  Future<List<JsonMap>> categories() async => [];
  @override
  Future<List<JsonMap>> keywords() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected call');
}

void main() {
  sqfliteFfiInit();
  late AppDatabase db;
  late ServerApi api;
  late MutationStore store;
  late SyncEngine engine;
  final original = Recipe.fromJson({
    'id': '1',
    'name': 'Original',
    'unknown': {'nested': true},
    'recipeIngredient': ['1 cup water'],
  });
  setUp(() async {
    db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    await db.db.insert('accounts', {
      'id': 'a',
      'server': 'https://example.invalid',
      'login_name': 'cook',
      'capabilities': '{}',
    });
    api = ServerApi()..recipes['1'] = original;
    store = MutationStore(db, 'a');
    engine = SyncEngine(db, api, 'a');
    await ReadSync(db, api, 'a').run();
  });
  tearDown(() async => db.close());
  Future<List<Map<String, Object?>>> operations() =>
      db.db.query('pending_operations', orderBy: 'id');
  test(
    'open local editor remains addressable after create ID remaps',
    () async {
      final id = await store.save(
        original.patch({'name': 'New'}),
        create: true,
      );
      final snapshot = (await db.recipes('a')).firstWhere((r) => r.id == id);
      await engine.run();
      expect(await db.resolveId('a', id), '101');
      final savedId = await store.save(
        snapshot.patch({'name': 'Still editing'}),
        expectedRecipe: snapshot,
      );
      expect(savedId, '101');
      await engine.run();
      expect(api.recipes['101']!.name, 'Still editing');
    },
  );
  test('stale editor cannot overwrite a newer local snapshot', () async {
    await store.save(original.patch({'name': 'Other form'}));
    await expectLater(
      store.save(
        original.patch({'name': 'Stale form'}),
        expectedRecipe: original,
      ),
      throwsA(isA<AppFailure>()),
    );
    expect((await db.recipes('a')).single.name, 'Other form');
    expect(await operations(), hasLength(1));
  });
  test(
    'failed confirmation transaction retains uncertainty and reconciles without a second create',
    () async {
      final id = await store.save(
        original.patch({'name': 'Unique transaction recipe'}),
        create: true,
      );
      await db.db.execute(
        "CREATE TRIGGER break_mapping BEFORE UPDATE OF id ON recipes BEGIN SELECT RAISE(ABORT,'test interruption'); END",
      );
      await engine.run();
      expect((await operations()).single['state'], 'unknownOutcome');
      expect(await db.resolveId('a', id), id);
      expect(await db.db.query('recipe_aliases'), isEmpty);
      await db.db.execute('DROP TRIGGER break_mapping');
      await engine.run();
      expect(api.calls, ['create']);
      expect(await db.resolveId('a', id), '101');
      expect((await operations()).single['state'], 'applied');
    },
  );
  test(
    'original local alias follows a later recreation after remote deletion',
    () async {
      final id = await store.save(
        original.patch({'name': 'New recipe'}),
        create: true,
      );
      await engine.run();
      final first = api.recipes['101']!;
      await store.save(first.patch({'name': 'Retain this edit'}));
      api.recipes.remove('101');
      await engine.run();
      await store.resolve('101', keepLocal: true);
      await engine.run();
      expect(await db.resolveId('a', id), '102');
      expect(await db.resolveId('a', '101'), '102');
      expect(api.recipes['102']!.name, 'Retain this edit');
    },
  );
  test(
    'offline URL import becomes canonical server recipe with alias',
    () async {
      final id = await store.queueImport(
        Uri.parse('https://example.invalid/food'),
      );
      await engine.run();
      expect(api.calls, ['import']);
      expect(await db.resolveId('a', id), '101');
      expect((await operations()).single['state'], 'applied');
      expect(
        (await db.recipes(
          'a',
        )).firstWhere((r) => r.id == '101').toJson()['custom'],
        {'retained': true},
      );
    },
  );
  test(
    'lost import response is never repeated and requires inspected association',
    () async {
      api.uncertain = 'import';
      await store.queueImport(Uri.parse('https://example.invalid/food'));
      await engine.run();
      await engine.run();
      expect(api.calls, ['import']);
      final op = (await operations()).single;
      expect(op['state'], 'unknownOutcome');
      final inspected = api.recipes['101']!;
      api.recipes['101'] = inspected.patch({'name': 'Changed'});
      await expectLater(
        engine.attachUnknown(
          op['id'] as int,
          '101',
          inspectedRecipe: inspected,
        ),
        throwsA(isA<AppFailure>()),
      );
      await engine.attachUnknown(
        op['id'] as int,
        '101',
        inspectedRecipe: api.recipes['101'],
      );
      expect((await operations()).single['state'], 'applied');
    },
  );
  test(
    'offline create is visible and identity remaps queued edits and local sessions atomically',
    () async {
      final id = await store.save(
        original.patch({'name': 'New'}),
        create: true,
      );
      expect(id, startsWith('local:'));
      expect(await db.recipes('a'), hasLength(2));
      await db.db.insert('cooking_sessions', {
        'account_id': 'a',
        'recipe_id': id,
        'state_json': jsonEncode({
          'recipeId': id,
          'checked': [1],
        }),
      });
      await store.save(original.patch({'id': id, 'name': 'Newer'}));
      await engine.run();
      expect(api.calls, ['create', 'update:Newer']);
      expect((await operations()).every((r) => r['state'] == 'applied'), true);
      expect(
        (await db.db.query('cooking_sessions')).single['recipe_id'],
        '101',
      );
      expect(
        jsonDecode(
          (await db.db.query('cooking_sessions')).single['state_json']
              as String,
        )['recipeId'],
        '101',
      );
    },
  );
  test(
    'multiple offline edits then delete dispatch in deterministic order',
    () async {
      await store.save(original.patch({'name': 'A'}));
      await store.save(original.patch({'name': 'B'}));
      await store.delete('1');
      expect(await db.recipes('a'), isEmpty);
      await engine.run();
      expect(api.calls, ['update:A', 'update:B', 'delete']);
    },
  );
  test('queued delete can be recovered before dispatch', () async {
    await store.delete('1');
    await store.undoDelete('1');
    await engine.run();
    expect(api.calls, isEmpty);
    expect(await db.recipes('a'), hasLength(1));
  });
  for (final deleting in [false, true]) {
    test(
      'server change conflicts with local ${deleting ? 'delete' : 'update'} and retains all three snapshots',
      () async {
        if (deleting) {
          await store.delete('1');
        } else {
          await store.save(original.patch({'name': 'Local'}));
        }
        api.recipes['1'] = original.patch({'name': 'Remote'});
        await engine.run();
        expect(api.calls, isEmpty);
        final conflict = (await db.db.query('conflicts')).single;
        expect(jsonDecode(conflict['base_json'] as String)['name'], 'Original');
        expect(jsonDecode(conflict['server_json'] as String)['name'], 'Remote');
        expect(conflict['local_json'], isNotNull);
        await store.resolve('1', keepLocal: false);
        expect((await db.recipes('a')).single.name, 'Remote');
      },
    );
  }
  test(
    'local edit versus deleted server conflicts; Keep Local recreates without losing unknown fields',
    () async {
      await store.save(original.patch({'name': 'Local'}));
      api.recipes.clear();
      await engine.run();
      expect((await db.db.query('conflicts')).single['server_json'], null);
      await store.resolve('1', keepLocal: true);
      await engine.run();
      expect(api.recipes.values.single.toJson()['unknown'], {'nested': true});
    },
  );
  for (final kind in ['create', 'update', 'delete']) {
    test('lost $kind response reconciles without duplicate dispatch', () async {
      if (kind == 'create') {
        await store.save(original.patch({'name': 'Unique new'}), create: true);
      }
      if (kind == 'update') {
        await store.save(original.patch({'name': 'Updated'}));
      }
      if (kind == 'delete') await store.delete('1');
      api.uncertain = kind;
      await engine.run();
      expect((await operations()).single['state'], 'unknownOutcome');
      await engine.run();
      expect(api.calls, hasLength(1));
      expect((await operations()).single['state'], 'applied');
    });
  }
  test(
    'ambiguous uncertain create remains unresolved and is never sent again',
    () async {
      await store.save(original.patch({'name': 'Duplicate'}), create: true);
      api.uncertain = 'create';
      await engine.run();
      api.recipes['102'] = api.recipes['101']!.patch({'id': '102'});
      await engine.run();
      expect(api.calls, ['create']);
      expect((await operations()).single['state'], 'unknownOutcome');
    },
  );
  test(
    'restart sending operation becomes uncertain and needs reconciliation',
    () async {
      await store.save(original.patch({'name': 'Edited'}));
      await db.db.update('pending_operations', {'state': 'sending'});
      await engine.run();
      expect(api.calls, isEmpty);
      expect((await operations()).single['state'], 'failed');
    },
  );
  test(
    'uncertain update with another server change becomes conflict',
    () async {
      await store.save(original.patch({'name': 'Edited'}));
      api.uncertain = 'update';
      await engine.run();
      api.recipes['1'] = original.patch({'name': 'Other editor'});
      await engine.run();
      expect((await operations()).single['state'], 'conflict');
      expect(api.calls, hasLength(1));
    },
  );
  test('two sync jobs share a mutex without sleeps', () async {
    await store.save(original.patch({'name': 'Edited'}));
    final gate = api.gate = Completer<void>();
    final first = engine.run();
    final second = SyncEngine(db, api, 'a').run();
    gate.complete();
    await Future.wait([first, second]);
    expect(api.calls, ['update:Edited']);
  });
  for (final error in [
    const AppFailure(FailureKind.server, status: 500),
    const AppFailure(FailureKind.timeout),
    const AppFailure(FailureKind.authentication, status: 401),
    const AppFailure(FailureKind.malformedResponse),
  ]) {
    test(
      'listing ${error.kind.name} cannot dispatch or destroy recipes',
      () async {
        await store.delete('1');
        api.listFailure = error;
        await expectLater(engine.run(), throwsA(isA<AppFailure>()));
        expect(api.calls, isEmpty);
        expect(await db.db.query('recipes'), hasLength(1));
        expect((await operations()).single['state'], 'queued');
      },
    );
  }
  test(
    'remote deletion needs two successful absences and detail 404; JSON retained as tombstone',
    () async {
      api.recipes.clear();
      await ReadSync(db, api, 'a').run();
      expect(await db.recipes('a'), hasLength(1));
      await ReadSync(db, api, 'a').run();
      expect(await db.recipes('a'), isEmpty);
      expect((await db.db.query('recipes')).single['detail_json'], isNotNull);
    },
  );
  test('a partial successful list cannot delete an existing detail', () async {
    final partial = PartialApi(api);
    await ReadSync(db, partial, 'a').run();
    await ReadSync(db, partial, 'a').run();
    expect(await db.recipes('a'), hasLength(1));
  });
  test('local save transaction rolls back if queue insertion fails', () async {
    await db.db.execute(
      "CREATE TRIGGER break_queue BEFORE INSERT ON pending_operations BEGIN SELECT RAISE(ABORT,'test interruption'); END",
    );
    await expectLater(
      store.save(original.patch({'name': 'Lost edit'})),
      throwsA(anything),
    );
    expect((await db.recipes('a')).single.name, 'Original');
    expect(await operations(), isEmpty);
  });
  test(
    'LRU image budget and corrupt/orphan cleanup never affect recipes',
    () async {
      final cache = ImageCacheStore(db, 'a');
      final jpg = Uint8List.fromList([255, 216, 1, 255, 217]);
      await cache.setLimit(5);
      await cache.put('1', 'thumb', jpg);
      await cache.put('1', 'full', jpg);
      expect(await cache.size(), 5);
      expect(await db.recipes('a'), hasLength(1));
      await db.db.insert('image_cache', {
        'account_id': 'a',
        'recipe_id': 'missing',
        'size': 'thumb',
        'bytes': jpg,
      });
      await cache.trim();
      expect(await cache.size(), 5);
      await db.db.update('image_cache', {'bytes': Uint8List(3)});
      expect(await cache.read('1', 'full'), null);
      await cache.clear();
      expect(await cache.size(), 0);
      expect(await db.recipes('a'), hasLength(1));
    },
  );
}

class PartialApi extends ServerApi {
  PartialApi(this.source);
  final ServerApi source;
  @override
  Future<List<Recipe>> listRecipes() async => [];
  @override
  Future<Recipe> recipe(String id) => source.recipe(id);
}
