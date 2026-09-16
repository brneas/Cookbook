import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'cooking_providers.dart';
import 'cooking_screen.dart';
import 'timers_panel.dart';

class CookingSettings extends ConsumerWidget {
  const CookingSettings({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs =
        ref.watch(cookingPreferencesProvider).asData?.value ??
        const CookingPreferences();
    final permission = ref.watch(notificationAccessProvider).asData?.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 40),
        Text('Cooking', style: Theme.of(context).textTheme.titleLarge),
        SwitchListTile(
          title: const Text('Keep screen awake while cooking'),
          subtitle: const Text(
            'Only while Cooking Mode is visible and Cookbook is in the foreground.',
          ),
          value: prefs.awake,
          onChanged: (value) => kitchenAction(
            context,
            () => ref
                .read(cookingPreferencesProvider.notifier)
                .set('awake', '$value'),
          ),
        ),
        ListTile(
          title: const Text('Cooking text size'),
          subtitle: Text('${prefs.size} · also respects Android text size'),
          trailing: const Icon(Icons.text_fields),
          onTap: () => textSizeDialog(context, ref),
        ),
        ListTile(
          title: const Text('Timer notifications'),
          subtitle: Text(
            permission == null
                ? 'Checking Android permission…'
                : !permission.available
                ? 'Unavailable on this platform'
                : permission.allowed
                ? 'Allowed · sound and vibration follow Android channel settings'
                : 'Permission required or disabled in Android settings',
          ),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            if (permission?.allowed != true)
              OutlinedButton(
                onPressed: () => kitchenAction(context, () async {
                  await ref
                      .read(cookingPreferencesProvider.notifier)
                      .set('notificationAsked', 'true');
                  await ref.read(timerNotificationsProvider).request();
                  ref.invalidate(notificationAccessProvider);
                  await ref
                      .read(cookingProvider.notifier)
                      .refresh(reschedule: true);
                }),
                child: const Text('Allow notifications'),
              ),
            TextButton(
              onPressed: () => kitchenAction(
                context,
                () => ref.read(timerNotificationsProvider).settings(),
              ),
              child: const Text('Android notification settings'),
            ),
          ],
        ),
        ListTile(
          title: const Text('Precise timer alerts'),
          subtitle: Text(
            permission?.precise == true
                ? 'Allowed by Android'
                : 'Optional. Without access Android can delay background alerts; in-app countdowns remain accurate.',
          ),
        ),
        if (permission?.precise != true)
          OutlinedButton(
            onPressed: () => kitchenAction(context, () async {
              if (await kitchenConfirm(
                context,
                'Allow precise timer alerts?',
                'Android can delay ordinary scheduled alerts. Allow Alarms & reminders for completion alerts at your chosen cooking time. You can continue without this access.',
              )) {
                await ref.read(timerNotificationsProvider).requestPrecise();
                ref.invalidate(notificationAccessProvider);
                await ref
                    .read(cookingProvider.notifier)
                    .refresh(reschedule: true);
              }
            }),
            child: const Text('Enable precise alerts'),
          ),
      ],
    );
  }
}
