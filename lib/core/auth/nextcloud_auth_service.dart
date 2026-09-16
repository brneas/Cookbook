import 'dart:async';
import 'package:dio/dio.dart';
import '../api/json_response.dart';
import '../errors/app_failure.dart';
import '../networking/nextcloud_client.dart';
import '../networking/server_address.dart';
import 'credential_store.dart';
import 'auth_diagnostics.dart';

final class LoginChallenge {
  LoginChallenge(this.loginUri, this.pollUri, this.token, {DateTime? createdAt})
    : createdAt = createdAt ?? DateTime.now();
  final Uri loginUri, pollUri;
  final String token;
  final DateTime createdAt;
  bool consumed = false;
  @override
  String toString() => 'LoginChallenge([redacted])';
}

final class LoginResult {
  const LoginResult(this.server, this.credentials);
  final ServerAddress server;
  final AppCredentials credentials;
  @override
  String toString() => 'LoginResult([redacted])';
}

final class NextcloudAuthService {
  NextcloudAuthService(
    this.client, {
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  }) : now = now ?? DateTime.now,
       delay = delay ?? Future<void>.delayed;
  final NextcloudClient client;
  final DateTime Function() now;
  final Future<void> Function(Duration) delay;
  Uri _safeUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !client.server.sameOrigin(uri) ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw client.protocolFailure(
        'returnedEndpointOriginRejected',
        kind: FailureKind.invalidUrl,
      );
    }
    return uri;
  }

  String _required(Map<String, Object?> value, String key) {
    if (value[key] is! String || (value[key] as String).isEmpty) {
      throw client.protocolFailure('missingOrInvalid_$key');
    }
    return value[key] as String;
  }

  Future<LoginChallenge> begin(CancelToken cancel) async {
    client.stage = AuthStage.startingLoginFlow;
    final raw = await client.request(
      'POST',
      client.server.route(['index.php', 'login', 'v2']),
      redirects: true,
      cancelToken: cancel,
    );
    if (raw is! Map) throw client.protocolFailure('loginResponseNotObject');
    final response = jsonObject(raw);
    if (response['poll'] is! Map) {
      throw client.protocolFailure('missingOrInvalid_poll');
    }
    final poll = jsonObject(response['poll']);
    return LoginChallenge(
      _safeUri(_required(response, 'login')),
      _safeUri(_required(poll, 'endpoint')),
      _required(poll, 'token'),
      createdAt: now(),
    );
  }

  Future<LoginResult?> poll(
    LoginChallenge challenge,
    CancelToken cancel,
  ) async {
    if (challenge.consumed) {
      throw client.protocolFailure('credentialsAlreadyReceived');
    }
    client.stage = AuthStage.waitingForAuthorization;
    Object? response;
    try {
      response = await client.request(
        'POST',
        challenge.pollUri,
        data: {'token': challenge.token},
        form: true,
        redirects: true,
        polling: true,
        cancelToken: cancel,
      );
    } on AppFailure catch (e) {
      if (e.diagnostic?.status == 200) challenge.consumed = true;
      rethrow;
    }
    if (response is LoginPending) return null;
    // A successful response is one-time, even if malformed. Never consume it twice.
    challenge.consumed = true;
    client.stage = AuthStage.receivingCredentials;
    if (response is! Map) throw client.protocolFailure('credentialsNotObject');
    final json = jsonObject(response);
    final server = ServerAddress.parse(_required(json, 'server'));
    if (!client.server.sameOrigin(server.uri)) {
      throw client.protocolFailure(
        'returnedServerOriginRejected',
        kind: FailureKind.invalidUrl,
      );
    }
    final login = _required(json, 'loginName');
    if (login.contains(':')) throw client.protocolFailure('invalidLoginName');
    return LoginResult(
      server,
      AppCredentials(login, _required(json, 'appPassword')),
    );
  }

  Future<LoginResult> waitForApproval(
    LoginChallenge challenge,
    CancelToken cancel, {
    void Function(AppFailure)? onTransient,
  }) async {
    while (now().difference(challenge.createdAt) <
        const Duration(minutes: 20)) {
      if (cancel.isCancelled) throw const AppFailure(FailureKind.cancelled);
      try {
        final result = await poll(challenge, cancel);
        if (result != null) return result;
      } on AppFailure catch (e) {
        if (![
              FailureKind.network,
              FailureKind.dns,
              FailureKind.connectionRefused,
              FailureKind.timeout,
            ].contains(e.kind) ||
            challenge.consumed) {
          rethrow;
        }
        onTransient?.call(e);
      }
      await Future.any([
        delay(const Duration(seconds: 2)),
        cancel.whenCancel.then<void>((_) {}),
      ]);
    }
    throw client.protocolFailure(
      'loginTokenExpiredAfter20Minutes',
      kind: FailureKind.expired,
    );
  }

  static Future<void> revoke(NextcloudClient authenticated) async {
    ocsData(
      await authenticated.request(
        'DELETE',
        authenticated.server.ocs(['core', 'apppassword']),
      ),
    );
  }
}
