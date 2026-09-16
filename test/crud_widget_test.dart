import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cookbook/app/providers.dart';
import 'package:cookbook/core/database/app_database.dart';
import 'package:cookbook/features/editor/presentation/editor_screen.dart';
import 'package:cookbook/features/editor/presentation/line_editor.dart';
import 'package:cookbook/features/import/presentation/import_screen.dart';
import 'package:cookbook/features/recipes/domain/recipe.dart';
import 'package:cookbook/features/recipes/presentation/recipe_actions.dart';
import 'package:cookbook/features/sync/presentation/conflict_screen.dart';
import 'package:cookbook/features/sync/presentation/sync_providers.dart';
import 'package:cookbook/features/sync/data/mutation_store.dart';
import 'widget_test.dart' show SavedAccount, OfflineSync;

void main() {
  sqfliteFfiInit();
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(
      factory: databaseFactoryFfiNoIsolate,
      path: inMemoryDatabasePath,
    );
    await db.db.insert('accounts', {
      'id': 'test',
      'server': 'https://cloud.test',
      'login_name': 'cook',
      'capabilities': '{}',
    });
  });
  tearDown(() async => db.close());
  Future<void> pump(WidgetTester tester, Widget child) async {
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => child),
        GoRoute(
          path: '/library',
          builder: (_, _) => const Scaffold(body: Text('Library')),
        ),
        GoRoute(
          path: '/recipe/:id',
          builder: (_, state) => Scaffold(
            body: Text('Saved locally: ${state.pathParameters['id']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountProvider.overrideWith(SavedAccount.new),
          syncProvider.overrideWith(OfflineSync.new),
          databaseProvider.overrideWith((_) async => db),
          taxonomyProvider.overrideWith(
            (_) async => {
              'categories': ['Dinner'],
              'keywords': ['Quick'],
            },
          ),
        ],
        child: MaterialApp.router(
          theme: ThemeData.dark(useMaterial3: true),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> settleDb(WidgetTester tester) async {
    await tester.pumpAndSettle();
  }

  Finder field(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(TextFormField));
  testWidgets(
    'background provider refresh does not replace an unsaved editor draft',
    (tester) async {
      final json = jsonEncode({'id': '42', 'name': 'Before'});
      await db.db.insert('recipes', {
        'account_id': 'test',
        'id': '42',
        'name': 'Before',
        'stub_json': json,
        'detail_json': json,
        'base_json': json,
        'server_json': json,
      });
      await pump(tester, const EditorScreen(id: '42'));
      await tester.enterText(field('Recipe name'), 'Unsaved draft');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(RecipeEditor)),
      );
      await db.db.update(
        'recipes',
        {
          'name': 'Background version',
          'detail_json': '{"id":"42","name":"Background version"}',
        },
        where: 'id=?',
        whereArgs: ['42'],
      );
      container.read(syncProvider.notifier).localChanged();
      await tester.pumpAndSettle();
      expect(find.text('Unsaved draft'), findsOneWidget);
      await tester.tap(find.text('Save recipe'));
      await tester.pumpAndSettle();
      expect(find.text('Unsaved draft'), findsOneWidget);
      expect(find.textContaining('Review before saving'), findsOneWidget);
      expect(await db.db.query('pending_operations'), isEmpty);
    },
  );
  testWidgets(
    'native edit queues changed field while preserving unedited nested JSON',
    (tester) async {
      final recipe = Recipe.fromJson({
        'id': '42',
        'name': 'Before',
        'author': {
          'name': 'Writer',
          'custom': {'keep': true},
        },
        'recipeInstructions': {
          '@type': 'HowToStep',
          'text': 'Stir',
          'custom': 12,
        },
      });
      await db.db.insert('recipes', {
        'account_id': 'test',
        'id': '42',
        'name': recipe.name,
        'stub_json': jsonEncode(recipe.toJson()),
        'detail_json': jsonEncode(recipe.toJson()),
        'base_json': jsonEncode(recipe.toJson()),
        'server_json': jsonEncode(recipe.toJson()),
      });
      await pump(tester, RecipeEditor(recipe: recipe));
      await tester.enterText(field('Recipe name'), 'After');
      await tester.tap(find.text('Save recipe'));
      await settleDb(tester);
      final op = (await db.db.query('pending_operations')).single;
      expect(op['kind'], 'update');
      expect(jsonDecode(op['payload_json'] as String), {
        ...recipe.toJson(),
        'name': 'After',
      });
      expect(jsonDecode(op['base_json'] as String), recipe.toJson());
    },
  );
  for (final label in ['Ingredient', 'Tool']) {
    testWidgets(
      '$label line controls add edit reorder and remove with accessible labels',
      (tester) async {
        final values = <String>['First', 'Second'];
        var revision = 0;
        await pump(
          tester,
          Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => ListView(
                children: [
                  LineEditor(
                    label: label,
                    lines: values,
                    revision: revision,
                    onEdit: (i, s) => values[i] = s,
                    onAdd: () => setState(() {
                      values.add('');
                      revision++;
                    }),
                    onRemove: (i) => setState(() {
                      values.removeAt(i);
                      revision++;
                    }),
                    onMove: (a, b) => setState(() {
                      values.insert(b, values.removeAt(a));
                      revision++;
                    }),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('$label 1 actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Move $label 1 down'));
        await tester.pumpAndSettle();
        expect(values, ['Second', 'First']);
        await tester.enterText(field('$label 1'), 'Edited');
        await tester.tap(find.byTooltip('$label 2 actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove $label 2'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add ${label.toLowerCase()}'));
        await tester.pumpAndSettle();
        expect(values, ['Edited', '']);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'Add Recipe validates name, saves offline, and preserves full local queue payload',
    (tester) async {
      await pump(tester, const RecipeEditor());
      await tester.tap(find.text('Save recipe'));
      await tester.pumpAndSettle();
      expect(find.text('A recipe name is required'), findsOneWidget);
      await tester.enterText(field('Recipe name'), 'Offline dinner');
      await tester.tap(find.text('Save recipe'));
      await settleDb(tester);
      expect(find.textContaining('Saved locally:'), findsOneWidget);
      final rows = await db.db.query('pending_operations');
      expect(rows.single['kind'], 'create');
      expect(rows.single['state'], 'queued');
      expect(
        jsonDecode(rows.single['payload_json'] as String)['name'],
        'Offline dinner',
      );
    },
  );
  testWidgets(
    'unsaved changes require explicit discard and retain form on cancel',
    (tester) async {
      await pump(tester, const RecipeEditor());
      await tester.enterText(field('Recipe name'), 'Unsaved');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Discard unsaved changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Unsaved'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard changes'));
      await tester.pumpAndSettle();
      expect(find.text('Library'), findsOneWidget);
    },
  );
  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    testWidgets(
      'Edit Recipe long name, dark mode, 200% text at ${size.width}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pump(
          tester,
          RecipeEditor(
            recipe: Recipe.fromJson({
              'id': '42',
              'name': List.filled(12, 'A very long recipe name').join(' '),
              'recipeIngredient': [],
              'recipeInstructions': [],
            }),
          ),
        );
        expect(find.text('Edit Recipe'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Ingredients'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Ingredients'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('No ingredient yet.'),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('No ingredient yet.'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Instructions'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Instructions'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('No step yet.'),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('No step yet.'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('category suggestion updates visible form value', (tester) async {
    await pump(tester, const RecipeEditor());
    await tester.ensureVisible(find.text('Dinner'));
    await tester.tap(find.text('Dinner'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(field('Category')).controller!.text,
      'Dinner',
    );
  });
  testWidgets(
    'delete confirmation identifies recipe and cancel keeps queue unchanged',
    (tester) async {
      final store = MutationStore(db, 'test');
      final id = await store.save(
        Recipe.fromJson({'name': 'Named dinner'}),
        create: true,
      );
      await pump(
        tester,
        Scaffold(
          body: RecipeActions(
            Recipe.fromJson({'id': id, 'name': 'Named dinner'}),
          ),
        ),
      );
      await settleDb(tester);
      expect(find.textContaining('Saved locally'), findsOneWidget);
      await tester.tap(find.text('Delete recipe'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Delete “Named dinner”'), findsOneWidget);
      await tester.tap(find.text('Keep recipe'));
      await tester.pumpAndSettle();
      expect(await db.db.query('pending_operations'), hasLength(1));
      await tester.tap(find.text('Delete recipe'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete recipe'));
      await settleDb(tester);
      expect((await db.db.query('pending_operations')).last['kind'], 'delete');
      expect(find.textContaining('Deletion queued · undo'), findsOneWidget);
    },
  );
  testWidgets(
    'URL import rejects invalid input then queues server-side import offline',
    (tester) async {
      await pump(tester, const ImportScreen());
      await tester.tap(find.text('Import recipe'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Enter a complete'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField),
        'https://example.invalid/recipe',
      );
      await tester.tap(find.text('Import recipe'));
      await settleDb(tester);
      final op = (await db.db.query('pending_operations')).single;
      expect(op['kind'], 'import');
      expect(op['state'], 'queued');
      expect(jsonDecode(op['payload_json'] as String), {
        'url': 'https://example.invalid/recipe',
      });
    },
  );
  testWidgets('conflict exposes Base Local Server and explicit decisions', (
    tester,
  ) async {
    await db.db.insert('conflicts', {
      'account_id': 'test',
      'recipe_id': '42',
      'kind': 'update',
      'base_json': '{"name":"Before"}',
      'local_json': '{"name":"My version"}',
      'server_json': '{"name":"Their version"}',
    });
    await pump(tester, const ConflictScreen('42'));
    await settleDb(tester);
    expect(find.text('Base: "Before"'), findsOneWidget);
    expect(find.text('Local: "My version"'), findsOneWidget);
    expect(find.text('Server: "Their version"'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Keep Local'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Keep Server'), findsOneWidget);
    expect(find.text('Decide Later'), findsOneWidget);
  });
}
