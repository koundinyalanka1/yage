import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/mgba_bindings.dart';
import '../models/gamepad_layout.dart';
import '../models/gamepad_skin.dart';
import '../utils/theme.dart';

/// Virtual gamepad for touch input
class VirtualGamepad extends StatefulWidget {
  final Rect gameRect;

  final void Function(int keys) onKeysChanged;
  final double opacity;
  final double scale;
  final bool enableVibration;
  final GamepadLayout layout;
  final bool editMode;
  final void Function(GamepadLayout)? onLayoutChanged;
  final bool useJoystick; // true = joystick, false = d-pad
  final GamepadSkinType skin;
  /// Current platform — controls which buttons are shown.
  ///   • NES: hides L/R (only A, B, Start, Select, D-pad)
  ///   • SNES: shows X, Y in addition to A, B, L, R
  ///   • GB/GBA/unknown: default layout (A, B, L, R, Start, Select, D-pad)
  final GamePlatform platform;

  const VirtualGamepad({
    super.key,
    required this.gameRect,
    required this.onKeysChanged,
    this.opacity = 0.7,
    this.scale = 1.0,
    this.enableVibration = true,
    required this.layout,
    this.editMode = false,
    this.onLayoutChanged,
    this.useJoystick = false,
    this.skin = GamepadSkinType.classic,
    this.platform = GamePlatform.gba,
  });

  @override
  State<VirtualGamepad> createState() => _VirtualGamepadState();
}


class _VirtualGamepadState extends State<VirtualGamepad> {
  int _currentKeys = 0;
  GamepadButton? _selectedButton;
  late GamepadLayout _editingLayout;
  late GamepadSkinData _resolvedSkin;

