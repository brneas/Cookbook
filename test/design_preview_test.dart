import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cookbook/app/providers.dart';
import 'package:cookbook/app/shell.dart';
import 'package:cookbook/core/database/app_database.dart';
import 'package:cookbook/core/theme/app_theme.dart';
import 'package:cookbook/core/theme/server_theme.dart';
import 'package:cookbook/features/cooking/data/cooking_repository.dart';
import 'package:cookbook/features/cooking/presentation/cooking_providers.dart';
import 'package:cookbook/features/cooking/presentation/cooking_screen.dart';
import 'package:cookbook/features/editor/presentation/editor_screen.dart';
import 'package:cookbook/features/recipes/data/image_repository.dart';
import 'package:cookbook/features/recipes/data/library_repository.dart';
import 'package:cookbook/features/recipes/domain/recipe.dart';
import 'package:cookbook/features/recipes/presentation/library_providers.dart';
import 'package:cookbook/features/recipes/presentation/recipe_screen.dart';
import 'package:cookbook/features/settings/presentation/settings_screen.dart';
import 'package:cookbook/features/settings/presentation/server_settings.dart';
import 'package:cookbook/features/settings/data/server_cookbook_settings.dart';
import 'package:cookbook/features/sync/presentation/sync_providers.dart';
import 'support/fake_timer_notifications.dart';
import 'package:cookbook/features/recipes/presentation/detail_ingredients.dart';
import 'package:cookbook/features/recipes/data/ingredient_check_store.dart';
import 'widget_test.dart' show SavedAccount;
import 'library_widget_test.dart' show IdleSync, VisualPreferences;

// Synthetic fixtures only. Never imported by production code or APK entrypoints.
Recipe sample({bool long = false, bool edge = false}) => Recipe.fromJson({
  'id': '42',
  'name': edge
      ? 'Slow-roasted winter vegetables with chickpeas, preserved lemon and toasted sourdough for a family gathering'
      : long
      ? 'Sunday vegetable feast'
      : 'Lemon & herb chickpeas',
  'description':
      'A warming one-pan supper with bright lemon, tender chickpeas and fresh herbs. Serve with crusty bread.',
  'recipeCategory': 'Everyday dinners',
  'keywords': 'Vegetarian,Weeknight',
  'recipeYield': edge ? 'One generous casserole' : '4 servings',
  'prepTime': 'PT10M',
  'cookTime': 'PT20M',
  'totalTime': 'PT30M',
  'recipeIngredient': [
    '2 tbsp olive oil',
    '1 onion, finely sliced',
    '2 cans chickpeas, drained',
    '½ lemon, zest and juice',
    '1 handful fresh parsley',
    if (long || edge)
      ...List.generate(20, (i) => '${i % 3 + 1} ½ tsp mixed spice ${i + 1}'),
  ],
  'recipeInstructions': [
    {
      '@type': 'HowToSection',
      'name': 'Prepare',
      'itemListElement': [
        'Warm the olive oil in a wide pan. Add the onion and cook gently for 5 minutes.',
        'Stir in the chickpeas and lemon zest. Season with salt and freshly ground pepper.',
      ],
    },
    {
      '@type': 'HowToSection',
      'name': 'Cook & serve',
      'itemListElement': [
        'Add a splash of water, cover and simmer for 15 minutes. Stir occasionally.',
        'Finish with lemon juice and parsley. Taste, adjust the seasoning and serve warm.',
        if (long || edge)
          ...List.generate(
            12,
            (i) =>
                'Prepare accompaniment ${i + 1}. Stir gently and taste before serving. Rest for ${i + 2} minutes.',
          ),
      ],
    },
  ],
});

void main() {
  sqfliteFfiInit();
  for (final scenario in [
    'unchecked',
    'checked',
    'ingredient-handles',
    'instruction-handles',
    'before',
    'after',
    'menu',
    'stale-menu',
  ]) {
    testWidgets('interaction preview $scenario', (tester) async {
      await preview(
        tester,
        size: const Size(390, 844),
        mode: scenario.contains('handles')
            ? 'editor'
            : ['unchecked', 'checked'].contains(scenario)
            ? 'detail'
            : 'focus',
        interaction: scenario,
      );
    });
  }
  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    for (final mode in [
      'list',
      'grid',
      'categories',
      'detail',
      'editor',
      'recipe',
      'focus',
      'timer',
      'settings',
    ]) {
      testWidgets('design ${size.width.toInt()} $mode', (tester) async {
        await preview(tester, size: size, mode: mode);
      });
    }
  }
  for (final mode in ['detail', 'editor', 'recipe', 'focus', 'settings']) {
    testWidgets('design edge dark 200% $mode', (tester) async {
      await preview(
        tester,
        size: const Size(390, 844),
        mode: mode,
        edge: true,
        scale: 2,
        dark: true,
      );
    });
  }
  testWidgets('design tablet long recipe dark custom theme', (tester) async {
    await preview(
      tester,
      size: const Size(1200, 900),
      mode: 'recipe',
      long: true,
      dark: true,
    );
  });
}

