import '../../features/recipes/domain/recipe.dart';
import '../errors/app_failure.dart';
import '../networking/nextcloud_client.dart';
import 'cookbook_api.dart';
import 'cookbook_capabilities.dart';
import 'json_response.dart';

final class CookbookApiService implements CookbookApi {
  CookbookApiService(this.client, this.capabilities);
  final NextcloudClient client;
  final CookbookCapabilities capabilities;
  Future<Object?> _call(
    String method,
    List<String> path, {
    Object? data,
    Map<String, String>? query,
    bool bytes = false,
  }) {
    if (!capabilities.supported) {
      throw const AppFailure(FailureKind.unsupported);
    }
    return client.request(
      method,
      client.server.cookbook(['v1', ...path], query: query),
      data: data,
      bytes: bytes,
    );
  }

  static List<Recipe> parseStubs(Object? value) {
    final items = jsonObjects(value).map((json) {
      final id = json['id'] ?? json['recipe_id'];
      if ((id is! String && id is! int) ||
          '$id'.isEmpty ||
          json['name'] is! String) {
        throw const AppFailure(FailureKind.malformedResponse);
      }
      return Recipe.fromJson(json);
    }).toList();
    if (items.map((r) => r.id).toSet().length != items.length) {
      throw const AppFailure(FailureKind.malformedResponse);
    }
    return items;
  }

  String _id(Object? value) {
    if (value is int || value is String && value.isNotEmpty) return '$value';
    throw const AppFailure(FailureKind.malformedResponse);
  }

  @override
  Future<JsonMap> version() async => jsonObject(
    await client.request('GET', client.server.cookbook(['version'])),
  );
  @override
  Future<List<Recipe>> listRecipes() async =>
      parseStubs(await _call('GET', ['recipes']));
  @override
  Future<Recipe> recipe(String id) async {
    final result = Recipe.fromJson(
      jsonObject(await _call('GET', ['recipes', id])),
    );
    if (result.id != id || result.name.isEmpty) {
      throw const AppFailure(FailureKind.malformedResponse);
    }
    return result;
  }

  @override
  Future<String> create(Recipe recipe) async {
    final json = recipe.toJson()
      ..remove('id')
      ..remove('recipe_id');
    return _id(await _call('POST', ['recipes'], data: json));
  }

  @override
  Future<void> update(String id, Recipe recipe) async {
    final returned = _id(
      await _call('PUT', [
        'recipes',
        id,
      ], data: recipe.patch({'id': id}).toJson()),
    );
    if (returned != id) throw const AppFailure(FailureKind.malformedResponse);
  }

  @override
  Future<void> delete(String id) async {
    await _call('DELETE', ['recipes', id]);
  }

  @override
  Future<List<int>> image(String id, {bool fullSize = false}) async {
    final value = await _call(
      'GET',
      ['recipes', id, 'image'],
      query: {'size': fullSize ? 'full' : 'thumb'},
      bytes: true,
    );
    if (value is! List<int>) {
      throw const AppFailure(FailureKind.malformedResponse);
    }
    return value;
  }

  @override
  Future<Recipe> importUrl(Uri url) async {
    if (!['http', 'https'].contains(url.scheme) ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty) {
      throw const AppFailure(FailureKind.invalidUrl);
    }
    return Recipe.fromJson(
      jsonObject(
        await _call('POST', ['import'], data: {'url': url.toString()}),
      ),
    );
  }

  @override
  Future<List<Recipe>> search(String query) async =>
      parseStubs(await _call('GET', ['search', query]));
  @override
  Future<List<JsonMap>> categories() async =>
      jsonObjects(await _call('GET', ['categories']));
  @override
  Future<List<JsonMap>> keywords() async =>
      jsonObjects(await _call('GET', ['keywords']));
  @override
  Future<List<Recipe>> inCategory(String category) async => parseStubs(
    await _call('GET', ['category', category.isEmpty ? '_' : category]),
  );
  @override
  Future<List<Recipe>> withKeywords(List<String> keywords) async =>
      parseStubs(await _call('GET', ['tags', keywords.join(',')]));
  @override
  Future<void> renameCategory(String oldName, String newName) async {
    await _call(
      'PUT',
      ['category', oldName.isEmpty ? '_' : oldName],
      data: {'name': newName},
    );
  }

  @override
  Future<JsonMap> configuration() async =>
      jsonObject(await _call('GET', ['config']));
  @override
  Future<void> configure(JsonMap configuration) async {
    await _call('POST', ['config'], data: configuration);
  }

  @override
  Future<void> reindex() async {
    await _call('POST', ['reindex']);
  }
}
