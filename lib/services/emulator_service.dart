import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../core/mgba_bindings.dart';
import '../core/mgba_stub.dart';
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
/// Falls back to stub implementation if native library unavailable
class EmulatorService extends ChangeNotifier {
  final MGBABindings _bindings = MGBABindings();
  MGBACore? _core;
  MGBAStub? _stub; // Fallback stub for testing
  bool _useStub = false;
  
  EmulatorState _state = EmulatorState.uninitialized;
  GameRom? _currentRom;
  EmulatorSettings _settings = const EmulatorSettings();
  String? _errorMessage;
  
  Timer? _frameTimer;
  Stopwatch? _frameStopwatch;
  int _frameCount = 0;
  double _currentFps = 0;
  double _speedMultiplier = 1.0;
  
  // Frame timing (GBA runs at ~59.7275 fps)
  static const Duration _baseFrameTime = Duration(microseconds: 16742);
  Duration get _targetFrameTime => Duration(
    microseconds: (_baseFrameTime.inMicroseconds / _speedMultiplier).round(),
  );
  
  // Callbacks
  void Function(Uint8List pixels, int width, int height)? onFrame;
  void Function(Int16List samples, int count)? onAudio;

  EmulatorState get state => _state;
  GameRom? get currentRom => _currentRom;
  EmulatorSettings get settings => _settings;
  String? get errorMessage => _errorMessage;
  double get currentFps => _currentFps;
  bool get isRunning => _state == EmulatorState.running;
  bool get isUsingStub => _useStub;
  double get speedMultiplier => _speedMultiplier;
  
  /// Set emulation speed (0.5x, 1x, 2x, 4x, etc.)
  void setSpeed(double speed) {
    _speedMultiplier = speed.clamp(0.25, 8.0);
    notifyListeners();
  }
  
  /// Toggle fast forward (between 1x and 2x)
  void toggleFastForward() {
    if (_speedMultiplier > 1.0) {
      _speedMultiplier = 1.0;
    } else {
      _speedMultiplier = 2.0;
    }
    notifyListeners();
  }
  
  int get screenWidth {
    if (_useStub) return _stub?.width ?? 240;
    return _core?.width ?? 240;
  }
  
  int get screenHeight {
    if (_useStub) return _stub?.height ?? 160;
    return _core?.height ?? 160;
  }
  
  GamePlatform get platform {
    if (_useStub) return _stub?.platform ?? GamePlatform.unknown;
    return _core?.platform ?? GamePlatform.unknown;
  }

