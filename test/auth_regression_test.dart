import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cookbook/core/auth/nextcloud_auth_service.dart';
import 'package:cookbook/core/auth/nextcloud_verification.dart';
import 'package:cookbook/core/auth/credential_store.dart';
import 'package:cookbook/core/auth/auth_diagnostics.dart';
import 'package:cookbook/core/api/cookbook_capabilities.dart';
import 'package:cookbook/core/networking/nextcloud_client.dart';
import 'package:cookbook/core/networking/server_address.dart';
import 'package:cookbook/core/errors/app_failure.dart';
import 'support/mock_http.dart';

void main() {
  final server = ServerAddress.parse('https://cloud.test/nextcloud');
  Map<String, Object> challenge() => {
    'login': 'https://cloud.test/nextcloud/index.php/login/v2/flow/TOP_SECRET',
    'poll': {
      'token': 'TOP_SECRET',
      'endpoint':
          'https://cloud.test/nextcloud/login/v2/poll?secret=TOP_SECRET',
    },
  };
  final credentials = {
    'server': 'https://cloud.test/nextcloud',
    'loginName': 'cook',
    'appPassword': 'PRIVATE_PASSWORD',
  };
  for (final value in [
    'https://cloud.test',
    'https://cloud.test/',
    'HTTPS://CLOUD.TEST:443',
    'https://cloud.test/nextcloud',
    'https://cloud.test/nextcloud/',
    'https://CLOUD.TEST:443/nextcloud',
  ]) {
    test('normalizes HTTPS origin and retains installation path: $value', () {
      final s = ServerAddress.parse(' $value ');
      expect(s.sameOrigin(Uri.parse('https://CLOUD.TEST:443/elsewhere')), true);
      expect(
        s.route(['index.php', 'login', 'v2']).path,
        value.contains('nextcloud')
            ? '/nextcloud/index.php/login/v2'
            : '/index.php/login/v2',
      );
      expect(s.uri.host, 'cloud.test');
    });
  }
  test('start uses bodyless anonymous POST and exact returned URLs', () async {
    final client = NextcloudClient(
      server,
      dio: mockDio((o) {
        expect(o.method, 'POST');
        expect(o.data, null);
        expect(o.headers.containsKey('Authorization'), false);
        expect(o.headers.containsKey('OCS-APIRequest'), false);
        return jsonResponse(challenge());
      }),
    );
    final c = await NextcloudAuthService(client).begin(CancelToken());
    expect(c.loginUri.toString(), challenge()['login']);
    expect(c.pollUri.query, 'secret=TOP_SECRET');
  });
  for (final code in [301, 302, 307, 308]) {
    test(
      'login initialization safely follows same-origin $code preserving POST',
      () async {
        var calls = 0;
        final client = NextcloudClient(
          server,
          dio: mockDio((o) {
            expect(o.method, 'POST');
            if (++calls == 1) {
              return ResponseBody.fromString(
                '',
                code,
                headers: {
                  'location': ['https://CLOUD.TEST:443/nextcloud/login/v2'],
                },
              );
            }
            expect(o.uri.path, '/nextcloud/login/v2');
            return jsonResponse(challenge());
          }),
        );
        expect(
          (await NextcloudAuthService(client).begin(CancelToken())).token,
          'TOP_SECRET',
        );
        expect(calls, 2);
      },
    );
  }
  test('cross-origin redirect never forwards credentials or token', () async {
    var calls = 0;
    final client = NextcloudClient(
      server,
      credentials: const AppCredentials('cook', 'SECRET'),
      dio: mockDio((o) {
        calls++;
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['https://evil.test/SECRET'],
          },
        );
      }),
    );
    await expectLater(
      client.request('GET', server.ocs(['cloud', 'user'])),
      throwsA(
        isA<AppFailure>().having((e) => e.kind, 'kind', FailureKind.redirect),
      ),
    );
    expect(calls, 1);
    expect(client.lastDiagnostic!.text, isNot(contains('SECRET')));
    expect(client.lastDiagnostic!.text, isNot(contains('evil.test')));
  });
  test(
    'redirect loop is bounded and mutation POST is never replayed',
    () async {
      var calls = 0;
      final client = NextcloudClient(
        server,
        dio: mockDio((o) {
          calls++;
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': ['/nextcloud/index.php/login/v2'],
            },
          );
        }),
      );
      await expectLater(
        NextcloudAuthService(client).begin(CancelToken()),
        throwsA(isA<AppFailure>()),
      );
      expect(calls, 6);
      calls = 0;
      await expectLater(
        client.request('POST', server.cookbook(['v1', 'recipes']), data: {}),
        throwsA(isA<AppFailure>()),
      );
      expect(calls, 1);
    },
  );
  for (final code in [403, 404, 405, 500]) {
    test(
      'start HTTP $code proves server reached even for invalid HTML body',
      () async {
        final client = NextcloudClient(
          server,
          dio: mockDio(
            (_) => ResponseBody.fromString(
              '<html>secret error</html>',
              code,
              headers: {
                'content-type': ['application/json'],
              },
            ),
          ),
        );
        await expectLater(
          NextcloudAuthService(client).begin(CancelToken()),
          throwsA(
            isA<AppFailure>()
                .having((e) => e.status, 'HTTP', code)
                .having((e) => e.kind, 'kind', isNot(FailureKind.network)),
          ),
        );
        expect(client.lastDiagnostic!.stage, AuthStage.startingLoginFlow);
        expect(client.lastDiagnostic!.text, isNot(contains('secret error')));
      },
    );
  }
  for (final entry in {
    'invalidJson': '{',
    'missingLogin':
        '{"poll":{"token":"SECRET","endpoint":"https://cloud.test/poll"}}',
    'missingPoll': '{"login":"https://cloud.test/login"}',
  }.entries) {
    test('initialization diagnoses ${entry.key}', () async {
      final client = NextcloudClient(
        server,
        dio: mockDio((_) => ResponseBody.fromString(entry.value, 200)),
      );
      await expectLater(
        NextcloudAuthService(client).begin(CancelToken()),
        throwsA(
          isA<AppFailure>()
              .having((e) => e.kind, 'kind', FailureKind.malformedResponse)
              .having((e) => e.diagnostic?.reason, 'reason', isNotNull),
        ),
      );
    });
  }
  for (final type in [
    DioExceptionType.connectionTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.badCertificate,
    DioExceptionType.connectionError,
  ]) {
    test('start distinguishes transport category ${type.name}', () async {
      final client = NextcloudClient(
        server,
        dio: mockDio(
          (o) => throw DioException(
            requestOptions: o,
            type: type,
            error: type == DioExceptionType.connectionError
                ? const SocketException('Failed host lookup: TOP_SECRET')
                : null,
            message: 'TOP_SECRET',
          ),
        ),
      );
      await expectLater(
        NextcloudAuthService(client).begin(CancelToken()),
        throwsA(isA<AppFailure>()),
      );
      expect(client.lastDiagnostic!.status, null);
      expect(client.lastDiagnostic!.dioCategory, type.name);
      expect(client.lastDiagnostic!.text, isNot(contains('TOP_SECRET')));
      if (type == DioExceptionType.connectionError) {
        expect(client.lastDiagnostic!.transport, 'dns');
      }
    });
  }
  test('three poll 404s then one 200 yield credentials exactly once', () async {
    var count = 0;
    var now = DateTime(2026);
    final client = NextcloudClient(
      server,
      dio: mockDio((o) {
        expect(o.contentType, Headers.formUrlEncodedContentType);
        expect(o.data, {'token': 'TOP_SECRET'});
        return ++count <= 3
            ? ResponseBody.fromString('not JSON', 404)
            : jsonResponse(credentials);
      }),
    );
    final auth = NextcloudAuthService(
      client,
      now: () => now,
      delay: (d) async {
        now = now.add(d);
      },
    );
    final c = LoginChallenge(
      Uri.parse('https://cloud.test/login/flow/TOP_SECRET'),
      Uri.parse('https://cloud.test/nextcloud/login/v2/poll?token=TOP_SECRET'),
      'TOP_SECRET',
      createdAt: now,
    );
    final result = await auth.waitForApproval(c, CancelToken());
    expect(result.credentials.loginName, 'cook');
    expect(count, 4);
    await expectLater(auth.poll(c, CancelToken()), throwsA(isA<AppFailure>()));
    expect(count, 4);
    expect(client.lastDiagnostic!.text, isNot(contains('TOP_SECRET')));
  });
  for (final status in [401, 403, 500]) {
    test(
      'poll $status is fatal HTTP error rather than pending or unreachable',
      () async {
        final auth = NextcloudAuthService(
          NextcloudClient(
            server,
            dio: mockDio((_) => jsonResponse({}, status: status)),
          ),
        );
        await expectLater(
          auth.poll(
            LoginChallenge(server.uri, server.uri, 'TOKEN'),
            CancelToken(),
          ),
          throwsA(
            isA<AppFailure>()
                .having((e) => e.status, 'status', status)
                .having((e) => e.kind, 'kind', isNot(FailureKind.network)),
          ),
        );
      },
    );
  }
  test('poll timeout can recover without restarting Login Flow', () async {
    var count = 0;
    var now = DateTime(2026);
    var transient = 0;
    final client = NextcloudClient(
      server,
      dio: mockDio((o) {
        if (++count == 1) {
          throw DioException(
            requestOptions: o,
            type: DioExceptionType.receiveTimeout,
          );
        }
        return jsonResponse(credentials);
      }),
    );
    final auth = NextcloudAuthService(
      client,
      now: () => now,
      delay: (d) async {
        now = now.add(d);
      },
    );
    await auth.waitForApproval(
      LoginChallenge(server.uri, server.uri, 'TOKEN', createdAt: now),
      CancelToken(),
      onTransient: (_) => transient++,
    );
    expect(count, 2);
    expect(transient, 1);
  });
  test('malformed 200 credentials is fatal and never polled again', () async {
    var count = 0;
    final auth = NextcloudAuthService(
      NextcloudClient(
        server,
        dio: mockDio((_) {
          count++;
          return jsonResponse({'server': server.toString()});
        }),
      ),
    );
    final c = LoginChallenge(server.uri, server.uri, 'TOKEN');
    await expectLater(auth.poll(c, CancelToken()), throwsA(isA<AppFailure>()));
    await expectLater(auth.poll(c, CancelToken()), throwsA(isA<AppFailure>()));
    expect(count, 1);
  });
  test('cancellation and expiration send no polling request', () async {
    var count = 0;
    final auth = NextcloudAuthService(
      NextcloudClient(
        server,
        dio: mockDio((_) {
          count++;
          return jsonResponse({});
        }),
      ),
    );
    await expectLater(
      auth.waitForApproval(
        LoginChallenge(server.uri, server.uri, 'TOKEN'),
        CancelToken()..cancel(),
      ),
      throwsA(
        isA<AppFailure>().having((e) => e.kind, 'kind', FailureKind.cancelled),
      ),
    );
    await expectLater(
      auth.waitForApproval(
        LoginChallenge(
          server.uri,
          server.uri,
          'TOKEN',
          createdAt: DateTime(2000),
        ),
        CancelToken(),
      ),
      throwsA(
        isA<AppFailure>().having((e) => e.kind, 'kind', FailureKind.expired),
      ),
    );
    expect(count, 0);
  });
  test(
    'Basic auth verification precedes capabilities and Cookbook can be absent',
    () async {
      final paths = <String>[];
      final client = NextcloudClient(
        server,
        credentials: const AppCredentials('cook', 'PRIVATE'),
        dio: mockDio((o) {
          paths.add(o.uri.path);
          expect(o.headers['OCS-APIRequest'], 'true');
          expect(o.headers['Authorization'], startsWith('Basic '));
          return jsonResponse({
            'ocs': {
              'meta': {'statuscode': 200},
              'data': o.uri.path.endsWith('/user')
                  ? {'id': 'cook'}
                  : {
                      'version': {'string': '32.0.1'},
                      'capabilities': {
                        'theming': {'color': '#1177AA'},
                      },
                    },
            },
          });
        }),
      );
      final verify = NextcloudVerification(client);
      await verify.verify();
      final info = await verify.capabilities();
      expect(info.version, '32.0.1');
      expect(paths.first, endsWith('/cloud/user'));
      expect(info.capabilities.containsKey('cookbook'), false);
    },
  );
  test('invalid credentials are rejected before capabilities', () async {
    final client = NextcloudClient(
      server,
      dio: mockDio((_) => jsonResponse({}, status: 401)),
    );
    await expectLater(
      NextcloudVerification(client).verify(),
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
    'supplied Cookbook capability avoids deprecated discovery request',
    () async {
      final client = NextcloudClient(
        server,
        dio: mockDio((_) => throw StateError('Unexpected request')),
      );
      final caps = await CookbookCapabilityService(client).discover(
        nextcloudCapabilities: {
          'cookbook': {
            'api-version': {'epoch': 0, 'major': 1, 'minor': 3},
          },
        },
      );
      expect(caps.versionLabel, '0.1.3');
    },
  );
  test(
    'normal account password is not accepted by manual token validation',
    () {
      expect(looksLikeAppPassword('my-normal-password'), false);
      expect(looksLikeAppPassword('abcde-fghij-klmno-pqrst-uvwxy'), true);
    },
  );
}
