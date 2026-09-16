import 'package:flutter/material.dart';

/// Shared native layout rhythm; text and rows grow with system text scaling.
abstract final class AppLayout {
  static const page = 24.0;
  static const compactPage = 16.0;
  static const section = 24.0;
  static const gap = 12.0;
  static const radius = 12.0;
  static const controlRadius = 10.0;
  static const controlHeight = 48.0;
  static const appBarHeight = 56.0;
  static const iconSize = 24.0;
  static const thumbnail = 64.0;
  static const readingWidth = 1100.0;
  static const settingsWidth = 760.0;
  static const editorWidth = 900.0;
  static const pageInsets = EdgeInsets.all(page);
  static const compactInsets = EdgeInsets.all(compactPage);
}
