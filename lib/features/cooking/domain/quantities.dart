/// Exact arithmetic for quantities; no binary floating-point in scaling.
class Rational implements Comparable<Rational> {
  factory Rational(int numerator, [int denominator = 1]) =>
      Rational._reduce(BigInt.from(numerator), BigInt.from(denominator));
  factory Rational._reduce(BigInt numerator, BigInt denominator) {
    if (denominator == BigInt.zero) {
      throw const FormatException('Zero denominator');
    }
    final sign = denominator.isNegative ? -BigInt.one : BigInt.one;
    final gcd = numerator.gcd(denominator);
    return Rational._(sign * numerator ~/ gcd, denominator.abs() ~/ gcd);
  }
  const Rational._(this.n, this.d);
  final BigInt n, d;
  Rational operator *(Rational b) => Rational._reduce(n * b.n, d * b.d);
  Rational operator /(Rational b) => Rational._reduce(n * b.d, d * b.n);
  Rational operator +(Rational b) =>
      Rational._reduce(n * b.d + b.n * d, d * b.d);
  @override
  int compareTo(Rational other) => (n * other.d).compareTo(other.n * d);
  String get wire => '$n/$d';

  /// Restore our exact stored ratio without applying ingredient-input limits.
  static Rational? fromWire(String input) {
    final match = RegExp(r'^(\d{1,80})/(\d{1,80})$').firstMatch(input);
    if (match == null) return null;
    final numerator = BigInt.parse(match[1]!);
    final denominator = BigInt.parse(match[2]!);
    if (numerator <= BigInt.zero || denominator <= BigInt.zero) return null;
    return Rational._reduce(numerator, denominator);
  }

  static Rational? parse(String input) {
    final text = input.trim();
    if (text.length > 24 || RegExp(r'\d{10}').hasMatch(text)) return null;
    final unicode = RegExp(
      r'^(\d*)\s*([¼½¾⅐⅑⅒⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞])$',
    ).firstMatch(text);
    if (unicode != null) {
      return Rational(int.tryParse(unicode[1]!) ?? 0) + vulgar[unicode[2]]!;
    }
    final mixed = RegExp(r'^(\d+)\s+(\d+)/(\d+)$').firstMatch(text);
    if (mixed != null) {
      final fraction = parse('${mixed[2]}/${mixed[3]}');
      return fraction == null
          ? null
          : Rational(int.parse(mixed[1]!)) + fraction;
    }
    final fraction = RegExp(r'^(\d+)/(\d+)$').firstMatch(text);
    if (fraction != null) {
      final d = int.parse(fraction[2]!);
      return d == 0 ? null : Rational(int.parse(fraction[1]!), d);
    }
    if (!RegExp(r'^\d*\.?\d+$').hasMatch(text) || text.length > 12) return null;
    final parts = text.split('.');
    if (parts.length == 1) return Rational(int.parse(text));
    final denominator = int.parse('1${'0' * parts.last.length}');
    return Rational(
      (int.tryParse(parts.first) ?? 0) * denominator + int.parse(parts.last),
      denominator,
    );
  }

  String get display {
    if (d == BigInt.one) return '$n';
    final whole = n ~/ d, remainder = n % d;
    if ([2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 16].any((v) => d == BigInt.from(v))) {
      return '${whole == BigInt.zero ? '' : '$whole '}$remainder/$d';
    }
    // Exact fraction is preferable to silently changing a quantity.
    return '$n/$d';
  }
}

final vulgar = <String, Rational>{
  '¼': Rational(1, 4),
  '½': Rational(1, 2),
  '¾': Rational(3, 4),
  '⅐': Rational(1, 7),
  '⅑': Rational(1, 9),
  '⅒': Rational(1, 10),
  '⅓': Rational(1, 3),
  '⅔': Rational(2, 3),
  '⅕': Rational(1, 5),
  '⅖': Rational(2, 5),
  '⅗': Rational(3, 5),
  '⅘': Rational(4, 5),
  '⅙': Rational(1, 6),
  '⅚': Rational(5, 6),
  '⅛': Rational(1, 8),
  '⅜': Rational(3, 8),
  '⅝': Rational(5, 8),
  '⅞': Rational(7, 8),
};
const _quantity =
    r'(?:\d+\s+\d+/\d+|\d*[¼½¾⅐⅑⅒⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞]|\d+/\d+|\d*\.\d+|\d+)';

class IngredientQuantity {
  const IngredientQuantity(
    this.original, {
    this.low,
    this.high,
    this.remainder = '',
    this.safe = false,
  });
  final String original, remainder;
  final Rational? low, high;
  final bool safe;
  factory IngredientQuantity.parse(String line) {
    final match = RegExp(
      '^($_quantity)(?:\\s*(?:-|–|to)\\s*($_quantity))?(?=\\s|\$)(.*)\$',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) return IngredientQuantity(line);
    final low = Rational.parse(match[1]!);
    final high = match[2] == null ? null : Rational.parse(match[2]!);
    final rest = match[3]!;
    final uncertain = RegExp(
      r'^\s*(?:\(|[x×]\s*\d)|\d|\b(?:to taste|as needed)\b',
      caseSensitive: false,
    ).hasMatch(rest);
    final safe =
        low != null &&
        low.n > BigInt.zero &&
        !uncertain &&
        (match[2] == null || high != null && high.compareTo(low) >= 0);
    return IngredientQuantity(
      line,
      low: low,
      high: high,
      remainder: rest,
      safe: safe,
    );
  }
  String scaled(Rational multiplier) {
    if (!safe ||
        multiplier.n <= BigInt.zero ||
        multiplier.compareTo(Rational(1)) == 0) {
      return original;
    }
    return '${(low! * multiplier).display}${high == null ? '' : '–${(high! * multiplier).display}'}$remainder';
  }
}

Rational? yieldBasis(String text) {
  final match = RegExp(
    r'^(?:(?:serves|makes)\s+)?(\d+(?:\.\d+)?)(?:\s+(?:servings?|portions?|cookies?|loaves?|people))?$',
    caseSensitive: false,
  ).firstMatch(text.trim());
  final value = match == null ? null : Rational.parse(match[1]!);
  return value != null && value.n > BigInt.zero ? value : null;
}
