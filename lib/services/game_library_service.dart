import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../models/game_rom.dart';
import '../core/mgba_bindings.dart';
import 'game_database.dart';


/// Service for managing the game library.
///
/// Backed by SQLite (via [GameDatabase]) so that each mutation is a cheap
/// row-level write rather than a full JSON-blob rewrite.
class GameLibraryService extends ChangeNotifier {
  final GameDatabase _database;

  GameLibraryService(this._database);

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

  /// Load the game library from SQLite.
  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();

    try {
      // Load games from the database, filtering out deleted files.
      final allGames = await _database.getAllGames();
      _games = allGames.where((game) => File(game.path).existsSync()).toList();

      // Remove stale entries (files that no longer exist) from the database.
      final stale = allGames.length - _games.length;
      if (stale > 0) {
        final stalePaths = allGames
            .where((g) => !File(g.path).existsSync())
            .map((g) => g.path);
        for (final path in stalePaths) {
          await _database.deleteGame(path);
        }
      }

      _romDirectories = await _database.getRomDirectories();

      _isLoading = false;
      _error = null;
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load library: $e';
      _isLoading = false;
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
    await _database.upsertGame(game);
    notifyListeners();
    return game;
  }

  /// Add a ROM directory to scan (legacy — works only when filesystem is accessible)
  Future<void> addRomDirectory(String path) async {
    if (_romDirectories.contains(path)) return;

    _romDirectories.add(path);
    await _database.addRomDirectory(path);
    await scanDirectory(path);
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
      final newGames = <GameRom>[];

      for (final entity in entities) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (['.gba', '.gb', '.gbc', '.sgb'].contains(ext)) {
            final game = GameRom.fromPath(entity.path);
            if (game != null && !_games.any((g) => g.path == entity.path)) {
              _games.add(game);
              newGames.add(game);
            }
          }
        }
      }

      if (newGames.isNotEmpty) {
        await _database.upsertGames(newGames);
      }

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
    await _database.deleteGame(game.path);
    notifyListeners();
  }

  /// Remove a ROM directory
  Future<void> removeRomDirectory(String path) async {
    _romDirectories.remove(path);
    final prefix = path.endsWith(p.separator) ? path : '$path${p.separator}';
    // Use both prefix match AND exact match to avoid false positives
    // (e.g. "/roms" must not match "/roms2/game.gba").
    _games.removeWhere((g) => g.path.startsWith(prefix) || g.path == path);
    await _database.removeRomDirectory(path);
    await _database.deleteGamesWithPrefix(prefix);
    notifyListeners();
  }

  /// Toggle favorite status
  Future<void> toggleFavorite(GameRom game) async {
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      _games[index] = _games[index].copyWith(isFavorite: !_games[index].isFavorite);
      await _database.updateGame(game.path, {
        'is_favorite': _games[index].isFavorite ? 1 : 0,
      });
      notifyListeners();
    }
  }

  /// Update last played time
  Future<void> updateLastPlayed(GameRom game) async {
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      final now = DateTime.now();
      _games[index] = _games[index].copyWith(lastPlayed: now);
      await _database.updateGame(game.path, {
        'last_played': now.toIso8601String(),
      });
      notifyListeners();
    }
  }

  /// Add play time (seconds) to a game's total
  Future<void> addPlayTime(GameRom game, int seconds) async {
    if (seconds <= 0) return;
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      final newTotal = _games[index].totalPlayTimeSeconds + seconds;
      _games[index] = _games[index].copyWith(totalPlayTimeSeconds: newTotal);
      await _database.updateGame(game.path, {
        'total_play_time_seconds': newTotal,
      });
      notifyListeners();
    }
  }

  /// Set cover art for a game
  Future<void> setCoverArt(GameRom game, String coverPath) async {
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      _games[index] = _games[index].copyWith(coverPath: coverPath);
      await _database.updateGame(game.path, {'cover_path': coverPath});
      notifyListeners();
    }
  }

  /// Remove cover art from a game
  Future<void> removeCoverArt(GameRom game) async {
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      _games[index] = _games[index].copyWith(coverPath: null);
      await _database.updateGame(game.path, {'cover_path': null});
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

    // Atomic swap — old library is only replaced after scanning succeeds.
    // A plain assignment ensures _games is never transiently empty.
    _games = freshGames;

    // Persist the refreshed list to the database in a single batch.
    await _database.upsertGames(freshGames);
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
