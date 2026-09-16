import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cookbook/app/app.dart';
import 'package:cookbook/app/bootstrap.dart';
import 'package:cookbook/app/providers.dart';
import 'package:cookbook/core/database/app_database.dart';
import 'package:cookbook/core/errors/app_failure.dart';
import 'package:cookbook/core/networking/nextcloud_client.dart';
import 'package:cookbook/core/networking/server_address.dart';
import 'package:dio/dio.dart';
import 'package:cookbook/features/account/presentation/connect_screen.dart';
import 'package:cookbook/features/recipes/data/bounded_image.dart';
import 'package:cookbook/features/recipes/data/image_repository.dart';
import 'package:cookbook/features/recipes/data/library_repository.dart';
import 'package:cookbook/features/recipes/domain/recipe.dart';
import 'package:cookbook/features/recipes/presentation/library_providers.dart';
import 'package:cookbook/features/recipes/presentation/library_screen.dart';
import 'package:cookbook/features/sync/data/read_sync.dart';
import 'package:cookbook/features/sync/data/sync_engine.dart';
import '../tool/renderer_fixtures.dart';
import 'database_sync_test.dart' show ReadApi, MemoryCredentials;
import 'support/mock_http.dart';
import 'widget_test.dart'
    show SavedAccount, EmptyAccount, OfflineSync, TestLibraryPreferences;

class InvalidCredentialsSync extends OfflineSync {
  @override
  SyncState build() =>
      const SyncState(error: AppFailure(FailureKind.authentication));
}

class VisibleSync extends OfflineSync {
  @override
  SyncState build() => const SyncState();
  void begin() => state = SyncState(running: true, revision: state.revision);
  void finish({bool fail = false}) => state = SyncState(
    revision: state.revision + 1,
    error: fail ? const AppFailure(FailureKind.network) : null,
  );
}

class CountingSync extends OfflineSync {
  int calls = 0;
  @override
  Future<void> automatic(String trigger) async {
    calls++;
  }
}

