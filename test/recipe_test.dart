import 'package:flutter_test/flutter_test.dart';
import 'package:cookbook/features/recipes/domain/recipe.dart';

void main() {
  test('unknown nested fields survive edits and cannot mutate the model', () {
    final input = <String, Object?>{
      'name': 'Soup',
      'future': {
        'value': [1, 2],
      },
      'author': {'name': 'Cook'},
    };
    final recipe = Recipe.fromJson(input);
    (input['future'] as Map)['value'] = <int>[];
    final changed = recipe.patch({'name': 'Stew'});
    expect(changed.toJson()['future'], {
      'value': [1, 2],
    });
    expect(changed.toJson()['author'], {'name': 'Cook'});
  });
  test('sparse and malformed optional fields remain readable', () {
    final recipe = Recipe.fromJson({
      'id': 42,
      'recipeIngredient': false,
      'keywords': null,
      'nutrition': [],
    });
    expect(recipe.id, '42');
    expect(recipe.ingredients, isEmpty);
    expect(recipe.keywords, isEmpty);
    expect(recipe.toJson()['nutrition'], isEmpty);
  });
  test('structured instructions flatten only for display', () {
    final input = {
      'recipeInstructions': [
        {
          '@type': 'HowToSection',
          'itemListElement': [
            {'@type': 'HowToStep', 'text': 'Stir'},
            'Bake',
          ],
        },
      ],
    };
    final recipe = Recipe.fromJson(input);
    expect(recipe.instructions, ['Stir', 'Bake']);
    expect(recipe.toJson(), input);
  });
  test('ISO durations and historic offsets', () {
    expect(parseIsoDuration('PT1H20M'), const Duration(minutes: 80));
    expect(
      parseIsoDuration('P1DT0.5S'),
      const Duration(days: 1, milliseconds: 500),
    );
    for (final invalid in ['P', 'PT', 'P1M', 'P1DT', 'bad']) {
      expect(parseIsoDuration(invalid), isNull);
    }
    expect(
      parseRecipeDate('2021-05-23T17:10:25+0000'),
      DateTime.utc(2021, 5, 23, 17, 10, 25),
    );
    expect(parseRecipeDate('2021-05-23'), isNotNull);
    expect(parseRecipeDate(false), isNull);
  });
}
