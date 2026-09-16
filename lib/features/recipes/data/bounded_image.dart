import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Queue work rather than introducing timing-dependent delays.
class WorkPool {
  WorkPool(this.limit);
  final int limit;
  int _active = 0;
  final _waiting = Queue<Completer<void>>();
  Future<T> run<T>(Future<T> Function() work) async {
    if (_active >= limit) {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    } else {
      _active++;
    }
    try {
      return await work();
    } finally {
      if (_waiting.isEmpty) {
        _active--;
      } else {
        _waiting.removeFirst().complete();
      }
    }
  }
}

final imageFetchPool = WorkPool(4);
final imageDecodePool = WorkPool(2);

ui.Size boundedImageSize(int width, int height, int maxEdge) {
  final scale = math.min(1.0, maxEdge / math.max(width, height));
  return ui.Size(
    math.max(1, (width * scale).round()).toDouble(),
    math.max(1, (height * scale).round()).toDouble(),
  );
}

/// Inspect encoded metadata without creating or uploading a throwaway GPU image.
Future<bool> validImageMetadata(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return descriptor.width > 0 &&
        descriptor.height > 0 &&
        descriptor.width <= 32768 &&
        descriptor.height <= 32768 &&
        descriptor.width * descriptor.height <= 64000000;
  } catch (_) {
    return false;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Reuses Flutter's ImageCache; both target dimensions are always positive.
class BoundedMemoryImage extends ImageProvider<BoundedMemoryImage> {
  const BoundedMemoryImage(this.bytes, this.maxEdge);
  final Uint8List bytes;
  final int maxEdge;
  @override
  Future<BoundedMemoryImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
    BoundedMemoryImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _codec(), scale: 1);
  Future<ui.Codec> _codec() async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return _QueuedCodec(
      await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (width, height) {
          if (width <= 0 ||
              height <= 0 ||
              width * height > 64000000 ||
              width > 32768 ||
              height > 32768) {
            throw StateError('Unsupported image dimensions');
          }
          final size = boundedImageSize(width, height, maxEdge);
          return ui.TargetImageSize(
            width: size.width.toInt(),
            height: size.height.toInt(),
          );
        },
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BoundedMemoryImage &&
      identical(bytes, other.bytes) &&
      maxEdge == other.maxEdge;
  @override
  int get hashCode => Object.hash(identityHashCode(bytes), maxEdge);
}

class _QueuedCodec implements ui.Codec {
  _QueuedCodec(this.codec);
  final ui.Codec codec;
  bool _disposed = false;
  @override
  int get frameCount => codec.frameCount;
  @override
  int get repetitionCount => codec.repetitionCount;
  @override
  Future<ui.FrameInfo> getNextFrame() => imageDecodePool.run(() {
    if (_disposed) throw StateError('Image codec disposed');
    return codec.getNextFrame();
  });
  @override
  void dispose() {
    _disposed = true;
    codec.dispose();
  }
}
