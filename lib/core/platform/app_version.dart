import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Read installed metadata so build overrides cannot leave a stale About version.
final appVersionProvider = FutureProvider<String>((ref) async {
  try {
    final package = await PackageInfo.fromPlatform();
    return '${package.version}+${package.buildNumber}';
  } on PlatformException {
    return 'Unknown';
  } on MissingPluginException {
    return 'Unknown';
  }
});
