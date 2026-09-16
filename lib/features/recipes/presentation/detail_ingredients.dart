import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/providers.dart';
import '../../../core/errors/app_failure.dart';
import '../data/ingredient_check_store.dart';
import '../domain/recipe.dart';
import 'recipe_screen.dart';
import 'recipe_text.dart';

final detailChecksProvider = AsyncNotifierProvider.autoDispose
    .family<DetailChecks, Set<String>, String>(DetailChecks.new);

class DetailChecks extends AsyncNotifier<Set<String>> {
  DetailChecks(this.id);
  final String id;
  Future<void> _tail = Future.value();
  Future<void> get settled => _tail;

  @override
  Future<Set<String>> build() async {
    final account = await ref.watch(accountProvider.future);
    final recipe = await ref.watch(recipeDetailProvider(id).future);
    if (account == null || recipe == null) return {};
    final db = await ref.watch(databaseProvider.future);
    return IngredientCheckStore(db, account.id).update(recipe);
  }

  Future<void> change({String? toggle, bool clear = false}) {
    final action = _tail.then((_) => _change(toggle: toggle, clear: clear));
    _tail = action.then((_) {}, onError: (Object _, StackTrace _) {});
    return action;
  }

  Future<void> _change({String? toggle, bool clear = false}) async {
    await future;
    final account = await ref.read(accountProvider.future);
    final recipe = await ref.read(recipeDetailProvider(id).future);
    if (account == null || recipe == null) return;
    final db = await ref.read(databaseProvider.future);
    final checked = await IngredientCheckStore(
      db,
      account.id,
    ).update(recipe, toggle: toggle, clear: clear);
    if (ref.mounted) state = AsyncData(checked);
  }
}

Future<void> changeDetailChecks(
  BuildContext context,
  WidgetRef ref,
  String id, {
  String? toggle,
  bool clear = false,
}) async {
  try {
    await ref
        .read(detailChecksProvider(id).notifier)
        .change(toggle: toggle, clear: clear);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeFailure(e).message)));
    }
  }
}

class DetailIngredients extends ConsumerWidget {
  const DetailIngredients(this.recipe, {super.key});
  final Recipe recipe;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final checks = ref.watch(detailChecksProvider(recipe.id));
    final keys = ingredientKeys(recipe.ingredients);
    final checked = checks.value ?? <String>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Ingredients', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (checks.hasError) Text(safeFailure(checks.error!).message),
        if (recipe.ingredients.isEmpty)
          const Text('Not provided in this recipe.'),
        for (var i = 0; i < recipe.ingredients.length; i++)
          if (keys[i] == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: RecipeText(recipe.ingredients[i]),
            )
          else
            CheckboxListTile(
              key: ValueKey(keys[i]),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: checked.contains(keys[i]),
              onChanged: checks.isLoading || checks.hasError
                  ? null
                  : (_) => changeDetailChecks(
                      context,
                      ref,
                      recipe.id,
                      toggle: keys[i],
                    ),
              title: Text(
                recipe.ingredients[i],
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  decoration: checked.contains(keys[i])
                      ? TextDecoration.lineThrough
                      : null,
                  color: checked.contains(keys[i])
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : null,
                ),
              ),
            ),
        const SizedBox(height: 24),
      ],
    );
  }
}
