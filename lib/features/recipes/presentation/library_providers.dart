import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import '../../../app/providers.dart';
import '../../../core/errors/app_failure.dart';
import '../data/library_repository.dart';

final libraryRepositoryProvider = FutureProvider<LibraryRepository>((
  ref,
) async {
  final account = await ref.watch(accountProvider.future);
  if (account == null) throw const AppFailure(FailureKind.authentication);
  return LibraryRepository(
    await ref.watch(databaseProvider.future),
    account.id,
  );
});
final categoryFacetsProvider = FutureProvider<List<Facet>>((ref) async {
  ref.watch(syncProvider.select((s) => s.revision));
  return (await ref.watch(libraryRepositoryProvider.future)).categories();
});
final keywordFacetsProvider = FutureProvider.autoDispose
    .family<List<Facet>, LibraryFilter>((ref, filter) async {
      ref.watch(syncProvider.select((s) => s.revision));
      return (await ref.watch(
        libraryRepositoryProvider.future,
      )).keywords(filter);
    });
final libraryPageProvider = FutureProvider.autoDispose
    .family<LibraryPage, ({LibraryFilter filter, int offset})>((
      ref,
      request,
    ) async {
      ref.watch(syncProvider.select((s) => s.revision));
      return (await ref.watch(
        libraryRepositoryProvider.future,
      )).page(request.filter, offset: request.offset);
    });

class LibraryPreferences {
  const LibraryPreferences({
    this.grid = false,
    this.sort = RecipeSort.nameAscending,
  });
  final bool grid;
  final RecipeSort sort;
}

final libraryPreferencesProvider =
    AsyncNotifierProvider<LibraryPreferencesController, LibraryPreferences>(
      LibraryPreferencesController.new,
    );

class LibraryPreferencesController extends AsyncNotifier<LibraryPreferences> {
  @override
  Future<LibraryPreferences> build() async {
    final db = await ref.watch(databaseProvider.future);
    final rows = await db.db.query(
      'preferences',
      where: "key IN ('library.view','library.sort')",
    );
    final values = {for (final row in rows) row['key']: row['value']};
    return LibraryPreferences(
      grid: values['library.view'] == 'grid',
      sort:
          RecipeSort.values
              .where((s) => s.name == values['library.sort'])
              .firstOrNull ??
          RecipeSort.nameAscending,
    );
  }

  Future<void> set({bool? grid, RecipeSort? sort}) async {
    final old = state.asData?.value ?? await future;
    final value = LibraryPreferences(
      grid: grid ?? old.grid,
      sort: sort ?? old.sort,
    );
    final db = await ref.read(databaseProvider.future);
    await db.db.transaction((tx) async {
      for (final entry in {
        'library.view': value.grid ? 'grid' : 'list',
        'library.sort': value.sort.name,
      }.entries) {
        await tx.insert('preferences', {
          'key': entry.key,
          'value': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    state = AsyncData(value);
  }
}
