// Isolated renderer diagnostic target. Contains no account or network access.
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cookbook/features/recipes/data/bounded_image.dart';
import 'renderer_fixtures.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const legacy = bool.fromEnvironment('PROBE_LEGACY');
  if (const bool.fromEnvironment('PROBE_MATRIX')) {
    runApp(const MaterialApp(home: MatrixProbe()));
    return;
  }
  const images = bool.fromEnvironment('PROBE_IMAGES', defaultValue: true);
  const grid = bool.fromEnvironment('PROBE_GRID', defaultValue: true);
  const count = int.fromEnvironment('PROBE_COUNT', defaultValue: 60);
  const edge = int.fromEnvironment('PROBE_EDGE', defaultValue: 250);
  final bytes = rendererFixtures.values.map(base64Decode).toList();
  Widget tile(int i) => SizedBox(
    height: 180,
    child: images
        ? Image(
            image: BoundedMemoryImage(bytes[i % bytes.length], edge),
            errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
          )
        : const Icon(Icons.restaurant_outlined),
  );
  runApp(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Isolated renderer probe')),
        body: grid
            ? GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                ),
                itemCount: count,
                itemBuilder: (_, i) => tile(i),
              )
            : ListView.builder(
                itemCount: count,
                itemBuilder: (_, i) => tile(i),
              ),
      ),
    ),
  );
  debugPrint(
    'PROBE layout grid=$grid images=$images count=$count edge=$edge legacy=$legacy',
  );
  if (images) {
    for (final fixture in rendererFixtures.entries) {
      debugPrint('PROBE start ${fixture.key}');
      try {
        final data = base64Decode(fixture.value);
        final ui.Codec codec;
        if (legacy) {
          codec = await ui.instantiateImageCodec(data, targetWidth: 1);
        } else {
          final buffer = await ui.ImmutableBuffer.fromUint8List(data);
          codec = await ui.instantiateImageCodecWithSize(
            buffer,
            getTargetSize: (width, height) {
              final size = boundedImageSize(width, height, edge);
              return ui.TargetImageSize(
                width: size.width.toInt(),
                height: size.height.toInt(),
              );
            },
          );
        }
        final frame = await codec.getNextFrame();
        debugPrint(
          'PROBE decoded ${fixture.key} ${frame.image.width}x${frame.image.height}',
        );
        frame.image.dispose();
        codec.dispose();
      } catch (_) {
        debugPrint('PROBE recoverable decode failure ${fixture.key}');
      }
    }
  }
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => debugPrint('PROBE first frame complete'),
  );
  WidgetsBinding.instance.scheduleFrame();
}

class MatrixProbe extends StatefulWidget {
  const MatrixProbe({super.key});
  @override
  State<MatrixProbe> createState() => _MatrixProbeState();
}

class _MatrixProbeState extends State<MatrixProbe> {
  bool grid = false, images = false;
  int count = 1, edge = 250;
  late final bytes = rendererFixtures.values.map(base64Decode).toList();
  List<BoundedMemoryImage> providers = [];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => runMatrix());
  }

  Future<void> runMatrix() async {
    var failures = 0;
    for (final nextGrid in [false, true]) {
      for (final nextImages in [false, true]) {
        for (final nextCount in [1, 60]) {
          for (final nextEdge in [250, 2048]) {
            setState(() {
              grid = nextGrid;
              images = nextImages;
              count = nextCount;
              edge = nextEdge;
              providers = List.generate(
                count,
                (i) => BoundedMemoryImage(
                  Uint8List.fromList(bytes[i % bytes.length]),
                  edge,
                ),
              );
            });
            await WidgetsBinding.instance.endOfFrame;
            if (images && mounted) {
              // Deliberately stress concurrent requests; production remains lazy.
              await Future.wait(
                providers
                    .take(12)
                    .map(
                      (image) => precacheImage(
                        image,
                        context,
                        onError: (_, _) {
                          failures++;
                        },
                      ),
                    ),
              );
            }
            await WidgetsBinding.instance.endOfFrame;
            debugPrint(
              'PROBE MATRIX grid=$grid images=$images count=$count edge=$edge failures=$failures',
            );
          }
        }
      }
    }
    debugPrint('PROBE MATRIX COMPLETE failures=$failures');
  }

  @override
  Widget build(BuildContext context) {
    Widget tile(int i) => SizedBox(
      height: 180,
      child: images
          ? Image(
              image: providers[i],
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.broken_image_outlined),
            )
          : const Icon(Icons.restaurant_outlined),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Renderer matrix')),
      body: grid
          ? GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
              ),
              itemCount: count,
              itemBuilder: (_, i) => tile(i),
            )
          : ListView.builder(itemCount: count, itemBuilder: (_, i) => tile(i)),
    );
  }
}
