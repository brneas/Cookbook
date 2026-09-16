import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import '../../../app/providers.dart';
import '../../recipes/domain/recipe.dart';
import '../data/cooking_repository.dart';
import '../data/timer_notifications.dart';
import '../domain/cooking_models.dart';

final cookingClockProvider = Provider<DateTime Function()>((_) => DateTime.now);
final timerNotificationsProvider = Provider<TimerNotifications>(
  (_) => TimerNotifications(),
);
final cookingRepositoryProvider = FutureProvider<CookingRepository?>((
  ref,
) async {
  final account = await ref.watch(accountProvider.future);
  if (account == null) return null;
  return CookingRepository(
    await ref.watch(databaseProvider.future),
    account.id,
    now: ref.watch(cookingClockProvider),
  );
});

class KitchenState {
  const KitchenState({this.sessions = const [], this.timers = const []});
  final List<CookingSession> sessions;
  final List<CookingTimer> timers;
  List<CookingTimer> get visibleTimers => timers
      .where((t) => !['dismissed', 'cancelled'].contains(t.status))
      .toList();
}

final cookingProvider = AsyncNotifierProvider<CookingController, KitchenState>(
  CookingController.new,
);

class CookingController extends AsyncNotifier<KitchenState> {
  Timer? _boundary;
  Future<void> _tail = Future.value();
  Future<void> get settled => _tail;
  @override
  Future<KitchenState> build() async {
    ref.onDispose(() => _boundary?.cancel());
    final repo = await ref.watch(cookingRepositoryProvider.future);
    if (repo == null) return const KitchenState();
    return _load(repo, restore: true);
  }

  Future<KitchenState> _load(
    CookingRepository repo, {
    bool restore = false,
  }) async {
    final due = (await repo.timers())
        .where((t) => t.running && t.remaining(repo.now()) == Duration.zero)
        .map((t) => t.id)
        .toSet();
    await repo.reconcile();
    var timers = await repo.timers();
    final notifications = ref.read(timerNotificationsProvider);
    for (final timer in timers) {
      if (timer.running && restore ||
          !restore && due.contains(timer.id) ||
          timer.notification == 'pending' ||
          timer.running &&
              [
                'failed',
                'blocked',
                'unavailable',
              ].contains(timer.notification)) {
        String outcome;
        if (timer.running || timer.status == 'completed') {
          outcome = timer.status == 'completed'
              ? await notifications.complete(timer, repo.now())
              : await notifications.schedule(timer, repo.now());
        } else {
          try {
            await notifications.cancel(timer.notificationId);
            outcome = 'cancelled';
          } catch (_) {
            outcome = 'pending';
          }
        }
        await repo.notificationResult(timer.id, outcome);
      }
    }
    timers = await repo.timers();
    _boundary?.cancel();
    final running = timers.where((t) => t.running).toList()
      ..sort((a, b) => a.target!.compareTo(b.target!));
    if (running.isNotEmpty && ref.mounted) {
      final wait = running.first.target!.difference(repo.now());
      _boundary = Timer(
        wait.isNegative ? Duration.zero : wait,
        () => refresh().catchError((Object _) {}),
      );
    }
    return KitchenState(sessions: await repo.sessions(), timers: timers);
  }

