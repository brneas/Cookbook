import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../../core/errors/app_failure.dart';
import '../../recipes/presentation/recipe_screen.dart';
import '../../sync/domain/recipe_comparison.dart';
import '../domain/cooking_models.dart';
import '../domain/quantities.dart';
import '../domain/duration_suggestions.dart';
import 'cooking_providers.dart';
import 'timers_panel.dart';

final keepAwakeProvider = Provider<Future<void> Function(bool)>(
  (_) =>
      (enabled) => WakelockPlus.toggle(enable: enabled),
);

class CookingScreen extends ConsumerStatefulWidget {
  const CookingScreen(this.sessionId, {super.key});
  final String sessionId;
  @override
  ConsumerState<CookingScreen> createState() => _CookingScreenState();
}

class _CookingScreenState extends ConsumerState<CookingScreen>
    with WidgetsBindingObserver {
  bool foreground = true, awake = false;
  final ingredientsKey = GlobalKey();
  final stepsKey = GlobalKey();
  final workspaceScroll = ScrollController();
  final ingredientScroll = ScrollController();
  bool ingredientsExpanded = false;

  void jump(GlobalKey key) {
    if (key == ingredientsKey && ingredientScroll.hasClients) {
      if (MediaQuery.disableAnimationsOf(context)) {
        ingredientScroll.jumpTo(0);
      } else {
        ingredientScroll.animateTo(
          0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
      return;
    }
    final target = key.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
      );
    }
  }

  String? awakeError;
  late Future<void> Function(bool) wake;
  Future<void> wakeTail = Future.value();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    wake = ref.read(keepAwakeProvider);
  }

  void updateAwake(bool enabled) {
    if (awake == enabled) return;
    awake = enabled;
    wakeTail = wakeTail.then((_) => wake(enabled)).catchError((Object _) {
      if (mounted) {
        setState(
          () => awakeError =
              'Screen-awake control is unavailable on this device.',
        );
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) updateAwake(false);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    workspaceScroll.dispose();
    ingredientScroll.dispose();
    updateAwake(false);
    super.dispose();
  }

  Future<void> finish(CookingSession session) async {
    final active = (ref.read(cookingProvider).asData?.value.timers ?? [])
        .where((t) => t.sessionId == session.id && t.active)
        .length;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Finish Cooking?'),
        content: Text(
          active == 0
              ? 'Your progress will remain saved locally.'
              : '$active timers are still active. What should happen to them?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          if (active > 0)
            OutlinedButton(
              onPressed: () => Navigator.pop(context, 'keep'),
              child: const Text('Keep timers running'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'stop'),
            child: Text(active > 0 ? 'Stop timers' : 'Finish Cooking'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    await kitchenAction(context, () async {
      await ref
          .read(cookingProvider.notifier)
          .finish(session.id, stopTimers: choice == 'stop');
      if (mounted) context.go('/cooking');
    });
  }

  Future<void> menu(String action, CookingSession session) async {
    if (action == 'finish') {
      await finish(session);
      return;
    }
    if (action == 'size') {
      await textSizeDialog(context, ref);
      return;
    }
    if (action == 'overview') {
      await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (context) => FractionallySizedBox(
          heightFactor: .85,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                session.recipe.name,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text(session.recipe.description),
              const Divider(),
              for (var i = 0; i < session.steps.length; i++)
                ListTile(
                  leading: Icon(
                    session.checks('steps').contains(i)
                        ? Icons.check_circle_outline
                        : Icons.circle_outlined,
                  ),
                  title: Text('${i + 1}. ${session.steps[i].text}'),
                  subtitle: session.steps[i].sections.isEmpty
                      ? null
                      : Text(session.steps[i].sections.join(' › ')),
                  onTap: () {
                    Navigator.pop(context);
                    kitchenAction(
                      this.context,
                      () => ref
                          .read(cookingProvider.notifier)
                          .edit(session.id, (_) => {'current': i}),
                    );
                  },
                ),
            ],
          ),
        ),
      );
      return;
    }
    if (action == 'reset' &&
        await kitchenConfirm(
          context,
          'Reset cooking progress?',
          'Ingredient and step checkmarks will be cleared. Your serving size, running timers and saved recipe version will be kept.',
        ) &&
        mounted) {
      await kitchenAction(
        context,
        () => ref.read(cookingProvider.notifier).reset(session.id),
      );
    }
    if (!mounted) return;
    if (action == 'over' &&
        await kitchenConfirm(
          context,
          'Restart with updated recipe?',
          'Use the latest downloaded ingredients and instructions. Progress will reset and servings return to the recipe’s original yield. Existing timers keep running and remain in Timers.',
        ) &&
        mounted) {
      await kitchenAction(context, () async {
        final latest = await ref.read(
          recipeDetailProvider(session.recipeId).future,
        );
        if (latest == null) throw const AppFailure(FailureKind.notFound);
        final next = await ref
            .read(cookingProvider.notifier)
            .start(latest, over: true);
        if (mounted) context.replace('/cook/${next.id}');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final kitchen = ref.watch(cookingProvider);
    final prefs =
        ref.watch(cookingPreferencesProvider).asData?.value ??
        const CookingPreferences();
    final session = kitchen.asData?.value.sessions
        .where((s) => s.id == widget.sessionId)
        .firstOrNull;
    final currentRoute = ModalRoute.of(context)?.isCurrent ?? true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        updateAwake(
          foreground && currentRoute && prefs.awake && session?.active == true,
        );
      }
    });
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Cooking')),
        body: Center(
          child: Text(
            kitchen.hasError
                ? safeFailure(kitchen.error!).message
                : kitchen.isLoading
                ? 'Opening your cooking session…'
                : 'This cooking session is no longer available.',
          ),
        ),
      );
    }
    final latest = ref
        .watch(recipeDetailProvider(session.recipeId))
        .asData
        ?.value;
    final changed =
        latest != null && fingerprint(latest.toJson()) != session.revision;
    final focus = prefs.presentation == 'focus';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          session.recipe.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Cooking text size',
            icon: const Icon(Icons.text_fields),
            onPressed: () => textSizeDialog(context, ref),
          ),
          PopupMenuButton<String>(
            tooltip: 'Cooking options',
            onSelected: (value) => menu(value, session),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'overview', child: Text('Overview')),
              if (session.active)
                const PopupMenuItem(
                  value: 'finish',
                  child: Text('Finish Cooking'),
                ),
              const PopupMenuItem(
                value: 'reset',
                child: Text('Reset Progress'),
              ),
              if (changed)
                const PopupMenuItem(
                  value: 'over',
                  child: Text('Restart with Updated Recipe'),
                ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: TimerBar(session: session, hideWhenEmpty: true),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            // Split only when both panes can accommodate large text and controls.
            final split =
                box.maxWidth >= 840 ||
                box.maxWidth >= 700 && box.maxWidth > box.maxHeight;
            final header = Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'recipe',
                        label: Text('Recipe'),
                        icon: Icon(Icons.menu_book_outlined),
                      ),
                      ButtonSegment(
                        value: 'focus',
                        label: Text('Focus'),
                        icon: Icon(Icons.center_focus_strong_outlined),
                      ),
                    ],
                    selected: {focus ? 'focus' : 'recipe'},
                    onSelectionChanged: (value) => kitchenAction(
                      context,
                      () => ref
                          .read(cookingPreferencesProvider.notifier)
                          .set('presentation', value.single),
                    ),
                  ),
                  if (session.steps.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        session.allStepsComplete
                            ? 'All steps complete'
                            : '${session.checks('steps').length} of ${session.steps.length} steps completed',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            );
            final instructions = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  focus
                      ? 'Step ${session.current + 1} of ${session.steps.length}'
                      : 'Steps',
                  key: stepsKey,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                if (session.steps.isEmpty)
                  const Text('No instructions provided'),
                for (var i = 0; i < session.steps.length; i++)
                  if (!focus || i == session.current)
                    _CookingStep(
                      session: session,
                      index: i,
                      font: prefs.font,
                      focus: focus,
                    ),
                if (focus && session.steps.isNotEmpty)
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: session.current > 0
                            ? () => kitchenAction(
                                context,
                                () => ref
                                    .read(cookingProvider.notifier)
                                    .edit(
                                      session.id,
                                      (_) => {'current': session.current - 1},
                                    ),
                              )
                            : null,
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Previous'),
                      ),
                      FilledButton.icon(
                        onPressed: session.current < session.steps.length - 1
                            ? () => kitchenAction(
                                context,
                                () => ref
                                    .read(cookingProvider.notifier)
                                    .edit(
                                      session.id,
                                      (_) => {'current': session.current + 1},
                                    ),
                              )
                            : null,
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text('Next'),
                      ),
                    ],
                  ),
                const SizedBox(height: 24),
                if (session.active)
                  OutlinedButton(
                    onPressed: () => finish(session),
                    child: const Text('Finish Cooking'),
                  ),
              ],
            );
            final ingredients = IngredientsPanel(
              headingKey: ingredientsKey,
              controller: split ? ingredientScroll : null,
              sessionId: session.id,
              embedded: !split,
            );
            final notes = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (changed)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text(
                      'This recipe has been updated since this cooking session started. You are using your saved cooking version.',
                    ),
                  ),
                if (awakeError != null) Text(awakeError!),
              ],
            );
            final jumpNavigation = Material(
              color: Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(
                  spacing: 4,
                  children: [
                    TextButton(
                      onPressed: () {
                        if (focus && !split) {
                          setState(() => ingredientsExpanded = true);
                        }
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) jump(ingredientsKey);
                        });
                      },
                      child: const Text('Ingredients'),
                    ),
                    TextButton(
                      onPressed: () => jump(stepsKey),
                      child: const Text('Steps'),
                    ),
                    TextButton.icon(
                      onPressed: () => showTimers(context, session: session),
                      icon: const Icon(Icons.timer_outlined, size: 20),
                      label: const Text('Timers'),
                    ),
                  ],
                ),
              ),
            );
            return Column(
              children: [
                if (split && MediaQuery.textScalerOf(context).scale(1) <= 1.3)
                  Row(
                    children: [
                      header,
                      const Spacer(),
                      jumpNavigation,
                      const SizedBox(width: 16),
                    ],
                  )
                else ...[
                  header,
                  jumpNavigation,
                ],
                const Divider(height: 1),
                Expanded(
                  child: split
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: (box.maxWidth * .36).clamp(280, 420),
                              child: ingredients,
                            ),
                            const VerticalDivider(width: 1),
                            Expanded(
                              child: SingleChildScrollView(
                                controller: workspaceScroll,
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [notes, instructions],
                                ),
                              ),
                            ),
                          ],
                        )
                      : SingleChildScrollView(
                          controller: workspaceScroll,
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              notes,
                              if (focus) ...[
                                ExpansionTile(
                                  key: ValueKey(ingredientsExpanded),
                                  initiallyExpanded: ingredientsExpanded,
                                  tilePadding: EdgeInsets.zero,
                                  onExpansionChanged: (value) =>
                                      ingredientsExpanded = value,
                                  title: const Text('Ingredients & servings'),
                                  children: [ingredients],
                                ),
                                const SizedBox(height: 24),
                              ] else ...[
                                ingredients,
                                const Divider(height: 40),
                              ],
                              instructions,
                            ],
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

