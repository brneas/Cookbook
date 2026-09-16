import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/errors/app_failure.dart';
import '../../sync/presentation/sync_providers.dart';
import '../domain/recipe.dart';
import 'detail_ingredients.dart';

class RecipeActions extends ConsumerWidget {
  const RecipeActions(this.recipe, {super.key, this.menuOnly = false});
  final bool menuOnly;
  final Recipe recipe;
  Future<void> remove(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete recipe?'),
        content: Text(
          'Delete “${recipe.name}”? This will queue a deletion from your server. You can undo it until synchronization starts.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep recipe'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete recipe'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final store = await ref.read(mutationStoreProvider.future);
      await store.delete(recipe.id);
      ref.read(syncProvider.notifier).localChanged();
      if (!context.mounted) return;
      // Leave deletion queued so the undo window does not race an automatic upload.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Deletion queued. Undo is available in sync review.',
          ),
          action: SnackBarAction(
            label: 'Review',
            onPressed: () => context.push('/sync-review'),
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeFailure(e).message)));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final row = ref.watch(recipeRecordProvider(recipe.id)).asData?.value;
    if (row == null) return const SizedBox.shrink();
    final blocked =
        row['local_deleted'] == 1 ||
        row['remote_state'] == 'deleted' ||
        ['conflict', 'unknownOutcome', 'sending'].contains(row['sync_state']) ||
        row['import_pending'] == true;
    final hasChecks =
        menuOnly &&
        ref.watch(detailChecksProvider(recipe.id)).value?.isNotEmpty == true;
    if (menuOnly) {
      return PopupMenuButton<String>(
        tooltip: 'Recipe actions',
        onSelected: (action) {
          switch (action) {
            case 'clear':
              changeDetailChecks(context, ref, recipe.id, clear: true);
            case 'edit':
              context.push('/editor/${Uri.encodeComponent(recipe.id)}');
            case 'delete':
              remove(context, ref);
            case 'conflict':
              context.push('/conflict/${Uri.encodeComponent(recipe.id)}');
            case 'sync':
              context.push('/sync-review');
          }
        },
        itemBuilder: (_) => [
          if (hasChecks)
            const PopupMenuItem(
              value: 'clear',
              child: Text('Clear ingredient checks'),
            ),
          PopupMenuItem(
            value: 'edit',
            enabled: !blocked,
            child: const Text('Edit recipe'),
          ),
          PopupMenuItem(
            value: 'delete',
            enabled: !blocked,
            child: const Text('Delete recipe'),
          ),
          if (row['sync_state'] == 'conflict')
            const PopupMenuItem(
              value: 'conflict',
              child: Text('Review conflict'),
            ),
          if (row['sync_state'] != 'clean')
            const PopupMenuItem(
              value: 'sync',
              child: Text('Review synchronization'),
            ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            row['local_deleted'] == 1
                ? 'Deletion queued · undo in sync review'
                : syncLabel(row),
          ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: blocked
                    ? null
                    : () => context.push(
                        '/editor/${Uri.encodeComponent(recipe.id)}',
                      ),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit recipe'),
              ),
              TextButton.icon(
                onPressed: blocked ? null : () => remove(context, ref),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete recipe'),
              ),
              if (row['sync_state'] == 'conflict')
                TextButton(
                  onPressed: () => context.push(
                    '/conflict/${Uri.encodeComponent(recipe.id)}',
                  ),
                  child: const Text('Review conflict'),
                ),
              if (row['sync_state'] != 'clean')
                TextButton(
                  onPressed: () => context.push('/sync-review'),
                  child: const Text('Review synchronization'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