  /// Cooldown guard so rapid touch events don't spam the haptic engine.
  final Stopwatch _hapticCooldown = Stopwatch();
  static const Duration _hapticMinInterval = Duration(milliseconds: 60);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Resolve the skin using the current theme from the widget tree.
    // This runs after initState and whenever Theme changes.
    _resolvedSkin = GamepadSkinData.resolve(
      widget.skin,
      AppColorTheme.of(context),
    );
  }

  @override
  void initState() {
    super.initState();
    _editingLayout = widget.layout;
  }

  @override
  void didUpdateWidget(VirtualGamepad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layout != widget.layout) {
      _editingLayout = widget.layout;
    }
    if (oldWidget.skin != widget.skin) {
      _resolvedSkin = GamepadSkinData.resolve(
        widget.skin,
        AppColorTheme.of(context),
      );
    }
  }

  void _updateKey(int key, bool pressed) {
    if (widget.editMode) return; // Disable input in edit mode
    
    final newKeys = pressed 
        ? (_currentKeys | key)
        : (_currentKeys & ~key);
    
    if (newKeys != _currentKeys) {
      _currentKeys = newKeys;
      widget.onKeysChanged(_currentKeys);
      
      if (pressed && widget.enableVibration) {
        if (!_hapticCooldown.isRunning ||
            _hapticCooldown.elapsed >= _hapticMinInterval) {
          HapticFeedback.lightImpact();
          _hapticCooldown.reset();
          _hapticCooldown.start();
        }
      }
    }
  }

  void _onButtonDrag(GamepadButton button, Offset delta, Size screenSize) {
    if (!widget.editMode) return;
    
    final bool isPortrait = screenSize.height > screenSize.width;
    final Rect gameRect = widget.gameRect;
    
    setState(() {
      _selectedButton = button;
      final currentLayout = _getButtonLayout(button);
      
      double newX, newY;
      
      // Use proportional margins (2% of screen dimension)
      final double marginPercent = 0.02;
      
      if (isPortrait) {
        // Portrait: widget IS the control area
        final double marginX = screenSize.width * marginPercent;
        final double marginY = screenSize.height * marginPercent;
        final double usableWidth = screenSize.width - marginX * 2;
        final double usableHeight = screenSize.height - marginY * 2;
        
        newX = (currentLayout.x + delta.dx / usableWidth).clamp(0.0, 1.0);
        newY = (currentLayout.y + delta.dy / usableHeight).clamp(0.0, 1.0);
      } else {
        // Landscape: x spans zone width, y spans full height
        final double edgePadding = screenSize.width * marginPercent;
        final double gameGap = screenSize.width * 0.01;
        
        final bool isLeftSide =
            button == GamepadButton.dpad ||
            button == GamepadButton.lButton ||
            button == GamepadButton.selectButton;
        // X/Y/A/B/R/Start are right side — no special handling needed
        
        final double zoneWidth = isLeftSide
            ? math.max(1, gameRect.left - gameGap - edgePadding)
            : math.max(1, screenSize.width - edgePadding - gameRect.right - gameGap);
        
        final double usableHeight = screenSize.height - edgePadding * 2;
        
        newX = (currentLayout.x + delta.dx / zoneWidth).clamp(0.0, 1.0);
        newY = (currentLayout.y + delta.dy / usableHeight).clamp(0.0, 1.0);
      }

      _editingLayout = _updateButtonLayout(
        button,
        currentLayout.copyWith(x: newX, y: newY),
      );
    });
    
    widget.onLayoutChanged?.call(_editingLayout);
  }

  /// Minimum touch target in logical pixels (per Material Design guidelines).
  static const double _minTouchTarget = 36.0;

  /// Per-button-type scale limits.
  /// D-pad / joystick can be larger; small utility buttons have a tighter range.
  static (double min, double max) _sizeRange(GamepadButton button) {
    return switch (button) {
      GamepadButton.dpad          => (0.70, 2.50),
      GamepadButton.aButton       => (0.70, 2.00),
      GamepadButton.bButton       => (0.70, 2.00),
      GamepadButton.xButton       => (0.70, 2.00),
      GamepadButton.yButton       => (0.70, 2.00),
      GamepadButton.lButton       => (0.80, 2.00),
      GamepadButton.rButton       => (0.80, 2.00),
      GamepadButton.startButton   => (0.80, 1.80),
      GamepadButton.selectButton  => (0.80, 1.80),
    };
  }

  void _onButtonResize(GamepadButton button, double scaleDelta) {
    if (!widget.editMode) return;
    
    setState(() {
      _selectedButton = button;
      final currentLayout = _getButtonLayout(button);
      final (minScale, maxScale) = _sizeRange(button);
      final newSize = (currentLayout.size + scaleDelta).clamp(minScale, maxScale);
      
      // Enforce a minimum pixel size so the button stays tappable.
      // Compute the smallest dimension at the candidate scale and reject
      // the resize if it would drop below the touch-target threshold.
      final gameRect = widget.gameRect;
      final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;
      final sizeRef = isPortrait
          ? gameRect.width
          : MediaQuery.of(context).size.height;
      final baseSize = isPortrait ? sizeRef * 0.28 : sizeRef * 0.26;
      final buttonBase = isPortrait ? sizeRef * 0.17 : sizeRef * 0.16;

      final double smallestDim;
      switch (button) {
        case GamepadButton.dpad:
          smallestDim = baseSize * newSize * widget.scale;
        case GamepadButton.aButton:
        case GamepadButton.bButton:
        case GamepadButton.xButton:
        case GamepadButton.yButton:
          smallestDim = buttonBase * newSize * widget.scale;
        case GamepadButton.lButton:
        case GamepadButton.rButton:
          // Height is the smallest dimension for shoulder buttons
          smallestDim = baseSize * 0.30 * newSize * widget.scale;
        case GamepadButton.startButton:
        case GamepadButton.selectButton:
          smallestDim = baseSize * 0.12 * newSize * widget.scale;
      }

      if (smallestDim < _minTouchTarget && scaleDelta < 0) {
        // Would shrink below minimum tappable size — ignore
        return;
      }

      _editingLayout = _updateButtonLayout(
        button,
        currentLayout.copyWith(size: newSize),
      );
    });
    
    widget.onLayoutChanged?.call(_editingLayout);
  }

  ButtonLayout _getButtonLayout(GamepadButton button) {
    switch (button) {
      case GamepadButton.dpad:
        return _editingLayout.dpad;
      case GamepadButton.aButton:
        return _editingLayout.aButton;
      case GamepadButton.bButton:
        return _editingLayout.bButton;
      case GamepadButton.lButton:
        return _editingLayout.lButton;
      case GamepadButton.rButton:
        return _editingLayout.rButton;
      case GamepadButton.startButton:
        return _editingLayout.startButton;
      case GamepadButton.selectButton:
        return _editingLayout.selectButton;
      case GamepadButton.xButton:
        return _editingLayout.xButton ?? GamepadLayout.defaultPortrait.xButton!;
      case GamepadButton.yButton:
        return _editingLayout.yButton ?? GamepadLayout.defaultPortrait.yButton!;
    }
  }

  GamepadLayout _updateButtonLayout(GamepadButton button, ButtonLayout layout) {
    switch (button) {
      case GamepadButton.dpad:
        return _editingLayout.copyWith(dpad: layout);
      case GamepadButton.aButton:
        return _editingLayout.copyWith(aButton: layout);
      case GamepadButton.bButton:
        return _editingLayout.copyWith(bButton: layout);
      case GamepadButton.lButton:
        return _editingLayout.copyWith(lButton: layout);
      case GamepadButton.rButton:
        return _editingLayout.copyWith(rButton: layout);
      case GamepadButton.startButton:
        return _editingLayout.copyWith(startButton: layout);
      case GamepadButton.selectButton:
        return _editingLayout.copyWith(selectButton: layout);
      case GamepadButton.xButton:
        return _editingLayout.copyWith(xButton: layout);
      case GamepadButton.yButton:
        return _editingLayout.copyWith(yButton: layout);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Opacity(
      opacity: widget.opacity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final screenSize = Size(constraints.maxWidth, constraints.maxHeight);
          final layout = _editingLayout;
          
          // Responsive sizing based on screen
          final gameRect = widget.gameRect;

// Size relative to GAME in portrait; relative to screen height in
          // landscape so buttons stay consistent regardless of game aspect
          // ratio (GB/GBC is nearly square → narrower gameRect in landscape).
          final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;

          final sizeRef = isPortrait ? gameRect.width : screenSize.height;

          final baseSize = isPortrait
              ? sizeRef * 0.28
              : sizeRef * 0.26;

          final buttonBase = isPortrait
              ? sizeRef * 0.17
              : sizeRef * 0.16;
          // D-pad / joystick boost: 10% bigger in portrait, 25% bigger in
          // landscape (user request — gives more comfortable thumb target).
          final dpadBoost = isPortrait ? 1.1 : 1.25;

          // Use cached skin data (resolved in initState / didUpdateWidget)
          final skin = _resolvedSkin;

          // Pre-compute child sizes for each button so the clamp logic can
          // keep the entire widget on screen, not just its top-left corner.
          final dpadScale = layout.dpad.size * widget.scale * dpadBoost;
          final dpadSize = Size(baseSize * dpadScale, baseSize * dpadScale);

          final aSize = buttonBase * layout.aButton.size * widget.scale;
          final bSize = buttonBase * layout.bButton.size * widget.scale;

          final lScale = layout.lButton.size * widget.scale;
          final lSize = Size(baseSize * 0.55 * lScale, baseSize * 0.30 * lScale);

          final rScale = layout.rButton.size * widget.scale;
          final rSize = Size(baseSize * 0.55 * rScale, baseSize * 0.30 * rScale);

          final startScale = layout.startButton.size * widget.scale;
          // SmallButton uses padding; approximate outer size
          final startSize = Size(
            baseSize * 0.20 * startScale + baseSize * 0.20 * startScale,
            baseSize * 0.12 * startScale + baseSize * 0.12 * startScale,
          );

          final selectScale = layout.selectButton.size * widget.scale;
          final selectSize = Size(
            baseSize * 0.20 * selectScale + baseSize * 0.20 * selectScale,
            baseSize * 0.12 * selectScale + baseSize * 0.12 * selectScale,
          );

          // ── Determine active buttons based on platform ──
          final bool showLR = widget.platform != GamePlatform.nes;
          final bool showXY = widget.platform == GamePlatform.snes;

          // ── Pre-compute all button sizes ──
          final buttonSizes = <GamepadButton, Size>{
            GamepadButton.dpad: dpadSize,
            GamepadButton.aButton: Size(aSize, aSize),
            GamepadButton.bButton: Size(bSize, bSize),
            if (showLR) GamepadButton.lButton: lSize,
            if (showLR) GamepadButton.rButton: rSize,
            GamepadButton.startButton: startSize,
            GamepadButton.selectButton: selectSize,
          };

          // SNES X / Y sizes (same sizing logic as A/B)
          if (showXY) {
            final xLayout = layout.xButton ?? GamepadLayout.defaultPortrait.xButton!;
            final yLayout = layout.yButton ?? GamepadLayout.defaultPortrait.yButton!;
            final xSize = buttonBase * xLayout.size * widget.scale;
            final ySize = buttonBase * yLayout.size * widget.scale;
            buttonSizes[GamepadButton.xButton] = Size(xSize, xSize);
            buttonSizes[GamepadButton.yButton] = Size(ySize, ySize);
          }

          // ── Pre-compute raw pixel positions for active buttons ──
          final rawPositions = <GamepadButton, Offset>{};
          for (final btn in buttonSizes.keys) {
            rawPositions[btn] = _computeButtonPosition(
              layout: _getButtonLayout(btn),
              screenSize: screenSize,
              button: btn,
              childSize: buttonSizes[btn]!,
            );
          }

          // ── Resolve collisions so no two buttons overlap ──
          final resolvedPositions = _resolveCollisions(
            positions: rawPositions,
            sizes: buttonSizes,
            screenSize: screenSize,
            isPortrait: isPortrait,
          );

          return Stack(
            children: [
              // D-Pad or Joystick
              _buildButtonAtPosition(
                position: resolvedPositions[GamepadButton.dpad]!,
                button: GamepadButton.dpad,
                screenSize: screenSize,
                child: widget.useJoystick
                    ? _Joystick(
                        onDirectionChanged: (up, down, left, right) {
                          _updateKey(GBAKey.up, up);
                          _updateKey(GBAKey.down, down);
                          _updateKey(GBAKey.left, left);
                          _updateKey(GBAKey.right, right);
                        },
                        scale: dpadScale,
                        baseSize: baseSize,
                        editMode: widget.editMode,
                        skin: skin,
                      )
                    : _DPad(
                  onDirectionChanged: (up, down, left, right) {
                    _updateKey(GBAKey.up, up);
                    _updateKey(GBAKey.down, down);
                    _updateKey(GBAKey.left, left);
                    _updateKey(GBAKey.right, right);
                  },
                  scale: dpadScale,
                  baseSize: baseSize,
                  editMode: widget.editMode,
                  skin: skin,
                ),
              ),
              
              // A Button
              _buildButtonAtPosition(
                position: resolvedPositions[GamepadButton.aButton]!,
                button: GamepadButton.aButton,
                screenSize: screenSize,
                child: _CircleButton(
                  label: 'A',
                  color: colors.accentAlt,
                  onChanged: (pressed) => _updateKey(GBAKey.a, pressed),
                  size: aSize,
                  editMode: widget.editMode,
                  skin: skin,
                ),
              ),
              
              // B Button
              _buildButtonAtPosition(
                position: resolvedPositions[GamepadButton.bButton]!,
                button: GamepadButton.bButton,
                screenSize: screenSize,
                child: _CircleButton(
                  label: 'B',
                  color: colors.accentYellow,
                  onChanged: (pressed) => _updateKey(GBAKey.b, pressed),
                  size: bSize,
                  editMode: widget.editMode,
                  skin: skin,
                ),
              ),
              
              // L Button (hidden for NES)
              if (showLR)
                _buildButtonAtPosition(
                  position: resolvedPositions[GamepadButton.lButton]!,
                  button: GamepadButton.lButton,
                  screenSize: screenSize,
                  child: _ShoulderButton(
                    label: 'L',
                    onChanged: (pressed) => _updateKey(GBAKey.l, pressed),
                    scale: lScale,
                    baseSize: baseSize,
                    editMode: widget.editMode,
                    skin: skin,
                  ),
                ),
              
              // R Button (hidden for NES)
              if (showLR)
                _buildButtonAtPosition(
                  position: resolvedPositions[GamepadButton.rButton]!,
                  button: GamepadButton.rButton,
                  screenSize: screenSize,
                  child: _ShoulderButton(
                    label: 'R',
                    onChanged: (pressed) => _updateKey(GBAKey.r, pressed),
                    scale: rScale,
                    baseSize: baseSize,
                    editMode: widget.editMode,
                    skin: skin,
                  ),
                ),

              // SNES X Button
              if (showXY)
                _buildButtonAtPosition(
                  position: resolvedPositions[GamepadButton.xButton]!,
                  button: GamepadButton.xButton,
                  screenSize: screenSize,
                  child: _CircleButton(
                    label: 'X',
                    color: colors.primary,
                    onChanged: (pressed) => _updateKey(GBAKey.x, pressed),
                    size: buttonSizes[GamepadButton.xButton]!.width,
                    editMode: widget.editMode,
                    skin: skin,
                  ),
                ),

              // SNES Y Button
              if (showXY)
                _buildButtonAtPosition(
                  position: resolvedPositions[GamepadButton.yButton]!,
                  button: GamepadButton.yButton,
                  screenSize: screenSize,
                  child: _CircleButton(
                    label: 'Y',
                    color: colors.success,
                    onChanged: (pressed) => _updateKey(GBAKey.y, pressed),
                    size: buttonSizes[GamepadButton.yButton]!.width,
                    editMode: widget.editMode,
                    skin: skin,
                  ),
                ),
              
              // Start Button
              _buildButtonAtPosition(
                position: resolvedPositions[GamepadButton.startButton]!,
                button: GamepadButton.startButton,
                screenSize: screenSize,
                child: _SmallButton(
                  label: 'START',
                  onChanged: (pressed) => _updateKey(GBAKey.start, pressed),
                  scale: startScale,
                  baseSize: baseSize,
                  editMode: widget.editMode,
                  skin: skin,
                ),
              ),
              
              // Select Button
              _buildButtonAtPosition(
                position: resolvedPositions[GamepadButton.selectButton]!,
                button: GamepadButton.selectButton,
                screenSize: screenSize,
                child: _SmallButton(
                  label: 'SELECT',
                  onChanged: (pressed) => _updateKey(GBAKey.select, pressed),
                  scale: selectScale,
                  baseSize: baseSize,
                  editMode: widget.editMode,
                  skin: skin,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────
  // Position computation — pure function, no widget creation
  // ────────────────────────────────────────────────────────────────
  Offset _computeButtonPosition({
    required ButtonLayout layout,
    required Size screenSize,
    required GamepadButton button,
    required Size childSize,
  }) {
    final Rect gameRect = widget.gameRect;
    final bool isPortrait = screenSize.height > screenSize.width;

    double x = 0.0;
    double y = 0.0;

    const double marginPercent = 0.02;

    if (isPortrait) {
      final double widgetW = screenSize.width;
      final double widgetH = screenSize.height;
      final double marginX = widgetW * marginPercent;
      final double marginY = widgetH * marginPercent;
      final double usableWidth = widgetW - marginX * 2;
      final double usableHeight = widgetH - marginY * 2;
      x = marginX + layout.x * usableWidth;
      y = marginY + layout.y * usableHeight;
    } else {
      final double screenW = screenSize.width;
      final double screenH = screenSize.height;
      final double edgePadding = screenW * marginPercent;
      final double gameGap = screenW * 0.01;

      final double leftZoneLeft = edgePadding;
      final double leftZoneRight = gameRect.left - gameGap;
      final double leftZoneWidth = math.max(0, leftZoneRight - leftZoneLeft);

      final double rightZoneLeft = gameRect.right + gameGap;
      final double rightZoneRight = screenW - edgePadding;
      final double rightZoneWidth = math.max(0, rightZoneRight - rightZoneLeft);

      final double marginY = edgePadding;
      final double usableHeight = screenH - marginY * 2;

      final bool isLeftSide =
          button == GamepadButton.dpad ||
          button == GamepadButton.lButton ||
          button == GamepadButton.selectButton;

      if (isLeftSide) {
        x = leftZoneLeft + layout.x * leftZoneWidth;
      } else {
        x = rightZoneLeft + layout.x * rightZoneWidth;
      }
      y = marginY + layout.y * usableHeight;
    }

    // ── Safe clamp ──
    final double minMargin = screenSize.width * 0.01;
    final double minYMargin = isPortrait
        ? minMargin
        : (screenSize.width * 0.107).clamp(36.0, 56.0) + screenSize.height * 0.02;

    final double clampedX = x.clamp(
      minMargin,
      math.max(minMargin, screenSize.width - childSize.width - minMargin),
    );
    final double clampedY = y.clamp(
      minYMargin,
      math.max(minYMargin, screenSize.height - childSize.height - minMargin),
    );

    return Offset(clampedX, clampedY);
  }

  // ────────────────────────────────────────────────────────────────
  // Collision resolution — ensures a minimum gap between every pair
  // of buttons, regardless of user/saved configuration.
  // Uses iterative pair-wise separation clamped to screen bounds.
  // ────────────────────────────────────────────────────────────────
  Map<GamepadButton, Offset> _resolveCollisions({
    required Map<GamepadButton, Offset> positions,
    required Map<GamepadButton, Size> sizes,
    required Size screenSize,
    required bool isPortrait,
  }) {
    // Minimum gap between any two button rects (proportional to shorter dim).
    final double minGap = math.min(screenSize.width, screenSize.height) * 0.015;

    final double minMargin = screenSize.width * 0.01;
    final double minYMargin = isPortrait
        ? minMargin
        : (screenSize.width * 0.107).clamp(36.0, 56.0) + screenSize.height * 0.02;

    // Work on mutable copies.
    final pos = Map<GamepadButton, Offset>.from(positions);

    // Run a few iterations — most layouts converge in 2-3.
    for (int iter = 0; iter < 4; iter++) {
      bool moved = false;
      // Only iterate over buttons that are actually present (platform-dependent).
      final buttons = positions.keys.toList();
      for (int i = 0; i < buttons.length; i++) {
        for (int j = i + 1; j < buttons.length; j++) {
          final a = buttons[i];
          final b = buttons[j];
          final sa = sizes[a]!;
          final sb = sizes[b]!;

          // Inflate rects by half the gap on each side.
          final rA = Rect.fromLTWH(
            pos[a]!.dx - minGap / 2,
            pos[a]!.dy - minGap / 2,
            sa.width + minGap,
            sa.height + minGap,
          );
          final rB = Rect.fromLTWH(
            pos[b]!.dx - minGap / 2,
            pos[b]!.dy - minGap / 2,
            sb.width + minGap,
            sb.height + minGap,
          );

          if (!rA.overlaps(rB)) continue;

          moved = true;

          // Compute overlap on each axis.
          final overlapX = math.min(rA.right, rB.right) - math.max(rA.left, rB.left);
          final overlapY = math.min(rA.bottom, rB.bottom) - math.max(rA.top, rB.top);

          // Push apart along the axis with the SMALLER overlap (cheaper move).
          if (overlapX < overlapY) {
            final half = overlapX / 2 + 0.5; // +0.5 to break ties
            final sign = pos[a]!.dx <= pos[b]!.dx ? -1.0 : 1.0;
            pos[a] = Offset(pos[a]!.dx + sign * half, pos[a]!.dy);
            pos[b] = Offset(pos[b]!.dx - sign * half, pos[b]!.dy);
          } else {
            final half = overlapY / 2 + 0.5;
            final sign = pos[a]!.dy <= pos[b]!.dy ? -1.0 : 1.0;
            pos[a] = Offset(pos[a]!.dx, pos[a]!.dy + sign * half);
            pos[b] = Offset(pos[b]!.dx, pos[b]!.dy - sign * half);
          }

          // Re-clamp both buttons to screen bounds.
          pos[a] = Offset(
            pos[a]!.dx.clamp(minMargin, math.max(minMargin, screenSize.width - sa.width - minMargin)),
            pos[a]!.dy.clamp(minYMargin, math.max(minYMargin, screenSize.height - sa.height - minMargin)),
          );
          pos[b] = Offset(
            pos[b]!.dx.clamp(minMargin, math.max(minMargin, screenSize.width - sb.width - minMargin)),
            pos[b]!.dy.clamp(minYMargin, math.max(minYMargin, screenSize.height - sb.height - minMargin)),
          );
        }
      }

      if (!moved) break; // Already non-overlapping.
    }

    return pos;
  }

  // ────────────────────────────────────────────────────────────────
  // Build a positioned button widget at a pre-computed position
  // ────────────────────────────────────────────────────────────────
  Widget _buildButtonAtPosition({
    required Offset position,
    required GamepadButton button,
    required Size screenSize,
    required Widget child,
  }) {
    final isSelected = widget.editMode && _selectedButton == button;

    return Positioned(
      left: position.dx,
      top: position.dy,
      child: widget.editMode
          ? _EditableButtonWrapper(
              isSelected: isSelected,
              onDrag: (delta) => _onButtonDrag(button, delta, screenSize),
              onScaleUp: () => _onButtonResize(button, 0.1),
              onScaleDown: () => _onButtonResize(button, -0.1),
              onTap: () => setState(() => _selectedButton = button),
              child: child,
            )
          : child,
    );
  }

}

/// Wrapper for making buttons editable (draggable + resizable)
class _EditableButtonWrapper extends StatelessWidget {
  final Widget child;
  final bool isSelected;
  final void Function(Offset delta) onDrag;
  final VoidCallback onScaleUp;
  final VoidCallback onScaleDown;
  final VoidCallback onTap;

  const _EditableButtonWrapper({
    required this.child,
    required this.isSelected,
    required this.onDrag,
    required this.onScaleUp,
    required this.onScaleDown,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      onPanUpdate: (details) => onDrag(details.delta),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Selection indicator
          if (isSelected)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: colors.accent,
                    width: 3,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          
          // The actual button
          child,
          
          // Resize controls (only when selected)
          if (isSelected) ...[
            // Scale up button
            Positioned(
              top: -20,
              right: -20,
              child: GestureDetector(
                onTap: onScaleUp,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: colors.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: const Icon(Icons.add, color: Colors.white, size: 20),
                ),
              ),
            ),
            // Scale down button
            Positioned(
              bottom: -20,
              right: -20,
              child: GestureDetector(
                onTap: onScaleDown,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: colors.error,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: const Icon(Icons.remove, color: Colors.white, size: 20),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// D-Pad widget
class _DPad extends StatefulWidget {
  final void Function(bool up, bool down, bool left, bool right) onDirectionChanged;
  final double scale;
  final double baseSize;
  final bool editMode;
  final GamepadSkinData skin;

  const _DPad({
    required this.onDirectionChanged,
    this.scale = 1.0,
    this.baseSize = 190.0,
    this.editMode = false,
    required this.skin,
  });

  @override
  State<_DPad> createState() => _DPadState();
}

class _DPadState extends State<_DPad> {
  bool _up = false;
  bool _down = false;
  bool _left = false;
  bool _right = false;

  void _handlePan(Offset localPosition, Size size) {
    if (widget.editMode) return;
    
    final center = Offset(size.width / 2, size.height / 2);
    final delta = localPosition - center;
    final deadzone = size.width * 0.15;
    
    final newUp = delta.dy < -deadzone;
    final newDown = delta.dy > deadzone;
    final newLeft = delta.dx < -deadzone;
    final newRight = delta.dx > deadzone;
    
    if (newUp != _up || newDown != _down || 
        newLeft != _left || newRight != _right) {
      setState(() {
        _up = newUp;
        _down = newDown;
        _left = newLeft;
        _right = newRight;
      });
      widget.onDirectionChanged(_up, _down, _left, _right);
    }
  }

  void _reset() {
    if (_up || _down || _left || _right) {
      setState(() {
        _up = false;
        _down = false;
        _left = false;
        _right = false;
      });
      widget.onDirectionChanged(false, false, false, false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.baseSize * widget.scale;
    final buttonSize = size * 0.34;
    
    return GestureDetector(
      onPanStart: widget.editMode ? null : (details) => _handlePan(details.localPosition, Size(size, size)),
      onPanUpdate: widget.editMode ? null : (details) => _handlePan(details.localPosition, Size(size, size)),
      onPanEnd: widget.editMode ? null : (_) => _reset(),
      onPanCancel: widget.editMode ? null : _reset,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          children: [
            // Background
            Center(
              child: Container(
                width: size - 16,
                height: size - 16,
                decoration: BoxDecoration(
                  color: widget.skin.dpadBackground,
                  borderRadius: BorderRadius.circular(widget.skin.dpadRadius),
                  border: Border.all(
                    color: widget.skin.dpadBorder,
                    width: widget.skin.dpadBorderWidth,
                  ),
                  boxShadow: widget.skin.normalShadows,
                ),
              ),
            ),
            
            // Up
            Positioned(
              top: 0,
              left: (size - buttonSize) / 2,
              child: _DPadButton(
                isPressed: _up,
                icon: Icons.keyboard_arrow_up,
                size: buttonSize,
                skin: widget.skin,
              ),
            ),
            
            // Down
            Positioned(
              bottom: 0,
              left: (size - buttonSize) / 2,
              child: _DPadButton(
                isPressed: _down,
                icon: Icons.keyboard_arrow_down,
                size: buttonSize,
                skin: widget.skin,
              ),
            ),
            
            // Left
            Positioned(
              left: 0,
              top: (size - buttonSize) / 2,
              child: _DPadButton(
                isPressed: _left,
                icon: Icons.keyboard_arrow_left,
                size: buttonSize,
                skin: widget.skin,
              ),
            ),
            
            // Right
            Positioned(
              right: 0,
              top: (size - buttonSize) / 2,
              child: _DPadButton(
                isPressed: _right,
                icon: Icons.keyboard_arrow_right,
                size: buttonSize,
                skin: widget.skin,
              ),
            ),
            
            // Center circle
            Center(
              child: Container(
                width: 36 * widget.scale,
                height: 36 * widget.scale,
                decoration: BoxDecoration(
                  color: widget.skin.dpadCenter,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.skin.dpadBorder,
                    width: widget.skin.dpadBorderWidth,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DPadButton extends StatelessWidget {
  final bool isPressed;
  final IconData icon;
  final double size;
  final GamepadSkinData skin;

  const _DPadButton({
    required this.isPressed,
    required this.icon,
    this.size = 60,
    required this.skin,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isPressed ? skin.buttonFillPressed : skin.buttonFill,
        borderRadius: BorderRadius.circular(skin.buttonRadius),
        border: Border.all(
          color: isPressed ? skin.buttonBorderPressed : skin.buttonBorder,
          width: skin.buttonBorderWidth,
        ),
        boxShadow: isPressed ? skin.pressedShadows : skin.normalShadows,
      ),
      child: Icon(
        icon,
        color: isPressed ? skin.textPressed : skin.textNormal,
        size: size * 0.55,
      ),
    );
  }
}

class _CircleButton extends StatefulWidget {
  final String label;
  final Color color;
  final void Function(bool pressed) onChanged;
  final double size;
  final bool editMode;
  final GamepadSkinData skin;

  const _CircleButton({
    required this.label,
    required this.color,
    required this.onChanged,
    this.size = 80,
    this.editMode = false,
    required this.skin,
  });

  @override
  State<_CircleButton> createState() => _CircleButtonState();
}

class _CircleButtonState extends State<_CircleButton> {
  bool _isPressed = false;

  void _setPressed(bool pressed) {
    if (widget.editMode) return;
    
    if (pressed != _isPressed) {
      setState(() => _isPressed = pressed);
      widget.onChanged(pressed);
      if (pressed) HapticFeedback.lightImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.editMode ? null : (_) => _setPressed(true),
      onTapUp: widget.editMode ? null : (_) => _setPressed(false),
      onTapCancel: widget.editMode ? null : () => _setPressed(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: _isPressed
              ? widget.skin.buttonFillPressed
              : widget.skin.buttonFill,
          shape: BoxShape.circle,
          border: Border.all(
            color: _isPressed
                ? widget.skin.buttonBorderPressed
                : widget.skin.buttonBorder,
            width: widget.skin.buttonBorderWidth,
          ),
          boxShadow: _isPressed
              ? widget.skin.pressedShadows
              : widget.skin.normalShadows,
        ),
        child: Center(
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: widget.size * 0.35,
              fontWeight: FontWeight.bold,
              color: _isPressed
                  ? widget.skin.textPressed
                  : widget.skin.textNormal,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shoulder button (L/R)
class _ShoulderButton extends StatefulWidget {
  final String label;
  final void Function(bool pressed) onChanged;
  final double scale;
  final double baseSize;
  final bool editMode;
  final GamepadSkinData skin;

  const _ShoulderButton({
    required this.label,
    required this.onChanged,
    this.scale = 1.0,
    this.baseSize = 80.0,
    this.editMode = false,
    required this.skin,
  });

  @override
  State<_ShoulderButton> createState() => _ShoulderButtonState();
}

class _ShoulderButtonState extends State<_ShoulderButton> {
  bool _isPressed = false;

  void _setPressed(bool pressed) {
    if (widget.editMode) return;
    
    if (pressed != _isPressed) {
      setState(() => _isPressed = pressed);
      widget.onChanged(pressed);
      if (pressed) HapticFeedback.lightImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.editMode ? null : (_) => _setPressed(true),
      onTapUp: widget.editMode ? null : (_) => _setPressed(false),
      onTapCancel: widget.editMode ? null : () => _setPressed(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        width: widget.baseSize * 0.55 * widget.scale,
        height: widget.baseSize * 0.30 * widget.scale,
        decoration: BoxDecoration(
          color: _isPressed
              ? widget.skin.buttonFillPressed
              : widget.skin.buttonFill,
          borderRadius: BorderRadius.circular(widget.skin.buttonRadius + 2),
          border: Border.all(
            color: _isPressed
                ? widget.skin.buttonBorderPressed
                : widget.skin.buttonBorder,
            width: widget.skin.buttonBorderWidth,
          ),
          boxShadow: _isPressed
              ? widget.skin.pressedShadows
              : widget.skin.normalShadows,
        ),
        child: Center(
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: widget.baseSize * 0.12 * widget.scale,
              fontWeight: FontWeight.bold,
              color: _isPressed
                  ? widget.skin.textPressed
                  : widget.skin.textNormal,
            ),
          ),
        ),
      ),
    );
  }
}

/// Small button (Start/Select)
class _SmallButton extends StatefulWidget {
  final String label;
  final void Function(bool pressed) onChanged;
  final double scale;
  final double baseSize;
  final bool editMode;
  final GamepadSkinData skin;

  const _SmallButton({
    required this.label,
    required this.onChanged,
    this.scale = 1.0,
    this.baseSize = 80.0,
    this.editMode = false,
    required this.skin,
  });

  @override
  State<_SmallButton> createState() => _SmallButtonState();
}

class _SmallButtonState extends State<_SmallButton> {
  bool _isPressed = false;

  void _setPressed(bool pressed) {
    if (widget.editMode) return;
    
    if (pressed != _isPressed) {
      setState(() => _isPressed = pressed);
      widget.onChanged(pressed);
      if (pressed) HapticFeedback.lightImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.editMode ? null : (_) => _setPressed(true),
      onTapUp: widget.editMode ? null : (_) => _setPressed(false),
      onTapCancel: widget.editMode ? null : () => _setPressed(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        padding: EdgeInsets.symmetric(
          horizontal: widget.baseSize * 0.10 * widget.scale,
          vertical: widget.baseSize * 0.06 * widget.scale,
        ),
        decoration: BoxDecoration(
          color: _isPressed
              ? widget.skin.buttonFillPressed
              : widget.skin.buttonFill,
          borderRadius: BorderRadius.circular(widget.skin.buttonRadius),
          border: Border.all(
            color: _isPressed
                ? widget.skin.buttonBorderPressed
                : widget.skin.buttonBorder,
            width: widget.skin.buttonBorderWidth,
          ),
          boxShadow: _isPressed
              ? widget.skin.pressedShadows
              : widget.skin.normalShadows,
        ),
        child: Text(
          widget.label,
          style: TextStyle(
            fontSize: widget.baseSize * 0.09 * widget.scale,
            fontWeight: FontWeight.bold,
            color: _isPressed
                ? widget.skin.textPressed
                : widget.skin.textNormal,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}

/// Joystick widget - analog-style directional input
class _Joystick extends StatefulWidget {
  final void Function(bool up, bool down, bool left, bool right) onDirectionChanged;
  final double scale;
  final double baseSize;
  final bool editMode;
  final GamepadSkinData skin;

  const _Joystick({
    required this.onDirectionChanged,
    this.scale = 1.0,
    this.baseSize = 190.0,
    this.editMode = false,
    required this.skin,
  });

  @override
  State<_Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<_Joystick> {
  Offset _stickPosition = Offset.zero;
  bool _up = false;
  bool _down = false;
  bool _left = false;
  bool _right = false;

  void _handlePan(Offset localPosition, Size size) {
    if (widget.editMode) return;
    
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width * 0.35;
    final deadzone = size.width * 0.12;
    
    Offset delta = localPosition - center;
    
    // Clamp to max radius
    final distance = delta.distance;
    if (distance > maxRadius) {
      delta = delta * (maxRadius / distance);
    }
    
    setState(() {
      _stickPosition = delta;
    });
    
    // Calculate directions based on position
    final newUp = delta.dy < -deadzone;
    final newDown = delta.dy > deadzone;
    final newLeft = delta.dx < -deadzone;
    final newRight = delta.dx > deadzone;
    
    if (newUp != _up || newDown != _down || 
        newLeft != _left || newRight != _right) {
      _up = newUp;
      _down = newDown;
      _left = newLeft;
      _right = newRight;
      widget.onDirectionChanged(_up, _down, _left, _right);
    }
  }

  void _reset() {
    setState(() {
      _stickPosition = Offset.zero;
    });
    
    if (_up || _down || _left || _right) {
      _up = false;
      _down = false;
      _left = false;
      _right = false;
      widget.onDirectionChanged(false, false, false, false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.baseSize * widget.scale;
    final stickSize = size * 0.45;
    
    return GestureDetector(
      onPanStart: widget.editMode ? null : (details) => _handlePan(details.localPosition, Size(size, size)),
      onPanUpdate: widget.editMode ? null : (details) => _handlePan(details.localPosition, Size(size, size)),
      onPanEnd: widget.editMode ? null : (_) => _reset(),
      onPanCancel: widget.editMode ? null : _reset,
        child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Outer ring (background)
            Container(
              width: size - 8,
              height: size - 8,
              decoration: BoxDecoration(
                color: widget.skin.joystickBg,
                shape: BoxShape.circle,
                border: Border.all(
                  color: widget.skin.joystickBorder,
                  width: widget.skin.joystickBorderWidth,
                ),
                boxShadow: widget.skin.normalShadows,
              ),
            ),
            
            // Direction indicators (subtle)
            ..._buildDirectionIndicators(size),
            
            // Movable stick
            Transform.translate(
              offset: _stickPosition,
              child: Container(
                width: stickSize,
                height: stickSize,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      widget.skin.stickColor,
                      widget.skin.stickColor.withAlpha(
                        (widget.skin.stickColor.a * 255 * 0.78).round().clamp(0, 255),
                      ),
                    ],
                    center: const Alignment(-0.3, -0.3),
                  ),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.skin.stickBorder,
                    width: widget.skin.joystickBorderWidth,
                  ),
                  boxShadow: widget.skin.pressedShadows.isNotEmpty
                      ? widget.skin.pressedShadows
                      : [
                          BoxShadow(
                            color: widget.skin.stickBorder.withAlpha(80),
                            blurRadius: 12,
                            spreadRadius: 2,
                          ),
                        ],
                ),
                child: widget.skin.stickHighlight != null
                    ? Center(
                        child: Container(
                          width: stickSize * 0.3,
                          height: stickSize * 0.3,
                          decoration: BoxDecoration(
                            color: widget.skin.stickHighlight,
                            shape: BoxShape.circle,
                          ),
                        ),
                      )
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildDirectionIndicators(double size) {
    final indicatorSize = size * 0.08;
    final offset = size * 0.38;
    
    return [
      // Up indicator
      Positioned(
        top: size / 2 - offset - indicatorSize / 2,
        left: size / 2 - indicatorSize / 2,
        child: _DirectionIndicator(
          isActive: _up,
          size: indicatorSize,
          activeColor: widget.skin.buttonBorderPressed,
          inactiveColor: widget.skin.dpadBorder.withAlpha(100),
        ),
      ),
      // Down indicator
      Positioned(
        bottom: size / 2 - offset - indicatorSize / 2,
        left: size / 2 - indicatorSize / 2,
        child: _DirectionIndicator(
          isActive: _down,
          size: indicatorSize,
          activeColor: widget.skin.buttonBorderPressed,
          inactiveColor: widget.skin.dpadBorder.withAlpha(100),
        ),
      ),
      // Left indicator
      Positioned(
        left: size / 2 - offset - indicatorSize / 2,
        top: size / 2 - indicatorSize / 2,
        child: _DirectionIndicator(
          isActive: _left,
          size: indicatorSize,
          activeColor: widget.skin.buttonBorderPressed,
          inactiveColor: widget.skin.dpadBorder.withAlpha(100),
        ),
      ),
      // Right indicator
      Positioned(
        right: size / 2 - offset - indicatorSize / 2,
        top: size / 2 - indicatorSize / 2,
        child: _DirectionIndicator(
          isActive: _right,
          size: indicatorSize,
          activeColor: widget.skin.buttonBorderPressed,
          inactiveColor: widget.skin.dpadBorder.withAlpha(100),
        ),
      ),
    ];
  }
}

class _DirectionIndicator extends StatelessWidget {
  final bool isActive;
  final double size;
  final Color activeColor;
  final Color inactiveColor;

  const _DirectionIndicator({
    required this.isActive,
    required this.size,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isActive
            ? activeColor.withAlpha(200)
            : inactiveColor,
        shape: BoxShape.circle,
      ),
    );
  }
}
