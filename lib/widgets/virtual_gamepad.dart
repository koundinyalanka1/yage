import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/mgba_bindings.dart';
import '../models/gamepad_layout.dart';
import '../utils/theme.dart';

/// Virtual gamepad for touch input
class VirtualGamepad extends StatefulWidget {
  final void Function(int keys) onKeysChanged;
  final double opacity;
  final double scale;
  final bool enableVibration;
  final GamepadLayout layout;
  final bool editMode;
  final void Function(GamepadLayout)? onLayoutChanged;

  const VirtualGamepad({
    super.key,
    required this.onKeysChanged,
    this.opacity = 0.7,
    this.scale = 1.0,
    this.enableVibration = true,
    required this.layout,
    this.editMode = false,
    this.onLayoutChanged,
  });

  @override
  State<VirtualGamepad> createState() => _VirtualGamepadState();
}

class _VirtualGamepadState extends State<VirtualGamepad> {
  int _currentKeys = 0;
  GamepadButton? _selectedButton;
  late GamepadLayout _editingLayout;

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
        HapticFeedback.lightImpact();
      }
    }
  }

  void _onButtonDrag(GamepadButton button, Offset delta, Size screenSize) {
    if (!widget.editMode) return;
    
    setState(() {
      _selectedButton = button;
      final currentLayout = _getButtonLayout(button);
      // Use the same unit for both axes (fully proportional)
      final unit = screenSize.width < screenSize.height 
          ? screenSize.width 
          : screenSize.height;
      
      // Both X and Y scale from the same unit
      final newX = (currentLayout.x + delta.dx / unit).clamp(0.0, 2.0);
      final newY = (currentLayout.y + delta.dy / unit).clamp(0.0, 2.0);
      
      _editingLayout = _updateButtonLayout(
        button,
        currentLayout.copyWith(x: newX, y: newY),
      );
    });
    
    widget.onLayoutChanged?.call(_editingLayout);
  }

  void _onButtonResize(GamepadButton button, double scaleDelta) {
    if (!widget.editMode) return;
    
    setState(() {
      _selectedButton = button;
      final currentLayout = _getButtonLayout(button);
      final newSize = (currentLayout.size + scaleDelta).clamp(0.5, 2.0);
      
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
    return Opacity(
      opacity: widget.opacity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final screenSize = Size(constraints.maxWidth, constraints.maxHeight);
          final layout = _editingLayout;
          
          // Responsive sizing based on screen
          final shortSide = screenSize.width < screenSize.height 
              ? screenSize.width 
              : screenSize.height;
          final baseSize = shortSide * 0.28; // D-pad size
          final buttonBase = shortSide * 0.15; // A/B button size
          
          return Stack(
            children: [
              // D-Pad
              _buildPositionedButton(
                layout: layout.dpad,
                screenSize: screenSize,
                button: GamepadButton.dpad,
                child: _DPad(
                  onDirectionChanged: (up, down, left, right) {
                    _updateKey(GBAKey.up, up);
                    _updateKey(GBAKey.down, down);
                    _updateKey(GBAKey.left, left);
                    _updateKey(GBAKey.right, right);
                  },
                  scale: layout.dpad.size * widget.scale,
                  baseSize: baseSize,
                  editMode: widget.editMode,
                ),
              ),
              
              // A Button
              _buildPositionedButton(
                layout: layout.aButton,
                screenSize: screenSize,
                button: GamepadButton.aButton,
                child: _CircleButton(
                  label: 'A',
                  color: YageColors.accentAlt,
                  onChanged: (pressed) => _updateKey(GBAKey.a, pressed),
                  size: buttonBase * layout.aButton.size * widget.scale,
                  editMode: widget.editMode,
                ),
              ),
              
              // B Button
              _buildPositionedButton(
                layout: layout.bButton,
                screenSize: screenSize,
                button: GamepadButton.bButton,
                child: _CircleButton(
                  label: 'B',
                  color: YageColors.accentYellow,
                  onChanged: (pressed) => _updateKey(GBAKey.b, pressed),
                  size: buttonBase * layout.bButton.size * widget.scale,
                  editMode: widget.editMode,
                ),
              ),
              
              // L Button
              _buildPositionedButton(
                layout: layout.lButton,
                screenSize: screenSize,
                button: GamepadButton.lButton,
                child: _ShoulderButton(
                  label: 'L',
                  onChanged: (pressed) => _updateKey(GBAKey.l, pressed),
                  scale: layout.lButton.size * widget.scale,
                  baseSize: baseSize,
                  editMode: widget.editMode,
                ),
              ),
              
              // R Button
              _buildPositionedButton(
                layout: layout.rButton,
                screenSize: screenSize,
                button: GamepadButton.rButton,
                child: _ShoulderButton(
                  label: 'R',
                  onChanged: (pressed) => _updateKey(GBAKey.r, pressed),
                  scale: layout.rButton.size * widget.scale,
                  baseSize: baseSize,
                  editMode: widget.editMode,
                ),
              ),
              
              // Start Button
              _buildPositionedButton(
                layout: layout.startButton,
                screenSize: screenSize,
                button: GamepadButton.startButton,
                child: _SmallButton(
                  label: 'START',
                  onChanged: (pressed) => _updateKey(GBAKey.start, pressed),
                  scale: layout.startButton.size * widget.scale,
                  baseSize: baseSize,
                  editMode: widget.editMode,
                ),
              ),
              
              // Select Button
              _buildPositionedButton(
                layout: layout.selectButton,
                screenSize: screenSize,
                button: GamepadButton.selectButton,
                child: _SmallButton(
                  label: 'SELECT',
                  onChanged: (pressed) => _updateKey(GBAKey.select, pressed),
                  scale: layout.selectButton.size * widget.scale,
                  baseSize: baseSize,
                  editMode: widget.editMode,
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
    required Widget child,
  }) {
    final isSelected = widget.editMode && _selectedButton == button;
    final offset = layout.toProportionalOffset(screenSize);
    
    return Positioned(
      left: offset.dx,
      top: offset.dy,
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
                    color: YageColors.accent,
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
                    color: YageColors.primary,
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
                    color: YageColors.error,
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

  const _DPad({
    required this.onDirectionChanged,
    this.scale = 1.0,
    this.baseSize = 190.0,
    this.editMode = false,
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
                  color: YageColors.surface.withAlpha(210),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: YageColors.surfaceLight,
                    width: 1.5,
                  ),
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
              ),
            ),
            
            // Center circle - matching app theme
            Center(
              child: Container(
                width: 36 * widget.scale,
                height: 36 * widget.scale,
                decoration: BoxDecoration(
                  color: YageColors.backgroundMedium,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: YageColors.surfaceLight,
                    width: 1.5,
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

  const _DPadButton({
    required this.isPressed,
    required this.icon,
    this.size = 60,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isPressed 
            ? YageColors.primary.withAlpha(230)
            : YageColors.surface.withAlpha(220),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isPressed ? YageColors.primary : YageColors.surfaceLight,
          width: 1,
        ),
      ),
      child: Icon(
        icon,
        color: isPressed 
            ? YageColors.textPrimary 
            : YageColors.textSecondary,
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

  const _CircleButton({
    required this.label,
    required this.color,
    required this.onChanged,
    this.size = 80,
    this.editMode = false,
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
              ? YageColors.primary.withAlpha(230)
              : YageColors.surface.withAlpha(220),
          shape: BoxShape.circle,
          border: Border.all(
            color: _isPressed ? YageColors.primary : YageColors.surfaceLight,
            width: 1.5,
          ),
        ),
        child: Center(
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: widget.size * 0.35,
              fontWeight: FontWeight.bold,
              color: _isPressed 
                  ? YageColors.textPrimary
                  : YageColors.textSecondary,
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

  const _ShoulderButton({
    required this.label,
    required this.onChanged,
    this.scale = 1.0,
    this.baseSize = 80.0,
    this.editMode = false,
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
              ? YageColors.primary.withAlpha(230)
              : YageColors.surface.withAlpha(210),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _isPressed ? YageColors.primary : YageColors.surfaceLight,
            width: 1.5,
          ),
        ),
        child: Center(
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: widget.baseSize * 0.12 * widget.scale,
              fontWeight: FontWeight.bold,
              color: _isPressed 
                  ? YageColors.textPrimary
                  : YageColors.textSecondary,
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

  const _SmallButton({
    required this.label,
    required this.onChanged,
    this.scale = 1.0,
    this.baseSize = 80.0,
    this.editMode = false,
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
              ? YageColors.primary.withAlpha(230)
              : YageColors.surface.withAlpha(210),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _isPressed ? YageColors.primary : YageColors.surfaceLight,
            width: 1.5,
          ),
        ),
        child: Text(
          widget.label,
          style: TextStyle(
            fontSize: widget.baseSize * 0.09 * widget.scale,
            fontWeight: FontWeight.bold,
            color: _isPressed 
                ? YageColors.textPrimary
                : YageColors.textSecondary,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}
