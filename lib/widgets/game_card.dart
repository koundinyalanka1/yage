import 'dart:io';

import 'package:flutter/material.dart';

import '../models/game_rom.dart';
import '../core/mgba_bindings.dart';
import '../utils/theme.dart';

/// Card widget displaying a game in the library
class GameCard extends StatelessWidget {
  final GameRom game;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool isSelected;

  const GameCard({
    super.key,
    required this.game,
    required this.onTap,
    this.onLongPress,
    this.isSelected = false,
  });

  Color _platformColor(AppColorTheme colors) => switch (game.platform) {
    GamePlatform.gb => colors.gbColor,
    GamePlatform.gbc => colors.gbcColor,
    GamePlatform.gba => colors.gbaColor,
    GamePlatform.nes => colors.nesColor,
    GamePlatform.snes => colors.snesColor,
    GamePlatform.unknown => colors.textMuted,
  };

  IconData get _platformIcon => switch (game.platform) {
    GamePlatform.gb => Icons.sports_esports,
    GamePlatform.gbc => Icons.gamepad,
    GamePlatform.gba => Icons.videogame_asset,
    GamePlatform.nes => Icons.tv,
    GamePlatform.snes => Icons.games,
    GamePlatform.unknown => Icons.help_outline,
  };

  Widget _buildPlaceholder(AppColorTheme colors) {
    final pColor = _platformColor(colors);
    return Stack(
      children: [
        // Decorative pattern
        Positioned.fill(
          child: CustomPaint(
            painter: _GridPatternPainter(
              color: pColor.withAlpha(26),
            ),
          ),
        ),
        // Platform icon
        Center(
          child: Icon(
            _platformIcon,
            size: 48,
            color: pColor.withAlpha(204),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final pColor = _platformColor(colors);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: isSelected
            ? Border.all(color: colors.accent, width: 2)
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  colors.surface,
                  colors.surface.withAlpha(204),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: pColor.withAlpha(26),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Cover/Icon area — fills remaining space after info
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          pColor.withAlpha(77),
                          pColor.withAlpha(26),
                        ],
                      ),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(16),
                      ),
                    ),
                    child: Stack(
                      children: [
                        // Cover image or decorative pattern
                        if (game.coverPath != null && File(game.coverPath!).existsSync())
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(16),
                              ),
                              child: Image.file(
                                File(game.coverPath!),
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) => _buildPlaceholder(colors),
                              ),
                            ),
                          )
                        else
                          _buildPlaceholder(colors),
                        
                        // Platform badge
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: pColor,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              game.platformShortName,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: colors.backgroundDark,
                              ),
                            ),
                          ),
                        ),
                        
                        // Favorite indicator
                        if (game.isFavorite)
                          Positioned(
                            top: 8,
                            left: 8,
                            child: Icon(
                              Icons.favorite,
                              size: 20,
                              color: colors.accentAlt,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                
                // Info area — uses intrinsic height so details are never clipped
                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 8, bottom: 8, right: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Title
                            Text(
                              game.name,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: colors.textPrimary,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            
                            const SizedBox(height: 4),
                            
                            // Size and play time
                            Row(
                              children: [
                                Text(
                                  game.formattedSize,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: colors.textMuted,
                                  ),
                                ),
                                if (game.totalPlayTimeSeconds > 0) ...[
                                  Text(
                                    '  •  ',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: colors.textMuted,
                                    ),
                                  ),
                                  Icon(
                                    Icons.timer_outlined,
                                    size: 11,
                                    color: colors.textMuted,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    game.formattedPlayTime,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: colors.textMuted,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      // More options hint
                      if (onLongPress != null)
                        GestureDetector(
                          onTap: onLongPress,
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                            child: Icon(
                              Icons.more_vert,
                              size: 18,
                              color: colors.textMuted.withAlpha(140),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Grid pattern painter for card background
class _GridPatternPainter extends CustomPainter {
  final Color color;

  _GridPatternPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    const spacing = 20.0;

    // Vertical lines
    for (double x = 0; x < size.width; x += spacing) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        paint,
      );
    }

    // Horizontal lines
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// List tile variant of game card
class GameListTile extends StatelessWidget {
  final GameRom game;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const GameListTile({
    super.key,
    required this.game,
    required this.onTap,
    this.onLongPress,
  });

  Color _platformColor(AppColorTheme colors) => switch (game.platform) {
    GamePlatform.gb => colors.gbColor,
    GamePlatform.gbc => colors.gbcColor,
    GamePlatform.gba => colors.gbaColor,
    GamePlatform.nes => colors.nesColor,
    GamePlatform.snes => colors.snesColor,
    GamePlatform.unknown => colors.textMuted,
  };

  Widget _buildLeading(AppColorTheme colors) {
    if (game.coverPath != null && File(game.coverPath!).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(game.coverPath!),
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _buildPlatformBadge(colors),
        ),
      );
    }
    return _buildPlatformBadge(colors);
  }

  Widget _buildPlatformBadge(AppColorTheme colors) {
    final pColor = _platformColor(colors);
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: pColor.withAlpha(51),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: pColor.withAlpha(128),
          width: 1,
        ),
      ),
      child: Center(
        child: Text(
          game.platformShortName,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: pColor,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      leading: _buildLeading(colors),
      title: Text(
        game.name,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: colors.textPrimary,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        game.totalPlayTimeSeconds > 0
            ? '${game.platformName} • ${game.formattedSize} • ${game.formattedPlayTime}'
            : '${game.platformName} • ${game.formattedSize}',
        style: TextStyle(
          fontSize: 12,
          color: colors.textMuted,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (game.isFavorite)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(
                Icons.favorite,
                size: 18,
                color: colors.accentAlt,
              ),
            ),
          if (onLongPress != null)
            GestureDetector(
              onTap: onLongPress,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.more_vert,
                  size: 20,
                  color: colors.textMuted,
                ),
              ),
            )
          else
            Icon(
              Icons.chevron_right,
              color: colors.textMuted,
            ),
        ],
      ),
    );
  }
}
