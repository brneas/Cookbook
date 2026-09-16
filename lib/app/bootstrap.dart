import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/runtime_diagnostics.dart';
import '../core/theme/theme_providers.dart';
import '../features/recipes/presentation/library_providers.dart';
import '../features/recipes/data/library_repository.dart';
import 'providers.dart';

enum BootstrapPhase { authenticated, unauthenticated }

class BootstrapResult {
  const BootstrapResult(this.phase, {this.needsCredentials = false});
  final BootstrapPhase phase;
  final bool needsCredentials;
}

/// AsyncLoading is the initializing state. No network dependency is allowed here.
final bootstrapProvider = FutureProvider<BootstrapResult>((ref) async {
  final account = await ref.watch(accountProvider.future);
  RuntimeDiagnostics.mark('account restored');
  await Future.wait([
    ref
        .read(serverThemeProvider.future)
        .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ref
        .read(appearanceProvider.future)
        .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ref
        .read(libraryPreferencesProvider.future)
        .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
  ]);
  RuntimeDiagnostics.mark('theme restored');
  if (account == null) {
    return const BootstrapResult(BootstrapPhase.unauthenticated);
  }
  var needsCredentials = false;
  try {
    final secret = await ref.read(credentialStoreProvider).read(account.id);
    needsCredentials = secret == null || secret.isEmpty;
  } catch (_) {
    needsCredentials = true;
  }
  return BootstrapResult(
    BootstrapPhase.authenticated,
    needsCredentials: needsCredentials,
  );
});

class StartupSurface extends ConsumerWidget {
  const StartupSurface({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.menu_book_outlined, size: 48),
          const SizedBox(height: 16),
          const Text('Cookbook'),
          if (ref.watch(bootstrapProvider).hasError) ...[
            const Text('Could not open the local library.'),
            TextButton(
              onPressed: () {
                ref.invalidate(accountProvider);
                ref.invalidate(bootstrapProvider);
              },
              child: const Text('Retry'),
            ),
          ] else
            const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
        ],
      ),
    ),
  );
}

/// One lifecycle observer for the application, independent of routes.
class SyncRuntime extends ConsumerStatefulWidget {
  const SyncRuntime({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<SyncRuntime> createState() => _SyncRuntimeState();
}

class _SyncRuntimeState extends ConsumerState<SyncRuntime>
    with WidgetsBindingObserver {
  String? _startedAccount;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _startedAccount != null) {
      unawaited(ref.read(syncProvider.notifier).automatic('resume'));
    }
  }

  Future<void> _startAfterLocal() async {
    try {
      await ref.read(
        libraryPageProvider((filter: const LibraryFilter(), offset: 0)).future,
      );
    } catch (_) {
      /* Local error remains separate from connection status. */
    }
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(syncProvider.notifier).automatic('launch'));
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(bootstrapProvider).asData?.value;
    final id = ref.watch(accountProvider).asData?.value?.id;
    if (ready?.phase == BootstrapPhase.authenticated && id != _startedAccount) {
      _startedAccount = id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_startAfterLocal());
        }
      });
    } else if (ready?.phase == BootstrapPhase.unauthenticated) {
      _startedAccount = null;
    }
    return widget.child;
  }
}
