import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import '../domain/cooking_models.dart';
import '../domain/duration_suggestions.dart';

class NotificationAccess {
  const NotificationAccess({
    this.allowed = false,
    this.precise = false,
    this.available = true,
  });
  final bool allowed, precise, available;
}

class TimerNotifications {
  final plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _ready;
  void Function()? onOpen;
  Future<void> initialize() => _ready ??= _initialize();
  Future<void> _initialize() async {
    if (!Platform.isAndroid) return;
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_timer_notification'),
      ),
      onDidReceiveNotificationResponse: (_) => onOpen?.call(),
    );
    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'cooking_timers',
        'Cooking timers',
        description: 'Completion alerts for your cooking timers',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      ),
    );
  }

  AndroidFlutterLocalNotificationsPlugin? get _android => plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  Future<NotificationAccess> access() async {
    try {
      await initialize();
      if (!Platform.isAndroid) {
        return const NotificationAccess(available: false);
      }
      final channels = await _android?.getNotificationChannels();
      final channel = channels
          ?.where((c) => c.id == 'cooking_timers')
          .firstOrNull;
      return NotificationAccess(
        allowed:
            await _android?.areNotificationsEnabled() == true &&
            channel?.importance != Importance.none,
        precise: await _android?.canScheduleExactNotifications() == true,
      );
    } catch (_) {
      return const NotificationAccess(available: false);
    }
  }

  Future<void> request() async {
    await initialize();
    await _android?.requestNotificationsPermission();
  }

  Future<void> requestPrecise() async {
    await initialize();
    await _android?.requestExactAlarmsPermission();
  }

  Future<void> settings() async {
    await initialize();
    await plugin.openAppNotificationSettings();
  }

  Future<void> cancel(int id) async {
    await initialize();
    if (Platform.isAndroid) await plugin.cancel(id: id);
  }

  Future<bool> launchedFromTimer() async {
    try {
      await initialize();
      return (await plugin.getNotificationAppLaunchDetails())
              ?.didNotificationLaunchApp ==
          true;
    } catch (_) {
      return false;
    }
  }

  Future<String> schedule(CookingTimer timer, DateTime now) async {
    final permission = await access();
    if (!permission.allowed) {
      return permission.available ? 'blocked' : 'unavailable';
    }
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'cooking_timers',
        'Cooking timers',
        channelDescription: 'Completion alerts for your cooking timers',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        visibility: NotificationVisibility.private,
        onlyAlertOnce: true,
      ),
    );
    try {
      if (timer.target == null || !timer.target!.isAfter(now)) {
        await plugin.show(
          id: timer.notificationId,
          title: 'Timer finished',
          body: '${timer.label} — ${durationLabel(timer.duration)}',
          notificationDetails: details,
          payload: 'timers',
        );
        return 'shown';
      }
      await plugin.zonedSchedule(
        id: timer.notificationId,
        title: 'Timer finished',
        body: '${timer.label} — ${durationLabel(timer.duration)}',
        scheduledDate: tz.TZDateTime.from(timer.target!, tz.UTC),
        notificationDetails: details,
        androidScheduleMode: permission.precise
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        payload: 'timers',
      );
      return permission.precise ? 'scheduledExact' : 'scheduledInexact';
    } catch (_) {
      return 'failed';
    }
  }

  Future<String> complete(CookingTimer timer, DateTime now) async {
    try {
      await initialize();
      if (Platform.isAndroid &&
          (await plugin.getActiveNotifications()).any(
            (n) => n.id == timer.notificationId,
          )) {
        return 'shown';
      }
      await cancel(timer.notificationId);
      return schedule(timer, now);
    } catch (_) {
      return 'failed';
    }
  }
}
