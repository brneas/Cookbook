import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:cookbook/app/providers.dart';
import 'package:cookbook/core/database/app_database.dart';
import 'package:cookbook/core/database/library_guard.dart';
import 'package:cookbook/core/errors/app_failure.dart';
import 'package:cookbook/features/recipes/domain/recipe.dart';
import 'package:cookbook/features/recipes/data/library_repository.dart';
import 'package:cookbook/features/recipes/presentation/library_providers.dart';
import 'package:cookbook/features/recipes/presentation/recipe_text.dart';
import 'package:cookbook/features/editor/domain/recipe_draft.dart';
import 'package:cookbook/features/files/data/nextcloud_files_service.dart';
import 'package:cookbook/features/settings/data/server_cookbook_settings.dart';
import 'package:cookbook/features/sync/data/mutation_store.dart';
import 'database_sync_test.dart' show ReadApi;

class SettingsApi extends ReadApi {
  JsonMap config = {
    'folder': '/Recipes',
    'update_interval': 5,
    'print_image': true,
    'visibleInfoBlocks': {
      'tools': true,
      'future-block': {'enabled': false},
    },
    'future-option': 42,
  };
  bool fail = false;
  int renames = 0;
  @override
  Future<JsonMap> configuration() async => config;
  @override
  Future<void> configure(JsonMap values) async {
    config = {...config, ...values};
    if (fail) throw const AppFailure(FailureKind.network);
  }

  @override
  Future<void> renameCategory(String old, String name) async {
    renames++;
    if (fail) throw const AppFailure(FailureKind.network);
    stubs = stubs
        .map(
          (r) => r.patch({
            'recipeCategory': name,
            'dateModified': '2026-09-16T12:00:00Z',
          }),
        )
        .toList();
    details = {for (final r in stubs) r.id: r};
  }
}

