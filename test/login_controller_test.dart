import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cookbook/app/providers.dart';
import 'package:cookbook/core/database/app_database.dart';
import 'package:cookbook/core/errors/app_failure.dart';
import 'package:cookbook/core/networking/nextcloud_client.dart';
import 'package:cookbook/core/theme/theme_providers.dart';
import 'package:cookbook/core/theme/server_theme.dart';
import 'package:cookbook/features/account/data/account_repository.dart';
import 'package:cookbook/features/account/presentation/login_controller.dart';
import 'database_sync_test.dart' show MemoryCredentials;
import 'support/mock_http.dart';

void main() {
  sqfliteFfiInit();
  late AppDatabase db;
  late MemoryCredentials secrets;
  late ProviderContainer container;
  var browserWorks = true, rejectUser = false, missingCookbook = false;
  var failVerification = false, starts = 0, polls = 0;
  Completer<bool>? browserGate;
  const address = 'https://cloud.test/nextcloud';
  const secret = 'abcde-fghij-klmno-pqrst-uvwxy';
  ResponseBody handler(RequestOptions o) {
    if (o.uri.path.endsWith('/login/v2')) {
      starts++;
      return jsonResponse({
        'login': '$address/flow/SECRET',
        'poll': {'token': 'SECRET', 'endpoint': '$address/login/v2/poll'},
      });
    }
    if (o.uri.path.endsWith('/poll')) {
      polls++;
      return jsonResponse({
        'server': address,
        'loginName': 'cook',
        'appPassword': secret,
      });
    }
    if (o.uri.path.endsWith('/user')) {
      if (failVerification) {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.connectionTimeout,
        );
      }
      if (rejectUser) return jsonResponse({}, status: 401);
      return jsonResponse({
        'ocs': {
          'meta': {'statuscode': 200},
          'data': {'id': 'cook'},
        },
      });
    }
    if (o.uri.path.endsWith('/capabilities')) {
      return jsonResponse({
        'ocs': {
          'meta': {'statuscode': 200},
          'data': {
            'version': {'string': '32.0.1'},
            'capabilities': {
              'theming': {
                'color': '#123456',
                'logo': 'https://evil.test/SECRET',
              },
              if (!missingCookbook)
                'cookbook': {
                  'api-version': {'epoch': 0, 'major': 1, 'minor': 3},
                },
            },
          },
        },
      });
    }
    return jsonResponse({}, status: 404);
  }

  ProviderContainer createContainer() => ProviderContainer(
    overrides: [
      databaseProvider.overrideWith((_) async => db),
      credentialStoreProvider.overrideWithValue(secrets),
      authClientFactoryProvider.overrideWithValue(
        (server, credentials) => NextcloudClient(
          server,
          credentials: credentials,
          dio: mockDio(handler),
        ),
      ),
      browserLauncherProvider.overrideWithValue((uri) async {
        expect(uri.toString(), '$address/flow/SECRET');
        return browserGate == null ? browserWorks : await browserGate!.future;
      }),
    ],
  );
  setUp(() async {
    db = await AppDatabase.open(
      factory: databaseFactoryFfiNoIsolate,
      path: inMemoryDatabasePath,
    );
    secrets = MemoryCredentials();
    browserWorks = true;
    rejectUser = false;
    missingCookbook = false;
    failVerification = false;
    starts = 0;
    polls = 0;
    browserGate = null;
    container = createContainer();
    await container.read(accountProvider.future);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });
  test(
    'browser login verifies then installs; offline restart retains theme and appearance',
    () async {
      expect(
        await container.read(loginProvider.notifier).connect(address),
        true,
      );
      expect(starts, 1);
      expect(polls, 1);
      final account = (await container.read(accountProvider.future))!;
      expect(secrets.values[account.id], secret);
      expect(secrets.values.containsKey(AccountRepository.pendingKey), false);
      final metadata = await db.db.query('account_metadata');
      expect(metadata.toString(), isNot(contains(secret)));
      expect(metadata.toString(), isNot(contains('evil.test')));
      expect(
        (await container.read(serverThemeProvider.future)).color,
        const Color(0xff123456),
      );
      await container.read(appearanceProvider.future);
      await container.read(appearanceProvider.notifier).setMode(ThemeMode.dark);
      container.dispose();
      container = createContainer();
      expect((await container.read(accountProvider.future))!.id, account.id);
      expect(
        (await container.read(serverThemeProvider.future)).color,
        const Color(0xff123456),
      );
      expect(await container.read(appearanceProvider.future), ThemeMode.dark);
      await db.removeAccount(account.id);
      container.invalidate(accountProvider);
      expect(await db.db.query('account_metadata'), isEmpty);
      expect(
        (await container.read(serverThemeProvider.future)).color,
        nextcloudBlue,
      );
    },
  );
  test(
    'verification failure is recoverable across restart without a second poll',
    () async {
      failVerification = true;
      expect(
        await container.read(loginProvider.notifier).connect(address),
        false,
      );
      expect(await container.read(accountProvider.future), null);
      expect(container.read(loginProvider).recoverable, true);
      expect(secrets.values.containsKey(AccountRepository.pendingKey), true);
      container.dispose();
      container = createContainer();
      failVerification = false;
      expect(
        await container.read(loginProvider.notifier).connect(address),
        true,
      );
      expect(starts, 1);
      expect(polls, 1);
    },
  );
  test('browser failure offers reopen of the same exact challenge', () async {
    browserWorks = false;
    expect(
      await container.read(loginProvider.notifier).connect(address),
      false,
    );
    expect(container.read(loginProvider).error!.kind, FailureKind.browser);
    expect(
      container.read(loginProvider).diagnostic!.reason,
      'browserLaunchFailed',
    );
    browserWorks = true;
    expect(await container.read(loginProvider.notifier).reopenBrowser(), true);
    expect(starts, 1);
    expect(polls, 1);
  });
  test(
    'cancel during browser handoff never polls or installs an account',
    () async {
      browserGate = Completer<bool>();
      final controller = container.read(loginProvider.notifier);
      final attempt = controller.connect(address);
      while (starts == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      controller.cancel();
      browserGate!.complete(true);
      expect(await attempt, false);
      expect(polls, 0);
      expect(await container.read(accountProvider.future), null);
    },
  );
  test('manual rejected credentials are not stored or accepted', () async {
    rejectUser = true;
    expect(
      await container
          .read(loginProvider.notifier)
          .connect(
            address,
            loginName: 'cook',
            appPassword: secret,
            appPasswordConfirmed: true,
          ),
      false,
    );
    expect(
      container.read(loginProvider).error!.kind,
      FailureKind.authentication,
    );
    expect(await container.read(accountProvider.future), null);
    expect(secrets.values, isEmpty);
    expect(starts, 0);
  });
  test(
    'rejected browser credentials clear checkpoint so new authorization is possible',
    () async {
      rejectUser = true;
      expect(
        await container.read(loginProvider.notifier).connect(address),
        false,
      );
      expect(secrets.values, isEmpty);
      rejectUser = false;
      expect(
        await container.read(loginProvider.notifier).connect(address),
        true,
      );
      expect(starts, 2);
    },
  );
  test('manual fallback requires explicit app-password confirmation', () async {
    expect(
      await container
          .read(loginProvider.notifier)
          .connect(address, loginName: 'cook', appPassword: secret),
      false,
    );
    expect(
      container.read(loginProvider).error!.kind,
      FailureKind.appPasswordRequired,
    );
    expect(secrets.values, isEmpty);
  });
  test(
    'valid manual Nextcloud account with missing Cookbook is distinct from failed authentication',
    () async {
      missingCookbook = true;
      expect(
        await container
            .read(loginProvider.notifier)
            .connect(
              address,
              loginName: 'cook',
              appPassword: secret,
              appPasswordConfirmed: true,
            ),
        true,
      );
      expect(
        container.read(loginProvider).error!.kind,
        FailureKind.unavailable,
      );
      expect(await container.read(accountProvider.future), isNotNull);
      expect(starts, 0);
    },
  );
}
