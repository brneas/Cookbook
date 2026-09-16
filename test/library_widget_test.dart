import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:cookbook/app/providers.dart';
import 'package:cookbook/core/theme/app_theme.dart';
import 'package:cookbook/features/recipes/data/library_repository.dart';
import 'package:cookbook/features/recipes/data/image_repository.dart';
import 'package:cookbook/features/recipes/presentation/library_providers.dart';
import 'package:cookbook/features/recipes/presentation/library_screen.dart';
import 'package:cookbook/features/recipes/presentation/categories_screen.dart';
import 'package:cookbook/features/recipes/presentation/filter_pickers.dart';
import 'package:cookbook/features/editor/presentation/linked_text_field.dart';
import 'package:cookbook/features/recipes/presentation/recipe_text.dart';

class VisualPreferences extends LibraryPreferencesController {
  VisualPreferences(this.grid);
  final bool grid;
  @override
  Future<LibraryPreferences> build() async => LibraryPreferences(grid: grid);
  @override
  Future<void> set({bool? grid, RecipeSort? sort}) async {
    final p = state.asData!.value;
    state = AsyncData(
      LibraryPreferences(grid: grid ?? p.grid, sort: sort ?? p.sort),
    );
  }
}

class IdleSync extends SyncController {
  @override
  SyncState build() => const SyncState();
  @override
  Future<void> sync() async {}
}

