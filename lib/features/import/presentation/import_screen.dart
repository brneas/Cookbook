import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/errors/app_failure.dart';
import '../../sync/presentation/sync_providers.dart';

class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});
  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  final url = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    url.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final uri = Uri.tryParse(url.text.trim());
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        setState(
          () => error = 'Enter a complete http:// or https:// recipe URL.',
        );
        return;
      }
      final id = await (await ref.read(
        mutationStoreProvider.future,
      )).queueImport(uri);
      ref.read(syncProvider.notifier).localChanged();
      // Durable queue first; leaving this screen cannot lose or repeat the import.
      ref.read(syncProvider.notifier).request('import', mutation: true);
      if (mounted) context.go('/recipe/${Uri.encodeComponent(id)}');
    } catch (e) {
      if (mounted) setState(() => error = safeFailure(e).message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Import from URL')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Your Nextcloud Cookbook server will import the recipe. This app does not scrape the website.',
            ),
            const SizedBox(height: 24),
            TextField(
              controller: url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Recipe URL'),
            ),
            const SizedBox(height: 16),
            if (error != null) Semantics(liveRegion: true, child: Text(error!)),
            FilledButton.icon(
              onPressed: busy ? null : submit,
              icon: const Icon(Icons.download),
              label: Text(busy ? 'Saving import request…' : 'Import recipe'),
            ),
            const SizedBox(height: 16),
            const Text(
              'An offline import waits for synchronization. If the server response is lost, you will be asked to reconcile the result rather than importing a duplicate.',
            ),
          ],
        ),
      ),
    ),
  );
}
