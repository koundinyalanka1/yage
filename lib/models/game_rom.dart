import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/mgba_bindings.dart';

const _sentinel = Object();

/// Represents a game ROM file
class GameRom {
  final String path;
  final String name;
  final String extension;
  final GamePlatform platform;
  final int sizeBytes;
  final DateTime? lastPlayed;
  final String? coverPath;
  final bool isFavorite;
  final int totalPlayTimeSeconds;

  GameRom({
    required this.path,
    required this.name,
    required this.extension,
    required this.platform,
    required this.sizeBytes,
    this.lastPlayed,
    this.coverPath,
    this.isFavorite = false,
    this.totalPlayTimeSeconds = 0,
  });

  /// Create from file path
  static GameRom? fromPath(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) return null;

    final ext = p.extension(filePath).toLowerCase();
    final platform = _detectPlatform(ext);
    if (platform == GamePlatform.unknown) return null;

    final name = p.basenameWithoutExtension(filePath);
    final stat = file.statSync();

    return GameRom(
      path: filePath,
      name: name,
      extension: ext,
      platform: platform,
      sizeBytes: stat.size,
    );
  }

  static GamePlatform _detectPlatform(String extension) {
    return switch (extension) {
      '.gba' => GamePlatform.gba,
      '.gb' => GamePlatform.gb,
      '.gbc' => GamePlatform.gbc,
      '.sgb' => GamePlatform.gb,
      _ => GamePlatform.unknown,
    };
  }

  String get platformName => switch (platform) {
    GamePlatform.gba => 'Game Boy Advance',
    GamePlatform.gb => 'Game Boy',
    GamePlatform.gbc => 'Game Boy Color',
    GamePlatform.unknown => 'Unknown',
  };

  String get platformShortName => switch (platform) {
    GamePlatform.gba => 'GBA',
    GamePlatform.gb => 'GB',
    GamePlatform.gbc => 'GBC',
    GamePlatform.unknown => '???',
  };

  String get formattedSize {
    if (sizeBytes < 1024) {
      return '$sizeBytes B';
    } else if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    } else {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
  }

  /// Format total play time as a human-readable string
  String get formattedPlayTime {
    if (totalPlayTimeSeconds <= 0) return 'Never played';
    final hours = totalPlayTimeSeconds ~/ 3600;
    final minutes = (totalPlayTimeSeconds % 3600) ~/ 60;
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else if (minutes > 0) {
      return '${minutes}m';
    } else {
      return '<1m';
    }
  }

  GameRom copyWith({
    String? path,
    String? name,
    String? extension,
    GamePlatform? platform,
    int? sizeBytes,
    Object? lastPlayed = _sentinel,
    Object? coverPath = _sentinel,
    bool? isFavorite,
    int? totalPlayTimeSeconds,
  }) {
    return GameRom(
      path: path ?? this.path,
      name: name ?? this.name,
      extension: extension ?? this.extension,
      platform: platform ?? this.platform,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      lastPlayed: lastPlayed == _sentinel ? this.lastPlayed : lastPlayed as DateTime?,
      coverPath: coverPath == _sentinel ? this.coverPath : coverPath as String?,
      isFavorite: isFavorite ?? this.isFavorite,
      totalPlayTimeSeconds: totalPlayTimeSeconds ?? this.totalPlayTimeSeconds,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'name': name,
      'extension': extension,
      'platform': platform.name,
      'sizeBytes': sizeBytes,
      'lastPlayed': lastPlayed?.toIso8601String(),
      'coverPath': coverPath,
      'isFavorite': isFavorite,
      'totalPlayTimeSeconds': totalPlayTimeSeconds,
    };
  }

  factory GameRom.fromJson(Map<String, dynamic> json) {
    return GameRom(
      path: json['path'] as String,
      name: json['name'] as String,
      extension: json['extension'] as String,
      platform: _parsePlatform(json['platform']),
      sizeBytes: json['sizeBytes'] as int,
      lastPlayed: json['lastPlayed'] != null
          ? DateTime.parse(json['lastPlayed'] as String)
          : null,
      coverPath: json['coverPath'] as String?,
      isFavorite: json['isFavorite'] as bool? ?? false,
      totalPlayTimeSeconds: json['totalPlayTimeSeconds'] as int? ?? 0,
    );
  }

  /// Parse platform from JSON, supporting both the current string format
  /// (.name) and the legacy int index format for backwards compatibility.
  static GamePlatform _parsePlatform(dynamic value) {
    if (value is String) {
      return GamePlatform.values.firstWhere(
        (e) => e.name == value,
        orElse: () => GamePlatform.unknown,
      );
    }
    if (value is int && value >= 0 && value < GamePlatform.values.length) {
      return GamePlatform.values[value];
    }
    return GamePlatform.unknown;
  }
}