void main() {
  final key = GlobalKey();
  final requests = <int>[];
  final names = [
    'Slow-roasted tomatoes with lemon, thyme and toasted sourdough',
    'Chickpea & spinach stew',
    'Apple and blackberry crumble',
    'Sunday pancakes',
    'Roasted vegetable soup',
    'Lemon tart',
    'Fresh garden salad',
  ];
  final cats = [
    'Baking',
    'Breakfast',
    'Desserts',
    'Everyday dinners',
    'Salads',
    'Soups',
    'Very long category name for family celebrations and special occasions',
  ];
  Uint8List? thumbnail;
  Future<void> prepareAssets(WidgetTester tester) async {
    await tester.runAsync(() async {
      final font = Platform.environment['COOKBOOK_VISUAL_FONT'];
      final icons = Platform.environment['COOKBOOK_VISUAL_ICONS'];
      if (font != null) {
        await (FontLoader('Roboto')..addFont(
              Future.value(
                ByteData.sublistView(await File(font).readAsBytes()),
              ),
            ))
            .load();
      }
      if (icons != null) {
        await (FontLoader('MaterialIcons')..addFont(
              Future.value(
                ByteData.sublistView(await File(icons).readAsBytes()),
              ),
            ))
            .load();
      }
      // Synthetic placeholder photograph substitute, confined to the test fixture.
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 250, 180),
        Paint()..color = const Color(0xffece0ca),
      );
      canvas.drawCircle(
        const Offset(125, 90),
        72,
        Paint()..color = Colors.white,
      );
      canvas.drawCircle(
        const Offset(125, 90),
        57,
        Paint()..color = const Color(0xffa94728),
      );
      for (var i = 0; i < 8; i++) {
        canvas.drawCircle(
          Offset(90 + (i % 3) * 27, 60 + (i ~/ 3) * 27),
          9,
          Paint()..color = const Color(0xff697246),
        );
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(250, 180);
      thumbnail = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
    });
  }

  Future<void> pump(
    WidgetTester tester, {
    required String mode,
    Size size = const Size(390, 844),
    double scale = 1,
    int count = 5000,
    int categoryCount = 500,
    int keywordCount = 1000,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    requests.clear();
    final router = GoRouter(
      initialLocation: '/start',
      routes: [
        GoRoute(
          path: '/start',
          builder: (context, state) => Scaffold(
            appBar: AppBar(
              title: Text(mode == 'categories' ? 'Categories' : 'Recipes'),
            ),
            body: Row(
              children: [
                if (size.width >= 840)
                  NavigationRail(
                    selectedIndex: mode == 'categories' ? 1 : 0,
                    labelType: NavigationRailLabelType.all,
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.menu_book_outlined),
                        label: Text('Recipes'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.category_outlined),
                        label: Text('Categories'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.restaurant_outlined),
                        label: Text('Cooking'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.settings_outlined),
                        label: Text('Settings'),
                      ),
                    ],
                  ),
                Expanded(
                  child: switch (mode) {
                    'categories' => const CategoriesScreen(),
                    'category-picker' => const CategoryPicker(
                      selected: 'Baking',
                    ),
                    'keyword-picker' => const KeywordPicker(
                      filter: LibraryFilter(keywords: ['Quick']),
                    ),
                    _ => const LibraryScreen(),
                  },
                ),
              ],
            ),
            bottomNavigationBar: mode.contains('picker') || size.width >= 840
                ? null
                : NavigationBar(
                    selectedIndex: mode == 'categories' ? 1 : 0,
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.menu_book_outlined),
                        label: 'Recipes',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.category_outlined),
                        label: 'Categories',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.restaurant_outlined),
                        label: 'Cooking',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.settings_outlined),
                        label: 'Settings',
                      ),
                    ],
                  ),
          ),
        ),
        GoRoute(
          path: '/library',
          builder: (context, state) => Scaffold(
            appBar: AppBar(title: const Text('Filtered recipes')),
            body: LibraryScreen(
              initialCategory: state.uri.queryParameters['category'],
            ),
          ),
        ),
        GoRoute(
          path: '/recipe/:id',
          builder: (context, state) => Scaffold(
            appBar: AppBar(),
            body: Text('Recipe ${state.pathParameters['id']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncProvider.overrideWith(IdleSync.new),
          libraryPreferencesProvider.overrideWith(
            () => VisualPreferences(mode == 'grid'),
          ),
          libraryPageProvider.overrideWith((ref, r) async {
            requests.add(r.offset);
            return LibraryPage(
              List.generate((count - r.offset).clamp(0, 60), (i) {
                final n = i + r.offset;
                return LibraryItem(
                  '$n',
                  names[n % names.length],
                  n % 4 == 0 ? '' : cats[n % cats.length],
                  created: n % 3 == 0 ? null : DateTime(2024, 2, 12),
                  modified: DateTime(2026, 9, 10),
                );
              }),
              count,
            );
          }),
          categoryFacetsProvider.overrideWith(
            (_) async => List.generate(
              categoryCount,
              (i) => Facet(
                i == 0
                    ? ''
                    : i <= cats.length
                    ? cats[i - 1]
                    : 'Category $i',
                i + 1,
              ),
            ),
          ),
          keywordFacetsProvider.overrideWith(
            (_, filter) async => List.generate(
              keywordCount,
              (i) => Facet(
                i == 0
                    ? 'Quick'
                    : i == 1
                    ? 'Vegetarian'
                    : i == 2
                    ? 'A very long keyword for meals that can be prepared in advance'
                    : 'Keyword $i',
                i + 2,
                available: i % 5 != 4,
              ),
            ),
          ),
          recipeImageProvider.overrideWith(
            (_, id) async => int.parse(id) % 3 == 0 ? null : thumbnail,
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          theme: cookbookTheme(Brightness.light),
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
    if (thumbnail != null) {
      await tester.runAsync(() async {
        await precacheImage(
          ResizeImage(MemoryImage(thumbnail!), width: 250),
          key.currentContext!,
        );
      });
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  }

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    for (final mode in [
      'list',
      'grid',
      'categories',
      if (size.width == 390) ...['category-picker', 'keyword-picker'],
    ]) {
      testWidgets('preview $mode ${size.width}', (tester) async {
        await prepareAssets(tester);
        await pump(tester, mode: mode, size: size);
        expect(find.byType(TextField), findsWidgets);
        final output = Platform.environment['COOKBOOK_VISUAL_DIR'];
        if (output != null) {
          await tester.runAsync(() async {
            final image =
                await (key.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(output).create(recursive: true);
            await File(
              '$output/library-$mode-${size.width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }
  for (final mode in [
    'list',
    'grid',
    'categories',
    'category-picker',
    'keyword-picker',
  ]) {
    testWidgets('$mode long labels at 200% text', (tester) async {
      await pump(tester, mode: mode, scale: 2);
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -450));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
  for (final count in [100, 1000, 5000]) {
    for (final mode in ['list', 'grid']) {
      testWidgets('lazy $mode $count items scroll search sort', (tester) async {
        await pump(tester, mode: mode, count: count);
        expect(requests.toSet(), {0});
        await tester.drag(
          find.byType(Scrollable).first,
          const Offset(0, -1200),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ListTile).evaluate().length, lessThan(50));
        await tester.enterText(find.byType(TextField).first, 'soup');
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sort'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.ancestor(
            of: find.text('Modified · newest first'),
            matching: find.byType(CheckedPopupMenuItem<RecipeSort>),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final n in [0, 1, 20, 100, 500]) {
    testWidgets('category picker $n searchable lazy rows', (tester) async {
      await pump(tester, mode: 'category-picker', categoryCount: n);
      await tester.enterText(find.byType(TextField), 'Baking');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
  for (final n in [0, 20, 200, 1000]) {
    testWidgets('keyword picker $n searchable lazy rows', (tester) async {
      await pump(tester, mode: 'keyword-picker', keywordCount: n);
      await tester.enterText(find.byType(TextField), 'Quick');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('category navigation keeps back and rename action', (
    tester,
  ) async {
    await pump(tester, mode: 'categories');
    await tester.tap(find.byTooltip('Category actions for Baking'));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Baking'));
    await tester.pumpAndSettle();
    expect(find.text('Filtered recipes'), findsOneWidget);
    expect(find.byType(InputChip), findsWidgets);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Search categories'), findsOneWidget);
  });
  testWidgets('editor inserts stable recipe reference at cursor', (
    tester,
  ) async {
    String changed = '';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryPageProvider.overrideWith(
            (_, _) async =>
                const LibraryPage([LibraryItem('123', 'Stock', 'Basics')], 1),
          ),
          libraryPreferencesProvider.overrideWith(
            () => VisualPreferences(false),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: LinkedTextField(
              value: 'Add ',
              label: 'Step',
              onChanged: (s) => changed = s,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Insert recipe link'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stock'));
    await tester.pumpAndSettle();
    expect(changed, contains('#r/123'));
  });
  testWidgets('linked recipe text opens native route', (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: RecipeText('Use #r/123')),
        ),
        GoRoute(
          path: '/recipe/:id',
          builder: (_, state) => Text('Opened ${state.pathParameters['id']}'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recipeLinkNamesProvider.overrideWith(
            (_, _) async => {'123': 'Stock'},
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Stock', findRichText: true).first);
    await tester.pumpAndSettle();
    expect(find.text('Opened 123'), findsOneWidget);
  });
}
