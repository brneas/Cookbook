import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cookbook/core/database/app_database.dart';
import 'package:cookbook/features/cooking/data/cooking_repository.dart';
import 'package:cookbook/features/cooking/data/timer_notifications.dart';
import 'package:cookbook/features/cooking/presentation/cooking_providers.dart';
import 'package:cookbook/features/recipes/domain/recipe.dart';
import 'support/fake_timer_notifications.dart';

void main() {
  sqfliteFfiInit();
  late AppDatabase db;
  late CookingRepository repo;
  late ProviderContainer container;
  late FakeTimerNotifications alerts;
  late DateTime now;
  ProviderContainer create() => ProviderContainer(
    overrides: [
      cookingRepositoryProvider.overrideWith((_) async => repo),
      timerNotificationsProvider.overrideWithValue(alerts),
    ],
  );
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
    now = DateTime.utc(2026);
    repo = CookingRepository(db, 'a', now: () => now);
    alerts = FakeTimerNotifications();
    container = create();
    await container.read(cookingProvider.future);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });
  test(
    'OS schedule follows durable timer, pause cancels, restart replaces same ID',
    () async {
      final controller = container.read(cookingProvider.notifier);
      await controller.addTimer(const Duration(minutes: 10), 'Bake');
      var timer = (await repo.timers()).single;
      expect(alerts.scheduled.keys, [timer.notificationId]);
      await controller.timerAction(timer.id, 'pause');
      expect(alerts.cancelled, contains(timer.notificationId));
      expect(alerts.scheduled, isEmpty);
      await controller.timerAction(timer.id, 'resume');
      expect(alerts.scheduled.keys, [timer.notificationId]);
      await controller.timerAction(timer.id, 'restart');
      expect(alerts.scheduled.length, 1);
      expect((await repo.timers()).single.notification, 'scheduledExact');
      alerts.permission = const NotificationAccess(allowed: true);
      await container.read(cookingProvider.notifier).refresh(reschedule: true);
      expect((await repo.timers()).single.notification, 'scheduledInexact');
      alerts.permission = const NotificationAccess(
        allowed: true,
        precise: true,
      );
      await container.read(cookingProvider.notifier).refresh(reschedule: true);
      expect((await repo.timers()).single.notification, 'scheduledExact');
      await controller.timerAction(timer.id, 'cancel');
      expect(alerts.scheduled, isEmpty);
    },
  );
  test(
    'permission denied never stops timer; granting later schedules it',
    () async {
      alerts.permission = const NotificationAccess();
      await container
          .read(cookingProvider.notifier)
          .addTimer(const Duration(minutes: 10), 'Bake');
      expect((await repo.timers()).single.running, true);
      expect((await repo.timers()).single.notification, 'blocked');
      expect(alerts.requests, 0);
      alerts.permission = const NotificationAccess(
        allowed: true,
        precise: true,
      );
      await container.read(cookingProvider.notifier).refresh();
      expect(alerts.scheduled.length, 1);
    },
  );
  test(
    'process restart reconstructs schedule and recognizes completed timer',
    () async {
      await container
          .read(cookingProvider.notifier)
          .addTimer(const Duration(minutes: 10), 'Bake');
      final id = (await repo.timers()).single.notificationId;
      container.dispose();
      alerts.scheduled.clear();
      now = now.add(const Duration(minutes: 5));
      container = create();
      await container.read(cookingProvider.future);
      expect(alerts.scheduled.keys, [id]);
      expect((await repo.timers()).single.remaining(now).inMinutes, 5);
      now = now.add(const Duration(minutes: 6));
      await container.read(cookingProvider.notifier).refresh();
      expect((await repo.timers()).single.status, 'completed');
      expect((await repo.timers()).single.notification, 'shown');
    },
  );
  test('account removal cancels every associated notification', () async {
    final controller = container.read(cookingProvider.notifier);
    await controller.addTimer(const Duration(minutes: 5), 'One');
    await controller.addTimer(const Duration(minutes: 10), 'Two');
    await controller.cancelForRemoval();
    expect(alerts.scheduled, isEmpty);
    expect((await repo.timers()).every((t) => t.status == 'cancelled'), true);
  });
  test('finish with Stop timers cancels only this cooking session', () async {
    final controller = container.read(cookingProvider.notifier);
    final session = await controller.start(
      Recipe.fromJson({
        'id': 'bread',
        'name': 'Bread',
        'recipeInstructions': ['Bake.'],
      }),
    );
    await controller.addTimer(
      const Duration(minutes: 5),
      'Bread',
      session: session,
    );
    await controller.addTimer(const Duration(minutes: 10), 'Other');
    await controller.finish(session.id, stopTimers: true);
    final timers = await repo.timers();
    expect(timers.first.status, 'cancelled');
    expect(timers.last.running, true);
    expect(alerts.scheduled.keys, [timers.last.notificationId]);
    expect((await repo.sessions()).single.active, false);
  });
}
