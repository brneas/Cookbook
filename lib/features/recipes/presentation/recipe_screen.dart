import '../../../core/theme/layout.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../app/providers.dart';
import '../../../core/errors/app_failure.dart';
import '../domain/recipe.dart';
import 'recipe_thumbnail.dart';
import '../data/image_repository.dart';
import '../../editor/domain/recipe_draft.dart';
import '../../sync/presentation/sync_providers.dart';
import 'recipe_actions.dart';
import '../../cooking/presentation/cooking_hub.dart';
import '../../settings/presentation/server_settings.dart';
import '../../settings/data/server_cookbook_settings.dart';
import 'recipe_text.dart';
import 'detail_ingredients.dart';

final recipeDetailProvider = FutureProvider.autoDispose.family<Recipe?, String>(
  (ref, id) async {
    final row = await ref.watch(recipeRecordProvider(id).future);
    if (row == null || row['detail_json'] == null) return null;
    return recipeFromRow(row);
  },
);

class RecipeScreen extends ConsumerWidget {
  const RecipeScreen(this.id, {super.key});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        tooltip: 'Recipe library',
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/library'),
        icon: const Icon(Icons.arrow_back),
      ),
      title: const Text('Recipe'),
      actions: [
        if (ref.watch(recipeDetailProvider(id)).asData?.value
            case final Recipe recipe)
          RecipeActions(recipe, menuOnly: true),
      ],
    ),
    body: ref
        .watch(recipeDetailProvider(id))
        .when(
          skipLoadingOnReload: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text(safeFailure(error).message)),
          data: (recipe) {
            final config =
                ref.watch(serverSettingsProvider).asData?.value ??
                const ServerCookbookSettings({});
            if (recipe == null) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('This recipe has not been downloaded yet.'),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: ref.watch(syncProvider).running
                            ? null
                            : () => ref
                                  .read(syncProvider.notifier)
                                  .request('detail download'),
                        child: const Text('Download recipes'),
                      ),
                    ],
                  ),
                ),
              );
            }
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppLayout.readingWidth,
                ),
                child: ListView(
                  padding: AppLayout.pageInsets,
                  children: [
                    LayoutBuilder(
                      builder: (context, box) {
                        final imageAvailable =
                            ref
                                .watch(recipeFullImageProvider(recipe.id))
                                .asData
                                ?.value !=
                            null;
                        final hero = AspectRatio(
                          aspectRatio: 4 / 3,
                          child: RecipeThumbnail(recipe.id, hero: true),
                        );
                        final summary = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              recipe.name,
                              style: Theme.of(context).textTheme.headlineLarge,
                            ),
                            const SizedBox(height: 12),
                            StartCookingButton(recipe),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (recipe.category.isNotEmpty)
                                  ActionChip(
                                    label: Text(recipe.category),
                                    onPressed: () => context.push(
                                      Uri(
                                        path: '/library',
                                        queryParameters: {
                                          'category': recipe.category,
                                        },
                                      ).toString(),
                                    ),
                                  ),
                                for (final tag in recipe.keywords)
                                  ActionChip(
                                    label: Text(tag),
                                    onPressed: () => context.push(
                                      Uri(
                                        path: '/library',
                                        queryParameters: {'keyword': tag},
                                      ).toString(),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 24,
                              runSpacing: 12,
                              children: [
                                if (recipe.yieldText.isNotEmpty)
                                  Text('Yield: ${recipe.yieldText}'),
                                for (final time in {
                                  'prepTime': 'Prep',
                                  'cookTime': 'Cook',
                                  'totalTime': 'Total',
                                }.entries)
                                  if (recipe.duration(time.key) != null &&
                                      config.visible(
                                        const {
                                          'prepTime': 'preparation-time',
                                          'cookTime': 'cooking-time',
                                          'totalTime': 'total-time',
                                        }[time.key]!,
                                      ))
                                    Text(
                                      '${time.value}: ${displayRecipeDuration(recipe.duration(time.key)!)}',
                                    ),
                              ],
                            ),
                            if (recipe.description.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 24,
                                ),
                                child: RecipeText(
                                  recipe.description,
                                  style: Theme.of(context).textTheme.bodyLarge,
                                ),
                              ),
                          ],
                        );
                        if (box.maxWidth >= 760 && imageAvailable) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 24),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(flex: 2, child: hero),
                                const SizedBox(width: 32),
                                Expanded(flex: 3, child: summary),
                              ],
                            ),
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (imageAvailable) ...[
                              hero,
                              const SizedBox(height: 24),
                            ],
                            summary,
                          ],
                        );
                      },
                    ),
                    LayoutBuilder(
                      builder: (context, box) {
                        final ingredients = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (recipe.ingredients.isNotEmpty)
                              TextButton.icon(
                                onPressed: () async {
                                  await Clipboard.setData(
                                    ClipboardData(
                                      text: recipe.ingredients.join('\n'),
                                    ),
                                  );
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Ingredients copied.'),
                                      ),
                                    );
                                  }
                                },
                                icon: const Icon(Icons.copy_outlined),
                                label: const Text('Copy ingredients'),
                              ),
                            DetailIngredients(recipe),
                            if (recipe.tools.isNotEmpty &&
                                config.visible('tools'))
                              _section(context, 'Equipment', recipe.tools),
                          ],
                        );
                        final leaves = InstructionTree(
                          recipe.toJson()['recipeInstructions'],
                        ).leaves;
                        final steps = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Instructions',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 16),
                            if (leaves.isEmpty)
                              const Text('Not provided in this recipe.'),
                            for (var i = 0; i < leaves.length; i++) ...[
                              if (leaves[i].sections.isNotEmpty &&
                                  (i == 0 ||
                                      leaves[i - 1].sections.join(' › ') !=
                                          leaves[i].sections.join(' › ')))
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Text(
                                    leaves[i].sections.join(' › '),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 24),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: 32,
                                      child: Text(
                                        '${i + 1}.',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodyLarge,
                                      ),
                                    ),
                                    Expanded(
                                      child: RecipeText(
                                        leaves[i].text,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodyLarge,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        );
                        return box.maxWidth >= 760
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 2, child: ingredients),
                                  const SizedBox(width: 40),
                                  Expanded(flex: 3, child: steps),
                                ],
                              )
                            : Column(children: [ingredients, steps]);
                      },
                    ),
                    if (config.visible('nutrition-information') &&
                        recipe.toJson()['nutrition'] is Map) ...[
                      Text(
                        'Nutrition',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      for (final item
                          in (recipe.toJson()['nutrition'] as Map).entries
                              .where((e) => e.key != '@type'))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text('${item.key}: ${item.value}'),
                        ),
                    ],
                    for (final key in [
                      'author',
                      'publisher',
                      'recipeCuisine',
                      'cookingMethod',
                      'suitableForDiet',
                      'license',
                    ])
                      if (recipe.toJson()[key] != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            '${_metadataLabels[key] ?? key}: ${metadataText(recipe.toJson()[key])}',
                          ),
                        ),
                    for (final key in [
                      'dateCreated',
                      'dateModified',
                      'datePublished',
                    ])
                      if (parseRecipeDate(recipe.toJson()[key])
                          case final DateTime date)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            '${_metadataLabels[key] ?? key}: ${MaterialLocalizations.of(context).formatMediumDate(date.toLocal())}',
                          ),
                        ),
                    if (recipe.text('url').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('Open original recipe website'),
                          onPressed: () async {
                            final uri = Uri.tryParse(recipe.text('url'));
                            final safe =
                                uri != null &&
                                ['https', 'http'].contains(uri.scheme) &&
                                uri.host.isNotEmpty &&
                                uri.userInfo.isEmpty;
                            var opened = false;
                            if (safe) {
                              try {
                                opened = await launchUrl(
                                  uri,
                                  mode: LaunchMode.externalApplication,
                                );
                              } catch (_) {
                                opened = false;
                              }
                            }
                            if (!opened && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'This source link could not be opened.',
                                  ),
                                ),
                              );
                            }
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
  );
  Widget _section(BuildContext context, String title, List<String> lines) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          if (lines.isEmpty) const Text('Not provided in this recipe.'),
          for (var i = 0; i < lines.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: RecipeText(
                lines[i],
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          const SizedBox(height: 16),
        ],
      );
}

String metadataText(Object? value) {
  if (value is Map) {
    return [
      if (value['name'] != null) metadataText(value['name']),
      if (value['url'] != null) metadataText(value['url']),
    ].join(' · ');
  }
  if (value is List) {
    return value.map(metadataText).where((s) => s.isNotEmpty).join(', ');
  }
  return value?.toString() ?? '';
}

String displayRecipeDuration(Duration value) =>
    '${value.inHours > 0 ? '${value.inHours} h ' : ''}${value.inMinutes % 60} min${value.inSeconds % 60 > 0 ? ' ${value.inSeconds % 60} sec' : ''}';

const _metadataLabels = {
  'author': 'Author',
  'publisher': 'Publisher',
  'recipeCuisine': 'Cuisine',
  'cookingMethod': 'Method',
  'suitableForDiet': 'Diet',
  'license': 'License',
  'dateCreated': 'Created',
  'dateModified': 'Updated',
  'datePublished': 'Published',
};
