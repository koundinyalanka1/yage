import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/game_rom.dart';

/// Service for exporting / importing save data as ZIP archives,
/// with optional Google Drive cloud backup.
class SaveBackupService {
  // ─────────────────────────────────────────────
  //  ZIP Export
  // ─────────────────────────────────────────────

  /// Export save files for ALL games into a ZIP.
  /// Returns the saved ZIP path, or null if cancelled / failed.
  static Future<String?> exportAllSaves({
    required List<GameRom> games,
    required String? appSaveDir,
    void Function(int done, int total)? onProgress,
  }) async {
    final files = await _collectSaveFiles(games, appSaveDir, onProgress);
    if (files.isEmpty) return null;
    return _writeZip(files, 'retropal_saves');
  }

  /// Export save files for a SINGLE game into a ZIP.
  static Future<String?> exportGameSaves({
    required GameRom game,
    required String? appSaveDir,
  }) async {
    final files = await _collectSaveFiles([game], appSaveDir, null);
    if (files.isEmpty) return null;
    final safeName = p.basenameWithoutExtension(game.path)
        .replaceAll(RegExp(r'[^\w\-.]'), '_');
    return _writeZip(files, 'retropal_${safeName}_saves');
  }

  /// Let the user pick where to save the ZIP (file picker).
  ///
  /// The temp ZIP at [tempZipPath] is always deleted when this method
  /// returns — whether the user saved, cancelled, or an error occurred.
  static Future<String?> saveZipToUserLocation(String tempZipPath) async {
    try {
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save backup ZIP',
        fileName: p.basename(tempZipPath),
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (result == null) return null;

      // Copy temp file to chosen location
      final destPath = result.endsWith('.zip') ? result : '$result.zip';
      await File(tempZipPath).copy(destPath);
      return destPath;
    } catch (e) {
      debugPrint('Error saving ZIP: $e');
      return null;
    } finally {
      deleteTempZip(tempZipPath);
    }
  }

  /// Delete a temp ZIP file if it exists.  Call this when the temp file
  /// is no longer needed (e.g. after sharing or when a dialog closes).
  static void deleteTempZip(String? path) {
    if (path == null) return;
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  /// Share the ZIP via the system share sheet (Google Drive, email, etc.).
  ///
  /// The temp ZIP at [zipPath] is deleted after the share sheet is
  /// dismissed (or on error).
  static Future<void> shareZip(String zipPath) async {
    try {
      await Share.shareXFiles(
        [XFile(zipPath)],
        subject: 'RetroPal Save Backup',
        text: 'RetroPal save data backup',
      );
    } catch (e) {
      debugPrint('Error sharing ZIP: $e');
    } finally {
      deleteTempZip(zipPath);
    }
  }

  // ─────────────────────────────────────────────
  //  ZIP Import
  // ─────────────────────────────────────────────

  /// Let user pick a ZIP and import saves, placing files next to matching ROMs.
  /// Returns the number of files restored.
  static Future<int> importFromZipPicker({
    required List<GameRom> games,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select backup ZIP',
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (result == null || result.files.isEmpty) return 0;

    final path = result.files.single.path;
    if (path == null) return 0;

    return importFromZip(zipPath: path, games: games);
  }

  /// Import saves from a ZIP file, matching files to existing ROMs by name.
  static Future<int> importFromZip({
    required String zipPath,
    required List<GameRom> games,
  }) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // Build a lookup: romBaseName -> ROM directory
      final romDirMap = <String, String>{};
      for (final game in games) {
        final baseName = p.basenameWithoutExtension(game.path);
        final romDir = p.dirname(game.path);
        romDirMap[baseName] = romDir;
      }

      int restored = 0;

      for (final entry in archive.files) {
        if (entry.isFile) {
          // Expected path in ZIP: retropal_saves/<RomBaseName>/<filename>
          final parts = p.split(entry.name);
          if (parts.length < 2) continue;

          // The game folder is the second-to-last path component
          final gameFolderName = parts[parts.length - 2];
          final fileName = parts.last;

          // Skip metadata
          if (fileName == '_metadata.json') continue;

          // Find matching ROM
          final romDir = romDirMap[gameFolderName];
          if (romDir == null) {
            debugPrint('No matching ROM for: $gameFolderName/$fileName');
            continue;
          }

          // Write file next to ROM
          try {
            final destPath = p.join(romDir, fileName);
            final destFile = File(destPath);
            await destFile.writeAsBytes(entry.content as List<int>);
            restored++;
            debugPrint('Restored: $destPath');
          } catch (e) {
            debugPrint('Error restoring $fileName: $e');
          }
        }
      }

      return restored;
    } catch (e) {
      debugPrint('Error importing ZIP: $e');
      return 0;
    }
  }

