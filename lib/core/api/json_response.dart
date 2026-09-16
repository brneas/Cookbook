import '../../features/recipes/domain/recipe.dart';
import '../errors/app_failure.dart';

JsonMap jsonObject(Object? value) {
  if (value is! Map || value.keys.any((k) => k is! String)) {
    throw const AppFailure(FailureKind.malformedResponse);
  }
  return value.cast<String, Object?>();
}

List<JsonMap> jsonObjects(Object? value) {
  if (value is! List) throw const AppFailure(FailureKind.malformedResponse);
  return value.map(jsonObject).toList();
}

String requiredString(JsonMap value, String field) {
  final entry = value[field];
  if (entry is! String || entry.isEmpty) {
    throw const AppFailure(FailureKind.malformedResponse);
  }
  return entry;
}

Object? ocsData(Object? value) {
  final envelope = jsonObject(jsonObject(value)['ocs']);
  final meta = jsonObject(envelope['meta']);
  final status = int.tryParse('${meta['statuscode']}');
  if (status != 100 && status != 200) {
    throw AppFailure(
      status == 401
          ? FailureKind.authentication
          : status == 403
          ? FailureKind.permission
          : FailureKind.server,
      status: status,
    );
  }
  return envelope['data'];
}
