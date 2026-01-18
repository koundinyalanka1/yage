import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/mgba_bindings.dart';

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

  GameRom({
    required this.path,
    required this.name,
    required this.extension,
    required this.platform,
    required this.sizeBytes,
    this.lastPlayed,
    this.coverPath,
    this.isFavorite = false,
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

  GameRom copyWith({
    String? path,
    String? name,
    String? extension,
    GamePlatform? platform,
    int? sizeBytes,
    DateTime? lastPlayed,
    String? coverPath,
    bool? isFavorite,
  }) {
    return GameRom(
      path: path ?? this.path,
      name: name ?? this.name,
      extension: extension ?? this.extension,
      platform: platform ?? this.platform,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      lastPlayed: lastPlayed ?? this.lastPlayed,
      coverPath: coverPath ?? this.coverPath,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'name': name,
      'extension': extension,
      'platform': platform.index,
      'sizeBytes': sizeBytes,
      'lastPlayed': lastPlayed?.toIso8601String(),
      'coverPath': coverPath,
      'isFavorite': isFavorite,
    };
  }

  factory GameRom.fromJson(Map<String, dynamic> json) {
    return GameRom(
      path: json['path'] as String,
      name: json['name'] as String,
      extension: json['extension'] as String,
      platform: GamePlatform.values[json['platform'] as int],
      sizeBytes: json['sizeBytes'] as int,
      lastPlayed: json['lastPlayed'] != null
          ? DateTime.parse(json['lastPlayed'] as String)
          : null,
      coverPath: json['coverPath'] as String?,
      isFavorite: json['isFavorite'] as bool? ?? false,
    );
  }
}

