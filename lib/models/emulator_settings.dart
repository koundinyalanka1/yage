import 'dart:convert';

import 'game_frame.dart';
import 'gamepad_layout.dart';
import 'gamepad_skin.dart';

/// Emulator settings configuration
class EmulatorSettings {
  final double volume;
  final bool enableSound;
  final int frameSkip;
  final bool showFps;
  final bool enableVibration;
  final double gamepadOpacity;
  final double gamepadScale;
  final bool enableTurbo;
  final double turboSpeed;
  final String? biosPathGba;
  final String? biosPathGb;
  final String? biosPathGbc;
  final bool skipBios;
  final int selectedColorPalette;
  final bool enableFiltering;
  final bool maintainAspectRatio;
  final int autoSaveInterval; // in seconds, 0 = disabled
  final GamepadLayout gamepadLayoutPortrait;
  final GamepadLayout gamepadLayoutLandscape;
  final bool useJoystick; // true = joystick, false = d-pad
  final bool enableExternalGamepad; // physical controller support
  final GamepadSkinType gamepadSkin; // visual theme for touch controls
  final GameFrameType gameFrame; // decorative console shell overlay
  final String selectedTheme; // theme id string
  final bool enableRewind; // hold-to-rewind feature
  final int rewindBufferSeconds; // seconds of rewind history (1-10)
  final String sortOption; // persisted sort choice for the game library
  final bool isGridView; // grid vs list view on the home screen

  const EmulatorSettings({
    this.volume = 0.8,
    this.enableSound = true,
    this.frameSkip = 0,
    this.showFps = false,
    this.enableVibration = true,
    this.gamepadOpacity = 0.7,
    this.gamepadScale = 1.0,
    this.enableTurbo = false,
    this.turboSpeed = 2.0,
    this.biosPathGba,
    this.biosPathGb,
    this.biosPathGbc,
    this.skipBios = true,
    this.selectedColorPalette = 0,
    this.enableFiltering = true,
    this.maintainAspectRatio = true,
    this.autoSaveInterval = 0,
    this.gamepadLayoutPortrait = GamepadLayout.defaultPortrait,
    this.gamepadLayoutLandscape = GamepadLayout.defaultLandscape,
    this.useJoystick = false,
    this.enableExternalGamepad = true,
    this.gamepadSkin = GamepadSkinType.classic,
    this.gameFrame = GameFrameType.none,
    this.selectedTheme = 'neon_night',
    this.enableRewind = false,
    this.rewindBufferSeconds = 3,
    this.sortOption = 'nameAsc',
    this.isGridView = true,
  });

  EmulatorSettings copyWith({
    double? volume,
    bool? enableSound,
    int? frameSkip,
    bool? showFps,
    bool? enableVibration,
    double? gamepadOpacity,
    double? gamepadScale,
    bool? enableTurbo,
    double? turboSpeed,
    String? biosPathGba,
    String? biosPathGb,
    String? biosPathGbc,
    bool? skipBios,
    int? selectedColorPalette,
    bool? enableFiltering,
    bool? maintainAspectRatio,
    int? autoSaveInterval,
    GamepadLayout? gamepadLayoutPortrait,
    GamepadLayout? gamepadLayoutLandscape,
    bool? useJoystick,
    bool? enableExternalGamepad,
    GamepadSkinType? gamepadSkin,
    GameFrameType? gameFrame,
    String? selectedTheme,
    bool? enableRewind,
    int? rewindBufferSeconds,
    String? sortOption,
    bool? isGridView,
  }) {
    return EmulatorSettings(
      volume: volume ?? this.volume,
      enableSound: enableSound ?? this.enableSound,
      frameSkip: frameSkip ?? this.frameSkip,
      showFps: showFps ?? this.showFps,
      enableVibration: enableVibration ?? this.enableVibration,
      gamepadOpacity: gamepadOpacity ?? this.gamepadOpacity,
      gamepadScale: gamepadScale ?? this.gamepadScale,
      enableTurbo: enableTurbo ?? this.enableTurbo,
      turboSpeed: turboSpeed ?? this.turboSpeed,
      biosPathGba: biosPathGba ?? this.biosPathGba,
      biosPathGb: biosPathGb ?? this.biosPathGb,
      biosPathGbc: biosPathGbc ?? this.biosPathGbc,
      skipBios: skipBios ?? this.skipBios,
      selectedColorPalette: selectedColorPalette ?? this.selectedColorPalette,
      enableFiltering: enableFiltering ?? this.enableFiltering,
      maintainAspectRatio: maintainAspectRatio ?? this.maintainAspectRatio,
      autoSaveInterval: autoSaveInterval ?? this.autoSaveInterval,
      gamepadLayoutPortrait: gamepadLayoutPortrait ?? this.gamepadLayoutPortrait,
      gamepadLayoutLandscape: gamepadLayoutLandscape ?? this.gamepadLayoutLandscape,
      useJoystick: useJoystick ?? this.useJoystick,
      enableExternalGamepad: enableExternalGamepad ?? this.enableExternalGamepad,
      gamepadSkin: gamepadSkin ?? this.gamepadSkin,
      gameFrame: gameFrame ?? this.gameFrame,
      selectedTheme: selectedTheme ?? this.selectedTheme,
      enableRewind: enableRewind ?? this.enableRewind,
      rewindBufferSeconds: rewindBufferSeconds ?? this.rewindBufferSeconds,
      sortOption: sortOption ?? this.sortOption,
      isGridView: isGridView ?? this.isGridView,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'volume': volume,
      'enableSound': enableSound,
      'frameSkip': frameSkip,
      'showFps': showFps,
      'enableVibration': enableVibration,
      'gamepadOpacity': gamepadOpacity,
      'gamepadScale': gamepadScale,
      'enableTurbo': enableTurbo,
      'turboSpeed': turboSpeed,
      'biosPathGba': biosPathGba,
      'biosPathGb': biosPathGb,
      'biosPathGbc': biosPathGbc,
      'skipBios': skipBios,
      'selectedColorPalette': selectedColorPalette,
      'enableFiltering': enableFiltering,
      'maintainAspectRatio': maintainAspectRatio,
      'autoSaveInterval': autoSaveInterval,
      'gamepadLayoutPortrait': gamepadLayoutPortrait.toJson(),
      'gamepadLayoutLandscape': gamepadLayoutLandscape.toJson(),
      'useJoystick': useJoystick,
      'enableExternalGamepad': enableExternalGamepad,
      'gamepadSkin': gamepadSkin.index,
      'gameFrame': gameFrame.index,
      'selectedTheme': selectedTheme,
      'enableRewind': enableRewind,
      'rewindBufferSeconds': rewindBufferSeconds,
      'sortOption': sortOption,
      'isGridView': isGridView,
    };
  }

