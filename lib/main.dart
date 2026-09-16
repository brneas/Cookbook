import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/app.dart';
import 'core/runtime_diagnostics.dart';

void main() {
  RuntimeDiagnostics.mark('process start');
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ProviderScope(retry: (_, _) => null, child: const CookbookApp()));
}
