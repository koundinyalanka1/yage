import 'dart:io';

import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';

import '../models/emulator_settings.dart';
import '../models/game_frame.dart';
import '../models/game_rom.dart';
import '../models/gamepad_skin.dart';
import '../services/settings_service.dart';
import '../services/game_library_service.dart';
import '../services/emulator_service.dart';
import '../services/retro_achievements_service.dart';
import '../services/save_backup_service.dart';
import '../utils/theme.dart';
import '../widgets/tv_focusable.dart';
import 'ra_login_screen.dart';

/// Settings screen
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Consumer<SettingsService>(
        builder: (context, settingsService, _) {
          final settings = settingsService.settings;
          
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ── Quick Settings (always visible, most-used controls) ──
              _SectionHeader(title: 'Quick Settings'),
              _SettingsCard(
                children: [
                  _SliderTile(
                    icon: Icons.volume_down,
                    title: 'Volume',
                    value: settings.volume,
                    onChanged: settingsService.setVolume,
                  ),
                  const Divider(height: 1),
                  _SliderTile(
                    icon: Icons.opacity,
                    title: 'Gamepad Opacity',
                    value: settings.gamepadOpacity,
                    min: 0.1,
                    max: 1.0,
                    onChanged: settingsService.setGamepadOpacity,
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // ── Theme (collapsible) ──
              _CollapsibleSection(
                title: 'Theme',
                icon: Icons.color_lens,
                initiallyExpanded: false,
                child: _ThemePicker(
                  selectedThemeId: settings.selectedTheme,
                  onChanged: settingsService.setAppTheme,
                ),
              ),

              const SizedBox(height: 12),

              // ── Audio (collapsible) ──
              _CollapsibleSection(
                title: 'Audio',
                icon: Icons.volume_up,
                child: _SettingsCard(
                  children: [
                    _SwitchTile(
                      icon: Icons.volume_up,
                      title: 'Enable Sound',
                      subtitle: 'Play game audio',
                      value: settings.enableSound,
                      onChanged: (_) => settingsService.toggleSound(),
                    ),
                    if (settings.enableSound) ...[
                      const Divider(height: 1),
                      _SliderTile(
                        icon: Icons.volume_down,
                        title: 'Volume',
                        value: settings.volume,
                        onChanged: settingsService.setVolume,
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // ── Display (collapsible) ──
              _CollapsibleSection(
                title: 'Display',
                icon: Icons.display_settings,
                child: _SettingsCard(
                  children: [
                    _SwitchTile(
                      icon: Icons.speed,
                      title: 'Show FPS',
                      subtitle: 'Display frame rate counter',
                      value: settings.showFps,
                      onChanged: (_) => settingsService.toggleShowFps(),
                    ),
                    const Divider(height: 1),
                    _SwitchTile(
                      icon: Icons.aspect_ratio,
                      title: 'Maintain Aspect Ratio',
                      subtitle: 'Keep original game proportions',
                      value: settings.maintainAspectRatio,
                      onChanged: (_) => settingsService.toggleAspectRatio(),
                    ),
                    const Divider(height: 1),
                    _SwitchTile(
                      icon: Icons.blur_on,
                      title: 'Smooth Scaling',
                      subtitle: 'ON = smooth, modern look · OFF = crisp, pixelated retro look',
                      value: settings.enableFiltering,
                      onChanged: (_) => settingsService.toggleFiltering(),
                    ),
                    const Divider(height: 1),
                    _PaletteTile(
                      selectedIndex: settings.selectedColorPalette,
                      onChanged: settingsService.setColorPalette,
                    ),
                    const Divider(height: 1),
                    _GameFrameTile(
                      selected: settings.gameFrame,
                      onChanged: settingsService.setGameFrame,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // ── Controls (collapsible) ──
              _CollapsibleSection(
                title: 'Controls',
                icon: Icons.sports_esports,
                child: _SettingsCard(
                  children: [
                    _SwitchTile(
                      icon: Icons.vibration,
                      title: 'Haptic Feedback',
                      subtitle: 'Vibrate on button press',
                      value: settings.enableVibration,
                      onChanged: (_) => settingsService.toggleVibration(),
                    ),
                    const Divider(height: 1),
                    _SliderTile(
                      icon: Icons.opacity,
                      title: 'Gamepad Opacity',
                      value: settings.gamepadOpacity,
                      min: 0.1,
                      max: 1.0,
                      onChanged: settingsService.setGamepadOpacity,
                    ),
                    const Divider(height: 1),
                    _SliderTile(
                      icon: Icons.zoom_in,
                      title: 'Gamepad Scale',
                      value: settings.gamepadScale,
                      min: 0.5,
                      max: 2.0,
                      onChanged: settingsService.setGamepadScale,
                    ),
                    const Divider(height: 1),
                    _SwitchTile(
                      icon: Icons.sports_esports,
                      title: 'External Controller',
                      subtitle: 'Bluetooth / USB gamepad & keyboard',
                      value: settings.enableExternalGamepad,
                      onChanged: (_) => settingsService.toggleExternalGamepad(),
                    ),
                    const Divider(height: 1),
                    _GamepadSkinTile(
                      selected: settings.gamepadSkin,
                      onChanged: settingsService.setGamepadSkin,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // ── Emulation (collapsible) ──
              _CollapsibleSection(
                title: 'Emulation',
                icon: Icons.memory,
                child: _SettingsCard(
                  children: [
                    _SwitchTile(
                      icon: Icons.fast_forward,
                      title: 'Turbo Mode',
                      subtitle: 'Fast forward emulation',
                      value: settings.enableTurbo,
                      onChanged: (_) => settingsService.toggleTurbo(),
                    ),
                    if (settings.enableTurbo) ...[
                      const Divider(height: 1),
                      _SliderTile(
                        icon: Icons.speed,
                        title: 'Turbo Speed',
                        value: settings.turboSpeed,
                        min: 1.5,
                        max: 8.0,
                        divisions: 13,
                        labelSuffix: 'x',
                        onChanged: settingsService.setTurboSpeed,
                      ),
                    ],
                    const Divider(height: 1),
                    _SwitchTile(
                      icon: Icons.fast_rewind,
                      title: 'Rewind',
                      subtitle: 'Hold button to step backward in time',
                      value: settings.enableRewind,
                      onChanged: (_) => settingsService.toggleRewind(),
                    ),
                    if (settings.enableRewind) ...[
                      const Divider(height: 1),
                      _SliderTile(
                        icon: Icons.timelapse,
                        title: 'Rewind Buffer',
                        value: settings.rewindBufferSeconds.toDouble(),
                        min: 1.0,
                        max: 10.0,
                        divisions: 9,
                        labelSuffix: 's',
                        onChanged: (v) =>
                            settingsService.setRewindBufferSeconds(v.round()),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // ── Library (collapsible) ──
              _CollapsibleSection(
                title: 'Library',
                icon: Icons.library_books,
                initiallyExpanded: false,
                child: _SettingsCard(
                  children: [
                    _ActionTile(
                      icon: Icons.folder,
                      title: 'Manage ROM Folders',
                      onTap: () => _showRomFolders(context),
                    ),
                    const Divider(height: 1),
                    _ActionTile(
                      icon: Icons.refresh,
                      title: 'Refresh Library',
                      onTap: () {
                        context.read<GameLibraryService>().refresh();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Refreshing library...')),
                        );
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // ── Backup & Restore (collapsible) ──
              _CollapsibleSection(
                title: 'Backup & Restore',
                icon: Icons.backup,
                initiallyExpanded: false,
                child: _SettingsCard(
                  children: [
                    _ActionTile(
                      icon: Icons.upload_file,
                      title: 'Export All Saves to ZIP',
                      onTap: () => _exportAllSaves(context),
                    ),
                    const Divider(height: 1),
                    _ActionTile(
                      icon: Icons.download,
                      title: 'Import Saves from ZIP',
                      onTap: () => _importSaves(context),
                    ),
                    const Divider(height: 1),
                    _ActionTile(
                      icon: Icons.cloud_upload,
                      title: 'Backup to Google Drive',
                      onTap: () => _backupToDrive(context),
                    ),
                    const Divider(height: 1),
                    _ActionTile(
                      icon: Icons.cloud_download,
                      title: 'Restore from Google Drive',
                      onTap: () => _restoreFromDrive(context),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // ── RetroAchievements (collapsible) ──
              _CollapsibleSection(
                title: 'RetroAchievements',
                icon: Icons.emoji_events,
                initiallyExpanded: false,
                child: Column(
                  children: [
                    // Master enable/disable toggle
                    _SettingsCard(
                      children: [
                        _SwitchTile(
                          icon: Icons.emoji_events,
                          title: 'Enable RetroAchievements',
                          subtitle: 'Track and earn achievements while playing',
                          value: settings.raEnabled,
                          onChanged: (_) => settingsService.toggleRA(),
                        ),
                      ],
                    ),
                    // Everything below is gated on raEnabled
                    if (settings.raEnabled) ...[
                      const SizedBox(height: 8),
                      _RetroAchievementsTile(),
                      // Show mode/notification settings only when logged in
                      Consumer<RetroAchievementsService>(
                        builder: (context, raService, _) {
                          if (!raService.isLoggedIn) return const SizedBox.shrink();
                          return Column(
                            children: [
                              const SizedBox(height: 8),
                              _SettingsCard(
                                children: [
                                  _SwitchTile(
                                    icon: Icons.shield,
                                    title: 'Hardcore Mode',
                                    subtitle: 'Disable savestates, cheats, rewind, and fast-forward',
                                    value: settings.raHardcoreMode,
                                    onChanged: (_) => settingsService.toggleRAHardcoreMode(),
                                  ),
                                  const Divider(height: 1),
                                  _SwitchTile(
                                    icon: Icons.notifications_active,
                                    title: 'Unlock Notifications',
                                    subtitle: 'Show on-screen toast when achievements unlock',
                                    value: settings.raNotificationsEnabled,
                                    onChanged: (_) => settingsService.toggleRANotifications(),
                                  ),
                                  const Divider(height: 1),
                                  _ActionTile(
                                    icon: Icons.key,
                                    title: 'Change API Key',
                                    onTap: () async {
                                      await raService.logout();
                                      if (context.mounted) {
                                        Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => const RALoginScreen(),
                                          ),
                                        );
                                      }
                                    },
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      // Disclosure
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 14,
                              color: YageColors.textMuted,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Uses RetroAchievements. Passwords are never shared. '
                                'Only your username and Web API key are stored securely on-device.',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: YageColors.textMuted,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // ── About (collapsible) ──
              _CollapsibleSection(
                title: 'About',
                icon: Icons.info_outline,
                initiallyExpanded: false,
                child: _SettingsCard(
                  children: [
                    _InfoTile(
                      icon: Icons.info_outline,
                      title: 'RetroPal',
                      subtitle: 'Classic GB/GBC/GBA Games\nVersion 0.1.0',
                    ),
                    const Divider(height: 1),
                    _ActionTile(
                      icon: Icons.restore,
                      title: 'Reset to Defaults',
                      onTap: () => _confirmReset(context),
                      isDestructive: true,
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  void _showRomFolders(BuildContext context) {
    final library = context.read<GameLibraryService>();
    
    showModalBottomSheet(
      context: context,
      backgroundColor: YageColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: YageColors.surfaceLight,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'ROM Folders',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: YageColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  if (library.romDirectories.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'No folders added yet',
                        style: TextStyle(color: YageColors.textMuted),
                      ),
                    )
                  else
                    ListView.builder(
                      shrinkWrap: true,
                      itemCount: library.romDirectories.length,
                      itemBuilder: (context, index) {
                        final dir = library.romDirectories[index];
                        return ListTile(
                          leading: Icon(Icons.folder, color: YageColors.accent),
                          title: Text(
                            dir.split(RegExp(r'[/\\]')).last,
                            style: TextStyle(color: YageColors.textPrimary),
                          ),
                          subtitle: Text(
                            dir,
                            style: TextStyle(
                              fontSize: 11,
                              color: YageColors.textMuted,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            icon: Icon(Icons.delete, color: YageColors.error),
                            onPressed: () {
                              library.removeRomDirectory(dir);
                              setState(() {});
                            },
                          ),
                        );
                      },
                    ),
                  
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final result = await FilePicker.platform.getDirectoryPath();
                        if (result != null) {
                          await library.addRomDirectory(result);
                          setState(() {});
                        }
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('Add Folder'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _confirmReset(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: YageColors.surface,
        title: Text(
          'Reset Settings?',
          style: TextStyle(
            color: YageColors.textPrimary,
          ),
        ),
        content: Text(
          'This will reset all settings to their default values.',
          style: TextStyle(color: YageColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              context.read<SettingsService>().resetToDefaults();
              Navigator.pop(context);
            },
            child: Text(
              'Reset',
              style: TextStyle(color: YageColors.error),
            ),
          ),
        ],
      ),
    );
  }

  void _exportAllSaves(BuildContext context) async {
    final library = context.read<GameLibraryService>();
    final emulator = context.read<EmulatorService>();
    final games = library.games;

    if (games.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No games in library to export')),
      );
      return;
    }

    // Show progress dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _BackupProgressDialog(
        title: 'Exporting Saves',
        games: games,
        appSaveDir: emulator.saveDir,
      ),
    );
  }

  void _importSaves(BuildContext context) async {
    final library = context.read<GameLibraryService>();
    final games = library.games;

    if (games.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add games to library first before importing saves')),
      );
      return;
    }

    try {
      final count = await SaveBackupService.importFromZipPicker(games: games);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            count > 0
                ? 'Restored $count save file${count == 1 ? '' : 's'}'
                : 'No matching save files found in ZIP',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    }
  }

  void _backupToDrive(BuildContext context) async {
    final library = context.read<GameLibraryService>();
    final emulator = context.read<EmulatorService>();
    final games = library.games;

    if (games.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No games in library to backup')),
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _DriveBackupDialog(
        games: games,
        appSaveDir: emulator.saveDir,
      ),
    );
  }

  void _restoreFromDrive(BuildContext context) async {
    final library = context.read<GameLibraryService>();

    if (library.games.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add games to library first before restoring')),
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _DriveRestoreDialog(games: library.games),
    );
  }
}

/// Collapsible accordion section for grouping related settings.
class _CollapsibleSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool initiallyExpanded;
  final Widget child;

  const _CollapsibleSection({
    required this.title,
    required this.icon,
    this.initiallyExpanded = false,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: YageColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: YageColors.surfaceLight,
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // Remove the default divider line that ExpansionTile adds
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding: EdgeInsets.zero,
          leading: Icon(icon, color: YageColors.accent, size: 22),
          title: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: YageColors.primary,
              letterSpacing: 1.5,
            ),
          ),
          iconColor: YageColors.textMuted,
          collapsedIconColor: YageColors.textMuted,
          children: [
            Divider(height: 1, color: YageColors.surfaceLight),
            child,
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: YageColors.primary,
          letterSpacing: 2,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final List<Widget> children;

  const _SettingsCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: YageColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: YageColors.surfaceLight,
          width: 1,
        ),
      ),
      child: Column(
        children: children,
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: YageColors.accent),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          color: YageColors.textPrimary,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontSize: 12,
          color: YageColors.textMuted,
        ),
      ),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String labelSuffix;
  final ValueChanged<double> onChanged;

  const _SliderTile({
    required this.icon,
    required this.title,
    required this.value,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.labelSuffix = '',
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: YageColors.accent, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    color: YageColors.textPrimary,
                  ),
                ),
              ),
              Text(
                '${value.toStringAsFixed(1)}$labelSuffix',
                style: TextStyle(
                  fontSize: 12,
                  color: YageColors.accent,
                ),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool isDestructive;

  const _ActionTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        icon,
        color: isDestructive ? YageColors.error : YageColors.accent,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          color: isDestructive ? YageColors.error : YageColors.textPrimary,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right,
        color: YageColors.textMuted,
      ),
      onTap: onTap,
    );
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _InfoTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: YageColors.accent),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: YageColors.textPrimary,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontSize: 12,
          color: YageColors.textMuted,
        ),
      ),
    );
  }
}

class _PaletteTile extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  const _PaletteTile({
    required this.selectedIndex,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.palette, color: YageColors.accent, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'GB Color Palette',
                      style: TextStyle(
                        fontSize: 14,
                        color: YageColors.textPrimary,
                      ),
                    ),
                    Text(
                      'Custom colors for original Game Boy',
                      style: TextStyle(
                        fontSize: 12,
                        color: YageColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 60,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: GBColorPalette.palettes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final palette = GBColorPalette.palettes[index];
                final isSelected = index == selectedIndex;
                return TvFocusable(
                  onTap: () => onChanged(index),
                  borderRadius: BorderRadius.circular(12),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 72,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected
                            ? YageColors.primary
                            : YageColors.surfaceLight,
                        width: isSelected ? 2.5 : 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(10),
                            ),
                            child: Row(
                              children: [
                                for (final color in palette)
                                  Expanded(
                                    child: Container(
                                      color: Color(0xFF000000 | color),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? YageColors.primary.withValues(alpha: 0.15)
                                : YageColors.surface,
                            borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(10),
                            ),
                          ),
                          child: Text(
                            GBColorPalette.names[index],
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 8,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isSelected
                                  ? YageColors.primary
                                  : YageColors.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemePicker extends StatelessWidget {
  final String selectedThemeId;
  final ValueChanged<String> onChanged;

  const _ThemePicker({
    required this.selectedThemeId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: YageColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: YageColors.surfaceLight,
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.color_lens, color: YageColors.accent, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'App Theme',
                      style: TextStyle(
                        fontSize: 14,
                        color: YageColors.textPrimary,
                      ),
                    ),
                    Text(
                      'Choose your vibe',
                      style: TextStyle(
                        fontSize: 12,
                        color: YageColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...AppThemes.all.map((theme) {
            final isSelected = theme.id == selectedThemeId;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TvFocusable(
                onTap: () => onChanged(theme.id),
                borderRadius: BorderRadius.circular(12),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? theme.primary.withAlpha(30)
                        : YageColors.backgroundLight,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? theme.primary : YageColors.surfaceLight,
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      // Color swatch preview
                      Container(
                        width: 44,
                        height: 32,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          gradient: LinearGradient(
                            colors: [
                              theme.primary,
                              theme.accent,
                            ],
                          ),
                        ),
                        child: Center(
                          child: Text(
                            theme.emoji,
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      // Name and color dots
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              theme.name,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                                color: isSelected
                                    ? theme.primary
                                    : YageColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                _colorDot(theme.backgroundDark),
                                _colorDot(theme.surface),
                                _colorDot(theme.primary),
                                _colorDot(theme.accent),
                                _colorDot(theme.textPrimary),
                              ],
                            ),
                          ],
                        ),
                      ),
                      // Check mark
                      if (isSelected)
                        Icon(
                          Icons.check_circle,
                          color: theme.primary,
                          size: 22,
                        ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _colorDot(Color color) {
    return Container(
      width: 14,
      height: 14,
      margin: const EdgeInsets.only(right: 4),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withAlpha(40),
          width: 0.5,
        ),
      ),
    );
  }
}

/// Gamepad skin picker — horizontal chips with mini preview
class _GamepadSkinTile extends StatelessWidget {
  final GamepadSkinType selected;
  final ValueChanged<GamepadSkinType> onChanged;

  const _GamepadSkinTile({
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.brush, color: YageColors.accent, size: 20),
              const SizedBox(width: 12),
              Text(
                'Button Skin',
                style: TextStyle(
                  fontSize: 14,
                  color: YageColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: GamepadSkinType.values.map((skin) {
              final isSelected = skin == selected;
              final skinData = GamepadSkinData.resolve(skin);
              return TvFocusable(
                onTap: () => onChanged(skin),
                borderRadius: BorderRadius.circular(12),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? YageColors.primary.withAlpha(40)
                        : YageColors.surface.withAlpha(120),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected
                          ? YageColors.primary
                          : YageColors.surfaceLight,
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Mini preview: two small circles showing button style
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _MiniButtonPreview(
                            fill: skinData.buttonFill,
                            border: skinData.buttonBorder,
                            borderWidth: skinData.buttonBorderWidth,
                            shadows: skinData.normalShadows,
                          ),
                          const SizedBox(width: 4),
                          _MiniButtonPreview(
                            fill: skinData.buttonFillPressed,
                            border: skinData.buttonBorderPressed,
                            borderWidth: skinData.buttonBorderWidth,
                            shadows: skinData.pressedShadows,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        skin.label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected
                              ? YageColors.primary
                              : YageColors.textSecondary,
                        ),
                      ),
                    ],
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

class _MiniButtonPreview extends StatelessWidget {
  final Color fill;
  final Color border;
  final double borderWidth;
  final List<BoxShadow> shadows;

  const _MiniButtonPreview({
    required this.fill,
    required this.border,
    required this.borderWidth,
    required this.shadows,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(
          color: border,
          width: borderWidth.clamp(0.5, 2.0),
        ),
        boxShadow: shadows,
      ),
    );
  }
}

/// Game frame / shell picker — horizontal chips with console color preview
class _GameFrameTile extends StatelessWidget {
  final GameFrameType selected;
  final ValueChanged<GameFrameType> onChanged;

  const _GameFrameTile({
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.phone_android, color: YageColors.accent, size: 20),
              const SizedBox(width: 12),
              Text(
                'Console Frame',
                style: TextStyle(
                  fontSize: 14,
                  color: YageColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Decorative Game Boy shell around the screen',
            style: TextStyle(fontSize: 11, color: YageColors.textMuted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: GameFrameType.values.map((frame) {
              final isSelected = frame == selected;
              return TvFocusable(
                onTap: () => onChanged(frame),
                borderRadius: BorderRadius.circular(12),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? YageColors.primary.withAlpha(40)
                        : YageColors.surface.withAlpha(120),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected
                          ? YageColors.primary
                          : YageColors.surfaceLight,
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Mini console preview
                      _MiniFramePreview(
                        frame: frame,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        frame.label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: isSelected
                              ? YageColors.primary
                              : YageColors.textSecondary,
                        ),
                      ),
                    ],
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

/// Tiny console silhouette for the frame picker chips
class _MiniFramePreview extends StatelessWidget {
  final GameFrameType frame;

  const _MiniFramePreview({required this.frame});

  @override
  Widget build(BuildContext context) {
    if (frame == GameFrameType.none) {
      return Container(
        width: 28,
        height: 22,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: YageColors.textMuted.withAlpha(60),
            width: 1,
          ),
        ),
        child: Icon(Icons.crop_free,
            size: 14, color: YageColors.textMuted.withAlpha(80)),
      );
    }

    final isLandscape = frame == GameFrameType.advance;
    final w = isLandscape ? 32.0 : 20.0;
    final h = isLandscape ? 20.0 : 28.0;
    final screenW = isLandscape ? 16.0 : 14.0;
    final screenH = isLandscape ? 10.0 : 10.0;

    return SizedBox(
      width: w,
      height: h,
      child: CustomPaint(
        painter: _MiniFramePainter(
          bodyColor: frame.previewColor,
          screenRect: Rect.fromCenter(
            center: Offset(w / 2, h * (isLandscape ? 0.45 : 0.35)),
            width: screenW,
            height: screenH,
          ),
        ),
      ),
    );
  }
}

class _MiniFramePainter extends CustomPainter {
  final Color bodyColor;
  final Rect screenRect;

  _MiniFramePainter({required this.bodyColor, required this.screenRect});

  @override
  void paint(Canvas canvas, Size size) {
    // Body
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        const Radius.circular(3),
      ),
      Paint()..color = bodyColor,
    );
    // Screen cutout (dark)
    canvas.drawRRect(
      RRect.fromRectAndRadius(screenRect, const Radius.circular(1.5)),
      Paint()..color = const Color(0xFF1A1A24),
    );
    // Tiny green "screen" glow
    canvas.drawRRect(
      RRect.fromRectAndRadius(screenRect.deflate(1), const Radius.circular(1)),
      Paint()..color = const Color(0xFF4A6A4A).withAlpha(120),
    );
  }

  @override
  bool shouldRepaint(_MiniFramePainter old) => old.bodyColor != bodyColor;
}

// ─────────────────────────────────────────────────────────
//  RetroAchievements account tile
// ─────────────────────────────────────────────────────────

class _RetroAchievementsTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<RetroAchievementsService>(
      builder: (context, raService, _) {
        if (raService.isLoading) {
          return _SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: YageColors.accent,
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        if (raService.isLoggedIn) {
          final profile = raService.profile;
          return _SettingsCard(
            children: [
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: YageColors.primary,
                  backgroundImage: profile != null
                      ? NetworkImage(profile.profileImageUrl)
                      : null,
                  child: profile == null
                      ? Icon(Icons.person, color: YageColors.textPrimary)
                      : null,
                ),
                title: Text(
                  raService.username ?? 'Player',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: YageColors.textPrimary,
                  ),
                ),
                subtitle: Text(
                  '${profile?.totalPoints ?? 0} points · Member since ${profile?.memberSince ?? '—'}',
                  style: TextStyle(
                    fontSize: 11,
                    color: YageColors.textMuted,
                  ),
                ),
              ),
              const Divider(height: 1),
              _ActionTile(
                icon: Icons.logout,
                title: 'Sign Out',
                onTap: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: YageColors.surface,
                      title: Text(
                        'Sign out of RetroAchievements?',
                        style: TextStyle(color: YageColors.textPrimary),
                      ),
                      content: Text(
                        'You will no longer earn achievements until you sign in again.',
                        style: TextStyle(color: YageColors.textSecondary),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text(
                            'Sign Out',
                            style: TextStyle(color: YageColors.error),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    raService.logout();
                  }
                },
                isDestructive: true,
              ),
            ],
          );
        }

        // Not logged in — show error banner if API key was invalid
        return _SettingsCard(
          children: [
            // Error banner (invalid API key, network failure, etc.)
            if (raService.lastError != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: YageColors.error.withAlpha(20),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(16),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: YageColors.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        raService.lastError!,
                        style: TextStyle(
                          fontSize: 12,
                          color: YageColors.error,
                          height: 1.4,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: raService.clearError,
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: YageColors.error.withAlpha(160),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Icon(
                    Icons.emoji_events_outlined,
                    size: 40,
                    color: YageColors.textMuted,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Sign in to track achievements',
                    style: TextStyle(
                      fontSize: 13,
                      color: YageColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.login, size: 18),
                      label: const Text('Sign In'),
                      onPressed: () {
                        raService.clearError();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const RALoginScreen(),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────
//  Backup / Restore dialogs
// ─────────────────────────────────────────────────────────

/// Dialog that exports all saves to ZIP and offers Save / Share options.
class _BackupProgressDialog extends StatefulWidget {
  final List<GameRom> games;
  final String? appSaveDir;

  const _BackupProgressDialog({
    required this.title,
    required this.games,
    required this.appSaveDir,
  });

  final String title;

  @override
  State<_BackupProgressDialog> createState() => _BackupProgressDialogState();
}

class _BackupProgressDialogState extends State<_BackupProgressDialog> {
  String _status = 'Collecting save files…';
  double _progress = 0;
  String? _zipPath;
  bool _done = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _export();
  }

  Future<void> _export() async {
    try {
      final zipPath = await SaveBackupService.exportAllSaves(
        games: widget.games,
        appSaveDir: widget.appSaveDir,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _progress = total > 0 ? done / total : 0;
              _status = 'Scanning game $done of $total…';
            });
          }
        },
      );

      if (!mounted) return;

      if (zipPath == null) {
        setState(() {
          _status = 'No save files found.';
          _done = true;
        });
        return;
      }

      final fileSize = File(zipPath).lengthSync();
      final sizeMb = (fileSize / (1024 * 1024)).toStringAsFixed(1);

      setState(() {
        _zipPath = zipPath;
        _status = 'Backup ready! ($sizeMb MB)';
        _done = true;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Export failed: $e';
          _done = true;
          _error = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: YageColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(
            _error
                ? Icons.error_outline
                : (_done ? Icons.check_circle : Icons.archive),
            color: _error
                ? YageColors.error
                : (_done ? YageColors.accent : YageColors.textSecondary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.title,
              style: TextStyle(
                color: YageColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_done) ...[
            LinearProgressIndicator(
              value: _progress > 0 ? _progress : null,
              backgroundColor: YageColors.surfaceLight,
              valueColor: AlwaysStoppedAnimation(YageColors.accent),
            ),
            const SizedBox(height: 12),
          ],
          Text(
            _status,
            style: TextStyle(color: YageColors.textSecondary, fontSize: 13),
          ),
        ],
      ),
      actions: [
        if (_done && !_error)
          TextButton.icon(
            icon: const Icon(Icons.share, size: 18),
            label: const Text('Share'),
            onPressed: _zipPath != null
                ? () {
                    SaveBackupService.shareZip(_zipPath!);
                  }
                : null,
          ),
        if (_done && !_error)
          TextButton.icon(
            icon: const Icon(Icons.save_alt, size: 18),
            label: const Text('Save to…'),
            onPressed: _zipPath != null
                ? () async {
                    final saved =
                        await SaveBackupService.saveZipToUserLocation(_zipPath!);
                    if (saved != null && context.mounted) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Saved to $saved')),
                      );
                    }
                  }
                : null,
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            _done ? 'Close' : 'Cancel',
            style: TextStyle(color: YageColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// Dialog that handles Google Drive backup (sign in → export → upload).
class _DriveBackupDialog extends StatefulWidget {
  final List<GameRom> games;
  final String? appSaveDir;

  const _DriveBackupDialog({
    required this.games,
    required this.appSaveDir,
  });

  @override
  State<_DriveBackupDialog> createState() => _DriveBackupDialogState();
}

class _DriveBackupDialogState extends State<_DriveBackupDialog> {
  String _status = 'Signing in to Google…';
  bool _done = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      // Step 1: Sign in
      final signedIn = await SaveBackupService.googleSignIn();
      if (!signedIn) {
        if (mounted) {
          setState(() {
            _status = 'Google Sign-In cancelled or failed.\n\n'
                'Make sure Google Sign-In is configured in your project.';
            _done = true;
            _error = true;
          });
        }
        return;
      }

      // Step 2: Export to ZIP
      if (mounted) setState(() => _status = 'Creating backup ZIP…');
      final zipPath = await SaveBackupService.exportAllSaves(
        games: widget.games,
        appSaveDir: widget.appSaveDir,
      );

      if (zipPath == null) {
        if (mounted) {
          setState(() {
            _status = 'No save files found to backup.';
            _done = true;
          });
        }
        return;
      }

      // Step 3: Upload to Drive
      if (mounted) setState(() => _status = 'Uploading to Google Drive…');
      final fileId = await SaveBackupService.uploadToDrive(zipPath);

      if (mounted) {
        setState(() {
          _done = true;
          if (fileId != null) {
            _status = 'Backup uploaded to Google Drive!\n'
                'Saved in the "RetroPal" folder.';
          } else {
            _status = 'Upload to Google Drive failed.';
            _error = true;
          }
        });
      }

      // Clean up temp ZIP
      try {
        File(zipPath).deleteSync();
      } catch (_) {}
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Error: $e';
          _done = true;
          _error = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: YageColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(
            _error
                ? Icons.error_outline
                : (_done ? Icons.cloud_done : Icons.cloud_upload),
            color: _error
                ? YageColors.error
                : (_done ? YageColors.accent : YageColors.textSecondary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Google Drive Backup',
              style: TextStyle(
                color: YageColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_done) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
          ],
          Text(
            _status,
            style: TextStyle(
              color: _error ? YageColors.error : YageColors.textSecondary,
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            _done ? 'Close' : 'Cancel',
            style: TextStyle(color: YageColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// Dialog that lists Drive backups and lets user pick one to restore.
class _DriveRestoreDialog extends StatefulWidget {
  final List<GameRom> games;

  const _DriveRestoreDialog({required this.games});

  @override
  State<_DriveRestoreDialog> createState() => _DriveRestoreDialogState();
}

class _DriveRestoreDialogState extends State<_DriveRestoreDialog> {
  String _status = 'Signing in to Google…';
  List<drive.File>? _backups;
  bool _loading = true;
  bool _error = false;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _loadBackups();
  }

  Future<void> _loadBackups() async {
    try {
      final signedIn = await SaveBackupService.googleSignIn();
      if (!signedIn) {
        if (mounted) {
          setState(() {
            _status = 'Google Sign-In cancelled or failed.';
            _loading = false;
            _error = true;
          });
        }
        return;
      }

      if (mounted) setState(() => _status = 'Loading backups…');
      final backups = await SaveBackupService.listDriveBackups();

      if (mounted) {
        setState(() {
          _backups = backups;
          _loading = false;
          _status = backups.isEmpty
              ? 'No backups found in Google Drive.\n'
                  'Use "Backup to Google Drive" first.'
              : 'Select a backup to restore:';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Error: $e';
          _loading = false;
          _error = true;
        });
      }
    }
  }

  Future<void> _restore(drive.File backup) async {
    if (_restoring) return;
    setState(() {
      _restoring = true;
      _status = 'Downloading ${backup.name}…';
    });

    try {
      final zipPath = await SaveBackupService.downloadFromDrive(backup.id!);
      if (zipPath == null) {
        if (mounted) {
          setState(() {
            _status = 'Download failed.';
            _restoring = false;
            _error = true;
          });
        }
        return;
      }

      if (mounted) setState(() => _status = 'Restoring saves…');
      final count = await SaveBackupService.importFromZip(
        zipPath: zipPath,
        games: widget.games,
      );

      // Clean up temp file
      try {
        File(zipPath).deleteSync();
      } catch (_) {}

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              count > 0
                  ? 'Restored $count save file${count == 1 ? '' : 's'} from Drive'
                  : 'No matching save files found in backup',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Restore failed: $e';
          _restoring = false;
          _error = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: YageColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(
            _error ? Icons.error_outline : Icons.cloud_download,
            color: _error ? YageColors.error : YageColors.accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Restore from Drive',
              style: TextStyle(
                color: YageColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_loading || _restoring) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
            ],
            Text(
              _status,
              style: TextStyle(
                color: _error ? YageColors.error : YageColors.textSecondary,
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
            if (_backups != null && _backups!.isNotEmpty && !_restoring) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 250),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _backups!.length,
                  itemBuilder: (context, index) {
                    final backup = _backups![index];
                    final modified = backup.modifiedTime;
                    final sizeBytes = int.tryParse(backup.size ?? '') ?? 0;
                    final sizeMb = (sizeBytes / (1024 * 1024)).toStringAsFixed(1);
                    final dateStr = modified != null
                        ? '${modified.year}-${modified.month.toString().padLeft(2, '0')}-${modified.day.toString().padLeft(2, '0')} '
                          '${modified.hour.toString().padLeft(2, '0')}:${modified.minute.toString().padLeft(2, '0')}'
                        : 'Unknown date';

                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.archive, size: 20),
                      title: Text(
                        backup.name ?? 'Backup',
                        style: TextStyle(
                          fontSize: 12,
                          color: YageColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '$dateStr · $sizeMb MB',
                        style: TextStyle(
                          fontSize: 11,
                          color: YageColors.textMuted,
                        ),
                      ),
                      onTap: () => _restore(backup),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _restoring ? null : () => Navigator.pop(context),
          child: Text(
            'Close',
            style: TextStyle(color: YageColors.textSecondary),
          ),
        ),
      ],
    );
  }
}