  /// Initialize the emulator service
  Future<bool> initialize() async {
    if (_state != EmulatorState.uninitialized) return true;

    try {
      // Try to load native library first
      if (_bindings.load()) {
        _core = MGBACore(_bindings);
        if (_core!.initialize()) {
          final saveDir = await _getSaveDirectory();
          _core!.setSaveDir(saveDir);
          _useStub = false;
          _state = EmulatorState.ready;
          notifyListeners();
          return true;
        }
      }
      
      // Fall back to stub implementation
      debugPrint('Native mGBA library not available, using stub for UI testing');
      _stub = MGBAStub();
      _stub!.initialize();
      _useStub = true;
      _state = EmulatorState.ready;
      _errorMessage = 'Running in demo mode (native library not found)';
      notifyListeners();
      return true;
    } catch (e) {
      // Final fallback to stub
      debugPrint('Error initializing: $e, falling back to stub');
      _stub = MGBAStub();
      _stub!.initialize();
      _useStub = true;
      _state = EmulatorState.ready;
      _errorMessage = 'Running in demo mode';
      notifyListeners();
      return true;
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

  /// Get the .sav file path for a ROM (battery/SRAM save)
  Future<String> _getSramPath(GameRom rom) async {
    final saveDir = await _getSaveDirectory();
    // Use ROM name without extension + .sav
    final saveName = p.basenameWithoutExtension(rom.path);
    return p.join(saveDir, '$saveName.sav');
  }

  /// Load SRAM from .sav file if it exists
  Future<void> _loadSram(GameRom rom) async {
    if (_useStub || _core == null) return;
    
    try {
      final sramPath = await _getSramPath(rom);
      if (File(sramPath).existsSync()) {
        final success = _core!.loadSram(sramPath);
        debugPrint('Loaded SRAM from $sramPath: $success');
      }
    } catch (e) {
      debugPrint('Error loading SRAM: $e');
    }
  }

  /// Save SRAM to .sav file
  Future<void> saveSram() async {
    if (_useStub || _core == null || _currentRom == null) return;
    
    try {
      final sramPath = await _getSramPath(_currentRom!);
      final success = _core!.saveSram(sramPath);
      debugPrint('Saved SRAM to $sramPath: $success');
    } catch (e) {
      debugPrint('Error saving SRAM: $e');
    }
  }

  /// Load a ROM file
  Future<bool> loadRom(GameRom rom) async {
    if (_state == EmulatorState.uninitialized) {
      if (!await initialize()) return false;
    }

    try {
      if (_useStub) {
        _stub!.loadROM(rom.path);
        _currentRom = rom.copyWith(lastPlayed: DateTime.now());
        _state = EmulatorState.paused;
        notifyListeners();
        return true;
      }
      
      // Native path
      final biosPath = _getBiosPath(rom.platform);
      if (biosPath != null && File(biosPath).existsSync()) {
        _core!.loadBIOS(biosPath);
      }

      if (!_core!.loadROM(rom.path)) {
        _errorMessage = 'Failed to load ROM: ${rom.name}';
        notifyListeners();
        return false;
      }

      // Load SRAM (battery save) if exists
      await _loadSram(rom);

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
    if (_state != EmulatorState.paused) return;
    if (!_useStub && _core == null) return;
    if (_useStub && _stub == null) return;

    _state = EmulatorState.running;
    _frameStopwatch = Stopwatch()..start();
    _frameCount = 0;
    _startFrameLoop();
    notifyListeners();
  }

  /// Pause emulation (also saves SRAM)
  Future<void> pause() async {
    if (_state != EmulatorState.running) return;

    _state = EmulatorState.paused;
    _frameTimer?.cancel();
    _frameTimer = null;
    
    // Auto-save SRAM when pausing
    await saveSram();
    
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
    if (_useStub) {
      _stub?.reset();
    } else {
      _core?.reset();
    }
    if (_state == EmulatorState.paused) {
      _runSingleFrame();
    }
  }

  void _startFrameLoop() {
    _frameTimer?.cancel();
    _lastFrameTime = DateTime.now();
    _frameAccumulator = Duration.zero;
    
    // Use a fast timer and accumulator for precise frame pacing
    _frameTimer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      if (_state != EmulatorState.running) return;
      
      final now = DateTime.now();
      final elapsed = now.difference(_lastFrameTime);
      _lastFrameTime = now;
      _frameAccumulator += elapsed;
      
      // Run frames to catch up, but limit to avoid spiral of death
      int framesRun = 0;
      while (_frameAccumulator >= _targetFrameTime && framesRun < 3) {
        _runFrame();
        _frameAccumulator -= _targetFrameTime;
        framesRun++;
      }
      
      // If we're way behind, reset accumulator
      if (_frameAccumulator > _targetFrameTime * 5) {
        _frameAccumulator = Duration.zero;
      }
    });
  }
  
  DateTime _lastFrameTime = DateTime.now();
  Duration _frameAccumulator = Duration.zero;

  void _runFrame() {
    if (_useStub) {
      if (_stub == null || !_stub!.isRunning) return;
      _stub!.runFrame();
      _frameCount++;
      
      final pixels = _stub!.getVideoBuffer();
      if (pixels != null && onFrame != null) {
        onFrame!(pixels, _stub!.width, _stub!.height);
      }
    } else {
      if (_core == null || !_core!.isRunning) return;
      _core!.runFrame();
      _frameCount++;

      final pixels = _core!.getVideoBuffer();
      if (pixels != null && onFrame != null) {
        onFrame!(pixels, _core!.width, _core!.height);
      }
      
      // Note: Audio is now handled natively by OpenSL ES on Android
      // No need to process audio buffer in Dart
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
    if (_useStub) {
      if (_stub == null || !_stub!.isRunning) return;
      _stub!.runFrame();
      final pixels = _stub!.getVideoBuffer();
      if (pixels != null && onFrame != null) {
        onFrame!(pixels, _stub!.width, _stub!.height);
      }
    } else {
      if (_core == null || !_core!.isRunning) return;
      _core!.runFrame();
      final pixels = _core!.getVideoBuffer();
      if (pixels != null && onFrame != null) {
        onFrame!(pixels, _core!.width, _core!.height);
      }
    }
  }

  /// Set key states
  void setKeys(int keys) {
    if (_useStub) {
      _stub?.setKeys(keys);
    } else {
      _core?.setKeys(keys);
    }
  }

  /// Press a key
  void pressKey(int key) {
    if (_useStub) {
      _stub?.pressKey(key);
    } else {
      _core?.pressKey(key);
    }
  }

  /// Release a key
  void releaseKey(int key) {
    if (_useStub) {
      _stub?.releaseKey(key);
    } else {
      _core?.releaseKey(key);
    }
  }

  /// Save state to slot
  Future<bool> saveState(int slot) async {
    if (_useStub) return _stub?.saveState(slot) ?? false;
    if (_core == null) return false;
    return _core!.saveState(slot);
  }

  /// Load state from slot
  Future<bool> loadState(int slot) async {
    if (_useStub) {
      final success = _stub?.loadState(slot) ?? false;
      if (success && _state == EmulatorState.paused) {
        _runSingleFrame();
      }
      return success;
    }
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
  Future<void> stop() async {
    _frameTimer?.cancel();
    _frameTimer = null;
    
    // Save SRAM before stopping
    await saveSram();
    
    if (_useStub) {
      _stub?.dispose();
      _stub = null;
    } else {
      _core?.dispose();
      _core = null;
    }
    _currentRom = null;
    _state = EmulatorState.uninitialized;
    _frameCount = 0;
    _currentFps = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _frameTimer?.cancel();
    _stub?.dispose();
    _core?.dispose();
    super.dispose();
  }
}
