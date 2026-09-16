import 'package:flutter/foundation.dart';

/// Monotonic, content-free development measurements.
abstract final class RuntimeDiagnostics {
  static int networkRequests = 0;
  static final clock = Stopwatch()..start();
  static final _seen = <String>{};
  static void mark(String name) {
    if (_seen.add(name)) event(name, {'elapsedMs': clock.elapsedMilliseconds});
  }

  static void event(String name, Map<String, Object?> values) {
    if (kDebugMode) debugPrint('Cookbook runtime: $name $values');
  }
}
