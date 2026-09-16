import 'dart:convert';
import 'package:diacritic/diacritic.dart';
import 'package:sqflite/sqflite.dart';
import '../../../core/database/app_database.dart';
import '../domain/recipe.dart';

String normalizeKeyword(String value) => removeDiacritics(value)
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll('ß', 'ss')
    .replaceAll('æ', 'ae')
    .replaceAll('œ', 'oe')
    .replaceAll('ø', 'o')
    .replaceAll('ł', 'l');

enum RecipeSort {
  nameAscending,
  nameDescending,
  createdAscending,
  createdDescending,
  modifiedAscending,
  modifiedDescending,
}

extension RecipeSortLabel on RecipeSort {
  String get label => const [
    'Name · A–Z',
    'Name · Z–A',
    'Created · oldest first',
    'Created · newest first',
    'Modified · oldest first',
    'Modified · newest first',
  ][index];
  String get sql {
    final field = index < 2
        ? 'name_fold'
        : index < 4
        ? 'created'
        : 'modified';
    return '${index < 2 ? '' : 'r.$field IS NULL, '}r.$field ${index.isEven ? 'ASC' : 'DESC'}, r.id';
  }
}

class LibraryFilter {
  const LibraryFilter({
    this.search = '',
    this.category,
    this.keywords = const [],
    this.anyKeyword = false,
    this.sort = RecipeSort.nameAscending,
  });
  final String search;
  final String? category;
  final List<String> keywords;
  final bool anyKeyword;
  final RecipeSort sort;
  LibraryFilter copy({
    String? search,
    String? category,
    bool clearCategory = false,
    List<String>? keywords,
    bool? anyKeyword,
    RecipeSort? sort,
  }) => LibraryFilter(
    search: search ?? this.search,
    category: clearCategory ? null : category ?? this.category,
    keywords: keywords ?? this.keywords,
    anyKeyword: anyKeyword ?? this.anyKeyword,
    sort: sort ?? this.sort,
  );
  bool get active =>
      search.isNotEmpty || category != null || keywords.isNotEmpty;
  @override
  bool operator ==(Object other) =>
      other is LibraryFilter &&
      search == other.search &&
      category == other.category &&
      keywords.join('\u0000') == other.keywords.join('\u0000') &&
      anyKeyword == other.anyKeyword &&
      sort == other.sort;
  @override
  int get hashCode =>
      Object.hash(search, category, keywords.join('\u0000'), anyKeyword, sort);
}

class LibraryItem {
  const LibraryItem(
    this.id,
    this.name,
    this.category, {
    this.created,
    this.modified,
  });
  final String id, name, category;
  final DateTime? created, modified;
  factory LibraryItem.row(Map<String, Object?> row) => LibraryItem(
    row['id'] as String,
    row['name'] as String,
    row['category'] as String,
    created: row['created'] is int
        ? DateTime.fromMillisecondsSinceEpoch(
            row['created'] as int,
            isUtc: true,
          )
        : null,
    modified: row['modified'] is int
        ? DateTime.fromMillisecondsSinceEpoch(
            row['modified'] as int,
            isUtc: true,
          )
        : null,
  );
}

class Facet {
  const Facet(this.name, this.count, {this.available = true});
  final String name;
  final int count;
  final bool available;
  String get categoryLabel => name.isEmpty ? 'Uncategorized' : name;
}

class LibraryPage {
  const LibraryPage(this.items, this.total);
  final List<LibraryItem> items;
  final int total;
}

