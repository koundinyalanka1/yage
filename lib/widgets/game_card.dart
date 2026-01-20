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

  Color get _platformColor => switch (game.platform) {
    GamePlatform.gb => YageColors.gbColor,
    GamePlatform.gbc => YageColors.gbcColor,
    GamePlatform.gba => YageColors.gbaColor,
    GamePlatform.unknown => YageColors.textMuted,
  };

  IconData get _platformIcon => switch (game.platform) {
    GamePlatform.gb => Icons.sports_esports,
    GamePlatform.gbc => Icons.gamepad,
    GamePlatform.gba => Icons.videogame_asset,
    GamePlatform.unknown => Icons.help_outline,
  };

  Widget _buildPlaceholder() {
    return Stack(
      children: [
        // Decorative pattern
        Positioned.fill(
          child: CustomPaint(
            painter: _GridPatternPainter(
              color: _platformColor.withAlpha(26),
            ),
          ),
        ),
        // Platform icon
        Center(
          child: Icon(
            _platformIcon,
            size: 48,
            color: _platformColor.withAlpha(204),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: isSelected
            ? Border.all(color: YageColors.accent, width: 2)
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
                  YageColors.surface,
                  YageColors.surface.withAlpha(204),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: _platformColor.withAlpha(26),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Cover/Icon area
                Expanded(
                  flex: 3,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          _platformColor.withAlpha(77),
                          _platformColor.withAlpha(26),
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
                                errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
                              ),
                            ),
                          )
                        else
                          _buildPlaceholder(),
                        
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
                              color: _platformColor,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              game.platformShortName,
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: YageColors.backgroundDark,
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
                              color: YageColors.accentAlt,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                
                // Info area
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Title
                        Expanded(
                          child: Text(
                            game.name,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: YageColors.textPrimary,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        
                        const SizedBox(height: 4),
                        
                        // Size
                        Text(
                          game.formattedSize,
                          style: const TextStyle(
                            fontSize: 10,
                            color: YageColors.textMuted,
                          ),
                        ),
                      ],
                    ),
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

  Color get _platformColor => switch (game.platform) {
    GamePlatform.gb => YageColors.gbColor,
    GamePlatform.gbc => YageColors.gbcColor,
    GamePlatform.gba => YageColors.gbaColor,
    GamePlatform.unknown => YageColors.textMuted,
  };

  Widget _buildLeading() {
    if (game.coverPath != null && File(game.coverPath!).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(game.coverPath!),
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _buildPlatformBadge(),
        ),
      );
    }
    return _buildPlatformBadge();
  }

  Widget _buildPlatformBadge() {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: _platformColor.withAlpha(51),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _platformColor.withAlpha(128),
          width: 1,
        ),
      ),
      child: Center(
        child: Text(
          game.platformShortName,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: _platformColor,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      leading: _buildLeading(),
      title: Text(
        game.name,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: YageColors.textPrimary,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${game.platformName} • ${game.formattedSize}',
        style: const TextStyle(
          fontSize: 12,
          color: YageColors.textMuted,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (game.isFavorite)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(
                Icons.favorite,
                size: 18,
                color: YageColors.accentAlt,
              ),
            ),
          const Icon(
            Icons.chevron_right,
            color: YageColors.textMuted,
          ),
        ],
      ),
    );
  }
}

