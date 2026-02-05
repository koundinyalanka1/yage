import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';

import '../core/mgba_bindings.dart';
import '../models/game_rom.dart';
import '../services/game_library_service.dart';
import '../services/emulator_service.dart';
import '../services/artwork_service.dart';
import '../widgets/game_card.dart';
import '../widgets/platform_filter.dart';
import '../utils/theme.dart';
import 'game_screen.dart';
import 'settings_screen.dart';

/// Main home screen with game library
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  GamePlatform? _selectedPlatform;
  String _searchQuery = '';
  bool _isGridView = true;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _addRomFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
    );

    if (result != null && mounted) {
      final library = context.read<GameLibraryService>();
      final addedGames = <GameRom>[];
      
      for (final file in result.files) {
        if (file.path != null) {
          final game = await library.addRom(file.path!);
          if (game != null) {
            addedGames.add(game);
          }
        }
      }
      
      // Auto-download artwork for newly added games
      if (addedGames.isNotEmpty && mounted) {
        _autoDownloadArtwork(addedGames, library);
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
    final result = await FilePicker.platform.getDirectoryPath();

    if (result != null && mounted) {
      final library = context.read<GameLibraryService>();
      await library.addRomDirectory(result);
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
    
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // In landscape, combine header elements into a single row
            if (isLandscape)
              _buildCompactHeader()
            else ...[
              _buildHeader(),
              _buildSearchBar(),
              _buildPlatformFilter(),
            ],
            _buildTabBar(),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildAllGames(),
                  _buildRecentGames(),
                  _buildFavorites(),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: _buildFAB(),
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
                onChanged: (value) => setState(() => _searchQuery = value),
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search...',
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  prefixIcon: Icon(Icons.search, color: YageColors.textMuted, size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: Icon(Icons.clear, color: YageColors.textMuted, size: 18),
                          onPressed: () {
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
          
          // View toggle
          IconButton(
            icon: Icon(
              _isGridView ? Icons.view_list : Icons.grid_view,
              color: YageColors.textSecondary,
              size: 20,
            ),
            onPressed: () => setState(() => _isGridView = !_isGridView),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          
          // More options menu
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
          
          // View toggle
          IconButton(
            icon: Icon(
              _isGridView ? Icons.view_list : Icons.grid_view,
              color: YageColors.textSecondary,
            ),
            onPressed: () => setState(() => _isGridView = !_isGridView),
          ),
          
          // More options menu
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
        onChanged: (value) => setState(() => _searchQuery = value),
        decoration: InputDecoration(
          hintText: 'Search games...',
          prefixIcon: Icon(Icons.search, color: YageColors.textMuted),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.clear, color: YageColors.textMuted),
                  onPressed: () {
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
      child: TabBar(
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
        tabs: const [
          Tab(text: 'All Games'),
          Tab(text: 'Recent'),
          Tab(text: 'Favorites'),
        ],
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

        if (games.isEmpty) {
          return _buildEmptyState();
        }

        return _buildGameList(games);
      },
    );
  }

  Widget _buildRecentGames() {
    return Consumer<GameLibraryService>(
      builder: (context, library, _) {
        final games = library.recentlyPlayed;

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
        final games = library.favorites;

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
      return GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.75,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: games.length,
        itemBuilder: (context, index) {
          final game = games[index];
          return GameCard(
            game: game,
            onTap: () => _launchGame(game),
            onLongPress: () => _showGameOptions(game),
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
        return GameListTile(
          game: game,
          onTap: () => _launchGame(game),
          onLongPress: () => _showGameOptions(game),
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
              OutlinedButton.icon(
                onPressed: _addRomFile,
                icon: const Icon(Icons.add),
                label: const Text('Add ROMs'),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _addRomFolder,
                icon: const Icon(Icons.folder_open),
                label: const Text('Add Folder'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFAB() {
    return FloatingActionButton(
      onPressed: _addRomFile,
      child: const Icon(Icons.add),
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
        );
      },
    );
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

