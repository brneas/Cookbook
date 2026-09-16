import '../runtime_diagnostics.dart';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import '../auth/credential_store.dart';
import '../auth/auth_diagnostics.dart';
import '../errors/app_failure.dart';
import 'server_address.dart';

typedef DiagnosticSink = void Function(String message);
String requestDiagnostic(String method, int? status) =>
    '${const {'GET', 'POST', 'PUT', 'DELETE', 'PROPFIND'}.contains(method) ? method : 'REQUEST'} status=${status ?? 'unavailable'}';

class LoginPending {
  const LoginPending();
}

final class NextcloudClient {
  NextcloudClient(this.server, {this.credentials, Dio? dio, this.diagnostics})
    : _dio = dio ?? Dio() {
    _dio.options = BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 45),
      sendTimeout: const Duration(seconds: 30),
      followRedirects: false,
      // Classify HTTP before decoding: a pending 404/HTML error is still an HTTP response.
      validateStatus: (status) => status != null,
      headers: {
        'Accept': 'application/json',
        'User-Agent': 'Cookbook (Flutter; Nextcloud Login Flow v2)',
      },
    );
  }
  final ServerAddress server;
  final Dio _dio;
  final AppCredentials? credentials;
  final DiagnosticSink? diagnostics;
  AuthStage? stage;
  RequestDiagnostic? lastDiagnostic;
  AppFailure protocolFailure(
    String reason, {
    FailureKind kind = FailureKind.malformedResponse,
  }) => AppFailure(
    kind,
    diagnostic:
        (lastDiagnostic ??
                RequestDiagnostic(stage: stage, host: server.uri.host))
            .at(stage ?? lastDiagnostic?.stage ?? AuthStage.normalizingServer)
            .withReason(reason),
  );
  Future<Object?> request(
    String method,
    Uri uri, {
    Object? data,
    bool form = false,
    bool bytes = false,
    bool redirects = false,
    bool polling = false,
    bool dav = false,
    CancelToken? cancelToken,
  }) async {
    var current = uri;
    final redirectHistory = <int>[];
    for (var hop = 0; hop <= 5; hop++) {
      if (!server.sameOrigin(current) ||
          current.userInfo.isNotEmpty ||
          current.hasFragment) {
        throw protocolFailure(
          'originOrUrlRejected',
          kind: FailureKind.invalidUrl,
        );
      }
      RequestDiagnostic record({
        int? status,
        String? dio,
        String? transport,
        String? reason,
        String? redirect,
      }) => RequestDiagnostic(
        stage: stage,
        method:
            const {'GET', 'POST', 'PUT', 'DELETE', 'PROPFIND'}.contains(method)
            ? method
            : 'REQUEST',
        host: current.host,
        path: diagnosticPath(current),
        status: status,
        dioCategory: dio,
        transport: transport,
        reason: reason,
        redirect:
            redirect ??
            (redirectHistory.isEmpty
                ? null
                : 'sameOrigin ${redirectHistory.join(",")}'),
      );
      void retain(RequestDiagnostic value) {
        lastDiagnostic = value;
        diagnostics?.call(value.text);
      }

      try {
        // Dio overrides responseType for Object?; dynamic preserves plain text.
        RuntimeDiagnostics.networkRequests++;
        final response = await _dio.requestUri<dynamic>(
          current,
          data: data,
          cancelToken: cancelToken,
          options: Options(
            method: method,
            contentType: dav
                ? 'application/xml; charset=utf-8'
                : form
                ? Headers.formUrlEncodedContentType
                : data == null
                ? null
                : Headers.jsonContentType,
            responseType: bytes ? ResponseType.bytes : ResponseType.plain,
            headers: {
              if (dav) ...{'Accept': 'application/xml', 'Depth': '1'},
              if (bytes) 'Accept': 'image/jpeg',
              if (current.path.contains('/ocs/')) 'OCS-APIRequest': 'true',
              if (credentials != null)
                'Authorization':
                    'Basic ${base64Encode(utf8.encode('${credentials!.loginName}:${credentials!.appPassword}'))}',
            },
          ),
        );
        final status = response.statusCode!;
        retain(record(status: status));
        if ([301, 302, 303, 307, 308].contains(status)) {
          final location = response.headers.value('location');
          final target = location == null ? null : current.resolve(location);
          final safe =
              target != null &&
              server.sameOrigin(target) &&
              target.userInfo.isEmpty &&
              !target.hasFragment;
          final allowed = method == 'GET' || redirects && status != 303;
          retain(
            record(
              status: status,
              redirect: !safe
                  ? 'blockedOriginOrLocation'
                  : !allowed
                  ? 'blockedMethod'
                  : hop == 5
                  ? 'limitExceeded'
                  : 'sameOrigin',
            ),
          );
          if (!safe || !allowed || hop == 5) {
            throw AppFailure(
              FailureKind.redirect,
              status: status,
              diagnostic: lastDiagnostic,
            );
          }
          current = target;
          redirectHistory.add(status);
          continue;
        }
        if (polling && status == 404) return const LoginPending();
        if (status < 200 || status >= 300) {
          throw AppFailure(
            httpFailure(status),
            status: status,
            diagnostic: lastDiagnostic,
          );
        }
        if (bytes) {
          final mime = response.headers
              .value('content-type')
              ?.split(';')
              .first
              .trim()
              .toLowerCase();
          if (mime != null &&
              ![
                'image/jpeg',
                'image/png',
                'application/octet-stream',
              ].contains(mime)) {
            throw const AppFailure(FailureKind.malformedResponse);
          }
          return response.data;
        }
        if (dav) return response.data;
        if (status == 204) return null;
        try {
          return response.data is String
              ? jsonDecode(response.data as String)
              : response.data;
        } on FormatException {
          throw protocolFailure('invalidJson');
        }
      } on DioException catch (error) {
        final failure = translateNetworkError(error);
        final transport = switch (error.type) {
          DioExceptionType.connectionTimeout => 'connectTimeout',
          DioExceptionType.sendTimeout => 'sendTimeout',
          DioExceptionType.receiveTimeout => 'receiveTimeout',
          _ => failure.kind.name,
        };
        retain(
          record(
            status: error.response?.statusCode,
            dio: error.type.name,
            transport: transport,
          ),
        );
        throw failure.withDiagnostic(lastDiagnostic!);
      }
    }
    throw protocolFailure('redirectLimit', kind: FailureKind.redirect);
  }

  void close() => _dio.close(force: true);
}

FailureKind httpFailure(int status) => switch (status) {
  401 => FailureKind.authentication,
  403 => FailureKind.permission,
  404 => FailureKind.notFound,
  409 || 412 => FailureKind.conflict,
  _ => FailureKind.server,
};
AppFailure translateNetworkError(DioException error) {
  final status = error.response?.statusCode;
  if (status != null) return AppFailure(httpFailure(status), status: status);
  final cause = error.error;
  final kind = switch (error.type) {
    DioExceptionType.cancel => FailureKind.cancelled,
    DioExceptionType.connectionTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.sendTimeout => FailureKind.timeout,
    DioExceptionType.badCertificate => FailureKind.tls,
    _ =>
      cause is HandshakeException || cause is TlsException
          ? FailureKind.tls
          : cause is SocketException
          ? (cause.message.toLowerCase().contains('host lookup') ||
                    [-2, 7, 8, 11001].contains(cause.osError?.errorCode)
                ? FailureKind.dns
                : [61, 111, 10061].contains(cause.osError?.errorCode)
                ? FailureKind.connectionRefused
                : FailureKind.network)
          : error.type == DioExceptionType.connectionError
          ? FailureKind.network
          : FailureKind.malformedResponse,
  };
  return AppFailure(kind);
}