  Future<T> _run<T>(
    Future<T> Function(CookingRepository) action, {
    bool reschedule = false,
  }) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        if (state.isLoading) await future;
        final repo = await ref.read(cookingRepositoryProvider.future);
        if (repo == null) throw StateError('No account');
        final value = await action(repo);
        final updated = await _load(repo, restore: reschedule);
        if (ref.mounted) state = AsyncData(updated);
        result.complete(value);
      } catch (e, stack) {
        result.completeError(e, stack);
      }
    });
    return result.future;
  }

  Future<void> refresh({bool reschedule = false}) =>
      _run((repo) async {}, reschedule: reschedule);
  Future<CookingSession> start(Recipe recipe, {bool over = false}) =>
      _run((r) => r.start(recipe, over: over));
  Future<void> edit(String session, JsonMap Function(CookingSession) action) =>
      _run((r) => r.updateSession(session, action));
  Future<void> check(String session, String key, int index) =>
      _run((r) => r.check(session, key, index));
  Future<void> reset(String session) => _run((r) => r.reset(session));
  Future<void> addTimer(
    Duration duration,
    String label, {
    CookingSession? session,
    int? step,
  }) => _run((r) async {
    await r.createTimer(duration, label, session: session, step: step);
  });
  Future<void> timerAction(
    String id,
    String action, {
    String? label,
    Duration? add,
  }) => _run((r) async {
    await r.control(id, action, label: label, add: add);
  });
  Future<void> finish(String id, {required bool stopTimers}) => _run((r) async {
    if (stopTimers) {
      for (final timer in await r.timers()) {
        if (timer.sessionId == id && timer.active) {
          await r.control(timer.id, 'cancel');
        }
      }
    }
    await r.updateSession(
      id,
      (_) => {'status': 'completed', 'finished': r.stamp},
    );
  });
  Future<void> cancelForRemoval() => _run((r) async {
    for (final timer in await r.timers()) {
      await ref.read(timerNotificationsProvider).cancel(timer.notificationId);
      await r.control(timer.id, 'cancel');
    }
  });
}

class CookingPreferences {
  const CookingPreferences({
    this.awake = true,
    this.size = 'Normal',
    this.presentation = 'recipe',
    this.notificationAsked = false,
  });
  final bool awake, notificationAsked;
  final String size, presentation;
  double get font => switch (size) {
    'Small' => 20,
    'Large' => 30,
    'Extra Large' => 38,
    _ => 24,
  };
}

final cookingPreferencesProvider =
    AsyncNotifierProvider<CookingPreferencesController, CookingPreferences>(
      CookingPreferencesController.new,
    );

class CookingPreferencesController extends AsyncNotifier<CookingPreferences> {
  @override
  Future<CookingPreferences> build() async {
    final db = await ref.watch(databaseProvider.future);
    final rows = await db.db.query(
      'preferences',
      where: "key LIKE 'cooking.%'",
    );
    final values = {for (final row in rows) row['key']: row['value']};
    return CookingPreferences(
      awake: values['cooking.awake'] != 'false',
      size: values['cooking.size'] as String? ?? 'Normal',
      presentation: values['cooking.presentation'] == 'focus'
          ? 'focus'
          : 'recipe',
      notificationAsked: values['cooking.notificationAsked'] == 'true',
    );
  }

  Future<void> set(String key, String value) async {
    final previous = state.asData?.value ?? await future;
    final db = await ref.read(databaseProvider.future);
    await db.db.insert('preferences', {
      'key': 'cooking.$key',
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    state = AsyncData(
      CookingPreferences(
        awake: key == 'awake' ? value == 'true' : previous.awake,
        size: key == 'size' ? value : previous.size,
        presentation: key == 'presentation' ? value : previous.presentation,
        notificationAsked: key == 'notificationAsked'
            ? value == 'true'
            : previous.notificationAsked,
      ),
    );
  }
}

final notificationAccessProvider = FutureProvider<NotificationAccess>(
  (ref) => ref.watch(timerNotificationsProvider).access(),
);

class KitchenForeground extends Notifier<bool> {
  @override
  bool build() => true;
  void set(bool value) => state = value;
}

final kitchenForegroundProvider = NotifierProvider<KitchenForeground, bool>(
  KitchenForeground.new,
);
// Only timer display widgets subscribe; this does not read SQL or refresh recipes.
final timerTickProvider = StreamProvider.autoDispose<DateTime>(
  (ref) => !ref.watch(kitchenForegroundProvider)
      ? const Stream.empty()
      : Stream.periodic(
          const Duration(seconds: 1),
          (_) => ref.read(cookingClockProvider)(),
        ),
);
