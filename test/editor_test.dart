import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:cookbook/features/editor/domain/recipe_draft.dart';
import 'package:cookbook/features/recipes/domain/recipe.dart';

void main() {
  for (final name in ['imported-string', 'imported-structured']) {
    test('editing known fields preserves independent $name metadata', () {
      final original =
          (jsonDecode(File('test/fixtures/$name.json').readAsStringSync())
                  as Map)
              .cast<String, Object?>();
      final draft = RecipeDraft(Recipe.fromJson(original));
      expect(draft.changed, false);
      expect(draft.build().toJson(), original);
      draft.set('name', 'Edited name');
      final expected = {...original, 'name': 'Edited name'};
      expect(draft.build().toJson(), expected);
      expect(draft.original, original);
      expect(draft.changed, true);
    });
  }
  test('nested author nutrition and image edits preserve unknown keys', () {
    final draft = RecipeDraft(
      Recipe.fromJson({
        'name': 'Test',
        'author': {'name': 'A', 'url': 'https://example.invalid/author'},
        'image': {
          'url': 'old',
          'credit': {'name': 'Photographer'},
        },
        'nutrition': {
          'calories': '1',
          'custom': {'unit': 'g'},
        },
      }),
    );
    draft.authorName('B');
    draft.imageUrl('new');
    draft.nested('nutrition', 'calories', '2');
    expect(draft.values['author'], {
      'name': 'B',
      'url': 'https://example.invalid/author',
    });
    expect((draft.values['nutrition'] as Map)['custom'], {'unit': 'g'});
    expect((draft.values['image'] as Map)['credit'], {'name': 'Photographer'});
  });
  for (final shape in <Object>[
    'Stir slowly',
    ['Stir slowly', 'Serve'],
    {'@type': 'HowToStep', 'text': 'Stir slowly', 'url': '#step'},
    [
      {
        '@type': 'HowToSection',
        'name': 'Sauce',
        'custom': true,
        'itemListElement': [
          {
            '@type': 'HowToStep',
            'text': 'Stir slowly',
            'image': {'url': 'step.jpg'},
          },
        ],
      },
      'Serve',
      {
        'unrecognized': [1, 2],
      },
    ],
  ]) {
    test(
      'instruction round trip ${shape.runtimeType}: only selected text changes',
      () {
        final tree = InstructionTree(shape);
        final before = jsonEncode(shape);
        expect(jsonEncode(tree.value), before);
        tree.edit(tree.leaves.first, 'Whisk gently');
        expect(
          jsonEncode(tree.value),
          before.replaceFirst('Stir slowly', 'Whisk gently'),
        );
        expect(jsonEncode(shape), before);
      },
    );
  }
  test(
    'structured metadata travels with reordered step and unsupported data stays read only',
    () {
      final tree = InstructionTree([
        {'@type': 'HowToStep', 'text': 'First', 'custom': 42},
        'Second',
      ]);
      tree.move(0, 1);
      expect((tree.value as List).last, {
        '@type': 'HowToStep',
        'text': 'First',
        'custom': 42,
      });
      tree.remove(0);
      tree.add();
      expect((tree.value as List).length, 2);
      final opaque = InstructionTree({
        'custom': [1, 2],
      });
      expect(opaque.leaves.single.editable, false);
      expect(() => opaque.edit(opaque.leaves.single, 'Lost'), throwsStateError);
      expect(opaque.value, {
        'custom': [1, 2],
      });
    },
  );
  test('new recipe has canonical schema and no proprietary fields', () {
    final draft = RecipeDraft.empty()..set('name', 'Synthetic dinner');
    expect(draft.values['@type'], 'Recipe');
    expect(draft.values['recipeIngredient'], isEmpty);
    expect(draft.values['recipeInstructions'], isEmpty);
    expect(draft.values.containsKey('sync_state'), false);
    expect(draft.build().name, 'Synthetic dinner');
  });
}
