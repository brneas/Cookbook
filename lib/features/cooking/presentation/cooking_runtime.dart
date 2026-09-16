import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/app.dart';
import '../../../app/providers.dart';
import 'cooking_providers.dart';
import '../data/timer_notifications.dart';

class CookingRuntime extends ConsumerStatefulWidget {
  const CookingRuntime({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<CookingRuntime> createState() => _CookingRuntimeState();
}

class _CookingRuntimeState extends ConsumerState<CookingRuntime>
    with WidgetsBindingObserver {
  bool launchChecked = false;
  late TimerNotifications notifications;
  @override
  void initState() {
    super.initState();
    notifications = ref.read(timerNotificationsProvider);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    notifications.onOpen = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref
        .read(kitchenForegroundProvider.notifier)
        .set(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(notificationAccessProvider);
      if (ref.read(accountProvider).asData?.value != null) {
        ref
            .read(cookingProvider.notifier)
            .refresh(reschedule: true)
            .catchError((Object _) {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider).asData?.value;
    if (account != null) {
      ref.watch(cookingProvider);
      ref.read(timerNotificationsProvider).onOpen = () {
        if (mounted) ref.read(routerProvider).go('/timers');
      };
      if (!launchChecked) {
        launchChecked = true;
        ref.read(timerNotificationsProvider).launchedFromTimer().then((
          launched,
        ) {
          if (launched && mounted) ref.read(routerProvider).go('/timers');
        });
      }
    }
    return widget.child;
  }
}
