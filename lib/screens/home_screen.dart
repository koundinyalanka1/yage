import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';

import '../core/mgba_bindings.dart';
import '../models/game_rom.dart';
import '../services/game_library_service.dart';
import '../services/emulator_service.dart';
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
      type: FileType.custom,
      allowedExtensions: ['gba', 'gb', 'gbc', 'sgb'],
      allowMultiple: true,
    );

    if (result != null && mounted) {
      final library = context.read<GameLibraryService>();
      for (final file in result.files) {
        if (file.path != null) {
          await library.addRom(file.path!);
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
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildSearchBar(),
            _buildPlatformFilter(),
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
                    gradient: const LinearGradient(
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
                  child: const Center(
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
                    const Text(
                      'YAGE',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: YageColors.textPrimary,
                        letterSpacing: 2,
                      ),
                    ),
                    Text(
                      'Yet Another GB Emulator',
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
          
          // Settings
          IconButton(
            icon: const Icon(
              Icons.settings_outlined,
              color: YageColors.textSecondary,
            ),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
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
          prefixIcon: const Icon(Icons.search, color: YageColors.textMuted),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, color: YageColors.textMuted),
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
              decoration: const BoxDecoration(
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
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: YageColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: const TextStyle(
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
                    style: const TextStyle(
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
                  leading: const Icon(Icons.delete_outline, color: YageColors.error),
                  title: const Text(
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

