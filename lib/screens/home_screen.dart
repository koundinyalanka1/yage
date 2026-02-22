import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';

import '../core/mgba_bindings.dart';
import '../models/game_rom.dart';
import '../services/cover_art_service.dart';
import '../services/game_library_service.dart';
import '../services/emulator_service.dart';
import '../services/retro_achievements_service.dart';

import '../services/save_backup_service.dart';
import '../utils/tv_detector.dart';
import '../widgets/banner_ad_widget.dart';
import '../widgets/game_card.dart';
import '../widgets/platform_filter.dart';
import '../widgets/tv_file_browser.dart';
import '../widgets/tv_focusable.dart';
import '../services/settings_service.dart';
import '../utils/theme.dart';
import 'achievements_screen.dart';
import 'game_screen.dart';
import 'settings_screen.dart';

/// Sort options for the game library
enum GameSortOption {
  nameAsc('Name (A-Z)', Icons.sort_by_alpha),
  nameDesc('Name (Z-A)', Icons.sort_by_alpha),
  lastPlayed('Last Played', Icons.history),
  mostPlayed('Most Played', Icons.timer),
  platform('Platform', Icons.devices),
  sizeAsc('Size (Small)', Icons.straighten),
  sizeDesc('Size (Large)', Icons.straighten);

  final String label;
  final IconData icon;
  const GameSortOption(this.label, this.icon);
}

