import 'package:flutter/material.dart';

/// Defines a complete app color theme
class AppColorTheme {
  final String id;
  final String name;
  final String emoji;

  // Primary colors
  final Color primary;
  final Color primaryDark;
  final Color primaryLight;

  // Accent colors
  final Color accent;
  final Color accentAlt;
  final Color accentYellow;

  // Background colors
  final Color backgroundDark;
  final Color backgroundMedium;
  final Color backgroundLight;
  final Color surface;
  final Color surfaceLight;

  // Text colors
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  // Platform colors
  final Color gbColor;
  final Color gbcColor;
  final Color gbaColor;

  // State colors
  final Color success;
  final Color warning;
  final Color error;

  const AppColorTheme({
    required this.id,
    required this.name,
    required this.emoji,
    required this.primary,
    required this.primaryDark,
    required this.primaryLight,
    required this.accent,
    required this.accentAlt,
    required this.accentYellow,
    required this.backgroundDark,
    required this.backgroundMedium,
    required this.backgroundLight,
    required this.surface,
    required this.surfaceLight,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    this.gbColor = const Color(0xFF8BC34A),
    this.gbcColor = const Color(0xFF03A9F4),
    this.gbaColor = const Color(0xFFE91E63),
    this.success = const Color(0xFF4CAF50),
    this.warning = const Color(0xFFFF9800),
    this.error = const Color(0xFFF44336),
  });
}

/// All available app themes
class AppThemes {
  static const List<AppColorTheme> all = [
    // 0 — Neon Night (default, the original purple/teal theme)
    AppColorTheme(
      id: 'neon_night',
      name: 'Neon Night',
      emoji: '🌃',
      primary: Color(0xFF6B4EE6),
      primaryDark: Color(0xFF4A2FB8),
      primaryLight: Color(0xFF9B7EFF),
      accent: Color(0xFF00F5D4),
      accentAlt: Color(0xFFFF6B6B),
      accentYellow: Color(0xFFFEE440),
      backgroundDark: Color(0xFF0D0D1A),
      backgroundMedium: Color(0xFF151528),
      backgroundLight: Color(0xFF1E1E38),
      surface: Color(0xFF252545),
      surfaceLight: Color(0xFF2D2D55),
      textPrimary: Color(0xFFF0F0FF),
      textSecondary: Color(0xFFA0A0C0),
      textMuted: Color(0xFF606080),
    ),

    // 1 — Crimson Blaze
    AppColorTheme(
      id: 'crimson_blaze',
      name: 'Crimson Blaze',
      emoji: '🔥',
      primary: Color(0xFFE63946),
      primaryDark: Color(0xFFB5212D),
      primaryLight: Color(0xFFFF6B7A),
      accent: Color(0xFFFFB703),
      accentAlt: Color(0xFFFF4D6D),
      accentYellow: Color(0xFFFEE440),
      backgroundDark: Color(0xFF100808),
      backgroundMedium: Color(0xFF1A0F0F),
      backgroundLight: Color(0xFF2A1818),
      surface: Color(0xFF352020),
      surfaceLight: Color(0xFF452A2A),
      textPrimary: Color(0xFFFFF0F0),
      textSecondary: Color(0xFFC0A0A0),
      textMuted: Color(0xFF806060),
    ),

    // 2 — Cyberpunk
    AppColorTheme(
      id: 'cyberpunk',
      name: 'Cyberpunk',
      emoji: '⚡',
      primary: Color(0xFFFF2A6D),
      primaryDark: Color(0xFFD1184F),
      primaryLight: Color(0xFFFF6B9D),
      accent: Color(0xFF05D9E8),
      accentAlt: Color(0xFFFF2A6D),
      accentYellow: Color(0xFFD1F7FF),
      backgroundDark: Color(0xFF01012B),
      backgroundMedium: Color(0xFF050533),
      backgroundLight: Color(0xFF0A0A3E),
      surface: Color(0xFF12124A),
      surfaceLight: Color(0xFF1A1A5C),
      textPrimary: Color(0xFFD1F7FF),
      textSecondary: Color(0xFF7EB8C9),
      textMuted: Color(0xFF3E6A78),
    ),

    // 3 — Emerald Forest
    AppColorTheme(
      id: 'emerald_forest',
      name: 'Emerald',
      emoji: '🌲',
      primary: Color(0xFF00C853),
      primaryDark: Color(0xFF009624),
      primaryLight: Color(0xFF5EFC82),
      accent: Color(0xFF69F0AE),
      accentAlt: Color(0xFFFFD740),
      accentYellow: Color(0xFFFFEB3B),
      backgroundDark: Color(0xFF0A1410),
      backgroundMedium: Color(0xFF0F1D16),
      backgroundLight: Color(0xFF162B20),
      surface: Color(0xFF1E3A2A),
      surfaceLight: Color(0xFF264A35),
      textPrimary: Color(0xFFE8F5E9),
      textSecondary: Color(0xFF8DC49A),
      textMuted: Color(0xFF4E7B5C),
    ),

    // 4 — Midnight Ocean
    AppColorTheme(
      id: 'midnight_ocean',
      name: 'Ocean',
      emoji: '🌊',
      primary: Color(0xFF0088FF),
      primaryDark: Color(0xFF0055CC),
      primaryLight: Color(0xFF55AAFF),
      accent: Color(0xFF00E5FF),
      accentAlt: Color(0xFF7C4DFF),
      accentYellow: Color(0xFF82B1FF),
      backgroundDark: Color(0xFF060D14),
      backgroundMedium: Color(0xFF0A1520),
      backgroundLight: Color(0xFF102030),
      surface: Color(0xFF142840),
      surfaceLight: Color(0xFF1A3250),
      textPrimary: Color(0xFFE3F2FD),
      textSecondary: Color(0xFF90CAF9),
      textMuted: Color(0xFF4A7A9B),
    ),

    // 5 — Sunset Haze
    AppColorTheme(
      id: 'sunset_haze',
      name: 'Sunset',
      emoji: '🌅',
      primary: Color(0xFFFF7043),
      primaryDark: Color(0xFFD84315),
      primaryLight: Color(0xFFFFAB91),
      accent: Color(0xFFFFD54F),
      accentAlt: Color(0xFFFF8A80),
      accentYellow: Color(0xFFFFF176),
      backgroundDark: Color(0xFF140E0A),
      backgroundMedium: Color(0xFF1E150F),
      backgroundLight: Color(0xFF2E2018),
      surface: Color(0xFF3E2C22),
      surfaceLight: Color(0xFF50382C),
      textPrimary: Color(0xFFFFF3E0),
      textSecondary: Color(0xFFCCAA88),
      textMuted: Color(0xFF806650),
    ),
  ];

