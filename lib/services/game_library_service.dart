import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../models/game_rom.dart';
import '../core/mgba_bindings.dart';
import 'game_database.dart';
import 'retro_achievements_service.dart';


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

  final Completer<void> _initCompleter = Completer<void>();

  /// Future that completes when [initialize] has finished.
  Future<void> get whenReady => _initCompleter.future;

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
    try {
      final appDir = await getApplicationSupportDirectory();
      final romsDir = Directory(p.join(appDir.path, 'roms'));
      if (!await romsDir.exists()) {
        await romsDir.create(recursive: true);
      }
      _internalRomsDir = romsDir.path;
      return _internalRomsDir!;
    } catch (e) {
      debugPrint('GameLibraryService: getInternalRomsDir failed — $e');
      rethrow;
    }
  }

  // ──────────── Initialize ────────────

  /// Load the game library from SQLite.
  /// Uses async file.exists() instead of existsSync() to avoid ANR on
  /// large libraries or slow storage.
  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();

    try {
      final allGames = await _database.getAllGames();
      final existing = <GameRom>[];
      final stalePaths = <String>[];

      for (final game in allGames) {
        try {
          if (await File(game.path).exists()) {
            existing.add(game);
          } else {
            stalePaths.add(game.path);
          }
        } catch (_) {
          // Permission denied, I/O error — treat as stale
          stalePaths.add(game.path);
        }
      }

      _games = existing;

      for (final path in stalePaths) {
        await _database.deleteGame(path);
      }

      _romDirectories = await _database.getRomDirectories();

      _isLoading = false;
      _error = null;
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load library: $e';
      _isLoading = false;
      notifyListeners();
    } finally {
      if (!_initCompleter.isCompleted) _initCompleter.complete();
    }
  }

  // ──────────── ROM import (SAF-friendly) ────────────

  /// Import a ROM by copying it to internal storage first, then adding to library.
  ///
  /// Use this when the source file might be in a cache or SAF-provided location
  /// that could be cleaned up. The ROM is copied to the app's permanent internal
  /// roms directory. Skips duplicates (same content hash).
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

    final game = await addRom(destPath);
    if (game == null) {
      // Duplicate - remove the copied file to avoid wasting space
      try {
        await File(destPath).delete();
      } catch (_) {}
    }
    return game;
  }

  /// Import ROMs from a ZIP archive.
  ///
  /// Extracts any `.gba`, `.gb`, `.gbc`, `.sgb`, `.nes`, `.sfc`, or `.smc` files found inside the ZIP,
  /// copies them to internal storage, and adds them to the library.
  /// Returns the list of successfully imported [GameRom]s.
  ///
  /// If the ZIP file itself is inside the internal roms directory (e.g. copied
  /// there by a VIEW intent), it is deleted after extraction to save space.
  Future<List<GameRom>> importRomZip(String zipPath) async {
    const romExtensions = {'.gba', '.gb', '.gbc', '.sgb', '.nes', '.sfc', '.smc'};
    final romsDir = await getInternalRomsDir();
    final addedGames = <GameRom>[];

    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      for (final entry in archive.files) {
        if (!entry.isFile) continue;

        final ext = p.extension(entry.name).toLowerCase();
        if (!romExtensions.contains(ext)) continue;

        // Use the leaf file name (ignore directory structure inside ZIP)
        final fileName = p.basename(entry.name);
        final destPath = p.join(romsDir, fileName);

        // Skip if a ROM with the same name already exists on disk
        if (await File(destPath).exists()) {
          final game = await addRom(destPath);
          if (game != null) addedGames.add(game);
          continue;
        }

        // Check for duplicate by content hash before writing (avoids writing then deleting)
        final bytes = entry.content as List<int>;
        final contentHash = RetroAchievementsService.computeRAHashFromBytes(
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
          ext,
        );
        if (contentHash != null) {
          final existingPath = await _database.getPathByRomHash(contentHash);
          if (existingPath != null) {
            debugPrint('GameLibraryService: skipping duplicate ROM in ZIP (hash $contentHash)');
            continue;
          }
        }

        // Write extracted ROM to internal storage
        try {
          await File(destPath).writeAsBytes(bytes);
          final game = await addRom(destPath);
          if (game != null) addedGames.add(game);
        } catch (e) {
          debugPrint('Error extracting ROM "$fileName" from ZIP: $e');
        }
      }
    } catch (e) {
      debugPrint('Error reading ZIP file: $e');
    }

    // Clean up: if the ZIP is inside the roms directory (e.g. copied there
    // by a VIEW intent), delete it after extraction to save space.
    try {
      final zipFile = File(zipPath);
      if (await zipFile.exists() && p.dirname(zipPath) == romsDir) {
        await zipFile.delete();
      }
    } catch (_) {}

    return addedGames;
  }

  // ──────────── ROM management ────────────

  /// Add a single ROM file - returns the added game or null.
  /// Skips duplicates (same content hash) to avoid duplicate entries in the library.
  Future<GameRom?> addRom(String path) async {
    final game = GameRom.fromPath(path);
    if (game == null) return null;

    // Check if already exists by path
    if (_games.any((g) => g.path == path)) return null;

    // Compute content hash and check for duplicate (same ROM, different path)
    final hash = await RetroAchievementsService.computeRAHash(path);
    if (hash != null) {
      final existingPath = await _database.getPathByRomHash(hash);
      if (existingPath != null && existingPath != path) {
        debugPrint('GameLibraryService: skipping duplicate ROM (hash $hash)');
        return null;
      }
    }

    _games.add(game);
    if (!await _database.upsertGame(game, romHash: hash)) {
      _games.removeLast();
      return null;
    }
    notifyListeners();
    return game;
  }

  /// Import ROMs and saves from a directory by copying to internal storage.
  /// Use this when setting up a user folder (e.g. on TV or reinstall).
  /// Returns the list of imported games.
  Future<List<GameRom>> importFromDirectory(
    String path, {
    String? appSaveDir,
  }) async {
    final addedGames = <GameRom>[];
    final dir = Directory(path);
    if (!await dir.exists()) return addedGames;

    final romExtensions = {'.gba', '.gb', '.gbc', '.sgb', '.nes', '.sfc', '.smc'};
    final entities = await dir.list(recursive: true).toList();

    for (final entity in entities) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (!romExtensions.contains(ext)) continue;

      final game = await importRom(entity.path);
      if (game != null) addedGames.add(game);
    }

    if (appSaveDir != null) {
      final saveDir = Directory(appSaveDir);
      if (!await saveDir.exists()) await saveDir.create(recursive: true);

      for (final entity in entities) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        final ext = p.extension(entity.path).toLowerCase();

        final isSram = ext == '.sav';
        final isSaveState = RegExp(r'\.ss[0-5]$').hasMatch(name) ||
            RegExp(r'\.ss[0-5]\.png$').hasMatch(name);

        if (isSram || isSaveState) {
          try {
            final dest = File(p.join(appSaveDir, name));
            if (!await dest.exists()) {
              await entity.copy(dest.path);
            }
          } catch (_) {}
        }
      }
    }

    if (addedGames.isNotEmpty) notifyListeners();
    return addedGames;
  }

  /// Add a ROM directory to scan (legacy — works only when filesystem is accessible)
  Future<void> addRomDirectory(String path) async {
    if (_romDirectories.contains(path)) return;

    if (!await _database.addRomDirectory(path)) return;
    _romDirectories.add(path);
    await scanDirectory(path);
  }

  /// Scan a directory for ROM files (requires filesystem read access)
  Future<void> scanDirectory(String path) async {
    _isLoading = true;
    notifyListeners();

    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        _error = 'Directory does not exist: $path';
        _isLoading = false;
        notifyListeners();
        return;
      }

      final entities = await dir.list(recursive: true).toList();
      final newGames = <GameRom>[];

      for (final entity in entities) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (['.gba', '.gb', '.gbc', '.sgb', '.nes', '.sfc', '.smc'].contains(ext)) {
            final game = GameRom.fromPath(entity.path);
            if (game == null || _games.any((g) => g.path == entity.path)) continue;

            // Skip duplicates by content hash
            final hash = await RetroAchievementsService.computeRAHash(entity.path);
            if (hash != null) {
              final existingPath = await _database.getPathByRomHash(hash);
              if (existingPath != null) continue;
            }

            _games.add(game);
            newGames.add(game);
          }
        }
      }

      if (newGames.isNotEmpty) {
        try {
          final hashes = <String, String>{};
          for (final g in newGames) {
            final h = await RetroAchievementsService.computeRAHash(g.path);
            if (h != null) hashes[g.path] = h;
          }
          await _database.upsertGames(newGames, romHashes: hashes);
        } catch (e) {
          debugPrint('GameLibraryService: scanDirectory upsert failed — $e');
        }
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
    try {
      await _database.deleteGame(game.path);
    } catch (e) {
      debugPrint('GameLibraryService: removeRom delete failed — $e');
    }
    notifyListeners();
  }

  /// Remove a ROM directory
  Future<void> removeRomDirectory(String path) async {
    _romDirectories.remove(path);
    final prefix = path.endsWith(p.separator) ? path : '$path${p.separator}';
    _games.removeWhere((g) => g.path.startsWith(prefix) || g.path == path);
    try {
      await _database.removeRomDirectory(path);
      await _database.deleteGamesWithPrefix(prefix);
    } catch (e) {
      debugPrint('GameLibraryService: removeRomDirectory failed — $e');
    }
    notifyListeners();
  }

  /// Toggle favorite status
  Future<void> toggleFavorite(GameRom game) async {
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      _games[index] = _games[index].copyWith(isFavorite: !_games[index].isFavorite);
      try {
        await _database.updateGame(game.path, {
          'is_favorite': _games[index].isFavorite ? 1 : 0,
        });
      } catch (e) {
        _games[index] = _games[index].copyWith(isFavorite: !_games[index].isFavorite);
        debugPrint('GameLibraryService: toggleFavorite failed — $e');
      }
      notifyListeners();
    }
  }

  /// Update last played time
  Future<void> updateLastPlayed(GameRom game) async {
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      final now = DateTime.now();
      _games[index] = _games[index].copyWith(lastPlayed: now);
      try {
        await _database.updateGame(game.path, {
          'last_played': now.toIso8601String(),
        });
      } catch (e) {
        debugPrint('GameLibraryService: updateLastPlayed failed — $e');
      }
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
      try {
        await _database.updateGame(game.path, {
          'total_play_time_seconds': newTotal,
        });
      } catch (e) {
        _games[index] = _games[index].copyWith(
            totalPlayTimeSeconds: _games[index].totalPlayTimeSeconds - seconds);
        debugPrint('GameLibraryService: addPlayTime failed — $e');
      }
      notifyListeners();
    }
  }

  /// Set cover art for a game
  Future<void> setCoverArt(GameRom game, String coverPath) async {
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      final prev = _games[index].coverPath;
      _games[index] = _games[index].copyWith(coverPath: coverPath);
      try {
        await _database.updateGame(game.path, {'cover_path': coverPath});
      } catch (e) {
        _games[index] = _games[index].copyWith(coverPath: prev);
        debugPrint('GameLibraryService: setCoverArt failed — $e');
      }
      notifyListeners();
    }
  }

  /// Remove cover art from a game
  Future<void> removeCoverArt(GameRom game) async {
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      final prev = _games[index].coverPath;
      _games[index] = _games[index].copyWith(coverPath: null);
      try {
        await _database.updateGame(game.path, {'cover_path': null});
      } catch (e) {
        _games[index] = _games[index].copyWith(coverPath: prev);
        debugPrint('GameLibraryService: removeCoverArt failed — $e');
      }
      notifyListeners();
    }
  }

  /// Refresh library by rescanning all directories.
  ///
  /// Builds a fresh game list without clearing the existing one first,
  /// then swaps atomically — so a disk error or permission failure
  /// during scanning never causes data loss.
  ///
  /// Always includes the internal ROMs directory (intent/SAF imports)
  /// so those games are never lost on refresh.
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

    // Collect all directories to scan: user-added + internal storage.
    final dirsToScan = List<String>.from(_romDirectories);
    try {
      final internalDir = await getInternalRomsDir();
      if (!dirsToScan.contains(internalDir)) {
        dirsToScan.add(internalDir);
      }
    } catch (_) {
      // Internal dir unavailable — continue with user dirs only
    }

    try {
      for (final dir in dirsToScan) {
        try {
          final dirObj = Directory(dir);
          if (!await dirObj.exists()) continue;

          final entities = await dirObj.list(recursive: true).toList();
          for (final entity in entities) {
            if (entity is File) {
              final ext = p.extension(entity.path).toLowerCase();
              if (['.gba', '.gb', '.gbc', '.sgb', '.nes', '.sfc', '.smc'].contains(ext)) {
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
      _games = freshGames;

      // Persist the refreshed list to the database in a single batch.
      try {
        await _database.upsertGames(freshGames);
      } catch (e) {
        debugPrint('GameLibraryService: refresh upsert failed — $e');
      }
      _error = null;
    } catch (e) {
      debugPrint('GameLibraryService: refresh failed — $e');
      _error = 'Refresh failed: $e';
      // Keep existing _games — do not overwrite with empty
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Search games by name
  List<GameRom> search(String query) {
    if (query.isEmpty) return _games;
    final lowerQuery = query.toLowerCase();
    return _games.where((g) => g.name.toLowerCase().contains(lowerQuery)).toList();
  }

}
