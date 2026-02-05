import 'package:flutter/material.dart';

/// RetroPal color palette - inspired by retro gaming with modern twist
class YageColors {
  // Primary colors - deep purple/violet theme
  static const Color primary = Color(0xFF6B4EE6);
  static const Color primaryDark = Color(0xFF4A2FB8);
  static const Color primaryLight = Color(0xFF9B7EFF);
  
  // Accent colors - neon highlights
  static const Color accent = Color(0xFF00F5D4);
  static const Color accentAlt = Color(0xFFFF6B6B);
  static const Color accentYellow = Color(0xFFFEE440);
  
  // Background colors
  static const Color backgroundDark = Color(0xFF0D0D1A);
  static const Color backgroundMedium = Color(0xFF151528);
  static const Color backgroundLight = Color(0xFF1E1E38);
  static const Color surface = Color(0xFF252545);
  static const Color surfaceLight = Color(0xFF2D2D55);
  
  // Text colors
  static const Color textPrimary = Color(0xFFF0F0FF);
  static const Color textSecondary = Color(0xFFA0A0C0);
  static const Color textMuted = Color(0xFF606080);
  
  // Platform colors
  static const Color gbColor = Color(0xFF8BC34A);
  static const Color gbcColor = Color(0xFF03A9F4);
  static const Color gbaColor = Color(0xFFE91E63);
  
  // State colors
  static const Color success = Color(0xFF4CAF50);
  static const Color warning = Color(0xFFFF9800);
  static const Color error = Color(0xFFF44336);
}

/// RetroPal theme configuration
class YageTheme {
  static const String _fontFamily = 'Rajdhani';
  static const String _monoFontFamily = 'JetBrains Mono';

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: _fontFamily,
      
      // Color scheme
      colorScheme: const ColorScheme.dark(
        primary: YageColors.primary,
        secondary: YageColors.accent,
        surface: YageColors.surface,
        error: YageColors.error,
        onPrimary: YageColors.textPrimary,
        onSecondary: YageColors.backgroundDark,
        onSurface: YageColors.textPrimary,
        onError: YageColors.textPrimary,
      ),
      
      // Scaffold
      scaffoldBackgroundColor: YageColors.backgroundDark,
      
      // AppBar
      appBarTheme: const AppBarTheme(
        backgroundColor: YageColors.backgroundMedium,
        foregroundColor: YageColors.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: YageColors.textPrimary,
        ),
      ),
      
      // Cards
      cardTheme: CardThemeData(
        color: YageColors.surface,
        elevation: 4,
        shadowColor: Colors.black54,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      
      // Buttons
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: YageColors.primary,
          foregroundColor: YageColors.textPrimary,
          elevation: 4,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontFamily: _fontFamily,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: YageColors.accent,
          side: const BorderSide(color: YageColors.accent, width: 2),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: YageColors.accent,
        ),
      ),
      
      // FAB
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: YageColors.accent,
        foregroundColor: YageColors.backgroundDark,
        elevation: 6,
      ),
      
      // Icons
      iconTheme: const IconThemeData(
        color: YageColors.textPrimary,
        size: 24,
      ),
      
      // Text
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 48,
          fontWeight: FontWeight.bold,
          color: YageColors.textPrimary,
        ),
        displayMedium: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 36,
          fontWeight: FontWeight.bold,
          color: YageColors.textPrimary,
        ),
        displaySmall: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 28,
          fontWeight: FontWeight.bold,
          color: YageColors.textPrimary,
        ),
        headlineLarge: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: YageColors.textPrimary,
        ),
        headlineMedium: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: YageColors.textPrimary,
        ),
        headlineSmall: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: YageColors.textPrimary,
        ),
        titleLarge: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: YageColors.textPrimary,
        ),
        titleMedium: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: YageColors.textPrimary,
        ),
        titleSmall: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: YageColors.textSecondary,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          color: YageColors.textPrimary,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          color: YageColors.textSecondary,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          color: YageColors.textMuted,
        ),
        labelLarge: TextStyle(
          fontFamily: _monoFontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: YageColors.textPrimary,
        ),
        labelMedium: TextStyle(
          fontFamily: _monoFontFamily,
          fontSize: 12,
          color: YageColors.textSecondary,
        ),
        labelSmall: TextStyle(
          fontFamily: _monoFontFamily,
          fontSize: 10,
          color: YageColors.textMuted,
        ),
      ),
      
      // Input decoration
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: YageColors.backgroundLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: YageColors.surfaceLight, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: YageColors.primary, width: 2),
        ),
        hintStyle: const TextStyle(color: YageColors.textMuted),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      
      // Slider
      sliderTheme: SliderThemeData(
        activeTrackColor: YageColors.primary,
        inactiveTrackColor: YageColors.surfaceLight,
        thumbColor: YageColors.accent,
        overlayColor: YageColors.accent.withAlpha(51),
        trackHeight: 4,
      ),
      
      // Switch
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return YageColors.accent;
          }
          return YageColors.textMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return YageColors.primary;
          }
          return YageColors.surfaceLight;
        }),
      ),
      
      // Divider
      dividerTheme: const DividerThemeData(
        color: YageColors.surfaceLight,
        thickness: 1,
      ),
      
      // Bottom nav
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: YageColors.backgroundMedium,
        selectedItemColor: YageColors.accent,
        unselectedItemColor: YageColors.textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
      
      // Dialogs
      dialogTheme: DialogThemeData(
        backgroundColor: YageColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      
      // Snackbar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: YageColors.surfaceLight,
        contentTextStyle: const TextStyle(color: YageColors.textPrimary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      
      // Progress indicator
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: YageColors.accent,
        linearTrackColor: YageColors.surfaceLight,
      ),
      
      // Tab bar
      tabBarTheme: const TabBarThemeData(
        labelColor: YageColors.textPrimary,
        unselectedLabelColor: YageColors.textMuted,
        indicatorColor: YageColors.primary,
      ),
    );
  }
}
