import 'dart:convert';
import 'dart:math';
import 'package:sqflite/sqflite.dart';
import '../../../core/database/app_database.dart';
import '../../../core/errors/app_failure.dart';
import '../../recipes/domain/recipe.dart';
import '../../sync/domain/recipe_comparison.dart';
import '../domain/cooking_models.dart';
import '../domain/quantities.dart';

class CookingRepository {
  CookingRepository(this.database, this.account, {DateTime Function()? now})
    : now = now ?? DateTime.now;
  final AppDatabase database;
  final String account;
  final DateTime Function() now;
  String _id() =>
      '${now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
  String get stamp => now().toUtc().toIso8601String();
  Future<List<CookingSession>> sessions() async {
    final rows = await database.db.query(
      'cooking_sessions',
      where: 'account_id=?',
      whereArgs: [account],
    );
    return [
      for (final row in rows)
        if (_json(row)['v'] == 1)
          CookingSession(row['recipe_id'] as String, _json(row)),
    ]..sort(
      (a, b) => ('${b.data['finished'] ?? b.data['lastOpened']}').compareTo(
        '${a.data['finished'] ?? a.data['lastOpened']}',
      ),
    );
  }

  JsonMap _json(Map<String, Object?> row) =>
      (jsonDecode(row['state_json'] as String) as Map).cast<String, Object?>();
  Future<CookingSession> start(Recipe recipe, {bool over = false}) =>
      database.withSyncLock(() async {
        final id = await database.resolveId(account, recipe.id);
        final existing = (await sessions())
            .where((s) => s.recipeId == id)
            .firstOrNull;
        if (!over && existing != null && existing.active) {
          final resumed = existing.patch({'lastOpened': stamp});
          await saveSession(resumed);
          return resumed;
        }
        final session = CookingSession(id, {
          'v': 1,
          'sessionId': _id(),
          'recipeId': id,
          'snapshot': recipe.toJson(),
          'fingerprint': fingerprint(recipe.toJson()),
          'started': stamp,
          'lastOpened': stamp,
          'status': 'active',
          'current': 0,
          'ingredients': <int>[],
          'steps': <int>[],
          'multiplier': '1/1',
          if (existing == null)
            'legacy': (await database.db.query(
              'cooking_sessions',
              where: 'account_id=? AND recipe_id=?',
              whereArgs: [account, id],
            )).firstOrNull?['state_json'],
        });
        await saveSession(session);
        return session;
      });
  Future<void> saveSession(CookingSession session) => database.db
      .insert('cooking_sessions', {
        'account_id': account,
        'recipe_id': session.recipeId,
        'state_json': jsonEncode(session.data),
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});
  Future<void> updateSession(
    String id,
    JsonMap Function(CookingSession) edit,
  ) => database.withSyncLock(() async {
    final session = (await sessions()).where((s) => s.id == id).firstOrNull;
    if (session == null) throw const AppFailure(FailureKind.notFound);
    await saveSession(session.patch(edit(session)));
  });
  Future<void> check(String id, String key, int index) =>
      updateSession(id, (s) {
        final checks = s.checks(key);
        final completing = !checks.contains(index);
        completing ? checks.add(index) : checks.remove(index);
        // Completion and advancement are one persisted session update.
        int? next;
        if (key == 'steps' && completing) {
          for (var i = index + 1; i < s.steps.length; i++) {
            if (!checks.contains(i)) {
              next = i;
              break;
            }
          }
        }
        return {
          key: checks.toList()..sort(),
          if (key == 'steps' && completing) 'current': next ?? index,
        };
      });
  Future<void> reset(String id) => updateSession(
    id,
    (_) => {'current': 0, 'ingredients': <int>[], 'steps': <int>[]},
  );
  Future<void> scale(String id, Rational value) =>
      updateSession(id, (_) => {'multiplier': value.wire});
  Future<List<CookingTimer>> timers() async {
    final rows = await database.db.query(
      'timers',
      where: 'account_id=?',
      whereArgs: [account],
      orderBy: 'notification_id ASC',
    );
    return [
      for (final row in rows)
        if (_json(row)['v'] == 1 && row['notification_id'] is int)
          CookingTimer(
            row['id'] as String,
            row['notification_id'] as int,
            _json(row),
          ),
    ];
  }