/// Main home screen with game library
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _deviceChannel = MethodChannel('com.yourmateapps.retropal/device');
  
  late TabController _tabController;
  GamePlatform? _selectedPlatform;
  String _searchQuery = '';
  late bool _isGridView;
  late GameSortOption _sortOption;
  final _searchController = TextEditingController();
  Timer? _searchDebounce;

  /// Index of the last focused game card so we can restore focus after
  /// navigating away (settings, game screen) and coming back.
  int _lastFocusedGameIndex = 0;

  /// Tab index when the last game card was focused. Restore only when
  /// we're on the same tab (All=0, Recent=1, Favorites=2).
  int _lastFocusedTabIndex = 0;

  /// Whether we should restore focus to [_lastFocusedGameIndex] on the
  /// next build (set to true after returning from a pushed route).
  bool _shouldRestoreFocus = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addObserver(this);

    // Restore persisted view preferences
    final settings = context.read<SettingsService>().settings;
    _isGridView = settings.isGridView;
    _sortOption = GameSortOption.values.firstWhere(
      (o) => o.name == settings.sortOption,
      orElse: () => GameSortOption.nameAsc,
    );

    // Check if the app was opened via a file intent
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkIncomingFile());
  }

  final FocusNode _keyFocusNode = FocusNode();
  /// Focus node for the game list area so we can programmatically refocus it.
  final FocusNode _gameListFocusNode = FocusNode();

  /// Debounced search update — waits 300ms after the last keystroke.
  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _searchQuery = value);
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    _searchController.dispose();
    _keyFocusNode.dispose();
    _gameListFocusNode.dispose();
    super.dispose();
  }

  /// Gamepad L1 / R1 bumpers switch tabs, B / Back refocuses game list.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

    // L1 / PageUp → previous tab
    if (key == LogicalKeyboardKey.gameButtonLeft1 ||
        key == LogicalKeyboardKey.pageUp) {
      final newIndex = (_tabController.index - 1).clamp(0, _tabController.length - 1);
      if (newIndex != _tabController.index) {
        _tabController.animateTo(newIndex);
      }
      return KeyEventResult.handled;
    }
    // R1 / PageDown → next tab
    if (key == LogicalKeyboardKey.gameButtonRight1 ||
        key == LogicalKeyboardKey.pageDown) {
      final newIndex = (_tabController.index + 1).clamp(0, _tabController.length - 1);
      if (newIndex != _tabController.index) {
        _tabController.animateTo(newIndex);
      }
      return KeyEventResult.handled;
    }
    // B / Back / Escape → refocus the game list (escape the FAB / tabs)
    if (key == LogicalKeyboardKey.gameButtonB ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      // If focus is NOT inside the game list, push it back there
      if (!_gameListFocusNode.hasFocus && !_gameListFocusNode.hasPrimaryFocus) {
        _gameListFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Check again when app is resumed (e.g. user opened another file while app was in background)
    if (state == AppLifecycleState.resumed) {
      _checkIncomingFile();
    }
  }

  /// Check if the app was opened via a VIEW intent with a ROM file path.
  /// If so, add it to the library and launch it immediately.
  /// Also handles ZIP files by extracting ROMs and importing them.
  Future<void> _checkIncomingFile() async {
    try {
      final path = await _deviceChannel.invokeMethod<String>('getOpenFilePath');
      if (path == null || path.isEmpty || !mounted) return;

      final library = context.read<GameLibraryService>();

      // ── Handle ZIP files: extract ROMs and import ──
      if (path.toLowerCase().endsWith('.zip')) {
        final games = await library.importRomZip(path);
        if (!mounted) return;

        if (games.isNotEmpty) {
          // Auto-download cover art for newly imported ROMs
          _autoFetchCovers(games, library);

          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  'Imported ${games.length} ROM${games.length == 1 ? '' : 's'} from ZIP',
                ),
                duration: const Duration(seconds: 2),
              ),
            );

          // Launch the first game if only one was imported
          if (games.length == 1) {
            _launchGame(games.first);
          }
        } else {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              const SnackBar(
                content: Text('No valid ROM files (.gb, .gbc, .gba, .nes, .sfc, .smc) found inside the ZIP.'),
              ),
            );
        }
        return;
      }

      // ── Handle individual ROM files ──
      final game = GameRom.fromPath(path);
      if (game == null) {
        if (mounted) {
          ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
            SnackBar(content: Text('Unsupported file: $path')),
          );
        }
        return;
      }

      // Add to library if not already there
      await library.addRom(path);

      // Find the game entry (addRom might return null if it already exists)
      final libraryGame = library.games.firstWhere(
        (g) => g.path == path,
        orElse: () => game,
      );

      if (mounted) {
        _launchGame(libraryGame);
      }
    } catch (_) {
      // Channel not available (non-Android) — ignore
    }
  }

  /// Sort a list of games according to the current sort option
  List<GameRom> _sortGames(List<GameRom> games) {
    final sorted = List<GameRom>.from(games);
    switch (_sortOption) {
      case GameSortOption.nameAsc:
        sorted.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case GameSortOption.nameDesc:
        sorted.sort((a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()));
      case GameSortOption.lastPlayed:
        sorted.sort((a, b) {
          // Games never played go to the bottom
          if (a.lastPlayed == null && b.lastPlayed == null) return 0;
          if (a.lastPlayed == null) return 1;
          if (b.lastPlayed == null) return -1;
          return b.lastPlayed!.compareTo(a.lastPlayed!); // most recent first
        });
      case GameSortOption.mostPlayed:
        sorted.sort((a, b) => b.totalPlayTimeSeconds.compareTo(a.totalPlayTimeSeconds));
      case GameSortOption.platform:
        sorted.sort((a, b) {
          final cmp = a.platformShortName.compareTo(b.platformShortName);
          return cmp != 0 ? cmp : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
      case GameSortOption.sizeAsc:
        sorted.sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));
      case GameSortOption.sizeDesc:
        sorted.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
    }
    return sorted;
  }

  /// Show a D-pad / TV-friendly sort dialog instead of PopupMenuButton.
  void _showSortDialog() {
    final colors = AppColorTheme.of(context);
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: colors.primary.withAlpha(77),
              width: 2,
            ),
          ),
          title: Row(
            children: [
              Icon(Icons.swap_vert, color: colors.accent, size: 22),
              const SizedBox(width: 10),
              Text(
                'Sort by',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ],
          ),
          contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          content: SizedBox(
            width: 300,
            child: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: GameSortOption.values.asMap().entries.map((entry) {
                    final index = entry.key;
                    final opt = entry.value;
                    final isSelected = _sortOption == opt;
                    return TvFocusable(
                      autofocus: isSelected || (index == 0 && !GameSortOption.values.contains(_sortOption)),
                      onTap: () {
                        setState(() => _sortOption = opt);
                        context.read<SettingsService>().setSortOption(opt.name);
                        Navigator.pop(dialogContext);
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: ListTile(
                        leading: Icon(
                          opt.icon,
                          size: 20,
                          color: isSelected ? colors.accent : null,
                        ),
                        title: Text(
                          opt.label,
                          style: TextStyle(
                            color: isSelected ? colors.accent : null,
                            fontWeight: isSelected ? FontWeight.bold : null,
                          ),
                        ),
                        trailing: isSelected
                            ? Icon(Icons.check, size: 18, color: colors.accent)
                            : null,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                        dense: true,
                        onTap: () {
                          setState(() => _sortOption = opt);
                          context.read<SettingsService>().setSortOption(opt.name);
                          Navigator.pop(dialogContext);
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(
                'Cancel',
                style: TextStyle(color: colors.textMuted),
              ),
            ),
          ],
        );
      },
    ).then((_) {
      // Restore focus to the game list on TV after dialog dismissal
      if (mounted) _gameListFocusNode.requestFocus();
    });
  }

  Future<void> _addRomFile() async {
    List<String>? paths;

    // Try system file picker (SAF) — works on both phone and TV.
    // We use FileType.any because Android SAF requires MIME types and
    // .gba/.gb/.gbc have no registered MIME type — FileType.custom would
    // silently drop them, leaving only .zip.  We filter results ourselves.
    //
    // NOTE: We check the original filename (f.name) instead of the cached
    // path (f.path) because on some Android devices the SAF file picker
    // caches files under a temporary name without the original extension.
    const _allowedExtensions = {'.gba', '.gb', '.gbc', '.sgb', '.nes', '.sfc', '.smc', '.zip'};
    // Track which cached paths are actually ZIPs (by original name), because
    // the cached file path may not preserve the original extension on some
    // Android devices.
    final zipPaths = <String>{};
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
      );
      if (result != null) {
        for (final f in result.files) {
          if (f.path == null) continue;
          // Use the original filename (always has extension) for matching
          final name = f.name.toLowerCase();
          final dot = name.lastIndexOf('.');
          if (dot == -1) continue;
          final ext = name.substring(dot);
          if (!_allowedExtensions.contains(ext)) continue;
          paths ??= [];
          paths!.add(f.path!);
          if (ext == '.zip') zipPaths.add(f.path!);
        }
      }
    } catch (_) {
      paths = null;
    }
    if (!mounted) return;

    // On TV, fall back to built-in browser if system picker returned nothing
    if ((paths == null || paths.isEmpty) && TvDetector.isTV) {
      paths = await TvFileBrowser.pickFiles(context);
      if (!mounted) return;
      // TV file browser returns direct filesystem paths — extension is reliable
      if (paths != null) {
        for (final p in paths) {
          if (p.toLowerCase().endsWith('.zip')) zipPaths.add(p);
        }
      }
    }

    if (paths != null && paths.isNotEmpty && mounted) {
      final library = context.read<GameLibraryService>();
      final addedGames = <GameRom>[];

      // Show a loading indicator while files are being copied.
      final navigator = Navigator.of(context);
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(
                  child: Text(
                    'Importing ${paths!.length} file${paths.length == 1 ? '' : 's'}…',
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      for (final path in paths) {
        if (!mounted) break;
        if (zipPaths.contains(path)) {
          // Extract ROM files from ZIP and import each one
          final games = await library.importRomZip(path);
          addedGames.addAll(games);
        } else {
          final game = await library.importRom(path);
          if (game != null) addedGames.add(game);
        }
      }

      // Dismiss loading dialog
      if (mounted && navigator.mounted) navigator.pop();

      if (addedGames.isNotEmpty && mounted) {
        _tabController.animateTo(0);

        // Auto-download cover art for newly imported ROMs (fire-and-forget).
        _autoFetchCovers(addedGames, library);
      } else if (mounted) {
        // Let the user know when nothing was imported (e.g. ZIP with no ROMs)
        final hasZip = paths.any((p) => p.toLowerCase().endsWith('.zip'));
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(
                hasZip
                    ? 'No valid ROM files (.gb, .gbc, .gba, .nes, .sfc, .smc) found inside the ZIP.'
                    : 'No valid ROM files were imported.',
              ),
            ),
          );
      }
    }
  }
  

  Future<void> _addRomFolder() async {
    final library = context.read<GameLibraryService>();
    List<String>? importedPaths;

    // Use native SAF folder picker → scan → copy ROMs to internal storage
    try {
      final result = await _deviceChannel.invokeMethod<List<dynamic>>('importRomsFromFolder');
      importedPaths = result?.cast<String>();
    } catch (_) {
      importedPaths = null;
    }
    if (!mounted) return;

    // On TV, fall back to built-in folder browser if SAF unavailable
    if (importedPaths == null && TvDetector.isTV && mounted) {
      final dirPath = await TvFileBrowser.pickDirectory(context);
      if (!mounted) return;
      if (dirPath != null) {
        await library.addRomDirectory(dirPath);
        if (mounted) _tabController.animateTo(0);
        return;
      }
    }

    if (importedPaths != null && importedPaths.isNotEmpty && mounted) {
      final navigator = Navigator.of(context);
      final messenger = ScaffoldMessenger.of(context);

      // Show a loading indicator while files are being registered.
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(
                  child: Text(
                    'Importing ${importedPaths!.length} ROM${importedPaths.length == 1 ? '' : 's'}…',
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final addedGames = <GameRom>[];
      for (final path in importedPaths) {
        if (!mounted) break;
        final game = await library.addRom(path);
        if (game != null) addedGames.add(game);
      }

      // Dismiss loading dialog
      if (mounted && navigator.mounted) navigator.pop();

      if (addedGames.isNotEmpty && mounted) {
        _tabController.animateTo(0);
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text('Imported ${addedGames.length} ROM${addedGames.length == 1 ? '' : 's'}'),
              duration: const Duration(seconds: 2),
            ),
          );
      } else if (mounted) {
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            const SnackBar(
              content: Text('No new ROM files found in selected folder'),
              duration: Duration(seconds: 2),
            ),
          );
      }
    } else if (importedPaths != null && importedPaths!.isEmpty && mounted) {
      // User selected folder via SAF but it was empty
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('No ROM files found in selected folder'),
            duration: Duration(seconds: 2),
          ),
        );
    }
    // When importedPaths == null: user cancelled SAF picker — no message
  }

  /// Navigate to settings and restore game list focus on return.
  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    ).then((_) {
      if (mounted) setState(() => _shouldRestoreFocus = true);
    });
  }

  void _launchGame(GameRom game) async {
    final emulator = context.read<EmulatorService>();
    final library = context.read<GameLibraryService>();
    final settings = context.read<SettingsService>().settings;
    final raService = context.read<RetroAchievementsService>();

    // Update last played
    await library.updateLastPlayed(game);

    // Start RA achievement session in parallel with ROM loading.
    // This kicks off hash computation + game ID lookup + achievement data
    // fetch so they're already in progress (or cached) by the time the
    // game screen's _detectRetroAchievements() runs.
    if (settings.raEnabled && raService.isLoggedIn) {
      // Fire-and-forget — don't block ROM loading
      raService.startGameSession(game);
    }

    // Load ROM
    final success = await emulator.loadRom(game);
    
    if (success && mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => GameScreen(game: game),
        ),
      ).then((_) {
        if (mounted) setState(() => _shouldRestoreFocus = true);
      });
    } else if (mounted) {
      ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
        SnackBar(
          content: Text('Failed to load ${game.name}'),
          backgroundColor: AppColorTheme.of(context).error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    
    return Focus(
      focusNode: _keyFocusNode,
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
      body: SafeArea(
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: Column(
            children: [
              // In landscape, combine header elements into a single row
              if (isLandscape)
                FocusTraversalOrder(
                  order: const NumericFocusOrder(0),
                  child: _buildCompactHeader(),
                )
              else ...[
                FocusTraversalOrder(
                  order: const NumericFocusOrder(0),
                  child: _buildHeader(),
                ),
                _buildSearchBar(),
                _buildPlatformFilter(),
              ],
              FocusTraversalOrder(
                order: const NumericFocusOrder(1),
                child: _buildTabBar(),
              ),
              Expanded(
                child: FocusTraversalOrder(
                  order: const NumericFocusOrder(2),
                  child: Focus(
                    focusNode: _gameListFocusNode,
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _buildAllGames(),
                        _buildRecentGames(),
                        _buildFavorites(),
                      ],
                    ),
                  ),
                ),
              ),
              // TV bumper hint bar
              if (TvDetector.isTV)
                _buildTvHintBar(),
              // Banner ad at bottom (mobile only, not during gameplay)
              const BannerAdWidget(),
            ],
          ),
        ),
      ),
      // On TV don't show FAB (focus gets stuck on it) — TV has
      // Add ROM buttons in the header and empty-state instead.
      floatingActionButton: TvDetector.isTV ? null : _buildFAB(),
    ),
    );
  }
  
  /// Compact header for landscape mode - combines logo, search, filter in one row
  Widget _buildCompactHeader() {
    final colors = AppColorTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Logo
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              'assets/images/app_icon.png',
              width: 36,
              height: 36,
            ),
          ),
          const SizedBox(width: 12),
          
          // Search bar - expanded (on TV in landscape: button opens dialog)
          Expanded(
            child: TvDetector.isTV
                ? TvFocusable(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _showTvSearchDialog(context),
                    child: Container(
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.search, color: colors.textMuted, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _searchQuery.isEmpty ? 'Search...' : _searchQuery,
                              style: TextStyle(
                                fontSize: 14,
                                color: _searchQuery.isEmpty ? colors.textMuted : colors.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (_searchQuery.isNotEmpty)
                            IconButton(
                              icon: Icon(Icons.clear, color: colors.textMuted, size: 18),
                              onPressed: () {
                                _searchDebounce?.cancel();
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                            ),
                        ],
                      ),
                    ),
                  )
                : SizedBox(
                    height: 40,
                    child: TextField(
                      controller: _searchController,
                      onChanged: _onSearchChanged,
                      keyboardType: TextInputType.text,
                      textInputAction: TextInputAction.search,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Search...',
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                        prefixIcon: Icon(Icons.search, color: colors.textMuted, size: 20),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: Icon(Icons.clear, color: colors.textMuted, size: 18),
                                onPressed: () {
                                  _searchDebounce?.cancel();
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          
          // Platform filter dropdown
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<GamePlatform?>(
                value: _selectedPlatform,
                hint: const Text('All', style: TextStyle(fontSize: 12)),
                style: TextStyle(fontSize: 12, color: colors.textPrimary),
                dropdownColor: colors.surface,
                items: [
                  const DropdownMenuItem(value: null, child: Text('All')),
                  const DropdownMenuItem(value: GamePlatform.gba, child: Text('GBA')),
                  const DropdownMenuItem(value: GamePlatform.gbc, child: Text('GBC')),
                  const DropdownMenuItem(value: GamePlatform.gb, child: Text('GB')),
                ],
                onChanged: (value) => setState(() => _selectedPlatform = value),
              ),
            ),
          ),
          const SizedBox(width: 8),
          
          // Sort button — uses dialog instead of PopupMenuButton for TV D-pad support
          TvFocusable(
            onTap: _showSortDialog,
            borderRadius: BorderRadius.circular(8),
            child: IconButton(
              icon: Icon(Icons.swap_vert, color: colors.textSecondary, size: 20),
              tooltip: 'Sort by',
              onPressed: _showSortDialog,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          ),

          // View toggle
          TvFocusable(
            onTap: () {
              setState(() => _isGridView = !_isGridView);
              context.read<SettingsService>().setGridView(_isGridView);
            },
            borderRadius: BorderRadius.circular(8),
            child: IconButton(
              icon: Icon(
                _isGridView ? Icons.view_list : Icons.grid_view,
                color: colors.textSecondary,
                size: 20,
              ),
              onPressed: () {
                setState(() => _isGridView = !_isGridView);
                context.read<SettingsService>().setGridView(_isGridView);
              },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          ),
          
          // On TV: direct focusable buttons (popup menus are hard with D-pad)
          if (TvDetector.isTV) ...[
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _addRomFile,
              child: IconButton(
                icon: Icon(Icons.add, color: colors.accent, size: 20),
                tooltip: 'Add ROMs',
                onPressed: _addRomFile,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _addRomFolder,
              child: IconButton(
                icon: Icon(Icons.create_new_folder, color: colors.accent, size: 20),
                tooltip: 'Add Folder',
                onPressed: _addRomFolder,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _openSettings,
              child: IconButton(
                icon: Icon(Icons.settings_outlined, color: colors.textSecondary, size: 20),
                tooltip: 'Settings',
                onPressed: _openSettings,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ),
          ] else ...[
          // More menu (phone/tablet compact) — Settings + Download All Cover Art
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: colors.textSecondary, size: 20),
            tooltip: 'More options',
            color: colors.surface,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onSelected: (value) {
              switch (value) {
                case 'settings':
                  _openSettings();
                case 'download_all_covers':
                  _downloadAllCoverArt();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'download_all_covers',
                child: ListTile(
                  leading: Icon(Icons.download),
                  title: Text('Download All Cover Art'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: ListTile(
                  leading: Icon(Icons.settings_outlined),
                  title: Text('Settings'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final colors = AppColorTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      child: Row(
        children: [
          // Logo/Title
          Expanded(
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: colors.primary.withAlpha(102),
                        blurRadius: 12,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset(
                      'assets/images/app_icon.png',
                      width: 44,
                      height: 44,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'RetroPal',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: colors.textPrimary,
                          letterSpacing: 2,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      Text(
                        'Enjoy Classic Games',
                        style: TextStyle(
                          fontSize: 10,
                          color: colors.textMuted,
                          letterSpacing: 0.5,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          // Sort button — uses dialog instead of PopupMenuButton for TV D-pad support
          TvFocusable(
            onTap: _showSortDialog,
            borderRadius: BorderRadius.circular(8),
            child: IconButton(
              icon: Icon(Icons.swap_vert, color: colors.textSecondary),
              tooltip: 'Sort by',
              onPressed: _showSortDialog,
            ),
          ),

          // View toggle
          TvFocusable(
            onTap: () {
              setState(() => _isGridView = !_isGridView);
              context.read<SettingsService>().setGridView(_isGridView);
            },
            borderRadius: BorderRadius.circular(8),
            child: IconButton(
              icon: Icon(
                _isGridView ? Icons.view_list : Icons.grid_view,
                color: colors.textSecondary,
              ),
              onPressed: () {
                setState(() => _isGridView = !_isGridView);
                context.read<SettingsService>().setGridView(_isGridView);
              },
            ),
          ),
          
          // On TV: direct focusable buttons (popup menus are hard with D-pad)
          if (TvDetector.isTV) ...[
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _addRomFile,
              child: IconButton(
                icon: Icon(Icons.add, color: colors.accent),
                tooltip: 'Add ROMs',
                onPressed: _addRomFile,
              ),
            ),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _addRomFolder,
              child: IconButton(
                icon: Icon(Icons.create_new_folder, color: colors.accent),
                tooltip: 'Add Folder',
                onPressed: _addRomFolder,
              ),
            ),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _openSettings,
              child: IconButton(
                icon: Icon(Icons.settings_outlined, color: colors.textSecondary),
                tooltip: 'Settings',
                onPressed: _openSettings,
              ),
            ),
          ] else ...[
          // More menu (phone/tablet) — Settings + Download All Cover Art
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: colors.textSecondary),
            tooltip: 'More options',
            color: colors.surface,
            onSelected: (value) {
              switch (value) {
                case 'settings':
                  _openSettings();
                case 'download_all_covers':
                  _downloadAllCoverArt();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'download_all_covers',
                child: ListTile(
                  leading: Icon(Icons.download),
                  title: Text('Download All Cover Art'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: ListTile(
                  leading: Icon(Icons.settings_outlined),
                  title: Text('Settings'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
          ],
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    final colors = AppColorTheme.of(context);

    // On TV: use a button that opens a full-screen search dialog.
    // The dialog's TextField is more likely to trigger the on-screen keyboard
    // than an inline field. Fallback for TVs where the platform keyboard
    // doesn't appear in the main layout.
    if (TvDetector.isTV) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: TvFocusable(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _showTvSearchDialog(context),
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.surfaceLight, width: 0.5),
            ),
            child: Row(
              children: [
                Icon(Icons.search, color: colors.textMuted, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _searchQuery.isEmpty ? 'Search games...' : _searchQuery,
                    style: TextStyle(
                      fontSize: 14,
                      color: _searchQuery.isEmpty ? colors.textMuted : colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_searchQuery.isNotEmpty)
                  IconButton(
                    icon: Icon(Icons.clear, color: colors.textMuted, size: 20),
                    onPressed: () {
                      _searchDebounce?.cancel();
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search games...',
          prefixIcon: Icon(Icons.search, color: colors.textMuted),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.clear, color: colors.textMuted),
                  onPressed: () {
                    _searchDebounce?.cancel();
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
        ),
      ),
    );
  }

  void _showTvSearchDialog(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final controller = TextEditingController(text: _searchController.text);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.escape ||
               event.logicalKey == LogicalKeyboardKey.goBack ||
               event.logicalKey == LogicalKeyboardKey.gameButtonB ||
               event.logicalKey == LogicalKeyboardKey.browserBack)) {
            Navigator.of(ctx).pop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: AlertDialog(
          title: const Text('Search games'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Type to search...',
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => Navigator.of(ctx).pop(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('Cancel', style: TextStyle(color: colors.textMuted)),
            ),
            FilledButton(
              onPressed: () {
                final query = controller.text;
                _searchController.text = query;
                _searchDebounce?.cancel();
                setState(() => _searchQuery = query);
                Navigator.of(ctx).pop();
              },
              child: const Text('Search'),
            ),
          ],
        ),
      ),
    ).then((_) {
      controller.dispose();
    });
  }

  Widget _buildPlatformFilter() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: PlatformFilter(
        selectedPlatform: _selectedPlatform,
        onChanged: (platform) {
          setState(() => _selectedPlatform = platform);
        },
      ),
    );
  }

  Widget _buildTabBar() {
    final colors = AppColorTheme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Consumer<GameLibraryService>(
        builder: (context, library, _) {
          final allCount = library.games.length;
          final recentCount = library.recentlyPlayed.length;
          final favCount = library.favorites.length;
          return TabBar(
            controller: _tabController,
            indicator: BoxDecoration(
              color: colors.primary,
              borderRadius: BorderRadius.circular(10),
            ),
            indicatorSize: TabBarIndicatorSize.tab,
            indicatorPadding: const EdgeInsets.all(4),
            labelColor: colors.textPrimary,
            unselectedLabelColor: colors.textMuted,
            labelStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
            // Visible focus ring for TV / D-pad navigation
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused)) {
                return colors.accent.withAlpha(50);
              }
              if (states.contains(WidgetState.hovered)) {
                return colors.accent.withAlpha(25);
              }
              return null;
            }),
            splashBorderRadius: BorderRadius.circular(10),
            dividerHeight: 0,
            tabs: [
              Tab(text: 'All Games ($allCount)'),
              Tab(text: 'Recent ($recentCount)'),
              Tab(text: 'Favorites ($favCount)'),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTvHintBar() {
    final colors = AppColorTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      color: colors.backgroundDark,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: colors.surfaceLight),
            ),
            child: Text(
              'L1',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                color: colors.textSecondary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '◄  Tabs  ►',
              style: TextStyle(
                fontSize: 12,
                color: colors.textMuted,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: colors.surfaceLight),
            ),
            child: Text(
              'R1',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                color: colors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: colors.surfaceLight),
            ),
            child: Text(
              'Select',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                color: colors.textSecondary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              'Options',
              style: TextStyle(
                fontSize: 12,
                color: colors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAllGames() {
    final colors = AppColorTheme.of(context);
    return Consumer<GameLibraryService>(
      builder: (context, library, _) {
        // Only show full-screen spinner on initial load (empty library).
        // During refresh, keep games visible with a subtle overlay.
        if (library.isLoading && library.games.isEmpty) {
          return const Center(
            child: CircularProgressIndicator(),
          );
        }

        var games = library.getGamesByPlatform(_selectedPlatform);
        if (_searchQuery.isNotEmpty) {
          games = games.where((g) => 
            g.name.toLowerCase().contains(_searchQuery.toLowerCase())
          ).toList();
        }
        games = _sortGames(games);

        if (games.isEmpty) {
          return _buildEmptyState();
        }

        return Stack(
          children: [
            Column(
              children: [
                if (_searchQuery.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${games.length} result${games.length == 1 ? '' : 's'} for \'$_searchQuery\'',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textMuted,
                        ),
                      ),
                    ),
                  ),
                Expanded(child: _buildGameList(games)),
              ],
            ),
            if (library.isLoading)
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: Center(
                  child: Material(
                    color: colors.surface.withAlpha(230),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colors.primary,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'Refreshing library…',
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildRecentGames() {
    return Consumer<GameLibraryService>(
      builder: (context, library, _) {
        var games = _sortGames(library.recentlyPlayed);

        if (games.isEmpty) {
          return _buildEmptyState(
            icon: Icons.history,
            title: 'No Recent Games',
            subtitle: 'Games you play will appear here',
          );
        }

        return _buildGameList(games);
      },
    );
  }

  Widget _buildFavorites() {
    return Consumer<GameLibraryService>(
      builder: (context, library, _) {
        var games = _sortGames(library.favorites);

        if (games.isEmpty) {
          return _buildEmptyState(
            icon: Icons.favorite_border,
            title: 'No Favorites',
            subtitle: 'Long press a game to add to favorites',
          );
        }

        return _buildGameList(games);
      },
    );
  }

  /// Determines which game card index should receive autofocus.
  /// On TV: uses the last-focused index when restoring focus (only if
  /// we're on the same tab), otherwise defaults to 0 on the initial build.
  bool _shouldAutofocusIndex(int index, int itemCount) {
    if (!TvDetector.isTV) return false;
    if (_shouldRestoreFocus &&
        _tabController.index == _lastFocusedTabIndex &&
        itemCount > 0) {
      return index == _lastFocusedGameIndex.clamp(0, itemCount - 1);
    }
    return index == 0;
  }

  Widget _buildGameList(List<GameRom> games) {
    // Clear the restore flag after this build frame so we don't keep
    // autofocusing on subsequent rebuilds (e.g. from Consumer).
    if (_shouldRestoreFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _shouldRestoreFocus = false;
      });
    }

    if (_isGridView) {
      // 2 items per row; larger cache extent for 100+ games (smoother scrolling)
      const crossAxisCount = 2;
      final cacheExtent = games.length > 100 ? 600.0 : 400.0;

      return TvScrollAccelerator(
        child: GridView.builder(
          padding: const EdgeInsets.all(16),
          cacheExtent: cacheExtent,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: 0.65,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: games.length,
          itemBuilder: (context, index) {
            final game = games[index];
            return TvFocusable(
              autofocus: _shouldAutofocusIndex(index, games.length),
              onTap: () => _launchGame(game),
              onLongPress: () => _showGameOptions(game),
              onFocusChanged: (focused) {
                if (focused) {
                  _lastFocusedGameIndex = index;
                  _lastFocusedTabIndex = _tabController.index;
                }
              },
              child: GameCard(
                game: game,
                onTap: () => _launchGame(game),
                onLongPress: () => _showGameOptions(game),
              ),
            );
          },
        ),
      );
    }

    final listCacheExtent = games.length > 100 ? 600.0 : 400.0;
    return TvScrollAccelerator(
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        cacheExtent: listCacheExtent,
        itemCount: games.length,
        separatorBuilder: (context, index) => const SizedBox(height: 4),
        itemBuilder: (context, index) {
          final game = games[index];
          return TvFocusable(
            autofocus: _shouldAutofocusIndex(index, games.length),
            borderRadius: BorderRadius.circular(12),
            onTap: () => _launchGame(game),
            onLongPress: () => _showGameOptions(game),
            onFocusChanged: (focused) {
              if (focused) {
                _lastFocusedGameIndex = index;
                _lastFocusedTabIndex = _tabController.index;
              }
            },
            child: GameListTile(
              game: game,
              onTap: () => _launchGame(game),
              onLongPress: () => _showGameOptions(game),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState({
    IconData icon = Icons.folder_open,
    String title = 'No Games Found',
    String subtitle = 'Add ROM files or folders to get started',
  }) {
    final colors = AppColorTheme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: colors.surface,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 48,
                color: colors.primary.withAlpha(128),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 14,
                color: colors.textMuted,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TvFocusable(
                  autofocus: TvDetector.isTV,
                  borderRadius: BorderRadius.circular(12),
                  onTap: _addRomFile,
                  child: OutlinedButton.icon(
                    onPressed: _addRomFile,
                    icon: const Icon(Icons.add),
                    label: const Text('Add ROMs'),
                  ),
                ),
                const SizedBox(width: 12),
                TvFocusable(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _addRomFolder,
                  child: ElevatedButton.icon(
                    onPressed: _addRomFolder,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Add Folder'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFAB() {
    return Padding(
      // Push the FAB up so it stays above the BannerAd (approx 50-60dp)
      padding: const EdgeInsets.only(bottom: 60),
      child: TvFocusable(
        borderRadius: BorderRadius.circular(16),
        onTap: _addRomFile,
        child: FloatingActionButton(
          onPressed: _addRomFile,
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  Future<void> _selectCoverArt(GameRom game) async {
    final library = context.read<GameLibraryService>();
    
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (!mounted) return;
    
    if (result != null && result.files.isNotEmpty) {
      final path = result.files.first.path;
      if (path != null) {
        await library.setCoverArt(game, path);
        if (mounted) {
          ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
            const SnackBar(
              content: Text('Cover art set!'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      }
    }
  }

  /// Download cover art for a single game by its ROM hash.
  Future<void> _downloadCoverArt(GameRom game) async {
    if (!mounted) return;

    final library = context.read<GameLibraryService>();
    final coverService = context.read<CoverArtService>();

    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Searching cover art for "${game.name}"…'),
              ),
            ],
          ),
          duration: const Duration(seconds: 30),
        ),
      );

    final localPath = await coverService.fetchCoverArt(game);

    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();

    if (localPath != null) {
      await library.setCoverArt(game, localPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cover art downloaded!'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No cover art found for this ROM.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// Download cover art for all games that don't have one.
  Future<void> _downloadAllCoverArt() async {
    if (!mounted) return;

    final library = context.read<GameLibraryService>();
    final coverService = context.read<CoverArtService>();
    final games = library.games;

    final gamesWithoutCover =
        games.where((g) => g.coverPath == null).toList();

    if (gamesWithoutCover.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('All games already have cover art.'),
            duration: Duration(seconds: 2),
          ),
        );
      return;
    }

    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Downloading cover art for ${gamesWithoutCover.length} '
            'game${gamesWithoutCover.length == 1 ? '' : 's'}…',
          ),
          duration: const Duration(seconds: 60),
        ),
      );

    final results = await coverService.fetchAllCoverArt(gamesWithoutCover);

    // Apply results to library
    for (final entry in results.entries) {
      final game = games.firstWhere(
        (g) => g.path == entry.key,
        orElse: () => gamesWithoutCover.first,
      );
      await library.setCoverArt(game, entry.value);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Downloaded ${results.length} of '
            '${gamesWithoutCover.length} cover art images.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
  }


  /// Fire-and-forget: download cover art for a list of newly imported games.
  void _autoFetchCovers(List<GameRom> games, GameLibraryService library) {
    final coverService = context.read<CoverArtService>();

    () async {
      for (final game in games) {
        if (game.coverPath != null) continue;
        try {
          final path = await coverService.fetchCoverArt(game);
          if (path != null) {
            await library.setCoverArt(game, path);
          }
        } catch (_) {
          // Best-effort — don't interrupt the user
        }
        // Small delay between requests
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }();
  }

  /// Show achievements list for a game.
  ///
  /// This resolves the game ID from the ROM hash, loads achievement data,
  /// and opens the AchievementsScreen.
  Future<void> _showAchievementsForGame(GameRom game) async {
    final raService = context.read<RetroAchievementsService>();
    final settings = context.read<SettingsService>().settings;

    if (!raService.isLoggedIn) return;

    // Show loading indicator
    ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            SizedBox(width: 12),
            Text('Loading achievements...'),
          ],
        ),
        duration: Duration(seconds: 10),
      ),
    );

    // Start game session to resolve game ID and load data.
    // awaitData: true ensures achievement metadata is fully loaded before
    // we check gameData — avoids the screen opening with no data.
    await raService.startGameSession(game, awaitData: true);

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final gameData = raService.gameData;
    final session = raService.activeSession;

    if (session == null || session.gameId <= 0) {
      ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
        const SnackBar(
          content: Text('This ROM is not recognized by RetroAchievements'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    if (gameData == null || gameData.achievements.isEmpty) {
      ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
        const SnackBar(
          content: Text('No achievements found for this game'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    if (!mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AchievementsScreen(
          gameData: gameData,
          isHardcore: settings.raHardcoreMode,
        ),
      ),
    ).then((_) {
      if (mounted) setState(() => _shouldRestoreFocus = true);
    });
  }

  void _showGameOptions(GameRom game) {
    final colors = AppColorTheme.of(context);
    final library = context.read<GameLibraryService>();

    showModalBottomSheet(
      context: context,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.surfaceLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                
                // Game title
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    game.name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 16),
                
                Flexible(
                  child: SingleChildScrollView(
                    child: FocusTraversalGroup(
                      policy: OrderedTraversalPolicy(),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TvFocusable(
                            autofocus: true,
                            onTap: () {
                              Navigator.pop(context);
                              _launchGame(game);
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: ListTile(
                              leading: const Icon(Icons.play_arrow),
                              title: const Text('Play'),
                              onTap: () {
                                Navigator.pop(context);
                                _launchGame(game);
                              },
                            ),
                          ),
                          // Achievements (only if RA is logged in)
                          Builder(
                            builder: (ctx) {
                              final raService = ctx.read<RetroAchievementsService>();
                              final settings = ctx.read<SettingsService>();
                              if (!settings.settings.raEnabled || !raService.isLoggedIn) {
                                return const SizedBox.shrink();
                              }
                              return TvFocusable(
                                onTap: () {
                                  Navigator.pop(ctx);
                                  _showAchievementsForGame(game);
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: ListTile(
                                  leading: const Icon(Icons.emoji_events, color: Colors.amber),
                                  title: const Text('Achievements'),
                                  subtitle: const Text('View RetroAchievements'),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    _showAchievementsForGame(game);
                                  },
                                ),
                              );
                            },
                          ),
                          TvFocusable(
                            onTap: () {
                              library.toggleFavorite(game);
                              Navigator.pop(context);
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: ListTile(
                              leading: Icon(
                                game.isFavorite ? Icons.favorite : Icons.favorite_border,
                                color: game.isFavorite ? colors.accentAlt : null,
                              ),
                              title: Text(
                                game.isFavorite ? 'Remove from Favorites' : 'Add to Favorites',
                              ),
                              onTap: () {
                                library.toggleFavorite(game);
                                Navigator.pop(context);
                              },
                            ),
                          ),
                          TvFocusable(
                            onTap: () {
                              Navigator.pop(context);
                              _selectCoverArt(game);
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: ListTile(
                              leading: const Icon(Icons.image),
                              title: const Text('Set Cover Art'),
                              subtitle: const Text('Choose from gallery'),
                              onTap: () {
                                Navigator.pop(context);
                                _selectCoverArt(game);
                              },
                            ),
                          ),
                          TvFocusable(
                            onTap: () {
                              Navigator.pop(context);
                              _downloadCoverArt(game);
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: ListTile(
                              leading: const Icon(Icons.download),
                              title: const Text('Download Cover Art'),
                              subtitle: const Text('Search online'),
                              onTap: () {
                                Navigator.pop(context);
                                _downloadCoverArt(game);
                              },
                            ),
                          ),
                          if (game.coverPath != null)
                            TvFocusable(
                              onTap: () {
                                library.removeCoverArt(game);
                                Navigator.pop(context);
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: ListTile(
                                leading: const Icon(Icons.hide_image_outlined),
                                title: const Text('Remove Cover Art'),
                                onTap: () {
                                  library.removeCoverArt(game);
                                  Navigator.pop(context);
                                },
                              ),
                            ),
                          TvFocusable(
                            onTap: () {
                              Navigator.pop(context);
                              _exportGameSaves(game);
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: ListTile(
                              leading: const Icon(Icons.archive_outlined),
                              title: const Text('Export Save Data'),
                              subtitle: Text(
                                'Backup .sav & save states to ZIP',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.textMuted,
                                ),
                              ),
                              onTap: () {
                                Navigator.pop(context);
                                _exportGameSaves(game);
                              },
                            ),
                          ),
                          TvFocusable(
                            onTap: () {
                              Navigator.pop(context);
                              _confirmDeleteSaveData(game);
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: ListTile(
                              leading: Icon(Icons.delete_sweep, color: colors.warning),
                              title: Text(
                                'Delete Save Data',
                                style: TextStyle(color: colors.warning),
                              ),
                              subtitle: Text(
                                'Remove .sav, save states & screenshots',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.textMuted,
                                ),
                              ),
                              onTap: () {
                                Navigator.pop(context);
                                _confirmDeleteSaveData(game);
                              },
                            ),
                          ),
                          TvFocusable(
                            onTap: () {
                              library.removeRom(game);
                              Navigator.pop(context);
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: ListTile(
                              leading: Icon(Icons.delete_outline, color: colors.error),
                              title: Text(
                                'Remove from Library',
                                style: TextStyle(color: colors.error),
                              ),
                              onTap: () {
                                library.removeRom(game);
                                Navigator.pop(context);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).then((_) {
      // Restore focus to the game list on TV after bottom sheet dismissal
      if (mounted) _gameListFocusNode.requestFocus();
    });
  }

  Future<void> _exportGameSaves(GameRom game) async {
    final colors = AppColorTheme.of(context);
    final emulator = context.read<EmulatorService>();

    ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
      const SnackBar(content: Text('Creating save backup…')),
    );

    try {
      final zipPath = await SaveBackupService.exportGameSaves(
        game: game,
        appSaveDir: emulator.saveDir,
      );

      if (!mounted) return;

      if (zipPath == null) {
        ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
          SnackBar(content: Text('No save files found for ${game.name}')),
        );
        return;
      }

      // Let the user choose: share or save.
      // Clean up the temp ZIP when the sheet is dismissed.
      showModalBottomSheet(
        context: context,
        backgroundColor: colors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (context) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.surfaceLight,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      'Save backup ready for ${game.name}',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: colors.textPrimary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FocusTraversalGroup(
                    policy: OrderedTraversalPolicy(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TvFocusable(
                          autofocus: true,
                          onTap: () {
                            Navigator.pop(context);
                            SaveBackupService.shareZip(zipPath);
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: ListTile(
                            leading: const Icon(Icons.share),
                            title: const Text('Share'),
                            subtitle: Text(
                              'Send via Google Drive, email, etc.',
                              style: TextStyle(fontSize: 12, color: colors.textMuted),
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              SaveBackupService.shareZip(zipPath);
                            },
                          ),
                        ),
                        TvFocusable(
                          onTap: () async {
                            final messenger = ScaffoldMessenger.of(context);
                            Navigator.pop(context);
                            final saved =
                                await SaveBackupService.saveZipToUserLocation(zipPath);
                            if (saved != null && mounted) {
                              messenger
                                ..clearSnackBars()
                                ..showSnackBar(
                                  SnackBar(content: Text('Saved to $saved')),
                                );
                            }
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: ListTile(
                            leading: const Icon(Icons.save_alt),
                            title: const Text('Save to…'),
                            subtitle: Text(
                              'Choose a folder on this device',
                              style: TextStyle(fontSize: 12, color: colors.textMuted),
                            ),
                            onTap: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              Navigator.pop(context);
                              final saved =
                                  await SaveBackupService.saveZipToUserLocation(zipPath);
                              if (saved != null && mounted) {
                                messenger
                                  ..clearSnackBars()
                                  ..showSnackBar(
                                    SnackBar(content: Text('Saved to $saved')),
                                  );
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ).whenComplete(() {
        // Delete the temp ZIP after the bottom sheet is dismissed,
        // regardless of whether the user shared, saved, or cancelled.
        SaveBackupService.deleteTempZip(zipPath);
        // Restore focus to the game list on TV
        if (mounted) _gameListFocusNode.requestFocus();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  Future<void> _confirmDeleteSaveData(GameRom game) async {
    final colors = AppColorTheme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.warning.withAlpha(80), width: 2),
        ),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: colors.warning, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Delete Save Data?',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will permanently delete all save data for:',
              style: TextStyle(color: colors.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              game.name,
              style: TextStyle(
                color: colors.textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '• Battery save (.sav)\n'
              '• All save states (slots 0-5)\n'
              '• Save state thumbnails\n'
              '• In-game screenshots',
              style: TextStyle(color: colors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Text(
              'This cannot be undone.',
              style: TextStyle(
                color: colors.warning,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancel',
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              backgroundColor: colors.warning.withAlpha(30),
            ),
            child: Text(
              'Delete',
              style: TextStyle(
                color: colors.warning,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final emulator = context.read<EmulatorService>();
      final count = await emulator.deleteSaveData(game);
      if (mounted) {
        ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(
          SnackBar(
            content: Text(
              count > 0
                  ? 'Deleted $count save file${count == 1 ? '' : 's'} for ${game.name}'
                  : 'No save files found for ${game.name}',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
    // Restore focus to the game list on TV after dialog dismissal
    if (mounted) _gameListFocusNode.requestFocus();
  }
}
