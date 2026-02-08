import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

import '../models/game_rom.dart';
import '../core/mgba_bindings.dart';
import 'artwork_service.dart';

/// Service for managing the game library
class GameLibraryService extends ChangeNotifier {
  static const String _gamesKey = 'game_library';
  static const String _romDirsKey = 'rom_directories';
  /// Shared-storage backup path so the library survives uninstall/reinstall.
  static const _backupPaths = [
    '/storage/emulated/0/RetroPal/library_backup.json',
    '/sdcard/RetroPal/library_backup.json',
  ];
  
  List<GameRom> _games = [];
  List<String> _romDirectories = [];
  bool _isLoading = false;
  String? _error;

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

  /// Initialize and load saved library.
  /// First tries SharedPreferences; if empty (e.g. after reinstall),
  /// falls back to the shared-storage backup.
  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Load ROM directories
      final dirsJson = prefs.getStringList(_romDirsKey);
      if (dirsJson != null) {
        _romDirectories = dirsJson;
      }

      // Load saved games from SharedPreferences
      String? gamesJson = prefs.getString(_gamesKey);

      // If nothing in prefs (fresh install / reinstall), try shared-storage backup
      if (gamesJson == null || gamesJson.isEmpty) {
        gamesJson = _readBackup();
        if (gamesJson != null) {
          debugPrint('Restored game library from shared-storage backup');
          // Also recover rom directories from backup
          try {
            final backup = jsonDecode(gamesJson) as Map<String, dynamic>;
            if (backup.containsKey('romDirectories')) {
              _romDirectories = List<String>.from(backup['romDirectories']);
            }
            if (backup.containsKey('games')) {
              gamesJson = jsonEncode(backup['games']);
            }
          } catch (_) {
            // Backup might be just the games list (old format)
          }
        }
      }

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

      // Write backup in background so it's ready for next reinstall
      _writeBackup();
    } catch (e) {
      _error = 'Failed to load library: $e';
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Save library to storage (SharedPreferences + shared-storage backup).
  Future<void> _saveLibrary() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final gamesJson = jsonEncode(_games.map((g) => g.toJson()).toList());
      await prefs.setString(_gamesKey, gamesJson);
      await prefs.setStringList(_romDirsKey, _romDirectories);

      // Also write to shared storage so data survives uninstall/reinstall
      _writeBackup();
    } catch (e) {
      _error = 'Failed to save library: $e';
      notifyListeners();
    }
  }

  // ──────────── Shared-storage backup helpers ────────────

  /// Write a JSON backup to shared storage (best-effort, non-blocking).
  void _writeBackup() {
    try {
      final backup = jsonEncode({
        'games': _games.map((g) => g.toJson()).toList(),
        'romDirectories': _romDirectories,
        'timestamp': DateTime.now().toIso8601String(),
      });
      for (final path in _backupPaths) {
        try {
          final file = File(path);
          final dir = file.parent;
          if (!dir.existsSync()) dir.createSync(recursive: true);
          file.writeAsStringSync(backup);
          return; // success — no need to try more paths
        } catch (_) {
          continue;
        }
      }
    } catch (e) {
      debugPrint('Could not write library backup: $e');
    }
  }

  /// Try reading a backup from shared storage. Returns the JSON or null.
  String? _readBackup() {
    for (final path in _backupPaths) {
      try {
        final file = File(path);
        if (file.existsSync()) {
          return file.readAsStringSync();
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

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

  /// Add a ROM directory to scan
  Future<void> addRomDirectory(String path) async {
    if (_romDirectories.contains(path)) return;

    _romDirectories.add(path);
    await scanDirectory(path);
    await _saveLibrary();
  }

  /// Scan a directory for ROM files
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
    _games.removeWhere((g) => g.path.startsWith(path));
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

  /// Refresh library by rescanning all directories
  Future<void> refresh() async {
    _isLoading = true;
    notifyListeners();

    // Keep favorites, play history, and play time
    final gameData = Map.fromEntries(
      _games.map((g) => MapEntry(g.path, (g.isFavorite, g.lastPlayed, g.totalPlayTimeSeconds))),
    );

    _games.clear();

    for (final dir in _romDirectories) {
      await scanDirectory(dir);
    }

    // Restore metadata
    for (int i = 0; i < _games.length; i++) {
      final data = gameData[_games[i].path];
      if (data != null) {
        _games[i] = _games[i].copyWith(
          isFavorite: data.$1,
          lastPlayed: data.$2,
          totalPlayTimeSeconds: data.$3,
        );
      }
    }

    await _saveLibrary();
    _isLoading = false;
    notifyListeners();
  }

  /// Search games by name
  List<GameRom> search(String query) {
    if (query.isEmpty) return _games;
    final lowerQuery = query.toLowerCase();
    return _games.where((g) => g.name.toLowerCase().contains(lowerQuery)).toList();
  }

  /// Fetch artwork for a single game
  Future<bool> fetchArtwork(GameRom game) async {
    final coverPath = await ArtworkService.fetchArtwork(game);
    if (coverPath != null) {
      await setCoverArt(game, coverPath);
      return true;
    }
    return false;
  }

  /// Fetch artwork for all games without covers
  Future<int> fetchAllArtwork({
    void Function(int completed, int total)? onProgress,
  }) async {
    final gamesNeedingArt = _games.where((g) => 
      g.coverPath == null || !File(g.coverPath!).existsSync()
    ).toList();

    if (gamesNeedingArt.isEmpty) return 0;

    int found = 0;
    for (int i = 0; i < gamesNeedingArt.length; i++) {
      final game = gamesNeedingArt[i];
      final success = await fetchArtwork(game);
      if (success) found++;
      onProgress?.call(i + 1, gamesNeedingArt.length);
      
      // Small delay to avoid rate limiting
      await Future.delayed(const Duration(milliseconds: 300));
    }

    return found;
  }
}

