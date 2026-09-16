import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/providers.dart';
import '../../../core/errors/app_failure.dart';
import '../data/nextcloud_files_service.dart';

final nextcloudFilesProvider =
    FutureProvider.autoDispose<NextcloudFilesService>((ref) async {
      final account = await ref.watch(accountProvider.future);
      if (account == null) throw const AppFailure(FailureKind.authentication);
      final client = await (await ref.watch(
        accountRepositoryProvider.future,
      )).client(account);
      ref.onDispose(client.close);
      return NextcloudFilesService(client);
    });
final filesListingProvider = FutureProvider.autoDispose
    .family<List<NextcloudFile>, String>(
      (ref, path) async =>
          (await ref.watch(nextcloudFilesProvider.future)).list(path),
    );
Future<String?> pickNextcloudImage(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const FractionallySizedBox(
        heightFactor: .92,
        child: NextcloudImagePicker(),
      ),
    );

class NextcloudImagePicker extends ConsumerStatefulWidget {
  const NextcloudImagePicker({super.key});
  @override
  ConsumerState<NextcloudImagePicker> createState() =>
      _NextcloudImagePickerState();
}

class _NextcloudImagePickerState extends ConsumerState<NextcloudImagePicker> {
  String path = '/', search = '';
  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        title: const Text('Choose a Nextcloud image'),
        subtitle: Text(path),
        leading: path == '/'
            ? null
            : IconButton(
                tooltip: 'Parent folder',
                icon: const Icon(Icons.arrow_upward),
                onPressed: () => setState(() {
                  search = '';
                  path = path.substring(0, path.lastIndexOf('/')).isEmpty
                      ? '/'
                      : path.substring(0, path.lastIndexOf('/'));
                }),
              ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          'JPEG or PNG. Cookbook copies the selected image when the recipe is saved. Requires a connection.',
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          key: ValueKey(path),
          decoration: const InputDecoration(
            labelText: 'Search this folder',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (s) => setState(() => search = s),
        ),
      ),
      Expanded(
        child: ref
            .watch(filesListingProvider(path))
            .when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(safeFailure(e).message),
                    TextButton(
                      onPressed: () =>
                          ref.invalidate(filesListingProvider(path)),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
              data: (files) {
                final visible = files
                    .where(
                      (f) =>
                          f.name.toLowerCase().contains(search.toLowerCase()),
                    )
                    .toList();
                if (visible.isEmpty) {
                  return const Center(
                    child: Text('No folders or JPEG/PNG images here.'),
                  );
                }
                return ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, i) {
                    final file = visible[i];
                    return ListTile(
                      leading: Icon(
                        file.folder
                            ? Icons.folder_outlined
                            : Icons.image_outlined,
                      ),
                      title: Text(file.name),
                      onTap: () {
                        if (file.folder) {
                          setState(() {
                            path = file.path;
                            search = '';
                          });
                        } else {
                          Navigator.pop(context, file.path);
                        }
                      },
                    );
                  },
                );
              },
            ),
      ),
    ],
  );
}
