import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../models/game_rom.dart';
import '../core/mgba_bindings.dart';


/// Service for managing the game library
class GameLibraryService extends ChangeNotifier {
  static const String _gamesKey = 'game_library';
  static const String _romDirsKey = 'rom_directories';

  List<GameRom> _games = [];
  List<String> _romDirectories = [];
  bool _isLoading = false;
  String? _error;

  /// Cached path to the internal ROM storage directory.
  String? _internalRomsDir;

  List<GameRom> get games => _games;
  List<String> get romDirectories => _romDirectories;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Get games filtered by platform
  List<GameRom> getGamesByPlatform(GamePlatform? platform) {
    if (platform == null) return _games;
    return _games.where((g) => g.platform == platform).toList();
  }

  /// Get favorite games
  List<GameRom> get favorites => _games.where((g) => g.isFavorite).toList();

  /// Get recently played games
  List<GameRom> get recentlyPlayed {
    final played = _games.where((g) => g.lastPlayed != null).toList();
    played.sort((a, b) => b.lastPlayed!.compareTo(a.lastPlayed!));
    return played.take(10).toList();
  }

  // ──────────── Internal ROM storage ────────────

  /// Returns the path to the app-internal ROMs directory, creating it if needed.
  Future<String> getInternalRomsDir() async {
    if (_internalRomsDir != null) return _internalRomsDir!;
    final appDir = await getApplicationSupportDirectory();
    final romsDir = Directory(p.join(appDir.path, 'roms'));
    if (!romsDir.existsSync()) romsDir.createSync(recursive: true);
    _internalRomsDir = romsDir.path;
    return _internalRomsDir!;
  }

  // ──────────── Initialize ────────────

  /// Initialize and load saved library from SharedPreferences.
  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();

      // Load ROM directories (legacy — kept for backwards compat)
      final dirsJson = prefs.getStringList(_romDirsKey);
      if (dirsJson != null) {
        _romDirectories = dirsJson;
      }

      // Load saved games from SharedPreferences
      final gamesJson = prefs.getString(_gamesKey);

      if (gamesJson != null && gamesJson.isNotEmpty) {
        final List<dynamic> gamesList = jsonDecode(gamesJson);
        _games = gamesList
            .map((json) => GameRom.fromJson(json as Map<String, dynamic>))
            .where((game) => File(game.path).existsSync())
            .toList();
      }

