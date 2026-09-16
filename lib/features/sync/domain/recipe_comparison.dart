import 'dart:convert';
import '../../recipes/domain/recipe.dart';

// Transport identifiers, generated dates, derived image routes and user print preference
// do not describe an edit's recipe content. All other fields, including unknowns, do.
const serverManagedFields = {
  'id',
  'recipe_id',
  'dateCreated',
  'dateModified',
  'imageUrl',
  'imagePlaceholderUrl',
  'printImage',
};
Object? sortedJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: sortedJson(value[key])};
  }
  if (value is List) return value.map(sortedJson).toList();
  return value;
}

String fingerprint(JsonMap json) => jsonEncode(
  sortedJson({
    for (final entry in json.entries)
      if (!serverManagedFields.contains(entry.key)) entry.key: entry.value,
  }),
);
bool sameRecipe(JsonMap? left, JsonMap? right) => left == null || right == null
    ? left == right
    : fingerprint(left) == fingerprint(right);
JsonMap? decodeRecipe(Object? value) => value == null
    ? null
    : (jsonDecode(value as String) as Map).cast<String, Object?>();

enum MutationState {
  queued,
  sending,
  unknownOutcome,
  conflict,
  applied,
  failed,
}
