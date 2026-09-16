import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cookbook/core/api/cookbook_api_service.dart';
import 'package:cookbook/core/api/cookbook_capabilities.dart';
import 'package:cookbook/core/auth/credential_store.dart';
import 'package:cookbook/core/auth/nextcloud_auth_service.dart';
import 'package:cookbook/core/errors/app_failure.dart';
import 'package:cookbook/core/networking/nextcloud_client.dart';
import 'package:cookbook/core/networking/server_address.dart';
import 'package:cookbook/features/recipes/domain/recipe.dart';
import 'support/mock_http.dart';

void main() {
  final server = ServerAddress.parse('https://cloud.test/nextcloud');
  test(
    'v2 initiation and polling follow supplied endpoints with form token',
    () async {
      var polls = 0;
      final logs = <String>[];
      final client = NextcloudClient(
        server,
        diagnostics: logs.add,
        dio: mockDio((options) {
          expect(options.headers.containsKey('Authorization'), false);
          if (options.uri.path.endsWith('/login/v2')) {
            return jsonResponse({
              'login': 'https://cloud.test/nextcloud/login/flow/secret',
              'poll': {
                'endpoint': 'https://cloud.test/nextcloud/custom/poll',
                'token': 'secret',
              },
            });
          }
          expect(options.uri.path, '/nextcloud/custom/poll');
          expect(options.contentType, Headers.formUrlEncodedContentType);
          expect(options.data, {'token': 'secret'});
          return ++polls == 1
              ? jsonResponse({}, status: 404)
              : jsonResponse({
                  'server': server.toString(),
                  'loginName': 'cook',
                  'appPassword': 'private',
                });
        }),
      );
      final auth = NextcloudAuthService(client), cancel = CancelToken();
      final challenge = await auth.begin(cancel);
      expect(await auth.poll(challenge, cancel), isNull);
      final result = await auth.poll(challenge, cancel);
      expect(result!.credentials.appPassword, 'private');
      expect('$challenge $result $logs', isNot(contains('secret')));
      expect('$challenge $result $logs', isNot(contains('private')));
    },
  );
  test('login rejects insecure and cross-origin challenge URLs', () async {
    for (final endpoint in [
      'https://evil.test/poll',
      'http://cloud.test/poll',
      'https://u:p@cloud.test/poll',
    ]) {
      final auth = NextcloudAuthService(
        NextcloudClient(
          server,
          dio: mockDio(
            (_) => jsonResponse({
              'login': 'https://cloud.test/login',
              'poll': {'endpoint': endpoint, 'token': 'secret'},
            }),
          ),
        ),
      );
      await expectLater(auth.begin(CancelToken()), throwsA(isA<AppFailure>()));
    }
  });
  test(
    'authenticated transport rejects cross-origin and does not follow redirects or retry POST',
    () async {
      var calls = 0;
      final client = NextcloudClient(
        server,
        credentials: const AppCredentials('cook', 'private'),
        dio: mockDio((options) {
          calls++;
          expect(options.followRedirects, false);
          expect(
            options.headers['Authorization'],
            'Basic ${base64Encode(utf8.encode('cook:private'))}',
          );
          return jsonResponse({'msg': 'private'}, status: 500);
        }),
      );
      await expectLater(
        client.request('GET', Uri.parse('https://evil.test/')),
        throwsA(isA<AppFailure>()),
      );
      expect(calls, 0);
      await expectLater(
        client.request('POST', server.cookbook(['v1', 'recipes']), data: {}),
        throwsA(isA<AppFailure>()),
      );
      expect(calls, 1);
    },
  );
  test(
    'version discovery supports old endpoint and rejects unknown epochs',
    () async {
      for (final epoch in [0, 1]) {
        final service = CookbookCapabilityService(
          NextcloudClient(
            server,
            dio: mockDio(
              (_) => jsonResponse({
                'api_version': {'epoch': epoch, 'major': 1, 'minor': 2},
                'cookbook_version': [0, 11, 10],
              }),
            ),
          ),
        );
        if (epoch == 0) {
          expect((await service.discover()).versionLabel, '0.1.2');
        } else {
          await expectLater(
            service.discover(),
            throwsA(
              isA<AppFailure>().having(
                (e) => e.kind,
                'kind',
                FailureKind.unsupported,
              ),
            ),
          );
        }
      }
    },
  );
  test(
    'deprecated version 404 falls back to authenticated OCS envelope',
    () async {
      final client = NextcloudClient(
        server,
        dio: mockDio(
          (options) => options.uri.path.endsWith('/api/version')
              ? jsonResponse({}, status: 404)
              : jsonResponse({
                  'ocs': {
                    'meta': {'statuscode': 200},
                    'data': {
                      'capabilities': {
                        'cookbook': {
                          'api_version': {'epoch': 0, 'major': 1, 'minor': 3},
                        },
                      },
                    },
                  },
                }),
        ),
      );
      expect(
        (await CookbookCapabilityService(client).discover()).versionLabel,
        '0.1.3',
      );
    },
  );
  test(
    'malformed list and duplicate IDs are not treated as an empty library',
    () {
      for (final json in [
        {},
        [
          {'name': 'missing ID'},
        ],
        [
          {'id': '1', 'name': 'A'},
          {'id': '1', 'name': 'B'},
        ],
      ]) {
        expect(
          () => CookbookApiService.parseStubs(json),
          throwsA(isA<AppFailure>()),
        );
      }
      expect(CookbookApiService.parseStubs([]), isEmpty);
      expect(
        CookbookApiService.parseStubs([
          {'recipe_id': 12, 'name': 'Old'},
        ]).single.id,
        '12',
      );
    },
  );
  test(
    'recipe IDs and category names are encoded; images use external API',
    () async {
      final paths = <String>[];
      final api = CookbookApiService(
        NextcloudClient(
          server,
          dio: mockDio((options) {
            paths.add(options.uri.toString());
            if (options.uri.path.endsWith('/image')) {
              expect(options.headers['Accept'], 'image/jpeg');
              return ResponseBody.fromBytes([1, 2], 200);
            }
            return jsonResponse([]);
          }),
        ),
        const CookbookCapabilities(0, 1, 2),
      );
      await api.inCategory('Soup / stew');
      await api.image('42');
      expect(paths.first, contains('Soup%20%2F%20stew'));
      expect(paths.last, contains('/api/v1/recipes/42/image?size=thumb'));
      expect(paths.join(), isNot(contains('/webapp/')));
    },
  );
  test('independently authored synthetic imports retain complete JSON', () {
    for (final file in Directory(
      'test/fixtures',
    ).listSync().whereType<File>().where((f) => f.path.contains('imported'))) {
      final json = (jsonDecode(file.readAsStringSync()) as Map)
          .cast<String, Object?>();
      expect(Recipe.fromJson(json).toJson(), json);
      expect(Recipe.fromJson(json).instructions, isNotEmpty);
    }
  });
  test('mutation IDs preserve server identity and unknown metadata', () async {
    final bodies = <Map<String, Object?>>[];
    final api = CookbookApiService(
      NextcloudClient(
        server,
        dio: mockDio((options) {
          bodies.add((options.data as Map).cast<String, Object?>());
          return jsonResponse(42);
        }),
      ),
      const CookbookCapabilities(0, 1, 2),
    );
    final value = Recipe.fromJson({
      'id': 'wrong',
      'recipe_id': 7,
      'name': 'Soup',
      'future': {'keep': true},
    });
    expect(await api.create(value), '42');
    expect(bodies.first.containsKey('id'), false);
    expect(bodies.first.containsKey('recipe_id'), false);
    await api.update('42', value);
    expect(bodies.last['id'], '42');
    expect(bodies.last['future'], {'keep': true});
    expect(value.id, 'wrong');
  });
  test('cancelled browser polling sends no request', () async {
    var called = false;
    final auth = NextcloudAuthService(
      NextcloudClient(
        server,
        dio: mockDio((_) {
          called = true;
          return jsonResponse({});
        }),
      ),
    );
    final cancel = CancelToken()..cancel();
    await expectLater(
      auth.waitForApproval(
        LoginChallenge(server.uri, server.uri, 'secret'),
        cancel,
      ),
      throwsA(
        isA<AppFailure>().having((e) => e.kind, 'kind', FailureKind.cancelled),
      ),
    );
    expect(called, false);
  });
  test(
    'actual PublicCapabilities source uses api-version with a hyphen',
    () async {
      final client = NextcloudClient(
        server,
        dio: mockDio(
          (options) => options.uri.path.endsWith('/api/version')
              ? jsonResponse({}, status: 404)
              : jsonResponse({
                  'ocs': {
                    'meta': {'statuscode': 200},
                    'data': {
                      'capabilities': {
                        'cookbook': {
                          'api-version': {'epoch': 0, 'major': 1, 'minor': 2},
                          'version': [0, 11, 10],
                        },
                      },
                    },
                  },
                }),
        ),
      );
      final caps = await CookbookCapabilityService(client).discover();
      expect(caps.versionLabel, '0.1.2');
      expect(caps.appVersion, '0.11.10');
    },
  );
  test('OCS failure envelope does not masquerade as capabilities', () async {
    final service = CookbookCapabilityService(
      NextcloudClient(
        server,
        dio: mockDio(
          (options) => options.uri.path.endsWith('/api/version')
              ? jsonResponse({}, status: 404)
              : jsonResponse({
                  'ocs': {
                    'meta': {'statuscode': 401},
                    'data': {'capabilities': {}},
                  },
                }),
        ),
      ),
    );
    await expectLater(
      service.discover(),
      throwsA(
        isA<AppFailure>().having(
          (e) => e.kind,
          'kind',
          FailureKind.authentication,
        ),
      ),
    );
  });
  test(
    'checked-in stub, taxonomy and version fixtures match the external contract',
    () async {
      Object? fixture(String name) =>
          jsonDecode(File('test/fixtures/$name.json').readAsStringSync());
      final client = NextcloudClient(
        server,
        dio: mockDio((options) {
          final last = options.uri.pathSegments.last;
          return jsonResponse(
            fixture(last == 'recipes' ? 'recipe-list' : last),
          );
        }),
      );
      final caps = await CookbookCapabilityService(client).discover();
      final api = CookbookApiService(client, caps);
      expect((await api.listRecipes()).single.id, '42');
      expect((await api.categories()).last['name'], '*');
      expect((await api.keywords()).first['recipe_count'], 1);
    },
  );
}
