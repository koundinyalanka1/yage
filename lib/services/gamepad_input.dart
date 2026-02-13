import 'package:flutter/services.dart';

import '../core/mgba_bindings.dart';

/// Maps physical gamepad and keyboard buttons to GBA key bitmask values.
///
/// Supports:
/// - Standard Bluetooth/USB gamepads (D-pad, face buttons, shoulders, start/select)
/// - Keyboard fallbacks (arrows, Z/X, A/S, Enter, Shift)
/// - Platform-specific layouts (SNES gets X/Y face buttons)
class GamepadMapper {
  /// Default mapping for GB/GBC/GBA/NES: LogicalKeyboardKey → GBAKey bitmask
  static final Map<LogicalKeyboardKey, int> defaultMapping = {
    // ── D-pad (arrow keys — used by both keyboard and gamepad D-pad) ──
    LogicalKeyboardKey.arrowUp: GBAKey.up,
    LogicalKeyboardKey.arrowDown: GBAKey.down,
    LogicalKeyboardKey.arrowLeft: GBAKey.left,
    LogicalKeyboardKey.arrowRight: GBAKey.right,

    // ── Gamepad face buttons ──
    LogicalKeyboardKey.gameButtonA: GBAKey.a,
    LogicalKeyboardKey.gameButtonB: GBAKey.b,
    LogicalKeyboardKey.gameButtonX: GBAKey.b, // alternate B
    LogicalKeyboardKey.gameButtonY: GBAKey.a, // alternate A

    // ── Shoulder buttons / triggers ──
    LogicalKeyboardKey.gameButtonLeft1: GBAKey.l,
    LogicalKeyboardKey.gameButtonRight1: GBAKey.r,
    LogicalKeyboardKey.gameButtonLeft2: GBAKey.l, // trigger → L
    LogicalKeyboardKey.gameButtonRight2: GBAKey.r, // trigger → R

    // ── Start / Select ──
    LogicalKeyboardKey.gameButtonStart: GBAKey.start,
    LogicalKeyboardKey.gameButtonSelect: GBAKey.select,

    // ── Keyboard fallbacks ──
    LogicalKeyboardKey.keyZ: GBAKey.a,
    LogicalKeyboardKey.keyX: GBAKey.b,
    LogicalKeyboardKey.keyA: GBAKey.l,
    LogicalKeyboardKey.keyS: GBAKey.r,
    LogicalKeyboardKey.enter: GBAKey.start,
    LogicalKeyboardKey.shiftRight: GBAKey.select,
    LogicalKeyboardKey.backspace: GBAKey.select,
    LogicalKeyboardKey.space: GBAKey.a,
  };

  /// SNES mapping: all 4 face buttons (A, B, X, Y) are distinct.
  static final Map<LogicalKeyboardKey, int> snesMapping = {
    // ── D-pad ──
    LogicalKeyboardKey.arrowUp: GBAKey.up,
    LogicalKeyboardKey.arrowDown: GBAKey.down,
    LogicalKeyboardKey.arrowLeft: GBAKey.left,
    LogicalKeyboardKey.arrowRight: GBAKey.right,

    // ── Gamepad face buttons (SNES diamond: B=south, A=east, Y=west, X=north) ──
    LogicalKeyboardKey.gameButtonA: GBAKey.a,   // east  → A
    LogicalKeyboardKey.gameButtonB: GBAKey.b,   // south → B
    LogicalKeyboardKey.gameButtonX: GBAKey.x,   // north → X
    LogicalKeyboardKey.gameButtonY: GBAKey.y,   // west  → Y

    // ── Shoulder buttons / triggers ──
    LogicalKeyboardKey.gameButtonLeft1: GBAKey.l,
    LogicalKeyboardKey.gameButtonRight1: GBAKey.r,
    LogicalKeyboardKey.gameButtonLeft2: GBAKey.l,
    LogicalKeyboardKey.gameButtonRight2: GBAKey.r,

    // ── Start / Select ──
    LogicalKeyboardKey.gameButtonStart: GBAKey.start,
    LogicalKeyboardKey.gameButtonSelect: GBAKey.select,

    // ── Keyboard fallbacks ──
    LogicalKeyboardKey.keyZ: GBAKey.a,
    LogicalKeyboardKey.keyX: GBAKey.b,
    LogicalKeyboardKey.keyC: GBAKey.x,
    LogicalKeyboardKey.keyV: GBAKey.y,
    LogicalKeyboardKey.keyA: GBAKey.l,
    LogicalKeyboardKey.keyS: GBAKey.r,
    LogicalKeyboardKey.enter: GBAKey.start,
    LogicalKeyboardKey.shiftRight: GBAKey.select,
    LogicalKeyboardKey.backspace: GBAKey.select,
    LogicalKeyboardKey.space: GBAKey.a,
  };

