import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../utils/theme.dart';
import 'tv_focusable.dart';

/// A built-in file/folder browser for Android TV where no system file picker
/// is available.  Navigates the filesystem with D-pad and selects files/folders.
///
/// [mode] controls what can be selected:
///   - [TvBrowseMode.files]   → pick one or more files (filtered by [extensions])
///   - [TvBrowseMode.folder]  → pick a directory
class TvFileBrowser extends StatefulWidget {
  final TvBrowseMode mode;
  final Set<String> extensions; // e.g. {'.gba', '.gb', '.gbc'}
  final bool allowMultiple;

  const TvFileBrowser({
    super.key,
    this.mode = TvBrowseMode.files,
    this.extensions = const {},
    this.allowMultiple = true,
  });

  /// Show the browser as a full-screen dialog. Returns selected paths or null.
  static Future<List<String>?> pickFiles(
    BuildContext context, {
    Set<String> extensions = const {'.gba', '.gb', '.gbc', '.sgb'},
    bool allowMultiple = true,
  }) {
    return Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => TvFileBrowser(
          mode: TvBrowseMode.files,
          extensions: extensions,
          allowMultiple: allowMultiple,
        ),
      ),
    );
  }

  /// Show the browser in folder-pick mode. Returns selected directory or null.
  static Future<String?> pickDirectory(BuildContext context) async {
    final result = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => const TvFileBrowser(mode: TvBrowseMode.folder),
      ),
    );
    return result?.firstOrNull;
  }

  @override
  State<TvFileBrowser> createState() => _TvFileBrowserState();
}

enum TvBrowseMode { files, folder }

class _TvFileBrowserState extends State<TvFileBrowser> {
  late Directory _currentDir;
  List<FileSystemEntity> _entries = [];
  final Set<String> _selected = {};
  bool _loading = true;
  String? _error;

  // Common Android storage roots to start from
  static const _storageRoots = [
    '/storage/emulated/0',
    '/sdcard',
    '/storage',
    '/mnt',
  ];

  @override
  void initState() {
    super.initState();
    // Start at /storage/emulated/0 if it exists, else /storage
    final startPath = _storageRoots.firstWhere(
      (p) => Directory(p).existsSync(),
      orElse: () => '/',
    );
    _currentDir = Directory(startPath);
    _loadDirectory();
  }

  Future<void> _loadDirectory() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final entities = <FileSystemEntity>[];
      await for (final entity in _currentDir.list()) {
        // Skip hidden files/dirs
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;

        if (entity is Directory) {
          entities.add(entity);
        } else if (entity is File && widget.mode == TvBrowseMode.files) {
          // Filter by extension if provided
          if (widget.extensions.isEmpty ||
              widget.extensions.contains(p.extension(entity.path).toLowerCase())) {
            entities.add(entity);
          }
        }
      }

      // Sort: directories first, then alphabetical
      entities.sort((a, b) {
        final aIsDir = a is Directory;
        final bIsDir = b is Directory;
        if (aIsDir && !bIsDir) return -1;
        if (!aIsDir && bIsDir) return 1;
        return p.basename(a.path).toLowerCase().compareTo(
              p.basename(b.path).toLowerCase());
      });

