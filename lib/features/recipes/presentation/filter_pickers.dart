import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/errors/app_failure.dart';
import '../data/library_repository.dart';
import 'library_providers.dart';

class CategoryChoice {
  const CategoryChoice(this.name);
  final String? name;
}

Future<CategoryChoice?> pickCategory(BuildContext context, String? selected) =>
    showModalBottomSheet<CategoryChoice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: .92,
        child: CategoryPicker(selected: selected),
      ),
    );
Future<LibraryFilter?> pickKeywords(
  BuildContext context,
  LibraryFilter filter,
) => showModalBottomSheet<LibraryFilter>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => FractionallySizedBox(
    heightFactor: .92,
    child: KeywordPicker(filter: filter),
  ),
);

class PickerSearch extends StatefulWidget {
  const PickerSearch({super.key, required this.label, required this.onSearch});
  final String label;
  final ValueChanged<String> onSearch;
  @override
  State<PickerSearch> createState() => _PickerSearchState();
}

class _PickerSearchState extends State<PickerSearch> {
  Timer? timer;
  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: TextField(
      decoration: InputDecoration(
        labelText: widget.label,
        prefixIcon: const Icon(Icons.search),
      ),
      onChanged: (s) {
        timer?.cancel();
        timer = Timer(
          const Duration(milliseconds: 200),
          () => widget.onSearch(s),
        );
      },
    ),
  );
}

class CategoryPicker extends ConsumerStatefulWidget {
  const CategoryPicker({super.key, this.selected});
  final String? selected;
  @override
  ConsumerState<CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends ConsumerState<CategoryPicker> {
  String search = '';
  @override
  Widget build(BuildContext context) => Column(
    children: [
      const SizedBox(height: 16),
      Text('Category', style: Theme.of(context).textTheme.titleLarge),
      PickerSearch(
        label: 'Search categories',
        onSearch: (s) => setState(() => search = s),
      ),
      Expanded(
        child: ref
            .watch(categoryFacetsProvider)
            .when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text(safeFailure(e).message)),
              data: (facets) {
                final choices = [
                  Facet(
                    'All recipes',
                    facets.fold<int>(0, (n, f) => n + f.count),
                  ),
                  ...facets,
                ];
                final visible = choices
                    .where(
                      (f) =>
                          (identical(f, choices.first)
                                  ? f.name
                                  : f.categoryLabel)
                              .toLowerCase()
                              .contains(search.toLowerCase()),
                    )
                    .toList();
                return ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, i) {
                    final item = visible[i];
                    final all = identical(item, choices.first);
                    final value = all ? null : item.name;
                    final title = all ? item.name : item.categoryLabel;
                    return Semantics(
                      label: '$title, ${item.count} recipes',
                      selected: widget.selected == value,
                      child: ListTile(
                        leading: Icon(
                          widget.selected == value
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                        ),
                        title: Text(title),
                        trailing: Text('${item.count}'),
                        onTap: () =>
                            Navigator.pop(context, CategoryChoice(value)),
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

class KeywordPicker extends ConsumerStatefulWidget {
  const KeywordPicker({super.key, required this.filter});
  final LibraryFilter filter;
  @override
  ConsumerState<KeywordPicker> createState() => _KeywordPickerState();
}

class _KeywordPickerState extends ConsumerState<KeywordPicker> {
  late LibraryFilter filter = widget.filter;
  String search = '';
  bool byCount = false;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      const SizedBox(height: 16),
      Text('Keywords', style: Theme.of(context).textTheme.titleLarge),
      PickerSearch(
        label: 'Search keywords',
        onSearch: (s) => setState(() => search = s),
      ),
      Wrap(
        spacing: 12,
        children: [
          ChoiceChip(
            label: const Text('Match all'),
            selected: !filter.anyKeyword,
            onSelected: (_) =>
                setState(() => filter = filter.copy(anyKeyword: false)),
          ),
          ChoiceChip(
            label: const Text('Match any'),
            selected: filter.anyKeyword,
            onSelected: (_) =>
                setState(() => filter = filter.copy(anyKeyword: true)),
          ),
          IconButton(
            tooltip: byCount
                ? 'Sort keywords alphabetically'
                : 'Sort keywords by count',
            onPressed: () => setState(() => byCount = !byCount),
            icon: const Icon(Icons.sort),
          ),
        ],
      ),
      Expanded(
        child: ref
            .watch(keywordFacetsProvider(filter))
            .when(
              skipLoadingOnReload: true,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text(safeFailure(e).message)),
              data: (facets) {
                final names = facets.map((f) => f.name).toSet();
                final items =
                    [
                          ...facets,
                          for (final name in filter.keywords.where(
                            (n) => !names.contains(n),
                          ))
                            Facet(name, 0, available: false),
                        ]
                        .where(
                          (f) => f.name.toLowerCase().contains(
                            search.toLowerCase(),
                          ),
                        )
                        .toList();
                if (byCount) items.sort((a, b) => b.count.compareTo(a.count));
                if (items.isEmpty) {
                  return const Center(
                    child: Text('No keywords in this category.'),
                  );
                }
                return ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final f = items[i],
                        selected = filter.keywords.contains(items[i].name);
                    return CheckboxListTile(
                      title: Text(f.name),
                      subtitle: !f.available && !selected
                          ? const Text('Unavailable with current filters')
                          : null,
                      secondary: Text('${f.count}'),
                      value: selected,
                      onChanged: !selected && !f.available && !filter.anyKeyword
                          ? null
                          : (checked) => setState(
                              () => filter = filter.copy(
                                keywords: checked == true
                                    ? [...filter.keywords, f.name]
                                    : filter.keywords
                                          .where((s) => s != f.name)
                                          .toList(),
                              ),
                            ),
                    );
                  },
                );
              },
            ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              TextButton(
                onPressed: () =>
                    setState(() => filter = filter.copy(keywords: [])),
                child: const Text('Clear'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.pop(context, filter),
                child: const Text('Apply'),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}
