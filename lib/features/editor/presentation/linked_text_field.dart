import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../recipes/data/library_repository.dart';
import '../../recipes/presentation/library_providers.dart';
import '../../recipes/presentation/filter_pickers.dart';
import '../../recipes/presentation/recipe_text.dart';

class LinkedTextField extends StatefulWidget {
  const LinkedTextField({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
    this.maxLines = 5,
  });
  final String value, label;
  final ValueChanged<String> onChanged;
  final int maxLines;
  @override
  State<LinkedTextField> createState() => _LinkedTextFieldState();
}

class _LinkedTextFieldState extends State<LinkedTextField> {
  late final controller = TextEditingController(text: widget.value);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LinkedTextField old) {
    super.didUpdateWidget(old);
    if (controller.text != widget.value) controller.text = widget.value;
  }

  Future<void> insert() async {
    final id = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => const FractionallySizedBox(
        heightFactor: .92,
        child: _RecipeSelector(),
      ),
    );
    if (id == null || !mounted) return;
    final selected = controller.selection;
    final start = selected.isValid ? selected.start : controller.text.length;
    final end = selected.isValid ? selected.end : start;
    final token =
        '${start > 0 && !RegExp(r'\s').hasMatch(controller.text[start - 1]) ? ' ' : ''}${recipeReference(id)} ';
    controller.value = TextEditingValue(
      text: controller.text.replaceRange(start, end, token),
      selection: TextSelection.collapsed(offset: start + token.length),
    );
    widget.onChanged(controller.text);
  }

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    minLines: 1,
    maxLines: widget.maxLines,
    onChanged: widget.onChanged,
    decoration: InputDecoration(
      labelText: widget.label,
      suffixIcon: IconButton(
        tooltip: 'Insert recipe link',
        onPressed: insert,
        icon: const Icon(Icons.add_link),
      ),
    ),
  );
}

class _RecipeSelector extends ConsumerStatefulWidget {
  const _RecipeSelector();
  @override
  ConsumerState<_RecipeSelector> createState() => _RecipeSelectorState();
}

class _RecipeSelectorState extends ConsumerState<_RecipeSelector> {
  String search = '';
  @override
  Widget build(BuildContext context) {
    final filter = LibraryFilter(search: search);
    return Column(
      children: [
        const SizedBox(height: 16),
        const Text('Insert a recipe link'),
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Recipes must have synchronized once to have a compatible server link.',
          ),
        ),
        PickerSearch(
          label: 'Find recipe',
          onSearch: (s) => setState(() => search = s),
        ),
        Expanded(
          child: ref
              .watch(libraryPageProvider((filter: filter, offset: 0)))
              .when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, _) =>
                    const Center(child: Text('Recipes could not be loaded.')),
                data: (page) => ListView.builder(
                  itemCount: page.total,
                  itemBuilder: (context, i) => Consumer(
                    builder: (context, ref, _) {
                      final item = ref
                          .watch(
                            libraryPageProvider((
                              filter: filter,
                              offset: i ~/ 60 * 60,
                            )),
                          )
                          .asData
                          ?.value
                          .items
                          .elementAtOrNull(i % 60);
                      if (item == null) return const SizedBox(height: 56);
                      final stable = RegExp(r'^\d+$').hasMatch(item.id);
                      return ListTile(
                        title: Text(item.name),
                        subtitle: stable
                            ? null
                            : const Text('Waiting for first sync'),
                        enabled: stable,
                        onTap: () => Navigator.pop(context, item.id),
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
