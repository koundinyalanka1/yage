import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/mgba_bindings.dart';
import '../utils/theme.dart';

/// Virtual gamepad for touch input
class VirtualGamepad extends StatefulWidget {
  final void Function(int keys) onKeysChanged;
  final double opacity;
  final double scale;
  final bool enableVibration;

  const VirtualGamepad({
    super.key,
    required this.onKeysChanged,
    this.opacity = 0.7,
    this.scale = 1.0,
    this.enableVibration = true,
  });

  @override
  State<VirtualGamepad> createState() => _VirtualGamepadState();
}

class _VirtualGamepadState extends State<VirtualGamepad> {
  int _currentKeys = 0;

  void _updateKey(int key, bool pressed) {
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

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: widget.opacity,
      child: Transform.scale(
        scale: widget.scale,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              children: [
                // D-Pad (left side)
                Positioned(
                  left: 20,
                  bottom: 40,
                  child: _DPad(
                    onDirectionChanged: (up, down, left, right) {
                      _updateKey(GBAKey.up, up);
                      _updateKey(GBAKey.down, down);
                      _updateKey(GBAKey.left, left);
                      _updateKey(GBAKey.right, right);
                    },
                  ),
                ),
                
                // A/B buttons (right side)
                Positioned(
                  right: 20,
                  bottom: 60,
                  child: _ActionButtons(
                    onAChanged: (pressed) => _updateKey(GBAKey.a, pressed),
                    onBChanged: (pressed) => _updateKey(GBAKey.b, pressed),
                  ),
                ),
                
                // L/R shoulder buttons
                Positioned(
                  left: 20,
                  top: 0,
                  child: _ShoulderButton(
                    label: 'L',
                    onChanged: (pressed) => _updateKey(GBAKey.l, pressed),
                  ),
                ),
                Positioned(
                  right: 20,
                  top: 0,
                  child: _ShoulderButton(
                    label: 'R',
                    onChanged: (pressed) => _updateKey(GBAKey.r, pressed),
                  ),
                ),
                
                // Start/Select buttons (center bottom)
                Positioned(
                  bottom: 16,
                  left: 0,
                  right: 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _SmallButton(
                        label: 'SELECT',
                        onChanged: (pressed) => _updateKey(GBAKey.select, pressed),
                      ),
                      const SizedBox(width: 40),
                      _SmallButton(
                        label: 'START',
                        onChanged: (pressed) => _updateKey(GBAKey.start, pressed),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// D-Pad widget
class _DPad extends StatefulWidget {
  final void Function(bool up, bool down, bool left, bool right) onDirectionChanged;

  const _DPad({required this.onDirectionChanged});

  @override
  State<_DPad> createState() => _DPadState();
}

class _DPadState extends State<_DPad> {
  bool _up = false;
  bool _down = false;
  bool _left = false;
  bool _right = false;

  void _handlePan(Offset localPosition, Size size) {
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
    const size = 150.0;
    const buttonSize = 50.0;
    
    return GestureDetector(
      onPanStart: (details) => _handlePan(details.localPosition, const Size(size, size)),
      onPanUpdate: (details) => _handlePan(details.localPosition, const Size(size, size)),
      onPanEnd: (_) => _reset(),
      onPanCancel: _reset,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          children: [
            // Background
            Center(
              child: Container(
                width: size - 20,
                height: size - 20,
                decoration: BoxDecoration(
                  color: YageColors.backgroundMedium,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: YageColors.surfaceLight,
                    width: 2,
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
              ),
            ),
            
            // Down
            Positioned(
              bottom: 0,
              left: (size - buttonSize) / 2,
              child: _DPadButton(
                isPressed: _down,
                icon: Icons.keyboard_arrow_down,
              ),
            ),
            
            // Left
            Positioned(
              left: 0,
              top: (size - buttonSize) / 2,
              child: _DPadButton(
                isPressed: _left,
                icon: Icons.keyboard_arrow_left,
              ),
            ),
            
            // Right
            Positioned(
              right: 0,
              top: (size - buttonSize) / 2,
              child: _DPadButton(
                isPressed: _right,
                icon: Icons.keyboard_arrow_right,
              ),
            ),
            
            // Center circle
            Center(
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: YageColors.surface,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: YageColors.surfaceLight,
                    width: 2,
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

  const _DPadButton({
    required this.isPressed,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: isPressed 
            ? YageColors.primary 
            : YageColors.surface,
        borderRadius: BorderRadius.circular(8),
        boxShadow: isPressed
            ? []
            : [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  offset: const Offset(0, 2),
                  blurRadius: 4,
                ),
              ],
      ),
      child: Icon(
        icon,
        color: isPressed ? YageColors.textPrimary : YageColors.textSecondary,
        size: 28,
      ),
    );
  }
}

/// A/B action buttons
class _ActionButtons extends StatelessWidget {
  final void Function(bool pressed) onAChanged;
  final void Function(bool pressed) onBChanged;

  const _ActionButtons({
    required this.onAChanged,
    required this.onBChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      height: 140,
      child: Stack(
        children: [
          // A button (right)
          Positioned(
            right: 0,
            top: 30,
            child: _CircleButton(
              label: 'A',
              color: YageColors.accentAlt,
              onChanged: onAChanged,
            ),
          ),
          
          // B button (left, lower)
          Positioned(
            left: 0,
            bottom: 0,
            child: _CircleButton(
              label: 'B',
              color: YageColors.accentYellow,
              onChanged: onBChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleButton extends StatefulWidget {
  final String label;
  final Color color;
  final void Function(bool pressed) onChanged;

  const _CircleButton({
    required this.label,
    required this.color,
    required this.onChanged,
  });

  @override
  State<_CircleButton> createState() => _CircleButtonState();
}

class _CircleButtonState extends State<_CircleButton> {
  bool _isPressed = false;

  void _setPressed(bool pressed) {
    if (pressed != _isPressed) {
      setState(() => _isPressed = pressed);
      widget.onChanged(pressed);
      if (pressed) HapticFeedback.lightImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        width: 70,
        height: 70,
        decoration: BoxDecoration(
          color: _isPressed 
              ? widget.color.withOpacity(0.8)
              : widget.color.withOpacity(0.6),
          shape: BoxShape.circle,
          border: Border.all(
            color: widget.color,
            width: 3,
          ),
          boxShadow: _isPressed
              ? []
              : [
                  BoxShadow(
                    color: widget.color.withOpacity(0.4),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    offset: const Offset(0, 3),
                    blurRadius: 6,
                  ),
                ],
        ),
        child: Center(
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: _isPressed 
                  ? YageColors.backgroundDark 
                  : YageColors.backgroundDark.withOpacity(0.9),
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

  const _ShoulderButton({
    required this.label,
    required this.onChanged,
  });

  @override
  State<_ShoulderButton> createState() => _ShoulderButtonState();
}

class _ShoulderButtonState extends State<_ShoulderButton> {
  bool _isPressed = false;

  void _setPressed(bool pressed) {
    if (pressed != _isPressed) {
      setState(() => _isPressed = pressed);
      widget.onChanged(pressed);
      if (pressed) HapticFeedback.lightImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        width: 80,
        height: 40,
        decoration: BoxDecoration(
          color: _isPressed 
              ? YageColors.primary
              : YageColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _isPressed ? YageColors.primaryLight : YageColors.surfaceLight,
            width: 2,
          ),
          boxShadow: _isPressed
              ? []
              : [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    offset: const Offset(0, 2),
                    blurRadius: 4,
                  ),
                ],
        ),
        child: Center(
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 18,
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

  const _SmallButton({
    required this.label,
    required this.onChanged,
  });

  @override
  State<_SmallButton> createState() => _SmallButtonState();
}

class _SmallButtonState extends State<_SmallButton> {
  bool _isPressed = false;

  void _setPressed(bool pressed) {
    if (pressed != _isPressed) {
      setState(() => _isPressed = pressed);
      widget.onChanged(pressed);
      if (pressed) HapticFeedback.lightImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: _isPressed 
              ? YageColors.surfaceLight
              : YageColors.backgroundMedium,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: YageColors.surfaceLight,
            width: 1,
          ),
        ),
        child: Text(
          widget.label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: _isPressed 
                ? YageColors.textPrimary 
                : YageColors.textMuted,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }
}

