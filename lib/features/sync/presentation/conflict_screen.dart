import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/errors/app_failure.dart';
import '../domain/recipe_comparison.dart';
import 'sync_providers.dart';

class ConflictScreen extends ConsumerStatefulWidget {
  const ConflictScreen(this.id, {super.key});
  final String id;
  @override
  ConsumerState<ConflictScreen> createState() => _ConflictScreenState();
}

class _ConflictScreenState extends ConsumerState<ConflictScreen> {
  bool busy = false;
  Future<void> resolve(bool local) async {
    setState(() => busy = true);
    try {
      await (await ref.read(
        mutationStoreProvider.future,
      )).resolve(widget.id, keepLocal: local);
      ref.read(syncProvider.notifier).localChanged();
      if (mounted) context.go('/recipe/${Uri.encodeComponent(widget.id)}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeFailure(e).message)));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Resolve conflict')),
    body: ref
        .watch(conflictProvider(widget.id))
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text(safeFailure(e).message)),
          data: (record) {
            if (record == null) {
              return const Center(child: Text('No unresolved conflict.'));
            }
            final snapshots = {
              'Base': decodeRecipe(record['base_json']),
              'Local': decodeRecipe(record['local_json']),
              'Server': decodeRecipe(record['server_json']),
            };
            final keys =
                snapshots.values
                    .whereType<Map>()
                    .expand((m) => m.keys.cast<String>())
                    .toSet()
                    .toList()
                  ..sort();
            final changed = keys
                .where(
                  (key) =>
                      jsonEncode(sortedJson(snapshots['Base']?[key])) !=
                          jsonEncode(sortedJson(snapshots['Local']?[key])) ||
                      jsonEncode(sortedJson(snapshots['Base']?[key])) !=
                          jsonEncode(sortedJson(snapshots['Server']?[key])),
                )
                .toList();
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(
                      record['kind'] == 'delete'
                          ? 'Your local intent is to delete this recipe.'
                          : 'Choose which complete version to keep.',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Keep Local queues your choice against the shown server version. It will be checked again before upload. No automatic field merge is performed.',
                    ),
                    const SizedBox(height: 16),
                    for (final key in changed)
                      Card(
                        child: ExpansionTile(
                          title: Text(key),
                          initiallyExpanded:
                              key == 'name' || key == 'description',
                          childrenPadding: const EdgeInsets.all(16),
                          children: [
                            for (final snapshot in snapshots.entries)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: SelectableText(
                                    '${snapshot.key}: ${snapshot.value == null ? 'Recipe absent' : const JsonEncoder.withIndent('  ').convert(snapshot.value![key])}',
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    for (final snapshot in snapshots.entries)
                      ExpansionTile(
                        title: Text('Full ${snapshot.key.toLowerCase()} JSON'),
                        children: [
                          SelectableText(
                            const JsonEncoder.withIndent(
                              '  ',
                            ).convert(snapshot.value),
                          ),
                        ],
                      ),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        FilledButton(
                          onPressed: busy ? null : () => resolve(true),
                          child: const Text('Keep Local'),
                        ),
                        OutlinedButton(
                          onPressed: busy ? null : () => resolve(false),
                          child: const Text('Keep Server'),
                        ),
                        TextButton(
                          onPressed: busy ? null : () => context.go('/library'),
                          child: const Text('Decide Later'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
  );
}