Future<void> preview(
  WidgetTester tester, {
  required Size size,
  required String mode,
  String? interaction,
  bool edge = false,
  bool long = false,
  bool dark = false,
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  Uint8List? bytes;
  await tester.runAsync(() async {
    for (final entry in {
      'Roboto': 'COOKBOOK_VISUAL_FONT',
      'MaterialIcons': 'COOKBOOK_VISUAL_ICONS',
    }.entries) {
      final path = Platform.environment[entry.value];
      if (path != null) {
        await (FontLoader(entry.key)..addFont(
              Future.value(
                ByteData.sublistView(await File(path).readAsBytes()),
              ),
            ))
            .load();
      }
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawPaint(Paint()..color = const Color(0xffe6d7bf));
    canvas.drawCircle(
      const Offset(320, 200),
      170,
      Paint()..color = const Color(0xfffaf6ee),
    );
    canvas.drawCircle(
      const Offset(320, 200),
      142,
      Paint()..color = const Color(0xffce9447),
    );
    for (var i = 0; i < 48; i++) {
      canvas.drawCircle(
        Offset(215 + (i % 8) * 30, 110 + (i ~/ 8) * 34),
        12,
        Paint()..color = const Color(0xffeed2a2),
      );
    }
    for (var i = 0; i < 9; i++) {
      canvas.drawOval(
        Rect.fromLTWH(230 + (i % 3) * 65, 120 + (i ~/ 3) * 65, 32, 12),
        Paint()..color = const Color(0xff546d3b),
      );
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(640, 400);
    bytes = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
    picture.dispose();
  });
  final recipe = sample(long: long, edge: edge);
  final db = (await tester.runAsync(
    () => AppDatabase.open(
      factory: databaseFactoryFfiNoIsolate,
      path: inMemoryDatabasePath,
    ),
  ))!;
  addTearDown(db.close);
  await tester.runAsync(
    () => db.db.insert('accounts', {
      'id': 'test',
      'server': 'https://cloud.test',
      'login_name': 'cook',
      'capabilities': '{}',
    }),
  );
  final repo = CookingRepository(db, 'test');
  final session = (await tester.runAsync(() => repo.start(recipe)))!;
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWith((_) async => db),
      accountProvider.overrideWith(SavedAccount.new),
      syncProvider.overrideWith(IdleSync.new),
      cookingRepositoryProvider.overrideWith((_) async => repo),
      timerNotificationsProvider.overrideWithValue(FakeTimerNotifications()),
      keepAwakeProvider.overrideWithValue((_) async {}),
      recipeDetailProvider.overrideWith(
        (_, _) async => interaction == 'stale-menu'
            ? recipe.patch({'name': 'Updated lemon & herb chickpeas'})
            : recipe,
      ),
      recipeRecordProvider.overrideWith(
        (_, _) async => {
          'detail_json': jsonEncode(recipe.toJson()),
          'sync_state': 'clean',
          'local_deleted': 0,
        },
      ),
      recipeImageProvider.overrideWith(
        (_, id) async => edge || id == '3' ? null : bytes,
      ),
      recipeFullImageProvider.overrideWith((_, _) async => edge ? null : bytes),
      taxonomyProvider.overrideWith(
        (_) async => {
          'categories': ['Everyday dinners', 'Baking'],
          'keywords': ['Vegetarian', 'Weeknight'],
        },
      ),
      libraryPreferencesProvider.overrideWith(
        () => VisualPreferences(mode == 'grid'),
      ),
      libraryPageProvider.overrideWith(
        (_, _) async => LibraryPage([
          LibraryItem('42', recipe.name, recipe.category),
          const LibraryItem('2', 'Roasted tomato soup', 'Soups'),
          const LibraryItem('3', 'Sunday sourdough', 'Baking'),
          const LibraryItem('4', 'Apple & blackberry crumble', 'Desserts'),
          const LibraryItem('5', 'Fresh garden salad', 'Salads'),
          const LibraryItem('6', 'Pancakes with berry compote', 'Breakfast'),
        ], 6),
      ),
      categoryFacetsProvider.overrideWith(
        (_) async => const [
          Facet('Everyday dinners', 12),
          Facet('Baking', 8),
          Facet('Breakfast', 5),
          Facet('Desserts', 9),
          Facet('Salads', 4),
          Facet('Soups', 7),
        ],
      ),
      serverSettingsProvider.overrideWith(
        (_) async => const ServerCookbookSettings({
          'folder': '/Recipes',
          'update_interval': 5,
        }),
      ),
      accountStatusProvider.overrideWith(
        (_) async => {'last_success': 'Today, 10:42'},
      ),
      diagnosticsProvider.overrideWith(
        (_) async => {
          'nextcloud_version': '34',
          'last_connection_test': 'Today, 10:42',
          'cache_bytes': 12582912,
          'cache_limit': 209715200,
          'local_count': 45,
          'detected': true,
          'api_version': '0.1.0',
        },
      ),
    ],
  );
  await tester.runAsync(() async {
    if (mode == 'detail') {
      container.listen(detailChecksProvider('42'), (_, _) {});
      await container.read(detailChecksProvider('42').future);
    }
    await container.read(cookingProvider.future);
    await container.read(cookingPreferencesProvider.future);
    if (mode == 'focus') {
      await container
          .read(cookingPreferencesProvider.notifier)
          .set('presentation', 'focus');
    }
    if (mode == 'timer' || long) {
      await container
          .read(cookingProvider.notifier)
          .addTimer(const Duration(minutes: 15), 'Chickpeas', session: session);
      await container
          .read(cookingProvider.notifier)
          .addTimer(const Duration(minutes: 5), 'Warm bread', session: session);
    }
  });
  final key = GlobalKey();
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => switch (mode) {
          'detail' => const RecipeScreen('42'),
          'editor' => RecipeEditor(recipe: recipe),
          'recipe' || 'focus' || 'timer' => CookingScreen(session.id),
          _ => AppShell(
            initialIndex: mode == 'settings'
                ? 3
                : mode == 'categories'
                ? 1
                : 0,
          ),
        },
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: cookbookTheme(
          dark ? Brightness.dark : Brightness.light,
          server: dark
              ? ServerTheme.parse({'color': '#7342a5'})
              : const ServerTheme(),
        ),
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: key, child: child!),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
  });
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  if (mode == 'timer') {
    await tester.tap(find.widgetWithText(TextButton, 'Timers'));
    await tester.pumpAndSettle();
  }
  if (interaction != null) {
    if (mode == 'detail') {
      await tester.runAsync(
        () => container.read(detailChecksProvider('42').future),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('2 tbsp olive oil'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('2 tbsp olive oil'));
      await tester.pumpAndSettle();
      if (interaction == 'checked') {
        await tester.runAsync(() async {
          for (final key in ingredientKeys(recipe.ingredients).take(2)) {
            await container
                .read(detailChecksProvider('42').notifier)
                .change(toggle: key);
          }
        });
        await tester.pumpAndSettle();
        expect(container.read(detailChecksProvider('42')).value!.length, 2);
      }
    } else if (mode == 'editor') {
      final heading = interaction == 'ingredient-handles'
          ? 'Ingredients'
          : 'Instructions';
      await tester.scrollUntilVisible(
        find.text(heading),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(heading));
      await tester.pumpAndSettle();
      final handle = find
          .byTooltip(
            interaction == 'ingredient-handles'
                ? 'Drag Ingredient 1'
                : 'Drag Step 1',
          )
          .first;
      for (var i = 0; i < 25 && handle.hitTestable().evaluate().isEmpty; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -180));
        await tester.pumpAndSettle();
      }
      expect(handle.hitTestable(), findsOneWidget);
      // Show several rows, not just the first handle at the bottom edge.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -280));
      await tester.pumpAndSettle();
    } else if (interaction == 'after') {
      await tester.ensureVisible(find.text('Step completed'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Step completed'));
        await container.read(cookingProvider.notifier).settled;
      });
      await tester.pumpAndSettle();
      expect((await repo.sessions()).single.current, 1);
    } else if (interaction.endsWith('menu')) {
      await tester.tap(find.byTooltip('Cooking options'));
      await tester.pumpAndSettle();
      expect(find.text('Finish Cooking').last, findsOneWidget);
      expect(
        find.text('Restart with Updated Recipe'),
        interaction == 'stale-menu' ? findsOneWidget : findsNothing,
      );
    }
  }
  final output = Platform.environment['COOKBOOK_VISUAL_DIR'];
  if (output != null) {
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(output).create(recursive: true);
      await File(
        '$output/design-${size.width.toInt()}-$mode${interaction == null ? '' : '-$interaction'}${edge ? '-edge-200' : ''}${long ? '-long' : ''}${dark ? '-dark' : ''}.png',
      ).writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    });
  }
  if (mode == 'recipe' && !edge && size.width == 390) {
    await tester.tap(find.widgetWithText(TextButton, 'Steps'));
    await tester.pumpAndSettle();
    if (output != null) {
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$output/design-390-recipe-steps.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
    }
  }
  // Scroll each primary surface as well as checking the initial screenshot.
  if (find.byType(Scrollable).hitTestable().evaluate().isNotEmpty) {
    await tester.drag(
      find.byType(Scrollable).hitTestable().first,
      const Offset(0, -650),
    );
    await tester.pumpAndSettle();
  }
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox());
  router.dispose();
  container.dispose();
  await tester.runAsync(db.close);
}
