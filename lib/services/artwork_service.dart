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
    // Remove common suffixes and clean up
    String cleaned = name
        // Remove file extension if present
        .replaceAll(RegExp(r'\.(gba|gb|gbc|sgb)$', caseSensitive: false), '')
        // Remove region codes like (USA), (Europe), (Japan), etc.
        .replaceAll(RegExp(r'\s*\([^)]*\)\s*'), ' ')
        // Remove bracket codes like [!], [T+Eng], etc.
        .replaceAll(RegExp(r'\s*\[[^\]]*\]\s*'), ' ')
        // Remove revision markers like (Rev 1), v1.1, etc.
        .replaceAll(RegExp(r'\s*v\d+\.?\d*\s*', caseSensitive: false), ' ')
        // Clean up multiple spaces
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    
    return cleaned;
  }

  /// URL encode for LibRetro (special handling for certain characters)
  static String _urlEncode(String name) {
    return Uri.encodeComponent(name)
        .replaceAll('%20', '%20')  // Keep spaces encoded
        .replaceAll('%26', '&')    // Ampersand
        .replaceAll('%27', "'")    // Apostrophe
        .replaceAll('%2C', ',');   // Comma
  }

  /// Generate possible artwork URLs to try
  static List<String> _generateUrls(String gameName, GamePlatform platform) {
    final systemName = _getSystemName(platform);
    if (systemName.isEmpty) return [];

    final cleanName = _cleanGameName(gameName);
    final urls = <String>[];
    
    // Try different name variations
    final variations = [
      cleanName,
      cleanName.replaceAll(' - ', ' '),
      cleanName.replaceAll("'", ''),
      cleanName.replaceAll('&', 'and'),
      // Title case
      cleanName.split(' ').map((w) => 
        w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}' : w
      ).join(' '),
    ];

    for (final name in variations.toSet()) {
      final encoded = _urlEncode(name);
      
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

  /// Fetch artwork for multiple games
  static Future<Map<String, String?>> fetchArtworkBatch(
    List<GameRom> games, {
    void Function(int completed, int total)? onProgress,
  }) async {
    final results = <String, String?>{};
    
    for (int i = 0; i < games.length; i++) {
      final game = games[i];
      
      // Skip if already has cover
      if (game.coverPath != null && File(game.coverPath!).existsSync()) {
        results[game.path] = game.coverPath;
        onProgress?.call(i + 1, games.length);
        continue;
      }

      results[game.path] = await fetchArtwork(game);
      onProgress?.call(i + 1, games.length);
      
      // Small delay to avoid rate limiting
      await Future.delayed(const Duration(milliseconds: 200));
    }

    return results;
  }

  /// Sanitize filename for caching
  static String _sanitizeFilename(String name) {
    return name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
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