  // ─────────────────────────────────────────────
  //  Google Drive
  // ─────────────────────────────────────────────

  static GoogleSignIn? _googleSignIn;

  static GoogleSignIn get _signIn {
    _googleSignIn ??= GoogleSignIn(
      scopes: [drive.DriveApi.driveFileScope],
    );
    return _googleSignIn!;
  }

  /// Check if a Google account is signed in.
  static Future<bool> isGoogleSignedIn() async {
    try {
      return await _signIn.isSignedIn();
    } catch (_) {
      return false;
    }
  }

  /// Sign in to Google (interactive).
  static Future<bool> googleSignIn() async {
    try {
      final account = await _signIn.signIn();
      return account != null;
    } catch (e) {
      debugPrint('Google Sign-In error: $e');
      return false;
    }
  }

  /// Sign out of Google.
  static Future<void> googleSignOut() async {
    try {
      await _signIn.signOut();
    } catch (_) {}
  }

  /// Upload a ZIP to Google Drive in a "RetroPal" folder.
  /// Returns the Drive file ID, or null on failure.
  static Future<String?> uploadToDrive(String zipPath) async {
    try {
      final httpClient = await _signIn.authenticatedClient();
      if (httpClient == null) return null;

      final driveApi = drive.DriveApi(httpClient);

      // Find or create "RetroPal" folder
      final folderId = await _getOrCreateDriveFolder(driveApi, 'RetroPal');

      // Check for an existing file with the same name and update it
      // instead of creating a duplicate.
      final fileName = p.basename(zipPath);
      final existing = await driveApi.files.list(
        q: "'$folderId' in parents and name='$fileName' and trashed=false",
        $fields: 'files(id)',
      );

      final media = drive.Media(
        File(zipPath).openRead(),
        File(zipPath).lengthSync(),
      );

      final drive.File result;
      if (existing.files != null && existing.files!.isNotEmpty) {
        // Update the existing file's content in place
        result = await driveApi.files.update(
          drive.File()..name = fileName,
          existing.files!.first.id!,
          uploadMedia: media,
        );
      } else {
        // No existing file — create a new one
        final driveFile = drive.File()
          ..name = fileName
          ..parents = [folderId];
        result = await driveApi.files.create(driveFile, uploadMedia: media);
      }
      httpClient.close();
      return result.id;
    } catch (e) {
      debugPrint('Drive upload error: $e');
      return null;
    }
  }

  /// List backup ZIPs in the "RetroPal" Drive folder.
  static Future<List<drive.File>> listDriveBackups() async {
    try {
      final httpClient = await _signIn.authenticatedClient();
      if (httpClient == null) return [];

      final driveApi = drive.DriveApi(httpClient);
      final folderId = await _getOrCreateDriveFolder(driveApi, 'RetroPal');

      final result = await driveApi.files.list(
        q: "'$folderId' in parents and mimeType='application/zip' and trashed=false",
        orderBy: 'modifiedTime desc',
        $fields: 'files(id,name,modifiedTime,size)',
      );

      httpClient.close();
      return result.files ?? [];
    } catch (e) {
      debugPrint('Drive list error: $e');
      return [];
    }
  }

  /// Download a backup ZIP from Google Drive to a temp path.
  static Future<String?> downloadFromDrive(String fileId) async {
    try {
      final httpClient = await _signIn.authenticatedClient();
      if (httpClient == null) return null;

      final driveApi = drive.DriveApi(httpClient);
      final media = await driveApi.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;

      final tempDir = await getTemporaryDirectory();
      final tempPath = p.join(tempDir.path, 'retropal_restore.zip');
      final sink = File(tempPath).openWrite();
      await media.stream.pipe(sink);
      await sink.close();

      httpClient.close();
      return tempPath;
    } catch (e) {
      debugPrint('Drive download error: $e');
      return null;
    }
  }

