import 'package:flutter/material.dart';

const nextcloudBlue = Color(0xff0082c9);
Color? parseThemeColor(Object? value) {
  if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    return null;
  }
  return Color(0xff000000 | int.parse(value.substring(1), radix: 16));
}

String colorHex(Color color) =>
    '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}';

class ServerTheme {
  const ServerTheme({
    this.color = nextcloudBlue,
    this.text,
    this.element,
    this.bright,
    this.dark,
    this.detected = false,
  });
  final Color color;
  final Color? text, element, bright, dark;
  final bool detected;
  factory ServerTheme.parse(Object? raw) {
    if (raw is! Map) return const ServerTheme();
    final color = parseThemeColor(raw['color']);
    return ServerTheme(
      color: color ?? nextcloudBlue,
      text: parseThemeColor(raw['color-text']),
      element: parseThemeColor(raw['color-element']),
      bright: parseThemeColor(raw['color-element-bright']),
      dark: parseThemeColor(raw['color-element-dark']),
      detected: color != null,
    );
  }
  Map<String, Object?> toJson() => {
    'color': colorHex(color),
    if (text != null) 'color-text': colorHex(text!),
    if (element != null) 'color-element': colorHex(element!),
    if (bright != null) 'color-element-bright': colorHex(bright!),
    if (dark != null) 'color-element-dark': colorHex(dark!),
    'detected': detected,
  };
  factory ServerTheme.stored(Object? raw) {
    if (raw is! Map || raw['detected'] != true) return const ServerTheme();
    return ServerTheme.parse(raw);
  }
}

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + 0.05) / ((x < y ? x : y) + 0.05);
}

Color readableOn(Color background, [Color? preferred]) {
  if (preferred != null && contrast(preferred, background) >= 4.5) {
    return preferred;
  }
  return contrast(Colors.white, background) > contrast(Colors.black, background)
      ? Colors.white
      : Colors.black;
}

Color accessibleAccent(Color color, Color surface) {
  if (contrast(color, surface) >= 4.5) return color;
  final target = surface.computeLuminance() > 0.5 ? Colors.black : Colors.white;
  for (var i = 1; i <= 20; i++) {
    final candidate = Color.lerp(color, target, i / 20)!;
    if (contrast(candidate, surface) >= 4.5) return candidate;
  }
  return target;
}
