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

  const TvFocusable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onBack,
    this.autofocus = false,
    this.focusNode,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
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

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
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
    if (_backKeys.contains(event.logicalKey) && widget.onBack != null) {
      widget.onBack!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) => setState(() => _focused = focused),
      onKeyEvent: _handleKey,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (context, child) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              decoration: _focused
                  ? BoxDecoration(
                      borderRadius: widget.borderRadius,
                      boxShadow: [
                        BoxShadow(
                          color: YageColors.accent
                              .withAlpha((_pulseAnimation.value * 120).toInt()),
                          blurRadius: 12,
                          spreadRadius: 2,
                        ),
                      ],
                      border: Border.all(
                        color: YageColors.accent,
                        width: 2.5,
                      ),
                    )
                  : BoxDecoration(
                      borderRadius: widget.borderRadius,
                      border: Border.all(
                        color: Colors.transparent,
                        width: 2.5,
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
