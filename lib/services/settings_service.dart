import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/emulator_settings.dart';

/// Service for managing app and emulator settings
class SettingsService extends ChangeNotifier {
  static const String _settingsKey = 'emulator_settings';
  
  EmulatorSettings _settings = const EmulatorSettings();
  bool _isLoaded = false;

  EmulatorSettings get settings => _settings;
  bool get isLoaded => _isLoaded;

  /// Load settings from storage
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_settingsKey);
      
      if (json != null) {
        _settings = EmulatorSettings.fromJsonString(json);
      }
      
      _isLoaded = true;
      notifyListeners();
    } catch (e) {
      // Use defaults on error
      _settings = const EmulatorSettings();
      _isLoaded = true;
      notifyListeners();
    }
  }

  /// Save settings to storage
  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_settingsKey, _settings.toJsonString());
    } catch (e) {
      debugPrint('Failed to save settings: $e');
    }
  }

  /// Update a single setting
  Future<void> update(EmulatorSettings Function(EmulatorSettings) updater) async {
    _settings = updater(_settings);
    notifyListeners();
    await save();
  }

  /// Update volume
  Future<void> setVolume(double volume) async {
    await update((s) => s.copyWith(volume: volume.clamp(0.0, 1.0)));
  }

  /// Toggle sound
  Future<void> toggleSound() async {
    await update((s) => s.copyWith(enableSound: !s.enableSound));
  }

  /// Set frame skip
  Future<void> setFrameSkip(int skip) async {
    await update((s) => s.copyWith(frameSkip: skip.clamp(0, 4)));
  }

  /// Toggle FPS display
  Future<void> toggleShowFps() async {
    await update((s) => s.copyWith(showFps: !s.showFps));
  }

  /// Toggle vibration
  Future<void> toggleVibration() async {
    await update((s) => s.copyWith(enableVibration: !s.enableVibration));
  }

  /// Set gamepad opacity
  Future<void> setGamepadOpacity(double opacity) async {
    await update((s) => s.copyWith(gamepadOpacity: opacity.clamp(0.1, 1.0)));
  }

  /// Set gamepad scale
  Future<void> setGamepadScale(double scale) async {
    await update((s) => s.copyWith(gamepadScale: scale.clamp(0.5, 2.0)));
  }

  /// Toggle turbo mode
  Future<void> toggleTurbo() async {
    await update((s) => s.copyWith(enableTurbo: !s.enableTurbo));
  }

  /// Set turbo speed
  Future<void> setTurboSpeed(double speed) async {
    await update((s) => s.copyWith(turboSpeed: speed.clamp(1.5, 8.0)));
  }

  /// Set GBA BIOS path
  Future<void> setGbaBiosPath(String? path) async {
    await update((s) => s.copyWith(biosPathGba: path));
  }

  /// Set GB BIOS path
  Future<void> setGbBiosPath(String? path) async {
    await update((s) => s.copyWith(biosPathGb: path));
  }

  /// Set GBC BIOS path
  Future<void> setGbcBiosPath(String? path) async {
    await update((s) => s.copyWith(biosPathGbc: path));
  }

  /// Toggle skip BIOS
  Future<void> toggleSkipBios() async {
    await update((s) => s.copyWith(skipBios: !s.skipBios));
  }

  /// Set color palette
  Future<void> setColorPalette(int index) async {
    await update((s) => s.copyWith(selectedColorPalette: index));
  }

  /// Toggle filtering
  Future<void> toggleFiltering() async {
    await update((s) => s.copyWith(enableFiltering: !s.enableFiltering));
  }

  /// Toggle aspect ratio maintenance
  Future<void> toggleAspectRatio() async {
    await update((s) => s.copyWith(maintainAspectRatio: !s.maintainAspectRatio));
  }

  /// Set auto save interval
  Future<void> setAutoSaveInterval(int seconds) async {
    await update((s) => s.copyWith(autoSaveInterval: seconds));
  }

  /// Reset to defaults
  Future<void> resetToDefaults() async {
    _settings = const EmulatorSettings();
    notifyListeners();
    await save();
  }
}

