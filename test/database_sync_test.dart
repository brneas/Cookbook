import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cookbook/core/api/cookbook_api.dart';
import 'package:cookbook/core/auth/credential_store.dart';
import 'package:cookbook/core/auth/nextcloud_auth_service.dart';
import 'package:cookbook/core/database/app_database.dart';
import 'package:cookbook/core/errors/app_failure.dart';
import 'package:cookbook/core/networking/nextcloud_client.dart';
import 'package:cookbook/core/networking/server_address.dart';
import 'package:cookbook/features/account/data/account_repository.dart';
import 'package:cookbook/features/recipes/domain/recipe.dart';
import 'package:cookbook/features/sync/data/read_sync.dart';
import 'support/mock_http.dart';

class MemoryCredentials implements CredentialStore {
  final values = <String, String>{};
  @override
  Future<void> write(String id, String value) async {
    values[id] = value;
  }

  @override
  Future<String?> read(String id) async => values[id];
  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }
}

class ReadApi implements CookbookApi {
  List<Recipe> stubs = [];
  Map<String, Recipe> details = {};
  int detailCalls = 0;
  bool failList = false;
  @override
  Future<List<Recipe>> listRecipes() async {
    if (failList) throw const AppFailure(FailureKind.network);
    return stubs;
  }

  @override
  Future<Recipe> recipe(String id) async {
    detailCalls++;
    return details[id]!;
  }

