import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../core/mgba_bindings.dart';
import '../models/game_rom.dart';

/// SQLite database for persisting the game library.
///
/// Replaces the previous SharedPreferences JSON-blob approach, which does not
/// scale well as the library grows because every mutation rewrites the entire
/// blob.  With SQLite each operation is an efficient row-level write.
class GameDatabase {
  static const int _version = 1;
  static const String _dbName = 'game_library.db';

  /// SharedPreferences keys used by the legacy JSON storage.
  static const String _legacyGamesKey = 'game_library';
  static const String _legacyDirsKey = 'rom_directories';

  Database? _db;

  /// The opened database instance.  Call [open] first.
  Database get db {
    assert(_db != null, 'GameDatabase.open() must be called before accessing db');
    return _db!;
  }

  bool get isOpen => _db != null;

  // ──────────── Open / create ────────────

  /// Open (or create) the database and run any pending migrations.
  /// If legacy SharedPreferences data exists it is migrated automatically.
  Future<void> open() async {
    if (_db != null) return;

    final dbPath = p.join(await getDatabasesPath(), _dbName);
    _db = await openDatabase(
      dbPath,
      version: _version,
      onCreate: _onCreate,
    );

    // One-time migration from SharedPreferences → SQLite.
    await _migrateLegacyData();
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE games (
        path         TEXT PRIMARY KEY,
        name         TEXT NOT NULL,
        extension    TEXT NOT NULL,
        platform     TEXT NOT NULL,
        size_bytes   INTEGER NOT NULL,
        last_played  TEXT,
        cover_path   TEXT,
        is_favorite  INTEGER NOT NULL DEFAULT 0,
        total_play_time_seconds INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE rom_directories (
        path TEXT PRIMARY KEY
      )
    ''');
  }

  // ──────────── Legacy migration ────────────

  Future<void> _migrateLegacyData() async {
    final prefs = await SharedPreferences.getInstance();
    final gamesJson = prefs.getString(_legacyGamesKey);

    if (gamesJson == null || gamesJson.isEmpty) return;

    debugPrint('GameDatabase: migrating legacy SharedPreferences data …');

    try {
      final List<dynamic> gamesList = jsonDecode(gamesJson);
      final batch = _db!.batch();
      int skipped = 0;
      for (final json in gamesList) {
        try {
          final map = json as Map<String, dynamic>;
          // Skip entries missing required fields instead of aborting the
          // entire migration.
          if (map['path'] == null || map['name'] == null || map['extension'] == null) {
            skipped++;
            continue;
          }
          batch.insert(
            'games',
            _gameJsonToRow(map),
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        } catch (e) {
          debugPrint('GameDatabase: skipping corrupt legacy entry — $e');
          skipped++;
        }
      }
      if (skipped > 0) {
        debugPrint('GameDatabase: skipped $skipped corrupt legacy entries');
      }

      final dirs = prefs.getStringList(_legacyDirsKey);
      if (dirs != null) {
        for (final dir in dirs) {
          batch.insert(
            'rom_directories',
            {'path': dir},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }

      await batch.commit(noResult: true);

      // Clear legacy keys so migration runs only once.
      await prefs.remove(_legacyGamesKey);
      await prefs.remove(_legacyDirsKey);

      debugPrint('GameDatabase: migration complete (${gamesList.length} games).');
    } catch (e) {
      debugPrint('GameDatabase: migration failed — $e');
      // Non-fatal: the legacy data stays in SharedPreferences so the user
      // can retry on next launch.
    }
  }

  /// Convert a legacy JSON map (same format as GameRom.toJson) to a flat
  /// row map suitable for SQLite insertion.
  static Map<String, Object?> _gameJsonToRow(Map<String, dynamic> json) {
    // Platform: legacy data may store as int index or string name.
    final rawPlatform = json['platform'];
    final String platformStr;
    if (rawPlatform is String) {
      platformStr = rawPlatform;
    } else if (rawPlatform is int) {
      platformStr = GamePlatform.values.elementAtOrNull(rawPlatform)?.name ?? 'unknown';
    } else {
      platformStr = 'unknown';
    }

    return {
      'path': json['path'] as String,
      'name': json['name'] as String,
      'extension': json['extension'] as String,
      'platform': platformStr,
      'size_bytes': json['sizeBytes'] as int,
      'last_played': json['lastPlayed'] as String?,
      'cover_path': json['coverPath'] as String?,
      'is_favorite': (json['isFavorite'] as bool? ?? false) ? 1 : 0,
      'total_play_time_seconds': json['totalPlayTimeSeconds'] as int? ?? 0,
    };
  }

  // ──────────── CRUD helpers ────────────

  /// Read all games from the database, ordered by name.
  Future<List<GameRom>> getAllGames() async {
    final rows = await db.query('games', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(_rowToGameRom).toList();
  }

  /// Insert or replace a single game.
  Future<void> upsertGame(GameRom game) async {
    await db.insert('games', _gameRomToRow(game),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Insert or replace many games in a single transaction.
  Future<void> upsertGames(List<GameRom> games) async {
    final batch = db.batch();
    for (final game in games) {
      batch.insert('games', _gameRomToRow(game),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// Delete a game by path.
  Future<void> deleteGame(String path) async {
    await db.delete('games', where: 'path = ?', whereArgs: [path]);
  }

  /// Delete all games whose path starts with [prefix].
  Future<void> deleteGamesWithPrefix(String prefix) async {
    // Use the LIKE operator with the prefix escaped for safety.
    final escaped = prefix.replaceAll('%', r'\%').replaceAll('_', r'\_');
    await db.delete(
      'games',
      where: "path LIKE ? ESCAPE '\\'",
      whereArgs: ['$escaped%'],
    );
  }

  /// Update specific columns for a game identified by [path].
  Future<void> updateGame(String path, Map<String, Object?> values) async {
    await db.update('games', values, where: 'path = ?', whereArgs: [path]);
  }

  // ──────────── ROM directories ────────────

  Future<List<String>> getRomDirectories() async {
    final rows = await db.query('rom_directories');
    return rows.map((r) => r['path'] as String).toList();
  }

  Future<void> addRomDirectory(String path) async {
    await db.insert('rom_directories', {'path': path},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removeRomDirectory(String path) async {
    await db.delete('rom_directories', where: 'path = ?', whereArgs: [path]);
  }

  // ──────────── Row ↔ GameRom conversion ────────────

  static GameRom _rowToGameRom(Map<String, Object?> row) {
    return GameRom(
      path: row['path'] as String,
      name: row['name'] as String,
      extension: row['extension'] as String,
      platform: _parsePlatform(row['platform'] as String),
      sizeBytes: row['size_bytes'] as int,
      lastPlayed: row['last_played'] != null
          ? DateTime.tryParse(row['last_played'] as String)
          : null,
      coverPath: row['cover_path'] as String?,
      isFavorite: (row['is_favorite'] as int) == 1,
      totalPlayTimeSeconds: row['total_play_time_seconds'] as int? ?? 0,
    );
  }

  static Map<String, Object?> _gameRomToRow(GameRom game) {
    return {
      'path': game.path,
      'name': game.name,
      'extension': game.extension,
      'platform': game.platform.name,
      'size_bytes': game.sizeBytes,
      'last_played': game.lastPlayed?.toIso8601String(),
      'cover_path': game.coverPath,
      'is_favorite': game.isFavorite ? 1 : 0,
      'total_play_time_seconds': game.totalPlayTimeSeconds,
    };
  }

  static GamePlatform _parsePlatform(String value) {
    return GamePlatform.values.firstWhere(
      (e) => e.name == value,
      orElse: () => GamePlatform.unknown,
    );
  }

  // ──────────── Lifecycle ────────────

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
