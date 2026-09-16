import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/theme/theme_providers.dart';
import '../../../core/theme/server_theme.dart';
import '../../../core/errors/app_failure.dart';
import '../../recipes/data/image_cache.dart';
import '../../recipes/data/image_repository.dart';
import '../../sync/presentation/sync_providers.dart';

class DiagnosticsPanel extends ConsumerStatefulWidget {
  const DiagnosticsPanel({super.key, this.section = 'diagnostics'});
  final String section;
  @override
  ConsumerState<DiagnosticsPanel> createState() => _DiagnosticsPanelState();
}

class _DiagnosticsPanelState extends ConsumerState<DiagnosticsPanel> {
  bool busy = false;
  String? result;
  Future<void> testConnection() async {
    setState(() => busy = true);
    try {
      final account = await ref.read(accountProvider.future);
      if (account == null) return;
      ref.invalidate(cookbookProvider);
      await ref.read(cookbookProvider.future);
      if (mounted) {
        setState(() => result = 'Connected to Nextcloud and Cookbook.');
      }
    } catch (e) {
      if (mounted) setState(() => result = safeFailure(e).message);
    } finally {
      if (mounted) {
        setState(() => busy = false);
        ref.invalidate(diagnosticsProvider);
      }
    }
  }

  Future<void> cacheAction({int? limit}) async {
    try {
      final account = await ref.read(accountProvider.future);
      if (account == null) return;
      final cache = ImageCacheStore(
        await ref.read(databaseProvider.future),
        account.id,
      );
      if (limit == null) {
        await cache.clear();
      } else {
        await cache.setLimit(limit);
      }
      ref.invalidate(recipeImageProvider);
      ref.invalidate(diagnosticsProvider);
    } catch (e) {
      if (mounted) setState(() => result = safeFailure(e).message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(diagnosticsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.section == 'diagnostics') ...[
          Text(
            'Connection & diagnostics',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const Text(
            'Status reflects completed requests; it is not a continuous connectivity monitor.',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: busy ? null : testConnection,
            icon: const Icon(Icons.network_check),
            label: Text(busy ? 'Testing…' : 'Test connection'),
          ),
          if (result != null) SelectableText(result!),
        ],
        if (widget.section != 'appearance')
          data.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text(safeFailure(e).message),
            data: (d) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.section == 'diagnostics') ...[
                  ListTile(
                    title: const Text('Nextcloud connection'),
                    subtitle: Text(
                      'Version: ${d['nextcloud_version'] ?? "Unknown"}\nLast connection test: ${d['last_connection_test'] ?? "Never"}',
                    ),
                  ),
                  ExpansionTile(
                    title: const Text('Last HTTP result'),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(
                          '${d['last_http_result'] ?? "No result"}',
                        ),
                      ),
                    ],
                  ),
                  ListTile(
                    title: const Text('Server theme'),
                    subtitle: Text(
                      'Detected: ${ref.watch(serverThemeProvider).asData?.value.detected == true ? "Yes" : "No · using Nextcloud blue"}\nPrimary: ${colorHex(ref.watch(serverThemeProvider).asData?.value.color ?? nextcloudBlue)}',
                    ),
                  ),
                  ListTile(
                    title: const Text('Server support'),
                    subtitle: Text(
                      'Cookbook: ${d['detected'] == true ? "detected" : "not verified"}\nApp: ${d['app_version'] ?? "Unknown"} · API: ${d['api_version'] ?? "Unknown"}\n${d['capabilities'] ?? "Unavailable"}',
                    ),
                  ),
                  ListTile(
                    title: const Text('Recipe counts'),
                    subtitle: Text(
                      'Local: ${d['local_count'] ?? 0} · Server last listed: ${d['server_count'] ?? "Unknown"}',
                    ),
                  ),
                  ListTile(
                    title: const Text('Sync history'),
                    subtitle: Text(
                      'Last attempt: ${d['last_attempt'] ?? "Never"}\nLast success: ${d['last_success'] ?? "Never"}\nStatus: ${d['status'] ?? "Not started"}\nLast error: ${d['last_error'] ?? "None"}',
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.sync_problem_outlined),
                    title: const Text('Review synchronization'),
                    subtitle: Text(
                      'Pending / failed: ${d['pending_count'] ?? 0} · Conflicts: ${d['conflict_count'] ?? 0} · Uncertain: ${d['uncertain_count'] ?? 0}',
                    ),
                    onTap: () => context.push('/sync-review'),
                  ),
                ],
                if (widget.section == 'storage') ...[
                  ListTile(
                    title: const Text('Image cache'),
                    subtitle: Text(
                      '${((d['cache_bytes'] as int? ?? 0) / 1048576).toStringAsFixed(1)} MiB used. Recipe text is retained separately.',
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final mb in [50, 200, 500])
                        ChoiceChip(
                          label: Text('$mb MiB'),
                          selected: d['cache_limit'] == mb * 1048576,
                          onSelected: (_) => cacheAction(limit: mb * 1048576),
                        ),
                    ],
                  ),
                  TextButton.icon(
                    onPressed: () => cacheAction(),
                    icon: const Icon(Icons.cleaning_services_outlined),
                    label: const Text('Clear image cache'),
                  ),
                ],
              ],
            ),
          ),
        if (widget.section == 'appearance')
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Accent follows your Nextcloud server.'),
              const SizedBox(height: 8),
              DropdownButtonFormField<ThemeMode>(
                decoration: const InputDecoration(labelText: 'Color mode'),
                initialValue:
                    ref.watch(appearanceProvider).asData?.value ??
                    ThemeMode.system,
                items: [
                  for (final mode in ThemeMode.values)
                    DropdownMenuItem(
                      value: mode,
                      child: Text(switch (mode) {
                        ThemeMode.system => 'System',
                        ThemeMode.light => 'Light',
                        ThemeMode.dark => 'Dark',
                      }),
                    ),
                ],
                onChanged: (mode) async {
                  if (mode == null) return;
                  try {
                    await ref.read(appearanceProvider.notifier).setMode(mode);
                  } catch (e) {
                    if (mounted) {
                      setState(() => result = safeFailure(e).message);
                    }
                  }
                },
              ),
              if (result != null) Text(result!),
            ],
          ),
      ],
    );
  }
}
