import '../api/json_response.dart';
import '../networking/nextcloud_client.dart';
import '../errors/app_failure.dart';
import '../theme/server_theme.dart';
import 'auth_diagnostics.dart';

class NextcloudInfo {
  const NextcloudInfo(this.version, this.theme, this.capabilities);
  final String? version;
  final ServerTheme theme;
  final Map<String, Object?> capabilities;
}

class NextcloudVerification {
  NextcloudVerification(this.client);
  final NextcloudClient client;
  Future<void> verify() async {
    client.stage = AuthStage.verifyingCredentials;
    try {
      final user = jsonObject(
        ocsData(
          await client.request('GET', client.server.ocs(['cloud', 'user'])),
        ),
      );
      if (user['id'] is! String || (user['id'] as String).isEmpty) {
        throw client.protocolFailure('missingAuthenticatedUserId');
      }
    } on AppFailure catch (e) {
      throw e.diagnostic != null
          ? e
          : AppFailure(
              e.kind,
              diagnostic: (client.lastDiagnostic ?? const RequestDiagnostic())
                  .withReason(
                    'ocsUserEnvelopeRejected${e.status == null ? "" : "_ocsStatus${e.status}"}',
                  ),
            );
    }
  }

  Future<NextcloudInfo> capabilities() async {
    client.stage = AuthStage.loadingNextcloudCapabilities;
    try {
      final data = jsonObject(
        ocsData(
          await client.request(
            'GET',
            client.server.ocs(['cloud', 'capabilities']),
          ),
        ),
      );
      final caps = jsonObject(data['capabilities']);
      final version = data['version'];
      final raw = version is Map ? version['string'] : null;
      return NextcloudInfo(
        raw is String && RegExp(r'^\d+(\.\d+){1,3}$').hasMatch(raw)
            ? raw
            : null,
        ServerTheme.parse(caps['theming']),
        caps,
      );
    } on AppFailure catch (e) {
      throw e.diagnostic != null
          ? e
          : AppFailure(
              e.kind,
              diagnostic: (client.lastDiagnostic ?? const RequestDiagnostic())
                  .withReason(
                    'ocsCapabilitiesEnvelopeRejected${e.status == null ? "" : "_ocsStatus${e.status}"}',
                  ),
            );
    }
  }
}

/// The fallback deliberately accepts only Nextcloud's generated token formats,
/// with an explicit user assertion in the UI. Basic auth cannot prove token type.
bool looksLikeAppPassword(String value) =>
    RegExp(r'^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}$').hasMatch(value) ||
    RegExp(r'^[A-Za-z0-9]{72}$').hasMatch(value);
