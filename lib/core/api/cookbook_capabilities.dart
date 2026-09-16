import '../../features/recipes/domain/recipe.dart';
import '../errors/app_failure.dart';
import '../networking/nextcloud_client.dart';
import 'json_response.dart';

final class CookbookCapabilities {
  const CookbookCapabilities(
    this.epoch,
    this.major,
    this.minor, {
    this.appVersion,
  });
  final int epoch, major, minor;
  final String? appVersion;
  bool get supported => epoch == 0 && major == 1 && minor >= 0;
  bool get canRead => supported;
  bool get canManage => supported;
  bool get canConfigure => supported;
  String get versionLabel => '$epoch.$major.$minor';
  JsonMap toJson() => {
    'epoch': epoch,
    'major': major,
    'minor': minor,
    'appVersion': appVersion,
  };
  factory CookbookCapabilities.fromJson(JsonMap json) {
    if (json['epoch'] is! int ||
        json['major'] is! int ||
        json['minor'] is! int) {
      throw const AppFailure(FailureKind.malformedResponse);
    }
    return CookbookCapabilities(
      json['epoch'] as int,
      json['major'] as int,
      json['minor'] as int,
      appVersion: json['appVersion'] as String?,
    );
  }
}

final class CookbookCapabilityService {
  CookbookCapabilityService(this.client);
  final NextcloudClient client;
  Future<CookbookCapabilities> discover({
    JsonMap? nextcloudCapabilities,
  }) async {
    JsonMap version;
    try {
      if (nextcloudCapabilities?['cookbook'] is Map) {
        version = jsonObject(nextcloudCapabilities!['cookbook']);
      } else {
        version = jsonObject(
          await client.request('GET', client.server.cookbook(['version'])),
        );
      }
    } on AppFailure catch (error) {
      if (error.kind != FailureKind.notFound) rethrow;
      final data = jsonObject(
        ocsData(
          await client.request(
            'GET',
            client.server.ocs(['cloud', 'capabilities']),
          ),
        ),
      );
      final apps = jsonObject(data['capabilities']);
      if (apps['cookbook'] == null) {
        throw client.protocolFailure(
          'cookbookCapabilityMissing',
          kind: FailureKind.unavailable,
        );
      }
      version = jsonObject(apps['cookbook']);
    }
    // Nextcloud public capabilities use a hyphen; the OpenAPI schema uses an underscore.
    final api = jsonObject(version['api_version'] ?? version['api-version']);
    final rawApp = version['cookbook_version'] ?? version['version'];
    final result = CookbookCapabilities.fromJson({
      ...api,
      'appVersion': rawApp is List ? rawApp.join('.') : null,
    });
    if (!result.supported) {
      throw client.protocolFailure(
        'unsupportedCookbookApi',
        kind: FailureKind.unsupported,
      );
    }
    return result;
  }
}
