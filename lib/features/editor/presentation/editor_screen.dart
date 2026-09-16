import '../../../core/theme/layout.dart';
import '../../recipes/data/library_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/errors/app_failure.dart';
import '../../recipes/domain/recipe.dart';
import '../../sync/presentation/sync_providers.dart';
import '../domain/recipe_draft.dart';
import 'line_editor.dart';
import 'linked_text_field.dart';
import '../../files/presentation/file_picker.dart';
import '../../recipes/presentation/filter_pickers.dart';

class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({super.key, this.id});
  final String? id;
  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  late final Future<Map<String, Object?>?> initial;
  @override
  void initState() {
    super.initState();
    if (widget.id != null) {
      // Keep the asynchronous initial read alive for this screen. Subsequent
      // refreshes must not replace the captured form or its unsaved draft.
      ref.listenManual(recipeRecordProvider(widget.id!), (_, _) {});
    }
    initial = widget.id == null
        ? Future.value(null)
        : ref.read(recipeRecordProvider(widget.id!).future);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.id == null) return const RecipeEditor();
    // Capture once: synchronization must not replace a form with unsaved changes.
    return FutureBuilder<Map<String, Object?>?>(
      future: initial,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(child: Text(safeFailure(snapshot.error!).message)),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final row = snapshot.data;
        return row == null
            ? const Scaffold(
                body: Center(child: Text('Recipe is not available locally.')),
              )
            : RecipeEditor(recipe: recipeFromRow(row));
      },
    );
  }
}

class RecipeEditor extends ConsumerStatefulWidget {
  const RecipeEditor({super.key, this.recipe});
  final Recipe? recipe;
  @override
  ConsumerState<RecipeEditor> createState() => _RecipeEditorState();
}

class _RecipeEditorState extends ConsumerState<RecipeEditor> {
  late final RecipeDraft draft;
  late final InstructionTree instructions;
  final form = GlobalKey<FormState>();
  final keyword = TextEditingController();
  late final TextEditingController categoryController;
  bool saving = false, saved = false, allowExit = false;
  String? error;
  int revision = 0;
  @override
  void initState() {
    super.initState();
    draft = widget.recipe == null
        ? RecipeDraft.empty()
        : RecipeDraft(widget.recipe!);
    instructions = InstructionTree(draft.values['recipeInstructions']);
    categoryController = TextEditingController(
      text: draft.values['recipeCategory'] as String? ?? '',
    );
  }

  @override
  void dispose() {
    keyword.dispose();
    categoryController.dispose();
    super.dispose();
  }

  void change(VoidCallback update) {
    setState(() {
      update();
    });
  }

