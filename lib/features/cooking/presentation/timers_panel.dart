import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/errors/app_failure.dart';
import '../domain/cooking_models.dart';
import '../domain/duration_suggestions.dart';
import 'cooking_providers.dart';

Future<void> kitchenAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeFailure(e).message)));
    }
  }
}

Future<bool> kitchenConfirm(
  BuildContext context,
  String title,
  String explanation,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(explanation),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    ) ==
    true;

Future<void> timerPermissionPrompt(BuildContext context, WidgetRef ref) async {
  final prefs = await ref.read(cookingPreferencesProvider.future);
  if (prefs.notificationAsked || !context.mounted) return;
  final allow = await kitchenConfirm(
    context,
    'Timer notifications',
    'Allow notifications so Cookbook can alert you when cooking timers finish. Without permission, timers still work in Cookbook.',
  );
  await ref
      .read(cookingPreferencesProvider.notifier)
      .set('notificationAsked', 'true');
  if (allow) await ref.read(timerNotificationsProvider).request();
  ref.invalidate(notificationAccessProvider);
}

Future<void> addTimerDialog(
  BuildContext context,
  WidgetRef ref, {
  CookingSession? session,
  int? step,
  Duration? suggested,
}) async {
  final result = await showDialog<({Duration duration, String label})>(
    context: context,
    builder: (_) => _TimerForm(
      initial: suggested,
      label: step == null ? 'Timer' : 'Step ${step + 1} timer',
    ),
  );
  if (result == null || !context.mounted) return;
  await kitchenAction(context, () async {
    await timerPermissionPrompt(context, ref);
    await ref
        .read(cookingProvider.notifier)
        .addTimer(result.duration, result.label, session: session, step: step);
  });
}

class _TimerForm extends StatefulWidget {
  const _TimerForm({this.initial, required this.label});
  final Duration? initial;
  final String label;
  @override
  State<_TimerForm> createState() => _TimerFormState();
}

class _TimerFormState extends State<_TimerForm> {
  late final label = TextEditingController(text: widget.label),
      hours = TextEditingController(text: '${widget.initial?.inHours ?? 0}'),
      minutes = TextEditingController(
        text: '${(widget.initial?.inMinutes ?? 5) % 60}',
      ),
      seconds = TextEditingController(
        text: '${(widget.initial?.inSeconds ?? 0) % 60}',
      );
  String? error;
  @override
  void dispose() {
    for (final c in [label, hours, minutes, seconds]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add Timer'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: label,
            maxLength: 80,
            decoration: const InputDecoration(labelText: 'Timer label'),
          ),
          for (final entry in {
            hours: 'Hours',
            minutes: 'Minutes',
            seconds: 'Seconds',
          }.entries)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextField(
                controller: entry.key,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: entry.value),
              ),
            ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          final h = int.tryParse(hours.text),
              m = int.tryParse(minutes.text),
              s = int.tryParse(seconds.text);
          if (h == null ||
              m == null ||
              s == null ||
              h < 0 ||
              m < 0 ||
              m > 59 ||
              s < 0 ||
              s > 59 ||
              h > 168 ||
              h * 3600 + m * 60 + s <= 0 ||
              h * 3600 + m * 60 + s > 604800) {
            setState(
              () => error =
                  'Enter a duration from 1 second to 7 days. Minutes and seconds must be 0–59.',
            );
            return;
          }
          Navigator.pop(context, (
            duration: Duration(hours: h, minutes: m, seconds: s),
            label: label.text,
          ));
        },
        child: const Text('Start Timer'),
      ),
    ],
  );
}

Future<void> showTimers(BuildContext context, {CookingSession? session}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (context) => FractionallySizedBox(
        heightFactor: .65,
        child: TimersPanel(session: session),
      ),
    );

class TimersPanel extends ConsumerWidget {
  const TimersPanel({super.key, this.session});
  final CookingSession? session;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kitchen = ref.watch(cookingProvider);
    final access = ref.watch(notificationAccessProvider).asData?.value;
    return kitchen.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(safeFailure(e).message)),
      data: (state) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Timers', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),
          if (access?.allowed != true)
            const Text(
              'Timers continue in Cookbook, but Android may not alert you when the app is closed. Enable notifications in Cooking settings.',
            ),
          if (access?.allowed == true && access?.precise != true)
            const Text(
              'Android may delay background alerts. Optional precise alerts are available in Cooking settings.',
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => addTimerDialog(context, ref, session: session),
            icon: const Icon(Icons.add_alarm),
            label: const Text('Add Timer'),
          ),
          if (state.visibleTimers.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No timers yet.'),
            ),
          for (final timer in state.visibleTimers) TimerCard(timer: timer),
        ],
      ),
    );
  }
}

