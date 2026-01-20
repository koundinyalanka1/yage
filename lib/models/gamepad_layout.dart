import 'dart:convert';
import 'dart:ui';

/// Position and size for a single gamepad button
class ButtonLayout {
  final double x; // Relative position (0.0 - 1.0 from left)
  final double y; // Relative position (0.0 - 1.0 from top)
  final double size; // Scale multiplier (1.0 = default)

  const ButtonLayout({
    required this.x,
    required this.y,
    this.size = 1.0,
  });

  ButtonLayout copyWith({double? x, double? y, double? size}) {
    return ButtonLayout(
      x: x ?? this.x,
      y: y ?? this.y,
      size: size ?? this.size,
    );
  }

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'size': size};

  factory ButtonLayout.fromJson(Map<String, dynamic> json) {
    return ButtonLayout(
      x: (json['x'] as num?)?.toDouble() ?? 0.0,
      y: (json['y'] as num?)?.toDouble() ?? 0.0,
      size: (json['size'] as num?)?.toDouble() ?? 1.0,
    );
  }

  Offset toOffset(Size screenSize) {
    return Offset(x * screenSize.width, y * screenSize.height);
  }

  static ButtonLayout fromOffset(Offset offset, Size screenSize) {
    return ButtonLayout(
      x: (offset.dx / screenSize.width).clamp(0.0, 1.0),
      y: (offset.dy / screenSize.height).clamp(0.0, 1.0),
    );
  }
}

/// Complete gamepad layout configuration
class GamepadLayout {
  final ButtonLayout dpad;
  final ButtonLayout aButton;
  final ButtonLayout bButton;
  final ButtonLayout lButton;
  final ButtonLayout rButton;
  final ButtonLayout startButton;
  final ButtonLayout selectButton;

  const GamepadLayout({
    required this.dpad,
    required this.aButton,
    required this.bButton,
    required this.lButton,
    required this.rButton,
    required this.startButton,
    required this.selectButton,
  });

  /// Default portrait layout - well spaced for comfortable play
  static const GamepadLayout defaultPortrait = GamepadLayout(
    dpad: ButtonLayout(x: 0.02, y: 0.45, size: 1.0),
    aButton: ButtonLayout(x: 0.72, y: 0.45, size: 1.0),
    bButton: ButtonLayout(x: 0.55, y: 0.62, size: 1.0),
    lButton: ButtonLayout(x: 0.02, y: 0.05, size: 1.0),
    rButton: ButtonLayout(x: 0.78, y: 0.05, size: 1.0),
    startButton: ButtonLayout(x: 0.55, y: 0.88, size: 1.0),
    selectButton: ButtonLayout(x: 0.28, y: 0.88, size: 1.0),
  );

  /// Default landscape layout - buttons spread to sides
  static const GamepadLayout defaultLandscape = GamepadLayout(
    dpad: ButtonLayout(x: 0.01, y: 0.30, size: 0.9),
    aButton: ButtonLayout(x: 0.82, y: 0.25, size: 0.9),
    bButton: ButtonLayout(x: 0.68, y: 0.50, size: 0.9),
    lButton: ButtonLayout(x: 0.01, y: 0.0, size: 0.85),
    rButton: ButtonLayout(x: 0.87, y: 0.0, size: 0.85),
    startButton: ButtonLayout(x: 0.55, y: 0.82, size: 0.85),
    selectButton: ButtonLayout(x: 0.35, y: 0.82, size: 0.85),
  );

  GamepadLayout copyWith({
    ButtonLayout? dpad,
    ButtonLayout? aButton,
    ButtonLayout? bButton,
    ButtonLayout? lButton,
    ButtonLayout? rButton,
    ButtonLayout? startButton,
    ButtonLayout? selectButton,
  }) {
    return GamepadLayout(
      dpad: dpad ?? this.dpad,
      aButton: aButton ?? this.aButton,
      bButton: bButton ?? this.bButton,
      lButton: lButton ?? this.lButton,
      rButton: rButton ?? this.rButton,
      startButton: startButton ?? this.startButton,
      selectButton: selectButton ?? this.selectButton,
    );
  }

  Map<String, dynamic> toJson() => {
    'dpad': dpad.toJson(),
    'aButton': aButton.toJson(),
    'bButton': bButton.toJson(),
    'lButton': lButton.toJson(),
    'rButton': rButton.toJson(),
    'startButton': startButton.toJson(),
    'selectButton': selectButton.toJson(),
  };

  factory GamepadLayout.fromJson(Map<String, dynamic> json) {
    return GamepadLayout(
      dpad: json['dpad'] != null 
          ? ButtonLayout.fromJson(json['dpad']) 
          : GamepadLayout.defaultPortrait.dpad,
      aButton: json['aButton'] != null 
          ? ButtonLayout.fromJson(json['aButton']) 
          : GamepadLayout.defaultPortrait.aButton,
      bButton: json['bButton'] != null 
          ? ButtonLayout.fromJson(json['bButton']) 
          : GamepadLayout.defaultPortrait.bButton,
      lButton: json['lButton'] != null 
          ? ButtonLayout.fromJson(json['lButton']) 
          : GamepadLayout.defaultPortrait.lButton,
      rButton: json['rButton'] != null 
          ? ButtonLayout.fromJson(json['rButton']) 
          : GamepadLayout.defaultPortrait.rButton,
      startButton: json['startButton'] != null 
          ? ButtonLayout.fromJson(json['startButton']) 
          : GamepadLayout.defaultPortrait.startButton,
      selectButton: json['selectButton'] != null 
          ? ButtonLayout.fromJson(json['selectButton']) 
          : GamepadLayout.defaultPortrait.selectButton,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory GamepadLayout.fromJsonString(String json) =>
      GamepadLayout.fromJson(jsonDecode(json) as Map<String, dynamic>);
}

/// Button identifiers for editing
enum GamepadButton {
  dpad,
  aButton,
  bButton,
  lButton,
  rButton,
  startButton,
  selectButton,
}

