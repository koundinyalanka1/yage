import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  /// Initialize and load saved library
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

      // Load saved games
      final gamesJson = prefs.getString(_gamesKey);
      if (gamesJson != null) {
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

  /// Save library to storage
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

  /// Add a single ROM file
  Future<bool> addRom(String path) async {
    final game = GameRom.fromPath(path);
    if (game == null) return false;

    // Check if already exists
    if (_games.any((g) => g.path == path)) return true;

    _games.add(game);
    await _saveLibrary();
    notifyListeners();
    return true;
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

  /// Refresh library by rescanning all directories
  Future<void> refresh() async {
    _isLoading = true;
    notifyListeners();

    // Keep favorites and play history
    final gameData = Map.fromEntries(
      _games.map((g) => MapEntry(g.path, (g.isFavorite, g.lastPlayed))),
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
}