class TimerCard extends ConsumerWidget {
  const TimerCard({super.key, required this.timer});
  final CookingTimer timer;
  Future<void> rename(BuildContext context, WidgetRef ref) async {
    var edited = timer.label;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename timer'),
        content: TextFormField(
          initialValue: edited,
          onChanged: (value) => edited = value,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Timer label'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, edited),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && context.mounted) {
      await kitchenAction(
        context,
        () => ref
            .read(cookingProvider.notifier)
            .timerAction(timer.id, 'rename', label: name),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = timer.running
        ? ref.watch(timerTickProvider).asData?.value ??
              ref.read(cookingClockProvider)()
        : ref.read(cookingClockProvider)();
    final remaining = timer.remaining(now);
    final done =
        timer.status == 'completed' ||
        timer.running && remaining == Duration.zero;
    final seconds = remaining.inSeconds;
    final digits =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    void action(String action, {Duration? add}) => kitchenAction(
      context,
      () => ref
          .read(cookingProvider.notifier)
          .timerAction(timer.id, action, add: add),
    );
    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(timer.label, style: Theme.of(context).textTheme.titleLarge),
            if (timer.recipeName.isNotEmpty) Text(timer.recipeName),
            Semantics(
              label:
                  '${timer.label} timer, ${done
                      ? 'finished'
                      : timer.status == 'paused'
                      ? 'paused, ${spokenDuration(remaining)} remaining'
                      : '${spokenDuration(remaining)} remaining'}',
              excludeSemantics: true,
              child: Text(
                done ? 'Finished' : digits,
                style: Theme.of(context).textTheme.displaySmall,
              ),
            ),
            if (timer.status == 'paused') const Text('Paused'),
            if ([
              'failed',
              'blocked',
              'unavailable',
            ].contains(timer.notification))
              const Text(
                'Background alert unavailable. Timer remains active in Cookbook.',
              ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                if (!done)
                  OutlinedButton(
                    onPressed: () => action(timer.running ? 'pause' : 'resume'),
                    child: Text(timer.running ? 'Pause' : 'Resume'),
                  ),
                if (done)
                  FilledButton(
                    onPressed: () => action('dismiss'),
                    child: const Text('Dismiss'),
                  ),
                OutlinedButton(
                  onPressed: () =>
                      action('add', add: const Duration(minutes: 1)),
                  child: const Text('+1 min'),
                ),
                OutlinedButton(
                  onPressed: () =>
                      action('add', add: const Duration(minutes: 5)),
                  child: const Text('+5 min'),
                ),
                TextButton(
                  onPressed: () => action('restart'),
                  child: const Text('Restart'),
                ),
                TextButton(
                  onPressed: () => rename(context, ref),
                  child: const Text('Rename'),
                ),
                if (!done)
                  TextButton(
                    onPressed: () => action('cancel'),
                    child: const Text('Cancel timer'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class TimerBar extends ConsumerWidget {
  const TimerBar({super.key, this.session, this.hideWhenEmpty = false});
  final bool hideWhenEmpty;
  final CookingSession? session;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timers = ref.watch(cookingProvider).asData?.value.visibleTimers ?? [];
    if (hideWhenEmpty && timers.isEmpty) return const SizedBox.shrink();
    final running = timers.where((t) => t.running).toList()
      ..sort((a, b) => a.target!.compareTo(b.target!));
    final now = running.isEmpty
        ? ref.read(cookingClockProvider)()
        : ref.watch(timerTickProvider).asData?.value ??
              ref.read(cookingClockProvider)();
    final next = running.firstOrNull?.remaining(now);
    final finished = timers.where((t) => t.status == 'completed').length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: OutlinedButton.icon(
          onPressed: () => showTimers(context, session: session),
          icon: const Icon(Icons.timer_outlined),
          label: Text(
            timers.isEmpty
                ? 'Timers · Add Timer'
                : '${timers.length} timers · ${finished > 0
                      ? '$finished finished'
                      : next == null
                      ? 'paused'
                      : 'next ${durationLabel(next)}'}',
          ),
        ),
      ),
    );
  }
}