/// Rebuildable, account-scoped projection. SQLite invalidates it on recipe writes.
class LibraryRepository {
  LibraryRepository(this.database, this.account);
  final AppDatabase database;
  final String account;
  Future<void>? _preparing;
  Future<void> prepare() =>
      _preparing ??= _prepare().whenComplete(() => _preparing = null);
  Future<void> _prepare() async {
    while (true) {
      final count = await database.db.transaction((tx) async {
        final rows = await tx.rawQuery(
          '''SELECT r.* FROM recipes r LEFT JOIN library_index i ON i.account_id=r.account_id AND i.id=r.id WHERE r.account_id=? AND i.id IS NULL AND r.local_deleted=0 AND r.remote_state!='deleted' LIMIT 100''',
          [account],
        );
        if (rows.isEmpty) return 0;
        final batch = tx.batch();
        for (final row in rows) {
          final recipe = Recipe.fromJson(
            (jsonDecode((row['detail_json'] ?? row['stub_json']) as String)
                    as Map)
                .cast<String, Object?>(),
          );
          batch.insert('library_index', {
            'account_id': account,
            'id': row['id'],
            'name': row['name'],
            'name_fold': (row['name'] as String).toLowerCase(),
            'category': row['category'],
            'search_text':
                '${row['name']}\n${row['category']}\n${row['keywords']}'
                    .toLowerCase(),
            'created': parseRecipeDate(
              recipe.toJson()['dateCreated'],
            )?.millisecondsSinceEpoch,
            'modified': recipe.modified?.millisecondsSinceEpoch,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          for (final tag in recipe.keywords.toSet()) {
            batch.insert('library_keywords', {
              'account_id': account,
              'recipe_id': row['id'],
              'name': tag,
              'normalized': normalizeKeyword(tag),
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
        }
        await batch.commit(noResult: true);
        return rows.length;
      });
      if (count == 0) return;
    }
  }

  (String, List<Object?>) _where(LibraryFilter filter) {
    final parts = ['r.account_id=?'];
    final args = <Object?>[account];
    if (filter.category != null) {
      parts.add('r.category=?');
      args.add(filter.category);
    }
    final words = filter.search
        .toLowerCase()
        .split(RegExp(r'[ ,]+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (words.isNotEmpty) {
      parts.add(
        '(${words.map((_) => "r.search_text LIKE ? ESCAPE '\\'").join(' OR ')})',
      );
      args.addAll(
        words.map(
          (w) =>
              '%${w.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_')}%',
        ),
      );
    }
    if (filter.keywords.isNotEmpty) {
      parts.add(
        '(${filter.keywords.map((_) => 'EXISTS (SELECT 1 FROM library_keywords k WHERE k.account_id=r.account_id AND k.recipe_id=r.id AND k.normalized=?)').join(filter.anyKeyword ? ' OR ' : ' AND ')})',
      );
      args.addAll(filter.keywords.map(normalizeKeyword));
    }
    return (parts.join(' AND '), args);
  }

  Future<LibraryPage> page(
    LibraryFilter filter, {
    int offset = 0,
    int limit = 60,
  }) async {
    await prepare();
    final (where, args) = _where(filter);
    final total =
        Sqflite.firstIntValue(
          await database.db.rawQuery(
            'SELECT COUNT(*) FROM library_index r WHERE $where',
            args,
          ),
        ) ??
        0;
    final rows = await database.db.rawQuery(
      'SELECT r.* FROM library_index r WHERE $where ORDER BY ${filter.sort.sql} LIMIT ? OFFSET ?',
      [...args, limit.clamp(1, 200), offset],
    );
    return LibraryPage(rows.map(LibraryItem.row).toList(), total);
  }

  Future<List<Facet>> categories() async {
    await prepare();
    final rows = await database.db.rawQuery(
      'SELECT category,COUNT(*) AS n FROM library_index WHERE account_id=? GROUP BY category ORDER BY category COLLATE NOCASE',
      [account],
    );
    return [
      for (final row in rows) Facet(row['category'] as String, row['n'] as int),
    ];
  }

  Future<List<Facet>> keywords(LibraryFilter filter) async {
    await prepare();
    final (base, baseArgs) = _where(LibraryFilter(category: filter.category));
    final (active, activeArgs) = _where(filter);
    final rows = await database.db.rawQuery(
      'SELECT k.name, COUNT(*) AS n FROM library_keywords k JOIN library_index r ON r.account_id=k.account_id AND r.id=k.recipe_id WHERE $base GROUP BY k.name ORDER BY k.name COLLATE NOCASE',
      baseArgs,
    );
    final available = (await database.db.rawQuery(
      'SELECT DISTINCT k.normalized FROM library_keywords k JOIN library_index r ON r.account_id=k.account_id AND r.id=k.recipe_id WHERE $active',
      activeArgs,
    )).map((r) => r['normalized']).toSet();
    return [
      for (final row in rows)
        Facet(
          row['name'] as String,
          row['n'] as int,
          available: available.contains(
            normalizeKeyword(row['name'] as String),
          ),
        ),
    ];
  }

  Future<Map<String, List<String>>> taxonomy() async => {
    'categories': (await categories())
        .map((c) => c.name)
        .where((s) => s.isNotEmpty)
        .toList(),
    'keywords': (await keywords(
      const LibraryFilter(),
    )).map((k) => k.name).toList(),
  };
}
