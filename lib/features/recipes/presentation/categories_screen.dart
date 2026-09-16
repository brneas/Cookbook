import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/errors/app_failure.dart';
import '../data/library_repository.dart';
import 'library_providers.dart';
import 'filter_pickers.dart';
import '../../settings/presentation/server_settings.dart';

class CategoriesScreen extends ConsumerStatefulWidget {
  const CategoriesScreen({super.key});
  @override
  ConsumerState<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends ConsumerState<CategoriesScreen> {
  String search = '';
  void open(String? category) => context.push(
    Uri(
      path: '/library',
      queryParameters: category == null ? null : {'category': category},
    ).toString(),
  );
  @override
  Widget build(BuildContext context) => Column(
    children: [
      PickerSearch(
        label: 'Search categories',
        onSearch: (s) => setState(() => search = s),
      ),
      Expanded(
        child: ref
            .watch(categoryFacetsProvider)
            .when(
              skipLoadingOnReload: true,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text(safeFailure(e).message)),
              data: (facets) {
                final all = Facet(
                  'All recipes',
                  facets.fold<int>(0, (n, c) => n + c.count),
                );
                final items = [all, ...facets]
                    .where(
                      (f) => (identical(f, all) ? f.name : f.categoryLabel)
                          .toLowerCase()
                          .contains(search.toLowerCase()),
                    )
                    .toList();
                return LayoutBuilder(
                  builder: (context, box) {
                    Widget item(int i) {
                      final f = items[i], isAll = identical(items[i], all);
                      final title = isAll ? f.name : f.categoryLabel;
                      return Semantics(
                        container: true,
                        child: Material(
                          color: Colors.transparent,
                          child: ListTile(
                            leading: Icon(
                              isAll
                                  ? Icons.menu_book_outlined
                                  : Icons.folder_outlined,
                            ),
                            title: Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text('${f.count} recipes'),
                            onTap: () => open(isAll ? null : f.name),
                            trailing: !isAll && f.name.isNotEmpty
                                ? PopupMenuButton<String>(
                                    tooltip: 'Category actions for $title',
                                    onSelected: (_) => renameCategoryDialog(
                                      context,
                                      ref,
                                      f.name,
                                    ),
                                    itemBuilder: (_) => [
                                      const PopupMenuItem(
                                        value: 'rename',
                                        child: Text('Rename'),
                                      ),
                                    ],
                                  )
                                : const Icon(Icons.chevron_right),
                          ),
                        ),
                      );
                    }

                    if (facets.isEmpty && search.isEmpty) {
                      return ListView(
                        children: [
                          item(0),
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'No categories yet. Add a category when creating or editing a recipe.',
                            ),
                          ),
                        ],
                      );
                    }
                    if (items.isEmpty) {
                      return const Center(
                        child: Text('No matching categories.'),
                      );
                    }
                    return Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: items.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) => item(i),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
      ),
    ],
  );
}
