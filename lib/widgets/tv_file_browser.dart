import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/theme.dart';
import 'tv_focusable.dart';

/// Count non-hidden items in a directory. Runs in isolate to avoid blocking UI.
int _countDirItemsIsolate(String dirPath) {
  try {
    return Directory(dirPath)
        .listSync()
        .where((e) => !p.basename(e.path).startsWith('.'))
        .length;
  } catch (_) {
    return 0;
  }
}

const _deviceChannel = MethodChannel('com.yourmateapps.retropal/device');

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
    Set<String> extensions = const {'.gba', '.gb', '.gbc', '.sgb', '.nes', '.sfc', '.smc', '.zip'},
    bool allowMultiple = true,
  }) async {
    final hasPermission = await _ensureStoragePermission();
    if (!hasPermission || !context.mounted) return null;
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
    final hasPermission = await _ensureStoragePermission();
    if (!hasPermission || !context.mounted) return null;
    final result = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => const TvFileBrowser(mode: TvBrowseMode.folder),
      ),
    );
    return result?.firstOrNull;
  }

  /// Check and request storage permission before opening the browser.
  /// Returns true if permission is granted.
  static Future<bool> _ensureStoragePermission() async {
    try {
      final hasPermission =
          await _deviceChannel.invokeMethod<bool>('hasStoragePermission') ?? false;
      if (hasPermission) return true;

      // Open system settings — fire-and-forget.
      // Don't await the method channel result because the activity may be
      // destroyed/recreated while in settings (low-memory TV), which would
      // crash with a stale callback.
      try {
        _deviceChannel.invokeMethod<bool>('requestStoragePermission');
      } catch (_) {}

      // Wait for the user to come back from settings by listening to
      // AppLifecycleState changes.
      final completer = Completer<void>();
      late final AppLifecycleListener listener;
      listener = AppLifecycleListener(
        onResume: () {
          if (!completer.isCompleted) completer.complete();
          listener.dispose();
        },
      );

      // Timeout after 2 minutes in case user never comes back
      await completer.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () {},
      );

      // Re-check permission after returning from settings
      final granted =
          await _deviceChannel.invokeMethod<bool>('hasStoragePermission') ?? false;
      return granted;
    } catch (_) {
      // Not on Android or channel unavailable — assume OK
      return true;
    }
  }

  @override
  State<TvFileBrowser> createState() => _TvFileBrowserState();
}

enum TvBrowseMode { files, folder }

class _TvFileBrowserState extends State<TvFileBrowser> {
  Directory? _currentDir;
  List<FileSystemEntity> _entries = [];
  final Set<String> _selected = {};
  bool _loading = true;
  String? _error;
  bool _permissionDenied = false;
  final _listKey = GlobalKey();

  /// Cached dir item counts (path → count). Populated via compute to avoid
  /// blocking UI with listSync on large directories.
  final Map<String, int> _dirCountCache = {};

  // Common Android storage roots to start from
  static const _storageRoots = [
    '/storage/emulated/0',
    '/sdcard',
    '/storage',
    '/mnt',
  ];

  /// Roots we cannot go above (so Back goes "exit" instead of "up").
  static const _rootPaths = {'/', '/storage', '/mnt'};

  static const _lastDirKey = 'tv_file_browser_last_dir';

  @override
  void initState() {
    super.initState();
    _initWithPermission();
  }

  Future<void> _initWithPermission() async {
    // Check if we already have storage permission
    bool hasPermission = true;
    try {
      hasPermission =
          await _deviceChannel.invokeMethod<bool>('hasStoragePermission') ??
              true;
    } catch (_) {
      // Not on Android or channel unavailable — assume permission is OK
    }

    if (!hasPermission) {
      // Try requesting it
      try {
        hasPermission =
            await _deviceChannel.invokeMethod<bool>('requestStoragePermission') ??
                false;
      } catch (_) {
        hasPermission = false;
      }
    }

    if (!mounted) return;

    if (!hasPermission) {
      setState(() {
        _loading = false;
        _permissionDenied = true;
      });
      return;
    }

    // Restore the last browsed directory if it still exists
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final lastDir = prefs.getString(_lastDirKey);
    if (lastDir != null && Directory(lastDir).existsSync()) {
      _currentDir = Directory(lastDir);
    } else {
      final startPath = _storageRoots.firstWhere(
        (p) => Directory(p).existsSync(),
        orElse: () => '/',
      );
      _currentDir = Directory(startPath);
    }
    _loadDirectory();
  }

