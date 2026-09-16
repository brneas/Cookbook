import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cookbook/core/api/cookbook_api_service.dart';
import 'package:cookbook/core/api/cookbook_capabilities.dart';
import 'package:cookbook/core/auth/credential_store.dart';
import 'package:cookbook/core/networking/nextcloud_client.dart';
import 'package:cookbook/core/networking/server_address.dart';
import 'package:cookbook/core/errors/app_failure.dart';
import 'package:cookbook/features/files/data/nextcloud_files_service.dart';
import 'package:cookbook/features/recipes/domain/recipe.dart';
import 'package:cookbook/features/settings/data/server_cookbook_settings.dart';
import 'support/mock_http.dart';

void main() {
  final server = ServerAddress.parse('https://cloud.test/nextcloud');
  test(
    'Files resolves canonical OCS UID then authenticated subdirectory PROPFIND',
    () async {
      final calls = <String>[];
      final client = NextcloudClient(
        server,
        credentials: const AppCredentials(
          'email@example.test',
          'synthetic-app-password',
        ),
        dio: mockDio((request) {
          calls.add(request.method);
          expect(
            request.headers['Authorization'],
            'Basic ${base64Encode(utf8.encode('email@example.test:synthetic-app-password'))}',
          );
          if (request.method == 'GET') {
            expect(request.headers['OCS-APIRequest'], 'true');
            return jsonResponse({
              'ocs': {
                'meta': {'status': 'ok', 'statuscode': 100},
                'data': {'id': 'canonical user'},
              },
            });
          }
          expect(request.uri.pathSegments, [
            'nextcloud',
            'remote.php',
            'dav',
            'files',
            'canonical user',
            'Photos',
            '',
          ]);
          expect(request.headers['Depth'], '1');
          expect(request.headers['Accept'], 'application/xml');
          expect(request.data, contains('resourcetype'));
          return ResponseBody.fromString(
            '<d:multistatus xmlns:d="DAV:"><d:response><d:href>/nextcloud/remote.php/dav/files/canonical%20user/Photos/pie.png</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontenttype>image/png</d:getcontenttype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>',
            207,
            headers: {
              Headers.contentTypeHeader: ['application/xml'],
            },
          );
        }),
      );
      final service = NextcloudFilesService(client);
      expect((await service.list('/Photos')).single.path, '/Photos/pie.png');
      await service.list('/Photos');
      expect(calls, ['GET', 'PROPFIND', 'PROPFIND']);
    },
  );
  for (final status in [401, 403, 500]) {
    test('Files HTTP $status is an HTTP failure', () async {
      final client = NextcloudClient(
        server,
        dio: mockDio((_) => jsonResponse({}, status: status)),
      );
      await expectLater(
        NextcloudFilesService(client).list('/'),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.diagnostic?.status,
            'status',
            status,
          ),
        ),
      );
    });
  }
  for (final image in [
    'https://images.example.test/pie.jpg',
    '/Photos/Pie with cream.png',
  ]) {
    test(
      'recipe save sends image unchanged through public Cookbook API: $image',
      () async {
        final api = CookbookApiService(
          NextcloudClient(
            server,
            dio: mockDio((request) {
              expect(request.method, 'PUT');
              expect(
                request.uri.path,
                '/nextcloud/index.php/apps/cookbook/api/v1/recipes/42',
              );
              expect((request.data as Map)['image'], image);
              return jsonResponse('42');
            }),
          ),
          const CookbookCapabilities(0, 1, 2),
        );
        await api.update(
          '42',
          Recipe.fromJson({'id': '42', 'name': 'Pie', 'image': image}),
        );
      },
    );
  }
  test(
    'category rename configuration and rescan use public contracts',
    () async {
      final requests = <RequestOptions>[];
      final api = CookbookApiService(
        NextcloudClient(
          server,
          dio: mockDio((r) {
            requests.add(r);
            return jsonResponse({});
          }),
        ),
        const CookbookCapabilities(0, 1, 2),
      );
      await api.renameCategory('Soup / stew', 'Dinners');
      await api.configure({
        'folder': '/Shared Recipes',
        'update_interval': 10,
        'print_image': false,
        'visibleInfoBlocks': {'tools': false},
      });
      await api.reindex();
      expect(requests.map((r) => r.method), ['PUT', 'POST', 'POST']);
      expect(requests[0].uri.pathSegments.last, 'Soup / stew');
      expect(requests[0].data, {'name': 'Dinners'});
      expect(requests[1].uri.path, endsWith('/api/v1/config'));
      expect(
        (requests[1].data as Map).keys,
        containsAll([
          'folder',
          'update_interval',
          'print_image',
          'visibleInfoBlocks',
        ]),
      );
      expect(requests[2].uri.path, endsWith('/api/v1/reindex'));
      expect(requests.any((r) => r.uri.path.contains('/webapp/')), false);
    },
  );
  for (final block in infoBlocks.keys) {
    test(
      'visible block $block independently hides and preserves other values',
      () {
        final config = ServerCookbookSettings({
          'visibleInfoBlocks': {block: false, 'future': true},
        });
        expect(config.visible(block), false);
        expect(config.visible('unspecified'), true);
        expect(
          (config.blockChange(block, true)['visibleInfoBlocks']
              as Map)['future'],
          true,
        );
      },
    );
  }
}
