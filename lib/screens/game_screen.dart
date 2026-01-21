import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/game_rom.dart';
import '../models/gamepad_layout.dart';
import '../services/emulator_service.dart';
import '../services/settings_service.dart';
import '../widgets/game_display.dart';
import '../widgets/virtual_gamepad.dart';
import '../utils/theme.dart';

/// Game playing screen - optimized for mobile
class GameScreen extends StatefulWidget {
  final GameRom game;

  const GameScreen({super.key, required this.game});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with WidgetsBindingObserver {
  bool _showControls = true;
  bool _showMenu = false;
  bool _isLandscape = false;
  bool _editingLayout = false;
  GamepadLayout? _tempLayout; // Temporary layout while editing
  
  // Use a key to preserve GameDisplay state across orientation changes
  final _gameDisplayKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    // Hide system UI for immersive gaming
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    
    // Allow all orientations for mobile gaming
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    
    // Start emulation
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final emulator = context.read<EmulatorService>();
      emulator.start();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    
    // Restore UI
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    
    // Restore all orientations
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final emulator = context.read<EmulatorService>();
    
    if (state == AppLifecycleState.paused) {
      emulator.pause();
    } else if (state == AppLifecycleState.resumed) {
      if (!_showMenu) {
        emulator.start();
      }
    }
  }

  void _toggleMenu() {
    final emulator = context.read<EmulatorService>();
    
    setState(() {
      _showMenu = !_showMenu;
    });
    
    if (_showMenu) {
      emulator.pause();
    } else {
      emulator.start();
    }
  }

  void _exitGame() {
    final emulator = context.read<EmulatorService>();
    emulator.stop();
    Navigator.of(context).pop();
  }