  /// Re-check permission (e.g. after the user granted it in Settings).
  Future<void> _retryPermission() async {
    setState(() {
      _loading = true;
      _permissionDenied = false;
    });
    await _initWithPermission();
  }

  // ───────────────────────── directory loading ─────────────────────────

  Future<void> _loadDirectory() async {
    setState(() {
      _loading = true;
      _error = null;
      _dirCountCache.clear();
    });

    try {
      final entities = <FileSystemEntity>[];
      final currentDir = _currentDir;
      if (currentDir != null) {
        await for (final entity in currentDir.list()) {
          final name = p.basename(entity.path);
          if (name.startsWith('.')) continue;

          if (entity is Directory) {
            entities.add(entity);
          } else if (entity is File && widget.mode == TvBrowseMode.files) {
            if (widget.extensions.isEmpty ||
                widget.extensions.contains(p.extension(entity.path).toLowerCase())) {
              entities.add(entity);
            }
          }
        }
      }

      entities.sort((a, b) {
        final aIsDir = a is Directory;
        final bIsDir = b is Directory;
        if (aIsDir && !bIsDir) return -1;
        if (!aIsDir && bIsDir) return 1;
        return p.basename(a.path)
            .toLowerCase()
            .compareTo(p.basename(b.path).toLowerCase());
      });

      // Compute dir item counts in background isolate to avoid ANR on
      // directories with thousands of files.
      final dirs = entities.whereType<Directory>().toList();
      if (dirs.isNotEmpty) {
        final counts = await Future.wait(
          dirs.map((d) => compute(_countDirItemsIsolate, d.path)),
        );
        if (!mounted) return;
        final cache = <String, int>{};
        for (var i = 0; i < dirs.length; i++) {
          cache[dirs[i].path] = counts[i];
        }
        if (!mounted) return;
        setState(() {
          _entries = entities;
          _dirCountCache.addAll(cache);
          _loading = false;
        });
      } else {
        if (!mounted) return;
        setState(() {
          _entries = entities;
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _entries = [];
        _loading = false;
        _error = 'Cannot access this folder';
      });
    }
  }

  // ───────────────────────── navigation ─────────────────────────

  void _navigateTo(Directory dir) {
    _selected.clear();
    _currentDir = dir;
    _loadDirectory();
    // Remember the last browsed directory for next session
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString(_lastDirKey, dir.path);
    });
  }

  bool get _isAtRoot =>
      _currentDir == null ||
      _rootPaths.contains(_currentDir!.path) ||
      _currentDir!.parent.path == _currentDir!.path;

  void _goUp() {
    if (_isAtRoot || _currentDir == null) return;
    _navigateTo(_currentDir!.parent);
  }

  /// B / Back handler: go up if possible, otherwise exit the browser.
  void _goBackOrExit() {
    if (_isAtRoot) {
      Navigator.of(context).pop(null);
    } else {
      _goUp();
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
    if (widget.mode == TvBrowseMode.folder && _currentDir != null) {
      Navigator.of(context).pop([_currentDir!.path]);
    } else if (_selected.isNotEmpty) {
      Navigator.of(context).pop(_selected.toList());
    }
  }

  void _selectAll() {
    setState(() {
      final files =
          _entries.whereType<File>().map((f) => f.path).toSet();
      if (_selected.containsAll(files)) {
        _selected.removeAll(files);
      } else {
        _selected.addAll(files);
      }
    });
  }

  // ───────────────────────── global key handler ─────────────────────────

  /// Handles gamepad Start → confirm, B → go up / exit at screen level.
  KeyEventResult _onKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

    // Gamepad Start / Enter → confirm selection
    if (key == LogicalKeyboardKey.gameButtonStart) {
      _confirmSelection();
      return KeyEventResult.handled;
    }

    // B / Back / Escape → go up or exit
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      _goBackOrExit();
      return KeyEventResult.handled;
    }

    // L1 → select all (file mode, multi-select)
    if (widget.mode == TvBrowseMode.files &&
        widget.allowMultiple &&
        key == LogicalKeyboardKey.gameButtonLeft1) {
      _selectAll();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // ───────────────────────── helpers ─────────────────────────

  int get _fileCount => _entries.whereType<File>().length;
  int get _dirCount => _entries.whereType<Directory>().length;

  /// Counts immediate children inside [dir] (non-hidden).
  /// Uses pre-computed cache from _loadDirectory (via compute) to avoid
  /// blocking UI with listSync on large directories.
  String _dirItemCount(Directory dir) {
    final count = _dirCountCache[dir.path];
    if (count == null) return '';
    return '$count item${count == 1 ? '' : 's'}';
  }

  List<_BreadcrumbSegment> get _breadcrumbs {
    if (_currentDir == null) return [];
    final parts = _currentDir!.path.split('/').where((s) => s.isNotEmpty).toList();
    final segments = <_BreadcrumbSegment>[];
    segments.add(_BreadcrumbSegment(label: '/', path: '/'));
    var running = '';
    for (final part in parts) {
      running += '/$part';
      segments.add(_BreadcrumbSegment(label: part, path: running));
    }
    return segments;
  }

  // ───────────────────────── build ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final canConfirm = widget.mode == TvBrowseMode.folder || _selected.isNotEmpty;

    return Focus(
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
        backgroundColor: colors.backgroundDark,
        appBar: AppBar(
          backgroundColor: colors.backgroundMedium,
          automaticallyImplyLeading: false,
          title: Text(
            widget.mode == TvBrowseMode.folder ? 'Select Folder' : 'Select ROMs',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
        body: Column(
          children: [
            // ── Interactive breadcrumb bar ──
            _buildBreadcrumbBar(),

            // ── Quick-nav chips ──
            _buildQuickNavRow(),

            const Divider(height: 1),

            // ── Status bar: file/folder counts & select-all ──
            if (!_loading && _error == null) _buildStatusBar(),

            // ── File list ──
            Expanded(child: _buildBody()),

            // ── Action bar: confirm + cancel (in same focus group as list) ──
            _buildActionBar(canConfirm),

            // ── Gamepad hint bar ──
            _buildHintBar(),
          ],
        ),
      ),
    );
  }

  // ─────────────── gamepad hint bar ───────────────

  Widget _buildHintBar() {
    final colors = AppColorTheme.of(context);
    final showSelectAll = widget.mode == TvBrowseMode.files && widget.allowMultiple;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      decoration: BoxDecoration(
        color: colors.backgroundMedium,
        border: Border(
          top: BorderSide(color: colors.surfaceLight, width: 0.5),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _hintChip(colors, 'A', 'Select'),
          _hintDot(colors),
          _hintChip(colors, 'B', 'Back'),
          _hintDot(colors),
          _hintChip(colors, 'Start', 'Confirm'),
          if (showSelectAll) ...[
            _hintDot(colors),
            _hintChip(colors, 'L1', 'Select All'),
          ],
        ],
      ),
    );
  }

  Widget _hintChip(AppColorTheme colors, String key, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: colors.surfaceLight),
          ),
          child: Text(
            key,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
              color: colors.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: colors.textMuted,
          ),
        ),
      ],
    );
  }

  Widget _hintDot(AppColorTheme colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Text(
        '·',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: colors.textMuted,
        ),
      ),
    );
  }

  // ─────────────── action bar (bottom, TV-traversable) ───────────────

  Widget _buildActionBar(bool canConfirm) {
    final colors = AppColorTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: colors.backgroundMedium,
        border: Border(
          top: BorderSide(color: colors.surfaceLight, width: 0.5),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TvFocusable(
            borderRadius: BorderRadius.circular(8),
            onTap: () => Navigator.of(context).pop(null),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.surfaceLight),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.close, size: 18, color: colors.textSecondary),
                  const SizedBox(width: 8),
                  Text('Cancel', style: TextStyle(color: colors.textSecondary, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
          if (canConfirm) ...[
            const SizedBox(width: 12),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _confirmSelection,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check, size: 18, color: colors.textPrimary),
                    const SizedBox(width: 8),
                    Text(
                      widget.mode == TvBrowseMode.folder
                          ? 'Select Folder'
                          : 'Add ${_selected.length} ROM${_selected.length == 1 ? '' : 's'}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: colors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─────────────── breadcrumb bar ───────────────

  Widget _buildBreadcrumbBar() {
    final colors = AppColorTheme.of(context);
    final segments = _breadcrumbs;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: colors.backgroundMedium.withAlpha(160),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true, // keep the rightmost (current) segment visible
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < segments.length; i++) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Icon(Icons.chevron_right,
                      size: 16, color: colors.textMuted),
                ),
              TvFocusable(
                borderRadius: BorderRadius.circular(6),
                onTap: () => _navigateTo(Directory(segments[i].path)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _navigateTo(Directory(segments[i].path)),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Text(
                      segments[i].label,
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        color: i == segments.length - 1
                            ? colors.accent
                            : colors.textSecondary,
                        fontWeight: i == segments.length - 1
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ─────────────── quick nav row ───────────────

  Widget _buildQuickNavRow() {
    final path = _currentDir?.path ?? '';
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          _QuickNavChip(
            icon: Icons.phone_android,
            label: 'Internal',
            path: '/storage/emulated/0',
            isCurrent: path.startsWith('/storage/emulated/0'),
            onTap: () => _navigateTo(Directory('/storage/emulated/0')),
          ),
          _QuickNavChip(
            icon: Icons.download,
            label: 'Downloads',
            path: '/storage/emulated/0/Download',
            isCurrent: path.startsWith('/storage/emulated/0/Download'),
            onTap: () =>
                _navigateTo(Directory('/storage/emulated/0/Download')),
          ),
          _QuickNavChip(
            icon: Icons.storage,
            label: 'Storage',
            path: '/storage',
            isCurrent: path == '/storage',
            onTap: () => _navigateTo(Directory('/storage')),
          ),
          _QuickNavChip(
            icon: Icons.usb,
            label: 'USB / SD',
            path: '/mnt',
            isCurrent: path.startsWith('/mnt'),
            onTap: () => _navigateTo(Directory('/mnt')),
          ),
        ],
      ),
    );
  }

  // ─────────────── status bar (counts + select all) ───────────────

  Widget _buildStatusBar() {
    final colors = AppColorTheme.of(context);
    final showSelectAll =
        widget.mode == TvBrowseMode.files && widget.allowMultiple && _fileCount > 0;
    final allSelected = showSelectAll &&
        _entries.whereType<File>().every((f) => _selected.contains(f.path));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: colors.surface.withAlpha(80),
      child: Row(
        children: [
          Icon(Icons.folder, size: 14, color: colors.textMuted),
          const SizedBox(width: 4),
          Text(
            '$_dirCount folder${_dirCount == 1 ? '' : 's'}',
            style: TextStyle(fontSize: 11, color: colors.textMuted),
          ),
          if (_fileCount > 0) ...[
            const SizedBox(width: 12),
            Icon(Icons.insert_drive_file, size: 14, color: colors.textMuted),
            const SizedBox(width: 4),
            Text(
              '$_fileCount file${_fileCount == 1 ? '' : 's'}',
              style: TextStyle(fontSize: 11, color: colors.textMuted),
            ),
          ],
          if (_selected.isNotEmpty) ...[
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: colors.primary.withAlpha(50),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colors.primary.withAlpha(100)),
              ),
              child: Text(
                '${_selected.length} selected',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: colors.primary,
                ),
              ),
            ),
          ],
          const Spacer(),
          if (showSelectAll)
            TvFocusable(
              borderRadius: BorderRadius.circular(6),
              onTap: _selectAll,
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: _selectAll,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        allSelected
                            ? Icons.deselect
                            : Icons.select_all,
                        size: 14,
                        color: colors.accent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        allSelected ? 'Deselect all' : 'Select all',
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.accent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─────────────── main body (list / loading / error / empty) ───────────────

  Widget _buildBody() {
    final colors = AppColorTheme.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_permissionDenied) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_off, size: 64,
                  color: colors.textMuted.withAlpha(100)),
              const SizedBox(height: 16),
              Text(
                'File Browsing Unavailable',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'On newer Android versions, file browsing is not available.\n\n'
                'Use the "Add ROMs" or "Add Folder" buttons on the home '
                'screen to import your game files using the system file picker.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: colors.textSecondary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TvFocusable(
                    autofocus: true,
                    borderRadius: BorderRadius.circular(12),
                    onTap: _retryPermission,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.primary,
                        foregroundColor: colors.textPrimary,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 14),
                      ),
                      onPressed: _retryPermission,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Retry'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  TvFocusable(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.of(context).pop(null),
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(null),
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock, size: 48, color: colors.textMuted),
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: colors.textMuted)),
            const SizedBox(height: 16),
            TvFocusable(
              autofocus: true,
              borderRadius: BorderRadius.circular(8),
              onTap: _goBackOrExit,
              child: OutlinedButton.icon(
                onPressed: _goBackOrExit,
                icon: const Icon(Icons.arrow_back, size: 16),
                label: const Text('Go back'),
              ),
            ),
          ],
        ),
      );
    }

    if (_entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open, size: 56, color: colors.textMuted.withAlpha(80)),
            const SizedBox(height: 12),
            Text(
              widget.mode == TvBrowseMode.files
                  ? 'No ROM files found here'
                  : 'This folder is empty',
              style: TextStyle(
                fontSize: 15,
                color: colors.textMuted,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Press Back to go up',
              style: TextStyle(fontSize: 12, color: colors.textMuted.withAlpha(120)),
            ),
            const SizedBox(height: 16),
            TvFocusable(
              autofocus: true,
              borderRadius: BorderRadius.circular(8),
              onTap: _goBackOrExit,
              onBack: _goBackOrExit,
              child: OutlinedButton.icon(
                onPressed: _goBackOrExit,
                icon: const Icon(Icons.arrow_back, size: 16),
                label: const Text('Go back'),
              ),
            ),
          ],
        ),
      );
    }

    // File/folder list
    return FocusTraversalGroup(
      child: ListView.builder(
        key: _listKey,
        padding: const EdgeInsets.only(bottom: 80),
        itemCount: _entries.length + (_isAtRoot ? 0 : 1),
        itemBuilder: (context, index) {
          // First item: ".." parent (only when not at root)
          if (!_isAtRoot && index == 0) {
            return TvFocusable(
              autofocus: true,
              borderRadius: BorderRadius.circular(0),
              onTap: _goUp,
              onBack: _goBackOrExit,
              child: ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colors.accent.withAlpha(30),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.arrow_upward,
                      color: colors.accent, size: 20),
                ),
                title: Text(
                  '.. (Parent folder)',
                  style: TextStyle(color: colors.textSecondary),
                ),
                onTap: _goUp,
              ),
            );
          }

          final entityIndex = _isAtRoot ? index : index - 1;
          final entity = _entries[entityIndex];
          final isDir = entity is Directory;
          final name = p.basename(entity.path);
          final isSelected = _selected.contains(entity.path);

          return TvFocusable(
            autofocus: _isAtRoot && index == 0,
            borderRadius: BorderRadius.circular(0),
            onTap: () => _onEntityTap(entity),
            onBack: _goBackOrExit,
            child: _FileListTile(
              name: name,
              isDir: isDir,
              isSelected: isSelected,
              subtitle: _entitySubtitle(entity),
              icon: isDir ? Icons.folder : _romIcon(name),
              onTap: () => _onEntityTap(entity),
            ),
          );
        },
      ),
    );
  }

  String _entitySubtitle(FileSystemEntity entity) {
    final parts = <String>[];
    if (entity is Directory) {
      parts.add(_dirItemCount(entity));
    } else if (entity is File) {
      parts.add(_formatSize(entity));
    }
    final dateStr = _formatModified(entity);
    if (dateStr.isNotEmpty) parts.add(dateStr);
    return parts.where((s) => s.isNotEmpty).join(' · ');
  }

  String _formatModified(FileSystemEntity entity) {
    try {
      final modified = entity.statSync().modified;
      final now = DateTime.now();
      final diff = now.difference(modified);

      if (diff.inMinutes < 1) return 'just now';
      if (diff.inHours < 1) return '${diff.inMinutes}m ago';
      if (diff.inDays < 1) return '${diff.inHours}h ago';
      if (diff.inDays < 7) return '${diff.inDays}d ago';

      return '${modified.year}-${modified.month.toString().padLeft(2, '0')}-${modified.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  IconData _romIcon(String name) {
    final ext = p.extension(name).toLowerCase();
    return switch (ext) {
      '.gba' => Icons.videogame_asset,
      '.gbc' => Icons.gamepad,
      '.gb' => Icons.sports_esports,
      '.nes' => Icons.tv,
      '.sfc' || '.smc' => Icons.games,
      _ => Icons.insert_drive_file,
    };
  }

  String _formatSize(File file) {
    try {
      final bytes = file.lengthSync();
      if (bytes < 1024) return '$bytes B';
      if (bytes < 1024 * 1024) {
        return '${(bytes / 1024).toStringAsFixed(1)} KB';
      }
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } catch (_) {
      return '';
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  List tile for files / directories
// ═══════════════════════════════════════════════════════════════════════

class _FileListTile extends StatelessWidget {
  final String name;
  final bool isDir;
  final bool isSelected;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  const _FileListTile({
    required this.name,
    required this.isDir,
    required this.isSelected,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      color: isSelected ? colors.primary.withAlpha(25) : Colors.transparent,
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isDir
                ? colors.accent.withAlpha(30)
                : isSelected
                    ? colors.primary.withAlpha(40)
                    : colors.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 20,
            color: isDir
                ? colors.accent
                : isSelected
                    ? colors.primary
                    : colors.textMuted,
          ),
        ),
        title: Text(
          name,
          style: TextStyle(
            color: isSelected ? colors.primary : colors.textPrimary,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: subtitle.isNotEmpty
            ? Text(
                subtitle,
                style: TextStyle(fontSize: 12, color: colors.textMuted),
              )
            : null,
        trailing: isDir
            ? Icon(Icons.chevron_right, color: colors.textMuted)
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: isSelected
                    ? Icon(Icons.check_circle,
                        key: const ValueKey('checked'),
                        color: colors.primary)
                    : Icon(Icons.radio_button_unchecked,
                        key: const ValueKey('unchecked'),
                        color: colors.surfaceLight),
              ),
        onTap: onTap,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Quick-nav chip
// ═══════════════════════════════════════════════════════════════════════

class _QuickNavChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String path;
  final bool isCurrent;
  final VoidCallback onTap;

  const _QuickNavChip({
    required this.icon,
    required this.label,
    required this.path,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final exists = Directory(path).existsSync();
    if (!exists) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: TvFocusable(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: ActionChip(
          avatar: Icon(
            icon,
            size: 16,
            color: isCurrent ? colors.backgroundDark : colors.textMuted,
          ),
          label: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent
                  ? colors.backgroundDark
                  : colors.textSecondary,
            ),
          ),
          backgroundColor:
              isCurrent ? colors.accent : colors.surface,
          side: BorderSide(
            color: isCurrent ? colors.accent : colors.surfaceLight,
          ),
          onPressed: onTap,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Breadcrumb segment model
// ═══════════════════════════════════════════════════════════════════════

class _BreadcrumbSegment {
  final String label;
  final String path;
  const _BreadcrumbSegment({required this.label, required this.path});
}