  static Future<String> _getOrCreateDriveFolder(
    drive.DriveApi api,
    String folderName,
  ) async {
    // Search for existing folder
    final existing = await api.files.list(
      q: "name='$folderName' and mimeType='application/vnd.google-apps.folder' and trashed=false",
      $fields: 'files(id)',
    );
    if (existing.files != null && existing.files!.isNotEmpty) {
      return existing.files!.first.id!;
    }

    // Create new folder
    final folder = drive.File()
      ..name = folderName
      ..mimeType = 'application/vnd.google-apps.folder';
    final created = await api.files.create(folder);
    return created.id!;
  }

  // ─────────────────────────────────────────────
  //  Internal helpers
  // ─────────────────────────────────────────────

  /// Collect all save files for a set of games.
  /// Returns map of ZIP-internal paths → file bytes.
  static Future<Map<String, List<int>>> _collectSaveFiles(
    List<GameRom> games,
    String? appSaveDir,
    void Function(int done, int total)? onProgress,
  ) async {
    final files = <String, List<int>>{};
    final total = games.length;

    for (var i = 0; i < games.length; i++) {
      final game = games[i];
      final baseName = p.basenameWithoutExtension(game.path);
      final romDir = p.dirname(game.path);

      // Directories to scan for this game's saves
      final dirs = <String>{romDir};
      if (appSaveDir != null && appSaveDir != romDir) {
        dirs.add(appSaveDir);
      }

      for (final dir in dirs) {
        // SRAM
        _tryAddFile(files, dir, '$baseName.sav', baseName);

        // Save states + thumbnails
        for (int slot = 0; slot < 6; slot++) {
          _tryAddFile(files, dir, '$baseName.ss$slot', baseName);
          _tryAddFile(files, dir, '$baseName.ss$slot.png', baseName);
        }

        // Timestamped screenshots
        try {
          final directory = Directory(dir);
          if (directory.existsSync()) {
            for (final entity in directory.listSync()) {
              if (entity is File) {
                final name = p.basename(entity.path);
                if (name.startsWith('${baseName}_') && name.endsWith('.png')) {
                  _tryAddFile(files, dir, name, baseName);
                }
              }
            }
          }
        } catch (_) {}
      }

      onProgress?.call(i + 1, total);
    }

    // Add metadata
    final meta = {
      'app': 'RetroPal',
      'version': '0.1.0',
      'exportDate': DateTime.now().toIso8601String(),
      'gameCount': games.length,
      'fileCount': files.length,
      'games': games
          .map((g) => {
                'name': g.name,
                'baseName': p.basenameWithoutExtension(g.path),
                'platform': g.platform.name,
              })
          .toList(),
    };
    files['retropal_saves/_metadata.json'] =
        utf8.encode(const JsonEncoder.withIndent('  ').convert(meta));

    return files;
  }

  static void _tryAddFile(
    Map<String, List<int>> files,
    String dir,
    String fileName,
    String gameFolder,
  ) {
    final file = File(p.join(dir, fileName));
    if (file.existsSync()) {
      try {
        final key = 'retropal_saves/$gameFolder/$fileName';
        if (!files.containsKey(key)) {
          files[key] = file.readAsBytesSync();
        }
      } catch (_) {}
    }
  }

  /// Create a ZIP from the file map and write to temp directory.
  /// Returns the temp ZIP path.
  static Future<String?> _writeZip(
    Map<String, List<int>> files,
    String baseName,
  ) async {
    try {
      final archive = Archive();

      for (final entry in files.entries) {
        archive.addFile(ArchiveFile(
          entry.key,
          entry.value.length,
          entry.value,
        ));
      }

      final zipData = ZipEncoder().encode(archive);
      if (zipData == null) return null;

      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final zipPath = p.join(tempDir.path, '${baseName}_$timestamp.zip');
      await File(zipPath).writeAsBytes(zipData);

      return zipPath;
    } catch (e) {
      debugPrint('Error creating ZIP: $e');
      return null;
    }
  }
}
