import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Native type definitions for mGBA core
typedef NativeCore = Pointer<Void>;
typedef NativeThread = Pointer<Void>;

/// Function signatures for mGBA library
typedef MgbaCoreCreateNative = NativeCore Function();
typedef MgbaCoreCreate = NativeCore Function();

typedef MgbaCoreInitNative = Int32 Function(NativeCore core);
typedef MgbaCoreInit = int Function(NativeCore core);

typedef MgbaCoreDestroyNative = Void Function(NativeCore core);
typedef MgbaCoreDestroy = void Function(NativeCore core);

typedef MgbaCoreLoadROMNative = Int32 Function(NativeCore core, Pointer<Utf8> path);
typedef MgbaCoreLoadROM = int Function(NativeCore core, Pointer<Utf8> path);

typedef MgbaCoreLoadBIOSNative = Int32 Function(NativeCore core, Pointer<Utf8> path);
typedef MgbaCoreLoadBIOS = int Function(NativeCore core, Pointer<Utf8> path);

typedef MgbaCoreResetNative = Void Function(NativeCore core);
typedef MgbaCoreReset = void Function(NativeCore core);

typedef MgbaCoreRunFrameNative = Void Function(NativeCore core);
typedef MgbaCoreRunFrame = void Function(NativeCore core);

typedef MgbaCoreSetKeysNative = Void Function(NativeCore core, Uint32 keys);
typedef MgbaCoreSetKeys = void Function(NativeCore core, int keys);

typedef MgbaCoreGetVideoBufferNative = Pointer<Uint32> Function(NativeCore core);
typedef MgbaCoreGetVideoBuffer = Pointer<Uint32> Function(NativeCore core);

typedef MgbaCoreGetAudioBufferNative = Pointer<Int16> Function(NativeCore core);
typedef MgbaCoreGetAudioBuffer = Pointer<Int16> Function(NativeCore core);

typedef MgbaCoreGetAudioSamplesNative = Int32 Function(NativeCore core);
typedef MgbaCoreGetAudioSamples = int Function(NativeCore core);

typedef MgbaCoreSaveStateNative = Int32 Function(NativeCore core, Int32 slot);
typedef MgbaCoreSaveState = int Function(NativeCore core, int slot);

typedef MgbaCoreLoadStateNative = Int32 Function(NativeCore core, Int32 slot);
typedef MgbaCoreLoadState = int Function(NativeCore core, int slot);

typedef MgbaCoreGetWidthNative = Int32 Function(NativeCore core);
typedef MgbaCoreGetWidth = int Function(NativeCore core);

typedef MgbaCoreGetHeightNative = Int32 Function(NativeCore core);
typedef MgbaCoreGetHeight = int Function(NativeCore core);

typedef MgbaCoreGetPlatformNative = Int32 Function(NativeCore core);
typedef MgbaCoreGetPlatform = int Function(NativeCore core);

typedef MgbaCoreSetSaveDirNative = Void Function(NativeCore core, Pointer<Utf8> path);
typedef MgbaCoreSetSaveDir = void Function(NativeCore core, Pointer<Utf8> path);

/// Game Boy key codes matching mGBA's input format
class GBAKey {
  static const int a = 1 << 0;
  static const int b = 1 << 1;
  static const int select = 1 << 2;
  static const int start = 1 << 3;
  static const int right = 1 << 4;
  static const int left = 1 << 5;
  static const int up = 1 << 6;
  static const int down = 1 << 7;
  static const int r = 1 << 8;
  static const int l = 1 << 9;
}

/// Platform types
enum GamePlatform {
  unknown,
  gb,
  gbc,
  gba,
}

/// mGBA native library bindings
class MGBABindings {
  late final DynamicLibrary _lib;
  bool _isLoaded = false;

  // Function pointers
  late final MgbaCoreCreate coreCreate;
  late final MgbaCoreInit coreInit;
  late final MgbaCoreDestroy coreDestroy;
  late final MgbaCoreLoadROM coreLoadROM;
  late final MgbaCoreLoadBIOS coreLoadBIOS;
  late final MgbaCoreReset coreReset;
  late final MgbaCoreRunFrame coreRunFrame;
  late final MgbaCoreSetKeys coreSetKeys;
  late final MgbaCoreGetVideoBuffer coreGetVideoBuffer;
  late final MgbaCoreGetAudioBuffer coreGetAudioBuffer;
  late final MgbaCoreGetAudioSamples coreGetAudioSamples;
  late final MgbaCoreSaveState coreSaveState;
  late final MgbaCoreLoadState coreLoadState;
  late final MgbaCoreGetWidth coreGetWidth;
  late final MgbaCoreGetHeight coreGetHeight;
  late final MgbaCoreGetPlatform coreGetPlatform;
  late final MgbaCoreSetSaveDir coreSetSaveDir;

