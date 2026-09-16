import 'package:cookbook/app/bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cookbook/app/app.dart';
import 'package:cookbook/app/providers.dart';
import 'package:cookbook/features/account/data/account_repository.dart';
import 'package:flutter/material.dart';
import 'package:cookbook/core/errors/app_failure.dart';
import 'package:cookbook/core/networking/server_address.dart';
import 'package:cookbook/features/recipes/data/library_repository.dart';
import 'package:cookbook/features/recipes/presentation/library_providers.dart';
import 'package:cookbook/features/recipes/data/image_repository.dart';

class SavedAccount extends AccountController {
  @override
  Future<Account?> build() async =>
      Account('test', ServerAddress.parse('https://cloud.test'), 'cook');
}

class OfflineSync extends SyncController {
  @override
  SyncState build() => const SyncState(error: AppFailure(FailureKind.network));
  @override
  Future<void> sync() async {}
}

class EmptyAccount extends AccountController {
  @override
  Future<Account?> build() async => null;
}

void main() {
  testWidgets('first run explains unofficial status', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [accountProvider.overrideWith(EmptyAccount.new)],
        child: const CookbookApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Cookbook'), findsOneWidget);
    expect(find.textContaining('Unofficial'), findsOneWidget);
  });
  testWidgets('tablet and large text login stay usable', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [accountProvider.overrideWith(EmptyAccount.new)],
        child: const CookbookApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Advanced: use an app password'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Advanced: use an app password'));
    await tester.pumpAndSettle();
    expect(find.text('Nextcloud app password'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    testWidgets(
      'saved library stays navigable offline at width ${size.width}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              accountProvider.overrideWith(SavedAccount.new),
              bootstrapProvider.overrideWith(
                (ref) async =>
                    const BootstrapResult(BootstrapPhase.authenticated),
              ),
              syncProvider.overrideWith(OfflineSync.new),
              libraryPageProvider.overrideWith(
                (ref, request) async => const LibraryPage([
                  LibraryItem('42', 'Saved test soup', 'Soup'),
                ], 1),
              ),
              libraryPreferencesProvider.overrideWith(
                TestLibraryPreferences.new,
              ),
              recipeImageProvider.overrideWith((ref, id) async => null),
            ],
            child: const CookbookApp(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Saved test soup'), findsOneWidget);
        expect(
          find.textContaining('Downloaded recipes remain available'),
          findsOneWidget,
        );
        expect(
          find.byType(size.width >= 840 ? NavigationRail : NavigationBar),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class TestLibraryPreferences extends LibraryPreferencesController {
  @override
  Future<LibraryPreferences> build() async => const LibraryPreferences();
}
