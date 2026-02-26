import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

import '../utils/tv_detector.dart';
import '../widgets/tv_file_browser.dart';

const _deviceChannel = MethodChannel('com.yourmateapps.retropal/device');

/// Service for ROM folder setup: pick folder, import from folder, sync saves.
///
/// On Android: uses SAF (Storage Access Framework) for persistent folder access.
/// On TV: uses TvFileBrowser for directory picker.
/// On desktop/other: uses FilePicker.getDirectoryPath.
class RomFolderService {
  /// Pick a ROMs folder. Returns URI (Android SAF) or path (other platforms).
  /// Returns null if user cancels.
  static Future<String?> pickFolder(dynamic context) async {
    // TV check must come before Android — SAF doesn't work well without touch.
    if (TvDetector.isTV && context != null) {
      return TvFileBrowser.pickDirectory(context as dynamic);
    }

    if (Platform.isAndroid) {
      try {
        final uri = await _deviceChannel.invokeMethod<String>('pickRomsFolder');
        return uri;
      } catch (e) {
        debugPrint('RomFolderService: pickRomsFolder failed — $e');
        return null;
      }
    }

    try {
      return await FilePicker.platform.getDirectoryPath();
    } catch (e) {
      debugPrint('RomFolderService: getDirectoryPath failed — $e');
      return null;
    }
  }

  /// Import ROMs and saves from the given folder URI/path into internal storage.
  /// On Android with SAF URI: uses native import.
  /// With direct path: scans directory and copies files.
  /// Returns list of internal ROM paths that were imported.
  static Future<List<String>> importFromFolder(String folderUriOrPath) async {
    if (Platform.isAndroid && folderUriOrPath.startsWith('content://')) {
      try {
        final result = await _deviceChannel.invokeMethod<List<dynamic>>(
          'importFromFolderUri',
          {'treeUri': folderUriOrPath},
        );
        return (result ?? []).cast<String>();
      } catch (e) {
        debugPrint('RomFolderService: importFromFolderUri failed — $e');
        return [];
      }
    }

    // Direct path (TV, desktop, or legacy Android)
    // GameLibraryService.addRomDirectory + scanDirectory handles this
    return [];
  }

  /// Copy a save file from internal storage to the user's folder.
  /// On Android with SAF URI: uses native copy.
  /// With direct path: uses Dart File.copy.
  /// Returns true if successful.
  static Future<bool> copySaveToUserFolder(
    String folderUriOrPath,
    String sourceFilePath,
  ) async {
    if (Platform.isAndroid && folderUriOrPath.startsWith('content://')) {
      try {
        final success = await _deviceChannel.invokeMethod<bool>(
          'copySaveToUserFolder',
          {
            'treeUri': folderUriOrPath,
            'sourcePath': sourceFilePath,
          },
        );
        return success ?? false;
      } catch (e) {
        debugPrint('RomFolderService: copySaveToUserFolder failed — $e');
        return false;
      }
    }

    // Direct path: copy file to folder
    try {
      final destDir = Directory(folderUriOrPath);
      if (!await destDir.exists()) {
        await destDir.create(recursive: true);
      }
      final fileName = sourceFilePath.split(RegExp(r'[/\\]')).last;
      final destFile = File('${destDir.path}/$fileName');
      await File(sourceFilePath).copy(destFile.path);
      return true;
    } catch (e) {
      debugPrint('RomFolderService: copy to path failed — $e');
      return false;
    }
  }

  /// Check if the platform supports the ROM folder feature (pick + sync).
  static bool get isSupported => true;
}