  bool get isLoaded => _isLoaded;

  /// Load the mGBA dynamic library
  bool load() {
    if (_isLoaded) return true;

    try {
      String libraryPath;
      
      if (Platform.isWindows) {
        libraryPath = 'mgba.dll';
      } else if (Platform.isLinux) {
        libraryPath = 'libmgba.so';
      } else if (Platform.isMacOS) {
        libraryPath = 'libmgba.dylib';
      } else if (Platform.isAndroid) {
        libraryPath = 'libmgba.so';
      } else {
        throw UnsupportedError('Unsupported platform');
      }

      _lib = DynamicLibrary.open(libraryPath);
      _bindFunctions();
      _isLoaded = true;
      return true;
    } catch (e) {
      print('Failed to load mGBA library: $e');
      return false;
    }
  }

  void _bindFunctions() {
    coreCreate = _lib
        .lookup<NativeFunction<MgbaCoreCreateNative>>('yage_core_create')
        .asFunction();
    
    coreInit = _lib
        .lookup<NativeFunction<MgbaCoreInitNative>>('yage_core_init')
        .asFunction();

    coreDestroy = _lib
        .lookup<NativeFunction<MgbaCoreDestroyNative>>('yage_core_destroy')
        .asFunction();

    coreLoadROM = _lib
        .lookup<NativeFunction<MgbaCoreLoadROMNative>>('yage_core_load_rom')
        .asFunction();

    coreLoadBIOS = _lib
        .lookup<NativeFunction<MgbaCoreLoadBIOSNative>>('yage_core_load_bios')
        .asFunction();

    coreReset = _lib
        .lookup<NativeFunction<MgbaCoreResetNative>>('yage_core_reset')
        .asFunction();

    coreRunFrame = _lib
        .lookup<NativeFunction<MgbaCoreRunFrameNative>>('yage_core_run_frame')
        .asFunction();

    coreSetKeys = _lib
        .lookup<NativeFunction<MgbaCoreSetKeysNative>>('yage_core_set_keys')
        .asFunction();

    coreGetVideoBuffer = _lib
        .lookup<NativeFunction<MgbaCoreGetVideoBufferNative>>('yage_core_get_video_buffer')
        .asFunction();

    coreGetAudioBuffer = _lib
        .lookup<NativeFunction<MgbaCoreGetAudioBufferNative>>('yage_core_get_audio_buffer')
        .asFunction();

    coreGetAudioSamples = _lib
        .lookup<NativeFunction<MgbaCoreGetAudioSamplesNative>>('yage_core_get_audio_samples')
        .asFunction();

    coreSaveState = _lib
        .lookup<NativeFunction<MgbaCoreSaveStateNative>>('yage_core_save_state')
        .asFunction();

    coreLoadState = _lib
        .lookup<NativeFunction<MgbaCoreLoadStateNative>>('yage_core_load_state')
        .asFunction();

    coreGetWidth = _lib
        .lookup<NativeFunction<MgbaCoreGetWidthNative>>('yage_core_get_width')
        .asFunction();

    coreGetHeight = _lib
        .lookup<NativeFunction<MgbaCoreGetHeightNative>>('yage_core_get_height')
        .asFunction();

    coreGetPlatform = _lib
        .lookup<NativeFunction<MgbaCoreGetPlatformNative>>('yage_core_get_platform')
        .asFunction();

    coreSetSaveDir = _lib
        .lookup<NativeFunction<MgbaCoreSetSaveDirNative>>('yage_core_set_save_dir')
        .asFunction();
  }
}

/// High-level wrapper for mGBA core operations
class MGBACore {
  final MGBABindings _bindings;
  NativeCore? _corePtr;
  bool _isRunning = false;
  int _currentKeys = 0;
  
  // Screen dimensions
  int _width = 240;
  int _height = 160;
  GamePlatform _platform = GamePlatform.unknown;

  MGBACore(this._bindings);

  bool get isRunning => _isRunning;
  int get width => _width;
  int get height => _height;
  GamePlatform get platform => _platform;

