import '../core/auth/nextcloud_verification.dart';
import '../core/runtime_diagnostics.dart';
import '../features/recipes/data/image_repository.dart';
import '../core/auth/auth_diagnostics.dart';
import '../core/theme/theme_providers.dart';
import '../features/cooking/presentation/cooking_providers.dart';
import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api/cookbook_api.dart';
import '../core/api/cookbook_api_service.dart';
import '../core/api/cookbook_capabilities.dart';
import '../core/auth/credential_store.dart';
import '../core/auth/nextcloud_auth_service.dart';
import '../core/database/app_database.dart';
import '../core/database/library_guard.dart';
import '../core/errors/app_failure.dart';
import '../features/account/data/account_repository.dart';
import '../features/recipes/domain/recipe.dart';
import '../features/sync/data/read_sync.dart';
import '../features/sync/data/sync_engine.dart';
import '../features/settings/data/server_cookbook_settings.dart';

final databaseProvider = FutureProvider<AppDatabase>((ref) async {
  final database = await AppDatabase.open();
  RuntimeDiagnostics.mark('database ready');
  ref.onDispose(() => unawaited(database.close()));
  return database;
});
final credentialStoreProvider = Provider<CredentialStore>(
  (_) => PlatformCredentialStore(),
);
final accountRepositoryProvider = FutureProvider<AccountRepository>(
  (ref) async => AccountRepository(
    await ref.watch(databaseProvider.future),
    ref.watch(credentialStoreProvider),
  ),
);
final accountProvider = AsyncNotifierProvider<AccountController, Account?>(
  AccountController.new,
);

class AccountController extends AsyncNotifier<Account?> {
  @override
  Future<Account?> build() async {
    try {
      return await (await ref.watch(accountRepositoryProvider.future)).load();
    } catch (error) {
      throw safeFailure(error);
    }
  }

  Future<void> install(
    LoginResult login, {
    NextcloudInfo? info,
    CookbookCapabilities? caps,
  }) async {
    final repositoryForLogin = await ref.read(accountRepositoryProvider.future);
    final existing = state.asData?.value;
    final Account account;
    if (existing != null) {
      if (existing.server.toString() != login.server.toString() ||
          existing.loginName != login.credentials.loginName) {
        throw const AppFailure(FailureKind.conflict);
      }
      await ref
          .read(credentialStoreProvider)
          .write(existing.id, login.credentials.appPassword);
      account = Account(
        existing.id,
        existing.server,
        existing.loginName,
        capabilities: caps ?? existing.capabilities,
      );
      ref.invalidate(cookbookProvider);
    } else {
      account = await repositoryForLogin.add(login);
    }
    final repository = await ref.read(accountRepositoryProvider.future);
    try {
      if (info != null) await repository.saveNextcloud(account, info);
      if (caps != null) await repository.saveCapabilities(account, caps);
    } catch (_) {
      /* Optional metadata must not strand an installed account. */
    }
    state = AsyncData(account);
    if (existing != null) {
      unawaited(
        Future.microtask(
          () => ref.read(syncProvider.notifier).request('reauthentication'),
        ),
      );
    }
  }

  Future<bool> remove() async {
    final account = state.asData?.value;
    if (account == null) return true;
    await ref.read(cookingProvider.notifier).cancelForRemoval();
    final sync = ref.read(syncProvider.notifier);
    await sync.pauseForRemoval();
    try {
      final revoked = await (await ref.read(
        accountRepositoryProvider.future,
      )).remove(account);
      state = const AsyncData(null);
      return revoked;
    } finally {
      sync.resume();
    }
  }
}

final cookbookProvider = FutureProvider<CookbookApi>((ref) async {
  final account = await ref.watch(accountProvider.future);
  if (account == null) throw const AppFailure(FailureKind.authentication);
  final repository = await ref.watch(accountRepositoryProvider.future);
  final http = await repository.client(account);
  if (!ref.mounted) {
    http.close();
    throw const AppFailure(FailureKind.cancelled);
  }
  ref.onDispose(http.close);
  final verify = NextcloudVerification(http);
  try {
    await verify.verify();
    NextcloudInfo? info;
    try {
      info = await verify.capabilities();
      await repository.saveNextcloud(account, info);
      if (ref.mounted) ref.read(metadataRevisionProvider.notifier).changed();
    } on AppFailure {
      /* Offline/optional theming failure retains the last known theme. */
    }
    http.stage = AuthStage.discoveringCookbook;
    final caps = await CookbookCapabilityService(
      http,
    ).discover(nextcloudCapabilities: info?.capabilities);
    await repository.saveCapabilities(account, caps);
    await repository.saveConnectionResult(account, http.lastDiagnostic);
    return CookbookApiService(http, caps);
  } on AppFailure catch (e) {
    await repository.saveConnectionResult(
      account,
      e.diagnostic ?? http.lastDiagnostic,
    );
    rethrow;
  }
});

class SyncState {
  const SyncState({
    this.running = false,
    this.completed = 0,
    this.total = 0,
    this.revision = 0,
    this.error,
  });
  final bool running;
  final int completed, total, revision;
  final AppFailure? error;
}

final syncClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

final syncProvider = NotifierProvider<SyncController, SyncState>(
  SyncController.new,
);

