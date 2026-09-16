import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/errors/app_failure.dart';
import '../data/sync_engine.dart';
import 'sync_providers.dart';

class OperationsScreen extends ConsumerWidget {
  const OperationsScreen({super.key});
  Future<void> act(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      ref.read(syncProvider.notifier).localChanged();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeFailure(e).message)));
      }
    }
  }

  Future<void> match(
    BuildContext context,
    WidgetRef ref,
    Map<String, Object?> op,
  ) async {
    final input = TextEditingController();
    final id = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Find the created recipe'),
        content: TextField(
          controller: input,
          decoration: const InputDecoration(labelText: 'Server recipe ID'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('Inspect recipe'),
          ),
        ],
      ),
    );
    input.dispose();
    if (id == null || id.isEmpty || !context.mounted) return;
    await act(context, ref, () async {
      final api = await ref.read(cookbookProvider.future);
      final recipe = await api.recipe(id);
      if (!context.mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Associate “${recipe.name}”?'),
          content: SingleChildScrollView(
            child: SelectableText(
              'Intended operation:\n${op['payload_json']}\n\nServer recipe:\n${const JsonEncoder.withIndent('  ').convert(recipe.toJson())}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Associate this recipe'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      final account = (await ref.read(accountProvider.future))!;
      await SyncEngine(
        await ref.read(databaseProvider.future),
        api,
        account.id,
      ).attachUnknown(op['id'] as int, id, inspectedRecipe: recipe);
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Synchronization review')),
    body: ref
        .watch(operationsProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text(safeFailure(e).message)),
          data: (ops) => ops.isEmpty
              ? const Center(child: Text('All local changes are synchronized.'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text(
                      'Uncertain uploads are never automatically repeated. Check your server or retry synchronization to reconcile them.',
                    ),
                    const SizedBox(height: 16),
                    for (final op in ops)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${op['name'] ?? op['recipe_id']}',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              Text('${op['kind']} · ${op['state']}'),
                              if (op['error_kind'] != null)
                                Text('Last error: ${op['error_kind']}'),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  if (op['state'] == 'conflict')
                                    FilledButton(
                                      onPressed: () => context.push(
                                        '/conflict/${Uri.encodeComponent(op['recipe_id'] as String)}',
                                      ),
                                      child: const Text('Review conflict'),
                                    ),
                                  if (op['state'] == 'failed')
                                    OutlinedButton(
                                      onPressed: () =>
                                          act(context, ref, () async {
                                            await (await ref.read(
                                              mutationStoreProvider.future,
                                            )).retryFailed(op['id'] as int);
                                          }),
                                      child: const Text(
                                        'Retry after checking server',
                                      ),
                                    ),
                                  if (op['kind'] == 'delete' &&
                                      op['state'] == 'queued')
                                    OutlinedButton(
                                      onPressed: () =>
                                          act(context, ref, () async {
                                            await (await ref.read(
                                              mutationStoreProvider.future,
                                            )).undoDelete(
                                              op['recipe_id'] as String,
                                            );
                                          }),
                                      child: const Text('Undo queued delete'),
                                    ),
                                  if (op['state'] == 'unknownOutcome' &&
                                      ['create', 'import'].contains(op['kind']))
                                    OutlinedButton(
                                      onPressed: () => match(context, ref, op),
                                      child: const Text(
                                        'Associate server recipe',
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    FilledButton.icon(
                      onPressed: ref.watch(syncProvider).running
                          ? null
                          : () => ref
                                .read(syncProvider.notifier)
                                .request('queue retry', mutation: true),
                      icon: const Icon(Icons.sync),
                      label: const Text('Sync / reconcile now'),
                    ),
                  ],
                ),
        ),
  );
}
