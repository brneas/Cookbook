import 'dart:async';
import 'dart:typed_data';
import 'bounded_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'image_cache.dart';
import '../../../app/providers.dart';
import '../../../core/errors/app_failure.dart';

final _failedUntil = <String, DateTime>{};

final recipeImageProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>((ref, id) => loadRecipeImage(ref, id));
final recipeFullImageProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>(
      (ref, id) => loadRecipeImage(ref, id, full: true),
    );

Future<Uint8List?> loadRecipeImage(
  Ref ref,
  String id, {
  bool full = false,
}) async {
  final size = full ? 'full' : 'thumb';
  // Retain only active/briefly-offscreen requests, not an unbounded byte library.
  final keep = ref.keepAlive();
  final expiry = Timer(const Duration(seconds: 30), keep.close);
  ref.onDispose(expiry.cancel);

  final account = await ref.watch(accountProvider.future);
  if (account == null) return null;
  final failureKey = '${account.id}/$id/$size';
  _failedUntil.removeWhere((_, time) => !time.isAfter(DateTime.now()));
  if (_failedUntil.containsKey(failureKey)) return null;
  final database = await ref.watch(databaseProvider.future);
  final cache = ImageCacheStore(database, account.id);
  final resolvedId = await database.resolveId(account.id, id);
  final cached = await cache.read(resolvedId, size);
  if (cached != null) {
    if (await decodable(cached)) return cached;
    await cache.remove(resolvedId, size);
  }
  if (resolvedId.startsWith('local:')) return null;
  try {
    final api = await ref.watch(cookbookProvider.future);
    final bytes = await imageFetchPool.run(
      () => api.image(resolvedId, fullSize: full),
    );
    if (bytes.isEmpty || bytes.length > (full ? 20 : 5) * 1024 * 1024) {
      return null;
    }
    final image = Uint8List.fromList(bytes);
    if (!await decodable(image)) {
      _failedUntil[failureKey] = DateTime.now().add(const Duration(minutes: 1));
      return null;
    }
    if (ref.mounted) {
      await cache.put(resolvedId, size, image);
    }
    return image;
  } on AppFailure {
    _failedUntil[failureKey] = DateTime.now().add(const Duration(minutes: 1));
    return null;
  }
}

Future<bool> decodable(Uint8List bytes) => validImageMetadata(bytes);

Future<void> discardFailedImage(WidgetRef ref, String id, bool full) async {
  final account = ref.read(accountProvider).asData?.value;
  if (account == null) return;
  final size = full ? 'full' : 'thumb';
  _failedUntil['${account.id}/$id/$size'] = DateTime.now().add(
    const Duration(minutes: 1),
  );
  try {
    final db = await ref.read(databaseProvider.future);
    await ImageCacheStore(
      db,
      account.id,
    ).remove(await db.resolveId(account.id, id), size);
  } catch (_) {
    /* An image failure never blocks recipe text. */
  }
}