  Future<bool> _showExitDialog() async {
    final emulator = context.read<EmulatorService>();
    final wasRunning = emulator.state == EmulatorState.running;
    
    // Pause while showing dialog
    if (wasRunning) {
      emulator.pause();
    }
    
    final shouldExit = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: YageColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: YageColors.primary.withAlpha(77),
            width: 2,
          ),
        ),
        title: const Text(
          'Exit Game?',
          style: TextStyle(
            color: YageColors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: const Text(
          'Your progress will be saved automatically.',
          style: TextStyle(
            color: YageColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: YageColors.textMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              backgroundColor: YageColors.error.withAlpha(51),
            ),
            child: const Text(
              'Exit',
              style: TextStyle(
                color: YageColors.error,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    
    if (shouldExit == true) {
      _exitGame();
      return true;
    } else {
      // Resume if was running
      if (wasRunning && !_showMenu) {
        emulator.start();
      }
      return false;
    }
  }

  void _toggleOrientation() {
    if (_isLandscape) {
      // Switch to portrait and lock it
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    } else {
      // Switch to landscape and lock it
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final emulator = context.watch<EmulatorService>();
    final settings = context.watch<SettingsService>().settings;
    
    // Create the game display once with a key to preserve it across rebuilds
    final gameDisplay = GameDisplay(
      key: _gameDisplayKey,
      emulator: emulator,
      maintainAspectRatio: settings.maintainAspectRatio,
      enableFiltering: settings.enableFiltering,
    );
    
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _showExitDialog();
      },
      child: Scaffold(
        backgroundColor: YageColors.backgroundDark,
        body: OrientationBuilder(
        builder: (context, orientation) {
          _isLandscape = orientation == Orientation.landscape;
          
          return Stack(
            children: [
              // Background
              Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 1.5,
                    colors: [
                      YageColors.backgroundLight,
                      YageColors.backgroundDark,
                    ],
                  ),
                ),
              ),
              
              // Main content - different layout for portrait vs landscape
              // Landscape: no SafeArea to maximize screen usage
              // Portrait: use SafeArea for proper spacing
              _isLandscape
                  ? _buildLandscapeLayout(emulator, settings, gameDisplay)
                  : SafeArea(
                      child: _buildPortraitLayout(emulator, settings, gameDisplay),
                    ),
              
              // FPS overlay - positioned to avoid R button in landscape
              if (settings.showFps)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 4,
                  right: _isLandscape 
                      ? MediaQuery.of(context).size.width * 0.12  // 12% from right
                      : 8,
                  child: FpsOverlay(fps: emulator.currentFps),
                ),
              
              // Demo mode indicator
              if (emulator.isUsingStub)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 8,
                  left: 60,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: YageColors.warning.withAlpha(200),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'DEMO MODE',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: YageColors.backgroundDark,
                      ),
                    ),
                  ),
                ),
              
              // Menu button (hide in edit mode)
              if (!_editingLayout)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 4,
                  left: _isLandscape 
                      ? MediaQuery.of(context).size.width * 0.12  // 12% from left
                      : 8,
                  child: _MenuButton(onTap: _toggleMenu),
                ),
              
              // Fast forward button (hide in edit mode) - next to menu
              if (!_editingLayout)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 4,
                  left: _isLandscape 
                      ? MediaQuery.of(context).size.width * 0.18  // 18% from left
                      : 60,
                  child: _FastForwardButton(
                    isActive: emulator.speedMultiplier > 1.0,
                    speed: emulator.speedMultiplier,
                    onTap: () => emulator.toggleFastForward(),
                  ),
                ),
              
              // Rotation toggle button (hide in edit mode)
              if (!_editingLayout)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 4,
                  right: _isLandscape 
                      ? MediaQuery.of(context).size.width * 0.18  // 18% from right
                      : (settings.showFps ? 70 : 8),
                  child: _RotationButton(
                    isLandscape: _isLandscape,
                    onTap: () => _toggleOrientation(),
                  ),
                ),
              
              // Layout editor toolbar - centered to avoid all buttons
              if (_editingLayout)
                Positioned(
                  top: _isLandscape 
                      ? MediaQuery.of(context).size.height * 0.35
                      : MediaQuery.of(context).padding.top + 60,
                  left: _isLandscape 
                      ? MediaQuery.of(context).size.width * 0.30 
                      : 16,
                  right: _isLandscape 
                      ? MediaQuery.of(context).size.width * 0.30 
                      : 16,
                  child: _LayoutEditorToolbar(
                    onSave: _saveLayout,
                    onCancel: _cancelEditLayout,
                    onReset: _resetLayout,
                  ),
                ),
              
              // In-game menu overlay
              if (_showMenu)
                _InGameMenu(
                  game: widget.game,
                  onResume: _toggleMenu,
                  onReset: () {
                    emulator.reset();
                    _toggleMenu();
                  },
                  onSaveState: (slot) async {
                    final success = await emulator.saveState(slot);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            success 
                                ? 'State saved to slot $slot' 
                                : 'Failed to save state',
                          ),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    }
                  },
                  onLoadState: (slot) async {
                    final success = await emulator.loadState(slot);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            success 
                                ? 'State loaded from slot $slot' 
                                : 'Failed to load state',
                          ),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                      if (success) _toggleMenu();
                    }
                  },
                  onToggleControls: () {
                    setState(() => _showControls = !_showControls);
                  },
                  showControls: _showControls,
                  onEditLayout: _enterEditMode,
                  currentSpeed: emulator.speedMultiplier,
                  onSpeedChanged: (speed) {
                    emulator.setSpeed(speed);
                  },
                  onExit: _exitGame,
                ),
            ],
          );
        },
      ),
      ),
    );
  }

  /// Portrait layout: Game on top, controls on bottom - MAXIMIZED
  Widget _buildPortraitLayout(EmulatorService emulator, settings, Widget gameDisplay) {
    final layout = _tempLayout ?? settings.gamepadLayoutPortrait;
    final screenSize = MediaQuery.of(context).size;
    final safeArea = MediaQuery.of(context).padding;
    
    // Calculate optimal game display - MAXIMIZE the game
    final aspectRatio = emulator.screenWidth / emulator.screenHeight;
    
    // Use full width (5px padding each side)
    final maxGameWidth = screenSize.width - 10;
    
    // Calculate height from width
    double gameWidth = maxGameWidth;
    double gameHeight = gameWidth / aspectRatio;
    
    // Top bar space (menu buttons) - extra clearance to avoid overlap
    final topBarHeight = 55.0;
    
    // Allow game to take more space - controls will overlay if needed
    // Reserve minimum 220px for controls on smaller screens, less on larger
    final minControlsHeight = screenSize.height > 700 ? 200.0 : 220.0;
    final maxGameHeight = screenSize.height - safeArea.top - safeArea.bottom - minControlsHeight - topBarHeight;
    
    // Constrain if too tall
    if (gameHeight > maxGameHeight) {
      gameHeight = maxGameHeight;
      gameWidth = gameHeight * aspectRatio;
    }
    
    return Stack(
      children: [
        // Game display at top
        Positioned(
          top: topBarHeight,
          left: 0,
          right: 0,
          child: Center(
            child: SizedBox(
              width: gameWidth,
              height: gameHeight,
              child: gameDisplay,
            ),
          ),
        ),
        
        // Virtual gamepad - positioned from bottom, can overlay game slightly
        if (_showControls)
          Positioned(
            left: 0,
            right: 0,
            bottom: safeArea.bottom,
            height: screenSize.height - topBarHeight - safeArea.top - gameHeight + 30, // Allow 30px overlap
            child: VirtualGamepad(
              gameRect: Rect.fromLTWH(
                (screenSize.width - gameWidth) / 2,
                topBarHeight + safeArea.top,
                gameWidth,
                gameHeight,
              ),
              onKeysChanged: emulator.setKeys,
              opacity: settings.gamepadOpacity,
              scale: settings.gamepadScale,
              enableVibration: settings.enableVibration,
              layout: layout,
              editMode: _editingLayout,
              onLayoutChanged: (newLayout) {
                setState(() => _tempLayout = newLayout);
              },
            ),

          ),
      ],
    );
  }

  /// Landscape layout: Game centered, controls overlay on sides
  Widget _buildLandscapeLayout(EmulatorService emulator, settings, Widget gameDisplay) {
    final layout = _tempLayout ?? settings.gamepadLayoutLandscape;
    final screenSize = MediaQuery.of(context).size;
    
    // Calculate game size - maximize with only 5px padding
    final aspectRatio = emulator.screenWidth / emulator.screenHeight;
    
    // Use nearly full height (5px margin top/bottom)
    final availableHeight = screenSize.height - 10;
    
    // Calculate width from height
    double gameHeight = availableHeight;
    double gameWidth = gameHeight * aspectRatio;
    
    // If too wide, constrain by width (5px margin each side)
    if (gameWidth > screenSize.width - 10) {
      gameWidth = screenSize.width - 10;
      gameHeight = gameWidth / aspectRatio;
    }
    
    return Stack(
      children: [
        // Game display - centered and MAXIMIZED
        Center(
          child: SizedBox(
            width: gameWidth,
            height: gameHeight,
            child: gameDisplay,
          ),
        ),
        
        // Virtual gamepad overlay in landscape (buttons positioned on sides)
        if (_showControls)
          VirtualGamepad(
            gameRect: Rect.fromLTWH(
              (screenSize.width - gameWidth) / 2,
              (screenSize.height - gameHeight) / 2,
              gameWidth,
              gameHeight,
            ),
            onKeysChanged: emulator.setKeys,
            opacity: settings.gamepadOpacity,
            scale: settings.gamepadScale,
            enableVibration: settings.enableVibration,
            layout: layout,
            editMode: _editingLayout,
            onLayoutChanged: (newLayout) {
              setState(() => _tempLayout = newLayout);
            },
          ),

      ],
    );
  }
  
  void _enterEditMode() {
    final settings = context.read<SettingsService>().settings;
    setState(() {
      _editingLayout = true;
      _showMenu = false;
      _tempLayout = _isLandscape 
          ? settings.gamepadLayoutLandscape 
          : settings.gamepadLayoutPortrait;
    });
    
    // Pause emulation while editing
    context.read<EmulatorService>().pause();
  }
  
  void _saveLayout() async {
    if (_tempLayout == null) return;
    
    final settingsService = context.read<SettingsService>();
    final emulatorService = context.read<EmulatorService>();
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    
    if (_isLandscape) {
      await settingsService.setGamepadLayoutLandscape(_tempLayout!);
    } else {
      await settingsService.setGamepadLayoutPortrait(_tempLayout!);
    }
    
    setState(() {
      _editingLayout = false;
      _tempLayout = null;
    });
    
    // Resume emulation
    emulatorService.start();
    
    if (mounted) {
      scaffoldMessenger.showSnackBar(
        const SnackBar(
          content: Text('Layout saved!'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }
  
  void _cancelEditLayout() {
    setState(() {
      _editingLayout = false;
      _tempLayout = null;
    });
    
    // Resume emulation
    context.read<EmulatorService>().start();
  }
  
  void _resetLayout() {
    if (_isLandscape) {
      setState(() => _tempLayout = GamepadLayout.defaultLandscape);
    } else {
      setState(() => _tempLayout = GamepadLayout.defaultPortrait);
    }
  }
}

class _MenuButton extends StatelessWidget {
  final VoidCallback onTap;

  const _MenuButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: YageColors.surface.withAlpha(204),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: YageColors.surfaceLight,
            width: 1,
          ),
        ),
        child: const Icon(
          Icons.menu,
          color: YageColors.textSecondary,
          size: 24,
        ),
      ),
    );
  }
}

