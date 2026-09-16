import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/image_repository.dart';
import '../data/bounded_image.dart';

class RecipeThumbnail extends ConsumerWidget {
  const RecipeThumbnail(
    this.id, {
    super.key,
    this.hero = false,
    this.radius = 12,
  });
  final String id;
  final bool hero;
  final double radius;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref
        .watch(hero ? recipeFullImageProvider(id) : recipeImageProvider(id))
        .asData
        ?.value;
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.restaurant_outlined,
          size: hero ? 64 : 32,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
    final picture = ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: bytes == null
            ? placeholder
            : Image(
                image: BoundedMemoryImage(bytes, hero ? 1024 : 250),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) {
                  unawaited(discardFailedImage(ref, id, hero));
                  return placeholder;
                },
              ),
      ),
    );
    if (!hero || bytes == null) return picture;
    return Semantics(
      label: 'View full recipe image',
      button: true,
      child: InkWell(
        onTap: () => showDialog<void>(
          context: context,
          builder: (context) => Dialog.fullscreen(
            child: Scaffold(
              appBar: AppBar(title: const Text('Recipe image')),
              body: Center(
                child: InteractiveViewer(
                  minScale: .5,
                  maxScale: 5,
                  child: Image(
                    image: BoundedMemoryImage(bytes, 2048),
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) {
                      unawaited(discardFailedImage(ref, id, hero));
                      return placeholder;
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
        child: picture,
      ),
    );
  }
}
