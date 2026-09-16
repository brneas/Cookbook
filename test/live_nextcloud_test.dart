import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:cookbook/core/api/cookbook_api_service.dart';
import 'package:cookbook/core/api/cookbook_capabilities.dart';
import 'package:cookbook/core/auth/credential_store.dart';
import 'package:cookbook/core/auth/nextcloud_verification.dart';
import 'package:cookbook/core/errors/app_failure.dart';
import 'package:cookbook/core/networking/nextcloud_client.dart';
import 'package:cookbook/core/networking/server_address.dart';
import 'package:cookbook/features/recipes/domain/recipe.dart';
import 'package:cookbook/features/sync/data/mutation_store.dart';

void main() {
  final env = Platform.environment;
  final configured = [
    'NEXTCLOUD_TEST_SERVER',
    'NEXTCLOUD_TEST_USERNAME',
    'NEXTCLOUD_TEST_APP_PASSWORD',
  ].every((key) => env[key]?.isNotEmpty == true);
  final writes = configured && env['NEXTCLOUD_TEST_ALLOW_WRITES'] == 'true';
  Future<void> session(Future<void> Function(CookbookApiService) body) async {
    NextcloudClient? client;
    try {
      client = NextcloudClient(
        ServerAddress.parse(env['NEXTCLOUD_TEST_SERVER']!),
        credentials: AppCredentials(
          env['NEXTCLOUD_TEST_USERNAME']!,
          env['NEXTCLOUD_TEST_APP_PASSWORD']!,
        ),
      );
      final verification = NextcloudVerification(client);
      await verification.verify();
      final info = await verification.capabilities();
      final caps = await CookbookCapabilityService(
        client,
      ).discover(nextcloudCapabilities: info.capabilities);
      await body(CookbookApiService(client, caps));
    } catch (error) {
      fail(
        'Live verification failed: ${safeFailure(error).kind.name}. Credentials and raw responses omitted.',
      );
    } finally {
      client?.close();
    }
  }

  test(
    'live read-only external API',
    () async => session((api) async {
      final recipes = await api.listRecipes();
      await api.categories();
      await api.keywords();
      if (recipes.isNotEmpty) {
        await api.recipe(recipes.first.id);
        try {
          await api.image(recipes.first.id);
        } on AppFailure catch (error) {
          if (error.status != 406) rethrow;
        }
      }
    }),
    skip: configured ? false : 'No opt-in live server credentials supplied',
  );
  test(
    'live owned-fixture create/read/update/delete',
    () async => session((api) async {
      final name = 'Cookbook Integration Test ${localRecipeId().substring(6)}';
      String? ownedId;
      try {
        ownedId = await api.create(
          Recipe.fromJson({
            '@context': 'https://schema.org',
            '@type': 'Recipe',
            'name': name,
            'recipeIngredient': ['1 cup water'],
            'recipeInstructions': ['Warm the water.'],
            'recipeCategory': 'Integration test',
            'keywords': 'integration-test',
            'recipeYield': 1,
            'tool': [],
          }),
        );
        final created = await api.recipe(ownedId);
        if (created.name != name) throw const AppFailure(FailureKind.conflict);
        await api.update(
          ownedId,
          created.patch({'description': 'Updated by this test run'}),
        );
        if ((await api.recipe(ownedId)).description !=
            'Updated by this test run') {
          throw const AppFailure(FailureKind.malformedResponse);
        }
        await api.delete(ownedId);
        try {
          await api.recipe(ownedId);
          throw const AppFailure(FailureKind.conflict);
        } on AppFailure catch (error) {
          if (error.kind != FailureKind.notFound) rethrow;
        }
        ownedId = null;
      } finally {
        if (ownedId != null) {
          // Only the positively identified recipe created by this run may be cleaned up.
          try {
            final remaining = await api.recipe(ownedId);
            if (remaining.name == name) await api.delete(ownedId);
          } on AppFailure catch (error) {
            if (error.kind != FailureKind.notFound) rethrow;
          }
        }
      }
    }),
    skip: writes
        ? false
        : 'Writes require NEXTCLOUD_TEST_ALLOW_WRITES=true and credentials',
  );
}
