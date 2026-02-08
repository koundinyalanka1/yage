import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';

import '../core/mgba_bindings.dart';
import '../models/game_rom.dart';
import '../services/game_library_service.dart';
import '../services/emulator_service.dart';
import '../services/artwork_service.dart';
import '../services/save_backup_service.dart';
import '../utils/tv_detector.dart';
import '../widgets/game_card.dart';
import '../widgets/platform_filter.dart';
import '../widgets/tv_file_browser.dart';
import '../widgets/tv_focusable.dart';
import '../services/settings_service.dart';
import '../utils/theme.dart';
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
  Future<void> _checkIncomingFile() async {
    try {
      final path = await _deviceChannel.invokeMethod<String>('getOpenFilePath');
      if (path == null || path.isEmpty || !mounted) return;

      final game = GameRom.fromPath(path);
      if (game == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Unsupported file: $path')),
          );
        }
        return;
      }

      // Add to library if not already there
      final library = context.read<GameLibraryService>();
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

  Future<void> _addRomFile() async {
    List<String>? paths;

    // Try system file picker (SAF) — works on both phone and TV
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
      );
      paths = result?.files
          .where((f) => f.path != null)
          .map((f) => f.path!)
          .toList();
    } catch (_) {
      paths = null;
    }

    // On TV, fall back to built-in browser if system picker returned nothing
    if ((paths == null || paths.isEmpty) && TvDetector.isTV && mounted) {
      paths = await TvFileBrowser.pickFiles(context);
    }

    if (paths != null && paths.isNotEmpty && mounted) {
      final library = context.read<GameLibraryService>();
      final addedGames = <GameRom>[];
      
      for (final path in paths) {
        // Import via internal copy so the file persists
        final game = await library.importRom(path);
        if (game != null) {
          addedGames.add(game);
        }
      }
      
      // Auto-download artwork for newly added games
      if (addedGames.isNotEmpty && mounted) {
        _autoDownloadArtwork(addedGames, library);
        // Switch to "All Games" tab so the user sees the newly added ROM
        _tabController.animateTo(0);
      }
    }
  }
  
  /// Auto-download artwork for games in background
  Future<void> _autoDownloadArtwork(List<GameRom> games, GameLibraryService library) async {
    for (final game in games) {
      if (game.coverPath == null) {
        try {
          final artworkPath = await ArtworkService.fetchArtwork(game);
          if (artworkPath != null && mounted) {
            await library.setCoverArt(game, artworkPath);
          }
        } catch (e) {
          // Silently fail - artwork is optional
          debugPrint('Auto-download artwork failed for ${game.name}: $e');
        }
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

    // On TV, fall back to built-in folder browser if SAF unavailable
    if (importedPaths == null && TvDetector.isTV && mounted) {
      final dirPath = await TvFileBrowser.pickDirectory(context);
      if (dirPath != null) {
        await library.addRomDirectory(dirPath);
        if (mounted) _tabController.animateTo(0);
        return;
      }
    }

    if (importedPaths != null && importedPaths.isNotEmpty && mounted) {
      final addedGames = <GameRom>[];
      for (final path in importedPaths) {
        final game = await library.addRom(path);
        if (game != null) addedGames.add(game);
      }

      if (addedGames.isNotEmpty && mounted) {
        _autoDownloadArtwork(addedGames, library);
        _tabController.animateTo(0);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Imported ${addedGames.length} ROM${addedGames.length == 1 ? '' : 's'}'),
            duration: const Duration(seconds: 2),
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No new ROM files found in selected folder'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _launchGame(GameRom game) async {
    final emulator = context.read<EmulatorService>();
    final library = context.read<GameLibraryService>();

    // Update last played
    await library.updateLastPlayed(game);

    // Load ROM
    final success = await emulator.loadRom(game);
    
    if (success && mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => GameScreen(game: game),
        ),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to load ${game.name}'),
          backgroundColor: YageColors.error,
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Logo
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [YageColors.primary, YageColors.accent],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                'Y',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: YageColors.backgroundDark,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          
          // Search bar - expanded
          Expanded(
            child: SizedBox(
              height: 40,
              child: TextField(
                controller: _searchController,
                onChanged: _onSearchChanged,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search...',
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  prefixIcon: Icon(Icons.search, color: YageColors.textMuted, size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: Icon(Icons.clear, color: YageColors.textMuted, size: 18),
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
              color: YageColors.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<GamePlatform?>(
                value: _selectedPlatform,
                hint: const Text('All', style: TextStyle(fontSize: 12)),
                style: TextStyle(fontSize: 12, color: YageColors.textPrimary),
                dropdownColor: YageColors.surface,
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
          
          // Sort button
          PopupMenuButton<GameSortOption>(
            icon: Icon(Icons.swap_vert, color: YageColors.textSecondary, size: 20),
            tooltip: 'Sort by',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            color: YageColors.surface,
            onSelected: (value) {
              setState(() => _sortOption = value);
              context.read<SettingsService>().setSortOption(value.name);
            },
            itemBuilder: (context) => GameSortOption.values.map((opt) {
              final isSelected = _sortOption == opt;
              return PopupMenuItem(
                value: opt,
                child: ListTile(
                  leading: Icon(
                    opt.icon,
                    size: 20,
                    color: isSelected ? YageColors.accent : null,
                  ),
                  title: Text(
                    opt.label,
                    style: TextStyle(
                      color: isSelected ? YageColors.accent : null,
                      fontWeight: isSelected ? FontWeight.bold : null,
                    ),
                  ),
                  trailing: isSelected
                      ? Icon(Icons.check, size: 18, color: YageColors.accent)
                      : null,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              );
            }).toList(),
          ),

          // View toggle
          IconButton(
            icon: Icon(
              _isGridView ? Icons.view_list : Icons.grid_view,
              color: YageColors.textSecondary,
              size: 20,
            ),
            onPressed: () {
              setState(() => _isGridView = !_isGridView);
              context.read<SettingsService>().setGridView(_isGridView);
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          
          // On TV: direct focusable buttons (popup menus are hard with D-pad)
          if (TvDetector.isTV) ...[
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _addRomFile,
              child: IconButton(
                icon: Icon(Icons.add, color: YageColors.accent, size: 20),
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
                icon: Icon(Icons.create_new_folder, color: YageColors.accent, size: 20),
                tooltip: 'Add Folder',
                onPressed: _addRomFolder,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _downloadAllArtwork,
              child: IconButton(
                icon: Icon(Icons.download, color: YageColors.textSecondary, size: 20),
                tooltip: 'Download All Artwork',
                onPressed: _downloadAllArtwork,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
              child: IconButton(
                icon: Icon(Icons.settings_outlined, color: YageColors.textSecondary, size: 20),
                tooltip: 'Settings',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ),
          ] else
          // More options menu (phone/tablet)
          PopupMenuButton<String>(
            icon: Icon(
              Icons.more_vert,
              color: YageColors.textSecondary,
              size: 20,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            color: YageColors.surface,
            onSelected: (value) {
              switch (value) {
                case 'download_artwork':
                  _downloadAllArtwork();
                  break;
                case 'settings':
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'download_artwork',
                child: ListTile(
                  leading: Icon(Icons.download, size: 20),
                  title: Text('Download All Artwork'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: ListTile(
                  leading: Icon(Icons.settings_outlined, size: 20),
                  title: Text('Settings'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
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
                    gradient: LinearGradient(
                      colors: [YageColors.primary, YageColors.accent],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: YageColors.primary.withAlpha(102),
                        blurRadius: 12,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      'Y',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: YageColors.backgroundDark,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'RetroPal',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: YageColors.textPrimary,
                        letterSpacing: 2,
                      ),
                    ),
                    Text(
                      'Classic GB/GBC/GBA Games',
                      style: TextStyle(
                        fontSize: 10,
                        color: YageColors.textMuted,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          
          // Sort button
          PopupMenuButton<GameSortOption>(
            icon: Icon(Icons.swap_vert, color: YageColors.textSecondary),
            tooltip: 'Sort by',
            color: YageColors.surface,
            onSelected: (value) {
              setState(() => _sortOption = value);
              context.read<SettingsService>().setSortOption(value.name);
            },
            itemBuilder: (context) => GameSortOption.values.map((opt) {
              final isSelected = _sortOption == opt;
              return PopupMenuItem(
                value: opt,
                child: ListTile(
                  leading: Icon(
                    opt.icon,
                    size: 20,
                    color: isSelected ? YageColors.accent : null,
                  ),
                  title: Text(
                    opt.label,
                    style: TextStyle(
                      color: isSelected ? YageColors.accent : null,
                      fontWeight: isSelected ? FontWeight.bold : null,
                    ),
                  ),
                  trailing: isSelected
                      ? Icon(Icons.check, size: 18, color: YageColors.accent)
                      : null,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              );
            }).toList(),
          ),

          // View toggle
          IconButton(
            icon: Icon(
              _isGridView ? Icons.view_list : Icons.grid_view,
              color: YageColors.textSecondary,
            ),
            onPressed: () {
              setState(() => _isGridView = !_isGridView);
              context.read<SettingsService>().setGridView(_isGridView);
            },
          ),
          
          // On TV: direct focusable buttons (popup menus are hard with D-pad)
          if (TvDetector.isTV) ...[
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _addRomFile,
              child: IconButton(
                icon: Icon(Icons.add, color: YageColors.accent),
                tooltip: 'Add ROMs',
                onPressed: _addRomFile,
              ),
            ),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _addRomFolder,
              child: IconButton(
                icon: Icon(Icons.create_new_folder, color: YageColors.accent),
                tooltip: 'Add Folder',
                onPressed: _addRomFolder,
              ),
            ),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _downloadAllArtwork,
              child: IconButton(
                icon: Icon(Icons.download, color: YageColors.textSecondary),
                tooltip: 'Download All Artwork',
                onPressed: _downloadAllArtwork,
              ),
            ),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
              child: IconButton(
                icon: Icon(Icons.settings_outlined, color: YageColors.textSecondary),
                tooltip: 'Settings',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
            ),
          ] else
          // More options menu (phone/tablet)
          PopupMenuButton<String>(
            icon: Icon(
              Icons.more_vert,
              color: YageColors.textSecondary,
            ),
            color: YageColors.surface,
            onSelected: (value) {
              switch (value) {
                case 'download_artwork':
                  _downloadAllArtwork();
                  break;
                case 'settings':
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'download_artwork',
                child: ListTile(
                  leading: Icon(Icons.download, size: 20),
                  title: Text('Download All Artwork'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: ListTile(
                  leading: Icon(Icons.settings_outlined, size: 20),
                  title: Text('Settings'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        decoration: InputDecoration(
          hintText: 'Search games...',
          prefixIcon: Icon(Icons.search, color: YageColors.textMuted),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.clear, color: YageColors.textMuted),
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
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: YageColors.surface,
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
              color: YageColors.primary,
              borderRadius: BorderRadius.circular(10),
            ),
            indicatorSize: TabBarIndicatorSize.tab,
            indicatorPadding: const EdgeInsets.all(4),
            labelColor: YageColors.textPrimary,
            unselectedLabelColor: YageColors.textMuted,
            labelStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
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

  Widget _buildAllGames() {
    return Consumer<GameLibraryService>(
      builder: (context, library, _) {
        if (library.isLoading) {
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

        return Column(
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
                      color: YageColors.textMuted,
                    ),
                  ),
                ),
              ),
            Expanded(child: _buildGameList(games)),
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

  Widget _buildGameList(List<GameRom> games) {
    if (_isGridView) {
      // Adaptive column count: more columns on TV / large screens
      return LayoutBuilder(
        builder: (context, constraints) {
          int crossAxisCount = 2;
          if (TvDetector.isTV || constraints.maxWidth > 900) {
            crossAxisCount = 5;
          } else if (constraints.maxWidth > 600) {
            crossAxisCount = 3;
          }

          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              childAspectRatio: 0.75,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: games.length,
            itemBuilder: (context, index) {
              final game = games[index];
              return TvFocusable(
                autofocus: TvDetector.isTV && index == 0,
                onTap: () => _launchGame(game),
                onLongPress: () => _showGameOptions(game),
                child: GameCard(
                  game: game,
                  onTap: () => _launchGame(game),
                  onLongPress: () => _showGameOptions(game),
                ),
              );
            },
          );
        },
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: games.length,
      separatorBuilder: (context, index) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final game = games[index];
        return TvFocusable(
          autofocus: TvDetector.isTV && index == 0,
          borderRadius: BorderRadius.circular(12),
          onTap: () => _launchGame(game),
          onLongPress: () => _showGameOptions(game),
          child: GameListTile(
            game: game,
            onTap: () => _launchGame(game),
            onLongPress: () => _showGameOptions(game),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState({
    IconData icon = Icons.folder_open,
    String title = 'No Games Found',
    String subtitle = 'Add ROM files or folders to get started',
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: YageColors.surface,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 48,
                color: YageColors.primary.withAlpha(128),
              ),
            ),
          const SizedBox(height: 24),
          Text(
            title,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: YageColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 14,
              color: YageColors.textMuted,
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
    );
  }

  Widget _buildFAB() {
    return TvFocusable(
      borderRadius: BorderRadius.circular(16),
      onTap: _addRomFile,
      child: FloatingActionButton(
        onPressed: _addRomFile,
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _selectCoverArt(GameRom game) async {
    final library = context.read<GameLibraryService>();
    
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    
    if (result != null && result.files.isNotEmpty) {
      final path = result.files.first.path;
      if (path != null) {
        await library.setCoverArt(game, path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Cover art set!'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      }
    }
  }

  Future<void> _downloadCoverArt(GameRom game) async {
    final library = context.read<GameLibraryService>();
    
    // Show loading indicator
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 16),
            Text('Searching for artwork...'),
          ],
        ),
        duration: Duration(seconds: 10),
      ),
    );
    
    final success = await library.fetchArtwork(game);
    
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(success ? 'Cover art downloaded!' : 'No artwork found'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _downloadAllArtwork() async {
    final library = context.read<GameLibraryService>();
    
    // Count games needing artwork
    final needsArt = library.games.where((g) => g.coverPath == null).length;
    if (needsArt == 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All games already have cover art!'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    
    // Show progress dialog
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ArtworkDownloadDialog(
        library: library,
        totalGames: needsArt,
      ),
    );
  }

  void _showGameOptions(GameRom game) {
    final library = context.read<GameLibraryService>();

    showModalBottomSheet(
      context: context,
      backgroundColor: YageColors.surface,
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
                    color: YageColors.surfaceLight,
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
                      color: YageColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 16),
                
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          leading: const Icon(Icons.play_arrow),
                          title: const Text('Play'),
                          onTap: () {
                            Navigator.pop(context);
                            _launchGame(game);
                          },
                        ),
                        ListTile(
                          leading: Icon(
                            game.isFavorite ? Icons.favorite : Icons.favorite_border,
                            color: game.isFavorite ? YageColors.accentAlt : null,
                          ),
                          title: Text(
                            game.isFavorite ? 'Remove from Favorites' : 'Add to Favorites',
                          ),
                          onTap: () {
                            library.toggleFavorite(game);
                            Navigator.pop(context);
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.download),
                          title: const Text('Download Cover Art'),
                          subtitle: const Text('Auto-fetch from database'),
                          onTap: () {
                            Navigator.pop(context);
                            _downloadCoverArt(game);
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.image),
                          title: const Text('Set Cover Art'),
                          subtitle: const Text('Choose from gallery'),
                          onTap: () {
                            Navigator.pop(context);
                            _selectCoverArt(game);
                          },
                        ),
                        if (game.coverPath != null)
                          ListTile(
                            leading: const Icon(Icons.hide_image_outlined),
                            title: const Text('Remove Cover Art'),
                            onTap: () {
                              library.removeCoverArt(game);
                              Navigator.pop(context);
                            },
                          ),
                        ListTile(
                          leading: const Icon(Icons.archive_outlined),
                          title: const Text('Export Save Data'),
                          subtitle: Text(
                            'Backup .sav & save states to ZIP',
                            style: TextStyle(
                              fontSize: 12,
                              color: YageColors.textMuted,
                            ),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            _exportGameSaves(game);
                          },
                        ),
                        ListTile(
                          leading: Icon(Icons.delete_sweep, color: YageColors.warning),
                          title: Text(
                            'Delete Save Data',
                            style: TextStyle(color: YageColors.warning),
                          ),
                          subtitle: Text(
                            'Remove .sav, save states & screenshots',
                            style: TextStyle(
                              fontSize: 12,
                              color: YageColors.textMuted,
                            ),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            _confirmDeleteSaveData(game);
                          },
                        ),
                        ListTile(
                          leading: Icon(Icons.delete_outline, color: YageColors.error),
                          title: Text(
                            'Remove from Library',
                            style: TextStyle(color: YageColors.error),
                          ),
                          onTap: () {
                            library.removeRom(game);
                            Navigator.pop(context);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _exportGameSaves(GameRom game) async {
    final emulator = context.read<EmulatorService>();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Creating save backup…')),
    );

    try {
      final zipPath = await SaveBackupService.exportGameSaves(
        game: game,
        appSaveDir: emulator.saveDir,
      );

      if (!mounted) return;

      if (zipPath == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No save files found for ${game.name}')),
        );
        return;
      }

      // Let the user choose: share or save
      showModalBottomSheet(
        context: context,
        backgroundColor: YageColors.surface,
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
                      color: YageColors.surfaceLight,
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
                        color: YageColors.textPrimary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    leading: const Icon(Icons.share),
                    title: const Text('Share'),
                    subtitle: Text(
                      'Send via Google Drive, email, etc.',
                      style: TextStyle(fontSize: 12, color: YageColors.textMuted),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      SaveBackupService.shareZip(zipPath);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.save_alt),
                    title: const Text('Save to…'),
                    subtitle: Text(
                      'Choose a folder on this device',
                      style: TextStyle(fontSize: 12, color: YageColors.textMuted),
                    ),
                    onTap: () async {
                      Navigator.pop(context);
                      final saved =
                          await SaveBackupService.saveZipToUserLocation(zipPath);
                      if (saved != null && mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Saved to $saved')),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          );
        },
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  Future<void> _confirmDeleteSaveData(GameRom game) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: YageColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: YageColors.warning.withAlpha(80), width: 2),
        ),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: YageColors.warning, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Delete Save Data?',
                style: TextStyle(
                  color: YageColors.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will permanently delete all save data for:',
              style: TextStyle(color: YageColors.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              game.name,
              style: TextStyle(
                color: YageColors.textPrimary,
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
              style: TextStyle(color: YageColors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Text(
              'This cannot be undone.',
              style: TextStyle(
                color: YageColors.warning,
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
              style: TextStyle(color: YageColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              backgroundColor: YageColors.warning.withAlpha(30),
            ),
            child: Text(
              'Delete',
              style: TextStyle(
                color: YageColors.warning,
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
        ScaffoldMessenger.of(context).showSnackBar(
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
  }
}

/// Dialog showing artwork download progress
class _ArtworkDownloadDialog extends StatefulWidget {
  final GameLibraryService library;
  final int totalGames;

  const _ArtworkDownloadDialog({
    required this.library,
    required this.totalGames,
  });

  @override
  State<_ArtworkDownloadDialog> createState() => _ArtworkDownloadDialogState();
}

class _ArtworkDownloadDialogState extends State<_ArtworkDownloadDialog> {
  int _completed = 0;
  int _found = 0;
  bool _isDownloading = true;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  Future<void> _startDownload() async {
    final found = await widget.library.fetchAllArtwork(
      onProgress: (completed, total) {
        if (mounted) {
          setState(() {
            _completed = completed;
          });
        }
      },
    );

    if (mounted) {
      setState(() {
        _found = found;
        _isDownloading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: YageColors.surface,
      title: Text(
        _isDownloading ? 'Downloading Artwork' : 'Download Complete',
        style: TextStyle(color: YageColors.textPrimary),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isDownloading) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: widget.totalGames > 0 
                  ? _completed / widget.totalGames 
                  : 0,
              backgroundColor: YageColors.backgroundLight,
              valueColor: AlwaysStoppedAnimation(YageColors.primary),
            ),
            const SizedBox(height: 16),
            Text(
              'Processing $_completed of ${widget.totalGames} games...',
              style: TextStyle(color: YageColors.textSecondary),
            ),
          ] else ...[
            Icon(
              _found > 0 ? Icons.check_circle : Icons.info_outline,
              size: 48,
              color: _found > 0 ? YageColors.success : YageColors.textMuted,
            ),
            const SizedBox(height: 16),
            Text(
              _found > 0
                  ? 'Found artwork for $_found games!'
                  : 'No new artwork found',
              style: TextStyle(
                color: YageColors.textPrimary,
                fontSize: 16,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
      actions: [
        if (!_isDownloading)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
      ],
    );
  }
}

