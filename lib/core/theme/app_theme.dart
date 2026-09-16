import 'package:flutter/material.dart';
import 'server_theme.dart';
import 'layout.dart';

ThemeData cookbookTheme(
  Brightness brightness, {
  ServerTheme server = const ServerTheme(),
}) {
  final dark = brightness == Brightness.dark;
  final surface = Color(dark ? 0xff181818 : 0xffffffff);
  final text = Color(dark ? 0xffd8d8d8 : 0xff222222);
  final muted = Color(dark ? 0xff8c8c8c : 0xff767676);
  final preferred =
      (dark ? server.dark : server.bright) ?? server.element ?? server.color;
  final accent = accessibleAccent(preferred, surface);
  final container = Color.alphaBlend(
    server.color.withValues(alpha: dark ? 0.25 : 0.12),
    surface,
  );
  final colors = ColorScheme(
    brightness: brightness,
    primary: server.color,
    onPrimary: readableOn(server.color, server.text),
    primaryContainer: container,
    onPrimaryContainer: readableOn(container),
    secondary: accent,
    onSecondary: readableOn(accent),
    secondaryContainer: container,
    onSecondaryContainer: readableOn(container),
    tertiary: accent,
    onTertiary: readableOn(accent),
    error: Color(dark ? 0xffffb4ab : 0xffb3261e),
    onError: Color(dark ? 0xff690005 : 0xffffffff),
    surface: surface,
    onSurface: text,
    onSurfaceVariant: muted,
    outline: muted,
    outlineVariant: Color(dark ? 0xff444444 : 0xffd0d0d0),
    surfaceContainerLowest: Color(dark ? 0xff101010 : 0xffffffff),
    surfaceContainerLow: Color(dark ? 0xff202020 : 0xfffafafa),
    surfaceContainer: Color(dark ? 0xff242424 : 0xfff3f3f3),
    surfaceContainerHigh: Color(dark ? 0xff2b2b2b : 0xffededed),
    surfaceContainerHighest: Color(dark ? 0xff333333 : 0xffe6e6e6),
    surfaceTint: Colors.transparent,
  );
  final action = WidgetStateProperty.resolveWith<Color?>(
    (s) => s.contains(WidgetState.disabled) ? null : accent,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    scaffoldBackgroundColor: surface,
    visualDensity: VisualDensity.standard,
    textTheme: Typography.material2021().black
        .copyWith(
          headlineLarge: TextStyle(
            fontSize: 30,
            height: 1.2,
            fontWeight: FontWeight.w600,
            color: text,
          ),
          headlineSmall: TextStyle(
            fontSize: 24,
            height: 1.3,
            fontWeight: FontWeight.w600,
            color: text,
          ),
          titleLarge: TextStyle(
            fontSize: 22,
            height: 1.3,
            fontWeight: FontWeight.w600,
            color: text,
          ),
          titleMedium: TextStyle(
            fontSize: 16,
            height: 1.4,
            fontWeight: FontWeight.w600,
            color: text,
          ),
          bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: text),
          bodyMedium: TextStyle(fontSize: 14, height: 1.45, color: text),
          bodySmall: TextStyle(fontSize: 12, height: 1.4, color: muted),
        )
        .apply(bodyColor: text, displayColor: text),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
    dividerTheme: DividerThemeData(
      color: colors.outlineVariant,
      thickness: .6,
      space: 24,
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
      tilePadding: EdgeInsets.symmetric(horizontal: 0, vertical: 4),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      showDragHandle: true,
    ),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      toolbarHeight: AppLayout.appBarHeight,
      backgroundColor: surface,
      foregroundColor: text,
      surfaceTintColor: Colors.transparent,
    ),
    iconTheme: IconThemeData(color: muted, size: AppLayout.iconSize),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppLayout.radius),
        side: BorderSide(color: colors.outlineVariant, width: .6),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppLayout.controlRadius),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppLayout.controlRadius),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      filled: true,
      fillColor: colors.surfaceContainerLow,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppLayout.controlRadius),
        borderSide: BorderSide(color: accent, width: 2),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: accent,
      selectionColor: container,
      selectionHandleColor: accent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, AppLayout.controlHeight),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppLayout.controlRadius),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, AppLayout.controlHeight),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppLayout.controlRadius),
        ),
        foregroundColor: accent,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: action,
        minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      backgroundColor: surface,
      indicatorColor: container,
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          color: s.contains(WidgetState.selected)
              ? colors.onPrimaryContainer
              : muted,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: surface,
      indicatorColor: container,
      selectedIconTheme: IconThemeData(color: colors.onPrimaryContainer),
      unselectedIconTheme: IconThemeData(
        color: muted,
        size: AppLayout.iconSize,
      ),
      selectedLabelTextStyle: TextStyle(
        color: accent,
        fontFamily: 'Roboto',
        fontSize: 12,
      ),
    ),
    chipTheme: ChipThemeData(
      selectedColor: container,
      checkmarkColor: colors.onPrimaryContainer,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? accent : null,
      ),
      checkColor: WidgetStatePropertyAll(readableOn(accent)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? readableOn(accent) : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? accent : null,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: server.color,
      foregroundColor: readableOn(server.color),
    ),
  );
}