  Future<void> leave() async {
    if (saving) return;
    final discard =
        !draft.changed ||
        await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Discard unsaved changes?'),
                content: const Text(
                  'Your changes have not been saved locally.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Keep editing'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Discard changes'),
                  ),
                ],
              ),
            ) ==
            true;
    if (discard && mounted) {
      setState(() => allowExit = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/library');
          }
        }
      });
    }
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final store = await ref.read(mutationStoreProvider.future);
      final id = await store.save(
        draft.build(),
        create: widget.recipe == null,
        expectedRecipe: widget.recipe,
      );
      ref.read(syncProvider.notifier).localChanged();
      if (!mounted) return;
      setState(() {
        saved = true;
        allowExit = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved locally · waiting for sync')),
      );
      // Network work runs independently; the local save never waits on connectivity.
      ref.read(syncProvider.notifier).request('local edit', mutation: true);
      context.go('/recipe/${Uri.encodeComponent(id)}');
    } catch (e) {
      if (mounted) setState(() => error = safeFailure(e).message);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget field(
    String key,
    String label, {
    int lines = 1,
    TextInputType? keyboardType,
    bool required = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      initialValue: '${draft.values[key] ?? ''}',
      decoration: InputDecoration(labelText: label),
      minLines: 1,
      maxLines: lines,
      keyboardType: keyboardType,
      validator: required
          ? (s) => s == null || s.trim().isEmpty
                ? 'A recipe name is required'
                : null
          : null,
      onChanged: (s) => change(() => draft.set(key, s)),
    ),
  );
  Widget group(String name, List<Widget> children, {bool expanded = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: ExpansionTile(
          title: Text(name),
          initiallyExpanded: expanded,
          maintainState: true,
          childrenPadding: const EdgeInsets.symmetric(vertical: 12),
          children: children,
        ),
      );
  Widget lines(String key, String title) {
    final raw = draft.values[key];
    if (raw != null && (raw is! List || raw.any((v) => v is! String))) {
      return const Text('This imported structure is preserved read-only.');
    }
    final values = (raw as List?)?.cast<String>() ?? <String>[];
    void edit(VoidCallback action) {
      change(() {
        action();
        draft.set(key, values);
        revision++;
      });
    }

    return LineEditor(
      label: title,
      lines: values,
      revision: revision,
      onEdit: (i, text) => change(() {
        values[i] = text;
        draft.set(key, values);
      }),
      onAdd: () => edit(() => values.add('')),
      onRemove: (i) => edit(() => values.removeAt(i)),
      onMove: (from, to) =>
          edit(() => values.insert(to, values.removeAt(from))),
    );
  }

  List<Widget> structuredInstructions() {
    final groups = instructions.reorderGroups;
    final grouped = groups
        .expand((g) => g.leaves)
        .map((l) => l.path.join('/'))
        .toSet();
    final result = <Widget>[];
    for (final leaf in instructions.leaves) {
      final group = groups
          .where((g) => g.leaves.first.path.join('/') == leaf.path.join('/'))
          .firstOrNull;
      if (group != null) {
        if (leaf.sections.isNotEmpty) {
          result.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(leaf.sections.join(' › ')),
            ),
          );
        }
        result.add(
          LineEditor(
            key: ValueKey(group.path.join('/')),
            label: 'Step',
            lines: group.leaves.map((l) => l.text).toList(),
            revision: revision,
            allowAddRemove: false,
            onEdit: (i, text) => change(() {
              instructions.edit(group.leaves[i], text);
              draft.set('recipeInstructions', instructions.value);
            }),
            onMove: (from, to) => change(() {
              instructions.moveWithin(group.path, from, to);
              draft.set('recipeInstructions', instructions.value);
              revision++;
            }),
            onAdd: () {},
            onRemove: (_) {},
          ),
        );
      } else if (!grouped.contains(leaf.path.join('/'))) {
        result.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: leaf.editable
                ? LinkedTextField(
                    value: leaf.text,
                    maxLines: 6,
                    label: 'Instruction text',
                    onChanged: (text) => change(() {
                      instructions.edit(leaf, text);
                      draft.set('recipeInstructions', instructions.value);
                    }),
                  )
                : SelectableText('Read-only instruction: ${leaf.text}'),
          ),
        );
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final known = ref.watch(taxonomyProvider).asData?.value ?? {};
    final tags = draft.build().keywords;
    final author = draft.values['author'];
    final image = draft.values['image'];
    return PopScope(
      canPop: !saving && (allowExit || saved || !draft.changed),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) leave();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Back',
            onPressed: leave,
            icon: const Icon(Icons.arrow_back),
          ),
          title: Text(widget.recipe == null ? 'Add Recipe' : 'Edit Recipe'),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              onPressed: saving ? null : save,
              icon: const Icon(Icons.save_outlined),
              label: Text(saving ? 'Saving…' : 'Save recipe'),
            ),
          ),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppLayout.editorWidth),
            child: Form(
              key: form,
              child: ListView(
                padding: AppLayout.compactInsets,
                children: [
                  if (error != null)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  field('name', 'Recipe name', required: true, lines: 2),
                  group('Basics', [
                    LinkedTextField(
                      value: draft.build().description,
                      label: 'Description',
                      onChanged: (s) =>
                          change(() => draft.set('description', s)),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: categoryController,
                      decoration: const InputDecoration(labelText: 'Category'),
                      onChanged: (s) =>
                          change(() => draft.set('recipeCategory', s)),
                    ),
                    if ((known['categories'] ?? []).isNotEmpty)
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final category in known['categories']!.take(8))
                            ActionChip(
                              label: Text(category),
                              onPressed: () => change(() {
                                categoryController.text = category;
                                draft.set('recipeCategory', category);
                              }),
                            ),
                        ],
                      ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () async {
                        final choice = await pickCategory(
                          context,
                          categoryController.text,
                        );
                        if (choice != null && mounted) {
                          change(() {
                            categoryController.text = choice.name ?? '';
                            draft.set(
                              'recipeCategory',
                              categoryController.text,
                            );
                          });
                        }
                      },
                      child: const Text('Browse all categories'),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final tag in tags)
                          InputChip(
                            label: Text(tag),
                            onDeleted: () => change(
                              () => draft.set(
                                'keywords',
                                (tags..remove(tag)).join(','),
                              ),
                            ),
                          ),
                      ],
                    ),
                    TextButton(
                      onPressed: () async {
                        final result = await pickKeywords(
                          context,
                          LibraryFilter(keywords: tags, anyKeyword: true),
                        );
                        if (result != null && mounted) {
                          change(
                            () => draft.set(
                              'keywords',
                              result.keywords.join(','),
                            ),
                          );
                        }
                      },
                      child: const Text('Browse all keywords'),
                    ),
                    TextField(
                      controller: keyword,
                      decoration: InputDecoration(
                        labelText: 'Add keyword',
                        suffixIcon: IconButton(
                          tooltip: 'Add keyword',
                          icon: const Icon(Icons.add),
                          onPressed: () {
                            final text = keyword.text.trim();
                            if (text.isNotEmpty) {
                              change(
                                () => draft.set(
                                  'keywords',
                                  ({...tags, text}.toList()).join(','),
                                ),
                              );
                            }
                            keyword.clear();
                          },
                        ),
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final tag
                            in (known['keywords'] ?? [])
                                .where((t) => !tags.contains(t))
                                .take(12))
                          ActionChip(
                            label: Text(tag),
                            onPressed: () => change(
                              () => draft.set(
                                'keywords',
                                [...tags, tag].join(','),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (image == null ||
                        image is String ||
                        image is Map && image['url'] is String)
                      TextFormField(
                        key: ValueKey('image-$revision'),
                        initialValue: image is Map
                            ? image['url'] as String
                            : image as String? ?? '',
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'Image URL or Nextcloud path',
                          helperText:
                              'Cookbook downloads or copies the image when saved.',
                          helperMaxLines: 2,
                        ),
                        onChanged: (s) => change(() => draft.imageUrl(s)),
                      )
                    else
                      const Text(
                        'The imported image structure is preserved read-only.',
                      ),
                    if (image == null ||
                        image is String ||
                        image is Map && image['url'] is String)
                      OutlinedButton.icon(
                        onPressed: () async {
                          final path = await pickNextcloudImage(context);
                          if (path != null && mounted) {
                            change(() {
                              draft.imageUrl(path);
                              revision++;
                            });
                          }
                        },
                        icon: const Icon(Icons.folder_open_outlined),
                        label: const Text('Choose Nextcloud image'),
                      ),
                  ], expanded: true),
                  group('Timing & servings', [
                    TextFormField(
                      initialValue: draft.build().yieldText,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Servings / yield',
                      ),
                      onChanged: (s) => change(
                        () => draft.set(
                          'recipeYield',
                          s.trim().isEmpty ? null : int.tryParse(s) ?? s,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    for (final entry in {
                      'prepTime': 'Preparation',
                      'cookTime': 'Cooking',
                      'totalTime': 'Total',
                    }.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: TextFormField(
                          initialValue: editorDuration(
                            draft.build().duration(entry.key),
                          ),
                          keyboardType: TextInputType.datetime,
                          decoration: InputDecoration(
                            labelText: '${entry.value} time (minutes)',
                            hintText: 'Minutes or H:MM:SS',
                            helperText:
                                draft.build().duration(entry.key) == null &&
                                    draft.values[entry.key] != null
                                ? 'Original value retained until edited'
                                : null,
                          ),
                          validator: (s) =>
                              s != null &&
                                  s.isNotEmpty &&
                                  parseEditorDuration(s) == null
                              ? 'Enter minutes or H:MM:SS'
                              : null,
                          onChanged: (s) => change(
                            () => draft.set(
                              entry.key,
                              s.isEmpty
                                  ? null
                                  : 'PT${parseEditorDuration(s)?.inSeconds ?? 0}S',
                            ),
                          ),
                        ),
                      ),
                  ]),
                  group('Ingredients', [
                    lines('recipeIngredient', 'Ingredient'),
                  ]),
                  group('Equipment', [lines('tool', 'Tool')]),
                  group('Instructions', [
                    if (instructions.flat)
                      LineEditor(
                        label: 'Step',
                        lines: instructions.leaves.map((l) => l.text).toList(),
                        revision: revision,
                        onEdit: (i, s) => change(() {
                          instructions.edit(instructions.leaves[i], s);
                          draft.set('recipeInstructions', instructions.value);
                        }),
                        onAdd: () => change(() {
                          instructions.add();
                          draft.set('recipeInstructions', instructions.value);
                          revision++;
                        }),
                        onRemove: (i) => change(() {
                          instructions.remove(i);
                          draft.set('recipeInstructions', instructions.value);
                          revision++;
                        }),
                        onMove: (a, b) => change(() {
                          instructions.move(a, b);
                          draft.set('recipeInstructions', instructions.value);
                          revision++;
                        }),
                      )
                    else ...[
                      const Text(
                        'Drag or use Move up/down within each editable section. Section boundaries and unsupported content are preserved.',
                      ),
                      ...structuredInstructions(),
                    ],
                  ]),
                  group('Nutrition', [
                    if (draft.values['nutrition'] == null ||
                        draft.values['nutrition'] is Map ||
                        draft.values['nutrition'] is List &&
                            (draft.values['nutrition'] as List).isEmpty)
                      for (final key in [
                        'calories',
                        'servingSize',
                        'proteinContent',
                        'fatContent',
                        'saturatedFatContent',
                        'unsaturatedFatContent',
                        'transFatContent',
                        'carbohydrateContent',
                        'sugarContent',
                        'fiberContent',
                        'sodiumContent',
                        'cholesterolContent',
                      ])
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: TextFormField(
                            initialValue: draft.values['nutrition'] is Map
                                ? '${(draft.values['nutrition'] as Map)[key] ?? ''}'
                                : '',
                            decoration: InputDecoration(labelText: key),
                            onChanged: (s) =>
                                change(() => draft.nested('nutrition', key, s)),
                          ),
                        )
                    else
                      const Text(
                        'Imported nutrition data is preserved read-only.',
                      ),
                  ]),
                  group('Source & metadata', [
                    field('url', 'Source URL', keyboardType: TextInputType.url),
                    if (author == null || author is String || author is Map)
                      TextFormField(
                        initialValue: author is Map
                            ? '${author['name'] ?? ''}'
                            : author as String? ?? '',
                        decoration: const InputDecoration(labelText: 'Author'),
                        onChanged: (s) => change(() => draft.authorName(s)),
                      )
                    else
                      const Text(
                        'Imported author list is preserved read-only.',
                      ),
                    const SizedBox(height: 16),
                    field('datePublished', 'Publication date'),
                    field('recipeCuisine', 'Cuisine'),
                    field('cookingMethod', 'Cooking method'),
                    const Text(
                      'Additional metadata and unknown fields are preserved when you save.',
                    ),
                  ]),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
