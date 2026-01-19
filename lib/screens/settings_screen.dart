import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';

import '../services/settings_service.dart';
import '../services/game_library_service.dart';
import '../utils/theme.dart';

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
              _SectionHeader(title: 'Audio'),
              _SettingsCard(
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
              
              const SizedBox(height: 24),
              _SectionHeader(title: 'Display'),
              _SettingsCard(
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
                    title: 'Bilinear Filtering',
                    subtitle: 'Smooth pixel scaling',
                    value: settings.enableFiltering,
                    onChanged: (_) => settingsService.toggleFiltering(),
                  ),
                ],
              ),
              
              const SizedBox(height: 24),
              _SectionHeader(title: 'Controls'),
              _SettingsCard(
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
                ],
              ),
              
              const SizedBox(height: 24),
              _SectionHeader(title: 'Emulation'),
              _SettingsCard(
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
                    icon: Icons.skip_next,
                    title: 'Skip BIOS',
                    subtitle: 'Skip startup animation',
                    value: settings.skipBios,
                    onChanged: (_) => settingsService.toggleSkipBios(),
                  ),
                ],
              ),
              
              const SizedBox(height: 24),
              _SectionHeader(title: 'BIOS Files'),
              _SettingsCard(
                children: [
                  _FileTile(
                    icon: Icons.memory,
                    title: 'GBA BIOS',
                    path: settings.biosPathGba,
                    onSelect: () => _selectBios(context, 'gba'),
                    onClear: () => settingsService.setGbaBiosPath(null),
                  ),
                  const Divider(height: 1),
                  _FileTile(
                    icon: Icons.memory,
                    title: 'GBC BIOS',
                    path: settings.biosPathGbc,
                    onSelect: () => _selectBios(context, 'gbc'),
                    onClear: () => settingsService.setGbcBiosPath(null),
                  ),
                  const Divider(height: 1),
                  _FileTile(
                    icon: Icons.memory,
                    title: 'GB BIOS',
                    path: settings.biosPathGb,
                    onSelect: () => _selectBios(context, 'gb'),
                    onClear: () => settingsService.setGbBiosPath(null),
                  ),
                ],
              ),
              
              const SizedBox(height: 24),
              _SectionHeader(title: 'Library'),
              _SettingsCard(
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
              
              const SizedBox(height: 24),
              _SectionHeader(title: 'About'),
              _SettingsCard(
                children: [
                  _InfoTile(
                    icon: Icons.info_outline,
                    title: 'YAGE',
                    subtitle: 'Yet Another Game Boy Emulator\nVersion 0.1.0',
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
              
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  Future<void> _selectBios(BuildContext context, String platform) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
    );

    if (result != null && result.files.single.path != null && context.mounted) {
      final path = result.files.single.path!;
      final settings = context.read<SettingsService>();
      
      switch (platform) {
        case 'gba':
          await settings.setGbaBiosPath(path);
          break;
        case 'gbc':
          await settings.setGbcBiosPath(path);
          break;
        case 'gb':
          await settings.setGbBiosPath(path);
          break;
      }
    }
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
                  const Text(
                    'ROM Folders',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: YageColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  if (library.romDirectories.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
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
                          leading: const Icon(Icons.folder, color: YageColors.accent),
                          title: Text(
                            dir.split(RegExp(r'[/\\]')).last,
                            style: const TextStyle(color: YageColors.textPrimary),
                          ),
                          subtitle: Text(
                            dir,
                            style: const TextStyle(
                              fontSize: 11,
                              color: YageColors.textMuted,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete, color: YageColors.error),
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
        title: const Text(
          'Reset Settings?',
          style: TextStyle(
            color: YageColors.textPrimary,
          ),
        ),
        content: const Text(
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
            child: const Text(
              'Reset',
              style: TextStyle(color: YageColors.error),
            ),
          ),
        ],
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
        style: const TextStyle(
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
        style: const TextStyle(
          fontSize: 14,
          color: YageColors.textPrimary,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
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
                  style: const TextStyle(
                    fontSize: 14,
                    color: YageColors.textPrimary,
                  ),
                ),
              ),
              Text(
                '${value.toStringAsFixed(1)}$labelSuffix',
                style: const TextStyle(
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

class _FileTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? path;
  final VoidCallback onSelect;
  final VoidCallback onClear;

  const _FileTile({
    required this.icon,
    required this.title,
    required this.path,
    required this.onSelect,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: YageColors.accent),
      title: Text(
        title,
        style: const TextStyle(
          fontSize: 14,
          color: YageColors.textPrimary,
        ),
      ),
      subtitle: Text(
        path ?? 'Not set',
        style: TextStyle(
          fontSize: 11,
          color: path != null ? YageColors.textSecondary : YageColors.textMuted,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (path != null)
            IconButton(
              icon: const Icon(Icons.clear, size: 20),
              color: YageColors.textMuted,
              onPressed: onClear,
            ),
          IconButton(
            icon: const Icon(Icons.folder_open, size: 20),
            color: YageColors.primary,
            onPressed: onSelect,
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
      trailing: const Icon(
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
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: YageColors.textPrimary,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          fontSize: 12,
          color: YageColors.textMuted,
        ),
      ),
    );
  }
}