class SyncController extends Notifier<SyncState> {
  Future<void>? _running;
  bool _paused = false;
  DateTime? _lastAttempt;
  bool _followUp = false;
  Future<void> request(String trigger, {bool mutation = false}) {
    _trigger = trigger;
    if (mutation && _running != null) _followUp = true;
    return sync();
  }

  String _trigger = 'manual';
  Future<void> automatic(String trigger) async {
    if (_paused) return;
    final now = ref.read(syncClockProvider)();
    if (_lastAttempt != null &&
        now.difference(_lastAttempt!) < const Duration(minutes: 5)) {
      return;
    }
    try {
      final account = await ref.read(accountProvider.future);
      if (account == null) return;
      final db = await ref.read(databaseProvider.future);
      final rows = await db.db.query(
        'sync_metadata',
        columns: ['last_attempt'],
        where: 'account_id=?',
        whereArgs: [account.id],
      );
      final last = DateTime.tryParse(
        rows.firstOrNull?['last_attempt'] as String? ?? '',
      );
      if (last != null && now.difference(last) < const Duration(minutes: 5)) {
        return;
      }
    } catch (_) {
      /* Sync reports local failures safely. */
    }
    if (_running != null) {
      await request(trigger);
      return;
    }
    await request(trigger);
  }

  @override
  SyncState build() {
    ref.watch(accountProvider);
    _lastAttempt = null;
    return const SyncState();
  }

  Future<void> pauseForRemoval() async {
    _paused = true;
    await _running;
  }

  void resume() {
    _paused = false;
  }

  void localChanged() {
    state = SyncState(
      revision: state.revision + 1,
      running: state.running,
      error: state.error,
    );
  }

  Future<void> sync() {
    if (_paused) return Future.value();
    RuntimeDiagnostics.event('sync requested', {
      'trigger': _trigger,
      'coalesced': _running != null,
    });
    return _running ??= _sync().whenComplete(() async {
      _running = null;
      if (_followUp && !_paused && ref.mounted) {
        _followUp = false;
        await request('mutation follow-up');
      }
    });
  }

  Future<void> _sync() async {
    final timer = Stopwatch()..start();
    final networkStart = RuntimeDiagnostics.networkRequests;
    _lastAttempt = ref.read(syncClockProvider)();
    _trigger = 'manual';
    RuntimeDiagnostics.mark('background sync start');
    state = SyncState(running: true, revision: state.revision);
    Account? syncingAccount;
    try {
      final account = await ref.read(accountProvider.future);
      syncingAccount = account;
      if (account == null) {
        state = const SyncState();
        return;
      }
      // A deliberate refresh retries discovery after a recoverable connection error.
      final database = await ref.read(databaseProvider.future);
      await ensureLibraryWritable(database.db, account.id);
      await database.db.insert('sync_metadata', {
        'account_id': account.id,
        'status': 'syncing',
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await database.db.update(
        'sync_metadata',
        {
          'last_attempt': DateTime.now().toUtc().toIso8601String(),
          'status': 'syncing',
          'last_error': null,
        },
        where: 'account_id=?',
        whereArgs: [account.id],
      );
      if (ref.read(cookbookProvider).hasError) ref.invalidate(cookbookProvider);
      final api = await ref.read(cookbookProvider.future);
      await ServerCookbookService(database, api, account.id).reload();
      var readChanged = false;
      await SyncEngine(
        database,
        api,
        account.id,
        onChanged: () {
          if (ref.mounted) localChanged();
        },
      ).run(
        shouldCancel: () => _paused,
        readSync: () => ReadSync(database, api, account.id).run(
          shouldCancel: () => _paused,
          onChanged: (imageIds) {
            readChanged = true;
            for (final id in imageIds) {
              ref.invalidate(recipeImageProvider(id));
              ref.invalidate(recipeFullImageProvider(id));
            }
            if (ref.mounted) localChanged();
          },
          onProgress: (completed, total) {
            if (ref.mounted) {
              state = SyncState(
                running: true,
                completed: completed,
                total: total,
                revision: state.revision,
              );
            }
          },
        ),
      );
      if (ref.mounted) state = SyncState(revision: state.revision);
      RuntimeDiagnostics.event('sync complete', {
        'durationMs': timer.elapsedMilliseconds,
        'changed': readChanged,
        'networkRequestsIncludingImages':
            RuntimeDiagnostics.networkRequests - networkStart,
      });
      RuntimeDiagnostics.mark('background sync complete');
    } catch (error) {
      if (syncingAccount != null) {
        try {
          final db = await ref.read(databaseProvider.future);
          await db.db.update(
            'sync_metadata',
            {'status': 'failed', 'last_error': safeFailure(error).kind.name},
            where: 'account_id=?',
            whereArgs: [syncingAccount.id],
          );
        } catch (_) {
          /* A database failure must not hide the original sanitized error. */
        }
      }
      if (ref.mounted) {
        state = SyncState(revision: state.revision, error: safeFailure(error));
      }
    }
  }
}

final recipesProvider = FutureProvider.autoDispose.family<List<Recipe>, String>(
  (ref, query) async {
    final account = await ref.watch(accountProvider.future);
    ref.watch(syncProvider.select((s) => s.revision));
    if (account == null) return [];
    return (await ref.watch(
      databaseProvider.future,
    )).recipes(account.id, query: query);
  },
);
