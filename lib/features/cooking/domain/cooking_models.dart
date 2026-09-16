import '../../recipes/domain/recipe.dart';
import '../../editor/domain/recipe_draft.dart';
import 'quantities.dart';

class CookingSession {
  CookingSession(this.recipeId, this.data);
  final String recipeId;
  final JsonMap data;
  String get id => data['sessionId'] as String;
  Recipe get recipe =>
      Recipe.fromJson((data['snapshot'] as Map).cast<String, Object?>());
  String get revision => data['fingerprint'] as String;
  bool get active => data['status'] == 'active';
  int get current => (data['current'] as int? ?? 0).clamp(
    0,
    steps.isEmpty ? 0 : steps.length - 1,
  );
  List<InstructionLeaf> get steps => InstructionTree(
    recipe.toJson()['recipeInstructions'],
  ).leaves.where((s) => s.text.trim().isNotEmpty).toList();
  bool get allStepsComplete =>
      steps.isNotEmpty &&
      List.generate(steps.length, (i) => i).every(checks('steps').contains);
  Set<int> checks(String key) =>
      ((data[key] as List?) ?? []).whereType<int>().toSet();
  Rational? get originalYield => yieldBasis(recipe.yieldText);
  Rational get multiplier =>
      Rational.fromWire(data['multiplier'] as String? ?? '1/1') ?? Rational(1);
  CookingSession patch(JsonMap values) =>
      CookingSession(recipeId, {...data, ...values});
}

class CookingTimer {
  CookingTimer(this.id, this.notificationId, this.data);
  final String id;
  final int notificationId;
  final JsonMap data;
  String? get sessionId => data['sessionId'] as String?;
  String get label => data['label'] as String? ?? 'Timer';
  String get recipeName => data['recipeName'] as String? ?? '';
  String get status => data['status'] as String;
  String get notification => data['notification'] as String? ?? 'pending';
  Duration get duration => Duration(milliseconds: data['durationMs'] as int);
  DateTime? get target => DateTime.tryParse(data['target'] as String? ?? '');
  bool get running => status == 'running';
  bool get active => running || status == 'paused';
  Duration remaining(DateTime now) => Duration(
    milliseconds:
        (running
                ? (target?.difference(now).inMilliseconds ?? 0)
                : status == 'paused'
                ? data['remainingMs'] as int
                : 0)
            .clamp(0, duration.inMilliseconds),
  );
  CookingTimer patch(JsonMap values) =>
      CookingTimer(id, notificationId, {...data, ...values});
}
