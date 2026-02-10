import 'dart:convert';
import 'dart:ui';
import 'dart:math' as math;

/// Position and size for a single gamepad button
/// Uses a proportional coordinate system based on the shorter screen dimension
/// to maintain Game Boy-like consistent spacing across devices
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ButtonLayout &&
          x == other.x &&
          y == other.y &&
          size == other.size;

  @override
  int get hashCode => Object.hash(x, y, size);

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'size': size};

  factory ButtonLayout.fromJson(Map<String, dynamic> json) {
    return ButtonLayout(
      x: (json['x'] as num?)?.toDouble() ?? 0.0,
      y: (json['y'] as num?)?.toDouble() ?? 0.0,
      size: (json['size'] as num?)?.toDouble() ?? 1.0,
    );
  }

  /// Convert to pixel offset using FULLY proportional scaling
  /// BOTH x and y scale relative to the shorter screen dimension (unit size)
  /// This ensures Game Boy-like consistent button spacing on ALL devices
  Offset toProportionalOffset(Size screenSize) {
    final unit = math.min(screenSize.width, screenSize.height);
    
    // Both axes use the same unit for truly proportional positioning
    // This makes button layout feel identical across all screen sizes
    return Offset(
      x * unit,
      y * unit,
    );
  }

  /// Legacy offset conversion (for compatibility)
  Offset toOffset(Size screenSize) {
    return Offset(x * screenSize.width, y * screenSize.height);
  }

  static ButtonLayout fromOffset(Offset offset, Size screenSize) {
    return ButtonLayout(
      x: (offset.dx / screenSize.width).clamp(0.0, 1.0),
      y: (offset.dy / screenSize.height).clamp(0.0, 1.0),
    );
  }
  
  /// Create from proportional offset (inverse of toProportionalOffset)
  static ButtonLayout fromProportionalOffset(Offset offset, Size screenSize) {
    final unit = math.min(screenSize.width, screenSize.height);
    
    // Both axes use the same unit
    return ButtonLayout(
      x: (offset.dx / unit).clamp(0.0, 3.0), // Can exceed 1.0 for positioning across screen
      y: (offset.dy / unit).clamp(0.0, 3.0),
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

  /// Portrait layout - screen independent
  /// x: 0-1 = left to right of screen
  /// y: 0-1 = top to bottom of control area (below game)
  static const GamepadLayout defaultPortrait = GamepadLayout(
    // D-pad: bottom-left corner of control area
    dpad: ButtonLayout(
      x: 0.02,
      y: 0.62,
      size: 1.30,
    ),

    // A button: bottom-right, primary action
    aButton: ButtonLayout(
      x: 0.78,
      y: 0.57,
      size: 1.20,
    ),

    // B button: left of A, slightly lower
    bButton: ButtonLayout(
      x: 0.58,
      y: 0.72,
      size: 1.20,
    ),

    // L shoulder: left side, with more clearance from game
    lButton: ButtonLayout(
      x: 0.02,
      y: 0.32,
      size: 1.10,
    ),

    // R shoulder: right side, with more clearance from game
    rButton: ButtonLayout(
      x: 0.82,
      y: 0.32,
      size: 1.10,
    ),

    // Select: center-left
    selectButton: ButtonLayout(
      x: 0.22,
      y: 0.42,
      size: 1.05,
    ),

    // Start: center-right
    startButton: ButtonLayout(
      x: 0.62,
      y: 0.42,
      size: 1.05,
    ),
  );




  /// Landscape layout - screen independent
  /// Left side (D-pad, L, Select): x 0=left edge, 1=near game
  /// Right side (A, B, R, Start): x 0=near game, 1=right edge  
  /// y: 0-1 = top to bottom of screen
  static const GamepadLayout defaultLandscape = GamepadLayout(
    // D-pad: left zone, vertically centered
    dpad: ButtonLayout(
      x: 0.05,
      y: 0.40,
      size: 1.25,
    ),

    // A button: right zone, upper-right (diagonal layout, near game)
    aButton: ButtonLayout(
      x: 0.35,
      y: 0.28,
      size: 1.15,
    ),

    // B button: right zone, lower-left of A (diagonal layout, near game)
    bButton: ButtonLayout(
      x: 0.05,
      y: 0.52,
      size: 1.15,
    ),

    // L shoulder: left zone, top
    lButton: ButtonLayout(
      x: 0.20,
      y: 0.08,
      size: 1.05,
    ),

    // R shoulder: right zone, top
    rButton: ButtonLayout(
      x: 0.40,
      y: 0.08,
      size: 1.05,
    ),

    // Select: left zone, bottom
    selectButton: ButtonLayout(
      x: 0.50,
      y: 0.85,
      size: 1.00,
    ),

    // Start: right zone, bottom (closer to game)
    startButton: ButtonLayout(
      x: 0.20,
      y: 0.85,
      size: 1.00,
    ),
  );





  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GamepadLayout &&
          dpad == other.dpad &&
          aButton == other.aButton &&
          bButton == other.bButton &&
          lButton == other.lButton &&
          rButton == other.rButton &&
          startButton == other.startButton &&
          selectButton == other.selectButton;

  @override
  int get hashCode => Object.hash(
        dpad, aButton, bButton, lButton, rButton, startButton, selectButton);

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