  /// Initialize the emulator core
  bool initialize() {
    if (!_bindings.isLoaded) {
      if (!_bindings.load()) return false;
    }

    final core = _bindings.coreCreate();
    if (core == nullptr) return false;

    final result = _bindings.coreInit(core);
    if (result != 0) {
      _bindings.coreDestroy(core);
      return false;
    }

    _corePtr = core;
    return true;
  }

  /// Load a ROM file
  bool loadROM(String path) {
    if (_corePtr == null) return false;

    final pathPtr = path.toNativeUtf8();
    try {
      final result = _bindings.coreLoadROM(_corePtr as Pointer<Void>, pathPtr);
      if (result == 0) {
        _updateDimensions();
        _isRunning = true;
        return true;
      }
      return false;
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Load a BIOS file
  bool loadBIOS(String path) {
    if (_corePtr == null) return false;

    final pathPtr = path.toNativeUtf8();
    try {
      final result = _bindings.coreLoadBIOS(_corePtr as Pointer<Void>, pathPtr);
      return result == 0;
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Set the save directory
  void setSaveDir(String path) {
    if (_corePtr == null) return;

    final pathPtr = path.toNativeUtf8();
    try {
      _bindings.coreSetSaveDir(_corePtr as Pointer<Void>, pathPtr);
    } finally {
      calloc.free(pathPtr);
    }
  }

  void _updateDimensions() {
    if (_corePtr == null) return;

    _width = _bindings.coreGetWidth(_corePtr as Pointer<Void>);
    _height = _bindings.coreGetHeight(_corePtr as Pointer<Void>);
    
    final platformInt = _bindings.coreGetPlatform(_corePtr as Pointer<Void>);
    _platform = switch (platformInt) {
      1 => GamePlatform.gb,
      2 => GamePlatform.gbc,
      3 => GamePlatform.gba,
      _ => GamePlatform.unknown,
    };
  }

  /// Run a single frame
  void runFrame() {
    if (_corePtr == null || !_isRunning) return;
    _bindings.coreRunFrame(_corePtr as Pointer<Void>);
  }

  /// Set key states
  void setKeys(int keys) {
    if (_corePtr == null) return;
    _currentKeys = keys;
    _bindings.coreSetKeys(_corePtr as Pointer<Void>, keys);
  }

  /// Press a key
  void pressKey(int key) {
    setKeys(_currentKeys | key);
  }

  /// Release a key
  void releaseKey(int key) {
    setKeys(_currentKeys & ~key);
  }

  /// Get video buffer as RGBA pixel data
  Uint8List? getVideoBuffer() {
    if (_corePtr == null) return null;

    final buffer = _bindings.coreGetVideoBuffer(_corePtr as Pointer<Void>);
    if (buffer == nullptr) return null;

    final pixelCount = _width * _height;
    final pixels = Uint8List(pixelCount * 4);
    
    for (int i = 0; i < pixelCount; i++) {
      final color = buffer[i];
      // Convert from XRGB8888 to RGBA8888
      pixels[i * 4 + 0] = (color >> 16) & 0xFF; // R
      pixels[i * 4 + 1] = (color >> 8) & 0xFF;  // G
      pixels[i * 4 + 2] = color & 0xFF;         // B
      pixels[i * 4 + 3] = 0xFF;                 // A
    }

    return pixels;
  }

  /// Get audio samples
  (Int16List?, int) getAudioBuffer() {
    if (_corePtr == null) return (null, 0);

    final samples = _bindings.coreGetAudioSamples(_corePtr as Pointer<Void>);
    if (samples == 0) return (null, 0);

    final buffer = _bindings.coreGetAudioBuffer(_corePtr as Pointer<Void>);
    if (buffer == nullptr) return (null, 0);

    final audioData = Int16List(samples * 2); // Stereo
    for (int i = 0; i < samples * 2; i++) {
      audioData[i] = buffer[i];
    }

    return (audioData, samples);
  }

  /// Save state to slot
  bool saveState(int slot) {
    if (_corePtr == null) return false;
    return _bindings.coreSaveState(_corePtr as Pointer<Void>, slot) == 0;
  }

  /// Load state from slot
  bool loadState(int slot) {
    if (_corePtr == null) return false;
    return _bindings.coreLoadState(_corePtr as Pointer<Void>, slot) == 0;
  }

  /// Reset the emulator
  void reset() {
    if (_corePtr == null) return;
    _bindings.coreReset(_corePtr as Pointer<Void>);
  }

  /// Stop and clean up
  void dispose() {
    if (_corePtr != null) {
      _bindings.coreDestroy(_corePtr as Pointer<Void>);
      _corePtr = null;
    }
    _isRunning = false;
  }
}

