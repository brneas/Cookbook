import '../../features/recipes/domain/recipe.dart';

abstract interface class CookbookApi {
  Future<JsonMap> version();
  Future<List<Recipe>> listRecipes();
  Future<Recipe> recipe(String id);
  Future<String> create(Recipe recipe);
  Future<void> update(String id, Recipe recipe);
  Future<void> delete(String id);
  Future<List<int>> image(String id, {bool fullSize = false});
  Future<Recipe> importUrl(Uri url);
  Future<List<Recipe>> search(String query);
  Future<List<JsonMap>> categories();
  Future<List<JsonMap>> keywords();
  Future<List<Recipe>> inCategory(String category);
  Future<List<Recipe>> withKeywords(List<String> keywords);
  Future<void> renameCategory(String oldName, String newName);
  Future<JsonMap> configuration();
  Future<void> configure(JsonMap configuration);
  Future<void> reindex();
}
