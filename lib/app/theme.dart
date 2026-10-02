import 'package:flutter/material.dart';

// Unified research design: Dify light hierarchy, Grok neutral dark, system CJK fonts.
// No proprietary font copied; Folio color retained as restrained interaction accent.
ThemeData workbenchTheme({bool dark = false}) {
  final canvas = Color(dark ? 0xFF131211 : 0xFFF2F4F7);
  final surface = Color(dark ? 0xFF181716 : 0xFFFFFFFF);
  final accent = Color(dark ? 0xFF7BA2FF : 0xFF2458D3);
  final rule = Color(dark ? 0xFF35332F : 0xFFE2E6EC);
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: dark ? Brightness.dark : Brightness.light,
    primary: accent,
    surface: surface,
    onSurface: Color(dark ? 0xFFFCFCFC : 0xFF101828),
    primaryContainer: Color(dark ? 0xFF1C2A4D : 0xFFE8EFFF),
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: canvas,
    fontFamilyFallback: const [
      'PingFang SC',
      'Microsoft YaHei UI',
      'Noto Sans CJK SC',
    ],
    textTheme: const TextTheme(
      titleLarge: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 1.35,
      ),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      bodyLarge: TextStyle(fontSize: 16, height: 1.625),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: canvas,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: shape.copyWith(side: BorderSide(color: rule)),
    ),
    dividerTheme: DividerThemeData(color: rule, thickness: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: shape),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(shape: shape),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: rule),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: scheme.primaryContainer,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Color(dark ? 0xFF151413 : 0xFFEEF1F5),
      indicatorColor: scheme.primaryContainer,
    ),
  );
}
