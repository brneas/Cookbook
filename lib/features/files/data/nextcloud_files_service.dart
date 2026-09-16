import 'package:xml/xml.dart';
import '../../../core/networking/nextcloud_client.dart';
import '../../../core/api/json_response.dart';
import '../../../core/errors/app_failure.dart';

class NextcloudFile {
  const NextcloudFile(
    this.path,
    this.name, {
    required this.folder,
    required this.mime,
  });
  final String path, name, mime;
  final bool folder;
  bool get image => ['image/jpeg', 'image/png'].contains(mime);
}

/// Read-only, narrowly scoped file selection. Saving the selected path through
/// Cookbook's public recipe API lets Cookbook perform its normal image copy.
class NextcloudFilesService {
  NextcloudFilesService(this.client);
  final NextcloudClient client;
  String? _uid;
  Future<Uri> root() async {
    if (_uid == null) {
      final user = jsonObject(
        ocsData(
          await client.request('GET', client.server.ocs(['cloud', 'user'])),
        ),
      );
      final id = user['id'];
      if (id is! String ||
          id.isEmpty ||
          id.contains('/') ||
          id.contains('\\') ||
          ['.', '..'].contains(id)) {
        throw const AppFailure(FailureKind.malformedResponse);
      }
      _uid = id;
    }
    return client.server.route(['remote.php', 'dav', 'files', _uid!, '']);
  }

  static List<String> segments(String path) {
    if (!path.startsWith('/') ||
        path.contains('\\') ||
        RegExp(r'[\x00-\x1f]').hasMatch(path)) {
      throw const AppFailure(FailureKind.malformedResponse);
    }
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.any((s) => s == '.' || s == '..')) {
      throw const AppFailure(FailureKind.malformedResponse);
    }
    return parts;
  }

  Future<List<NextcloudFile>> list(String path) async {
    final base = await root();
    final uri = base.replace(
      pathSegments: [
        ...base.pathSegments.where((s) => s.isNotEmpty),
        ...segments(path),
        '',
      ],
    );
    final response = await client.request(
      'PROPFIND',
      uri,
      dav: true,
      data:
          '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontenttype/></d:prop></d:propfind>',
    );
    if (response is! String) {
      throw const AppFailure(FailureKind.malformedResponse);
    }
    return parseListing(response, base, uri);
  }

  static List<NextcloudFile> parseListing(String xml, Uri root, Uri requested) {
    try {
      if (xml.length > 8 * 1024 * 1024 ||
          xml.contains('<!DOCTYPE') ||
          xml.contains('<!ENTITY')) {
        throw const FormatException();
      }
      final document = XmlDocument.parse(xml);
      if (document.rootElement.name.local != 'multistatus' ||
          document.rootElement.namespaceUri != 'DAV:') {
        throw const FormatException();
      }
      final base = root.pathSegments.where((s) => s.isNotEmpty).toList();
      final parent = requested.pathSegments.where((s) => s.isNotEmpty).toList();
      final files = <String, NextcloudFile>{};
      for (final node in document.rootElement.findElements(
        'response',
        namespaceUri: 'DAV:',
      )) {
        final href = node.getElement('href', namespaceUri: 'DAV:')?.innerText;
        if (href == null) continue;
        final uri = requested.resolve(href);
        if (uri.origin != root.origin ||
            uri.hasQuery ||
            uri.hasFragment ||
            uri.userInfo.isNotEmpty) {
          continue;
        }
        final parts = uri.pathSegments.where((s) => s.isNotEmpty).toList();
        if (parts.length != parent.length + 1 ||
            parts.take(parent.length).join('/') != parent.join('/') ||
            parts.take(base.length).join('/') != base.join('/')) {
          continue;
        }
        if (parts.any(
          (s) =>
              s == '.' ||
              s == '..' ||
              s.contains('/') ||
              s.contains('\\') ||
              RegExp(r'[\x00-\x1f]').hasMatch(s),
        )) {
          continue;
        }
        for (final stat in node.findElements(
          'propstat',
          namespaceUri: 'DAV:',
        )) {
          if (!RegExp(r'\s200(?:\s|$)').hasMatch(
            stat.getElement('status', namespaceUri: 'DAV:')?.innerText ?? '',
          )) {
            continue;
          }
          final prop = stat.getElement('prop', namespaceUri: 'DAV:');
          if (prop == null) continue;
          final folder =
              prop
                  .getElement('resourcetype', namespaceUri: 'DAV:')
                  ?.getElement('collection', namespaceUri: 'DAV:') !=
              null;
          final path = '/${parts.skip(base.length).join('/')}';
          final file = NextcloudFile(
            path,
            parts.last,
            folder: folder,
            mime:
                prop
                    .getElement('getcontenttype', namespaceUri: 'DAV:')
                    ?.innerText ??
                '',
          );
          if (file.folder || file.image) files[path] = file;
        }
      }
      return files.values.toList()..sort(
        (a, b) => a.folder != b.folder
            ? (a.folder ? -1 : 1)
            : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    } catch (e) {
      if (e is AppFailure) rethrow;
      throw const AppFailure(FailureKind.malformedResponse);
    }
  }
}
