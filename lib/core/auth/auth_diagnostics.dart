enum AuthStage {
  normalizingServer,
  startingLoginFlow,
  openingBrowser,
  waitingForAuthorization,
  receivingCredentials,
  verifyingCredentials,
  loadingNextcloudCapabilities,
  discoveringCookbook,
  savingAccount,
  complete,
}

extension AuthStageText on AuthStage {
  String get label => switch (this) {
    AuthStage.normalizingServer => 'Checking server address',
    AuthStage.startingLoginFlow => 'Contacting Nextcloud…',
    AuthStage.openingBrowser => 'Opening your browser…',
    AuthStage.waitingForAuthorization =>
      'Waiting for you to approve Cookbook in your browser…',
    AuthStage.receivingCredentials => 'Receiving application credentials…',
    AuthStage.verifyingCredentials => 'Verifying your Nextcloud account…',
    AuthStage.loadingNextcloudCapabilities => 'Loading Nextcloud capabilities…',
    AuthStage.discoveringCookbook => 'Connecting to Cookbook…',
    AuthStage.savingAccount => 'Saving your account securely…',
    AuthStage.complete => 'Connected',
  };
}

/// Only app-authored categories and redacted endpoint paths enter this object.
/// No raw exception, response body, header, query or Location is retained.
class RequestDiagnostic {
  const RequestDiagnostic({
    this.stage,
    this.method,
    this.host,
    this.path,
    this.status,
    this.dioCategory,
    this.transport,
    this.reason,
    this.redirect,
  });
  final AuthStage? stage;
  final String? method, host, path, dioCategory, transport, reason, redirect;
  final int? status;
  RequestDiagnostic at(AuthStage value) => RequestDiagnostic(
    stage: value,
    method: method,
    host: host,
    path: path,
    status: status,
    dioCategory: dioCategory,
    transport: transport,
    reason: reason,
    redirect: redirect,
  );
  RequestDiagnostic withReason(String value) => RequestDiagnostic(
    stage: stage,
    method: method,
    host: host,
    path: path,
    status: status,
    dioCategory: dioCategory,
    transport: transport,
    reason: value,
    redirect: redirect,
  );
  String get text => [
    if (stage != null) 'Stage: ${stage!.name}',
    if (host != null) 'Host: $host',
    if (method != null) 'Method: $method',
    if (path != null) 'Endpoint: $path',
    'Result: ${status == null ? "No HTTP response" : "HTTP $status"}',
    if (redirect != null) 'Redirect: $redirect',
    if (dioCategory != null) 'Dio: $dioCategory',
    if (transport != null) 'Transport: $transport',
    if (reason != null) 'Reason: $reason',
  ].join('\n');
  @override
  String toString() => text;
}

String diagnosticPath(Uri uri) {
  // Login URLs can embed tokens anywhere. Only known endpoint suffixes are shown.
  final path = uri.path;
  for (final suffix in [
    '/index.php/login/v2',
    '/login/v2/poll',
    '/ocs/v2.php/cloud/user',
    '/ocs/v2.php/cloud/capabilities',
    '/ocs/v2.php/core/getapppassword',
    '/index.php/apps/cookbook/api/version',
  ]) {
    if (path.endsWith(suffix)) {
      return path == suffix ? suffix : '/[installation]$suffix';
    }
  }
  if (path.contains('/login/') && path.contains('/flow/')) {
    return '/[redacted]/login/v2/flow/[redacted]';
  }
  return '/[redacted endpoint]';
}
