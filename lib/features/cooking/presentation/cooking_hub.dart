import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/errors/app_failure.dart';
import '../../recipes/domain/recipe.dart';
import 'cooking_providers.dart';
import 'timers_panel.dart';

class CookingHub extends ConsumerWidget {
  const CookingHub({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(cookingProvider)
      .when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(safeFailure(e).message)),
        data: (state) {
          final active = state.sessions.where((s) => s.active).toList();
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Your kitchen',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 16),
              if (active.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Text(
                    'Nothing cooking yet\n\nOpen a recipe and tap Start Cooking.',
                  ),
                ),
              for (final session in active)
                Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(20),
                    leading: const Icon(Icons.restaurant_outlined),
                    title: Text(session.recipe.name),
                    subtitle: Text(
                      '${session.steps.isEmpty ? 'Ingredients and overview' : 'Step ${session.current + 1} of ${session.steps.length}'} · ${state.timers.where((t) => t.sessionId == session.id && t.active).length} active timers',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/cook/${session.id}'),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => showTimers(context),
                icon: const Icon(Icons.timer_outlined),
                label: Text('Timers (${state.visibleTimers.length})'),
              ),
              for (final timer in state.visibleTimers) TimerCard(timer: timer),
              if (state.sessions.any((s) => !s.active)) ...[
                const SizedBox(height: 24),
                Text(
                  'Recently finished',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                for (final session
                    in state.sessions.where((s) => !s.active).take(5))
                  ListTile(
                    title: Text(session.recipe.name),
                    subtitle: const Text(
                      'Cooking completed · progress kept locally',
                    ),
                  ),
              ],
            ],
          );
        },
      );
}

class StartCookingButton extends ConsumerStatefulWidget {
  const StartCookingButton(this.recipe, {super.key});
  final Recipe recipe;
  @override
  ConsumerState<StartCookingButton> createState() => _StartCookingButtonState();
}

class _StartCookingButtonState extends ConsumerState<StartCookingButton> {
  bool busy = false;
  @override
  Widget build(BuildContext context) {
    final active =
        ref
            .watch(cookingProvider)
            .asData
            ?.value
            .sessions
            .any((s) => s.recipeId == widget.recipe.id && s.active) ==
        true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton.icon(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    await kitchenAction(context, () async {
                      final session = await ref
                          .read(cookingProvider.notifier)
                          .start(widget.recipe);
                      if (context.mounted) context.push('/cook/${session.id}');
                    });
                    if (mounted) setState(() => busy = false);
                  },
            icon: const Icon(Icons.restaurant_outlined),
            label: Text(
              busy
                  ? 'Opening…'
                  : active
                  ? 'Resume Cooking'
                  : 'Start Cooking',
            ),
          ),
          if (active)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Your cooking session keeps its saved recipe. Edits apply to future sessions.',
              ),
            ),
        ],
      ),
    );
  }
}