class ControlledApi extends ReadApi {
  final entered = Completer<void>();
  final release = Completer<void>();
  int listings = 0;
  @override
  Future<Map<String, Object?>> configuration() async => {
    'folder': '/Recipes',
    'update_interval': 5,
  };
  @override
  Future<List<Recipe>> listRecipes() async {
    listings++;
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return super.listRecipes();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'local bootstrap retains account with absent credentials, without HTTP',
    () async {
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(db.close);
      await db.db.insert('accounts', {
        'id': 'test',
        'server': 'https://cloud.test',
        'login_name': 'cook',
        'capabilities': '{}',
      });
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((_) async => db),
          credentialStoreProvider.overrideWithValue(MemoryCredentials()),
          cookbookProvider.overrideWith(
            (_) => throw StateError('Bootstrap must not request HTTP'),
          ),
        ],
      );
      addTearDown(container.dispose);
      final result = await container.read(bootstrapProvider.future);
      expect(result.phase, BootstrapPhase.authenticated);
      expect(result.needsCredentials, isTrue);
      expect((await db.db.query('accounts')).single['id'], 'test');
    },
  );
  testWidgets('route changes do not create additional startup syncs', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        bootstrapProvider.overrideWith(
          (_) async => const BootstrapResult(BootstrapPhase.authenticated),
        ),
        accountProvider.overrideWith(SavedAccount.new),
        syncProvider.overrideWith(CountingSync.new),
        libraryPreferencesProvider.overrideWith(TestLibraryPreferences.new),
        libraryPageProvider.overrideWith(
          (_, _) async =>
              const LibraryPage([LibraryItem('42', 'Cached soup', 'Soup')], 1),
        ),
        recipeImageProvider.overrideWith((_, _) async => null),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const CookbookApp(),
      ),
    );
    await tester.pumpAndSettle();
    final controller = container.read(syncProvider.notifier) as CountingSync;
    expect(controller.calls, 1);
    container.read(routerProvider).go('/library?category=Soup');
    await tester.pumpAndSettle();
    container.read(routerProvider).go('/library?keyword=easy');
    await tester.pumpAndSettle();
    expect(controller.calls, 1);
  });
  test(
    'simultaneous triggers join one sync; resume staleness uses injected clock',
    () async {
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(db.close);
      await db.db.insert('accounts', {
        'id': 'test',
        'server': 'https://cloud.test',
        'login_name': 'cook',
        'capabilities': '{}',
      });
      final api = ControlledApi();
      var now = DateTime.now();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((_) async => db),
          accountProvider.overrideWith(SavedAccount.new),
          cookbookProvider.overrideWith((_) async => api),
          syncClockProvider.overrideWithValue(() => now),
        ],
      );
      addTearDown(container.dispose);
      await container.read(accountProvider.future);
      final controller = container.read(syncProvider.notifier);
      final first = controller.request('manual');
      await api.entered.future;
      final second = controller.request('toolbar');
      expect(identical(first, second), isTrue);
      api.release.complete();
      await Future.wait([first, second]);
      expect(api.listings, 1);
      expect(container.read(syncProvider).error, isNull);
      await controller.automatic('resume');
      expect(api.listings, 1);
      now = now.add(const Duration(minutes: 6));
      await controller.automatic('resume');
      expect(api.listings, 2);
    },
  );
  test('unexpected image MIME fails safely before rendering', () async {
    final server = ServerAddress.parse('https://cloud.test');
    final client = NextcloudClient(
      server,
      dio: mockDio(
        (_) => ResponseBody.fromString(
          '<html>login</html>',
          200,
          headers: {
            'content-type': ['text/html'],
          },
        ),
      ),
    );
    addTearDown(client.close);
    await expectLater(
      client.request('GET', Uri.parse('https://cloud.test/image'), bytes: true),
      throwsA(
        isA<AppFailure>().having(
          (e) => e.kind,
          'kind',
          FailureKind.malformedResponse,
        ),
      ),
    );
  });
  for (final fails in [false, true]) {
    testWidgets(
      'cached rows, search and scroll survive ${fails ? "failed" : "successful"} sync',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            bootstrapProvider.overrideWith(
              (_) async => const BootstrapResult(BootstrapPhase.authenticated),
            ),
            accountProvider.overrideWith(SavedAccount.new),
            syncProvider.overrideWith(VisibleSync.new),
            libraryPreferencesProvider.overrideWith(TestLibraryPreferences.new),
            libraryPageProvider.overrideWith((ref, request) async {
              ref.watch(syncProvider.select((s) => s.revision));
              return LibraryPage(
                List.generate(
                  50,
                  (i) => LibraryItem(
                    '${request.offset + i}',
                    'Saved recipe ${request.offset + i}',
                    'Soup',
                  ),
                ),
                300,
              );
            }),
            recipeImageProvider.overrideWith((_, _) async => null),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: Scaffold(body: LibraryScreen())),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Saved');
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
        await tester.pumpAndSettle();
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        final position = scroll.position.pixels;
        final controller = container.read(syncProvider.notifier) as VisibleSync;
        controller.begin();
        await tester.pump();
        expect(find.textContaining('Saved recipe'), findsWidgets);
        expect(scroll.position.pixels, position);
        controller.finish(fail: fails);
        await tester.pumpAndSettle();
        expect(find.textContaining('Saved recipe'), findsWidgets);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Saved',
        );
        expect(scroll.position.pixels, position);
      },
    );
  }
  for (final loggedIn in [false, true]) {
    testWidgets(
      'bootstrap never renders login before local restoration: $loggedIn',
      (tester) async {
        final ready = Completer<BootstrapResult>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              bootstrapProvider.overrideWith((_) => ready.future),
              accountProvider.overrideWith(
                loggedIn ? SavedAccount.new : EmptyAccount.new,
              ),
              syncProvider.overrideWith(OfflineSync.new),
              libraryPreferencesProvider.overrideWith(
                TestLibraryPreferences.new,
              ),
              libraryPageProvider.overrideWith(
                (_, _) async => const LibraryPage([
                  LibraryItem('42', 'Cached soup', 'Soup'),
                ], 1),
              ),
              recipeImageProvider.overrideWith((_, _) async => null),
            ],
            child: const CookbookApp(),
          ),
        );
        await tester.pump();
        expect(find.byType(StartupSurface), findsOneWidget);
        expect(find.byType(ConnectScreen), findsNothing);
        ready.complete(
          BootstrapResult(
            loggedIn
                ? BootstrapPhase.authenticated
                : BootstrapPhase.unauthenticated,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(ConnectScreen),
          loggedIn ? findsNothing : findsOneWidget,
        );
        if (loggedIn) expect(find.text('Cached soup'), findsOneWidget);
      },
    );
  }
  testWidgets(
    'invalid credentials retain cached library and offer reauthentication',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bootstrapProvider.overrideWith(
              (_) async => const BootstrapResult(BootstrapPhase.authenticated),
            ),
            accountProvider.overrideWith(SavedAccount.new),
            syncProvider.overrideWith(InvalidCredentialsSync.new),
            libraryPreferencesProvider.overrideWith(TestLibraryPreferences.new),
            libraryPageProvider.overrideWith(
              (_, _) async => const LibraryPage([
                LibraryItem('42', 'Cached soup', 'Soup'),
              ], 1),
            ),
            recipeImageProvider.overrideWith((_, _) async => null),
          ],
          child: const CookbookApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Cached soup'), findsOneWidget);
      expect(find.text('Reauthenticate'), findsOneWidget);
      expect(find.byType(ConnectScreen), findsNothing);
    },
  );

  for (final entry in rendererFixtures.entries) {
    test(
      'metadata accepts synthetic ${entry.key} without GPU validation decode',
      () async {
        expect(await validImageMetadata(base64Decode(entry.value)), isTrue);
      },
    );
  }
  for (final data in [
    <int>[],
    [1, 2, 3],
    [255, 216, 255, 217],
  ]) {
    test('malformed or empty image ${data.length} is rejected', () async {
      expect(await validImageMetadata(Uint8List.fromList(data)), isFalse);
    });
  }
  test('extreme aspect ratios never request zero-sized textures', () {
    expect(boundedImageSize(6000, 4000, 250), const Size(250, 167));
    expect(boundedImageSize(32768, 1, 250), const Size(250, 1));
    expect(boundedImageSize(1, 32768, 250), const Size(1, 250));
    expect(boundedImageSize(800, 300, 2048), const Size(800, 300));
  });
  test('decode/fetch work is bounded and queue survives failure', () async {
    final pool = WorkPool(2);
    final gates = List.generate(5, (_) => Completer<void>());
    var active = 0, peak = 0;
    final futures = [
      for (var i = 0; i < 5; i++)
        pool.run(() async {
          active++;
          if (active > peak) peak = active;
          await gates[i].future;
          active--;
        }),
    ];
    expect(active, 2);
    for (final gate in gates) {
      gate.complete();
      await Future<void>.value();
    }
    await Future.wait(futures);
    expect(peak, 2);
    await expectLater(
      pool.run(() async => throw StateError('fixture')),
      throwsStateError,
    );
    expect(await pool.run(() async => 1), 1);
  });
  test(
    'local projection reads do not wait behind network sync lock',
    () async {
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(db.close);
      await db.db.insert('accounts', {
        'id': 'a',
        'server': 'https://test.invalid',
        'login_name': 'u',
        'capabilities': '{}',
      });
      await db.db.insert('recipes', {
        'account_id': 'a',
        'id': '1',
        'name': 'Cached',
        'stub_json': '{"id":"1","name":"Cached"}',
      });
      final blocked = Completer<void>();
      final entered = Completer<void>();
      final sync = db.withSyncLock(() {
        entered.complete();
        return blocked.future;
      });
      await entered.future;
      try {
        final page = await LibraryRepository(
          db,
          'a',
        ).page(const LibraryFilter());
        expect(page.items.single.name, 'Cached');
      } finally {
        blocked.complete();
        await sync;
      }
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );
  test('unchanged read sync preserves projection and cached image', () async {
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    await db.db.insert('accounts', {
      'id': 'a',
      'server': 'https://test.invalid',
      'login_name': 'u',
      'capabilities': '{}',
    });
    final recipe = Recipe.fromJson({
      'id': '1',
      'name': 'Cached',
      'dateModified': '2026-01-01T00:00:00Z',
    });
    final api = ReadApi()
      ..stubs = [recipe]
      ..details = {'1': recipe};
    await ReadSync(db, api, 'a').run();
    await LibraryRepository(db, 'a').prepare();
    await db.db.insert('image_cache', {
      'account_id': 'a',
      'recipe_id': '1',
      'size': 'thumb',
      'bytes': Uint8List.fromList([255, 216, 255, 217]),
      'accessed_at': 0,
    });
    var notifications = 0;
    await SyncEngine(db, api, 'a').run(
      readSync: () =>
          ReadSync(db, api, 'a').run(onChanged: (_) => notifications++),
    );
    expect(api.detailCalls, 1);
    expect(notifications, 0);
    expect(await db.db.query('library_index'), hasLength(1));
    expect(await db.db.query('image_cache'), hasLength(1));
  });
}
