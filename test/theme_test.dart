import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cookbook/core/theme/server_theme.dart';
import 'package:cookbook/core/theme/app_theme.dart';

void main() {
  test('default Nextcloud blue and neutral palettes', () {
    final light = cookbookTheme(Brightness.light),
        dark = cookbookTheme(Brightness.dark);
    expect(light.colorScheme.primary, nextcloudBlue);
    expect(light.scaffoldBackgroundColor, const Color(0xffffffff));
    expect(light.colorScheme.onSurface, const Color(0xff222222));
    expect(dark.scaffoldBackgroundColor, const Color(0xff181818));
    expect(dark.colorScheme.onSurface, const Color(0xffd8d8d8));
  });
  for (final value in [
    null,
    {},
    {'color': 'not a color'},
    {'color': '#12'},
    {'color': 'url(SECRET)'},
  ]) {
    test('missing/malformed theme falls back safely: $value', () {
      final t = ServerTheme.parse(value);
      expect(t.color, nextcloudBlue);
      expect(t.detected, false);
      expect(t.toJson().toString(), isNot(contains('SECRET')));
    });
  }
  for (final color in ['#1177AA', '#FFFFFF', '#000000']) {
    for (final brightness in Brightness.values) {
      test('$color theme has readable foregrounds in ${brightness.name}', () {
        final server = ServerTheme.parse({
          'color': color,
          'color-text': '#FFFFFF',
          'color-element-bright': '#EEEEEE',
          'color-element-dark': '#111111',
          'logo': 'https://secret.test/token',
          'slogan': 'SECRET',
        });
        final theme = cookbookTheme(brightness, server: server),
            scheme = cookbookTheme(brightness, server: server).colorScheme;
        expect(scheme.primary, parseThemeColor(color));
        expect(
          contrast(scheme.primary, scheme.onPrimary),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(scheme.secondary, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(scheme.primaryContainer, scheme.onPrimaryContainer),
          greaterThanOrEqualTo(4.5),
        );
        expect(theme.scaffoldBackgroundColor, scheme.surface);
        expect(server.toJson().toString(), isNot(contains('SECRET')));
        expect(server.toJson().containsKey('logo'), false);
        expect(ServerTheme.stored(server.toJson()).color, server.color);
      });
    }
  }
}
