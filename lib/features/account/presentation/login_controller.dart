import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../app/providers.dart';
import '../../../core/auth/credential_store.dart';
import '../../../core/auth/nextcloud_auth_service.dart';
import '../../../core/auth/nextcloud_verification.dart';
import '../../../core/auth/auth_diagnostics.dart';
import '../../../core/api/cookbook_capabilities.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/networking/nextcloud_client.dart';
import '../../../core/networking/server_address.dart';
import '../../../core/theme/theme_providers.dart';

typedef AuthClientFactory =
    NextcloudClient Function(ServerAddress, AppCredentials?);
final authClientFactoryProvider = Provider<AuthClientFactory>(
  (_) =>
      (server, credentials) =>
          NextcloudClient(server, credentials: credentials),
);
final browserLauncherProvider = Provider<Future<bool> Function(Uri)>(
  (_) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

class LoginState {
  const LoginState({
    this.busy = false,
    this.stage = AuthStage.normalizingServer,
    this.error,
    this.diagnostic,
    this.recoverable = false,
  });
  final bool busy, recoverable;
  final AuthStage stage;
  final AppFailure? error;
  final RequestDiagnostic? diagnostic;
  bool get waiting => stage == AuthStage.waitingForAuthorization;
  String? get errorMessage {
    final e = error;
    if (e == null) return null;
    if (e.status != null) {
      final action = stage == AuthStage.startingLoginFlow
          ? 'Could not start Nextcloud login.'
          : stage == AuthStage.waitingForAuthorization
          ? 'Nextcloud could not complete authorization.'
          : e.message;
      return '$action The server returned HTTP ${e.status} from ${diagnostic?.path ?? "the requested endpoint"}.';
    }
    if (e.kind == FailureKind.malformedResponse) {
      return 'The server was reached, but its ${stage == AuthStage.startingLoginFlow ? "login-flow" : "protocol"} response was invalid.';
    }
    return e.message;
  }
}

final loginProvider = NotifierProvider<LoginController, LoginState>(
  LoginController.new,
);

class LoginController extends Notifier<LoginState> {
  CancelToken? _cancel;
  LoginChallenge? _challenge;
  String? _address;
  @override
  LoginState build() {
    ref.onDispose(() => _cancel?.cancel());
    return const LoginState();
  }

  void cancel() {
    _cancel?.cancel();
    _challenge = null;
  }

  Future<bool> reopenBrowser() => connect(_address ?? '');
  Future<bool> connect(
    String address, {
    String? loginName,
    String? appPassword,
    bool appPasswordConfirmed = false,
  }) async {
    if (state.busy) return false;
    var stage = AuthStage.normalizingServer;
    NextcloudClient? http, authenticated;
    var checkpointed = false;
    void progress(AuthStage value) {
      stage = value;
      if (ref.mounted) state = LoginState(busy: true, stage: value);
    }

    progress(stage);
    try {
      final server = ServerAddress.parse(address);
      final cancel = _cancel = CancelToken();
      final factory = ref.read(authClientFactoryProvider);
      final repository = await ref.read(accountRepositoryProvider.future);
      LoginResult result;
      final manual = loginName != null && appPassword != null;
      if (manual) {
        if (loginName.trim().isEmpty || loginName.contains(':')) {
          throw const AppFailure(FailureKind.authentication);
        }
        if (!appPasswordConfirmed || !looksLikeAppPassword(appPassword)) {
          throw const AppFailure(FailureKind.appPasswordRequired);
        }
        result = LoginResult(
          server,
          AppCredentials(loginName.trim(), appPassword),
        );
      } else {
        final pending = await repository.pending(server);
        if (pending != null) {
          result = pending;
          checkpointed = true;
        } else {
          http = factory(server, null);
          final auth = NextcloudAuthService(http);
          progress(AuthStage.startingLoginFlow);
          if (_address != server.toString() || _challenge?.consumed == true) {
            _challenge = null;
          }
          _address = server.toString();
          final challenge = _challenge ??= await auth.begin(cancel);
          progress(AuthStage.openingBrowser);
          bool opened;
          try {
            opened = await ref.read(browserLauncherProvider)(
              challenge.loginUri,
            );
          } catch (_) {
            opened = false;
          }
          if (!opened) {
            throw AppFailure(
              FailureKind.browser,
              diagnostic: RequestDiagnostic(
                stage: stage,
                host: server.uri.host,
                reason: 'browserLaunchFailed',
              ),
            );
          }
          if (cancel.isCancelled) throw const AppFailure(FailureKind.cancelled);
          progress(AuthStage.waitingForAuthorization);
          result = await auth.waitForApproval(
            challenge,
            cancel,
            onTransient: (e) {
              if (ref.mounted) {
                state = LoginState(
                  busy: true,
                  stage: stage,
                  diagnostic: e.diagnostic,
                );
              }
            },
          );
          progress(AuthStage.receivingCredentials);
          await repository.checkpoint(result);
          checkpointed = true;
          _challenge = null;
        }
      }
      if (cancel.isCancelled) throw const AppFailure(FailureKind.cancelled);
      authenticated = factory(result.server, result.credentials);
      final verification = NextcloudVerification(authenticated);
      progress(AuthStage.verifyingCredentials);
      await verification.verify();
      if (cancel.isCancelled) throw const AppFailure(FailureKind.cancelled);
      progress(AuthStage.loadingNextcloudCapabilities);
      NextcloudInfo? info;
      try {
        info = await verification.capabilities();
      } on AppFailure {
        /* Optional metadata cannot prevent access to Cookbook. */
      }
      progress(AuthStage.discoveringCookbook);
      authenticated.stage = stage;
      CookbookCapabilities? caps;
      AppFailure? discoveryError;
      try {
        caps = await CookbookCapabilityService(
          authenticated,
        ).discover(nextcloudCapabilities: info?.capabilities);
      } on AppFailure catch (e) {
        discoveryError = e;
      }
      if (cancel.isCancelled) throw const AppFailure(FailureKind.cancelled);
      progress(AuthStage.savingAccount);
      await ref
          .read(accountProvider.notifier)
          .install(result, info: info, caps: caps);
      try {
        await repository.clearCheckpoint();
      } catch (_) {
        /* Account is already safely installed; removal also clears this checkpoint. */
      }
      ref.read(metadataRevisionProvider.notifier).changed();
      if (ref.mounted) {
        state = LoginState(
          stage: AuthStage.complete,
          error: discoveryError,
          diagnostic: authenticated.lastDiagnostic,
        );
      }
      return true;
    } catch (error) {
      final failure = safeFailure(error);
      if (checkpointed && failure.kind == FailureKind.authentication) {
        try {
          await (await ref.read(
            accountRepositoryProvider.future,
          )).clearCheckpoint();
          checkpointed = false;
        } catch (_) {
          /* Keep the safe recovery indication if cleanup failed. */
        }
      }
      final diagnostic =
          (failure.diagnostic ??
                  authenticated?.lastDiagnostic ??
                  http?.lastDiagnostic ??
                  const RequestDiagnostic())
              .at(failure.diagnostic?.stage ?? stage);
      if (ref.mounted) {
        state = LoginState(
          stage: stage,
          error: failure,
          diagnostic: diagnostic,
          recoverable: checkpointed,
        );
      }
      if (failure.kind != FailureKind.browser) _challenge = null;
      return false;
    } finally {
      http?.close();
      authenticated?.close();
      _cancel = null;
    }
  }
}
