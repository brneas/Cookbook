import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../../../core/database/app_database.dart';
import '../domain/recipe.dart';

bool ingredientHeading(String text) => RegExp(r'^\s*#{1,6}\s+').hasMatch(text);
String normalizedIngredient(String text) =>
    text.trim().replaceAll(RegExp(r'\s+'), ' ');
List<String?> ingredientKeys(List<String> lines) {
  final occurrences = <String, int>{};
  return [
    for (final line in lines)
      if (ingredientHeading(line) || line.trim().isEmpty)
        null
      else
        (() {
          final text = normalizedIngredient(line);
          final occurrence = occurrences.update(
            text,
            (n) => n + 1,
            ifAbsent: () => 0,
          );
          return jsonEncode([text, occurrence]);
        })(),
  ];
}

/// Account-owned presentation state, never part of a recipe or mutation payload.
class IngredientCheckStore {
  IngredientCheckStore(this.database, this.account);
  final AppDatabase database;
  final String account;
  String key(String id) => 'ingredientChecks.${jsonEncode(id)}';
  Future<Set<String>> update(
    Recipe recipe, {
    String? toggle,
    bool clear = false,
  }) async {
    final id = await database.resolveId(account, recipe.id);
    return database.db.transaction((tx) async {
      var migrated = false;
      var rows = await tx.query(
        'account_metadata',
        where: 'account_id=? AND key=?',
        whereArgs: [account, key(id)],
      );
      // Local recipe IDs may have been assigned a server ID after offline create.
      if (rows.isEmpty) {
        final aliases = await tx.query(
          'recipe_aliases',
          where: 'account_id=? AND server_id=?',
          whereArgs: [account, id],
        );
        for (final alias in aliases) {
          final oldKey = key(alias['local_id'] as String);
          rows = await tx.query(
            'account_metadata',
            where: 'account_id=? AND key=?',
            whereArgs: [account, oldKey],
          );
          if (rows.isNotEmpty) {
            migrated = true;
            await tx.delete(
              'account_metadata',
              where: 'account_id=? AND key=?',
              whereArgs: [account, oldKey],
            );
            break;
          }
        }
      }
      final old = rows.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(rows.single['value'] as String) as Map<String, dynamic>;
      final keys = ingredientKeys(
        recipe.ingredients,
      ).whereType<String>().toSet();
      final previous = ((old['lines'] as List?) ?? []).cast<String>();
      Map<String, int> counts(Iterable<String> values) {
        final result = <String, int>{};
        for (final value in values) {
          final text = (jsonDecode(value) as List).first as String;
          result.update(text, (n) => n + 1, ifAbsent: () => 1);
        }
        return result;
      }

      final before = counts(previous), after = counts(keys);
      final checked = ((old['checked'] as List?) ?? []).cast<String>().where((
        k,
      ) {
        if (!keys.contains(k)) return false;
        final text = (jsonDecode(k) as List).first as String;
        // Duplicate count changes are ambiguous: do not transfer their checks.
        return before[text] == after[text];
      }).toSet();
      if (clear) checked.clear();
      if (toggle != null && keys.contains(toggle)) {
        checked.contains(toggle) ? checked.remove(toggle) : checked.add(toggle);
      }
      final value = jsonEncode({
        'lines': keys.toList(),
        'checked': checked.toList()..sort(),
      });
      if (migrated || rows.isEmpty || rows.single['value'] != value) {
        await tx.insert('account_metadata', {
          'account_id': account,
          'key': key(id),
          'value': value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      return checked;
    });
  }
}
