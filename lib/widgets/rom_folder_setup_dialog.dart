import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../models/game_rom.dart';
import '../services/cover_art_service.dart';
import '../services/game_library_service.dart';
import '../services/rom_folder_service.dart';
import '../services/settings_service.dart';
import '../utils/theme.dart';
import '../utils/tv_detector.dart';
import 'tv_focusable.dart';

/// Dialog shown on first launch to encourage users to set up a ROMs folder.
///
/// When the user selects a folder:
/// 1. ROMs and saves are imported from that folder to internal storage
/// 2. The folder URI/path is persisted for future sync
/// 3. New saves will be synced to this folder when created
///
/// On reinstall: user selects the same folder again to restore ROMs and saves.
class RomFolderSetupDialog extends StatefulWidget {
  /// Whether to allow dismissing without selecting (e.g. "Skip for now").
  final bool allowSkip;

  const RomFolderSetupDialog({super.key, this.allowSkip = true});

  @override
  State<RomFolderSetupDialog> createState() => _RomFolderSetupDialogState();
}

class _RomFolderSetupDialogState extends State<RomFolderSetupDialog> {
  bool _isLoading = false;
  String? _error;
  int _importedCount = 0;

  Future<void> _pickAndImport(BuildContext context) async {
    setState(() {
      _isLoading = true;
      _error = null;
      _importedCount = 0;
    });

    try {
      final folderUriOrPath = await RomFolderService.pickFolder(context);
      if (!mounted) return;
      if (folderUriOrPath == null || folderUriOrPath.isEmpty) {
        setState(() => _isLoading = false);
        return;
      }

      if (!mounted) return;
      final settings = context.read<SettingsService>();
      final library = context.read<GameLibraryService>();
      final coverService = context.read<CoverArtService>();

      List<GameRom> addedGames = [];

      if (Platform.isAndroid && folderUriOrPath.startsWith('content://')) {
        final internalPaths = await RomFolderService.importFromFolder(folderUriOrPath);
        for (final path in internalPaths) {
          if (!mounted) return;
          final game = await library.addRom(path);
          if (game != null) addedGames.add(game);
        }
      } else if (folderUriOrPath.isNotEmpty) {
        // Direct path (TV, desktop): copy ROMs and saves to internal storage
        final appDir = await getApplicationSupportDirectory();
        final saveDir = p.join(appDir.path, 'saves');
        addedGames = await library.importFromDirectory(
          folderUriOrPath,
          appSaveDir: saveDir,
        );
      }

      if (!mounted) return;

      await settings.setUserRomsFolderUri(folderUriOrPath);
      await settings.markRomFolderSetupCompleted();

      // Fire-and-forget: download cover art for newly imported games
      if (addedGames.isNotEmpty) {
        _autoFetchCovers(coverService, library, addedGames);
      }

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _importedCount = addedGames.length;
      });

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Fire-and-forget: download cover art for newly imported games.
  void _autoFetchCovers(
    CoverArtService coverService,
    GameLibraryService library,
    List<GameRom> games,
  ) {
    () async {
      for (final game in games) {
        if (game.coverPath != null) continue;
        try {
          final path = await coverService.fetchCoverArt(game);
          if (path != null) {
            await library.setCoverArt(game, path);
          }
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }();
  }

  void _skip(BuildContext context) {
    if (widget.allowSkip) {
      context.read<SettingsService>().markRomFolderSetupCompleted();
      Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);

    return PopScope(
      canPop: widget.allowSkip && !_isLoading,
      child: Shortcuts(
        shortcuts: {
          SingleActivator(LogicalKeyboardKey.escape): const DismissIntent(),
          SingleActivator(LogicalKeyboardKey.goBack): const DismissIntent(),
          SingleActivator(LogicalKeyboardKey.browserBack): const DismissIntent(),
        },
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) {
                if (widget.allowSkip && !_isLoading) _skip(context);
                return null;
              },
            ),
          },
          child: Focus(
            autofocus: true,
            child: AlertDialog(
              backgroundColor: colors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: colors.primary.withAlpha(77), width: 2),
              ),
              title: Row(
                children: [
                  Icon(Icons.folder_open, color: colors.accent, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Set Up Your Games Folder',
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: TvDetector.isTV ? 22 : 20,
                      ),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: TvDetector.isTV ? 400 : 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Choose a folder to store your ROMs and save data. This lets you:\n\n'
                      '• Keep your games and saves in one place\n'
                      '• Restore everything after reinstalling the app\n'
                      '• Sync new saves to your folder automatically',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: TvDetector.isTV ? 16 : 14,
                        height: 1.5,
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colors.error.withAlpha(51),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline, color: colors.error, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: TextStyle(color: colors.error, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (_importedCount > 0) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Imported $_importedCount game${_importedCount == 1 ? '' : 's'}!',
                        style: TextStyle(
                          color: colors.success,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                FocusTraversalGroup(
                  policy: OrderedTraversalPolicy(),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(0),
                        child: TvFocusable(
                          autofocus: true,
                          animate: false,
                          borderRadius: BorderRadius.circular(12),
                          onTap: _isLoading ? null : () => _pickAndImport(context),
                          onBack: widget.allowSkip ? () => _skip(context) : null,
                          child: FilledButton.icon(
                            onPressed: _isLoading
                                ? null
                                : () => _pickAndImport(context),
                            icon: _isLoading
                                ? SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: colors.textPrimary,
                                    ),
                                  )
                                : Icon(Icons.folder_open, size: 18, color: colors.backgroundDark),
                            label: Text(_isLoading ? 'Importing…' : 'Select Folder'),
                            style: FilledButton.styleFrom(
                              backgroundColor: colors.accent,
                              foregroundColor: colors.backgroundDark,
                            ),
                          ),
                        ),
                      ),
                      if (widget.allowSkip) const SizedBox(width: 12),
                      if (widget.allowSkip)
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(1),
                          child: TvFocusable(
                            animate: false,
                            subtleFocus: true,
                            borderRadius: BorderRadius.circular(12),
                            onTap: _isLoading ? null : () => _skip(context),
                            onBack: () => _skip(context),
                            child: TextButton(
                              onPressed: _isLoading ? null : () => _skip(context),
                              child: Text(
                                'Skip for now',
                                style: TextStyle(color: colors.textMuted),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Show the ROM folder setup dialog if the user hasn't completed setup.
/// Call this after navigating to HomeScreen.
Future<void> maybeShowRomFolderSetupDialog(BuildContext context) async {
  final settings = context.read<SettingsService>();
  final completed = await settings.hasCompletedRomFolderSetup();
  if (completed) return;

  if (!context.mounted) return;
  await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const RomFolderSetupDialog(allowSkip: true),
  );
}