  @override
  Future<List<JsonMap>> categories() async => [
    {'name': 'Soup', 'recipe_count': 1},
  ];
  @override
  Future<List<JsonMap>> keywords() async => [
    {'name': 'easy', 'recipe_count': 1},
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected API call in read sync test');
}

void main() {
  sqfliteFfiInit();
  late AppDatabase database;
  late AccountRepository repository;
  late MemoryCredentials credentials;
  late Account account;
  final server = ServerAddress.parse('https://cloud.test/nextcloud');
  setUp(() async {
    database = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    credentials = MemoryCredentials();
    repository = AccountRepository(
      database,
      credentials,
      clientFactory: (account) async => NextcloudClient(
        server,
        dio: mockDio((_) => jsonResponse({}, status: 500)),
      ),
    );
    account = await repository.add(
      LoginResult(server, const AppCredentials('cook', 'PRIVATE_SECRET')),
    );
  });
  tearDown(() async => database.close());
  Recipe recipe(String name, String modified) => Recipe.fromJson({
    'id': '42',
    'name': name,
    'dateModified': modified,
    'recipeCategory': 'Soup',
    'keywords': 'easy',
    'recipeIngredient': ['1 cup water'],
  });
  test(
    'credentials never enter SQLite; account and private cache removal cascade even if revoke fails',
    () async {
      final accounts = await database.db.query('accounts');
      expect(jsonEncode(accounts), isNot(contains('PRIVATE_SECRET')));
      expect(await credentials.read(account.id), 'PRIVATE_SECRET');
      await database.db.insert('recipes', {
        'account_id': account.id,
        'id': '42',
        'name': 'Soup',
        'stub_json': '{}',
      });
      await database.db.insert('cooking_sessions', {
        'account_id': account.id,
        'recipe_id': '42',
        'state_json': '{}',
      });
      await database.db.insert('pending_operations', {
        'account_id': account.id,
        'recipe_id': '42',
        'kind': 'update',
        'created_at': 'now',
      });
      expect(await repository.remove(account), false);
      expect(credentials.values, isEmpty);
      for (final table in [
        'accounts',
        'recipes',
        'cooking_sessions',
        'pending_operations',
      ]) {
        expect(await database.db.query(table), isEmpty);
      }
    },
  );
  test('interrupted removal is completed on restart', () async {
    await database.db.update('accounts', {'removing': 1});
    expect(await repository.load(), isNull);
    expect(credentials.values, isEmpty);
  });
  test(
    'account removal can stop hydration without damaging cached rows',
    () async {
      final api = ReadApi();
      final value = recipe('Soup', '2026-01-01');
      api.stubs = [value];
      api.details = {'42': value};
      final sync = ReadSync(database, api, account.id);
      await sync.run();
      await expectLater(
        sync.run(shouldCancel: () => true),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
      expect((await database.recipes(account.id)).single.name, 'Soup');
    },
  );
  test(
    'new and changed server recipes hydrate; unchanged details are not downloaded twice',
    () async {
      final api = ReadApi();
      final first = recipe('Soup', '2026-01-01T12:00:00+0000');
      api.stubs = [first];
      api.details = {'42': first};
      final sync = ReadSync(database, api, account.id);
      await sync.run();
      await sync.run();
      expect(api.detailCalls, 1);
      final second = recipe('Stew', '2026-01-02T12:00:00Z');
      api.stubs = [second];
      api.details = {'42': second};
      await sync.run();
      expect(api.detailCalls, 2);
      expect((await database.recipes(account.id)).single.name, 'Stew');
      expect(
        (await database.db.query('sync_metadata')).single['last_success'],
        isNotNull,
      );
    },
  );
  test(
    'offline or malformed listing preserves usable library and successful timestamp',
    () async {
      final api = ReadApi();
      final value = recipe('Soup', '2026-01-01');
      api.stubs = [value];
      api.details = {'42': value};
      final sync = ReadSync(database, api, account.id);
      await sync.run();
      final stamp = (await database.db.query(
        'sync_metadata',
      )).single['last_success'];
      api.failList = true;
      await expectLater(sync.run(), throwsA(isA<AppFailure>()));
      expect((await database.recipes(account.id)).single.name, 'Soup');
      expect(
        (await database.db.query('sync_metadata')).single['last_success'],
        stamp,
      );
      api.failList = false;
      api.stubs = [value, value];
      await expectLater(sync.run(), throwsA(isA<AppFailure>()));
      expect((await database.db.query('recipes')).single['missing'], 0);
    },
  );
  test(
    'empty server listing marks missing but never destroys saved recipes',
    () async {
      final api = ReadApi();
      final value = recipe('Soup', '2026-01-01');
      api.stubs = [value];
      api.details = {'42': value};
      final sync = ReadSync(database, api, account.id);
      await sync.run();
      api.stubs = [];
      await sync.run();
      expect((await database.recipes(account.id)).single.name, 'Soup');
      expect((await database.db.query('recipes')).single['missing'], 1);
    },
  );
  test(
    'dirty local version and queue are protected from changed server reads',
    () async {
      final api = ReadApi();
      final value = recipe('Soup', '2026-01-01');
      api.stubs = [value];
      api.details = {'42': value};
      final sync = ReadSync(database, api, account.id);
      await sync.run();
      final local = value.patch({'name': 'Local soup'});
      await database.db.update('recipes', {
        'dirty': 1,
        'name': local.name,
        'detail_json': jsonEncode(local.toJson()),
      });
      await database.db.insert('pending_operations', {
        'account_id': account.id,
        'recipe_id': '42',
        'kind': 'update',
        'base_json': jsonEncode(value.toJson()),
        'payload_json': jsonEncode(local.toJson()),
        'created_at': 'now',
      });
      api.stubs = [recipe('Server soup', '2026-01-02')];
      await sync.run();
      expect((await database.recipes(account.id)).single.name, 'Local soup');
      expect(
        (await database.db.query('pending_operations')).single['state'],
        'queued',
      );
      expect(api.detailCalls, 1);
    },
  );
  test(
    'local SQL search escapes wildcard input and respects account boundaries',
    () async {
      final api = ReadApi();
      final value = recipe('100% Soup', '2026-01-01');
      api.stubs = [value];
      api.details = {'42': value};
      await ReadSync(database, api, account.id).run();
      expect(await database.recipes(account.id, query: '%'), hasLength(1));
      expect(await database.recipes(account.id, query: '_'), isEmpty);
      expect(await database.recipes('different-account'), isEmpty);
    },
  );
}