  Future<void> saveTimer(CookingTimer timer) => database.db
      .insert('timers', {
        'id': timer.id,
        'account_id': account,
        'notification_id': timer.notificationId,
        'state_json': jsonEncode(timer.data),
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});
  Future<CookingTimer> createTimer(
    Duration duration,
    String label, {
    CookingSession? session,
    int? step,
  }) => database.withSyncLock(() async {
    if (duration.inSeconds <= 0 || duration > const Duration(days: 7)) {
      throw const AppFailure(FailureKind.malformedResponse);
    }
    return database.db.transaction((tx) async {
      final counter = await tx.query(
        'preferences',
        where: 'key=?',
        whereArgs: ['timerNotificationCounter'],
      );
      final next =
          (int.tryParse(counter.firstOrNull?['value'] as String? ?? '') ??
              10000) +
          1;
      await tx.insert('preferences', {
        'key': 'timerNotificationCounter',
        'value': '$next',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      final timer = CookingTimer(_id(), next, {
        'v': 1,
        'sessionId': session?.id,
        'recipeId': session?.recipeId,
        'recipeName': session?.recipe.name ?? '',
        'step': step,
        'label': label.trim().isEmpty
            ? 'Timer'
            : label.trim().substring(0, min(label.trim().length, 80)),
        'created': stamp,
        'durationMs': duration.inMilliseconds,
        'target': now().toUtc().add(duration).toIso8601String(),
        'status': 'running',
        'remainingMs': duration.inMilliseconds,
        'notification': 'pending',
      });
      await tx.insert('timers', {
        'id': timer.id,
        'account_id': account,
        'notification_id': next,
        'state_json': jsonEncode(timer.data),
      });
      return timer;
    });
  });
  Future<CookingTimer> control(
    String id,
    String action, {
    String? label,
    Duration? add,
  }) => database.withSyncLock(() async {
    final timer = (await timers()).firstWhere((t) => t.id == id);
    final remaining = timer.remaining(now());
    var next = timer;
    switch (action) {
      case 'pause':
        if (timer.running) {
          next = timer.patch({
            'status': remaining == Duration.zero ? 'completed' : 'paused',
            'remainingMs': remaining.inMilliseconds,
            'target': null,
          });
        }
      case 'resume':
        if (timer.status == 'paused') {
          next = timer.patch({
            'status': 'running',
            'target': now().toUtc().add(remaining).toIso8601String(),
          });
        }
      case 'restart':
        next = timer.patch({
          'status': 'running',
          'target': now().toUtc().add(timer.duration).toIso8601String(),
        });
      case 'cancel':
        next = timer.patch({'status': 'cancelled', 'target': null});
      case 'dismiss':
        next = timer.patch({'status': 'dismissed', 'target': null});
      case 'rename':
        next = timer.patch({
          'label': (label?.trim().isNotEmpty == true ? label!.trim() : 'Timer')
              .substring(
                0,
                min(
                  label?.trim().isNotEmpty == true ? label!.trim().length : 5,
                  80,
                ),
              ),
        });
      case 'add':
        final extra = add ?? const Duration(minutes: 1);
        final total = remaining + extra;
        if (total.inSeconds <= 0 ||
            (timer.duration + extra) > const Duration(days: 7)) {
          throw const AppFailure(FailureKind.malformedResponse);
        }
        next = timer.patch({
          'durationMs': (timer.duration + extra).inMilliseconds,
          'remainingMs': total.inMilliseconds,
          'status': timer.status == 'paused' ? 'paused' : 'running',
          'target': timer.status == 'paused'
              ? null
              : now().toUtc().add(total).toIso8601String(),
        });
    }
    next = next.patch({'notification': 'pending'});
    await saveTimer(next);
    return next;
  });
  Future<void> reconcile() => database.withSyncLock(() async {
    for (final timer in await timers()) {
      if (timer.running && timer.remaining(now()) == Duration.zero) {
        await saveTimer(timer.patch({'status': 'completed'}));
      }
    }
  });
  Future<void> notificationResult(String id, String result) =>
      database.withSyncLock(() async {
        final timer = (await timers()).where((t) => t.id == id).firstOrNull;
        if (timer != null) {
          await saveTimer(timer.patch({'notification': result}));
        }
      });
}