Future<void> textSizeDialog(BuildContext context, WidgetRef ref) =>
    showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Cooking text size'),
        children: [
          for (final size in ['Small', 'Normal', 'Large', 'Extra Large'])
            SimpleDialogOption(
              padding: const EdgeInsets.all(20),
              onPressed: () {
                Navigator.pop(context);
                kitchenAction(
                  context,
                  () => ref
                      .read(cookingPreferencesProvider.notifier)
                      .set('size', size),
                );
              },
              child: Text(size),
            ),
        ],
      ),
    );

class IngredientsPanel extends ConsumerWidget {
  const IngredientsPanel({
    super.key,
    required this.sessionId,
    this.embedded = false,
    this.headingKey,
    this.controller,
  });
  final bool embedded;
  final Key? headingKey;
  final ScrollController? controller;
  final String sessionId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref
        .watch(cookingProvider)
        .asData
        ?.value
        .sessions
        .where((s) => s.id == sessionId)
        .firstOrNull;
    if (session == null) return const SizedBox.shrink();
    final font =
        (ref.watch(cookingPreferencesProvider).asData?.value.font ?? 24) * .8;
    final basis = session.originalYield, multiplier = session.multiplier;
    final children = <Widget>[
      Text(
        'Ingredients',
        key: headingKey,
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 12),
      Text(
        'Original yield: ${session.recipe.yieldText.isEmpty ? 'Not provided' : session.recipe.yieldText}',
      ),
      Text(
        basis == null
            ? 'Yield could not be parsed. Optional multiplier applies only to clear quantities.'
            : 'Cooking for ${(basis * multiplier).display} · original ${basis.display}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (basis != null)
            OutlinedButton(
              onPressed: (basis * multiplier).compareTo(Rational(1)) > 0
                  ? () => kitchenAction(
                      context,
                      () => ref
                          .read(cookingProvider.notifier)
                          .edit(
                            session.id,
                            (_) => {
                              'multiplier':
                                  ((basis * multiplier + Rational(-1)) / basis)
                                      .wire,
                            },
                          ),
                    )
                  : null,
              child: const Text('− 1 serving'),
            ),
          if (basis != null)
            OutlinedButton(
              onPressed: (basis * multiplier).compareTo(Rational(1000)) < 0
                  ? () => kitchenAction(
                      context,
                      () => ref
                          .read(cookingProvider.notifier)
                          .edit(
                            session.id,
                            (_) => {
                              'multiplier':
                                  ((basis * multiplier + Rational(1)) / basis)
                                      .wire,
                            },
                          ),
                    )
                  : null,
              child: const Text('+ 1 serving'),
            ),
          if (basis == null)
            for (final value in [
              Rational(1, 2),
              Rational(1),
              Rational(2),
              Rational(3),
            ])
              ChoiceChip(
                label: Text('${value.display}×'),
                selected: multiplier.compareTo(value) == 0,
                onSelected: (_) => kitchenAction(
                  context,
                  () => ref
                      .read(cookingProvider.notifier)
                      .edit(session.id, (_) => {'multiplier': value.wire}),
                ),
              ),
          TextButton(
            onPressed: () => kitchenAction(
              context,
              () => ref
                  .read(cookingProvider.notifier)
                  .edit(session.id, (_) => {'multiplier': '1/1'}),
            ),
            child: const Text('Reset to original'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (session.recipe.ingredients.isEmpty)
        const Text('No ingredients provided.'),
      for (var i = 0; i < session.recipe.ingredients.length; i++)
        Builder(
          builder: (context) {
            final original = session.recipe.ingredients[i],
                parsed = IngredientQuantity.parse(original),
                scaled = parsed.scaled(multiplier);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: session.checks('ingredients').contains(i),
                    onChanged: session.active
                        ? (_) => kitchenAction(
                            context,
                            () => ref
                                .read(cookingProvider.notifier)
                                .check(session.id, 'ingredients', i),
                          )
                        : null,
                    title: Text(
                      scaled,
                      style: TextStyle(
                        fontSize: font,
                        height: 1.4,
                        color: session.checks('ingredients').contains(i)
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : null,
                        decoration: session.checks('ingredients').contains(i)
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ),
                  if (scaled != original)
                    TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Ingredient quantity'),
                          content: Text(
                            'Scaled: $scaled\n\nOriginal: $original',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      ),
                      child: const Text('Show original'),
                    ),
                ],
              ),
            );
          },
        ),
      if (session.recipe.tools.isNotEmpty) ...[
        const Divider(),
        Text('Equipment', style: Theme.of(context).textTheme.titleLarge),
        for (final tool in session.recipe.tools)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(tool, style: TextStyle(fontSize: font)),
          ),
      ],
    ];
    return embedded
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          )
        : ListView(
            controller: controller,
            padding: const EdgeInsets.all(24),
            children: children,
          );
  }
}

