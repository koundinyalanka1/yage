import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../core/mgba_bindings.dart';
import '../models/game_rom.dart';
import '../models/emulator_settings.dart';

/// State of the emulator
enum EmulatorState {
  uninitialized,
  ready,
  running,
  paused,
  error,
}

/// Emulator service managing the mGBA core lifecycle
class EmulatorService extends ChangeNotifier {
  final MGBABindings _bindings = MGBABindings();
  MGBACore? _core;
  
  EmulatorState _state = EmulatorState.uninitialized;
  GameRom? _currentRom;
  EmulatorSettings _settings = const EmulatorSettings();
  String? _errorMessage;
  
  Timer? _frameTimer;
  Stopwatch? _frameStopwatch;
  int _frameCount = 0;
  double _currentFps = 0;
  
  // Frame timing (GBA runs at ~59.7275 fps)
  static const Duration _targetFrameTime = Duration(microseconds: 16742);
  
  // Callbacks
  void Function(Uint8List pixels, int width, int height)? onFrame;
  void Function(Int16List samples, int count)? onAudio;

  EmulatorState get state => _state;
  GameRom? get currentRom => _currentRom;
  EmulatorSettings get settings => _settings;
  String? get errorMessage => _errorMessage;
  double get currentFps => _currentFps;
  bool get isRunning => _state == EmulatorState.running;
  int get screenWidth => _core?.width ?? 240;
  int get screenHeight => _core?.height ?? 160;
  GamePlatform get platform => _core?.platform ?? GamePlatform.unknown;

  /// Initialize the emulator service
  Future<bool> initialize() async {
    if (_state != EmulatorState.uninitialized) return true;

    try {
      if (!_bindings.load()) {
        _errorMessage = 'Failed to load mGBA library';
        _state = EmulatorState.error;
        notifyListeners();
        return false;
      }

      _core = MGBACore(_bindings);
      if (!_core!.initialize()) {
        _errorMessage = 'Failed to initialize mGBA core';
        _state = EmulatorState.error;
        notifyListeners();
        return false;
      }

      // Set up save directory
      final saveDir = await _getSaveDirectory();
      _core!.setSaveDir(saveDir);

      _state = EmulatorState.ready;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = 'Initialization error: $e';
      _state = EmulatorState.error;
      notifyListeners();
      return false;
    }
  }

  Future<String> _getSaveDirectory() async {
    final appDir = await getApplicationSupportDirectory();
    final saveDir = Directory(p.join(appDir.path, 'saves'));
    if (!saveDir.existsSync()) {
      saveDir.createSync(recursive: true);
    }
    return saveDir.path;
  }

  /// Load a ROM file
  Future<bool> loadRom(GameRom rom) async {
    if (_core == null) {
      if (!await initialize()) return false;
    }

    try {
      // Load BIOS if available
      final biosPath = _getBiosPath(rom.platform);
      if (biosPath != null && File(biosPath).existsSync()) {
        _core!.loadBIOS(biosPath);
      }

      if (!_core!.loadROM(rom.path)) {
        _errorMessage = 'Failed to load ROM: ${rom.name}';
        notifyListeners();
        return false;
      }

      _currentRom = rom.copyWith(lastPlayed: DateTime.now());
      _state = EmulatorState.paused;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = 'Error loading ROM: $e';
      notifyListeners();
      return false;
    }
  }

  String? _getBiosPath(GamePlatform platform) {
    return switch (platform) {
      GamePlatform.gba => _settings.biosPathGba,
      GamePlatform.gb => _settings.biosPathGb,
      GamePlatform.gbc => _settings.biosPathGbc,
      GamePlatform.unknown => null,
    };
  }

  /// Start emulation
  void start() {
    if (_state != EmulatorState.paused || _core == null) return;

    _state = EmulatorState.running;
    _frameStopwatch = Stopwatch()..start();
    _frameCount = 0;
    _startFrameLoop();
    notifyListeners();
  }

  /// Pause emulation
  void pause() {
    if (_state != EmulatorState.running) return;

    _state = EmulatorState.paused;
    _frameTimer?.cancel();
    _frameTimer = null;
    notifyListeners();
  }

  /// Toggle pause/resume
  void togglePause() {
    if (_state == EmulatorState.running) {
      pause();
    } else if (_state == EmulatorState.paused) {
      start();
    }
  }

  /// Reset the emulator
  void reset() {
    _core?.reset();
    if (_state == EmulatorState.paused) {
      _runSingleFrame();
    }
  }

  void _startFrameLoop() {
    _frameTimer?.cancel();
    
    // Use a timer for frame pacing
    _frameTimer = Timer.periodic(_targetFrameTime, (_) {
      if (_state != EmulatorState.running) return;
      _runFrame();
    });
  }

  void _runFrame() {
    if (_core == null || !_core!.isRunning) return;

    // Run the frame
    _core!.runFrame();
    _frameCount++;

    // Get video output
    final pixels = _core!.getVideoBuffer();
    if (pixels != null && onFrame != null) {
      onFrame!(pixels, _core!.width, _core!.height);
    }

    // Get audio output
    if (_settings.enableSound) {
      final (audioData, samples) = _core!.getAudioBuffer();
      if (audioData != null && samples > 0 && onAudio != null) {
        onAudio!(audioData, samples);
      }
    }

    // Calculate FPS
    if (_frameStopwatch != null && _frameStopwatch!.elapsedMilliseconds >= 1000) {
      _currentFps = _frameCount * 1000 / _frameStopwatch!.elapsedMilliseconds;
      _frameCount = 0;
      _frameStopwatch!.reset();
      _frameStopwatch!.start();
      
      if (_settings.showFps) {
        notifyListeners();
      }
    }
  }

  void _runSingleFrame() {
    if (_core == null || !_core!.isRunning) return;

    _core!.runFrame();
    final pixels = _core!.getVideoBuffer();
    if (pixels != null && onFrame != null) {
      onFrame!(pixels, _core!.width, _core!.height);
    }
  }

  /// Set key states
  void setKeys(int keys) {
    _core?.setKeys(keys);
  }

  /// Press a key
  void pressKey(int key) {
    _core?.pressKey(key);
  }

  /// Release a key
  void releaseKey(int key) {
    _core?.releaseKey(key);
  }

  /// Save state to slot
  Future<bool> saveState(int slot) async {
    if (_core == null) return false;
    return _core!.saveState(slot);
  }

  /// Load state from slot
  Future<bool> loadState(int slot) async {
    if (_core == null) return false;
    final success = _core!.loadState(slot);
    if (success && _state == EmulatorState.paused) {
      _runSingleFrame();
    }
    return success;
  }

  /// Update settings
  void updateSettings(EmulatorSettings newSettings) {
    _settings = newSettings;
    notifyListeners();
  }

  /// Stop and unload current ROM
  void stop() {
    _frameTimer?.cancel();
    _frameTimer = null;
    _core?.dispose();
    _core = null;
    _currentRom = null;
    _state = EmulatorState.uninitialized;
    _frameCount = 0;
    _currentFps = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _frameTimer?.cancel();
    _core?.dispose();
    super.dispose();
  }
}

