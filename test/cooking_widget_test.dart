import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cookbook/app/providers.dart';
import 'package:cookbook/core/database/app_database.dart';
import 'package:cookbook/core/theme/app_theme.dart';
import 'package:cookbook/core/theme/server_theme.dart';
import 'package:cookbook/features/cooking/data/cooking_repository.dart';
import 'package:cookbook/features/cooking/domain/cooking_models.dart';
import 'package:cookbook/features/cooking/presentation/cooking_providers.dart';
import 'package:cookbook/features/cooking/presentation/cooking_screen.dart';
import 'package:cookbook/features/cooking/presentation/cooking_hub.dart';
import 'package:cookbook/features/cooking/presentation/timers_panel.dart';
import 'package:cookbook/features/recipes/domain/recipe.dart';
import 'package:cookbook/features/recipes/presentation/recipe_screen.dart';
import 'support/fake_timer_notifications.dart';

void main() {
  sqfliteFfiInit();
  late AppDatabase db;
  late CookingRepository repo;
  late ProviderContainer container;
  late CookingSession session;
  late FakeTimerNotifications notifications;
  final wakeEvents = <bool>[];
  final captureKey = GlobalKey();
  final recipe = Recipe.fromJson({
    'id': '1',
    'name': 'Kitchen bread',
    'recipeYield': '4 servings',
    'recipeIngredient': ['1 cup milk', 'salt to taste'],
    'recipeInstructions': [
      {
        '@type': 'HowToSection',
        'name': 'Dough',
        'itemListElement': ['Mix gently.', 'Rest for 20 minutes.'],
      },
    ],
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
    repo = CookingRepository(db, 'a');
    session = await repo.start(recipe);
    notifications = FakeTimerNotifications();
    wakeEvents.clear();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((_) async => db),
        cookingRepositoryProvider.overrideWith((_) async => repo),
        timerNotificationsProvider.overrideWithValue(notifications),
        keepAwakeProvider.overrideWithValue((enabled) async {
          wakeEvents.add(enabled);
        }),
        recipeDetailProvider.overrideWith((_, id) async => recipe),
      ],
    );
    await container.read(cookingProvider.future);
    await container.read(cookingPreferencesProvider.future);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });
  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double scale = 1,
    Brightness brightness = Brightness.light,
    Widget? child,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      initialLocation: '/cook',
      routes: [
        GoRoute(
          path: '/cook',
          builder: (_, _) => child ?? CookingScreen(session.id),
        ),
        GoRoute(
          path: '/cooking',
          builder: (_, _) => const Scaffold(body: CookingHub()),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: cookbookTheme(
            brightness,
            server: ServerTheme.parse({'color': '#123456'}),
          ),
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: captureKey, child: child!),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      await container.read(cookingProvider.notifier).settled;
    });
  }

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    testWidgets('cooking visual preview $size', (tester) async {
      final font = Platform.environment['COOKBOOK_VISUAL_FONT'];
      if (font != null) {
        await tester.runAsync(() async {
          final loader = FontLoader('Roboto')
            ..addFont(
              Future.value(
                ByteData.sublistView(await File(font).readAsBytes()),
              ),
            );
          await loader.load();
          final icons = Platform.environment['COOKBOOK_VISUAL_ICONS'];
          if (icons != null) {
            await (FontLoader('MaterialIcons')..addFont(
                  Future.value(
                    ByteData.sublistView(await File(icons).readAsBytes()),
                  ),
                ))
                .load();
          }
        });
      }
      await pump(
        tester,
        size: size,
        brightness: size.width > 840 ? Brightness.dark : Brightness.light,
      );
      expect(find.text('Mix gently.'), findsOneWidget);
      expect(tester.takeException(), null);
      final output = Platform.environment['COOKBOOK_VISUAL_DIR'];
      if (output != null) {
        await tester.runAsync(() async {
          final boundary =
              captureKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(output).create(recursive: true);
          await File(
            '$output/cooking-${size.width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
  testWidgets('detail offers Resume Cooking for the existing session', (
    tester,
  ) async {
    await pump(tester, child: Scaffold(body: StartCookingButton(recipe)));
    expect(find.text('Resume Cooking'), findsOneWidget);
  });
  testWidgets(
    'manual timer form starts a persisted timer without an automatic permission nag',
    (tester) async {
      await tester.runAsync(
        () => container
            .read(cookingPreferencesProvider.notifier)
            .set('notificationAsked', 'true'),
      );
      await pump(tester, child: const Scaffold(body: TimersPanel()));
      await tap(tester, find.text('Add Timer'));
      await tester.pumpAndSettle();
      await tap(tester, find.text('Start Timer'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => container.read(cookingProvider.notifier).settled,
      );
      expect((await repo.timers()).single.duration.inMinutes, 5);
      expect(notifications.requests, 0);
    },
  );

  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(900, 1200),
    const Size(1200, 900),
  ]) {
    testWidgets(
      'cooking layout $size dark custom theme 200 percent extra large',
      (tester) async {
        await tester.runAsync(
          () => container
              .read(cookingPreferencesProvider.notifier)
              .set('size', 'Extra Large'),
        );
        await pump(tester, size: size, scale: 2, brightness: Brightness.dark);
        expect(find.text('Kitchen bread'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Mix gently.'),
          150,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.text('Mix gently.'), findsOneWidget);
        expect(tester.takeException(), null);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(wakeEvents.last, false);
      },
    );
  }
  testWidgets(
    'phone recipe workspace scales, preserves original, and retains checks',
    (tester) async {
      await pump(tester);
      await tap(tester, find.widgetWithText(TextButton, 'Ingredients'));
      await tester.pump();
      await tester.pumpAndSettle();
      await tap(tester, find.text('+ 1 serving'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('1 1/4 cup milk'), findsOneWidget);
      expect(find.text('salt to taste'), findsOneWidget);
      await tester.ensureVisible(find.text('salt to taste'));
      await tap(tester, find.widgetWithText(CheckboxListTile, 'salt to taste'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect((await repo.sessions()).single.checks('ingredients'), {1});
      await tester.ensureVisible(find.text('Show original'));
      await tap(tester, find.text('Show original'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.textContaining('Original: 1 cup milk'), findsOneWidget);
      expect(tester.takeException(), null);
    },
  );
  testWidgets(
    'step navigation completion persists and section remains visible',
    (tester) async {
      await tester.runAsync(
        () => container
            .read(cookingPreferencesProvider.notifier)
            .set('presentation', 'focus'),
      );
      await pump(tester);
      await tester.ensureVisible(find.text('Next'));
      await tap(tester, find.text('Next'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('Rest for 20 minutes.'), findsOneWidget);
      expect(find.text('Dough'), findsOneWidget);
      await tap(tester, find.text('Step completed'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect((await repo.sessions()).single.current, 1);
      expect((await repo.sessions()).single.checks('steps'), {1});
      expect(find.text('Start 20 min timer'), findsOneWidget);
    },
  );
  for (final presentation in ['recipe', 'focus']) {
    testWidgets(
      '$presentation completion automatically advances persisted current step',
      (tester) async {
        await tester.runAsync(
          () => container
              .read(cookingPreferencesProvider.notifier)
              .set('presentation', presentation),
        );
        await pump(tester);
        if (presentation == 'recipe') {
          await tap(tester, find.widgetWithText(TextButton, 'Steps'));
          await tester.pumpAndSettle();
        }
        final label = presentation == 'recipe'
            ? 'Step 1 completed'
            : 'Step completed';
        await tester.ensureVisible(
          find.widgetWithText(CheckboxListTile, label),
        );
        await tester.pumpAndSettle();
        if (presentation == 'recipe') {
          await tester.drag(find.byType(Scrollable).last, const Offset(0, -40));
          await tester.pumpAndSettle();
        }
        await tap(tester, find.widgetWithText(CheckboxListTile, label));
        await tester.pumpAndSettle();
        expect((await repo.sessions()).single.current, 1);
        expect((await repo.sessions()).single.checks('steps'), {0});
        expect(find.text('Rest for 20 minutes.'), findsOneWidget);
      },
    );
  }
  testWidgets(
    'overflow finish keeps timer decision flow and unchanged snapshot hides restart',
    (tester) async {
      await tester.runAsync(
        () => container
            .read(cookingProvider.notifier)
            .addTimer(const Duration(minutes: 10), 'Bread', session: session),
      );
      await pump(tester);
      await tap(tester, find.byTooltip('Cooking options'));
      await tester.pumpAndSettle();
      expect(find.text('Start Over'), findsNothing);
      expect(find.text('Restart with Updated Recipe'), findsNothing);
      await tap(
        tester,
        find.widgetWithText(PopupMenuItem<String>, 'Finish Cooking'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Keep timers running'), findsOneWidget);
      expect(find.text('Stop timers'), findsOneWidget);
      await tap(tester, find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await repo.sessions()).single.active, true);
      expect((await repo.timers()).single.running, true);
    },
  );
  testWidgets('finish asks about active timers and keep preserves them', (
    tester,
  ) async {
    await tester.runAsync(
      () => container
          .read(cookingProvider.notifier)
          .addTimer(const Duration(minutes: 10), 'Bread', session: session),
    );
    await pump(tester);
    await tester.ensureVisible(find.text('Finish Cooking'));
    await tap(tester, find.text('Finish Cooking'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Keep timers running'), findsOneWidget);
    await tap(tester, find.text('Keep timers running'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect((await repo.sessions()).single.active, false);
    expect((await repo.timers()).single.running, true);
    expect(find.text('Your kitchen'), findsOneWidget);
    expect(wakeEvents.last, false);
  });
  testWidgets('timer panel supports multiple timers and pause', (tester) async {
    await tester.runAsync(
      () => container
          .read(cookingProvider.notifier)
          .addTimer(const Duration(minutes: 10), 'Bread', session: session),
    );
    await tester.runAsync(
      () => container
          .read(cookingProvider.notifier)
          .addTimer(const Duration(minutes: 5), 'Sauce'),
    );
    await pump(tester, child: const Scaffold(body: TimersPanel()));
    expect(find.text('Bread'), findsOneWidget);
    await tap(tester, find.text('Pause').first);
    await tester.pump();
    await tester.pumpAndSettle();
    expect((await repo.timers()).first.status, 'paused');
    expect(find.text('Resume'), findsOneWidget);
    expect(tester.takeException(), null);
  });
  testWidgets('no instructions or ingredients remains usable', (tester) async {
    session = (await tester.runAsync(
      () => repo.start(Recipe.fromJson({'id': '2', 'name': 'Empty recipe'})),
    ))!;
    await tester.runAsync(
      () => container.read(cookingProvider.notifier).refresh(),
    );
    await pump(tester, size: const Size(1200, 900));
    expect(find.text('No instructions provided'), findsOneWidget);
    expect(find.text('No ingredients provided.'), findsOneWidget);
    expect(find.text('Finish Cooking'), findsOneWidget);
    expect(tester.takeException(), null);
  });
  testWidgets('very long instruction and many ingredients remain scrollable', (
    tester,
  ) async {
    session = (await tester.runAsync(
      () => repo.start(
        recipe.patch({
          'id': '3',
          'recipeInstructions': [List.filled(250, 'Stir gently.').join(' ')],
          'recipeIngredient': List.generate(100, (i) => '$i cups flour'),
        }),
      ),
    ))!;
    await tester.runAsync(
      () => container.read(cookingProvider.notifier).refresh(),
    );
    await pump(tester, size: const Size(1200, 900));
    expect(tester.takeException(), null);
    await tester.scrollUntilVisible(
      find.text('Finish Cooking'),
      600,
      scrollable: find.byType(Scrollable).last,
    );
    expect(tester.takeException(), null);
  });
  testWidgets(
    'recipe default shows both sections and jump preserves all steps',
    (tester) async {
      await pump(tester);
      expect(
        container.read(cookingPreferencesProvider).asData!.value.presentation,
        'recipe',
      );
      expect(find.text('Mix gently.'), findsOneWidget);
      expect(find.text('Rest for 20 minutes.'), findsOneWidget);
      await tap(tester, find.widgetWithText(TextButton, 'Steps'));
      await tester.pumpAndSettle();
      final stepRect = tester.getRect(find.text('Mix gently.'));
      expect(stepRect.top, greaterThan(190));
      expect(stepRect.bottom, lessThan(844));
      expect(find.text('salt to taste'), findsOneWidget);
      expect((await repo.sessions()).single.checks('steps'), isEmpty);
      await tap(tester, find.widgetWithText(TextButton, 'Ingredients'));
      await tester.pumpAndSettle();
      expect(
        find.text('Original yield: 4 servings').hitTestable(),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'focus preference persists without changing completion and ingredients expand inline',
    (tester) async {
      await pump(tester);
      await tap(tester, find.text('Focus'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Rest for 20 minutes.'), findsNothing);
      await tap(tester, find.widgetWithText(TextButton, 'Ingredients'));
      await tester.pumpAndSettle();
      expect(find.text('salt to taste'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect((await repo.sessions()).single.checks('steps'), isEmpty);
      container.invalidate(cookingPreferencesProvider);
      final restored = await tester.runAsync(
        () => container.read(cookingPreferencesProvider.future),
      );
      expect(restored!.presentation, 'focus');
    },
  );
  testWidgets('timer ticks do not rebuild the recipe workspace', (
    tester,
  ) async {
    await tester.runAsync(
      () => container
          .read(cookingProvider.notifier)
          .addTimer(const Duration(minutes: 10), 'Bread', session: session),
    );
    await pump(tester);
    final before = tester.widget(find.text('Mix gently.'));
    await tester.pump(const Duration(seconds: 3));
    expect(identical(before, tester.widget(find.text('Mix gently.'))), isTrue);
    expect((await repo.sessions()).single.checks('steps'), isEmpty);
  });
  testWidgets('tablet ingredient jump restores its independent scroll pane', (
    tester,
  ) async {
    session = (await tester.runAsync(
      () => repo.start(
        recipe.patch({
          'id': 'long',
          'recipeIngredient': List.generate(45, (i) => '$i cups flour'),
        }),
      ),
    ))!;
    await tester.runAsync(
      () => container.read(cookingProvider.notifier).refresh(),
    );
    await pump(tester, size: const Size(1200, 900));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels,
      greaterThan(0),
    );
    await tap(tester, find.widgetWithText(TextButton, 'Ingredients'));
    await tester.pumpAndSettle();
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels,
      0,
    );
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).last)
          .position
          .pixels,
      0,
    );
  });
  testWidgets('keep awake releases on background and preference change', (
    tester,
  ) async {
    await pump(tester);
    expect(wakeEvents.last, true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(wakeEvents.last, false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(wakeEvents.last, true);
    await tester.runAsync(
      () => container
          .read(cookingPreferencesProvider.notifier)
          .set('awake', 'false'),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(wakeEvents.last, false);
  });
}