class _RotationButton extends StatelessWidget {
  final bool isLandscape;
  final VoidCallback onTap;

  const _RotationButton({required this.isLandscape, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: YageColors.surface.withAlpha(204),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: YageColors.surfaceLight,
            width: 1,
          ),
        ),
        child: Icon(
          Icons.screen_rotation,
          color: YageColors.textSecondary,
          size: 22,
        ),
      ),
    );
  }
}

class _LayoutEditorToolbar extends StatelessWidget {
  final VoidCallback onSave;
  final VoidCallback onCancel;
  final VoidCallback onReset;

  const _LayoutEditorToolbar({
    required this.onSave,
    required this.onCancel,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: YageColors.surface.withAlpha(240),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: YageColors.accent,
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: YageColors.accent.withAlpha(50),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Row(
            children: [
              const Icon(Icons.tune, color: YageColors.accent, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'EDIT LAYOUT',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: YageColors.accent,
                    letterSpacing: 2,
                  ),
                ),
              ),
              // Close button
              GestureDetector(
                onTap: onCancel,
                child: const Icon(Icons.close, color: YageColors.textMuted, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 8),
          
          // Instructions
          const Text(
            'Drag buttons to move • Tap to select • Use +/- to resize',
            style: TextStyle(
              fontSize: 11,
              color: YageColors.textMuted,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          
          // Action buttons
          Row(
            children: [
              // Reset button
              Expanded(
                child: GestureDetector(
                  onTap: onReset,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: YageColors.backgroundLight,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: YageColors.surfaceLight),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.restart_alt, color: YageColors.textSecondary, size: 18),
                        SizedBox(width: 6),
                        Text(
                          'Reset',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: YageColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              
              // Save button
              Expanded(
                child: GestureDetector(
                  onTap: onSave,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: YageColors.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check, color: YageColors.textPrimary, size: 18),
                        SizedBox(width: 6),
                        Text(
                          'Save',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: YageColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InGameMenu extends StatelessWidget {
  final GameRom game;
  final VoidCallback onResume;
  final VoidCallback onReset;
  final void Function(int slot) onSaveState;
  final void Function(int slot) onLoadState;
  final VoidCallback onToggleControls;
  final bool showControls;
  final VoidCallback onEditLayout;
  final double currentSpeed;
  final void Function(double speed) onSpeedChanged;
  final VoidCallback onExit;

  const _InGameMenu({
    required this.game,
    required this.onResume,
    required this.onReset,
    required this.onSaveState,
    required this.onLoadState,
    required this.onToggleControls,
    required this.showControls,
    required this.onEditLayout,
    required this.currentSpeed,
    required this.onSpeedChanged,
    required this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onResume,
      child: Container(
        color: Colors.black.withAlpha(138),
        child: Center(
          child: GestureDetector(
            onTap: () {}, // Prevent tap through
            child: Container(
              width: 320,
              margin: const EdgeInsets.all(20),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: YageColors.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: YageColors.primary.withAlpha(77),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: YageColors.primary.withAlpha(51),
                    blurRadius: 30,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Title
                    const Text(
                      'PAUSED',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: YageColors.accent,
                        letterSpacing: 4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      game.name,
                      style: const TextStyle(
                        fontSize: 14,
                        color: YageColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 20),
                    
                    // Resume button
                    _MenuActionButton(
                      icon: Icons.play_arrow,
                      label: 'Resume',
                      onTap: onResume,
                      isPrimary: true,
                    ),
                    const SizedBox(height: 10),
                    
                    // Save/Load states
                    Row(
                      children: [
                        Expanded(
                          child: _MenuActionButton(
                            icon: Icons.save,
                            label: 'Save',
                            onTap: () => _showStateSlots(context, true),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _MenuActionButton(
                            icon: Icons.upload_file,
                            label: 'Load',
                            onTap: () => _showStateSlots(context, false),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    
                    // Other options
                    _MenuActionButton(
                      icon: showControls ? Icons.gamepad : Icons.gamepad_outlined,
                      label: showControls ? 'Hide Controls' : 'Show Controls',
                      onTap: onToggleControls,
                    ),
                    const SizedBox(height: 10),
                    
                    _MenuActionButton(
                      icon: Icons.tune,
                      label: 'Edit Layout',
                      onTap: onEditLayout,
                    ),
                    const SizedBox(height: 10),
                    
                    // Speed control
                    _SpeedSelector(
                      currentSpeed: currentSpeed,
                      onSpeedChanged: onSpeedChanged,
                    ),
                    const SizedBox(height: 10),
                    
                    _MenuActionButton(
                      icon: Icons.refresh,
                      label: 'Reset',
                      onTap: onReset,
                    ),
                    const SizedBox(height: 10),
                    
                    _MenuActionButton(
                      icon: Icons.exit_to_app,
                      label: 'Exit Game',
                      onTap: onExit,
                      isDestructive: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showStateSlots(BuildContext context, bool isSave) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: YageColors.surface,
        title: Text(
          isSave ? 'Save State' : 'Load State',
          style: const TextStyle(
            color: YageColors.textPrimary,
          ),
        ),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: List.generate(4, (index) {
            return InkWell(
              onTap: () {
                Navigator.pop(context);
                if (isSave) {
                  onSaveState(index);
                } else {
                  onLoadState(index);
                }
              },
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: YageColors.backgroundLight,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: YageColors.surfaceLight,
                    width: 2,
                  ),
                ),
                child: Center(
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: YageColors.textPrimary,
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

class _MenuActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isPrimary;
  final bool isDestructive;

  const _MenuActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isPrimary = false,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = isPrimary 
        ? YageColors.primary 
        : isDestructive 
            ? YageColors.error.withAlpha(51) 
            : YageColors.backgroundLight;
    
    final fgColor = isPrimary 
        ? YageColors.textPrimary 
        : isDestructive 
            ? YageColors.error 
            : YageColors.textSecondary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
            border: isPrimary 
                ? null 
                : Border.all(color: YageColors.surfaceLight, width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: fgColor, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: fgColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FastForwardButton extends StatelessWidget {
  final bool isActive;
  final double speed;
  final VoidCallback onTap;

  const _FastForwardButton({
    required this.isActive,
    required this.speed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: isActive 
              ? YageColors.accent.withAlpha(230)
              : YageColors.surface.withAlpha(204),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isActive ? YageColors.accent : YageColors.surfaceLight,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.fast_forward,
              color: isActive ? YageColors.backgroundDark : YageColors.textSecondary,
              size: 20,
            ),
            if (isActive) ...[
              const SizedBox(width: 4),
              Text(
                '${speed.toStringAsFixed(0)}x',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: YageColors.backgroundDark,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SpeedSelector extends StatelessWidget {
  final double currentSpeed;
  final void Function(double speed) onSpeedChanged;

  const _SpeedSelector({
    required this.currentSpeed,
    required this.onSpeedChanged,
  });

  static const List<double> speeds = [0.5, 1.0, 2.0, 4.0];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: YageColors.backgroundLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: YageColors.surfaceLight, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.speed, color: YageColors.textSecondary, size: 18),
              const SizedBox(width: 8),
              const Text(
                'Speed',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: YageColors.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                '${currentSpeed.toStringAsFixed(1)}x',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: YageColors.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: speeds.map((speed) {
              final isSelected = (currentSpeed - speed).abs() < 0.1;
              return Expanded(
                child: GestureDetector(
                  onTap: () => onSpeedChanged(speed),
                  child: Container(
                    margin: EdgeInsets.only(
                      right: speed != speeds.last ? 6 : 0,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected 
                          ? YageColors.primary 
                          : YageColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: isSelected 
                          ? null 
                          : Border.all(color: YageColors.surfaceLight),
                    ),
                    child: Center(
                      child: Text(
                        '${speed.toStringAsFixed(speed == 0.5 ? 1 : 0)}x',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: isSelected 
                              ? YageColors.textPrimary 
                              : YageColors.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
