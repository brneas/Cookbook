import '../errors/app_failure.dart';

/// All Nextcloud route construction belongs here, including subdirectory support.
final class ServerAddress {
  ServerAddress._(this.uri);
  final Uri uri;
  factory ServerAddress.parse(String input) {
    try {
      final text = input.trim();
      if (text.isEmpty ||
          RegExp(
            r'\s|(?:/|%2[fF])(?:\.|%2[eE]){1,2}(?:/|%2[fF]|$)',
          ).hasMatch(text)) {
        throw const AppFailure(FailureKind.invalidUrl);
      }
      final uri = Uri.parse(text.contains('://') ? text : 'https://$text');
      if (uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.pathSegments.any((s) => s == '..' || s == '.')) {
        throw const AppFailure(FailureKind.invalidUrl);
      }
      var path = uri.path.replaceAll(RegExp(r'/+$'), '');
      if (path.endsWith('/index.php')) {
        path = path.substring(0, path.length - 10);
      }
      return ServerAddress._(uri.replace(path: '$path/'));
    } on AppFailure {
      rethrow;
    } on FormatException {
      throw const AppFailure(FailureKind.invalidUrl);
    }
  }
  Uri route(List<String> segments, {Map<String, String>? query}) => uri.replace(
    pathSegments: [...uri.pathSegments.where((s) => s.isNotEmpty), ...segments],
    queryParameters: query,
  );
  Uri cookbook(List<String> segments, {Map<String, String>? query}) => route([
    'index.php',
    'apps',
    'cookbook',
    'api',
    ...segments,
  ], query: query);
  Uri ocs(List<String> segments) =>
      route(['ocs', 'v2.php', ...segments], query: {'format': 'json'});
  bool sameOrigin(Uri other) =>
      other.scheme.toLowerCase() == uri.scheme.toLowerCase() &&
      other.host.toLowerCase() == uri.host.toLowerCase() &&
      other.port == uri.port;
  @override
  String toString() => uri.toString();
}
