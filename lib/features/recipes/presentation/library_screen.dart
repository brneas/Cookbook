import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../app/bootstrap.dart';
import '../../../core/runtime_diagnostics.dart';
import '../../../core/errors/app_failure.dart';
import '../data/library_repository.dart';
import 'library_providers.dart';
import 'filter_pickers.dart';
import 'recipe_thumbnail.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key, this.initialCategory, this.initialKeyword});
  final String? initialCategory, initialKeyword;
  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  late LibraryFilter filter = LibraryFilter(
    category: widget.initialCategory,
    keywords: widget.initialKeyword == null ? [] : [widget.initialKeyword!],
  );
  final search = TextEditingController();
  Timer? debounce;
  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LibraryScreen old) {
    super.didUpdateWidget(old);
    if (old.initialCategory != widget.initialCategory ||
        old.initialKeyword != widget.initialKeyword) {
      filter = LibraryFilter(
        category: widget.initialCategory,
        keywords: widget.initialKeyword == null ? [] : [widget.initialKeyword!],
      );
    }
  }

  void clear() {
    search.clear();
    setState(() => filter = LibraryFilter(sort: filter.sort));
  }

  Future<void> category() async {
    final value = await pickCategory(context, filter.category);
    if (value != null && mounted) {
      setState(
        () => filter = filter.copy(
          category: value.name,
          clearCategory: value.name == null,
          keywords: [],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(syncProvider);
    final prefs =
        ref.watch(libraryPreferencesProvider).asData?.value ??
        const LibraryPreferences();
    final effective = filter.copy(sort: prefs.sort);
    final page = ref.watch(libraryPageProvider((filter: effective, offset: 0)));
    final needsCredentials =
        ref.watch(bootstrapProvider).asData?.value.needsCredentials == true ||
        sync.error?.kind == FailureKind.authentication;
    if (page.asData?.value.items.isNotEmpty == true) {
      RuntimeDiagnostics.mark('first local recipe list available');
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => RuntimeDiagnostics.mark('first frame with recipe content'),
      );
    }
    return Column(
      children: [
        if (needsCredentials)
          MaterialBanner(
            content: const Text(
              'Your app credentials need attention. Downloaded recipes remain available.',
            ),
            actions: [
              TextButton(
                onPressed: () => context.push('/connect?reauth=true'),
                child: const Text('Reauthenticate'),
              ),
            ],
          ),
        if (sync.running) const LinearProgressIndicator(),
        if (sync.error != null && !needsCredentials)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${sync.error!.message} Downloaded recipes remain available.',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () => ref
                      .read(syncProvider.notifier)
                      .request('library refresh'),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: TextField(
            controller: search,
            decoration: InputDecoration(
              suffixIcon: search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        debounce?.cancel();
                        search.clear();
                        setState(() => filter = filter.copy(search: ''));
                      },
                    ),
              labelText: 'Search your recipes',
              prefixIcon: const Icon(Icons.search),
            ),
            onChanged: (s) {
              debounce?.cancel();
              debounce = Timer(
                const Duration(milliseconds: 200),
                () => setState(() => filter = filter.copy(search: s)),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                onPressed: category,
                icon: const Icon(Icons.expand_more, size: 18),
                iconAlignment: IconAlignment.end,
                label: const Text('Category'),
              ),
              TextButton.icon(
                icon: const Icon(Icons.expand_more, size: 18),
                iconAlignment: IconAlignment.end,
                onPressed: () async {
                  final next = await pickKeywords(context, filter);
                  if (next != null && mounted) setState(() => filter = next);
                },
                label: const Text('Keywords'),
              ),
              PopupMenuButton<RecipeSort>(
                tooltip: 'Sort recipes',
                initialValue: prefs.sort,
                onSelected: (s) =>
                    ref.read(libraryPreferencesProvider.notifier).set(sort: s),
                itemBuilder: (_) => [
                  for (final s in RecipeSort.values)
                    CheckedPopupMenuItem(
                      value: s,
                      checked: s == prefs.sort,
                      child: Text(s.label),
                    ),
                ],
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [Text('Sort'), Icon(Icons.expand_more, size: 18)],
                  ),
                ),
              ),
              IconButton(
                tooltip: prefs.grid
                    ? 'Switch to List view'
                    : 'Switch to Grid view',
                isSelected: prefs.grid,
                onPressed: () => ref
                    .read(libraryPreferencesProvider.notifier)
                    .set(grid: !prefs.grid),
                icon: Icon(
                  prefs.grid
                      ? Icons.view_list_outlined
                      : Icons.grid_view_outlined,
                ),
              ),
            ],
          ),
        ),
        if (filter.category != null || filter.keywords.isNotEmpty)
          SizedBox(
            height: 52 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                if (filter.category != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InputChip(
                      label: Text(
                        'Category: ${filter.category!.isEmpty ? 'Uncategorized' : filter.category}',
                      ),
                      onDeleted: () => setState(
                        () => filter = filter.copy(
                          clearCategory: true,
                          keywords: [],
                        ),
                      ),
                    ),
                  ),
                for (final tag in filter.keywords)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InputChip(
                      label: Text(tag),
                      onDeleted: () => setState(
                        () => filter = filter.copy(
                          keywords: filter.keywords
                              .where((s) => s != tag)
                              .toList(),
                        ),
                      ),
                    ),
                  ),
                TextButton(
                  onPressed: clear,
                  child: const Text('Clear filters'),
                ),
              ],
            ),
          ),
        Expanded(
          child: page.when(
            skipLoadingOnReload: true,
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text(safeFailure(e).message)),
            data: (first) => RefreshIndicator(
              onRefresh: () =>
                  ref.read(syncProvider.notifier).request('library refresh'),
              child: LayoutBuilder(
                builder: (context, box) {
                  final scale = MediaQuery.textScalerOf(context).scale(1);
                  final columns =
                      ((box.maxWidth - 20) / (172 * scale.clamp(1, 1.7)))
                          .floor()
                          .clamp(1, 6);
                  final imageHeight =
                      ((box.maxWidth - 24 - (columns - 1) * 8) / columns) * .75;
                  return CustomScrollView(
                    key: ValueKey((effective, prefs.grid)),
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                          child: Text(
                            '${first.total} recipes · ${prefs.sort.label}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                      if (first.total == 0)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.menu_book_outlined,
                                    size: 48,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    filter.active
                                        ? 'No recipes match these filters.'
                                        : sync.running
                                        ? 'Loading your Cookbook…'
                                        : 'No recipes yet',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleLarge,
                                  ),
                                  const SizedBox(height: 12),
                                  if (filter.active)
                                    TextButton(
                                      onPressed: clear,
                                      child: const Text('Clear filters'),
                                    )
                                  else
                                    const Text(
                                      'Create a recipe or import one from a website.',
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                        sliver: prefs.grid
                            ? SliverGrid.builder(
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: columns,
                                      crossAxisSpacing: 8,
                                      mainAxisSpacing: 8,
                                      mainAxisExtent: imageHeight + 100 * scale,
                                    ),
                                itemCount: first.total,
                                itemBuilder: (context, index) => _PagedRecipe(
                                  index: index,
                                  filter: effective,
                                  grid: true,
                                  imageHeight: imageHeight,
                                ),
                              )
                            : SliverList.builder(
                                itemCount: first.total,
                                itemBuilder: (context, index) => _PagedRecipe(
                                  index: index,
                                  filter: effective,
                                  grid: false,
                                ),
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PagedRecipe extends ConsumerWidget {
  const _PagedRecipe({
    required this.index,
    required this.filter,
    required this.grid,
    this.imageHeight = 140,
  });
  final int index;
  final LibraryFilter filter;
  final bool grid;
  final double imageHeight;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(
      libraryPageProvider((filter: filter, offset: index ~/ 60 * 60)),
    );
    return page.when(
      skipLoadingOnReload: true,
      loading: () => const SizedBox(
        height: 88,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Text(safeFailure(e).message),
      data: (page) {
        if (index % 60 >= page.items.length) return const SizedBox.shrink();
        final item = page.items[index % 60];
        final category = item.category.isEmpty
            ? 'Uncategorized'
            : item.category;
        void open() => context.push('/recipe/${Uri.encodeComponent(item.id)}');
        final semantic = '${item.name}, category $category';
        return Semantics(
          label: semantic,
          button: true,
          excludeSemantics: true,
          onTap: open,
          child: Material(
            color: grid
                ? Theme.of(context).colorScheme.surfaceContainerLow
                : Colors.transparent,
            borderRadius: BorderRadius.circular(grid ? 12 : 0),
            clipBehavior: Clip.antiAlias,
            child: grid
                ? InkWell(
                    onTap: open,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: imageHeight,
                          child: ExcludeSemantics(
                            child: RecipeThumbnail(item.id, radius: 0),
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 4),
                                Flexible(
                                  child: Text(
                                    category,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 8,
                    ),
                    minVerticalPadding: 12,
                    leading: SizedBox(
                      width: 64,
                      height: 64,
                      child: ExcludeSemantics(child: RecipeThumbnail(item.id)),
                    ),
                    title: Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      category,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: open,
                  ),
          ),
        );
      },
    );
  }
}
