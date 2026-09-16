import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/providers.dart';
import '../../../core/errors/app_failure.dart';
import '../data/server_cookbook_settings.dart';

final serverSettingsProvider = FutureProvider<ServerCookbookSettings>((
  ref,
) async {
  final account = await ref.watch(accountProvider.future);
  ref.watch(syncProvider.select((s) => s.revision));
  if (account == null) return const ServerCookbookSettings({});
  final db = await ref.watch(databaseProvider.future);
  final rows = await db.db.query(
    'account_metadata',
    where: 'account_id=? AND key=?',
    whereArgs: [account.id, 'cookbook_config'],
  );
  return ServerCookbookSettings(
    rows.isEmpty
        ? {}
        : (jsonDecode(rows.single['value'] as String) as Map)
              .cast<String, Object?>(),
  );
});
final serverCookbookServiceProvider = FutureProvider<ServerCookbookService>((
  ref,
) async {
  final account = await ref.watch(accountProvider.future);
  if (account == null) throw const AppFailure(FailureKind.authentication);
  return ServerCookbookService(
    await ref.watch(databaseProvider.future),
    await ref.watch(cookbookProvider.future),
    account.id,
  );
});
Future<String?> settingText(
  BuildContext context,
  String title,
  String initial,
  String explanation, {
  bool number = false,
}) async {
  var text = initial;
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(explanation),
            const SizedBox(height: 16),
            TextFormField(
              initialValue: initial,
              keyboardType: number ? TextInputType.number : TextInputType.text,
              onChanged: (s) => text = s,
              decoration: InputDecoration(labelText: title),
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
          onPressed: () => Navigator.pop(context, text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

Future<void> serverAction(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function(ServerCookbookService) action,
) async {
  try {
    await action(await ref.read(serverCookbookServiceProvider.future));
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${safeFailure(e).message} Server actions require a connection. Reload server settings before retrying an interrupted folder change or rename.',
          ),
        ),
      );
    }
  } finally {
    ref.invalidate(serverSettingsProvider);
    ref.read(syncProvider.notifier).localChanged();
  }
}

Future<void> renameCategoryDialog(
  BuildContext context,
  WidgetRef ref,
  String category,
) async {
  final value = await settingText(
    context,
    'Rename category',
    category,
    'Changes this category on Nextcloud. Existing recipes in the destination category will be combined. Synchronize pending edits first. Requires a connection.',
  );
  if (value == null || value == category || !context.mounted) return;
  await serverAction(
    context,
    ref,
    (service) => service.rename(category, value),
  );
}

class ServerSettings extends ConsumerStatefulWidget {
  const ServerSettings({super.key});
  @override
  ConsumerState<ServerSettings> createState() => _ServerSettingsState();
}

class _ServerSettingsState extends ConsumerState<ServerSettings> {
  bool busy = false;
  Future<void> run(Future<void> Function(ServerCookbookService) action) async {
    setState(() => busy = true);
    await serverAction(context, ref, action);
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final config =
        ref.watch(serverSettingsProvider).asData?.value ??
        const ServerCookbookSettings({});
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Nextcloud Cookbook settings',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const Text(
          'These settings belong to Cookbook on your server. Changes require a connection.',
        ),
        if (busy) const LinearProgressIndicator(),
        TextButton.icon(
          onPressed: busy
              ? null
              : () => run((s) async {
                  ref.invalidate(cookbookProvider);
                  final fresh = await ref.read(
                    serverCookbookServiceProvider.future,
                  );
                  await fresh.reload();
                }),
          icon: const Icon(Icons.refresh),
          label: const Text('Reload server settings'),
        ),
        ListTile(
          title: const Text('Recipe folder'),
          subtitle: Text(config.folder.isEmpty ? 'Not loaded' : config.folder),
          trailing: const Icon(Icons.edit_outlined),
          onTap: busy
              ? null
              : () async {
                  final path = await settingText(
                    context,
                    'Recipe folder',
                    config.folder,
                    'Changing this folder rebuilds Cookbook’s server index and replaces this device’s recipe cache. Files are not moved. Finish synchronizing all pending edits first. Cooking snapshots remain local.',
                  );
                  if (path != null && path != config.folder) {
                    await run((s) async {
                      await s.update({'folder': path});
                    });
                  }
                },
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'To share recipes, share this folder using Nextcloud Files, then select it as the Cookbook recipe folder.',
          ),
        ),
        ListTile(
          title: const Text('Server index update interval'),
          subtitle: Text(
            '${config.interval} minutes · separate from mobile synchronization',
          ),
          trailing: const Icon(Icons.edit_outlined),
          onTap: busy
              ? null
              : () async {
                  final value = await settingText(
                    context,
                    'Interval in minutes',
                    '${config.interval}',
                    'Whole minutes, at least 1. Cookbook checks its files for changes when the server index is due.',
                    number: true,
                  );
                  if (value != null) {
                    await run((s) async {
                      await s.update({'update_interval': int.tryParse(value)});
                    });
                  }
                },
        ),
        SwitchListTile(
          title: const Text('Print image with recipe'),
          subtitle: const Text('Used by Cookbook’s web print view'),
          value: config.printImage,
          onChanged: busy
              ? null
              : (v) => run((s) async {
                  await s.update({'print_image': v});
                }),
        ),
        ExpansionTile(
          title: const Text('Visible information blocks'),
          children: [
            for (final entry in infoBlocks.entries)
              SwitchListTile(
                title: Text(entry.value),
                value: config.visible(entry.key),
                onChanged: busy
                    ? null
                    : (v) => run((s) async {
                        final latest = await s.reload();
                        await s.update(latest.blockChange(entry.key, v));
                      }),
              ),
          ],
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.sync),
          label: const Text('Rescan library'),
          onPressed: busy
              ? null
              : () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Rescan library?'),
                      content: const Text(
                        'Compare recipe files with Cookbook’s server index. Useful after external file changes; large libraries can take time.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Rescan'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await run((s) async {
                      await s.rescan();
                    });
                  }
                },
        ),
        const Divider(height: 40),
      ],
    );
  }
}
