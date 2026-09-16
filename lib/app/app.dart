import '../core/theme/theme_providers.dart';
import '../core/theme/server_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/theme/app_theme.dart';
import '../features/account/presentation/connect_screen.dart';
import '../features/recipes/presentation/recipe_screen.dart';
import 'shell.dart';
import 'bootstrap.dart';
import '../features/cooking/presentation/cooking_screen.dart';
import '../features/cooking/presentation/cooking_runtime.dart';
import '../features/cooking/presentation/timers_panel.dart';
import '../features/editor/presentation/editor_screen.dart';
import '../features/import/presentation/import_screen.dart';
import '../features/sync/presentation/conflict_screen.dart';
import '../features/sync/presentation/operations_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier(0);
  ref.listen(bootstrapProvider, (_, _) => refresh.value++);
  final router = GoRouter(
    initialLocation: '/bootstrap',
    refreshListenable: refresh,
    redirect: (_, state) {
      final restored = ref.read(bootstrapProvider).asData?.value;
      if (restored == null) {
        return state.matchedLocation == '/bootstrap' ? null : '/bootstrap';
      }
      final loggedIn = restored.phase == BootstrapPhase.authenticated;
      if (state.matchedLocation == '/bootstrap') {
        return loggedIn ? '/library' : '/connect';
      }
      final connecting = state.matchedLocation == '/connect';
      if (!loggedIn && !connecting) return '/connect';
      if (loggedIn &&
          connecting &&
          state.uri.queryParameters['reauth'] != 'true') {
        return '/library';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/bootstrap', builder: (_, _) => const StartupSurface()),
      GoRoute(path: '/connect', builder: (_, _) => const ConnectScreen()),
      GoRoute(
        path: '/library',
        builder: (_, state) => AppShell(
          category: state.uri.queryParameters['category'],
          keyword: state.uri.queryParameters['keyword'],
        ),
      ),
      GoRoute(
        path: '/cooking',
        builder: (_, _) => const AppShell(initialIndex: 2),
      ),
      GoRoute(
        path: '/cook/:session',
        builder: (_, state) => CookingScreen(state.pathParameters['session']!),
      ),
      GoRoute(
        path: '/timers',
        builder: (_, _) => Scaffold(
          appBar: AppBar(title: const Text('Cooking timers')),
          body: const TimersPanel(),
        ),
      ),
      GoRoute(path: '/editor/new', builder: (_, _) => const EditorScreen()),
      GoRoute(
        path: '/editor/:id',
        builder: (_, state) => EditorScreen(id: state.pathParameters['id']!),
      ),
      GoRoute(path: '/import', builder: (_, _) => const ImportScreen()),
      GoRoute(
        path: '/conflict/:id',
        builder: (_, state) => ConflictScreen(state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/sync-review',
        builder: (_, _) => const OperationsScreen(),
      ),
      GoRoute(
        path: '/recipe/:id',
        builder: (_, state) => RecipeScreen(state.pathParameters['id']!),
      ),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});

class CookbookApp extends ConsumerWidget {
  const CookbookApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    title: 'Cookbook',
    debugShowCheckedModeBanner: false,
    builder: (context, child) => SyncRuntime(
      child: CookingRuntime(child: child ?? const SizedBox.shrink()),
    ),
    theme: cookbookTheme(
      Brightness.light,
      server:
          ref.watch(serverThemeProvider).asData?.value ?? const ServerTheme(),
    ),
    darkTheme: cookbookTheme(
      Brightness.dark,
      server:
          ref.watch(serverThemeProvider).asData?.value ?? const ServerTheme(),
    ),
    themeMode: ref.watch(appearanceProvider).asData?.value ?? ThemeMode.system,
    routerConfig: ref.watch(routerProvider),
  );
}
