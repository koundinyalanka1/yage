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
      final baseSize = isPortrait ? gameRect.width * 0.28 : gameRect.width * 0.20;
      final buttonBase = isPortrait ? gameRect.width * 0.17 : gameRect.width * 0.12;

      final double smallestDim;
      switch (button) {
        case GamepadButton.dpad:
          smallestDim = baseSize * newSize * widget.scale;
        case GamepadButton.aButton:
        case GamepadButton.bButton:
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

// Size relative to GAME, not full screen
          final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;

          final baseSize = isPortrait
              ? gameRect.width * 0.28
              : gameRect.width * 0.20;

          final buttonBase = isPortrait
              ? gameRect.width * 0.17
              : gameRect.width * 0.12;
          final portraitBoost = isPortrait ? 1.1 : 1.0;

          // Use cached skin data (resolved in initState / didUpdateWidget)
          final skin = _resolvedSkin;

          // Pre-compute child sizes for each button so the clamp logic can
          // keep the entire widget on screen, not just its top-left corner.
          final dpadScale = layout.dpad.size * widget.scale * portraitBoost;
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

          return Stack(
            children: [
              // D-Pad or Joystick
              _buildPositionedButton(
                layout: layout.dpad,
                screenSize: screenSize,
                button: GamepadButton.dpad,
                childSize: dpadSize,
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
              _buildPositionedButton(
                layout: layout.aButton,
                screenSize: screenSize,
                button: GamepadButton.aButton,
                childSize: Size(aSize, aSize),
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
              _buildPositionedButton(
                layout: layout.bButton,
                screenSize: screenSize,
                button: GamepadButton.bButton,
                childSize: Size(bSize, bSize),
                child: _CircleButton(
                  label: 'B',
                  color: colors.accentYellow,
                  onChanged: (pressed) => _updateKey(GBAKey.b, pressed),
                  size: bSize,
                  editMode: widget.editMode,
                  skin: skin,
                ),
              ),
              
              // L Button
              _buildPositionedButton(
                layout: layout.lButton,
                screenSize: screenSize,
                button: GamepadButton.lButton,
                childSize: lSize,
                child: _ShoulderButton(
                  label: 'L',
                  onChanged: (pressed) => _updateKey(GBAKey.l, pressed),
                  scale: lScale,
                  baseSize: baseSize,
                  editMode: widget.editMode,
                  skin: skin,
                ),
              ),
              
              // R Button
              _buildPositionedButton(
                layout: layout.rButton,
                screenSize: screenSize,
                button: GamepadButton.rButton,
                childSize: rSize,
                child: _ShoulderButton(
                  label: 'R',
                  onChanged: (pressed) => _updateKey(GBAKey.r, pressed),
                  scale: rScale,
                  baseSize: baseSize,
                  editMode: widget.editMode,
                  skin: skin,
                ),
              ),
              
              // Start Button
              _buildPositionedButton(
                layout: layout.startButton,
                screenSize: screenSize,
                button: GamepadButton.startButton,
                childSize: startSize,
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
              _buildPositionedButton(
                layout: layout.selectButton,
                screenSize: screenSize,
                button: GamepadButton.selectButton,
                childSize: selectSize,
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

  Widget _buildPositionedButton({
    required ButtonLayout layout,
    required Size screenSize,
    required GamepadButton button,
    required Size childSize,
    required Widget child,
  }) {
    final isSelected = widget.editMode && _selectedButton == button;
    final Rect gameRect = widget.gameRect;
    final bool isPortrait = screenSize.height > screenSize.width;

    double x = 0.0;
    double y = 0.0;

    // Use proportional margins (2% of screen dimension) for screen independence
    final double marginPercent = 0.02;

    if (isPortrait) {
      // ================= PORTRAIT MODE =================
      // In portrait, VirtualGamepad widget IS the control area (positioned below game)
      // So screenSize here = control area size, not full screen
      // Layout coordinates: x (0-1) = left to right of widget
      //                     y (0-1) = top to bottom of widget (control area)
      
      final double widgetW = screenSize.width;
      final double widgetH = screenSize.height;
      
      // Proportional margins from edges
      final double marginX = widgetW * marginPercent;
      final double marginY = widgetH * marginPercent;
      
      final double usableWidth = widgetW - marginX * 2;
      final double usableHeight = widgetH - marginY * 2;
      
      // Direct mapping: layout 0-1 -> widget coordinates
      x = marginX + layout.x * usableWidth;
      y = marginY + layout.y * usableHeight;

    } else {
      // ================= LANDSCAPE MODE =================
      // In landscape, VirtualGamepad fills the screen
      // gameRect tells us where the game display is
      // Left zone: left edge to game left
      // Right zone: game right to right edge

      final double screenW = screenSize.width;
      final double screenH = screenSize.height;

      // Define zones with proportional padding from edges
      final double edgePadding = screenW * marginPercent;
      final double gameGap = screenW * 0.01; // 1% gap between controls and game
      
      // Left zone dimensions
      final double leftZoneLeft = edgePadding;
      final double leftZoneRight = gameRect.left - gameGap;
      final double leftZoneWidth = math.max(0, leftZoneRight - leftZoneLeft);
      
      // Right zone dimensions  
      final double rightZoneLeft = gameRect.right + gameGap;
      final double rightZoneRight = screenW - edgePadding;
      final double rightZoneWidth = math.max(0, rightZoneRight - rightZoneLeft);

      // Vertical: full screen height with small margins
      final double marginY = edgePadding;
      final double usableHeight = screenH - marginY * 2;

      final bool isLeftSide =
          button == GamepadButton.dpad ||
              button == GamepadButton.lButton ||
              button == GamepadButton.selectButton;

      if (isLeftSide) {
        // Left zone: x=0 at left edge, x=1 at right edge (near game)
        x = leftZoneLeft + layout.x * leftZoneWidth;
      } else {
        // Right zone: x=0 at left edge (near game), x=1 at right edge
        x = rightZoneLeft + layout.x * rightZoneWidth;
      }

      // Y position within usable height
      y = marginY + layout.y * usableHeight;
    }

    // ================= SAFE CLAMP =================
    // Ensure the ENTIRE button stays on screen by accounting for its size.
    // minMargin is a small safety buffer from the screen edges.
    final double minMargin = screenSize.width * 0.01;
    final double clampedX = x.clamp(
      minMargin,
      math.max(minMargin, screenSize.width - childSize.width - minMargin),
    );
    final double clampedY = y.clamp(
      minMargin,
      math.max(minMargin, screenSize.height - childSize.height - minMargin),
    );

    return Positioned(
      left: clampedX,
      top: clampedY,
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