class _CookingStep extends ConsumerWidget {
  const _CookingStep({
    required this.session,
    required this.index,
    required this.font,
    required this.focus,
  });
  final CookingSession session;
  final int index;
  final double font;
  final bool focus;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final step = session.steps[index];
    final checked = session.checks('steps').contains(index);
    final current = !session.allStepsComplete && index == session.current;
    final colors = Theme.of(context).colorScheme;
    return Padding(
      key: ValueKey('step-$index'),
      padding: const EdgeInsets.only(bottom: 20),
      child: Material(
        color: current ? colors.primaryContainer : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: current ? BorderSide(color: colors.secondary) : BorderSide.none,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (step.sections.isNotEmpty &&
                  (focus ||
                      index == 0 ||
                      session.steps[index - 1].sections.join() !=
                          step.sections.join()))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    step.sections.join(' › '),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              Text(
                'Step ${index + 1}${current ? ' · Current' : ''}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              Text(
                step.text,
                style: TextStyle(
                  fontSize: font,
                  height: 1.5,
                  color: checked ? colors.onSurfaceVariant : colors.onSurface,
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  focus ? 'Step completed' : 'Step ${index + 1} completed',
                ),
                value: checked,
                onChanged: session.active
                    ? (_) => kitchenAction(
                        context,
                        () => ref
                            .read(cookingProvider.notifier)
                            .check(session.id, 'steps', index),
                      )
                    : null,
              ),
              if (!focus && !current)
                TextButton(
                  onPressed: () => kitchenAction(
                    context,
                    () => ref
                        .read(cookingProvider.notifier)
                        .edit(session.id, (_) => {'current': index}),
                  ),
                  child: const Text('Make current step'),
                ),
              for (final suggestion in durationSuggestions(step.text))
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final duration in [
                      suggestion.minimum,
                      if (suggestion.maximum != null) suggestion.maximum!,
                    ])
                      OutlinedButton.icon(
                        onPressed: () => addTimerDialog(
                          context,
                          ref,
                          session: session,
                          step: index,
                          suggested: duration,
                        ),
                        icon: const Icon(Icons.timer_outlined),
                        label: Text('Start ${durationLabel(duration)} timer'),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
