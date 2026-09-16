import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cookbook/core/database/app_database.dart';
import 'package:cookbook/core/database/migrations.dart';

void main() {
  sqfliteFfiInit();
  test(
    'v4 to v5 preserves canonical queued and cooking data and scopes indexes',
    () async {
      final old = await databaseFactoryFfiNoIsolate.openDatabase(
        inMemoryDatabasePath,
      );
      await old.execute('PRAGMA foreign_keys=ON');
      for (final sql in AppDatabase.schema) {
        await old.execute(sql);
      }
      await migrateDatabase(old, 1, 4);
      await old.insert('accounts', {
        'id': 'a',
        'server': 'https://cloud.test',
        'login_name': 'cook',
        'capabilities': '{}',
      });
      await old.insert('recipes', {
        'account_id': 'a',
        'id': '1',
        'name': 'Soup',
        'stub_json': '{"name":"Soup","unknown":{"keep":true}}',
      });
      await old.insert('cooking_sessions', {
        'account_id': 'a',
        'recipe_id': '1',
        'state_json': '{"legacy":true}',
      });
      await old.insert('pending_operations', {
        'account_id': 'a',
        'recipe_id': '1',
        'kind': 'update',
        'state': 'unknownOutcome',
        'created_at': 'then',
      });
      final recipes = await old.query('recipes'),
          cooking = await old.query('cooking_sessions'),
          queue = await old.query('pending_operations');
      await migrateDatabase(old, 4, 5);
      expect(await old.query('recipes'), recipes);
      expect(await old.query('cooking_sessions'), cooking);
      expect(await old.query('pending_operations'), queue);
      await old.insert('library_index', {
        'account_id': 'a',
        'id': '1',
        'name': 'Soup',
        'name_fold': 'soup',
        'category': '',
        'search_text': 'soup',
      });
      await old.insert('library_keywords', {
        'account_id': 'a',
        'recipe_id': '1',
        'name': 'Quick',
        'normalized': 'quick',
      });
      await old.update('recipes', {'name': 'Changed'});
      expect(await old.query('library_index'), isEmpty);
      expect(await old.query('library_keywords'), isEmpty);
      await old.close();
    },
  );
  test(
    'v2 to v3 adds isolated theme metadata without changing queued work',
    () async {
      final old = await databaseFactoryFfiNoIsolate.openDatabase(
        inMemoryDatabasePath,
      );
      await old.execute('PRAGMA foreign_keys = ON');
      for (final sql in AppDatabase.schema) {
        await old.execute(sql);
      }
      await migrateDatabase(old, 1, 2);
      await old.insert('accounts', {
        'id': 'a',
        'server': 'https://cloud.test',
        'login_name': 'cook',
        'capabilities': '{}',
      });
      await old.insert('pending_operations', {
        'account_id': 'a',
        'recipe_id': '1',
        'kind': 'update',
        'payload_json': '{"unknown":true}',
        'state': 'unknownOutcome',
        'created_at': 'then',
      });
      final before = await old.query('pending_operations');
      await migrateDatabase(old, 2, 3);
      expect(await old.query('pending_operations'), before);
      await old.insert('account_metadata', {
        'account_id': 'a',
        'key': 'theme',
        'value': '{"color":"#123456"}',
      });
      await old.delete('accounts', where: 'id=?', whereArgs: ['a']);
      expect(await old.query('account_metadata'), isEmpty);
      await old.close();
    },
  );
  test(
    'fresh schema has explicit current version and mutation states',
    () async {
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      expect(await db.db.getVersion(), AppDatabase.schemaVersion);
      expect(
        (await db.db.rawQuery(
          'PRAGMA table_info(recipes)',
        )).map((r) => r['name']),
        containsAll(['server_json', 'sync_state', 'remote_state']),
      );
      await db.close();
    },
  );
  test(
    'v1 upgrade preserves recipes, operations, conflicts, sessions and unknown JSON',
    () async {
      final folder = Directory.systemTemp.createTempSync('cookbook-migration-');
      final path = '${folder.path}/test.sqlite';
      final old = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            for (final sql in AppDatabase.schema) {
              await db.execute(sql);
            }
          },
        ),
      );
      await old.insert('accounts', {
        'id': 'a',
        'server': 'https://example.invalid',
        'login_name': 'cook',
        'capabilities': '{}',
      });
      const json = '{"id":"1","name":"Saved","unknown":{"keep":[1,true,null]}}';
      await old.insert('recipes', {
        'account_id': 'a',
        'id': '1',
        'name': 'Saved',
        'stub_json': json,
        'detail_json': json,
        'base_json': json,
        'dirty': 1,
      });
      for (final state in ['pending', 'sending', 'uncertain', 'conflict']) {
        await old.insert('pending_operations', {
          'account_id': 'a',
          'recipe_id': '1',
          'kind': 'update',
          'base_json': json,
          'payload_json': json,
          'state': state,
          'created_at': 'then',
        });
      }
      await old.insert('conflicts', {
        'account_id': 'a',
        'recipe_id': '1',
        'local_json': json,
        'server_json': json,
      });
      await old.insert('cooking_sessions', {
        'account_id': 'a',
        'recipe_id': '1',
        'state_json': '{"checked":[0,2]}',
      });
      await old.close();
      final upgraded = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: path,
      );
      expect((await upgraded.recipes('a')).single.toJson(), jsonDecode(json));
      expect(
        (await upgraded.db.query('pending_operations')).map((r) => r['state']),
        ['queued', 'unknownOutcome', 'unknownOutcome', 'conflict'],
      );
      expect((await upgraded.db.query('conflicts')).single['local_json'], json);
      expect(
        (await upgraded.db.query('cooking_sessions')).single['state_json'],
        '{"checked":[0,2]}',
      );
      expect((await upgraded.db.query('recipes')).single['server_json'], json);
      await upgraded.close();
      folder.deleteSync(recursive: true);
    },
  );
}