  static AppColorTheme getById(String id) {
    return all.firstWhere(
      (t) => t.id == id,
      orElse: () => all.first,
    );
  }

  static AppColorTheme getByIndex(int index) {
    if (index < 0 || index >= all.length) return all.first;
    return all[index];
  }
}

/// Provides the current active colors — delegates to the active theme
class YageColors {
  static AppColorTheme _current = AppThemes.all.first;

  /// Set the active theme
  static void setTheme(AppColorTheme theme) {
    _current = theme;
  }

  static AppColorTheme get currentTheme => _current;

  // Primary colors
  static Color get primary => _current.primary;
  static Color get primaryDark => _current.primaryDark;
  static Color get primaryLight => _current.primaryLight;

  // Accent colors
  static Color get accent => _current.accent;
  static Color get accentAlt => _current.accentAlt;
  static Color get accentYellow => _current.accentYellow;

  // Background colors
  static Color get backgroundDark => _current.backgroundDark;
  static Color get backgroundMedium => _current.backgroundMedium;
  static Color get backgroundLight => _current.backgroundLight;
  static Color get surface => _current.surface;
  static Color get surfaceLight => _current.surfaceLight;

  // Text colors
  static Color get textPrimary => _current.textPrimary;
  static Color get textSecondary => _current.textSecondary;
  static Color get textMuted => _current.textMuted;

  // Platform colors
  static Color get gbColor => _current.gbColor;
  static Color get gbcColor => _current.gbcColor;
  static Color get gbaColor => _current.gbaColor;

  // State colors
  static Color get success => _current.success;
  static Color get warning => _current.warning;
  static Color get error => _current.error;
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
      colorScheme: ColorScheme.dark(
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
      appBarTheme: AppBarTheme(
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
          side: BorderSide(color: YageColors.accent, width: 2),
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
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: YageColors.accent,
        foregroundColor: YageColors.backgroundDark,
        elevation: 6,
      ),
      
      // Icons
      iconTheme: IconThemeData(
        color: YageColors.textPrimary,
        size: 24,
      ),
      
      // Text
      textTheme: TextTheme(
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
          borderSide: BorderSide(color: YageColors.surfaceLight, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: YageColors.primary, width: 2),
        ),
        hintStyle: TextStyle(color: YageColors.textMuted),
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
      dividerTheme: DividerThemeData(
        color: YageColors.surfaceLight,
        thickness: 1,
      ),
      
      // Bottom nav
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
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
        contentTextStyle: TextStyle(color: YageColors.textPrimary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      
      // Progress indicator
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: YageColors.accent,
        linearTrackColor: YageColors.surfaceLight,
      ),
      
      // Tab bar
      tabBarTheme: TabBarThemeData(
        labelColor: YageColors.textPrimary,
        unselectedLabelColor: YageColors.textMuted,
        indicatorColor: YageColors.primary,
      ),
    );
  }
}
