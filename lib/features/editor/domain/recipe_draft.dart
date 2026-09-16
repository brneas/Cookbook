import 'dart:convert';
import '../../recipes/domain/recipe.dart';

class RecipeDraft {
  RecipeDraft(Recipe recipe)
    : original = recipe.toJson(),
      values = recipe.toJson();
  factory RecipeDraft.empty() => RecipeDraft(
    Recipe.fromJson({
      '@context': 'https://schema.org',
      '@type': 'Recipe',
      'name': '',
      'description': '',
      'recipeCategory': '',
      'keywords': '',
      'recipeYield': 1,
      'prepTime': null,
      'cookTime': null,
      'totalTime': null,
      'recipeIngredient': <String>[],
      'tool': <String>[],
      'recipeInstructions': <String>[],
      'nutrition': {'@type': 'NutritionInformation'},
      'image': '',
      'url': '',
    }),
  );
  final JsonMap original, values;
  bool get changed => jsonEncode(original) != jsonEncode(values);
  Recipe build() => Recipe.fromJson(values);
  void set(String field, Object? value) {
    values[field] = value;
  }

  void nested(String field, String key, String value) {
    final current = values[field];
    values[field] = {
      if (current is Map) ...current.cast<String, Object?>(),
      key: value,
    };
  }

  void authorName(String name) {
    if (values['author'] is Map) {
      nested('author', 'name', name);
    } else {
      values['author'] = name;
    }
  }

  void imageUrl(String url) {
    if (values['image'] is Map) {
      nested('image', 'url', url);
    } else {
      values['image'] = url;
    }
  }
}

class InstructionLeaf {
  const InstructionLeaf(
    this.path,
    this.text, {
    this.editable = true,
    this.sections = const [],
  });
  final List<Object> path;
  final String text;
  final bool editable;
  final List<String> sections;
}

class InstructionGroup {
  const InstructionGroup(this.path, this.leaves);
  final List<Object> path;
  final List<InstructionLeaf> leaves;
}

class InstructionTree {
  InstructionTree(Object? json)
    : value = jsonDecode(jsonEncode(json ?? <String>[]));
  Object? value;
  List<InstructionLeaf> get leaves {
    final result = <InstructionLeaf>[];
    void visit(Object? node, List<Object> path, List<String> sections) {
      if (node is String) {
        result.add(InstructionLeaf(path, node, sections: sections));
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          visit(node[i], [...path, i], sections);
        }
      } else if (node is Map && node.containsKey('itemListElement')) {
        visit(
          node['itemListElement'],
          [...path, 'itemListElement'],
          [...sections, if (node['name'] is String) node['name'] as String],
        );
      } else if (node is Map && node['text'] is String) {
        result.add(
          InstructionLeaf(
            [...path, 'text'],
            node['text'] as String,
            sections: sections,
          ),
        );
      } else {
        if (node != null) {
          result.add(
            InstructionLeaf(
              path,
              node is Map && node['name'] is String
                  ? node['name'] as String
                  : jsonEncode(node),
              editable: false,
              sections: sections,
            ),
          );
        }
      }
    }

    visit(value, [], []);
    return result;
  }

  void edit(InstructionLeaf leaf, String text) {
    if (!leaf.editable) throw StateError('Instruction is read-only');
    if (leaf.path.isEmpty) {
      value = text;
      return;
    }
    Object? node = value;
    for (final segment in leaf.path.take(leaf.path.length - 1)) {
      node = segment is int ? (node as List)[segment] : (node as Map)[segment];
    }
    final last = leaf.path.last;
    if (last is int) {
      (node as List)[last] = text;
    } else {
      (node as Map)[last] = text;
    }
  }

  bool get flat =>
      value is List &&
      (value as List).every(
        (n) =>
            n is String ||
            n is Map &&
                n['text'] is String &&
                !n.containsKey('itemListElement'),
      );

  /// Only homogeneous editable sibling lists can move; nodes move intact.
  List<InstructionGroup> get reorderGroups {
    final result = <InstructionGroup>[];
    void visit(Object? node, List<Object> path) {
      if (node is List) {
        if (node.isNotEmpty &&
            node.every(
              (n) =>
                  n is String ||
                  n is Map &&
                      n['text'] is String &&
                      !n.containsKey('itemListElement'),
            )) {
          result.add(
            InstructionGroup(
              path,
              leaves.where((leaf) {
                final itemPath = leaf.path.lastOrNull == 'text'
                    ? leaf.path.sublist(0, leaf.path.length - 1)
                    : leaf.path;
                return itemPath.length == path.length + 1 &&
                    List.generate(
                      path.length,
                      (i) => path[i] == itemPath[i],
                    ).every((v) => v);
              }).toList(),
            ),
          );
        } else {
          for (var i = 0; i < node.length; i++) {
            visit(node[i], [...path, i]);
          }
        }
      } else if (node is Map && node.containsKey('itemListElement')) {
        visit(node['itemListElement'], [...path, 'itemListElement']);
      }
    }

    visit(value, []);
    return result;
  }

  void moveWithin(List<Object> path, int from, int to) {
    if (!reorderGroups.any((g) => jsonEncode(g.path) == jsonEncode(path))) {
      throw StateError('Instruction group is read-only');
    }
    Object? node = value;
    for (final segment in path) {
      node = segment is int ? (node as List)[segment] : (node as Map)[segment];
    }
    final list = node as List;
    list.insert(to, list.removeAt(from));
  }

  void add() {
    if (flat) {
      (value as List).add('');
    } else {
      throw StateError('Section structure is preserved');
    }
  }

  void remove(int index) {
    if (flat) (value as List).removeAt(index);
  }

  void move(int from, int to) {
    if (flat) {
      final list = value as List;
      list.insert(to, list.removeAt(from));
    }
  }
}

// Plain numbers remain minutes; colon input preserves upstream second precision.
Duration? parseEditorDuration(String value) {
  final parts = value.trim().split(':');
  if (parts.isEmpty ||
      parts.length > 3 ||
      parts.any((p) => !RegExp(r'^\d+$').hasMatch(p))) {
    return null;
  }
  final n = parts.map(int.parse).toList();
  if (n.length == 1) return Duration(minutes: n[0]);
  if (n.skip(1).any((v) => v > 59)) return null;
  return n.length == 2
      ? Duration(minutes: n[0], seconds: n[1])
      : Duration(hours: n[0], minutes: n[1], seconds: n[2]);
}

String editorDuration(Duration? value) => value == null
    ? ''
    : value.inSeconds % 60 == 0
    ? '${value.inMinutes}'
    : '${value.inHours}:${(value.inMinutes % 60).toString().padLeft(2, '0')}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
