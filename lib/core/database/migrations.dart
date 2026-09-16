import 'package:sqflite/sqflite.dart';

/// sqflite wraps upgrade callbacks in a transaction. Never recreate user data.
Future<void> migrateDatabase(Database db, int from, int to) async {
  if (from < 2 && to >= 2) {
    for (final sql in [
      'CREATE TABLE recipe_aliases (account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, local_id TEXT NOT NULL, server_id TEXT NOT NULL, PRIMARY KEY(account_id,local_id))',
      "ALTER TABLE recipes ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'clean'",
      "ALTER TABLE recipes ADD COLUMN remote_state TEXT NOT NULL DEFAULT 'present'",
      'ALTER TABLE recipes ADD COLUMN local_deleted INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE recipes ADD COLUMN server_json TEXT',
      'UPDATE recipes SET server_json = base_json',
      "UPDATE recipes SET sync_state = 'queued' WHERE dirty = 1",
      "UPDATE recipes SET remote_state = 'suspected' WHERE missing = 1",
      'ALTER TABLE conflicts ADD COLUMN base_json TEXT',
      "ALTER TABLE conflicts ADD COLUMN kind TEXT NOT NULL DEFAULT 'update'",
      'ALTER TABLE conflicts ADD COLUMN operation_id INTEGER',
      'ALTER TABLE image_cache ADD COLUMN accessed_at INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE sync_metadata ADD COLUMN last_attempt TEXT',
      'ALTER TABLE sync_metadata ADD COLUMN server_count INTEGER',
      'ALTER TABLE pending_operations RENAME TO legacy_operations',
      '''CREATE TABLE pending_operations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        recipe_id TEXT NOT NULL,
        kind TEXT NOT NULL CHECK(kind IN ('create','update','delete','import')),
        base_json TEXT, payload_json TEXT, result_json TEXT, before_ids_json TEXT,
        state TEXT NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','sending','unknownOutcome','conflict','applied','failed')),
        error_kind TEXT, created_at TEXT NOT NULL)''',
      '''INSERT INTO pending_operations(id,account_id,recipe_id,kind,base_json,payload_json,state,created_at)
        SELECT id,account_id,recipe_id,kind,base_json,payload_json,
        CASE state WHEN 'pending' THEN 'queued' WHEN 'sending' THEN 'unknownOutcome' WHEN 'uncertain' THEN 'unknownOutcome' ELSE state END,created_at FROM legacy_operations''',
      'DROP TABLE legacy_operations',
      'CREATE INDEX operation_order ON pending_operations(account_id,recipe_id,id)',
      'CREATE INDEX image_lru ON image_cache(account_id,accessed_at)',
      "UPDATE recipes SET sync_state='unknownOutcome' WHERE EXISTS (SELECT 1 FROM pending_operations p WHERE p.account_id=recipes.account_id AND p.recipe_id=recipes.id AND p.state='unknownOutcome')",
    ]) {
      await db.execute(sql);
    }
  }
  if (from < 3 && to >= 3) {
    await db.execute(
      'CREATE TABLE account_metadata (account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(account_id,key))',
    );
  }
  if (from < 4 && to >= 4) {
    await db.execute('ALTER TABLE timers ADD COLUMN notification_id INTEGER');
    await db.execute(
      'CREATE UNIQUE INDEX timer_notification ON timers(notification_id)',
    );
    // JSON placeholders are retained byte-for-byte; new models use a version marker.
  }
  if (from < 5 && to >= 5) {
    for (final sql in [
      '''CREATE TABLE library_index (account_id TEXT NOT NULL, id TEXT NOT NULL,
        name TEXT NOT NULL, name_fold TEXT NOT NULL, category TEXT NOT NULL,
        search_text TEXT NOT NULL, created INTEGER, modified INTEGER,
        PRIMARY KEY(account_id,id), FOREIGN KEY(account_id,id)
        REFERENCES recipes(account_id,id) ON DELETE CASCADE)''',
      '''CREATE TABLE library_keywords (account_id TEXT NOT NULL, recipe_id TEXT NOT NULL,
        name TEXT NOT NULL, normalized TEXT NOT NULL, PRIMARY KEY(account_id,recipe_id,name),
        FOREIGN KEY(account_id,recipe_id) REFERENCES library_index(account_id,id) ON DELETE CASCADE)''',
      'CREATE INDEX library_names ON library_index(account_id,name_fold,id)',
      'CREATE INDEX library_categories ON library_index(account_id,category,name_fold)',
      'CREATE INDEX library_created ON library_index(account_id,created,id)',
      'CREATE INDEX library_modified ON library_index(account_id,modified,id)',
      'CREATE INDEX library_tags ON library_keywords(account_id,normalized,recipe_id)',
      '''CREATE TRIGGER library_recipe_changed AFTER UPDATE ON recipes BEGIN
        DELETE FROM library_index WHERE account_id=OLD.account_id AND id=OLD.id;
      END''',
    ]) {
      await db.execute(sql);
    }
  }
  if (from < 6 && to >= 6) {
    await db.execute('DROP TRIGGER IF EXISTS library_recipe_changed');
    await db.execute(
      """CREATE TRIGGER library_recipe_changed AFTER UPDATE ON recipes
      WHEN OLD.name IS NOT NEW.name OR OLD.category IS NOT NEW.category
        OR OLD.keywords IS NOT NEW.keywords OR OLD.detail_json IS NOT NEW.detail_json
        OR OLD.stub_json IS NOT NEW.stub_json OR OLD.local_deleted IS NOT NEW.local_deleted
        OR OLD.remote_state IS NOT NEW.remote_state
      BEGIN DELETE FROM library_index WHERE account_id=OLD.account_id AND id=OLD.id; END""",
    );
  }
}
