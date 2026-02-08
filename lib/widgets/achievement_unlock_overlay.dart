import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../models/ra_achievement.dart';
import '../services/ra_runtime_service.dart';
import '../utils/theme.dart';

/// Animated overlay that shows achievement unlock notifications.
///
/// Listens to [RARuntimeService] for unlock events and displays them
/// as animated toast banners that slide in from the top.
///
/// Usage: place this in a [Stack] above the game display.
class AchievementUnlockOverlay extends StatefulWidget {
  final RARuntimeService runtimeService;

  /// How long the toast stays visible (excluding animation time).
  final Duration displayDuration;

  const AchievementUnlockOverlay({
    super.key,
    required this.runtimeService,
    this.displayDuration = const Duration(seconds: 4),
  });

  @override
  State<AchievementUnlockOverlay> createState() =>
      _AchievementUnlockOverlayState();
}

class _AchievementUnlockOverlayState extends State<AchievementUnlockOverlay>
    with SingleTickerProviderStateMixin {
  RAUnlockEvent? _currentEvent;
  bool _visible = false;

  late final AnimationController _animController;
  late final Animation<Offset> _slideAnim;
  late final Animation<double> _fadeAnim;

  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    _slideAnim = Tween<Offset>(
      begin: const Offset(0, -1.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInCubic,
    ));

    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
        reverseCurve: const Interval(0.5, 1.0, curve: Curves.easeOut),
      ),
    );

    widget.runtimeService.addListener(_onRuntimeChanged);
  }

  @override
  void dispose() {
    widget.runtimeService.removeListener(_onRuntimeChanged);
    _dismissTimer?.cancel();
    _animController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AchievementUnlockOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtimeService != widget.runtimeService) {
      oldWidget.runtimeService.removeListener(_onRuntimeChanged);
      widget.runtimeService.addListener(_onRuntimeChanged);
    }
  }

  void _onRuntimeChanged() {
    if (!mounted) return;
    if (_visible) return; // Already showing a notification — next one later.

    final event = widget.runtimeService.nextNotification;
    if (event == null) return;

    _showNotification(event);
  }

  Future<void> _showNotification(RAUnlockEvent event) async {
    // Consume this notification
    widget.runtimeService.consumeNotification();

    setState(() {
      _currentEvent = event;
      _visible = true;
    });

    // Slide in
    await _animController.forward();

    // Stay visible
    final completer = Completer<void>();
    _dismissTimer = Timer(widget.displayDuration, () {
      completer.complete();
    });
    await completer.future;

    // Slide out
    if (mounted) {
      await _animController.reverse();
    }

    if (mounted) {
      setState(() {
        _visible = false;
        _currentEvent = null;
      });
    }

    // Check for more notifications
    if (mounted) {
      _onRuntimeChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible || _currentEvent == null) {
      return const SizedBox.shrink();
    }

    final achievement = _currentEvent!.achievement;
    final isHardcore = _currentEvent!.isHardcore;
    final safeTop = MediaQuery.of(context).padding.top;

    return Positioned(
      top: safeTop + 8,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: _slideAnim,
        child: FadeTransition(
          opacity: _fadeAnim,
          child: _AchievementToast(
            achievement: achievement,
            isHardcore: isHardcore,
          ),
        ),
      ),
    );
  }
}

/// The visual toast/banner for a single achievement unlock.
class _AchievementToast extends StatelessWidget {
  final RAAchievement achievement;
  final bool isHardcore;

  const _AchievementToast({
    required this.achievement,
    required this.isHardcore,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: YageColors.surface.withAlpha(240),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _borderColor,
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: _glowColor.withAlpha(80),
            blurRadius: 20,
            spreadRadius: 2,
          ),
          BoxShadow(
            color: Colors.black.withAlpha(120),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          // Badge image
          _BadgeImage(
            url: achievement.badgeUrl,
            size: 48,
          ),
          const SizedBox(width: 12),

          // Text content
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // "Achievement Unlocked!" header
                Row(
                  children: [
                    Icon(
                      Icons.emoji_events,
                      color: _accentColor,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Achievement Unlocked!',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: _accentColor,
                          letterSpacing: 0.5,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isHardcore) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withAlpha(40),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: Colors.redAccent.withAlpha(100),
                            width: 0.5,
                          ),
                        ),
                        child: const Text(
                          'HC',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: Colors.redAccent,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),

                // Achievement title
                Text(
                  achievement.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: YageColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),

                // Points
                Row(
                  children: [
                    Text(
                      achievement.description,
                      style: TextStyle(
                        fontSize: 11,
                        color: YageColors.textMuted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const Spacer(),
                    Text(
                      '${achievement.points} pts',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: _accentColor,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color get _accentColor =>
      isHardcore ? Colors.amber : YageColors.accent;

  Color get _borderColor =>
      isHardcore ? Colors.amber.withAlpha(120) : YageColors.primary.withAlpha(120);

  Color get _glowColor =>
      isHardcore ? Colors.amber : YageColors.primary;
}

/// Lazy-loaded badge image with placeholder and error fallback.
class _BadgeImage extends StatelessWidget {
  final String url;
  final double size;

  const _BadgeImage({required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: size,
        height: size,
        child: CachedNetworkImage(
          imageUrl: url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (_, __) => Container(
            color: YageColors.backgroundLight,
            child: Center(
              child: SizedBox(
                width: size * 0.4,
                height: size * 0.4,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: YageColors.accent.withAlpha(100),
                ),
              ),
            ),
          ),
          errorWidget: (_, __, ___) => Container(
            color: YageColors.backgroundLight,
            child: Icon(
              Icons.emoji_events_outlined,
              size: size * 0.5,
              color: YageColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}
