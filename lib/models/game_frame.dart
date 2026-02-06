import 'package:flutter/material.dart';

/// Available decorative console shell overlays
enum GameFrameType {
  none,
  dmg,
  pocket,
  color,
  advance,
}

extension GameFrameTypeName on GameFrameType {
  String get label => switch (this) {
    GameFrameType.none => 'None',
    GameFrameType.dmg => 'DMG',
    GameFrameType.pocket => 'Pocket',
    GameFrameType.color => 'Color',
    GameFrameType.advance => 'Advance',
  };

  String get description => switch (this) {
    GameFrameType.none => 'No frame',
    GameFrameType.dmg => 'Original Game Boy',
    GameFrameType.pocket => 'Game Boy Pocket',
    GameFrameType.color => 'Game Boy Color',
    GameFrameType.advance => 'Game Boy Advance',
  };

  IconData get icon => switch (this) {
    GameFrameType.none => Icons.crop_free,
    GameFrameType.dmg => Icons.phone_android,
    GameFrameType.pocket => Icons.smartphone,
    GameFrameType.color => Icons.color_lens,
    GameFrameType.advance => Icons.tablet,
  };

  /// Primary body color used for the preview swatch
  Color get previewColor => switch (this) {
    GameFrameType.none => Colors.transparent,
    GameFrameType.dmg => const Color(0xFFC8C4BE),
    GameFrameType.pocket => const Color(0xFFD1CFC7),
    GameFrameType.color => const Color(0xFF6A5ACD),
    GameFrameType.advance => const Color(0xFF504094),
  };
}
