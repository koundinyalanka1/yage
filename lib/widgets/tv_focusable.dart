import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/theme.dart';

/// Wraps any widget so it is D-pad / keyboard focusable and shows
/// a highlight ring when focused.  Enter, Space, and Gamepad-A
/// trigger [onTap].  Gamepad-B / Escape invoke [onBack] if provided.
///
/// On touchscreen-only devices this is essentially transparent.
class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onBack;
  final bool autofocus;
  final FocusNode? focusNode;
  final BorderRadius borderRadius;

  /// Whether to animate the focus glow. When `false`, a static highlight
  /// ring is shown instead of the pulsing glow — better for dialog buttons
  /// where the pulse can look like a distracting blink.
  final bool animate;

  /// When true, use a subtle focus ring (thinner border, lower glow) so the
  /// focus highlight does not dominate secondary actions like Cancel.
  final bool subtleFocus;

  /// Called when the focus state changes. Useful for tracking which widget
  /// in a list/grid was last focused so focus can be restored later.
  final ValueChanged<bool>? onFocusChanged;

  const TvFocusable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onBack,
    this.autofocus = false,
    this.focusNode,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.animate = true,
    this.subtleFocus = false,
    this.onFocusChanged,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable>
    with SingleTickerProviderStateMixin {
  late final FocusNode _focusNode;
  bool _focused = false;
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  /// Keys that trigger "select" / onTap
  static final _selectKeys = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.gameButtonA,
  };

  /// Keys that trigger "back" / onBack
  static final _backKeys = {
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.gameButtonB,
  };

  /// Keys that trigger the long-press / context-menu action on TV.
  /// Uses the keyboard context-menu key and gamepad Select (View/Back
  /// button).  Note: gameButtonX is intentionally excluded — it is
  /// mapped to GBA B in the gamepad mapper and would conflict in-game.
  /// gameButtonSelect is safe here because TvFocusable widgets are only
  /// focused outside gameplay (home screen, menus) where GBA Select is
  /// not needed.
  static final _contextKeys = {
    LogicalKeyboardKey.gameButtonSelect,
    LogicalKeyboardKey.contextMenu,
  };

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _pulseAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    if (widget.focusNode == null) _focusNode.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (_selectKeys.contains(event.logicalKey)) {
      widget.onTap?.call();
      return KeyEventResult.handled;
    }
    if (_contextKeys.contains(event.logicalKey) && widget.onLongPress != null) {
      widget.onLongPress!();
      return KeyEventResult.handled;
    }
    if (_backKeys.contains(event.logicalKey) && widget.onBack != null) {
      widget.onBack!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (widget.animate) {
          if (focused) {
            _pulseController.repeat(reverse: true);
          } else {
            _pulseController.stop();
            _pulseController.reset();
          }
        }
        widget.onFocusChanged?.call(focused);
      },
      onKeyEvent: _handleKey,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (context, child) {
            final baseAlpha = widget.subtleFocus ? 40 : 120;
            final staticAlpha = widget.subtleFocus ? 35 : 100;
            final glowAlpha = widget.animate
                ? (_pulseAnimation.value * baseAlpha).toInt()
                : (_focused ? staticAlpha : 0);
            final borderWidth = widget.subtleFocus ? 1.0 : 2.5;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              decoration: _focused
                  ? BoxDecoration(
                      borderRadius: widget.borderRadius,
                      boxShadow: widget.subtleFocus
                          ? null
                          : [
                              BoxShadow(
                                color: colors.accent.withAlpha(glowAlpha),
                                blurRadius: 12,
                                spreadRadius: 2,
                              ),
                            ],
                      border: Border.all(
                        color: colors.accent.withAlpha(widget.subtleFocus ? 80 : 255),
                        width: borderWidth,
                      ),
                    )
                  : BoxDecoration(
                      borderRadius: widget.borderRadius,
                      border: Border.all(
                        color: Colors.transparent,
                        width: borderWidth,
                      ),
                    ),
              child: child,
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}

/// Wraps a scrollable list / grid to provide D-pad hold-to-scroll
/// acceleration.  When a directional key is held down, focus traversal
/// progressively speeds up — instead of moving one item per key repeat,
/// it skips multiple items, making navigation through 50+ item lists viable.
///
/// On devices without a D-pad / gamepad this is effectively a no-op (the
/// Focus node never receives key-repeat events for directional keys).
class TvScrollAccelerator extends StatefulWidget {
  final Widget child;

  const TvScrollAccelerator({super.key, required this.child});

  @override
  State<TvScrollAccelerator> createState() => _TvScrollAcceleratorState();
}

class _TvScrollAcceleratorState extends State<TvScrollAccelerator> {
  int _repeatCount = 0;

  static final _directions = <LogicalKeyboardKey, TraversalDirection>{
    LogicalKeyboardKey.arrowUp: TraversalDirection.up,
    LogicalKeyboardKey.arrowDown: TraversalDirection.down,
    LogicalKeyboardKey.arrowLeft: TraversalDirection.left,
    LogicalKeyboardKey.arrowRight: TraversalDirection.right,
  };

  /// Progressive acceleration curve.
  /// Returns the number of **extra** focus steps to perform on top of
  /// the default one-item-per-repeat that Flutter's shortcut system
  /// already handles.
  int _extraSteps(int repeat) {
    if (repeat < 5) return 0; //  1× — normal one-at-a-time
    if (repeat < 12) return 1; // 2×
    if (repeat < 25) return 3; // 4×
    return 7; //                  8×
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final dir = _directions[event.logicalKey];
    if (dir == null) return KeyEventResult.ignored;

    if (event is KeyRepeatEvent) {
      _repeatCount++;
      final extra = _extraSteps(_repeatCount);
      if (extra > 0) {
        // Programmatically move focus by [extra] additional items.
        // focusInDirection is synchronous and updates primaryFocus
        // immediately, so sequential calls are safe.
        for (int i = 0; i < extra; i++) {
          primaryFocus?.focusInDirection(dir);
        }
      }
    } else if (event is KeyDownEvent) {
      _repeatCount = 0;
    } else if (event is KeyUpEvent) {
      _repeatCount = 0;
    }

    // Always return ignored so the framework's own directional-focus
    // shortcut still fires and moves focus by its normal +1 step.
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _onKey,
      canRequestFocus: false, // invisible to focus traversal
      skipTraversal: true,
      child: widget.child,
    );
  }
}

/// Animated builder helper – similar to AnimatedBuilder but takes Animation.
class AnimatedBuilder extends StatelessWidget {
  final Animation<double> animation;
  final Widget Function(BuildContext context, Widget? child) builder;
  final Widget? child;

  const AnimatedBuilder({
    super.key,
    required this.animation,
    required this.builder,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder._internal(
      animation: animation,
      builder: builder,
      child: child,
    );
  }

  /// Use the built-in Flutter AnimatedBuilder:
  static Widget _internal({
    required Animation<double> animation,
    required Widget Function(BuildContext, Widget?) builder,
    Widget? child,
  }) {
    return _AnimatedBuilderWidget(
      animation: animation,
      builder: builder,
      child: child,
    );
  }
}

class _AnimatedBuilderWidget extends AnimatedWidget {
  final Widget Function(BuildContext, Widget?) builder;
  final Widget? child;

  const _AnimatedBuilderWidget({
    required Animation<double> animation,
    required this.builder,
    this.child,
  }) : super(listenable: animation);

  @override
  Widget build(BuildContext context) {
    return builder(context, child);
  }
}
