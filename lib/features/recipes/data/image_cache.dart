import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import '../../../core/database/app_database.dart';

/// Bounded on-disk SQLite blob cache. Eviction touches images only, never recipe rows.
class ImageCacheStore {
  ImageCacheStore(this.database, this.accountId);
  final AppDatabase database;
  final String accountId;
  static const defaultLimit = 200 * 1024 * 1024;
  Future<int> limit() async {
    final rows = await database.db.query(
      'preferences',
      where: 'key=?',
      whereArgs: ['imageLimit.$accountId'],
    );
    return rows.isEmpty
        ? defaultLimit
        : int.tryParse(rows.first['value'] as String) ?? defaultLimit;
  }

  Future<int> size() async =>
      Sqflite.firstIntValue(
        await database.db.rawQuery(
          'SELECT COALESCE(SUM(length(bytes)),0) FROM image_cache WHERE account_id=?',
          [accountId],
        ),
      ) ??
      0;
  Future<void> setLimit(int bytes) async {
    if (bytes < 0) throw ArgumentError.value(bytes);
    await database.db.insert('preferences', {
      'key': 'imageLimit.$accountId',
      'value': '$bytes',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await trim();
  }

  Future<Uint8List?> read(String id, String size) async {
    final rows = await database.db.query(
      'image_cache',
      where: 'account_id=? AND recipe_id=? AND size=?',
      whereArgs: [accountId, id, size],
    );
    if (rows.isEmpty) return null;
    final data = rows.first['bytes'];
    if (data is! Uint8List || !validImageHeader(data)) {
      await remove(id, size);
      return null;
    }
    await database.db.update(
      'image_cache',
      {'accessed_at': DateTime.now().microsecondsSinceEpoch},
      where: 'account_id=? AND recipe_id=? AND size=?',
      whereArgs: [accountId, id, size],
    );
    return data;
  }

  Future<void> put(String id, String size, Uint8List bytes) async {
    if (!validImageHeader(bytes) || bytes.length > await limit()) return;
    await database.db.transaction((tx) async {
      final rows = await tx.query(
        'recipes',
        columns: ['id'],
        where: 'account_id=? AND id=?',
        whereArgs: [accountId, id],
      );
      if (rows.isEmpty) return;
      await tx.insert('image_cache', {
        'account_id': accountId,
        'recipe_id': id,
        'size': size,
        'bytes': bytes,
        'accessed_at': DateTime.now().microsecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    await trim();
  }

  Future<void> remove(String id, String size) async {
    await database.db.delete(
      'image_cache',
      where: 'account_id=? AND recipe_id=? AND size=?',
      whereArgs: [accountId, id, size],
    );
  }

  Future<void> clear() async {
    await database.db.delete(
      'image_cache',
      where: 'account_id=?',
      whereArgs: [accountId],
    );
  }

  Future<void> trim() async {
    final maxBytes = await limit();
    await database.db.transaction((tx) async {
      await tx.rawDelete(
        'DELETE FROM image_cache WHERE account_id=? AND NOT EXISTS (SELECT 1 FROM recipes r WHERE r.account_id=image_cache.account_id AND r.id=image_cache.recipe_id)',
        [accountId],
      );
      final rows = await tx.rawQuery(
        'SELECT recipe_id,size,length(bytes) AS length FROM image_cache WHERE account_id=? ORDER BY accessed_at DESC,recipe_id,size',
        [accountId],
      );
      var kept = 0;
      for (final row in rows) {
        final bytes = row['length'] as int;
        if (kept + bytes <= maxBytes) {
          kept += bytes;
        } else {
          await tx.delete(
            'image_cache',
            where: 'account_id=? AND recipe_id=? AND size=?',
            whereArgs: [accountId, row['recipe_id'], row['size']],
          );
        }
      }
    });
  }

  static bool validImageHeader(Uint8List bytes) =>
      validJpeg(bytes) ||
      (bytes.length >= 8 &&
          bytes.take(8).join(',') == '137,80,78,71,13,10,26,10');

  static bool validJpeg(Uint8List data) =>
      data.length > 3 &&
      data[0] == 255 &&
      data[1] == 216 &&
      data[data.length - 2] == 255 &&
      data.last == 217;
}
