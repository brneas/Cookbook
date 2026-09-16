import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:cookbook/core/auth/credential_store.dart';
import 'package:cookbook/core/errors/app_failure.dart';
import 'package:cookbook/core/networking/nextcloud_client.dart';
import 'package:cookbook/core/networking/server_address.dart';

void main() {
  test('normalization keeps reverse proxy subdirectory and encodes segments', () {
    final server = ServerAddress.parse(
      ' cloud.example.com/nextcloud/index.php/ ',
    );
    expect(server.toString(), 'https://cloud.example.com/nextcloud/');
    expect(
      server.cookbook(['v1', 'category', 'A/B']).toString(),
      'https://cloud.example.com/nextcloud/index.php/apps/cookbook/api/v1/category/A%2FB',
    );
    expect(
      server.ocs(['cloud', 'capabilities']).path,
      '/nextcloud/ocs/v2.php/cloud/capabilities',
    );
  });
  test('reject unsafe server URLs', () {
    for (final url in [
      '',
      'http://cloud.example.com',
      'https://u:secret@cloud.test',
      'https://cloud.test?token=x',
      'https://cloud.test/#x',
      'https://cloud.test/../other',
    ]) {
      expect(() => ServerAddress.parse(url), throwsA(isA<AppFailure>()));
    }
  });
  test('credentials and raw network errors cannot enter diagnostics', () {
    const credentials = AppCredentials('user', 'TOP_SECRET');
    final error = DioException(
      requestOptions: RequestOptions(
        path: 'https://secret.test',
        headers: {'Authorization': 'TOP_SECRET'},
      ),
      message: 'TOP_SECRET',
    );
    expect(
      '$credentials ${translateNetworkError(error)} ${requestDiagnostic('TOP_SECRET', 500)}',
      isNot(contains('TOP_SECRET')),
    );
  });
}
