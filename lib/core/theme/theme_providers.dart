import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import '../../app/providers.dart';
import 'server_theme.dart';

class MetadataRevision extends Notifier<int> {
  @override
  int build() => 0;
  void changed() => state++;
}

final metadataRevisionProvider = NotifierProvider<MetadataRevision, int>(
  MetadataRevision.new,
);
final serverThemeProvider = FutureProvider<ServerTheme>((ref) async {
  final account = await ref.watch(accountProvider.future);
  ref.watch(metadataRevisionProvider);
  if (account == null) return const ServerTheme();
  final db = await ref.watch(databaseProvider.future);
  final rows = await db.db.query(
    'account_metadata',
    where: 'account_id=? AND key=?',
    whereArgs: [account.id, 'theme'],
  );
  if (rows.isEmpty) return const ServerTheme();
  try {
    return ServerTheme.stored(jsonDecode(rows.single['value'] as String));
  } catch (_) {
    return const ServerTheme();
  }
});

class AppearanceController extends AsyncNotifier<ThemeMode> {
  @override
  Future<ThemeMode> build() async {
    final db = await ref.watch(databaseProvider.future);
    final rows = await db.db.query(
      'preferences',
      where: 'key=?',
      whereArgs: ['appearance'],
    );
    return ThemeMode.values.firstWhere(
      (v) => v.name == rows.firstOrNull?['value'],
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> setMode(ThemeMode mode) async {
    final db = await ref.read(databaseProvider.future);
    await db.db.insert('preferences', {
      'key': 'appearance',
      'value': mode.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    state = AsyncData(mode);
  }
}

final appearanceProvider =
    AsyncNotifierProvider<AppearanceController, ThemeMode>(
      AppearanceController.new,
    );
