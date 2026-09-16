import '../auth/auth_diagnostics.dart';

enum FailureKind {
  invalidUrl,
  network,
  dns,
  tls,
  connectionRefused,
  redirect,
  browser,
  expired,
  appPasswordRequired,
  timeout,
  authentication,
  permission,
  unavailable,
  unsupported,
  notFound,
  conflict,
  malformedResponse,
  cancelled,
  storage,
  server,
  libraryBusy,
}

/// Safe to display and log. Never carries a raw exception, URL, or response body.
final class AppFailure implements Exception {
  const AppFailure(this.kind, {this.status, this.diagnostic});
  final RequestDiagnostic? diagnostic;
  AppFailure withDiagnostic(RequestDiagnostic value) =>
      AppFailure(kind, status: status, diagnostic: value);
  final FailureKind kind;
  final int? status;
  String get message => switch (kind) {
    FailureKind.dns =>
      'The Nextcloud hostname could not be resolved. Check its spelling and DNS connection.',
    FailureKind.tls =>
      'A secure TLS connection could not be established. Check the server certificate, hostname and device clock.',
    FailureKind.connectionRefused =>
      'The connection was refused by the server or network.',
    FailureKind.redirect =>
      'The server redirected this request to an unsupported or unsafe destination. See Technical details.',
    FailureKind.browser =>
      'The system browser could not open Nextcloud. Tap Open browser to try again.',
    FailureKind.expired =>
      'This login request expired. Start a new browser sign-in.',
    FailureKind.appPasswordRequired =>
      'Use a dedicated Nextcloud app password from Personal settings → Security, not your normal account password.',
    FailureKind.invalidUrl => 'Enter a valid HTTPS Nextcloud server address.',
    FailureKind.network =>
      'The network connection failed or was interrupted. See Technical details.',
    FailureKind.timeout => 'The server took too long to respond.',
    FailureKind.authentication =>
      'Nextcloud rejected the application credentials.',
    FailureKind.permission =>
      'Your account does not have permission for this action.',
    FailureKind.unavailable =>
      'Connected to Nextcloud, but the Cookbook app does not appear to be available for this account.',
    FailureKind.unsupported =>
      'Cookbook was found, but this server exposes an API version this client does not support yet.',
    FailureKind.notFound => 'This recipe could not be found.',
    FailureKind.conflict =>
      'The server has a different version. Review before saving.',
    FailureKind.malformedResponse =>
      'The server returned an unexpected response. Your saved data is safe.',
    FailureKind.cancelled => 'The operation was cancelled.',
    FailureKind.storage =>
      'Local storage could not be accessed. Please try again.',
    FailureKind.server => 'The server could not complete this request.',
    FailureKind.libraryBusy =>
      'Finish synchronizing pending changes, or reload Nextcloud Cookbook settings to resolve an interrupted library change, before continuing.',
  };
  @override
  String toString() => 'AppFailure(${kind.name}, status: $status)';
}

sealed class Result<T> {
  const Result();
}

final class Success<T> extends Result<T> {
  const Success(this.value);
  final T value;
}

final class Failure<T> extends Result<T> {
  const Failure(this.error);
  final AppFailure error;
}

AppFailure safeFailure(Object error) =>
    error is AppFailure ? error : const AppFailure(FailureKind.storage);
