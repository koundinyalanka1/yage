import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../core/mgba_bindings.dart';
import '../core/mgba_stub.dart';
import '../models/game_rom.dart';
import '../models/emulator_settings.dart';
import 'link_cable_service.dart';
import 'ra_runtime_service.dart';

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
  String? _saveDir;

  /// Public accessor for the app-internal save directory (for backup service).
  String? get saveDir => _saveDir;
  
  Timer? _frameTimer;
  Timer? _autoSaveTimer;
  
  /// Simple future-chaining mutex that serializes SRAM saves so concurrent
  /// callers (auto-save timer, pause, stop) never write to the same file at
  /// the same time.
  Future<void> _sramSaveLock = Future.value();
  Stopwatch? _frameStopwatch;
  int _frameCount = 0;
  double _currentFps = 0;
  double _speedMultiplier = 1.0;
  
  /// Guard flag: true only while the frame loop should be actively running.
  /// Checked at the very top of every timer tick so that already-enqueued
  /// callbacks become no-ops the instant [pause] / [stop] flips it to false.
  bool _frameLoopActive = false;
  
  // Play time tracking — accumulates while the emulator is running
  final Stopwatch _playTimeStopwatch = Stopwatch();
  int _flushedPlayTimeSeconds = 0;
  
  /// Link cable service for network multiplayer (set externally).
  LinkCableService? linkCable;

  /// RA runtime service for per-frame achievement processing (set externally).
  RARuntimeService? raRuntime;

  /// Whether the native core supports link cable I/O register access.
  bool get isLinkSupported {
    if (_useStub) return _stub?.isLinkSupported ?? false;
    return _core?.isLinkSupported ?? false;
  }

  // Rewind state
  bool _isRewinding = false;
  int _rewindCaptureCounter = 0;
  int _rewindStepCounter = 0;
  static const int _rewindCaptureInterval = 5;  // Capture every 5 frames
  static const int _rewindStepFrames = 3;        // Pop state every 3 frame-ticks while rewinding
  
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
  bool get isRewinding => _isRewinding;
  
  /// Total play time in the current session (seconds)
  int get sessionPlayTimeSeconds => _playTimeStopwatch.elapsed.inSeconds;
  
  /// Consume accumulated play time since last flush.
  /// Returns seconds played since the last call to this method.
  int flushPlayTime() {
    final total = _playTimeStopwatch.elapsed.inSeconds;
    final delta = total - _flushedPlayTimeSeconds;
    _flushedPlayTimeSeconds = total;
    return delta;
  }
  
  /// Set emulation speed (0.5x, 1x, 2x, 4x, etc.)
  void setSpeed(double speed) {
    _speedMultiplier = speed.clamp(0.25, 8.0);
    notifyListeners();
  }
  
  /// Toggle fast forward between 1x and the configured turbo speed from settings
  void toggleFastForward() {
    if (_speedMultiplier > 1.0) {
      _speedMultiplier = 1.0;
    } else {
      _speedMultiplier = _settings.turboSpeed;
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
          _saveDir = saveDir;
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

  /// Get the directory where save files are stored for a ROM.
  /// Uses the app-internal saves directory.
  String _getRomSaveDir(GameRom rom) {
    return _saveDir ?? p.dirname(rom.path);
  }

  /// Get the .sav file path for a ROM (battery/SRAM save) — stored next to the ROM
  String _getSramPath(GameRom rom) {
    final saveDir = _getRomSaveDir(rom);
    final saveName = p.basenameWithoutExtension(rom.path);
    return p.join(saveDir, '$saveName.sav');
  }

  /// Load SRAM from .sav file if it exists.
  /// Searches multiple directories so saves from before a reinstall are found.
  Future<void> _loadSram(GameRom rom) async {
    if (_useStub || _core == null) return;

    final saveName = '${p.basenameWithoutExtension(rom.path)}.sav';
    final searchDirs = _allSaveDirectories(rom);

    for (final dir in searchDirs) {
      try {
        final sramPath = p.join(dir, saveName);
        if (File(sramPath).existsSync()) {
          final success = _core!.loadSram(sramPath);
          debugPrint('Loaded SRAM from $sramPath: $success');
          return;
        }
      } catch (e) {
        debugPrint('Error checking SRAM in $dir: $e');
      }
    }
    debugPrint('No SRAM file found for ${rom.name}');
  }

  /// All directories where save files might live, in priority order.
  List<String> _allSaveDirectories(GameRom rom) {
    final dirs = <String>{};
    // 1. App-internal saves directory
    if (_saveDir != null) dirs.add(_saveDir!);
    // 2. Next to the ROM (for ROMs in internal storage)
    dirs.add(p.dirname(rom.path));
    return dirs.toList();
  }

  /// Save SRAM to .sav file.
  ///
  /// Uses a future-chaining lock so that concurrent callers (auto-save timer,
  /// pause, stop) are serialized — each waits for the previous write to finish
  /// before starting its own, preventing file corruption.
  Future<void> saveSram() {
    final previous = _sramSaveLock;
    final completer = Completer<void>();
    _sramSaveLock = completer.future;

    return previous.then((_) async {
      if (_useStub || _core == null || _currentRom == null) return;

      try {
        final sramPath = _getSramPath(_currentRom!);
        final success = _core!.saveSram(sramPath);
        debugPrint('Saved SRAM to $sramPath: $success');
      } catch (e) {
        debugPrint('Error saving SRAM: $e');
      }
    }).whenComplete(() {
      completer.complete();
    });
  }

  /// Delete all save data for a game: SRAM (.sav), save states (.ss0-5),
  /// and save state thumbnails (.ss0.png-5.png).
  /// Returns the number of files deleted.
  Future<int> deleteSaveData(GameRom rom) async {
    int deleted = 0;
    final saveDir = _getRomSaveDir(rom);
    final baseName = p.basenameWithoutExtension(rom.path);

    // Also check app-internal save dir in case saves were created there
    final dirs = <String>{saveDir};
    if (_saveDir != null && _saveDir != saveDir) {
      dirs.add(_saveDir!);
    }

    for (final dir in dirs) {
      // SRAM (.sav)
      final sramFile = File(p.join(dir, '$baseName.sav'));
      if (sramFile.existsSync()) {
        try { sramFile.deleteSync(); deleted++; } catch (_) {}
      }

      // Save states and thumbnails (slots 0-5)
      for (int slot = 0; slot < 6; slot++) {
        final stateFile = File(p.join(dir, '$baseName.ss$slot'));
        if (stateFile.existsSync()) {
          try { stateFile.deleteSync(); deleted++; } catch (_) {}
        }
        final ssFile = File(p.join(dir, '$baseName.ss$slot.png'));
        if (ssFile.existsSync()) {
          try { ssFile.deleteSync(); deleted++; } catch (_) {}
        }
      }

      // Screenshots (timestamped PNGs matching <baseName>_*.png)
      try {
        final directory = Directory(dir);
        if (directory.existsSync()) {
          for (final entity in directory.listSync()) {
            if (entity is File) {
              final name = p.basename(entity.path);
              if (name.startsWith('${baseName}_') && name.endsWith('.png')) {
                try { entity.deleteSync(); deleted++; } catch (_) {}
              }
            }
          }
        }
      } catch (_) {}
    }

    debugPrint('Deleted $deleted save file(s) for ${rom.name}');
    return deleted;
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

      // Point the native core's save directory at the ROM's folder
      final romSaveDir = _getRomSaveDir(rom);
      _core!.setSaveDir(romSaveDir);

      if (!_core!.loadROM(rom.path)) {
        _errorMessage = 'Failed to load ROM: ${rom.name}';
        notifyListeners();
        return false;
      }

      // Load SRAM (battery save) if exists
      await _loadSram(rom);

      // Apply audio settings to the native core
      _applyAudioSettings();

      // Apply color palette (for original GB games)
      _applyColorPalette();

      // Initialize rewind buffer if enabled
      if (_settings.enableRewind) {
        _initRewind();
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
    if (_state != EmulatorState.paused) return;
    if (!_useStub && _core == null) return;
    if (_useStub && _stub == null) return;

    _state = EmulatorState.running;
    _frameLoopActive = true;
    _frameStopwatch = Stopwatch()..start();
    _frameCount = 0;
    _playTimeStopwatch.start();
    _startFrameLoop();
    _startAutoSaveTimer();
    notifyListeners();
  }

  /// Pause emulation (also saves SRAM)
  Future<void> pause() async {
    if (_state != EmulatorState.running) return;

    // Stop rewind if active
    if (_isRewinding) stopRewind();

    // Deactivate the frame loop guard first so any already-enqueued timer
    // callbacks become no-ops before we update the rest of the state.
    _frameLoopActive = false;
    _state = EmulatorState.paused;
    _frameTimer?.cancel();
    _frameTimer = null;
    _playTimeStopwatch.stop();
    _stopAutoSaveTimer();
    
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
    _frameTimer = null;
    _lastFrameTime = DateTime.now();
    _frameAccumulator = Duration.zero;
    
    // Adaptive frame loop: instead of a 1 ms periodic timer that fires
    // ~1000 times/sec (with ~940 no-ops), schedule each tick to wake up
    // right when the next frame is due. At 1× speed this means ~60
    // callbacks/sec; at 8× turbo ~480/sec — dramatically less CPU waste.
    _scheduleNextTick();
  }
  
  /// Schedule the next frame tick using [Future.delayed] with a calculated
  /// sleep duration, preserving the accumulator-based catch-up model.
  void _scheduleNextTick() {
    if (!_frameLoopActive || _state != EmulatorState.running) return;

    final now = DateTime.now();
    final elapsed = now.difference(_lastFrameTime);
    _lastFrameTime = now;
    _frameAccumulator += elapsed;

    // Run frames to catch up, but cap at 3 to avoid spiral of death
    int framesRun = 0;
    while (_frameLoopActive &&
           _frameAccumulator >= _targetFrameTime &&
           framesRun < 3) {
      _runFrame();
      _frameAccumulator -= _targetFrameTime;
      framesRun++;
    }

    // If we're way behind, reset accumulator to avoid permanent catch-up
    if (_frameAccumulator > _targetFrameTime * 5) {
      _frameAccumulator = Duration.zero;
    }

    // Bail if the loop was deactivated during frame execution
    if (!_frameLoopActive) return;

    // Calculate how long to sleep until the next frame is due.
    // If the accumulator already exceeds a frame time (we're behind),
    // schedule immediately (Duration.zero) so we catch up ASAP.
    final remaining = _targetFrameTime - _frameAccumulator;
    final delay = remaining > Duration.zero ? remaining : Duration.zero;

    // Use a one-shot Timer so we get a concrete Timer reference we can
    // cancel synchronously from pause()/stop().
    _frameTimer = Timer(delay, _scheduleNextTick);
  }
  
  DateTime _lastFrameTime = DateTime.now();
  Duration _frameAccumulator = Duration.zero;

  void _runFrame() {
    // Bail out immediately if the loop was deactivated between iterations
    // (e.g. pause() or stop() called while we were mid-catch-up).
    if (!_frameLoopActive) return;

    // ── Rewind mode: step backward through ring buffer ──
    if (_isRewinding && !_useStub) {
      _rewindStepCounter++;
      if (_rewindStepCounter >= _rewindStepFrames) {
        _rewindStepCounter = 0;
        _performRewindStep();
      }
      _frameCount++;
      _updateFps();
      return;
    }

    // ── Normal frame execution ──
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

      // Capture rewind snapshot every N frames
      if (_settings.enableRewind) {
        _rewindCaptureCounter++;
        if (_rewindCaptureCounter >= _rewindCaptureInterval) {
          _rewindCaptureCounter = 0;
          _core!.rewindPush();
        }
      }

      // ── Link Cable SIO polling ──
      _pollLinkCable();

      // ── RetroAchievements per-frame processing ──
      raRuntime?.processFrame();
    }

    _updateFps();
  }

  void _updateFps() {
    // Calculate FPS — update every 500ms for a responsive counter
    if (_frameStopwatch != null && _frameStopwatch!.elapsedMilliseconds >= 500) {
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

  // ── Rewind ──

  /// Initialize the rewind ring buffer based on current settings.
  /// Call after a ROM is loaded and the native state size is known.
  void _initRewind() {
    if (_useStub || _core == null) return;

    final capturesPerSecond = 60.0 / _rewindCaptureInterval;
    final capacity = (capturesPerSecond * _settings.rewindBufferSeconds).round();
    _core!.rewindInit(capacity.clamp(12, 256));
    _rewindCaptureCounter = 0;
  }

  /// Start rewinding (call while the rewind button is held).
  void startRewind() {
    if (!_settings.enableRewind || _useStub) return;
    if (_state != EmulatorState.running || _core == null) return;

    _isRewinding = true;
    _rewindStepCounter = 0;

    // Mute audio during rewind to avoid garbled sound
    _core!.setAudioEnabled(false);

    // Perform an immediate first step for instant feedback
    _performRewindStep();

    notifyListeners();
  }

  /// Stop rewinding (call when the rewind button is released).
  void stopRewind() {
    if (!_isRewinding) return;

    _isRewinding = false;

    // Restore audio settings
    if (_core != null) {
      _applyAudioSettings();
    }

    notifyListeners();
  }

  /// Pop one state from the rewind buffer and display it.
  ///
  /// Automatically stops rewinding when the buffer is exhausted or the pop
  /// fails, preventing repeated no-op calls and potential stale-frame display.
  void _performRewindStep() {
    if (_core == null) return;

    final count = _core!.rewindCount();
    if (count <= 0) {
      // Buffer exhausted — stop rewinding so the user gets clear feedback
      // instead of silently sitting on the last frame.
      debugPrint('Rewind buffer empty — auto-stopping rewind');
      stopRewind();
      return;
    }

    final popResult = _core!.rewindPop();
    if (popResult != 0) {
      // Pop failed (corrupt buffer, internal error, etc.) — stop rewinding
      // to avoid rendering frames from an unknown state.
      debugPrint('Rewind pop failed (result=$popResult) — auto-stopping rewind');
      stopRewind();
      return;
    }

    // Pop succeeded — run one frame to produce video output from the
    // restored state. Re-check _core since stopRewind path above may
    // have been triggered by a concurrent pause.
    if (_core == null || !_core!.isRunning) return;
    _core!.runFrame();

    final pixels = _core!.getVideoBuffer();
    if (pixels != null && onFrame != null) {
      onFrame!(pixels, _core!.width, _core!.height);
    }
  }

  // ── Link Cable ──

  /// Poll the SIO registers and exchange data with the link cable peer.
  /// Called once per frame when a [LinkCableService] is connected.
  void _pollLinkCable() {
    final lc = linkCable;
    if (lc == null || lc.state != LinkCableState.connected) return;
    if (_useStub || _core == null) return;

    // If the peer sent us a byte and a transfer is pending, inject it
    if (lc.hasIncomingData) {
      final status = _core!.linkGetTransferStatus();
      if (status >= 0) {
        // Exchange: write incoming byte, get outgoing byte, complete transfer
        final incoming = lc.consumeIncomingData();
        if (incoming >= 0) {
          _core!.linkExchangeData(incoming);
        }
      }
    }

    // If a transfer is pending on our side (master clock), send it out
    final status = _core!.linkGetTransferStatus();
    if (status == 1 && !lc.isAwaitingReply) {
      // Read the outgoing byte from SB
      final outgoing = _core!.linkReadByte(0xFF01); // GB_REG_SB
      if (outgoing >= 0) {
        lc.sendSioData(outgoing);
      }
    }
  }

  /// Set audio volume (0.0 = mute, 1.0 = full)
  void setVolume(double volume) {
    if (_useStub) {
      _stub?.setVolume(volume);
    } else {
      _core?.setVolume(volume);
    }
  }

  /// Enable or disable audio
  void setAudioEnabled(bool enabled) {
    if (_useStub) {
      _stub?.setAudioEnabled(enabled);
    } else {
      _core?.setAudioEnabled(enabled);
    }
  }

  /// Set color palette for original GB games
  /// Pass paletteIndex = -1 to disable palette remapping
  void setColorPalette(int paletteIndex, List<int> colors) {
    if (_useStub) {
      _stub?.setColorPalette(paletteIndex, colors);
    } else {
      _core?.setColorPalette(paletteIndex, colors);
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

  /// Get the current video buffer (raw RGBA pixels)
  Uint8List? getVideoBufferRaw() {
    if (_useStub) return _stub?.getVideoBuffer();
    return _core?.getVideoBuffer();
  }

  /// Get the save state file path for a slot — stored next to the ROM
  /// Get the save state file path for a slot.
  /// Searches all known save directories for an existing file; if none found,
  /// returns a path in the primary save directory (for creating new saves).
  String? getStatePath(int slot) {
    if (_currentRom == null) return null;
    final romName = p.basenameWithoutExtension(_currentRom!.path);
    final fileName = '$romName.ss$slot';

    // Search for existing state file
    for (final dir in _allSaveDirectories(_currentRom!)) {
      final path = p.join(dir, fileName);
      if (File(path).existsSync()) return path;
    }
    // Default: write to primary save dir
    final saveDir = _getRomSaveDir(_currentRom!);
    return p.join(saveDir, fileName);
  }

  /// Get the screenshot file path for a save state slot.
  /// Searches all known save directories for an existing file.
  String? getStateScreenshotPath(int slot) {
    if (_currentRom == null) return null;
    final romName = p.basenameWithoutExtension(_currentRom!.path);
    final fileName = '$romName.ss$slot.png';

    // Search for existing screenshot
    for (final dir in _allSaveDirectories(_currentRom!)) {
      final path = p.join(dir, fileName);
      if (File(path).existsSync()) return path;
    }
    // Default: write to primary save dir
    final saveDir = _getRomSaveDir(_currentRom!);
    return p.join(saveDir, fileName);
  }

  /// Save state to slot (also captures a screenshot thumbnail)
  Future<bool> saveState(int slot) async {
    bool success;
    if (_useStub) {
      success = _stub?.saveState(slot) ?? false;
    } else if (_core == null) {
      return false;
    } else {
      success = _core!.saveState(slot);
    }
    if (success) {
      await _saveStateScreenshot(slot);
    }
    return success;
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

  /// Capture the current video frame and save as PNG for save state thumbnail
  Future<void> _saveStateScreenshot(int slot) async {
    final path = getStateScreenshotPath(slot);
    if (path == null) return;

    final pixels = getVideoBufferRaw();
    if (pixels == null) return;

    final w = screenWidth;
    final h = screenHeight;

    try {
      // Copy pixel data since native memory may be reused
      final pixelsCopy = Uint8List.fromList(pixels);

      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixelsCopy, w, h, ui.PixelFormat.rgba8888,
        (image) => completer.complete(image),
      );
      final image = await completer.future;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();

      if (byteData != null) {
        await File(path).writeAsBytes(byteData.buffer.asUint8List());
      }
    } catch (e) {
      debugPrint('Error saving state screenshot: $e');
    }
  }

  /// Capture the current frame as a PNG and save it next to the ROM.
  /// Returns the saved file path on success, null on failure.
  Future<String?> captureScreenshot() async {
    if (_currentRom == null) return null;

    final pixels = getVideoBufferRaw();
    if (pixels == null) return null;

    final w = screenWidth;
    final h = screenHeight;

    try {
      final pixelsCopy = Uint8List.fromList(pixels);

      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixelsCopy, w, h, ui.PixelFormat.rgba8888,
        (image) => completer.complete(image),
      );
      final image = await completer.future;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();

      if (byteData == null) return null;

      final saveDir = _getRomSaveDir(_currentRom!);
      final romName = p.basenameWithoutExtension(_currentRom!.path);
      final ts = DateTime.now();
      final stamp = '${ts.year}${ts.month.toString().padLeft(2, '0')}'
          '${ts.day.toString().padLeft(2, '0')}_'
          '${ts.hour.toString().padLeft(2, '0')}'
          '${ts.minute.toString().padLeft(2, '0')}'
          '${ts.second.toString().padLeft(2, '0')}';
      final filePath = p.join(saveDir, '${romName}_$stamp.png');

      await File(filePath).writeAsBytes(byteData.buffer.asUint8List());
      debugPrint('Screenshot saved to $filePath');
      return filePath;
    } catch (e) {
      debugPrint('Error capturing screenshot: $e');
      return null;
    }
  }

  /// Update settings — applies audio/palette changes to the native core immediately.
  /// Only notifies listeners if settings actually changed.
  void updateSettings(EmulatorSettings newSettings) {
    if (identical(_settings, newSettings)) return;
    
    final oldSettings = _settings;
    _settings = newSettings;

    // Apply audio settings changes to the native core in real-time
    if (oldSettings.volume != newSettings.volume ||
        oldSettings.enableSound != newSettings.enableSound) {
      _applyAudioSettings();
    }

    // Apply color palette changes
    if (oldSettings.selectedColorPalette != newSettings.selectedColorPalette) {
      _applyColorPalette();
    }

    // Apply turbo speed changes — if fast-forward is active, update to new speed
    if (oldSettings.turboSpeed != newSettings.turboSpeed && _speedMultiplier > 1.0) {
      _speedMultiplier = newSettings.turboSpeed;
      notifyListeners();
    }

    // If turbo was disabled in settings while fast-forward is active, reset to 1x
    if (oldSettings.enableTurbo && !newSettings.enableTurbo && _speedMultiplier > 1.0) {
      _speedMultiplier = 1.0;
      notifyListeners();
    }

    // Handle rewind setting changes
    if (oldSettings.enableRewind != newSettings.enableRewind) {
      if (newSettings.enableRewind && !_useStub && _core != null &&
          _state != EmulatorState.uninitialized && _currentRom != null) {
        _initRewind();
      } else if (!newSettings.enableRewind) {
        if (_isRewinding) stopRewind();
        if (!_useStub && _core != null) _core!.rewindDeinit();
      }
    }
    if (oldSettings.rewindBufferSeconds != newSettings.rewindBufferSeconds &&
        newSettings.enableRewind && !_useStub && _core != null &&
        _state != EmulatorState.uninitialized) {
      _initRewind(); // Reinitialize with new capacity
    }

    // Restart auto-save timer if interval changed while running
    if (oldSettings.autoSaveInterval != newSettings.autoSaveInterval &&
        _state == EmulatorState.running) {
      _startAutoSaveTimer();
    }
  }

  /// Apply current audio settings (volume + mute) to the native core
  void _applyAudioSettings() {
    setAudioEnabled(_settings.enableSound);
    setVolume(_settings.enableSound ? _settings.volume : 0.0);
  }

  /// Apply color palette to the native core (only for original GB games)
  void _applyColorPalette() {
    final paletteIndex = _settings.selectedColorPalette;
    
    // Only apply palette remapping for original GB games
    if (platform != GamePlatform.gb) {
      // Disable palette for non-GB games
      setColorPalette(-1, [0, 0, 0, 0]);
      return;
    }

    if (paletteIndex < 0 || paletteIndex >= GBColorPalette.palettes.length) {
      // Disable palette (use original colors)
      setColorPalette(-1, [0, 0, 0, 0]);
      return;
    }

    final palette = GBColorPalette.palettes[paletteIndex];
    // Convert 0xRRGGBB to 0xFFRRGGBB (add full alpha)
    final colors = palette.map((c) => 0xFF000000 | c).toList();
    setColorPalette(paletteIndex, colors);
  }

  /// Start the periodic auto-save timer based on settings.
  /// Does nothing if autoSaveInterval is 0 (disabled).
  void _startAutoSaveTimer() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;

    final interval = _settings.autoSaveInterval;
    if (interval <= 0) return;

    _autoSaveTimer = Timer.periodic(Duration(seconds: interval), (_) {
      if (_state == EmulatorState.running) {
        saveSram();
        debugPrint('Auto-save SRAM (every ${interval}s)');
      }
    });
  }

  /// Stop the auto-save timer.
  void _stopAutoSaveTimer() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
  }

  /// Stop and unload current ROM
  Future<void> stop() async {
    if (_isRewinding) stopRewind();
    
    // Deactivate the frame loop guard first so any already-enqueued timer
    // callbacks become no-ops before we tear down the core.
    _frameLoopActive = false;
    _frameTimer?.cancel();
    _frameTimer = null;
    _playTimeStopwatch.stop();
    _stopAutoSaveTimer();
    
    // Save SRAM before stopping
    await saveSram();
    
    // Reset rewind state
    _isRewinding = false;
    _rewindCaptureCounter = 0;
    _rewindStepCounter = 0;
    
    if (_useStub) {
      _stub?.dispose();
      _stub = null;
    } else {
      _core?.dispose();
      _core = null;
    }
    // Reset play time tracking for next session
    _playTimeStopwatch.reset();
    _flushedPlayTimeSeconds = 0;
    _currentRom = null;
    _state = EmulatorState.uninitialized;
    _frameCount = 0;
    _currentFps = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _frameTimer?.cancel();
    _autoSaveTimer?.cancel();
    _stub?.dispose();
    _core?.dispose();
    super.dispose();
  }
}
