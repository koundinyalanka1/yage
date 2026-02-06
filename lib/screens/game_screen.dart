import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/game_rom.dart';
import '../models/game_frame.dart';
import '../models/gamepad_layout.dart';
import '../services/emulator_service.dart';
import '../services/game_library_service.dart';
import '../services/settings_service.dart';
import '../services/gamepad_input.dart';
import '../utils/tv_detector.dart';
import '../widgets/game_display.dart';
import '../widgets/game_frame_overlay.dart';
import '../widgets/tv_focusable.dart';
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
  
  // External gamepad / keyboard input
  final GamepadMapper _gamepadMapper = GamepadMapper();
  final FocusNode _focusNode = FocusNode();
  int _virtualKeys = 0;
  int _physicalKeys = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // On Android TV, hide virtual controls by default
    if (TvDetector.isTV) {
      _showControls = false;
    }
    
    // Keep screen awake while playing
    WakelockPlus.enable();
    
    // Hide system UI for immersive gaming
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    
    // On TV, lock to landscape; on mobile allow all orientations
    if (TvDetector.isTV) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    
    // Start emulation
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final emulator = context.read<EmulatorService>();
      emulator.start();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.dispose();
    
    // Allow screen to sleep again
    WakelockPlus.disable();
    
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
      _flushPlayTime();
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
      _gamepadMapper.reset();
      _physicalKeys = 0;
      emulator.pause();
    } else {
      emulator.start();
      // Re-request focus for gamepad input
      _focusNode.requestFocus();
    }
  }

  /// Merge virtual and physical keys and push to emulator
  void _syncKeys() {
    final emulator = context.read<EmulatorService>();
    emulator.setKeys(_virtualKeys | _physicalKeys);
  }

  /// Called by VirtualGamepad when touch keys change
  void _onVirtualKeysChanged(int keys) {
    _virtualKeys = keys;
    _syncKeys();
  }

  /// Handle physical key events from Focus widget
  /// Keys that toggle the pause menu from the gamepad
  static final _menuToggleKeys = {
    LogicalKeyboardKey.gameButtonMode,
    LogicalKeyboardKey.gameButtonThumbLeft,
    LogicalKeyboardKey.f1,
  };

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final settings = context.read<SettingsService>().settings;
    if (!settings.enableExternalGamepad) return KeyEventResult.ignored;

    // ── Menu toggle: Mode / L3 / F1 toggle the pause menu ──
    if (event is KeyDownEvent && _menuToggleKeys.contains(event.logicalKey)) {
      _toggleMenu();
      return KeyEventResult.handled;
    }

    // ── While the pause menu is shown, let it handle its own focus/D-pad ──
    if (_showMenu || _editingLayout) return KeyEventResult.ignored;

    final wasDetected = _gamepadMapper.controllerDetected;
    final handled = _gamepadMapper.handleKeyEvent(event);
    if (handled) {
      _physicalKeys = _gamepadMapper.keys;
      _syncKeys();

      // Auto-hide virtual gamepad the first time a real controller is detected
      if (!wasDetected && _gamepadMapper.controllerDetected && _showControls) {
        setState(() => _showControls = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Controller detected — touch controls hidden'),
            duration: Duration(seconds: 2),
          ),
        );
      }

      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Flush accumulated session play time to the library
  void _flushPlayTime() {
    final emulator = context.read<EmulatorService>();
    final library = context.read<GameLibraryService>();
    final delta = emulator.flushPlayTime();
    if (delta > 0) {
      library.addPlayTime(widget.game, delta);
    }
  }

  void _onRewindHold(bool held) {
    final emulator = context.read<EmulatorService>();
    if (held) {
      emulator.startRewind();
    } else {
      emulator.stopRewind();
    }
  }

  void _exitGame() {
    final emulator = context.read<EmulatorService>();
    _flushPlayTime();
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
        title: Text(
          'Exit Game?',
          style: TextStyle(
            color: YageColors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'Your progress will be saved automatically.',
          style: TextStyle(
            color: YageColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: YageColors.textMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              backgroundColor: YageColors.error.withAlpha(51),
            ),
            child: Text(
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
    
    // Push audio settings to the native core whenever they change
    emulator.updateSettings(settings);
    
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
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKeyEvent,
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
              // No SafeArea for either - maximize game display
              _isLandscape
                  ? _buildLandscapeLayout(emulator, settings, gameDisplay)
                  : _buildPortraitLayout(emulator, settings, gameDisplay),
              
              // FPS overlay - positioned to the left of the rotation button
              if (settings.showFps)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 4,
                  right: _isLandscape 
                      ? MediaQuery.of(context).size.width * 0.12 + 52  // left of rotate btn
                      : 56,  // 8 (rotate btn right) + 44 (rotate btn width) + 4 (gap)
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
                    child: Text(
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
              
              // Rewind button (hold to rewind) - next to menu
              if (!_editingLayout && settings.enableRewind)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 4,
                  left: _isLandscape 
                      ? MediaQuery.of(context).size.width * 0.18
                      : 60,
                  child: _RewindButton(
                    isActive: emulator.isRewinding,
                    onHoldChanged: _onRewindHold,
                  ),
                ),

              // Fast forward button (hide in edit mode) - next to menu/rewind
              if (!_editingLayout)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 4,
                  left: _isLandscape 
                      ? MediaQuery.of(context).size.width * (settings.enableRewind ? 0.24 : 0.18)
                      : settings.enableRewind ? 108 : 60,
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
                      ? MediaQuery.of(context).size.width * 0.12  // 12% from right
                      : 8,
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
                  turboSpeed: settings.turboSpeed,
                  onSpeedChanged: (speed) {
                    emulator.setSpeed(speed);
                  },
                  onExit: _exitGame,
                  useJoystick: settings.useJoystick,
                  onToggleJoystick: () {
                    context.read<SettingsService>().toggleJoystick();
                  },
                  onScreenshot: () async {
                    final path = await emulator.captureScreenshot();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            path != null
                                ? 'Screenshot saved'
                                : 'Failed to capture screenshot',
                          ),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
            ],
          );
        },
      ),
      ),
      ),
    );
  }

  /// Portrait layout: Game on top, controls on bottom - FULLY MAXIMIZED
  /// All values are PROPORTIONAL to screen size for consistent layout across devices
  Widget _buildPortraitLayout(EmulatorService emulator, settings, Widget gameDisplay) {
    final layout = _tempLayout ?? settings.gamepadLayoutPortrait;
    final screenSize = MediaQuery.of(context).size;
    final safeArea = MediaQuery.of(context).padding;
    
    // Calculate optimal game display - MAXIMUM SIZE, NO PADDING
    final aspectRatio = emulator.screenWidth / emulator.screenHeight;
    
    // Use FULL width - no padding
    final maxGameWidth = screenSize.width;
    
    // Calculate height from width
    double gameWidth = maxGameWidth;
    double gameHeight = gameWidth / aspectRatio;
    
    // Position game lower - PROPORTIONAL offset (7% of screen height)
    // This ensures consistent look on all screen sizes
    final gameTopOffset = screenSize.height * 0.07;
    final gameTop = safeArea.top + gameTopOffset;
    
    // Allow game to take maximum space - controls will overlay
    // Only constrain if game would be taller than available space
    final maxGameHeight = screenSize.height - safeArea.top;
    
    // Constrain if too tall (shouldn't happen in portrait for GBA 3:2 ratio)
    if (gameHeight > maxGameHeight) {
      gameHeight = maxGameHeight;
      gameWidth = gameHeight * aspectRatio;
    }
    
    // Proportional overlap (5% of screen height)
    final overlapAmount = screenSize.height * 0.05;
    
    final gameRectPortrait = Rect.fromLTWH(
      (screenSize.width - gameWidth) / 2,
      gameTop,
      gameWidth,
      gameHeight,
    );

    return Stack(
      children: [
        // Console frame overlay (behind game display)
        if (settings.gameFrame != GameFrameType.none)
          Positioned.fill(
            child: GameFrameOverlay(
              frame: settings.gameFrame,
              gameRect: gameRectPortrait,
            ),
          ),

        // Game display at top - FULL WIDTH, NO PADDING
        Positioned(
          top: gameTop,
          left: (screenSize.width - gameWidth) / 2,
          child: SizedBox(
            width: gameWidth,
            height: gameHeight,
            child: gameDisplay,
          ),
        ),
        
        // Virtual gamepad - fills remaining space and can overlay game
        if (_showControls)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: screenSize.height - gameTop - gameHeight + overlapAmount,
            child: VirtualGamepad(
              gameRect: Rect.fromLTWH(
                (screenSize.width - gameWidth) / 2,
                gameTop,
                gameWidth,
                gameHeight,
              ),
              onKeysChanged: _onVirtualKeysChanged,
              opacity: settings.gamepadOpacity,
              scale: settings.gamepadScale,
              enableVibration: settings.enableVibration,
              layout: layout,
              editMode: _editingLayout,
              onLayoutChanged: (newLayout) {
                setState(() => _tempLayout = newLayout);
              },
              useJoystick: settings.useJoystick,
              skin: settings.gamepadSkin,
            ),
          ),
      ],
    );
  }

  /// Landscape layout: Game centered, controls overlay on sides - FULLY MAXIMIZED
  Widget _buildLandscapeLayout(EmulatorService emulator, settings, Widget gameDisplay) {
    final layout = _tempLayout ?? settings.gamepadLayoutLandscape;
    final screenSize = MediaQuery.of(context).size;
    
    // Calculate game size - MAXIMUM SIZE, NO PADDING
    final aspectRatio = emulator.screenWidth / emulator.screenHeight;
    
    // Use FULL height - no padding
    final availableHeight = screenSize.height;
    
    // Calculate width from height
    double gameHeight = availableHeight;
    double gameWidth = gameHeight * aspectRatio;
    
    // If too wide, constrain by width (no padding)
    if (gameWidth > screenSize.width) {
      gameWidth = screenSize.width;
      gameHeight = gameWidth / aspectRatio;
    }
    
    final gameRectLandscape = Rect.fromLTWH(
      (screenSize.width - gameWidth) / 2,
      (screenSize.height - gameHeight) / 2,
      gameWidth,
      gameHeight,
    );

    return Stack(
      children: [
        // Console frame overlay (behind game display)
        if (settings.gameFrame != GameFrameType.none)
          Positioned.fill(
            child: GameFrameOverlay(
              frame: settings.gameFrame,
              gameRect: gameRectLandscape,
            ),
          ),

        // Game display - centered and FULLY MAXIMIZED
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
            onKeysChanged: _onVirtualKeysChanged,
            opacity: settings.gamepadOpacity,
            scale: settings.gamepadScale,
            enableVibration: settings.enableVibration,
            layout: layout,
            editMode: _editingLayout,
            onLayoutChanged: (newLayout) {
              setState(() => _tempLayout = newLayout);
            },
            useJoystick: settings.useJoystick,
            skin: settings.gamepadSkin,
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
        child: Icon(
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
              Icon(Icons.tune, color: YageColors.accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
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
                child: Icon(Icons.close, color: YageColors.textMuted, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 8),
          
          // Instructions
          Text(
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
                    child: Row(
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
                    child: Row(
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
  final double turboSpeed;
  final void Function(double speed) onSpeedChanged;
  final VoidCallback onExit;
  final bool useJoystick;
  final VoidCallback onToggleJoystick;
  final VoidCallback onScreenshot;

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
    this.turboSpeed = 2.0,
    required this.onSpeedChanged,
    required this.onExit,
    required this.useJoystick,
    required this.onToggleJoystick,
    required this.onScreenshot,
  });

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: GestureDetector(
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
                    Text(
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
                      style: TextStyle(
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
                      autofocus: true,
                    ),
                    const SizedBox(height: 10),
                    
                    // Screenshot button
                    _MenuActionButton(
                      icon: Icons.camera_alt,
                      label: 'Screenshot',
                      onTap: onScreenshot,
                    ),
                    const SizedBox(height: 10),
                    
                    // Save/Load states
                    Row(
                      children: [
                        Expanded(
                          child: _MenuActionButton(
                            icon: Icons.save,
                            label: 'Save State',
                            onTap: () => _showStateSlots(context, true),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _MenuActionButton(
                            icon: Icons.upload_file,
                            label: 'Load State',
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
                    
                    // D-Pad / Joystick selector
                    _InputTypeSelector(
                      useJoystick: useJoystick,
                      onChanged: onToggleJoystick,
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
                      turboSpeed: turboSpeed,
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
      ),
    );
  }

  void _showStateSlots(BuildContext context, bool isSave) {
    final emulator = context.read<EmulatorService>();
    showDialog(
      context: context,
      builder: (dialogContext) => _StateSlotDialog(
        isSave: isSave,
        emulator: emulator,
        onSelect: (slot) {
          Navigator.pop(dialogContext);
          if (isSave) {
            onSaveState(slot);
          } else {
            onLoadState(slot);
          }
        },
      ),
    );
  }
}

class _StateSlotDialog extends StatefulWidget {
  final bool isSave;
  final EmulatorService emulator;
  final void Function(int slot) onSelect;

  const _StateSlotDialog({
    required this.isSave,
    required this.emulator,
    required this.onSelect,
  });

  @override
  State<_StateSlotDialog> createState() => _StateSlotDialogState();
}

class _StateSlotDialogState extends State<_StateSlotDialog> {
  final Map<int, bool> _hasState = {};
  final Map<int, File?> _screenshotFiles = {};
  final Map<int, DateTime?> _timestamps = {};

  @override
  void initState() {
    super.initState();
    _loadSlotInfo();
  }

  void _loadSlotInfo() {
    for (int i = 0; i < 6; i++) {
      final statePath = widget.emulator.getStatePath(i);
      final ssPath = widget.emulator.getStateScreenshotPath(i);

      if (statePath != null) {
        final stateFile = File(statePath);
        if (stateFile.existsSync()) {
          _hasState[i] = true;
          _timestamps[i] = stateFile.lastModifiedSync();
        }
      }

      if (ssPath != null) {
        final ssFile = File(ssPath);
        if (ssFile.existsSync()) {
          _screenshotFiles[i] = ssFile;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: YageColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: YageColors.primary.withAlpha(77),
          width: 2,
        ),
      ),
      contentPadding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      title: Row(
        children: [
          Icon(
            widget.isSave ? Icons.save : Icons.upload_file,
            color: YageColors.accent,
            size: 22,
          ),
          const SizedBox(width: 10),
          Text(
            widget.isSave ? 'Save State' : 'Load State',
            style: TextStyle(
              color: YageColors.textPrimary,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(6, (i) => _buildSlot(i)),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: TextStyle(color: YageColors.textMuted),
          ),
        ),
      ],
    );
  }

  Widget _buildSlot(int index) {
    final hasState = _hasState[index] == true;
    final hasScreenshot = _screenshotFiles.containsKey(index);
    final timestamp = _timestamps[index];
    final isDisabled = !widget.isSave && !hasState;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isDisabled ? null : () => widget.onSelect(index),
          borderRadius: BorderRadius.circular(12),
          child: Opacity(
            opacity: isDisabled ? 0.4 : 1.0,
            child: Container(
              decoration: BoxDecoration(
                color: YageColors.backgroundLight,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: hasState
                      ? YageColors.primary.withAlpha(120)
                      : YageColors.surfaceLight,
                  width: hasState ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  // Screenshot thumbnail (GBA 3:2 aspect ratio)
                  ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(11),
                      bottomLeft: Radius.circular(11),
                    ),
                    child: SizedBox(
                      width: 96,
                      height: 64,
                      child: hasScreenshot
                          ? Image.file(
                              _screenshotFiles[index]!,
                              fit: BoxFit.cover,
                              cacheWidth: 192,
                              errorBuilder: (_, __, ___) =>
                                  _placeholderWidget(hasState),
                            )
                          : _placeholderWidget(hasState),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Slot info
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Slot ${index + 1}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: YageColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            hasState && timestamp != null
                                ? _formatTimestamp(timestamp)
                                : 'Empty',
                            style: TextStyle(
                              fontSize: 11,
                              color: hasState
                                  ? YageColors.textSecondary
                                  : YageColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Chevron indicator
                  if (!isDisabled)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Icon(
                        Icons.chevron_right,
                        color: YageColors.textMuted,
                        size: 20,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholderWidget(bool hasState) {
    return Container(
      color: YageColors.backgroundDark,
      child: Center(
        child: Icon(
          hasState ? Icons.image_outlined : Icons.add_photo_alternate_outlined,
          color: YageColors.textMuted.withAlpha(60),
          size: 24,
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime dt) {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour = dt.hour > 12
        ? dt.hour - 12
        : (dt.hour == 0 ? 12 : dt.hour);
    final amPm = dt.hour >= 12 ? 'PM' : 'AM';
    final minute = dt.minute.toString().padLeft(2, '0');
    return '${months[dt.month - 1]} ${dt.day}, $hour:$minute $amPm';
  }
}

class _MenuActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isPrimary;
  final bool isDestructive;
  final bool autofocus;

  const _MenuActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isPrimary = false,
    this.isDestructive = false,
    this.autofocus = false,
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

    return TvFocusable(
      onTap: onTap,
      autofocus: autofocus,
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
    );
  }
}

class _RewindButton extends StatelessWidget {
  final bool isActive;
  final void Function(bool held) onHoldChanged;

  const _RewindButton({
    required this.isActive,
    required this.onHoldChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => onHoldChanged(true),
      onTapUp: (_) => onHoldChanged(false),
      onTapCancel: () => onHoldChanged(false),
      child: Container(
        width: 44,
        height: 44,
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
        child: Icon(
          Icons.fast_rewind,
          color: isActive ? YageColors.backgroundDark : YageColors.textSecondary,
          size: 22,
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
                style: TextStyle(
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
  final double turboSpeed;
  final void Function(double speed) onSpeedChanged;

  const _SpeedSelector({
    required this.currentSpeed,
    required this.onSpeedChanged,
    this.turboSpeed = 2.0,
  });

  List<double> get speeds {
    // Build speed list: always include 0.5, 1.0, and the configured turbo speed
    final s = <double>{0.5, 1.0};
    // Add 2.0 if turbo is higher
    if (turboSpeed > 2.0) s.add(2.0);
    s.add(turboSpeed);
    // Add a higher step if turbo allows (e.g. 4x if turbo is 4+)
    if (turboSpeed >= 4.0 && turboSpeed > 4.0) s.add(4.0);
    final list = s.toList()..sort();
    return list;
  }

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
              Icon(Icons.speed, color: YageColors.textSecondary, size: 18),
              const SizedBox(width: 8),
              Text(
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
                style: TextStyle(
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
                        '${speed == speed.roundToDouble() ? speed.toStringAsFixed(0) : speed.toStringAsFixed(1)}x',
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

class _InputTypeSelector extends StatelessWidget {
  final bool useJoystick;
  final VoidCallback onChanged;

  const _InputTypeSelector({
    required this.useJoystick,
    required this.onChanged,
  });

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
              Icon(Icons.gamepad, color: YageColors.textSecondary, size: 18),
              const SizedBox(width: 8),
              Text(
                'Input Type',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: YageColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              // D-Pad option
              Expanded(
                child: GestureDetector(
                  onTap: useJoystick ? onChanged : null,
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: !useJoystick 
                          ? YageColors.primary 
                          : YageColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: !useJoystick 
                          ? null 
                          : Border.all(color: YageColors.surfaceLight),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.control_camera,
                          size: 18,
                          color: !useJoystick 
                              ? YageColors.textPrimary 
                              : YageColors.textMuted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'D-Pad',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: !useJoystick 
                                ? YageColors.textPrimary 
                                : YageColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Joystick option
              Expanded(
                child: GestureDetector(
                  onTap: !useJoystick ? onChanged : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: useJoystick 
                          ? YageColors.primary 
                          : YageColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: useJoystick 
                          ? null 
                          : Border.all(color: YageColors.surfaceLight),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.radio_button_checked,
                          size: 18,
                          color: useJoystick 
                              ? YageColors.textPrimary 
                              : YageColors.textMuted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Joystick',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: useJoystick 
                                ? YageColors.textPrimary 
                                : YageColors.textMuted,
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