      _isLoading = false;
      _error = null;
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load library: $e';
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Save library to SharedPreferences.
  Future<void> _saveLibrary() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final gamesJson = jsonEncode(_games.map((g) => g.toJson()).toList());
      await prefs.setString(_gamesKey, gamesJson);
      await prefs.setStringList(_romDirsKey, _romDirectories);
    } catch (e) {
      _error = 'Failed to save library: $e';
      notifyListeners();
    }
  }

  // ──────────── ROM import (SAF-friendly) ────────────

  /// Import a ROM by copying it to internal storage first, then adding to library.
  ///
  /// Use this when the source file might be in a cache or SAF-provided location
  /// that could be cleaned up. The ROM is copied to the app's permanent internal
  /// roms directory.
  Future<GameRom?> importRom(String sourcePath) async {
    final romsDir = await getInternalRomsDir();
    final fileName = p.basename(sourcePath);
    final destPath = p.join(romsDir, fileName);

    // If already in internal storage, just add directly
    if (sourcePath.startsWith(romsDir)) {
      return addRom(sourcePath);
    }

    // Copy to internal storage
    try {
      await File(sourcePath).copy(destPath);
    } catch (e) {
      debugPrint('Error copying ROM to internal storage: $e');
      return null;
    }

    return addRom(destPath);
  }

  // ──────────── ROM management ────────────

  /// Add a single ROM file - returns the added game or null
  Future<GameRom?> addRom(String path) async {
    final game = GameRom.fromPath(path);
    if (game == null) return null;

    // Check if already exists
    if (_games.any((g) => g.path == path)) return null;

    _games.add(game);
    await _saveLibrary();
    notifyListeners();
    return game;
  }

  /// Add a ROM directory to scan (legacy — works only when filesystem is accessible)
  Future<void> addRomDirectory(String path) async {
    if (_romDirectories.contains(path)) return;

    _romDirectories.add(path);
    await scanDirectory(path);
    await _saveLibrary();
  }

  /// Scan a directory for ROM files (requires filesystem read access)
  Future<void> scanDirectory(String path) async {
    _isLoading = true;
    notifyListeners();

    try {
      final dir = Directory(path);
      if (!dir.existsSync()) {
        _error = 'Directory does not exist: $path';
        _isLoading = false;
        notifyListeners();
        return;
      }

      final entities = dir.listSync(recursive: true);

      for (final entity in entities) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (['.gba', '.gb', '.gbc', '.sgb'].contains(ext)) {
            final game = GameRom.fromPath(entity.path);
            if (game != null && !_games.any((g) => g.path == entity.path)) {
              _games.add(game);
            }
          }
        }
      }

      await _saveLibrary();
      _isLoading = false;
      _error = null;
      notifyListeners();
    } catch (e) {
      _error = 'Failed to scan directory: $e';
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Remove a ROM from library
  Future<void> removeRom(GameRom game) async {
    _games.removeWhere((g) => g.path == game.path);
    await _saveLibrary();
    notifyListeners();
  }

  /// Remove a ROM directory
  Future<void> removeRomDirectory(String path) async {
    _romDirectories.remove(path);
    final prefix = path.endsWith(p.separator) ? path : '$path${p.separator}';
    _games.removeWhere((g) => g.path.startsWith(prefix));
    await _saveLibrary();
    notifyListeners();
  }

  /// Toggle favorite status
  Future<void> toggleFavorite(GameRom game) async {
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      _games[index] = _games[index].copyWith(isFavorite: !_games[index].isFavorite);
      await _saveLibrary();
      notifyListeners();
    }
  }

  /// Update last played time
  Future<void> updateLastPlayed(GameRom game) async {
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      _games[index] = _games[index].copyWith(lastPlayed: DateTime.now());
      await _saveLibrary();
      notifyListeners();
    }
  }

  /// Add play time (seconds) to a game's total
  Future<void> addPlayTime(GameRom game, int seconds) async {
    if (seconds <= 0) return;
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      _games[index] = _games[index].copyWith(
        totalPlayTimeSeconds: _games[index].totalPlayTimeSeconds + seconds,
      );
      await _saveLibrary();
      notifyListeners();
    }
  }

  /// Set cover art for a game
  Future<void> setCoverArt(GameRom game, String coverPath) async {
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      _games[index] = _games[index].copyWith(coverPath: coverPath);
      await _saveLibrary();
      notifyListeners();
    }
  }

  /// Remove cover art from a game
  Future<void> removeCoverArt(GameRom game) async {
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      _games[index] = _games[index].copyWith(coverPath: null);
      await _saveLibrary();
      notifyListeners();
    }
  }

  /// Refresh library by rescanning all directories.
  ///
  /// Builds a fresh game list without clearing the existing one first,
  /// then swaps atomically — so a disk error or permission failure
  /// during scanning never causes data loss.
  Future<void> refresh() async {
    _isLoading = true;
    notifyListeners();

    // Preserve metadata (favorites, play history, cover art, etc.)
    final gameData = Map.fromEntries(
      _games.map((g) => MapEntry(g.path, g)),
    );

    // Build a new list independently — _games stays intact until the
    // scan completes successfully.
    final freshGames = <GameRom>[];

    for (final dir in _romDirectories) {
      try {
        final dirObj = Directory(dir);
        if (!dirObj.existsSync()) continue;

        final entities = dirObj.listSync(recursive: true);
        for (final entity in entities) {
          if (entity is File) {
            final ext = p.extension(entity.path).toLowerCase();
            if (['.gba', '.gb', '.gbc', '.sgb'].contains(ext)) {
              final game = GameRom.fromPath(entity.path);
              if (game != null &&
                  !freshGames.any((g) => g.path == entity.path)) {
                freshGames.add(game);
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Refresh: failed to scan "$dir" — $e');
        // Continue scanning other directories
      }
    }

    // Restore metadata from the previous library onto the freshly
    // scanned entries.
    for (int i = 0; i < freshGames.length; i++) {
      final prev = gameData[freshGames[i].path];
      if (prev != null) {
        freshGames[i] = freshGames[i].copyWith(
          isFavorite: prev.isFavorite,
          lastPlayed: prev.lastPlayed,
          totalPlayTimeSeconds: prev.totalPlayTimeSeconds,
          coverPath: prev.coverPath,
        );
      }
    }

    // Atomic swap — old library is only replaced after scanning succeeds
    _games
      ..clear()
      ..addAll(freshGames);

    await _saveLibrary();
    _isLoading = false;
    _error = null;
    notifyListeners();
  }

  /// Search games by name
  List<GameRom> search(String query) {
    if (query.isEmpty) return _games;
    final lowerQuery = query.toLowerCase();
    return _games.where((g) => g.name.toLowerCase().contains(lowerQuery)).toList();
  }

}
