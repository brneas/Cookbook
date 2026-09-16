import 'package:flutter_test/flutter_test.dart';
import 'package:cookbook/features/cooking/domain/quantities.dart';
import 'package:cookbook/features/cooking/domain/duration_suggestions.dart';

void main() {
  for (final entry in {
    '1': '1',
    '2': '2',
    '10': '10',
    '0.5': '1/2',
    '.5': '1/2',
    '1.25': '1 1/4',
    '1/2': '1/2',
    '3/4': '3/4',
    '2/3': '2/3',
    '1 1/2': '1 1/2',
    '2 3/4': '2 3/4',
    '½': '1/2',
    '1½': '1 1/2',
    '¼': '1/4',
    '2¾': '2 3/4',
  }.entries) {
    test('exact quantity ${entry.key}', () {
      expect(Rational.parse(entry.key)!.display, entry.value);
    });
  }
  for (final fraction in vulgar.entries) {
    test('Unicode ${fraction.key}', () {
      expect(Rational.parse(fraction.key)!.wire, fraction.value.wire);
    });
  }
  for (final entry in {
    '1 cup milk': '1 1/2 cup milk',
    '2 cups flour': '3 cups flour',
    '0.5 teaspoon salt': '3/4 teaspoon salt',
    '.5 teaspoon salt': '3/4 teaspoon salt',
    '1/2 cup sugar': '3/4 cup sugar',
    '1 1/2 cups broth': '2 1/4 cups broth',
    '1½ cups broth': '2 1/4 cups broth',
    '¼ teaspoon pepper': '3/8 teaspoon pepper',
    '2-3 tablespoons oil': '3–4 1/2 tablespoons oil',
    '2 – 3 tablespoons oil': '3–4 1/2 tablespoons oil',
    '2 to 3 tablespoons oil': '3–4 1/2 tablespoons oil',
    '1-2': '1 1/2–3',
    '1 - 2': '1 1/2–3',
    '1–2': '1 1/2–3',
    '1 to 2': '1 1/2–3',
    '1 1/2-2': '2 1/4–3',
  }.entries) {
    test('scale ${entry.key}', () {
      expect(
        IngredientQuantity.parse(entry.key).scaled(Rational(3, 2)),
        entry.value,
      );
      expect(
        IngredientQuantity.parse(entry.key).scaled(Rational(1)),
        entry.key,
      );
    });
  }
  for (final line in [
    'salt to taste',
    'a pinch of pepper',
    'one large onion',
    'juice of half a lemon',
    '1 (14-ounce) can tomatoes',
    '2 x 400g cans',
    'as needed',
    'to taste',
    'a pinch',
    'one onion',
    '1/0 cup',
    '2-1 cups',
    '999999999999999999999999 cups',
    '1 1/0 cups',
  ]) {
    test('conservative unchanged $line', () {
      expect(IngredientQuantity.parse(line).scaled(Rational(2)), line);
    });
  }
  for (final entry in {
    '4': '4',
    '4 servings': '4',
    'Serves 6': '6',
    '6 portions': '6',
    'Makes 12 cookies': '12',
    '2 loaves': '2',
    '12': '12',
  }.entries) {
    test('yield ${entry.key}', () {
      expect(yieldBasis(entry.key)!.display, entry.value);
    });
  }
  for (final text in ['About 8', '4-6', 'a bowl', '', '0', '4 to 6 servings']) {
    test('unknown yield $text', () {
      expect(yieldBasis(text), null);
    });
  }
  for (final entry in {
    'Bake for 20 minutes.': 1200,
    'Simmer for 1 hour.': 3600,
    'Cook for 1 hour 30 minutes.': 5400,
    'Rest for 45 min.': 2700,
    'Wait 30 seconds.': 30,
    'Simmer 1 hr 15 min': 4500,
    '90 minutes': 5400,
  }.entries) {
    test('suggestion ${entry.key}', () {
      expect(
        durationSuggestions(entry.key).single.minimum.inSeconds,
        entry.value,
      );
    });
  }
  test('duration range has deliberate lower and upper options', () {
    final s = durationSuggestions('Bake for 20-25 minutes.').single;
    expect(s.minimum.inMinutes, 20);
    expect(s.maximum!.inMinutes, 25);
  });
  for (final text in [
    'Cook until done.',
    'Simmer briefly.',
    'cook for a while',
    '1.5 hours',
    '1/2 hour',
    '-20 minutes',
    '0 seconds',
    '999999999999999999999999999999 hours',
    '20-999999999999999999999999999 minutes',
    '1 hour 999999999999999999999999999 seconds',
  ]) {
    test('no precise suggestion $text', () {
      expect(durationSuggestions(text), isEmpty);
    });
  }
  test(
    'exact multiplication does not round to a prettier but wrong fraction',
    () {
      expect((Rational(1, 3) * Rational(1, 7)).wire, '1/21');
      expect((Rational(1, 2) * Rational(3, 2)).display, '3/4');
      final large = Rational.parse('999999999 1/999999997')!;
      expect(Rational.fromWire(large.wire)!.wire, large.wire);
      final smallYield = yieldBasis('0.000000001 servings')!;
      final multiplier = (smallYield + Rational(1)) / smallYield;
      expect(Rational.fromWire(multiplier.wire)!.wire, multiplier.wire);
      expect(Rational.fromWire('1/0'), null);
      expect(
        (large * Rational(999999999)).wire,
        '999999995000000007999999996/999999997',
      );
    },
  );
}