void main() {
  sqfliteFfiInit();
  late AppDatabase db;
  late LibraryRepository library;
  late MutationStore store;
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
    library = LibraryRepository(db, 'a');
    store = MutationStore(db, 'a');
  });
  tearDown(() async => db.close());
  Future<void> seed(List<JsonMap> recipes) async {
    final b = db.db.batch();
    for (final r in recipes) {
      b.insert('recipes', {
        'account_id': 'a',
        'id': '${r['id']}',
        'name': r['name'],
        'category': r['recipeCategory'] ?? '',
        'keywords': r['keywords'] ?? '',
        'stub_json': jsonEncode(r),
        'detail_json': jsonEncode(r),
        'base_json': jsonEncode(r),
        'server_json': jsonEncode(r),
      });
    }
    await b.commit(noResult: true);
  }

  final rows = <JsonMap>[
    {
      'id': '1',
      'name': 'Apple pie',
      'recipeCategory': 'Dessert',
      'keywords': 'quick,vegan',
      'dateCreated': '2020-01-01T00:00:00Z',
      'dateModified': '2024-01-01T00:00:00Z',
    },
    {
      'id': '2',
      'name': 'Bread',
      'recipeCategory': 'Bakery',
      'keywords': 'quick',
      'dateCreated': '2021-01-01T00:00:00+0000',
      'dateModified': '2023-01-01T00:00:00Z',
    },
    {
      'id': '3',
      'name': 'Carrot soup',
      'recipeCategory': '',
      'keywords': 'vegan,crème fraîche',
      'dateCreated': 'invalid',
    },
  ];
  test(
    'category counts include uncategorized and follow local create edit delete',
    () async {
      await seed(rows);
      expect((await library.categories()).map((f) => f.count), [1, 1, 1]);
      final id = await store.save(
        Recipe.fromJson({
          'name': 'New',
          'recipeCategory': 'Dessert',
          'keywords': 'new',
        }),
        create: true,
      );
      expect((await library.categories()).last.count, 2);
      await store.save(
        Recipe.fromJson({
          'id': id,
          'name': 'New',
          'recipeCategory': 'Bakery',
          'keywords': 'changed',
        }),
      );
      expect(
        (await library.categories())
            .firstWhere((f) => f.name == 'Bakery')
            .count,
        2,
      );
      await store.delete(id);
      expect((await library.page(const LibraryFilter())).total, 3);
      expect(
        (await library.taxonomy())['keywords'],
        isNot(contains('changed')),
      );
    },
  );
  test(
    'public search OR name/category/keyword, combined filters, literal wildcards',
    () async {
      await seed(rows);
      expect(
        (await library.page(const LibraryFilter(search: 'pie,bread'))).total,
        2,
      );
      expect(
        (await library.page(const LibraryFilter(search: 'Dessert'))).total,
        1,
      );
      expect(
        (await library.page(
          const LibraryFilter(search: 'quick', category: 'Dessert'),
        )).total,
        1,
      );
      expect((await library.page(const LibraryFilter(search: '%'))).total, 0);
      expect(
        (await library.page(const LibraryFilter(category: ''))).items.single.id,
        '3',
      );
    },
  );
  test('keyword AND default OR optional and contextual availability', () async {
    await seed(rows);
    expect(
      (await library.page(
        const LibraryFilter(keywords: ['quick', 'vegan']),
      )).total,
      1,
    );
    expect(
      (await library.page(
        const LibraryFilter(keywords: ['quick', 'vegan'], anyKeyword: true),
      )).total,
      3,
    );
    final f = await library.keywords(const LibraryFilter(keywords: ['quick']));
    expect(f.firstWhere((f) => f.name == 'crème fraîche').available, false);
    expect(f.firstWhere((f) => f.name == 'vegan').count, 2);
    expect(
      (await library.keywords(const LibraryFilter(category: 'Dessert'))).length,
      2,
    );
    expect(
      (await library.page(
        const LibraryFilter(keywords: ['cremefraiche']),
      )).items.single.id,
      '3',
    );
  });
  for (final sort in RecipeSort.values) {
    test('sort ${sort.name}, malformed dates last', () async {
      await seed(rows);
      final ids = (await library.page(
        LibraryFilter(sort: sort),
      )).items.map((r) => r.id).toList();
      expect(ids, switch (sort) {
        RecipeSort.nameAscending => ['1', '2', '3'],
        RecipeSort.nameDescending => ['3', '2', '1'],
        RecipeSort.createdAscending => ['1', '2', '3'],
        RecipeSort.createdDescending => ['2', '1', '3'],
        RecipeSort.modifiedAscending => ['2', '1', '3'],
        RecipeSort.modifiedDescending => ['1', '2', '3'],
      });
    });
  }
  test(
    'projection paginates without decoding unchanged canonical bodies',
    () async {
      await seed(rows);
      await library.prepare();
      await db.db.execute('DROP TRIGGER library_recipe_changed');
      await db.db.update('recipes', {'detail_json': 'not json'});
      final p = await library.page(const LibraryFilter(), offset: 1, limit: 1);
      expect(p.total, 3);
      expect(p.items.single.id, '2');
    },
  );
  test('preference list/grid and sort survive container restart', () async {
    var c = ProviderContainer(
      overrides: [databaseProvider.overrideWith((_) async => db)],
    );
    await c.read(libraryPreferencesProvider.future);
    await c
        .read(libraryPreferencesProvider.notifier)
        .set(grid: true, sort: RecipeSort.modifiedDescending);
    c.dispose();
    c = ProviderContainer(
      overrides: [databaseProvider.overrideWith((_) async => db)],
    );
    final p = await c.read(libraryPreferencesProvider.future);
    expect(p.grid, true);
    expect(p.sort, RecipeSort.modifiedDescending);
    c.dispose();
  });
  test('configuration preserves unknown settings and block values', () async {
    final api = SettingsApi();
    final service = ServerCookbookService(db, api, 'a');
    final config = await service.reload();
    await service.update(config.blockChange('tools', false));
    expect(api.config['future-option'], 42);
    expect((api.config['visibleInfoBlocks'] as Map)['future-block'], {
      'enabled': false,
    });
    expect((await service.cached()).visible('tools'), false);
    await service.update({'print_image': false, 'update_interval': 12});
    expect((await service.cached()).interval, 12);
    expect((await service.cached()).printImage, false);
  });
  test('invalid interval and relative/traversal folder rejected', () async {
    final s = ServerCookbookService(db, SettingsApi(), 'a');
    for (final value in [0, -1, 1.5, 'ten']) {
      await expectLater(
        s.update({'update_interval': value}),
        throwsA(isA<AppFailure>()),
      );
    }
    for (final value in ['Recipes', '/../Photos']) {
      await expectLater(
        s.update({'folder': value}),
        throwsA(isA<AppFailure>()),
      );
    }
  });
  test('rename is public API then authoritative refresh', () async {
    await seed([rows.first]);
    final api = SettingsApi()..stubs = [Recipe.fromJson(rows.first)];
    final s = ServerCookbookService(db, api, 'a');
    await s.rename('Dessert', 'Baking');
    expect(api.renames, 1);
    expect((await library.categories()).single.name, 'Baking');
  });
  test('queued edits prevent category rename and folder switch', () async {
    await store.save(Recipe.fromJson({'name': 'Offline'}), create: true);
    final api = SettingsApi();
    final s = ServerCookbookService(db, api, 'a');
    await expectLater(s.rename('A', 'B'), throwsA(isA<AppFailure>()));
    await expectLater(
      s.update({'folder': '/Other'}),
      throwsA(isA<AppFailure>()),
    );
    expect(api.renames, 0);
    expect(api.config['folder'], '/Recipes');
  });
  test(
    'interrupted rename pauses writes until reload without replay',
    () async {
      final api = SettingsApi()..fail = true;
      final s = ServerCookbookService(db, api, 'a');
      await expectLater(s.rename('A', 'B'), throwsA(isA<AppFailure>()));
      await expectLater(
        store.save(Recipe.fromJson({'name': 'Unsafe'}), create: true),
        throwsA(isA<AppFailure>()),
      );
      api.fail = false;
      await s.reload();
      await ensureLibraryWritable(db.db, 'a');
      expect(api.renames, 1);
    },
  );
  test(
    'folder switch invalidates old IDs and preserves detached cooking snapshot',
    () async {
      await seed(rows);
      await db.db.insert('cooking_sessions', {
        'account_id': 'a',
        'recipe_id': '1',
        'state_json': jsonEncode({
          'v': 1,
          'recipeId': '1',
          'snapshot': rows.first,
          'sessionId': 'session',
          'status': 'active',
        }),
      });
      final api = SettingsApi();
      final s = ServerCookbookService(db, api, 'a');
      await s.reload();
      api.fail = true;
      await expectLater(
        s.update({'folder': '/Other'}),
        throwsA(isA<AppFailure>()),
      );
      api.fail = false;
      await s.reload();
      expect((await library.page(const LibraryFilter())).total, 0);
      final saved = (await db.db.query('cooking_sessions')).single;
      expect(saved['recipe_id'], startsWith('previous-folder:'));
      expect(jsonDecode(saved['state_json'] as String)['snapshot'], rows.first);
      expect((await s.cached()).folder, '/Other');
    },
  );
  test('recipe references preserve upstream storage and Markdown links', () {
    expect(recipeReference('123'), '#r/123');
    expect(recipeReferenceId('#r/123'), '123');
    expect(recipeReferenceId('https://evil.test/#r/123'), isNull);
    expect(() => recipeReference('local:abc'), throwsFormatException);
    final html = md.markdownToHtml(
      'Use #r/123, then [other](#r/456).',
      inlineSyntaxes: [
        RecipeReferenceSyntax({'123': 'Stock'}),
      ],
    );
    expect(html, contains('href="#r/123">Stock</a>'));
    expect(html, contains('href="#r/456">other</a>'));
  });
  test('image path and references roundtrip unknown nested fields', () {
    final json = <String, Object?>{
      'id': '1',
      'name': 'Soup',
      'description': 'Use #r/2',
      'image': '/Photos/soup.png',
      'nutrition': {
        'future': {'unit': 'x'},
      },
      'recipeInstructions': [
        {'@type': 'HowToStep', 'text': 'Add #r/3', 'future': 42},
      ],
      'unknown': {
        'nested': [1, 2],
      },
    };
    final d = RecipeDraft(Recipe.fromJson(json));
    d.set('name', 'Changed');
    d.imageUrl('/Pictures/new.jpg');
    expect(d.build().toJson()['nutrition'], json['nutrition']);
    expect(
      d.build().toJson()['recipeInstructions'],
      json['recipeInstructions'],
    );
    expect(d.build().toJson()['unknown'], json['unknown']);
    expect(d.build().toJson()['image'], '/Pictures/new.jpg');
  });
  for (final value in ['0', '90', '1:30', '1:02:03']) {
    test('duration editor $value preserves seconds', () {
      final d = parseEditorDuration(value)!;
      expect(parseEditorDuration(editorDuration(d)), d);
    });
  }
  test('invalid editor durations and dates are safe', () {
    for (final s in ['-1', '1:99', 'x', '1:2:3:4']) {
      expect(parseEditorDuration(s), isNull);
    }
    expect(parseRecipeDate('2026-02-30'), isNull);
    expect(parseRecipeDate('2026-02-28T12:00:00+0000'), isNotNull);
  });
  test(
    'WebDAV picker limits to same account direct children JPEG PNG and folders',
    () {
      final root = Uri.parse(
        'https://cloud.test/nextcloud/remote.php/dav/files/user/',
      );
      String node(String href, String type, {bool folder = false}) =>
          '<d:response><d:href>$href</d:href><d:propstat><d:prop><d:resourcetype>${folder ? '<d:collection/>' : ''}</d:resourcetype><d:getcontenttype>$type</d:getcontenttype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
      final xml =
          '<d:multistatus xmlns:d="DAV:">${node('${root.path}Photos/', '', folder: true)}${node('${root.path}pie%20photo.png', 'image/png')}${node('${root.path}secret.txt', 'text/plain')}${node('https://evil.test/x.jpg', 'image/jpeg')}${node('${root.path}nested/x.jpg', 'image/jpeg')}</d:multistatus>';
      final files = NextcloudFilesService.parseListing(xml, root, root);
      expect(files.map((f) => f.path), ['/Photos', '/pie photo.png']);
    },
  );
  test('WebDAV malformed XML entities and traversal are rejected', () {
    final root = Uri.parse('https://cloud.test/files/u/');
    for (final xml in [
      'no xml',
      '<root/>',
      '<!DOCTYPE x><d:multistatus xmlns:d="DAV:"/>',
    ]) {
      expect(
        () => NextcloudFilesService.parseListing(xml, root, root),
        throwsA(isA<AppFailure>()),
      );
    }
    for (final path in ['relative', '/../private', '/a\\b']) {
      expect(
        () => NextcloudFilesService.segments(path),
        throwsA(isA<AppFailure>()),
      );
    }
  });
  for (final size in [100, 1000, 5000]) {
    test('library benchmark $size recipes', () async {
      await seed(
        List.generate(
          size,
          (i) => {
            'id': '$i',
            'name': 'Recipe ${i.toString().padLeft(5, '0')} with a long title',
            'recipeCategory': 'Category ${i % 500}',
            'keywords': 'tag${i % 1000},common',
            'recipeInstructions': List.filled(
              10,
              'A long instruction repeated for a realistic body.',
            ),
          },
        ),
      );
      final cold = Stopwatch()..start();
      await library.prepare();
      cold.stop();
      final warm = Stopwatch()..start();
      final page = await library.page(const LibraryFilter(), offset: size - 60);
      final categories = await library.categories();
      final keywords = await library.keywords(
        const LibraryFilter(keywords: ['common']),
      );
      warm.stop();
      expect(page.items.length, 60);
      expect(page.total, size);
      expect(categories.length, size < 500 ? size : 500);
      expect(keywords.length, (size < 1000 ? size : 1000) + 1);
      expect(
        await db.db.rawQuery(
          'EXPLAIN QUERY PLAN SELECT * FROM library_index WHERE account_id=? ORDER BY name_fold,id LIMIT 60',
          ['a'],
        ),
        isNotEmpty,
      );
      debugPrint(
        'LIBRARY_BENCHMARK recipes=$size coldIndexMs=${cold.elapsedMilliseconds} pageAndFacetsMs=${warm.elapsedMilliseconds} pageRows=${page.items.length}',
      );
    });
  }
}
