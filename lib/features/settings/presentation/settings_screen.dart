import '../../../core/platform/app_version.dart';
import '../../../core/theme/layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/errors/app_failure.dart';
import 'diagnostics_panel.dart';
import '../../cooking/presentation/cooking_settings.dart';
import 'server_settings.dart';

final accountStatusProvider = FutureProvider<Map<String, Object?>?>((
  ref,
) async {
  final account = await ref.watch(accountProvider.future);
  ref.watch(syncProvider.select((s) => s.revision));
  if (account == null) return null;
  final database = await ref.watch(databaseProvider.future);
  final rows = await database.db.rawQuery(
    'SELECT accounts.*, sync_metadata.last_success FROM accounts LEFT JOIN sync_metadata ON accounts.id = sync_metadata.account_id WHERE accounts.id = ?',
    [account.id],
  );
  return rows.isEmpty ? null : rows.first;
});

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _removing = false;
  Future<void> _remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this account?'),
        content: const Text(
          'Downloaded recipes, unsynchronized edits, queued imports and local account data will be removed from this device. Unsynchronized work cannot be recovered after removal. Your server recipes will remain. Cookbook will also try to revoke its app password.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep account'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove account'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _removing = true);
    try {
      final revoked = await ref.read(accountProvider.notifier).remove();
      if (!mounted) return;
      if (!revoked) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Local data removed. Revoke Cookbook’s app password in Nextcloud Security settings when your server is reachable.',
            ),
          ),
        );
      }
      context.go('/connect');
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeFailure(error).message)));
      }
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider).asData?.value;
    final version = ref.watch(appVersionProvider).value ?? 'Unknown';
    final sync = ref.watch(syncProvider);
    final metadata = ref.watch(accountStatusProvider).asData?.value;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppLayout.settingsWidth),
        child: ListView(
          padding: AppLayout.pageInsets,
          children: [
            Text('Account', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: Text(account?.server.toString() ?? 'No account'),
              subtitle: Text(account?.loginName ?? ''),
            ),
            ExpansionTile(
              title: const Text('Nextcloud Cookbook'),
              subtitle: const Text(
                'Recipe folder, metadata and server preferences',
              ),
              children: const [ServerSettings()],
            ),
            const Divider(height: 32),
            Text(
              'Synchronization',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            ListTile(
              leading: const Icon(Icons.sync),
              title: Text(sync.running ? 'Synchronizing…' : 'Synchronize now'),
              subtitle: Text(
                metadata?['last_success'] == null
                    ? 'No completed synchronization yet'
                    : 'Last successful sync: ${metadata!['last_success']}',
              ),
              onTap: sync.running || _removing
                  ? null
                  : () => ref.read(syncProvider.notifier).request('settings'),
            ),
            if (sync.error != null)
              Padding(
                padding: AppLayout.compactInsets,
                child: Text(sync.error!.message),
              ),
            ListTile(
              leading: const Icon(Icons.sync_problem_outlined),
              title: const Text('Review synchronization'),
              onTap: () => context.push('/sync-review'),
            ),
            ExpansionTile(
              title: const Text('Connection & diagnostics'),
              children: const [DiagnosticsPanel()],
            ),
            ExpansionTile(
              title: const Text('Cooking'),
              subtitle: const Text('Screen, text size and timer alerts'),
              children: const [CookingSettings()],
            ),
            const Divider(height: 32),
            Text('Appearance', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            const DiagnosticsPanel(section: 'appearance'),
            const Divider(height: 32),
            ExpansionTile(
              title: const Text('Storage'),
              subtitle: const Text('Downloaded recipe images'),
              children: const [DiagnosticsPanel(section: 'storage')],
            ),
            const Divider(height: 32),
            Text(
              'About Cookbook',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Text(
              'Version $version\nUnofficial Nextcloud Cookbook client\nNo ads, analytics, or intermediary cloud service.',
            ),
            const SizedBox(height: 16),
            const Text(
              'Create and edit recipes offline. Review conflicts and uncertain uploads before retrying. Appearance follows your device’s light or dark theme.',
            ),
            ListTile(
              leading: const Icon(Icons.code),
              title: const Text('Open-source licenses'),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Cookbook',
                applicationVersion: version,
              ),
            ),
            const SizedBox(height: 32),
            OutlinedButton.icon(
              onPressed: _removing ? null : _remove,
              icon: const Icon(Icons.logout),
              label: Text(_removing ? 'Removing account…' : 'Remove account'),
            ),
          ],
        ),
      ),
    );
  }
}
