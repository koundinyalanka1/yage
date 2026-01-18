import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/game_rom.dart';
import '../services/emulator_service.dart';
import '../services/settings_service.dart';
import '../widgets/game_display.dart';
import '../widgets/virtual_gamepad.dart';
import '../utils/theme.dart';

/// Game playing screen
class GameScreen extends StatefulWidget {
  final GameRom game;

  const GameScreen({super.key, required this.game});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with WidgetsBindingObserver {
  bool _showControls = true;
  bool _showMenu = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    // Enter immersive mode
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
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
    SystemChrome.setPreferredOrientations([]);
    
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

  @override
  Widget build(BuildContext context) {
    final emulator = context.watch<EmulatorService>();
    final settings = context.watch<SettingsService>().settings;

    return Scaffold(
      backgroundColor: YageColors.backgroundDark,
      body: Stack(
        children: [
          // Background gradient
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
          
          // Game display
          Center(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: _showControls ? 160 : 40,
                vertical: 20,
              ),
              child: GameDisplay(
                emulator: emulator,
                maintainAspectRatio: settings.maintainAspectRatio,
                enableFiltering: settings.enableFiltering,
              ),
            ),
          ),
          
          // FPS overlay
          if (settings.showFps)
            FpsOverlay(fps: emulator.currentFps),
          
          // Virtual gamepad
          if (_showControls)
            Positioned.fill(
              child: VirtualGamepad(
                onKeysChanged: emulator.setKeys,
                opacity: settings.gamepadOpacity,
                scale: settings.gamepadScale,
                enableVibration: settings.enableVibration,
              ),
            ),
          
          // Menu button
          Positioned(
            top: 8,
            left: 8,
            child: _MenuButton(
              onTap: _toggleMenu,
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
                if (mounted) {
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
                if (mounted) {
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
                }
                if (success) _toggleMenu();
              },
              onToggleControls: () {
                setState(() => _showControls = !_showControls);
              },
              showControls: _showControls,
              onExit: _exitGame,
            ),
        ],
      ),
    );
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
          color: YageColors.surface.withOpacity(0.8),
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

class _InGameMenu extends StatelessWidget {
  final GameRom game;
  final VoidCallback onResume;
  final VoidCallback onReset;
  final void Function(int slot) onSaveState;
  final void Function(int slot) onLoadState;
  final VoidCallback onToggleControls;
  final bool showControls;
  final VoidCallback onExit;

  const _InGameMenu({
    required this.game,
    required this.onResume,
    required this.onReset,
    required this.onSaveState,
    required this.onLoadState,
    required this.onToggleControls,
    required this.showControls,
    required this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onResume,
      child: Container(
        color: Colors.black54,
        child: Center(
          child: GestureDetector(
            onTap: () {}, // Prevent tap through
            child: Container(
              width: 340,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: YageColors.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: YageColors.primary.withOpacity(0.3),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: YageColors.primary.withOpacity(0.2),
                    blurRadius: 30,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Title
                  Text(
                    'PAUSED',
                    style: const TextStyle(
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
                  const SizedBox(height: 24),
                  
                  // Resume button
                  _MenuActionButton(
                    icon: Icons.play_arrow,
                    label: 'Resume',
                    onTap: onResume,
                    isPrimary: true,
                  ),
                  const SizedBox(height: 12),
                  
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
                      const SizedBox(width: 12),
                      Expanded(
                        child: _MenuActionButton(
                          icon: Icons.upload_file,
                          label: 'Load State',
                          onTap: () => _showStateSlots(context, false),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  
                  // Other options
                  _MenuActionButton(
                    icon: showControls ? Icons.gamepad : Icons.gamepad_outlined,
                    label: showControls ? 'Hide Controls' : 'Show Controls',
                    onTap: onToggleControls,
                  ),
                  const SizedBox(height: 12),
                  
                  _MenuActionButton(
                    icon: Icons.refresh,
                    label: 'Reset',
                    onTap: onReset,
                  ),
                  const SizedBox(height: 12),
                  
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
            ? YageColors.error.withOpacity(0.2) 
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

