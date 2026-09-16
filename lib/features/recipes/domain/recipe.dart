import 'dart:convert';

typedef JsonMap = Map<String, Object?>;

/// Canonical JSON is preserved. Typed projections tolerate messy imported data.
final class Recipe {
  Recipe.fromJson(JsonMap json) : _json = _copy(json);
  final JsonMap _json;
  static JsonMap _copy(JsonMap value) =>
      (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();
  JsonMap toJson() => _copy(_json);
  Recipe patch(JsonMap fields) => Recipe.fromJson({..._json, ...fields});
  String text(String field) =>
      _json[field] is String ? _json[field] as String : '';
  String get id => (_json['id'] ?? _json['recipe_id'] ?? '').toString();
  String get name => text('name');
  String get description => text('description');
  String get category => text('recipeCategory');
  String get yieldText => _json['recipeYield'] is num
      ? '${_json['recipeYield']}'
      : text('recipeYield');
  List<String> get keywords => switch (_json['keywords']) {
    String s =>
      s.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
    List items => items.whereType<String>().toList(),
    _ => [],
  };
  List<String> get ingredients => _strings(_json['recipeIngredient']);
  List<String> get tools => _strings(_json['tool']);
  List<String> get instructions => _steps(_json['recipeInstructions']);
  DateTime? get modified => parseRecipeDate(_json['dateModified']);
  Duration? duration(String field) => parseIsoDuration(text(field));
  static List<String> _strings(Object? value) => value is List
      ? value.whereType<String>().toList()
      : value is String
      ? [value]
      : [];
  static List<String> _steps(Object? value) {
    if (value is String) return value.trim().isEmpty ? [] : [value];
    if (value is List) return value.expand(_steps).toList();
    if (value is Map) {
      if (value['itemListElement'] != null) {
        return _steps(value['itemListElement']);
      }
      if (value['text'] is String) return _steps(value['text']);
      if (value['name'] is String) return _steps(value['name']);
    }
    return [];
  }
}

DateTime? parseRecipeDate(Object? value) {
  if (value is! String) return null;
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:T| |$)').firstMatch(value);
  if (match == null) return null;
  final year = int.parse(match[1]!),
      month = int.parse(match[2]!),
      day = int.parse(match[3]!);
  if (month < 1 ||
      month > 12 ||
      day < 1 ||
      day > DateTime.utc(year, month + 1, 0).day) {
    return null;
  }
  return DateTime.tryParse(value);
}

/// Calendar months/years have no fixed length and are deliberately unsupported.
Duration? parseIsoDuration(String value) {
  final match = RegExp(
    r'^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$',
  ).firstMatch(value);
  if (match == null ||
      [1, 2, 3, 4].every((i) => match.group(i) == null) ||
      value.endsWith('T')) {
    return null;
  }
  double part(int i) => double.tryParse(match.group(i) ?? '') ?? 0;
  return Duration(
    milliseconds:
        ((part(1) * 86400 + part(2) * 3600 + part(3) * 60 + part(4)) * 1000)
            .round(),
  );
}