  /// Get the appropriate mapping for the given platform.
  static Map<LogicalKeyboardKey, int> mappingForPlatform(GamePlatform platform) {
    return switch (platform) {
      GamePlatform.snes => snesMapping,
      _ => defaultMapping,
    };
  }

  /// Keys that indicate a real gamepad (not keyboard) is in use
  static final Set<LogicalKeyboardKey> _gamepadOnlyKeys = {
    LogicalKeyboardKey.gameButtonA,
    LogicalKeyboardKey.gameButtonB,
    LogicalKeyboardKey.gameButtonX,
    LogicalKeyboardKey.gameButtonY,
    LogicalKeyboardKey.gameButtonLeft1,
    LogicalKeyboardKey.gameButtonRight1,
    LogicalKeyboardKey.gameButtonLeft2,
    LogicalKeyboardKey.gameButtonRight2,
    LogicalKeyboardKey.gameButtonStart,
    LogicalKeyboardKey.gameButtonSelect,
  };

  /// Currently pressed physical keys (logical → GBA bitmask contribution)
  final Set<LogicalKeyboardKey> _activeKeys = {};

  /// Current computed bitmask of all pressed GBA keys
  int _pressedKeys = 0;

  /// Whether an actual gamepad controller has been detected this session
  bool _controllerDetected = false;

  final Map<LogicalKeyboardKey, int> _mapping;

  GamepadMapper({Map<LogicalKeyboardKey, int>? mapping})
      : _mapping = mapping ?? defaultMapping;

  /// Current GBA key bitmask from physical input
  int get keys => _pressedKeys;

  /// True once a real gamepad button (not keyboard) has been pressed
  bool get controllerDetected => _controllerDetected;

  /// Handle a [KeyEvent] from Flutter's focus/keyboard system.
  /// Returns `true` if the event was recognised and consumed.
  bool handleKeyEvent(KeyEvent event) {
    final logicalKey = event.logicalKey;
    if (!_mapping.containsKey(logicalKey)) return false;

    // Detect real gamepad hardware (not just keyboard)
    if (!_controllerDetected && _gamepadOnlyKeys.contains(logicalKey)) {
      _controllerDetected = true;
    }

    if (event is KeyDownEvent) {
      _activeKeys.add(logicalKey);
    } else if (event is KeyUpEvent) {
      _activeKeys.remove(logicalKey);
    }
    // KeyRepeatEvent — key already in _activeKeys, nothing to change

    // Rebuild bitmask from all active keys
    _rebuildBitmask();
    return true;
  }

  void _rebuildBitmask() {
    int mask = 0;
    for (final key in _activeKeys) {
      final gbaKey = _mapping[key];
      if (gbaKey != null) {
        mask |= gbaKey;
      }
    }
    _pressedKeys = mask;
  }

  /// Reset all pressed keys (e.g. when focus lost or game paused)
  void reset() {
    _activeKeys.clear();
    _pressedKeys = 0;
  }

  /// Reset the controller-detected flag so a reconnecting gamepad
  /// can be detected afresh (e.g. after a Bluetooth disconnect).
  void resetDetection() {
    _controllerDetected = false;
  }
}
