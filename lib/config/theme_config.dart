import 'package:flutter/material.dart';

class ThemeConfig {
  static ThemeData theme(Color color, Brightness brightness) {
    ColorScheme colorScheme = ColorScheme.fromSeed(seedColor: color, brightness: brightness);

    if (brightness == Brightness.dark) {
      colorScheme = colorScheme.copyWith(
        surface: Colors.black,
        surfaceTint: Colors.transparent,
        surfaceContainerHighest: const Color(0xFF1A1A1A),
      );
    }

    ThemeData themeData = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,

      /// default w500 is not supported for chinese characters in some devices
      textTheme: const TextTheme(titleMedium: TextStyle(fontWeight: FontWeight.w400)),
      appBarTheme: const AppBarTheme(scrolledUnderElevation: 0),
      navigationBarTheme: const NavigationBarThemeData(
        height: 48,
        surfaceTintColor: Colors.transparent,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
      ),
      popupMenuTheme: const PopupMenuThemeData(surfaceTintColor: Colors.transparent),
    );

    return themeData.copyWith(
      appBarTheme: themeData.appBarTheme.copyWith(backgroundColor: colorScheme.surface),
      dialogTheme: DialogThemeData(backgroundColor: colorScheme.surface),
    );
  }
}
