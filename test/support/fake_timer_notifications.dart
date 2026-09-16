import 'package:cookbook/features/cooking/data/timer_notifications.dart';
import 'package:cookbook/features/cooking/domain/cooking_models.dart';

class FakeTimerNotifications extends TimerNotifications {
  @override
  Future<String> complete(CookingTimer timer, DateTime now) async {
    await cancel(timer.notificationId);
    return schedule(timer, now);
  }

  NotificationAccess permission = const NotificationAccess(
    allowed: true,
    precise: true,
  );
  final scheduled = <int, CookingTimer>{};
  final cancelled = <int>[];
  var requests = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<NotificationAccess> access() async => permission;
  @override
  Future<void> request() async {
    requests++;
  }

  @override
  Future<void> requestPrecise() async {}
  @override
  Future<void> settings() async {}
  @override
  Future<bool> launchedFromTimer() async => false;
  @override
  Future<void> cancel(int id) async {
    scheduled.remove(id);
    cancelled.add(id);
  }

  @override
  Future<String> schedule(CookingTimer timer, DateTime now) async {
    if (!permission.allowed) return 'blocked';
    scheduled[timer.notificationId] = timer;
    return timer.target?.isAfter(now) == true
        ? permission.precise
              ? 'scheduledExact'
              : 'scheduledInexact'
        : 'shown';
  }
}
