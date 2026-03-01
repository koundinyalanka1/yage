import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../core/mgba_bindings.dart';
import '../core/mgba_stub.dart';
import '../utils/device_memory.dart';
import '../models/game_rom.dart';
import '../models/emulator_settings.dart';
import 'link_cable_service.dart';
import 'rcheevos_client.dart';
import 'rom_folder_service.dart';

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
  
  /// True when the native (pthread) frame loop is actively driving
  /// emulation instead of the Dart Timer-based loop.
  bool _useNativeFrameLoop = false;

  /// NativeCallable handle for the native frame loop callback.
  /// Must stay alive as long as the native thread is running.
  NativeCallable<NativeFrameCallback>? _nativeFrameCallable;

  /// True when frames are delivered via Android Texture widget
  /// (ANativeWindow), bypassing decodeImageFromPixels entirely.
  bool _useTextureRendering = false;
  bool get useTextureRendering => _useTextureRendering;

  /// Enable texture rendering mode (call after creating the platform
  /// texture via the method channel).
  void setTextureRendering(bool enabled) {
    _useTextureRendering = enabled;
    debugPrint('EmulatorService: texture rendering ${enabled ? "enabled" : "disabled"}');
  }

  // Play time tracking — accumulates while the emulator is running
  final Stopwatch _playTimeStopwatch = Stopwatch();
  int _flushedPlayTimeSeconds = 0;
  
  /// Link cable service for network multiplayer (set externally).
  LinkCableService? linkCable;

  /// Native rcheevos client for per-frame achievement processing (set externally).
  RcheevosClient? rcheevosClient;

  /// Expose the native core for memory reading (used by RA runtime).
  MGBACore? get core => _core;

  /// Whether the native core supports link cable I/O register access.
  bool get isLinkSupported {
    if (_useStub) return _stub?.isLinkSupported ?? false;
    return _core?.isLinkSupported ?? false;
  }

  /// Whether rewind is supported for the current platform.
  /// NES and SNES (libretro cores) do not support rewind.
  bool get isRewindSupported {
    if (_useStub) return false;
    final p = _currentRom?.platform ?? platform;
    return p != GamePlatform.nes && p != GamePlatform.snes;
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
    // Propagate to native frame loop if active
    if (_useNativeFrameLoop) {
      _core?.frameLoopSetSpeed((_speedMultiplier * 100).round());
    }
    notifyListeners();
  }
  
  /// Toggle fast forward between 1x and the configured turbo speed from settings
  void toggleFastForward() {
    if (_speedMultiplier > 1.0) {
      _speedMultiplier = 1.0;
    } else {
      _speedMultiplier = _settings.turboSpeed;
    }
    // Propagate to native frame loop if active
    if (_useNativeFrameLoop) {
      _core?.frameLoopSetSpeed((_speedMultiplier * 100).round());
    }
    notifyListeners();
  }
  
  int get screenWidth {
    if (_useStub) return _stub?.width ?? 240;
    // Use display dimensions when native frame loop is active
    // (may differ from core dimensions during SGB mode transitions)
    if (_useNativeFrameLoop) return _core?.displayWidth ?? 240;
    return _core?.width ?? 240;
  }
  
  int get screenHeight {
    if (_useStub) return _stub?.height ?? 160;
    if (_useNativeFrameLoop) return _core?.displayHeight ?? 160;
    return _core?.height ?? 160;
  }
  
  GamePlatform get platform {
    if (_useStub) return _stub?.platform ?? GamePlatform.unknown;
    return _core?.platform ?? GamePlatform.unknown;
  }

  /// Initialize the emulator service for the given [platform].
  ///
  /// Selects the appropriate libretro core (mGBA for GB/GBC/GBA, FCEUmm
  /// for NES, Snes9x2010 for SNES) and loads the native wrapper.
  /// If [platform] is `null`, defaults to mGBA (GB/GBA).
  Future<bool> initialize({GamePlatform? platform}) async {
    if (_state != EmulatorState.uninitialized) return true;

    try {
      // Select the right libretro core for the platform
      if (platform != null) {
        _bindings.selectCore(platform);
      }

      // Try to load native library first
      if (_bindings.load()) {
        _core = MGBACore(_bindings);

        // If the native wrapper supports multi-core, tell it which core
        // to load before initializing. NES/SNES: set explicit path.
        // GB/GBC/GBA: clear path so we use default mGBA (avoids input regression).
        if (platform != null && _bindings.isCoreSelectionLoaded) {
          if (platform == GamePlatform.nes || platform == GamePlatform.snes) {
            final coreLib = MGBABindings.platformCoreLibs[platform];
            if (coreLib != null) {
              _core!.setCoreLibrary(coreLib);
            }
          } else {
            // GB/GBC/GBA: explicitly clear so we use default (handles switch from NES/SNES)
            _core!.setCoreLibrary('');
          }
        }

        if (_core!.initialize()) {
          final saveDir = await _getSaveDirectory();
          _saveDir = saveDir;
          _core!.setSaveDir(saveDir);
          _useStub = false;
          _state = EmulatorState.ready;
          notifyListeners();
          return true;
        }
        // NES/SNES: fail clearly instead of falling back to stub —
        // there's no useful "demo mode" for these platforms.
        if (platform == GamePlatform.nes || platform == GamePlatform.snes) {
          _errorMessage = 'Failed to load ${platform!.name.toUpperCase()} core. '
              'Please reinstall the app or check that cores are bundled.';
        } else {
          _errorMessage = 'Failed to initialize emulator core.';
        }
        _state = EmulatorState.error;
        notifyListeners();
        return false;
      }

      // Native library not available at all
      _errorMessage = 'Emulator engine not found. Please reinstall the app.';
      _state = EmulatorState.error;
      notifyListeners();
      return false;
    } catch (e) {
      debugPrint('Error initializing: $e');
      _errorMessage = 'Failed to initialize emulator: $e';
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
        if (success) _syncSaveToUserFolder(sramPath);
      } catch (e) {
        debugPrint('Error saving SRAM: $e');
      }
    }).whenComplete(() {
      completer.complete();
    });
  }

  /// Sync a save file to the user's ROMs folder if one is configured.
  /// Fire-and-forget; failures are logged.
  void _syncSaveToUserFolder(String sourcePath) {
    final folderUri = _settings.userRomsFolderUri;
    if (folderUri == null || folderUri.isEmpty) return;
    unawaited(RomFolderService.copySaveToUserFolder(folderUri, sourcePath));
  }

  /// Delete all save data for a game: SRAM (.sav), save states (.ss0-5),
  /// and save state thumbnails (.ss0.png-5.png).
  /// Returns the number of files deleted.
  Future<int> deleteSaveData(GameRom rom) async {
    int deleted = 0;
    final saveDir = _getRomSaveDir(rom);
    final baseName = p.basenameWithoutExtension(rom.path);
    final romBase = p.basename(rom.path);

    // Also check app-internal save dir in case saves were created there
    final dirs = <String>{saveDir};
    if (_saveDir != null && _saveDir != saveDir) {
      dirs.add(_saveDir!);
    }

    for (final dir in dirs) {
      // SRAM (.sav) — uses basenameWithoutExtension
      final sramFile = File(p.join(dir, '$baseName.sav'));
      if (sramFile.existsSync()) {
        try { sramFile.deleteSync(); deleted++; } catch (e) {
          debugPrint('Failed to delete SRAM file ${sramFile.path}: $e');
        }
      }

      // Save states and thumbnails (slots 0-5) — use full basename to match native
      for (int slot = 0; slot < 6; slot++) {
        final stateFile = File(p.join(dir, '$romBase.ss$slot'));
        if (stateFile.existsSync()) {
          try { stateFile.deleteSync(); deleted++; } catch (e) {
            debugPrint('Failed to delete save state ${stateFile.path}: $e');
          }
        }
        final ssFile = File(p.join(dir, '$romBase.ss$slot.png'));
        if (ssFile.existsSync()) {
          try { ssFile.deleteSync(); deleted++; } catch (e) {
            debugPrint('Failed to delete screenshot ${ssFile.path}: $e');
          }
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
                try { entity.deleteSync(); deleted++; } catch (e) {
                  debugPrint('Failed to delete screenshot ${entity.path}: $e');
                }
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Failed to list save directory $dir: $e');
      }
    }

    debugPrint('Deleted $deleted save file(s) for ${rom.name}');
    return deleted;
  }

  /// Load a ROM file
  Future<bool> loadRom(GameRom rom) async {
    // Re-initialize when switching platforms (e.g. SNES→GBA or GBA→NES).
    // Also when _currentRom is null but we have core/stub — previous load may have failed.
    final platformChanged = _currentRom?.platform != rom.platform;
    if (platformChanged || (_currentRom == null && (_core != null || _stub != null))) {
      _stub?.dispose();
      _stub = null;
      _core?.dispose();
      _core = null;
      _currentRom = null;
      _state = EmulatorState.uninitialized;
    }
    if (_state == EmulatorState.uninitialized) {
      if (!await initialize(platform: rom.platform)) return false;
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

      // Apply SGB border setting before loading the ROM
      // (the core reads the option at load time — only relevant for GB)
      if (rom.platform == GamePlatform.gb ||
          rom.platform == GamePlatform.gbc) {
        _core!.setSgbBorders(_settings.enableSgbBorders);
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

      // Apply color palette (for original GB games only)
      _applyColorPalette();

      // Initialize rewind buffer if enabled (not supported for NES/SNES)
      if (_settings.enableRewind &&
          rom.platform != GamePlatform.nes &&
          rom.platform != GamePlatform.snes) {
        _initRewind();
      }

      _currentRom = rom.copyWith(lastPlayed: DateTime.now());
      _state = EmulatorState.paused;
      // Reset input state so NES/SNES cores start with clean keys after platform switch
      setKeys(0);
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
      // NES and SNES libretro cores don't require BIOS files
      GamePlatform.nes => null,
      GamePlatform.snes => null,
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

  /// Whether the native frame loop is available and should be used.
  /// Only for the real native core (not stub) and only on platforms
  /// that support pthread (Android, Linux, macOS — NOT Windows).
  bool get _canUseNativeFrameLoop {
    if (_useStub || _core == null) return false;
    if (Platform.isWindows) return false;
    return _core!.isFrameLoopSupported;
  }

  /// Pause emulation.
  ///
  /// SRAM is NOT flushed here — it is only written when:
  ///   1. The game itself writes to SRAM (in-game save).
  ///   2. The auto-save timer fires (if enabled by the user).
  ///   3. The ROM is unloaded via [stop] (exit game).
  Future<void> pause() async {
    if (_state != EmulatorState.running) return;

    // Stop rewind if active
    if (_isRewinding) stopRewind();

    // Deactivate the frame loop guard first so any already-enqueued timer
    // callbacks become no-ops before we update the rest of the state.
    _frameLoopActive = false;
    _state = EmulatorState.paused;

    // Stop native frame loop if active (blocks until thread exits)
    _stopNativeFrameLoop();

    _frameTimer?.cancel();
    _frameTimer = null;
    _playTimeStopwatch.stop();
    _stopAutoSaveTimer();

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
    // Must stop native frame loop before resetting the core —
    // retro_reset() and retro_run() must not execute concurrently.
    final wasNative = _useNativeFrameLoop;
    if (wasNative) _stopNativeFrameLoop();

    if (_useStub) {
      _stub?.reset();
    } else {
      _core?.reset();
    }
    if (_state == EmulatorState.paused) {
      _runSingleFrame();
    }

    // Restart native frame loop
    if (wasNative && _state == EmulatorState.running) {
      _startNativeFrameLoop();
    }
  }

  void _startFrameLoop() {
    // Prefer native (pthread) frame loop on supported platforms.
    // This moves emulation to a dedicated thread, keeping the Dart/UI
    // thread free for layout and painting.  The native thread signals
    // Dart at ~60 Hz for display updates regardless of turbo speed.
    if (_canUseNativeFrameLoop && !_isRewinding) {
      _startNativeFrameLoop();
      return;
    }

    // Fallback: Dart Timer-based loop (stub mode, rewind, Windows)
    _startDartFrameLoop();
  }

  /// Start the Dart Timer-based frame loop (legacy fallback).
  void _startDartFrameLoop() {
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

  /// Start the native (pthread) frame loop.
  void _startNativeFrameLoop() {
    if (_useNativeFrameLoop) return; // already running

    // Create NativeCallable.listener — invocations from the native thread
    // are posted to the Dart event loop automatically.
    _nativeFrameCallable?.close();
    _nativeFrameCallable =
        NativeCallable<NativeFrameCallback>.listener(_onNativeFrameReady);

    // Configure native thread parameters
    final core = _core!;
    core.frameLoopSetSpeed((_speedMultiplier * 100).round());
    core.frameLoopSetRewind(
      enabled: _settings.enableRewind && isRewindSupported,
      interval: _rewindCaptureInterval,
    );
    core.frameLoopSetRcheevos(enabled: rcheevosClient != null);

    final ok = core.startFrameLoop(_nativeFrameCallable!.nativeFunction);
    if (ok) {
      _useNativeFrameLoop = true;
      debugPrint('EmulatorService: using native frame loop');
    } else {
      // Fall back to Dart Timer
      debugPrint('EmulatorService: native frame loop failed, falling back to Dart Timer');
      _nativeFrameCallable?.close();
      _nativeFrameCallable = null;
      _startDartFrameLoop();
    }
  }

  /// Stop the native frame loop (blocks until thread exits).
  void _stopNativeFrameLoop() {
    if (!_useNativeFrameLoop) return;
    _core?.stopFrameLoop();
    _nativeFrameCallable?.close();
    _nativeFrameCallable = null;
    _useNativeFrameLoop = false;
  }

  /// Called at ~60 Hz from the native thread (via NativeCallable.listener).
  /// Runs on the Dart event loop — safe to call Flutter APIs.
  void _onNativeFrameReady(int framesRun) {
    if (!_frameLoopActive || !_useNativeFrameLoop) return;

    // ── Read display buffer (only when NOT using texture rendering) ──
    // With texture rendering the native frame loop blits directly to the
    // ANativeWindow — no Dart-side buffer copy needed.
    if (!_useTextureRendering) {
      final core = _core;
      if (core != null && onFrame != null) {
        final pixels = core.getDisplayBuffer();
        if (pixels != null) {
          final w = core.displayWidth;
          final h = core.displayHeight;
          onFrame!(pixels, w, h);
        }
      }
    }

    // ── Link cable polling (at display rate — 60 Hz is fine) ──
    _pollLinkCable();

    // ── FPS from native thread ──
    final c = core;
    if (c != null) {
      final nativeFps = c.getFrameLoopFps();
      if (nativeFps > 0) {
        _currentFps = nativeFps;
        if (_settings.showFps) {
          notifyListeners();
        }
      }
    }
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

      if (_useTextureRendering) {
        // Zero-copy: blit directly to ANativeWindow surface.
        // No Dart-side buffer copy, no decodeImageFromPixels.
        _core!.textureBlit();
      } else {
        final pixels = _core!.getVideoBuffer();
        if (pixels != null && onFrame != null) {
          onFrame!(pixels, _core!.width, _core!.height);
        }
      }
      
      // Note: Audio is now handled natively by OpenSL ES on Android
      // No need to process audio buffer in Dart

      // Capture rewind snapshot every N frames (not for NES/SNES)
      if (_settings.enableRewind && isRewindSupported) {
        _rewindCaptureCounter++;
        if (_rewindCaptureCounter >= _rewindCaptureInterval) {
          _rewindCaptureCounter = 0;
          _core!.rewindPush();
        }
      }

      // ── Link Cable SIO polling ──
      _pollLinkCable();

      // ── RetroAchievements per-frame processing ──
      rcheevosClient?.doFrame();
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
      if (_useTextureRendering) {
        _core!.textureBlit();
      } else {
        final pixels = _core!.getVideoBuffer();
        if (pixels != null && onFrame != null) {
          onFrame!(pixels, _core!.width, _core!.height);
        }
      }
    }
  }

  // ── Rewind ──

  /// Initialize the rewind ring buffer based on current settings.
  /// Call after a ROM is loaded and the native state size is known.
  /// Capacity is capped by device memory to avoid OOM on low-RAM devices.
  void _initRewind() {
    if (_useStub || _core == null) return;

    final capturesPerSecond = 60.0 / _rewindCaptureInterval;
    final requested = (capturesPerSecond * _settings.rewindBufferSeconds).round();
    final cap = rewindCapacityCap();
    final capacity = requested.clamp(12, cap);
    if (capacity < requested) {
      debugPrint('Rewind: capped to $capacity snapshots (device RAM)');
    }
    _core!.rewindInit(capacity);
    _rewindCaptureCounter = 0;
  }

  /// Start rewinding (call while the rewind button is held).
  void startRewind() {
    if (!_settings.enableRewind || _useStub) return;
    if (!isRewindSupported) return;
    if (_state != EmulatorState.running || _core == null) return;

    // Stop native frame loop — rewind needs Dart-side step control
    final wasNative = _useNativeFrameLoop;
    if (wasNative) {
      _stopNativeFrameLoop();
    }

    _isRewinding = true;
    _rewindStepCounter = 0;

    // Mute audio during rewind to avoid garbled sound
    _core!.setAudioEnabled(false);

    // Start Dart Timer fallback for rewind stepping
    if (wasNative) {
      _startDartFrameLoop();
    }

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

    // Switch back to native frame loop if available.
    // The Dart Timer loop was started for rewind stepping — kill it and
    // restart the native thread now that normal emulation resumes.
    if (_canUseNativeFrameLoop && _state == EmulatorState.running) {
      _frameTimer?.cancel();
      _frameTimer = null;
      _startNativeFrameLoop();
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

    if (_useTextureRendering) {
      _core!.textureBlit();
    } else {
      final pixels = _core!.getVideoBuffer();
      if (pixels != null && onFrame != null) {
        onFrame!(pixels, _core!.width, _core!.height);
      }
    }
  }

  // ── Link Cable ──

  /// Poll the SIO registers and exchange data with the link cable peer.
  // ── Link Cable SIO register addresses ──
  // GB / GBC
  static const int _gbRegSB = 0xFF01; // Serial transfer data
  // GBA (Normal / Multi-player modes)
  static const int _gbaRegSIODATA8 = 0x0400012A; // 8-bit serial data / multi-player send
  static const int _gbaRegSIODATA32 = 0x04000120; // 32-bit serial data (lo halfword)
  static const int _gbaRegSIOCNT = 0x04000128; // Serial control

  /// Called once per frame when a [LinkCableService] is connected.
  /// Link cable is only supported for GB/GBC/GBA platforms.
  void _pollLinkCable() {
    final lc = linkCable;
    if (lc == null || lc.state != LinkCableState.connected) return;
    if (_useStub || _core == null) return;
    // Link cable is only for GB/GBA — skip for NES/SNES
    final p = platform;
    if (p == GamePlatform.nes || p == GamePlatform.snes) return;

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
      final outgoing = _readSioOutgoing();
      if (outgoing >= 0) {
        lc.sendSioData(outgoing);
      }
    }
  }

  /// Read the outgoing serial byte from the correct I/O register
  /// for the current platform.
  int _readSioOutgoing() {
    if (_core == null) return -1;

    final plat = platform;
    if (plat == GamePlatform.gba) {
      // GBA: check SIOCNT bit 12 to determine 8-bit vs 32-bit Normal mode.
      // SIOCNT is a 16-bit register at 0x04000128.  Bit 12 lives in the
      // high byte (0x04000129), at bit 4 of that byte.
      // In Multi-player mode the send register is at the same address as
      // SIODATA8, so 0x0400012A covers both Normal-8 and Multi-player.
      final siocntHi = _core!.linkReadByte(_gbaRegSIOCNT + 1);
      if (siocntHi < 0) return -1;

      // Bit 12 of SIOCNT (bit 4 in the high byte): 0 = 8-bit, 1 = 32-bit.
      final is32bit = (siocntHi & (1 << 4)) != 0;
      return _core!.linkReadByte(is32bit ? _gbaRegSIODATA32 : _gbaRegSIODATA8);
    }

    // GB / GBC: read from SB register
    return _core!.linkReadByte(_gbRegSB);
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

  /// Enable or disable SGB (Super Game Boy) border rendering.
  /// Must be called before loadRom for the change to take effect.
  void setSgbBorders(bool enabled) {
    if (!_useStub) {
      _core?.setSgbBorders(enabled);
    }
  }

  /// Set key states
  void setKeys(int keys) {
    if (kDebugMode && keys != 0) {
      debugPrint('Input: EmulatorService.setKeys keys=0x${keys.toRadixString(16)} useStub=$_useStub core=${_core != null}');
    }
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

  /// Get the current video buffer (raw RGBA pixels).
  /// When the native frame loop was recently active, prefers the display
  /// buffer snapshot (which is always a complete frame).
  Uint8List? getVideoBufferRaw() {
    if (_useStub) return _stub?.getVideoBuffer();
    return _core?.getVideoBuffer();
  }

  /// Get the save state file path for a slot — stored next to the ROM.
  /// Uses full ROM filename (e.g. "Game.nes.ss0") to match native libretro.
  /// Searches all known save directories for an existing file; if none found,
  /// returns a path in the primary save directory (for creating new saves).
  String? getStatePath(int slot) {
    if (_currentRom == null) return null;
    final romBase = p.basename(_currentRom!.path);
    final fileName = '$romBase.ss$slot';

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
  /// Uses full ROM filename to match native save state naming.
  /// Searches all known save directories for an existing file.
  String? getStateScreenshotPath(int slot) {
    if (_currentRom == null) return null;
    final romBase = p.basename(_currentRom!.path);
    final fileName = '$romBase.ss$slot.png';

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
    // Pause native frame loop to prevent concurrent core access
    final wasNative = _useNativeFrameLoop;
    if (wasNative) _stopNativeFrameLoop();

    bool success;
    if (_useStub) {
      success = _stub?.saveState(slot) ?? false;
    } else if (_core == null) {
      if (wasNative) _startNativeFrameLoop();
      return false;
    } else {
      success = _core!.saveState(slot);
    }
    if (success) {
      await _saveStateScreenshot(slot);
      final statePath = getStatePath(slot);
      final screenshotPath = getStateScreenshotPath(slot);
      if (statePath != null) _syncSaveToUserFolder(statePath);
      if (screenshotPath != null) _syncSaveToUserFolder(screenshotPath);
    }

    if (wasNative && _state == EmulatorState.running) _startNativeFrameLoop();
    return success;
  }

  /// Load state from slot
  Future<bool> loadState(int slot) async {
    // Pause native frame loop to prevent concurrent core access
    final wasNative = _useNativeFrameLoop;
    if (wasNative) _stopNativeFrameLoop();

    if (_useStub) {
      final success = _stub?.loadState(slot) ?? false;
      if (success && _state == EmulatorState.paused) {
        _runSingleFrame();
      }
      if (wasNative && _state == EmulatorState.running) _startNativeFrameLoop();
      return success;
    }
    if (_core == null) {
      if (wasNative && _state == EmulatorState.running) _startNativeFrameLoop();
      return false;
    }
    final success = _core!.loadState(slot);
    if (success && _state == EmulatorState.paused) {
      _runSingleFrame();
    }

    if (wasNative && _state == EmulatorState.running) _startNativeFrameLoop();
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
    if (_settings == newSettings) return;
    
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
      if (_useNativeFrameLoop) {
        _core?.frameLoopSetSpeed((_speedMultiplier * 100).round());
      }
      notifyListeners();
    }

    // If turbo was disabled in settings while fast-forward is active, reset to 1x
    if (oldSettings.enableTurbo && !newSettings.enableTurbo && _speedMultiplier > 1.0) {
      _speedMultiplier = 1.0;
      if (_useNativeFrameLoop) {
        _core?.frameLoopSetSpeed(100);
      }
      notifyListeners();
    }

    // Propagate rewind config to native frame loop
    if (_useNativeFrameLoop &&
        (oldSettings.enableRewind != newSettings.enableRewind)) {
      _core?.frameLoopSetRewind(
          enabled: newSettings.enableRewind && isRewindSupported,
          interval: _rewindCaptureInterval);
    }

    // Handle rewind setting changes
    if (oldSettings.enableRewind != newSettings.enableRewind) {
      if (newSettings.enableRewind && !_useStub && _core != null &&
          _state != EmulatorState.uninitialized && _currentRom != null &&
          isRewindSupported) {
        _initRewind();
      } else if (!newSettings.enableRewind) {
        if (_isRewinding) stopRewind();
        if (!_useStub && _core != null) _core!.rewindDeinit();
      }
    }
    if (oldSettings.rewindBufferSeconds != newSettings.rewindBufferSeconds &&
        newSettings.enableRewind && !_useStub && _core != null &&
        _state != EmulatorState.uninitialized && isRewindSupported) {
      _initRewind(); // Reinitialize with new capacity
    }

    // Apply SGB border setting to native core
    // Note: the actual border rendering only takes effect on ROM reload,
    // but we update the native flag immediately so the next ROM load uses it.
    if (oldSettings.enableSgbBorders != newSettings.enableSgbBorders) {
      if (!_useStub && _core != null) {
        _core!.setSgbBorders(newSettings.enableSgbBorders);
      }
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

    // Stop native frame loop if active (blocks until thread exits)
    _stopNativeFrameLoop();

    _frameTimer?.cancel();
    _frameTimer = null;
    _playTimeStopwatch.stop();
    _stopAutoSaveTimer();
    
    // Save SRAM before stopping, then reset the lock so any previously
    // queued saves don't execute against the destroyed core.
    await saveSram();
    _sramSaveLock = Future.value();
    
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

  /// Synchronously flush SRAM before disposing the native core.
  ///
  /// [dispose] cannot be async, so we call the synchronous save path
  /// directly.  This ensures save data is never lost when the service
  /// is disposed without an explicit [stop] call.
  @override
  void dispose() {
    _frameLoopActive = false;
    _frameTimer?.cancel();
    _autoSaveTimer?.cancel();

    // Best-effort SRAM flush — must be sync because dispose() is void.
    try {
      if (_currentRom != null) {
        final saveDir = _getRomSaveDir(_currentRom!);
        final sramPath =
            p.join(saveDir, '${p.basenameWithoutExtension(_currentRom!.path)}.sav');
        if (_useStub) {
          _stub?.saveSram(sramPath);
        } else {
          _core?.saveSram(sramPath);
        }
        _syncSaveToUserFolder(sramPath);
      }
    } catch (e) {
      debugPrint('dispose: SRAM flush failed — $e');
    }

    _stub?.dispose();
    _core?.dispose();
    super.dispose();
  }
}