      setState(() {
        _entries = entities;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _entries = [];
        _loading = false;
        _error = 'Cannot access this folder';
      });
    }
  }

  void _navigateTo(Directory dir) {
    _currentDir = dir;
    _loadDirectory();
  }

  void _goUp() {
    final parent = _currentDir.parent;
    if (parent.path != _currentDir.path) {
      _navigateTo(parent);
    }
  }

  void _onEntityTap(FileSystemEntity entity) {
    if (entity is Directory) {
      _navigateTo(entity);
    } else if (entity is File) {
      setState(() {
        if (_selected.contains(entity.path)) {
          _selected.remove(entity.path);
        } else {
          if (!widget.allowMultiple) _selected.clear();
          _selected.add(entity.path);
        }
      });
    }
  }

  void _confirmSelection() {
    if (widget.mode == TvBrowseMode.folder) {
      Navigator.of(context).pop([_currentDir.path]);
    } else if (_selected.isNotEmpty) {
      Navigator.of(context).pop(_selected.toList());
    }
  }

  @override
  Widget build(BuildContext context) {
    final dirName = _currentDir.path == '/'
        ? '/'
        : p.basename(_currentDir.path);

    return Scaffold(
      backgroundColor: YageColors.backgroundDark,
      appBar: AppBar(
        title: Text(
          widget.mode == TvBrowseMode.folder
              ? 'Select Folder'
              : 'Select ROMs',
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(null),
        ),
        actions: [
          if (widget.mode == TvBrowseMode.folder ||
              _selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TvFocusable(
                borderRadius: BorderRadius.circular(8),
                onTap: _confirmSelection,
                child: TextButton.icon(
                  onPressed: _confirmSelection,
                  icon: const Icon(Icons.check),
                  label: Text(
                    widget.mode == TvBrowseMode.folder
                        ? 'Select This Folder'
                        : 'Add ${_selected.length} ROM${_selected.length == 1 ? '' : 's'}',
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // Breadcrumb / current path
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: YageColors.backgroundMedium,
            child: Row(
              children: [
                Icon(Icons.folder_open, size: 18, color: YageColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _currentDir.path,
                    style: TextStyle(
                      fontSize: 13,
                      color: YageColors.textSecondary,
                      fontFamily: 'monospace',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_selected.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: YageColors.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${_selected.length} selected',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: YageColors.textPrimary,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Quick-nav: storage roots
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              children: [
                _QuickNavChip(
                  label: 'Internal',
                  path: '/storage/emulated/0',
                  isCurrent: _currentDir.path.startsWith('/storage/emulated/0'),
                  onTap: () => _navigateTo(Directory('/storage/emulated/0')),
                ),
                _QuickNavChip(
                  label: 'Downloads',
                  path: '/storage/emulated/0/Download',
                  isCurrent: _currentDir.path.startsWith('/storage/emulated/0/Download'),
                  onTap: () => _navigateTo(Directory('/storage/emulated/0/Download')),
                ),
                _QuickNavChip(
                  label: 'Storage',
                  path: '/storage',
                  isCurrent: _currentDir.path == '/storage',
                  onTap: () => _navigateTo(Directory('/storage')),
                ),
                _QuickNavChip(
                  label: 'USB / SD',
                  path: '/mnt',
                  isCurrent: _currentDir.path.startsWith('/mnt'),
                  onTap: () => _navigateTo(Directory('/mnt')),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // File list
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.lock, size: 48,
                                color: YageColors.textMuted),
                            const SizedBox(height: 12),
                            Text(_error!,
                                style: TextStyle(color: YageColors.textMuted)),
                          ],
                        ),
                      )
                    : FocusTraversalGroup(
                        child: ListView.builder(
                          padding: const EdgeInsets.only(bottom: 80),
                          itemCount: _entries.length + 1, // +1 for ".." parent
                          itemBuilder: (context, index) {
                            // First item: go up
                            if (index == 0) {
                              return TvFocusable(
                                autofocus: true,
                                borderRadius: BorderRadius.circular(0),
                                onTap: _goUp,
                                child: ListTile(
                                  leading: Icon(Icons.arrow_upward,
                                      color: YageColors.accent),
                                  title: Text(
                                    '.. (Parent folder)',
                                    style: TextStyle(
                                      color: YageColors.textSecondary,
                                    ),
                                  ),
                                  onTap: _goUp,
                                ),
                              );
                            }

                            final entity = _entries[index - 1];
                            final isDir = entity is Directory;
                            final name = p.basename(entity.path);
                            final isSelected = _selected.contains(entity.path);

                            return TvFocusable(
                              borderRadius: BorderRadius.circular(0),
                              onTap: () => _onEntityTap(entity),
                              child: ListTile(
                                leading: Icon(
                                  isDir
                                      ? Icons.folder
                                      : _romIcon(name),
                                  color: isDir
                                      ? YageColors.accent
                                      : isSelected
                                          ? YageColors.primary
                                          : YageColors.textMuted,
                                ),
                                title: Text(
                                  name,
                                  style: TextStyle(
                                    color: isSelected
                                        ? YageColors.primary
                                        : YageColors.textPrimary,
                                    fontWeight: isSelected
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                                subtitle: isDir
                                    ? null
                                    : Text(
                                        _formatSize(entity as File),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: YageColors.textMuted,
                                        ),
                                      ),
                                trailing: isDir
                                    ? Icon(Icons.chevron_right,
                                        color: YageColors.textMuted)
                                    : isSelected
                                        ? Icon(Icons.check_circle,
                                            color: YageColors.primary)
                                        : Icon(Icons.radio_button_unchecked,
                                            color: YageColors.surfaceLight),
                                onTap: () => _onEntityTap(entity),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  IconData _romIcon(String name) {
    final ext = p.extension(name).toLowerCase();
    return switch (ext) {
      '.gba' => Icons.videogame_asset,
      '.gbc' => Icons.gamepad,
      '.gb' => Icons.sports_esports,
      _ => Icons.insert_drive_file,
    };
  }

  String _formatSize(File file) {
    try {
      final bytes = file.lengthSync();
      if (bytes < 1024) return '$bytes B';
      if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } catch (_) {
      return '';
    }
  }
}

class _QuickNavChip extends StatelessWidget {
  final String label;
  final String path;
  final bool isCurrent;
  final VoidCallback onTap;

  const _QuickNavChip({
    required this.label,
    required this.path,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final exists = Directory(path).existsSync();
    if (!exists) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: TvFocusable(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: ActionChip(
          label: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent ? YageColors.backgroundDark : YageColors.textSecondary,
            ),
          ),
          backgroundColor: isCurrent ? YageColors.accent : YageColors.surface,
          side: BorderSide(
            color: isCurrent ? YageColors.accent : YageColors.surfaceLight,
          ),
          onPressed: onTap,
        ),
      ),
    );
  }
}
