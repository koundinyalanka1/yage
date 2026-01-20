import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../core/mgba_bindings.dart';
import '../models/game_rom.dart';

/// Service for fetching and caching game artwork
class ArtworkService {
  static const String _libretroBaseUrl = 
      'https://raw.githubusercontent.com/libretro-thumbnails';
  
  /// LibRetro system names for each platform
  static String _getSystemName(GamePlatform platform) {
    return switch (platform) {
      GamePlatform.gb => 'Nintendo_-_Game_Boy',
      GamePlatform.gbc => 'Nintendo_-_Game_Boy_Color',
      GamePlatform.gba => 'Nintendo_-_Game_Boy_Advance',
      GamePlatform.unknown => '',
    };
  }

  /// Get local artwork cache directory
  static Future<Directory> _getArtworkDir() async {
    final appDir = await getApplicationSupportDirectory();
    final artworkDir = Directory(p.join(appDir.path, 'artwork'));
    if (!artworkDir.existsSync()) {
      await artworkDir.create(recursive: true);
    }
    return artworkDir;
  }

  /// Clean game name for matching (remove region codes, revision numbers, etc.)
  static String _cleanGameName(String name) {
    String cleaned = name
        .replaceAll(RegExp(r'\.(gba|gb|gbc|sgb)$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*\([^)]*\)\s*'), ' ')
        .replaceAll(RegExp(r'\s*\[[^\]]*\]\s*'), ' ')
        .replaceAll(RegExp(r'\s*v\d+\.?\d*\s*', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    
    return cleaned;
  }

  /// Sanitize filename for caching
  static String _sanitizeFilename(String name) {
    return name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
  }

  /// Generate possible artwork URLs to try
  static List<String> _generateUrls(String gameName, GamePlatform platform) {
    final systemName = _getSystemName(platform);
    if (systemName.isEmpty) return [];

    final cleanName = _cleanGameName(gameName);
    final urls = <String>[];
    
    final variations = <String>[
      cleanName,
      cleanName.replaceAll(' - ', ' - '),
      cleanName.replaceAll("'", "'"),
      cleanName.replaceAll(':', ' -'),
      // Title case version
      cleanName.split(' ').map((word) => 
        word.isNotEmpty ? '${word[0].toUpperCase()}${word.substring(1)}' : word
      ).join(' '),
      // All lowercase
      cleanName.toLowerCase(),
      // Without "The " prefix
      cleanName.startsWith('The ') ? cleanName.substring(4) : cleanName,
      // Original ROM name
      gameName,
    ];

    for (final name in variations.toSet()) {
      if (name.isEmpty) continue;
      
      final encoded = Uri.encodeComponent(name);
      
      // Try Named_Boxarts first (best quality)
      urls.add('$_libretroBaseUrl/$systemName/master/Named_Boxarts/$encoded.png');
      // Then Named_Titles
      urls.add('$_libretroBaseUrl/$systemName/master/Named_Titles/$encoded.png');
      // Then Named_Snaps
      urls.add('$_libretroBaseUrl/$systemName/master/Named_Snaps/$encoded.png');
    }

    return urls;
  }

  /// Fetch artwork for a game
  /// Returns the local path if successful, null otherwise
  static Future<String?> fetchArtwork(GameRom game, {
    void Function(String status)? onStatus,
  }) async {
    if (game.platform == GamePlatform.unknown) return null;

    try {
      final artworkDir = await _getArtworkDir();
      
      // Check if we already have cached artwork
      final cachedPath = p.join(artworkDir.path, '${_sanitizeFilename(game.name)}.png');
      if (File(cachedPath).existsSync()) {
        return cachedPath;
      }

      onStatus?.call('Searching for artwork...');
      
      final urls = _generateUrls(game.name, game.platform);
      
      for (final url in urls) {
        try {
          onStatus?.call('Trying source...');
          
          final response = await http.get(
            Uri.parse(url),
            headers: {'User-Agent': 'YAGE-Emulator/1.0'},
          ).timeout(const Duration(seconds: 10));

          if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
            // Verify it's actually an image
            if (response.headers['content-type']?.contains('image') == true ||
                response.bodyBytes.length > 1000) {
              
              // Save to cache
              final file = File(cachedPath);
              await file.writeAsBytes(response.bodyBytes);
              
              onStatus?.call('Artwork found!');
              return cachedPath;
            }
          }
        } catch (e) {
          // Try next URL
          debugPrint('Failed to fetch $url: $e');
        }
      }

      onStatus?.call('No artwork found');
      return null;
    } catch (e) {
      debugPrint('Error fetching artwork: $e');
      onStatus?.call('Error: $e');
      return null;
    }
  }

  /// Clear artwork cache
  static Future<void> clearCache() async {
    try {
      final artworkDir = await _getArtworkDir();
      if (artworkDir.existsSync()) {
        await artworkDir.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('Error clearing artwork cache: $e');
    }
  }
}