  factory EmulatorSettings.fromJson(Map<String, dynamic> json) {
    return EmulatorSettings(
      volume: (json['volume'] as num?)?.toDouble() ?? 0.8,
      enableSound: json['enableSound'] as bool? ?? true,
      frameSkip: json['frameSkip'] as int? ?? 0,
      showFps: json['showFps'] as bool? ?? false,
      enableVibration: json['enableVibration'] as bool? ?? true,
      gamepadOpacity: (json['gamepadOpacity'] as num?)?.toDouble() ?? 0.7,
      gamepadScale: (json['gamepadScale'] as num?)?.toDouble() ?? 1.0,
      enableTurbo: json['enableTurbo'] as bool? ?? false,
      turboSpeed: (json['turboSpeed'] as num?)?.toDouble() ?? 2.0,
      biosPathGba: json['biosPathGba'] as String?,
      biosPathGb: json['biosPathGb'] as String?,
      biosPathGbc: json['biosPathGbc'] as String?,
      skipBios: json['skipBios'] as bool? ?? true,
      selectedColorPalette: json['selectedColorPalette'] as int? ?? 0,
      enableFiltering: json['enableFiltering'] as bool? ?? true,
      maintainAspectRatio: json['maintainAspectRatio'] as bool? ?? true,
      autoSaveInterval: json['autoSaveInterval'] as int? ?? 0,
      gamepadLayoutPortrait: json['gamepadLayoutPortrait'] != null
          ? GamepadLayout.fromJson(json['gamepadLayoutPortrait'] as Map<String, dynamic>)
          : GamepadLayout.defaultPortrait,
      gamepadLayoutLandscape: json['gamepadLayoutLandscape'] != null
          ? GamepadLayout.fromJson(json['gamepadLayoutLandscape'] as Map<String, dynamic>)
          : GamepadLayout.defaultLandscape,
      useJoystick: json['useJoystick'] as bool? ?? false,
      enableExternalGamepad: json['enableExternalGamepad'] as bool? ?? true,
      gamepadSkin: GamepadSkinType.values.elementAtOrNull(
        json['gamepadSkin'] as int? ?? 0,
      ) ?? GamepadSkinType.classic,
      gameFrame: GameFrameType.values.elementAtOrNull(
        json['gameFrame'] as int? ?? 0,
      ) ?? GameFrameType.none,
      selectedTheme: json['selectedTheme'] as String? ?? 'neon_night',
      enableRewind: json['enableRewind'] as bool? ?? false,
      rewindBufferSeconds: json['rewindBufferSeconds'] as int? ?? 3,
      sortOption: json['sortOption'] as String? ?? 'nameAsc',
      isGridView: json['isGridView'] as bool? ?? true,
    );
  }

  String toJsonString() => jsonEncode(toJson());
  
  factory EmulatorSettings.fromJsonString(String json) =>
      EmulatorSettings.fromJson(jsonDecode(json) as Map<String, dynamic>);
}

/// Color palettes for original Game Boy
class GBColorPalette {
  static const List<String> names = [
    'Classic Green',
    'Original DMG',
    'Pocket',
    'Light',
    'Kiosk',
    'Grayscale',
    'Super Game Boy',
  ];

  static const List<List<int>> palettes = [
    [0x9BBC0F, 0x8BAC0F, 0x306230, 0x0F380F], // Classic Green
    [0x7B8210, 0x5A7942, 0x39594A, 0x294139], // Original DMG
    [0xC4CFA1, 0x8B956D, 0x4D533C, 0x1F1F1F], // Pocket
    [0x00B581, 0x009A71, 0x00694A, 0x004F3B], // Light
    [0xFFE4C2, 0xDCA456, 0xA9604C, 0x422936], // Kiosk
    [0xFFFFFF, 0xAAAAAA, 0x555555, 0x000000], // Grayscale
    [0xF7E7C6, 0xD68E49, 0xA63725, 0x331E50], // Super Game Boy
  ];
}

