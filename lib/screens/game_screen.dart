import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/mgba_bindings.dart';
import '../models/game_rom.dart';
import '../models/game_frame.dart';
import '../models/gamepad_layout.dart';
import '../services/emulator_service.dart';
import '../services/game_library_service.dart';
import '../services/link_cable_service.dart';
import '../services/ra_runtime_service.dart';
import '../services/retro_achievements_service.dart';
import '../services/settings_service.dart';
import '../services/gamepad_input.dart';
import '../utils/tv_detector.dart';
import '../widgets/achievement_unlock_overlay.dart';
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

  // ── Hotkey combo system ──
  // Hold Select, then press another button for shortcut actions.
  // Releasing Select without a combo sends a normal GBA Select tap.
  bool _hotkeyHeld = false;
  bool _hotkeyComboUsed = false;

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
    
    // Start emulation, then show shortcuts help on first launch
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final emulator = context.read<EmulatorService>();
      // Wire link cable service to emulator
      emulator.linkCable = context.read<LinkCableService>();
      // Wire RA runtime for per-frame achievement processing
      emulator.raRuntime = context.read<RARuntimeService>();
      emulator.start();
      _maybeShowShortcutsHelp();

      // Detect RetroAchievements game ID in the background.
      // This does NOT block gameplay — achievements are enabled async.
      _detectRetroAchievements();
    });
  }

  @override
  void dispose() {
    try {
      WidgetsBinding.instance.removeObserver(this);
      _focusNode.dispose();

      // Disconnect link cable when leaving the game screen
      try {
        final lc = context.read<LinkCableService>();
        lc.disconnect();
        final emulator = context.read<EmulatorService>();
        emulator.linkCable = null;
        emulator.raRuntime = null;
      } catch (_) {}

      // Allow screen to sleep again
      WakelockPlus.disable();
    } finally {
      // System-level cleanup runs even if earlier dispose steps throw,
      // so orientation / system-UI changes never leak to other screens.
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }

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

  // ─────────────────────────────────────────────────────────────────────
  //  Key / gamepad input handling
  // ─────────────────────────────────────────────────────────────────────

  /// The gamepad button used as the hotkey modifier.  Hold this and press
  /// another button to trigger a shortcut.  If released without a combo,
  /// a normal GBA Select tap is sent so in-game Select still works.
  static const _hotkeyModifier = LogicalKeyboardKey.gameButtonSelect;

  /// Combo actions when [_hotkeyModifier] is held.
  static final _hotkeyActions = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.gameButtonStart:  'menu',        // Select+Start → pause menu
    LogicalKeyboardKey.gameButtonA:      'quickSave',   // Select+A     → quick save
    LogicalKeyboardKey.gameButtonB:      'quickLoad',   // Select+B     → quick load
    LogicalKeyboardKey.gameButtonRight1: 'fastForward', // Select+R1    → fast forward
  };

  /// Back / Escape — opens menu during gameplay, closes it when shown.
  /// These are TV-remote / keyboard keys that never conflict with GBA.
  static final _backKeys = {
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.goBack,
  };

  /// Keyboard-only shortcuts (no gamepad conflict).
  static final _keyboardShortcuts = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.f1:  'menu',
    LogicalKeyboardKey.f5:  'quickSave',
    LogicalKeyboardKey.f9:  'quickLoad',
    LogicalKeyboardKey.tab: 'fastForward',
  };

  void _executeShortcutAction(String action) {
    switch (action) {
      case 'menu':
        _toggleMenu();
      case 'quickSave':
        _doQuickSave();
      case 'quickLoad':
        _doQuickLoad();
      case 'fastForward':
        final raRuntime = context.read<RARuntimeService>();
        final blocked = raRuntime.checkAction('fastForward');
        if (blocked != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(blocked),
              duration: const Duration(seconds: 2),
            ),
          );
          return;
        }
        context.read<EmulatorService>().toggleFastForward();
    }
  }

  /// When Select is released without triggering any combo, briefly send
  /// a GBA Select press so the button still works for in-game menus.
  void _simulateSelectTap() {
    _physicalKeys |= GBAKey.select;
    _syncKeys();
    Future.delayed(const Duration(milliseconds: 50), () {
      if (mounted) {
        _physicalKeys &= ~GBAKey.select;
        _syncKeys();
      }
    });
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final settings = context.read<SettingsService>().settings;
    if (!settings.enableExternalGamepad) return KeyEventResult.ignored;

    // ── Hotkey modifier (Select button) ──────────────────────────────
    if (event.logicalKey == _hotkeyModifier) {
      if (event is KeyDownEvent) {
        _hotkeyHeld = true;
        _hotkeyComboUsed = false;
        return KeyEventResult.handled; // suppress GBA Select
      }
      if (event is KeyUpEvent) {
        _hotkeyHeld = false;
        if (!_hotkeyComboUsed && !_showMenu && !_editingLayout) {
          // No combo was triggered — treat as a normal GBA Select tap
          _simulateSelectTap();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled; // suppress repeats
    }

    // ── Hotkey combos: Select + button ───────────────────────────────
    if (_hotkeyHeld && event is KeyDownEvent) {
      final action = _hotkeyActions[event.logicalKey];
      if (action != null) {
        _hotkeyComboUsed = true;
        _executeShortcutAction(action);
        return KeyEventResult.handled;
      }
    }

    // ── Back / Escape: open menu during gameplay, close it when shown ─
    if (event is KeyDownEvent && _backKeys.contains(event.logicalKey)) {
      if (_showMenu) {
        _toggleMenu();
        return KeyEventResult.handled;
      } else if (!_editingLayout) {
        _toggleMenu();
        return KeyEventResult.handled;
      }
    }

    // ── While the pause menu is shown, let it handle its own D-pad ───
    if (_showMenu || _editingLayout) return KeyEventResult.ignored;

    // ── Keyboard-only shortcuts (F1, F5, F9, Tab) ────────────────────
    if (event is KeyDownEvent) {
      final action = _keyboardShortcuts[event.logicalKey];
      if (action != null) {
        _executeShortcutAction(action);
        return KeyEventResult.handled;
      }
    }

    // ── Pass remaining keys to the GBA gamepad mapper ────────────────
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

  /// Detect RetroAchievements game ID for the loaded ROM,
  /// then activate the RA runtime for per-frame achievement processing.
  ///
  /// Skipped entirely when RetroAchievements is disabled in settings.
  /// Runs asynchronously in the background so gameplay is never blocked.
  /// On success, [RetroAchievementsService.activeSession] is populated
  /// and the RA runtime is activated with mode enforcement enabled.
  /// On failure, achievements are silently disabled for this game.
  Future<void> _detectRetroAchievements() async {
    final settings = context.read<SettingsService>().settings;
    if (!settings.raEnabled) {
      debugPrint('RA: RetroAchievements disabled in settings — skipping');
      return;
    }

    final raService = context.read<RetroAchievementsService>();
    await raService.startGameSession(widget.game);

    if (!mounted) return;

    final raRuntime = context.read<RARuntimeService>();

    await raRuntime.activate(
      hardcoreMode: settings.raHardcoreMode,
    );
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
    if (held) {
      // Block rewind in Hardcore mode
      final raRuntime = context.read<RARuntimeService>();
      final blocked = raRuntime.checkAction('rewind');
      if (blocked != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(blocked),
            duration: const Duration(seconds: 2),
          ),
        );
        return;
      }
      context.read<EmulatorService>().startRewind();
    } else {
      context.read<EmulatorService>().stopRewind();
    }
  }

  /// Quick-save to slot 0 and show feedback.
  /// Blocked in Hardcore mode.
  Future<void> _doQuickSave() async {
    final raRuntime = context.read<RARuntimeService>();
    final blocked = raRuntime.checkAction('saveState');
    if (blocked != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(blocked),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    final emulator = context.read<EmulatorService>();
    final success = await emulator.saveState(0);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? 'Quick saved (slot 1)' : 'Quick save failed'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  /// Quick-load from slot 0 and show feedback.
  /// Blocked in Hardcore mode.
  Future<void> _doQuickLoad() async {
    final raRuntime = context.read<RARuntimeService>();
    final blocked = raRuntime.checkAction('loadState');
    if (blocked != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(blocked),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    final emulator = context.read<EmulatorService>();
    final success = await emulator.loadState(0);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? 'Quick loaded (slot 1)' : 'Quick load failed'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  /// Show the shortcuts help dialog once on the second game launch.
  /// On the first launch the user should just enjoy the game; the dialog
  /// is always available from the in-game menu anyway.
  Future<void> _maybeShowShortcutsHelp() async {
    final settingsService = context.read<SettingsService>();
    await settingsService.incrementGameLaunchCount();
    final alreadyShown = await settingsService.isShortcutsHelpShown();
    if (alreadyShown) return;

    final launchCount = await settingsService.getGameLaunchCount();
    if (launchCount >= 2 && mounted) {
      // Pause briefly so the game loads visually before the overlay appears
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      await _showShortcutsHelp();
      await settingsService.markShortcutsHelpShown();
    }
  }

  /// Display the shortcuts reference dialog.
  Future<void> _showShortcutsHelp() {
    final emulator = context.read<EmulatorService>();
    final wasRunning = emulator.state == EmulatorState.running;
    if (wasRunning) emulator.pause();

    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => const _ShortcutsHelpDialog(),
    ).then((_) {
      if (mounted && wasRunning && !_showMenu) {
        emulator.start();
        _focusNode.requestFocus();
      }
    });
  }

  void _exitGame() {
    final emulator = context.read<EmulatorService>();
    _flushPlayTime();
    emulator.stop();

    // Deactivate the RA runtime and end the session
    context.read<RARuntimeService>().deactivate();
    context.read<RetroAchievementsService>().endGameSession();

    Navigator.of(context).pop();
  }

  Future<bool> _showExitDialog() async {
    final emulator = context.read<EmulatorService>();
    final wasRunning = emulator.state == EmulatorState.running;
    
    // Pause while showing dialog
    if (wasRunning) {
      emulator.pause();
    }
    
    final result = await showDialog<bool>(
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
          'Your battery save data will be preserved.',
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
    
    if (result == true) {
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

  void _showLinkCableDialog() {
    final emulator = context.read<EmulatorService>();
    final linkCable = context.read<LinkCableService>();

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => _LinkCableDialog(
        game: widget.game,
        linkCable: linkCable,
        isSupported: emulator.isLinkSupported,
      ),
    );
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
              
              // Link cable connection indicator
              if (context.watch<LinkCableService>().state == LinkCableState.connected)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 4,
                  right: _isLandscape 
                      ? MediaQuery.of(context).size.width * 0.12 + 100
                      : 104,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.green.withAlpha(160),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.cable, size: 12, color: Colors.white),
                        SizedBox(width: 3),
                        Text(
                          'LINKED',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
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

              // Hardcore mode indicator
              if (settings.raEnabled && context.watch<RARuntimeService>().isHardcore)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 8,
                  left: emulator.isUsingStub ? 150 : 60,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withAlpha(200),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.emoji_events, size: 10, color: Colors.white),
                        SizedBox(width: 3),
                        Text(
                          'HARDCORE',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Achievement unlock toast overlay
              if (settings.raEnabled && settings.raNotificationsEnabled)
                AchievementUnlockOverlay(
                  runtimeService: context.watch<RARuntimeService>(),
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
                    onTap: () {
                      final raRuntime = context.read<RARuntimeService>();
                      final blocked = raRuntime.checkAction('fastForward');
                      if (blocked != null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(blocked),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                        return;
                      }
                      emulator.toggleFastForward();
                    },
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
                    // Enforce hardcore mode
                    final raRuntime = context.read<RARuntimeService>();
                    final blocked = raRuntime.checkAction('saveState');
                    if (blocked != null) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(blocked),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                      return;
                    }
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
                    // Enforce hardcore mode
                    final raRuntime = context.read<RARuntimeService>();
                    final blocked = raRuntime.checkAction('loadState');
                    if (blocked != null) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(blocked),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                      return;
                    }
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
                  onShowShortcuts: () {
                    _toggleMenu(); // close menu first
                    _showShortcutsHelp();
                  },
                  onLinkCable: () {
                    _showLinkCableDialog();
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
  final VoidCallback onShowShortcuts;
  final VoidCallback onLinkCable;

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
    required this.onShowShortcuts,
    required this.onLinkCable,
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
                      icon: Icons.cable,
                      label: 'Link Cable',
                      onTap: onLinkCable,
                    ),
                    const SizedBox(height: 10),

                    _MenuActionButton(
                      icon: Icons.keyboard,
                      label: 'Shortcuts',
                      onTap: onShowShortcuts,
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
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSlotInfo();
  }

  Future<void> _loadSlotInfo() async {
    final hasState = <int, bool>{};
    final screenshotFiles = <int, File?>{};
    final timestamps = <int, DateTime?>{};

    for (int i = 0; i < 6; i++) {
      final statePath = widget.emulator.getStatePath(i);
      final ssPath = widget.emulator.getStateScreenshotPath(i);

      if (statePath != null) {
        final stateFile = File(statePath);
        if (await stateFile.exists()) {
          hasState[i] = true;
          timestamps[i] = await stateFile.lastModified();
        }
      }

      if (ssPath != null) {
        final ssFile = File(ssPath);
        if (await ssFile.exists()) {
          screenshotFiles[i] = ssFile;
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _hasState.addAll(hasState);
      _screenshotFiles.addAll(screenshotFiles);
      _timestamps.addAll(timestamps);
      _isLoading = false;
    });
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
        child: _isLoading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
              )
            : Column(
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
      child: TvFocusable(
        autofocus: index == 0,
        onTap: isDisabled ? null : () => widget.onSelect(index),
        borderRadius: BorderRadius.circular(12),
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
                child: TvFocusable(
                  onTap: () => onSpeedChanged(speed),
                  borderRadius: BorderRadius.circular(8),
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

// ═══════════════════════════════════════════════════════════════════════
//  Shortcuts help dialog
// ═══════════════════════════════════════════════════════════════════════

class _ShortcutsHelpDialog extends StatelessWidget {
  const _ShortcutsHelpDialog();

  void _dismiss(BuildContext context) {
    if (Navigator.of(context).canPop()) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Wrap in Focus so ANY key press (gamepad, remote, keyboard) dismisses it.
    // Also wrap in GestureDetector so tapping anywhere outside the card works.
    return Focus(
      autofocus: true,
      onKeyEvent: (_, __) {
        _dismiss(context);
        return KeyEventResult.handled;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _dismiss(context),
        child: AlertDialog(
          backgroundColor: YageColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: YageColors.accent.withAlpha(100),
              width: 2,
            ),
          ),
          contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          title: Row(
            children: [
              Icon(Icons.keyboard, color: YageColors.accent, size: 22),
              const SizedBox(width: 10),
              Text(
                'Shortcuts',
                style: TextStyle(
                  color: YageColors.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 340,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sectionHeader(Icons.gamepad, 'Gamepad combos  (hold Select +)'),
                  _shortcutRow('Select + Start', 'Pause menu'),
                  _shortcutRow('Select + A', 'Quick save (slot 1)'),
                  _shortcutRow('Select + B', 'Quick load (slot 1)'),
                  _shortcutRow('Select + R1', 'Fast forward'),
                  _shortcutRow('Select (tap)', 'GBA Select button'),
                  const SizedBox(height: 14),
                  _sectionHeader(Icons.keyboard_alt_outlined, 'Keyboard'),
                  _shortcutRow('F1', 'Pause menu'),
                  _shortcutRow('F5', 'Quick save (slot 1)'),
                  _shortcutRow('F9', 'Quick load (slot 1)'),
                  _shortcutRow('Tab', 'Fast forward'),
                  _shortcutRow('Esc', 'Toggle pause menu'),
                  const SizedBox(height: 14),
                  _sectionHeader(Icons.tv, 'TV / Remote'),
                  _shortcutRow('Back', 'Pause menu'),
                  _shortcutRow('L1 / R1', 'Switch tabs (home)'),
                  const SizedBox(height: 8),
                  Divider(color: YageColors.surfaceLight),
                  const SizedBox(height: 4),
                  Text(
                    'Press any button to dismiss.  '
                    'Open anytime from pause menu → Shortcuts.',
                    style: TextStyle(
                      fontSize: 11,
                      color: YageColors.textMuted,
                      fontStyle: FontStyle.italic,
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

  Widget _sectionHeader(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, color: YageColors.accent.withAlpha(180), size: 16),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: YageColors.accent,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _shortcutRow(String keys, String action) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: YageColors.backgroundLight,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: YageColors.surfaceLight),
            ),
            child: Text(
              keys,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
                color: YageColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              action,
              style: TextStyle(
                fontSize: 12,
                color: YageColors.textSecondary,
              ),
            ),
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
                child: TvFocusable(
                  onTap: useJoystick ? onChanged : null,
                  borderRadius: BorderRadius.circular(8),
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
                child: TvFocusable(
                  onTap: !useJoystick ? onChanged : null,
                  borderRadius: BorderRadius.circular(8),
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

// ═══════════════════════════════════════════════════════════════
// Link Cable Dialog
// ═══════════════════════════════════════════════════════════════

class _LinkCableDialog extends StatefulWidget {
  final GameRom game;
  final LinkCableService linkCable;
  final bool isSupported;

  const _LinkCableDialog({
    required this.game,
    required this.linkCable,
    required this.isSupported,
  });

  @override
  State<_LinkCableDialog> createState() => _LinkCableDialogState();
}

class _LinkCableDialogState extends State<_LinkCableDialog> {
  final TextEditingController _ipController = TextEditingController();
  List<String> _localIPs = [];
  bool _isBusy = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    widget.linkCable.addListener(_onLinkStateChanged);
    _loadLocalIPs();
  }

  @override
  void dispose() {
    widget.linkCable.removeListener(_onLinkStateChanged);
    _ipController.dispose();
    super.dispose();
  }

  void _onLinkStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadLocalIPs() async {
    final ips = await widget.linkCable.getLocalIPs();
    if (mounted) {
      setState(() => _localIPs = ips);
    }
  }

  Future<void> _host() async {
    setState(() {
      _isBusy = true;
      _statusMessage = 'Starting server...';
    });

    final hash = await LinkCableService.computeRomHash(widget.game.path);
    final ok = await widget.linkCable.host(romHash: hash);

    if (mounted) {
      setState(() {
        _isBusy = false;
        _statusMessage = ok ? 'Waiting for player 2...' : widget.linkCable.error;
      });
    }
  }

  Future<void> _join() async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) {
      setState(() => _statusMessage = 'Enter the host\'s IP address');
      return;
    }

    setState(() {
      _isBusy = true;
      _statusMessage = 'Connecting to $ip...';
    });

    final hash = await LinkCableService.computeRomHash(widget.game.path);
    final ok = await widget.linkCable.join(hostAddress: ip, romHash: hash);

    if (mounted) {
      setState(() {
        _isBusy = false;
        _statusMessage = ok ? null : widget.linkCable.error;
      });
    }
  }

  Future<void> _disconnect() async {
    await widget.linkCable.disconnect();
    if (mounted) {
      setState(() => _statusMessage = 'Disconnected');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.linkCable.state;
    final isConnected = state == LinkCableState.connected;

    return AlertDialog(
      backgroundColor: YageColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: YageColors.primary.withAlpha(77),
          width: 2,
        ),
      ),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      title: Row(
        children: [
          Icon(Icons.cable, color: YageColors.accent, size: 22),
          const SizedBox(width: 10),
          Text(
            'Link Cable',
            style: TextStyle(
              color: YageColors.textPrimary,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
          const Spacer(),
          if (isConnected)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.green.withAlpha(40),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8, height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${widget.linkCable.latencyMs}ms',
                    style: const TextStyle(
                      color: Colors.green,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status / error message
            if (_statusMessage != null || widget.linkCable.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  widget.linkCable.error ?? _statusMessage ?? '',
                  style: TextStyle(
                    color: widget.linkCable.error != null
                        ? YageColors.error
                        : YageColors.accent,
                    fontSize: 13,
                  ),
                ),
              ),

            if (isConnected) ...[
              _buildConnectedView(),
            ] else if (state == LinkCableState.hosting) ...[
              _buildHostingView(),
            ] else if (state == LinkCableState.joining) ...[
              _buildJoiningView(),
            ] else ...[
              _buildDisconnectedView(),
            ],
          ],
        ),
      ),
      actions: [
        if (isConnected || state == LinkCableState.hosting)
          TextButton(
            onPressed: _isBusy ? null : _disconnect,
            child: Text(
              'Disconnect',
              style: TextStyle(color: YageColors.error),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            isConnected ? 'Done' : 'Close',
            style: TextStyle(color: YageColors.textMuted),
          ),
        ),
      ],
    );
  }

  Widget _buildDisconnectedView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Connect two devices over Wi-Fi to trade, battle, or play '
          'multiplayer games using the virtual link cable.',
          style: TextStyle(
            color: YageColors.textSecondary,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 16),

        // Host button
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _isBusy ? null : _host,
            icon: const Icon(Icons.wifi_tethering, size: 18),
            label: const Text('Host Game'),
            style: ElevatedButton.styleFrom(
              backgroundColor: YageColors.primary,
              foregroundColor: YageColors.textPrimary,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // OR divider
        Row(
          children: [
            Expanded(child: Divider(color: YageColors.surfaceLight)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('OR',
                style: TextStyle(color: YageColors.textMuted, fontSize: 12),
              ),
            ),
            Expanded(child: Divider(color: YageColors.surfaceLight)),
          ],
        ),
        const SizedBox(height: 12),

        // Join section
        TextField(
          controller: _ipController,
          style: TextStyle(color: YageColors.textPrimary),
          decoration: InputDecoration(
            hintText: 'Host IP address (e.g. 192.168.1.5)',
            hintStyle: TextStyle(color: YageColors.textMuted, fontSize: 13),
            filled: true,
            fillColor: YageColors.backgroundLight,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 12,
            ),
          ),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _isBusy ? null : _join,
            icon: const Icon(Icons.link, size: 18),
            label: const Text('Join Game'),
            style: ElevatedButton.styleFrom(
              backgroundColor: YageColors.accent,
              foregroundColor: YageColors.textPrimary,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildHostingView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Your IP Address:',
          style: TextStyle(color: YageColors.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 6),
        for (final ip in _localIPs)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: YageColors.backgroundLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                '$ip : ${LinkCableService.defaultPort}',
                style: TextStyle(
                  color: YageColors.accent,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        if (_localIPs.isEmpty)
          Text(
            'Unable to detect IP address',
            style: TextStyle(color: YageColors.error, fontSize: 13),
          ),
        const SizedBox(height: 12),
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2, color: YageColors.accent,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Waiting for player 2 to join...',
                style: TextStyle(color: YageColors.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildJoiningView() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Column(
          children: [
            SizedBox(
              width: 24, height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5, color: YageColors.accent,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Connecting...',
              style: TextStyle(color: YageColors.textSecondary, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectedView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.green.withAlpha(20),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.green.withAlpha(60)),
          ),
          child: Column(
            children: [
              const Icon(Icons.link, color: Colors.green, size: 32),
              const SizedBox(height: 8),
              Text(
                'Link Cable Connected',
                style: TextStyle(
                  color: Colors.green.shade300,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Connected to ${widget.linkCable.peerAddress}',
                style: TextStyle(color: YageColors.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Resume the game to use link cable features like trading and battling.',
          style: TextStyle(color: YageColors.textSecondary, fontSize: 13),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
