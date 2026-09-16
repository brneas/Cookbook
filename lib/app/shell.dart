import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../features/recipes/presentation/library_screen.dart';
import '../features/recipes/presentation/categories_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import 'providers.dart';
import 'package:go_router/go_router.dart';
import '../features/cooking/presentation/cooking_hub.dart';
import '../features/cooking/presentation/cooking_providers.dart';
import '../features/cooking/presentation/timers_panel.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({
    super.key,
    this.initialIndex = 0,
    this.category,
    this.keyword,
  });
  final int initialIndex;
  final String? category, keyword;
  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _selected = 0;
  static const labels = ['Recipes', 'Categories', 'Cooking', 'Settings'];
  static const icons = [
    Icons.menu_book_outlined,
    Icons.category_outlined,
    Icons.restaurant_outlined,
    Icons.settings_outlined,
  ];
  @override
  void initState() {
    super.initState();
    _selected = widget.initialIndex;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 840;
      final content = switch (_selected) {
        0 => LibraryScreen(
          initialCategory: widget.category,
          initialKeyword: widget.keyword,
        ),
        1 => const CategoriesScreen(),
        2 => const CookingHub(),
        _ => const SettingsScreen(),
      };
      return Scaffold(
        appBar: AppBar(
          leading: context.canPop()
              ? BackButton(onPressed: () => context.pop())
              : null,
          title: Text(labels[_selected]),
          actions: [
            IconButton(
              tooltip: 'Cooking timers',
              onPressed: () => showTimers(context),
              icon: Badge(
                isLabelVisible:
                    (ref
                            .watch(cookingProvider)
                            .asData
                            ?.value
                            .visibleTimers
                            .length ??
                        0) >
                    0,
                label: Text(
                  '${ref.watch(cookingProvider).asData?.value.visibleTimers.length ?? 0}',
                ),
                child: const Icon(Icons.timer_outlined),
              ),
            ),
            if (_selected < 2)
              PopupMenuButton<String>(
                tooltip: 'Add or import recipe',
                onSelected: (value) => context.push(value),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: '/editor/new',
                    child: Text('Add Recipe'),
                  ),
                  PopupMenuItem(
                    value: '/import',
                    child: Text('Import from URL'),
                  ),
                ],
                icon: const Icon(Icons.add),
              ),
            if (_selected < 2)
              IconButton(
                tooltip: 'Refresh recipes',
                onPressed: ref.watch(syncProvider).running
                    ? null
                    : () => ref
                          .read(syncProvider.notifier)
                          .request('toolbar refresh'),
                icon: const Icon(Icons.sync),
              ),
          ],
        ),
        body: wide
            ? Row(
                children: [
                  NavigationRail(
                    selectedIndex: _selected,
                    onDestinationSelected: (i) => setState(() => _selected = i),
                    labelType: NavigationRailLabelType.all,
                    destinations: [
                      for (var i = 0; i < labels.length; i++)
                        NavigationRailDestination(
                          icon: Icon(icons[i]),
                          selectedIcon: Icon(
                            [
                              Icons.menu_book,
                              Icons.category,
                              Icons.restaurant,
                              Icons.settings,
                            ][i],
                          ),
                          label: Text(labels[i]),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: content),
                ],
              )
            : content,
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: _selected,
                onDestinationSelected: (i) => setState(() => _selected = i),
                destinations: [
                  for (var i = 0; i < labels.length; i++)
                    NavigationDestination(
                      icon: Icon(icons[i]),
                      selectedIcon: Icon(
                        [
                          Icons.menu_book,
                          Icons.category,
                          Icons.restaurant,
                          Icons.settings,
                        ][i],
                      ),
                      label: labels[i],
                    ),
                ],
              ),
      );
    },
  );
}
