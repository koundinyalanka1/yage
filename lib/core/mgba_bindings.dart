import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

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

typedef MgbaCoreSetVolumeNative = Void Function(NativeCore core, Float volume);
typedef MgbaCoreSetVolume = void Function(NativeCore core, double volume);

typedef MgbaCoreSetAudioEnabledNative = Void Function(NativeCore core, Int32 enabled);
typedef MgbaCoreSetAudioEnabled = void Function(NativeCore core, int enabled);

typedef MgbaCoreSetColorPaletteNative = Void Function(
    NativeCore core, Int32 paletteIndex,
    Uint32 color0, Uint32 color1, Uint32 color2, Uint32 color3);
typedef MgbaCoreSetColorPalette = void Function(
    NativeCore core, int paletteIndex,
    int color0, int color1, int color2, int color3);

// Battery/SRAM save functions
typedef MgbaCoreGetSramSizeNative = Int32 Function(NativeCore core);
typedef MgbaCoreGetSramSize = int Function(NativeCore core);

typedef MgbaCoreGetSramDataNative = Pointer<Uint8> Function(NativeCore core);
typedef MgbaCoreGetSramData = Pointer<Uint8> Function(NativeCore core);

typedef MgbaCoreSaveSramNative = Int32 Function(NativeCore core, Pointer<Utf8> path);
typedef MgbaCoreSaveSram = int Function(NativeCore core, Pointer<Utf8> path);

typedef MgbaCoreLoadSramNative = Int32 Function(NativeCore core, Pointer<Utf8> path);
typedef MgbaCoreLoadSram = int Function(NativeCore core, Pointer<Utf8> path);

// Rewind functions
typedef MgbaCoreRewindInitNative = Int32 Function(NativeCore core, Int32 capacity);
typedef MgbaCoreRewindInit = int Function(NativeCore core, int capacity);

typedef MgbaCoreRewindDeinitNative = Void Function(NativeCore core);
typedef MgbaCoreRewindDeinit = void Function(NativeCore core);

typedef MgbaCoreRewindPushNative = Int32 Function(NativeCore core);
typedef MgbaCoreRewindPush = int Function(NativeCore core);

typedef MgbaCoreRewindPopNative = Int32 Function(NativeCore core);
typedef MgbaCoreRewindPop = int Function(NativeCore core);

typedef MgbaCoreRewindCountNative = Int32 Function(NativeCore core);
typedef MgbaCoreRewindCount = int Function(NativeCore core);

// Link cable functions
typedef MgbaCoreLinkIsSupportedNative = Int32 Function(NativeCore core);
typedef MgbaCoreLinkIsSupported = int Function(NativeCore core);

typedef MgbaCoreLinkReadByteNative = Int32 Function(NativeCore core, Uint32 addr);
typedef MgbaCoreLinkReadByte = int Function(NativeCore core, int addr);

typedef MgbaCoreLinkWriteByteNative = Int32 Function(NativeCore core, Uint32 addr, Uint8 value);
typedef MgbaCoreLinkWriteByte = int Function(NativeCore core, int addr, int value);

typedef MgbaCoreLinkGetTransferStatusNative = Int32 Function(NativeCore core);
typedef MgbaCoreLinkGetTransferStatus = int Function(NativeCore core);

typedef MgbaCoreLinkExchangeDataNative = Int32 Function(NativeCore core, Uint8 incoming);
typedef MgbaCoreLinkExchangeData = int Function(NativeCore core, int incoming);

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
  late final MgbaCoreGetSramSize coreGetSramSize;
  late final MgbaCoreGetSramData coreGetSramData;
  late final MgbaCoreSaveSram coreSaveSram;
  late final MgbaCoreLoadSram coreLoadSram;
  late final MgbaCoreSetVolume coreSetVolume;
  late final MgbaCoreSetAudioEnabled coreSetAudioEnabled;
  late final MgbaCoreSetColorPalette coreSetColorPalette;
  late final MgbaCoreRewindInit coreRewindInit;
  late final MgbaCoreRewindDeinit coreRewindDeinit;
  late final MgbaCoreRewindPush coreRewindPush;
  late final MgbaCoreRewindPop coreRewindPop;
  late final MgbaCoreRewindCount coreRewindCount;

  // Link cable (optional — loaded separately so older native libs still work)
  MgbaCoreLinkIsSupported? coreLinkIsSupported;
  MgbaCoreLinkReadByte? coreLinkReadByte;
  MgbaCoreLinkWriteByte? coreLinkWriteByte;
  MgbaCoreLinkGetTransferStatus? coreLinkGetTransferStatus;
  MgbaCoreLinkExchangeData? coreLinkExchangeData;
  bool _linkLoaded = false;
  bool get isLinkLoaded => _linkLoaded;

  bool get isLoaded => _isLoaded;

  /// Load the mGBA dynamic library.
  ///
  /// All function symbols are resolved into local variables first. Only if
  /// every single lookup succeeds are the instance fields assigned and
  /// [_isLoaded] set to `true`. This prevents a partial-bind scenario where
  /// some `late` fields are initialised but others are not.
  bool load() {
    if (_isLoaded) return true;

    try {
      // On Android, we need to load the mGBA libretro core first
      // so it's available when yage_core tries to use it
      if (Platform.isAndroid) {
        try {
          DynamicLibrary.open('libmgba_libretro_android.so');
          debugPrint('Loaded mGBA libretro core');
        } catch (e) {
          debugPrint('Warning: Could not pre-load mGBA core: $e');
        }
      }
      
      String libraryPath;
      
      if (Platform.isWindows) {
        libraryPath = 'yage_core.dll';
      } else if (Platform.isLinux) {
        libraryPath = 'libyage_core.so';
      } else if (Platform.isMacOS) {
        libraryPath = 'libyage_core.dylib';
      } else if (Platform.isAndroid) {
        libraryPath = 'libyage_core.so';
      } else {
        throw UnsupportedError('Unsupported platform');
      }

      final lib = DynamicLibrary.open(libraryPath);

      // ── Resolve ALL symbols into locals first ──
      // If any lookup throws, none of the instance fields are modified,
      // keeping the object in a clean unloaded state.
      final bindCoreCreate = lib
          .lookup<NativeFunction<MgbaCoreCreateNative>>('yage_core_create')
          .asFunction<MgbaCoreCreate>();
      final bindCoreInit = lib
          .lookup<NativeFunction<MgbaCoreInitNative>>('yage_core_init')
          .asFunction<MgbaCoreInit>();
      final bindCoreDestroy = lib
          .lookup<NativeFunction<MgbaCoreDestroyNative>>('yage_core_destroy')
          .asFunction<MgbaCoreDestroy>();
      final bindCoreLoadROM = lib
          .lookup<NativeFunction<MgbaCoreLoadROMNative>>('yage_core_load_rom')
          .asFunction<MgbaCoreLoadROM>();
      final bindCoreLoadBIOS = lib
          .lookup<NativeFunction<MgbaCoreLoadBIOSNative>>('yage_core_load_bios')
          .asFunction<MgbaCoreLoadBIOS>();
      final bindCoreReset = lib
          .lookup<NativeFunction<MgbaCoreResetNative>>('yage_core_reset')
          .asFunction<MgbaCoreReset>();
      final bindCoreRunFrame = lib
          .lookup<NativeFunction<MgbaCoreRunFrameNative>>('yage_core_run_frame')
          .asFunction<MgbaCoreRunFrame>();
      final bindCoreSetKeys = lib
          .lookup<NativeFunction<MgbaCoreSetKeysNative>>('yage_core_set_keys')
          .asFunction<MgbaCoreSetKeys>();
      final bindCoreGetVideoBuffer = lib
          .lookup<NativeFunction<MgbaCoreGetVideoBufferNative>>('yage_core_get_video_buffer')
          .asFunction<MgbaCoreGetVideoBuffer>();
      final bindCoreGetAudioBuffer = lib
          .lookup<NativeFunction<MgbaCoreGetAudioBufferNative>>('yage_core_get_audio_buffer')
          .asFunction<MgbaCoreGetAudioBuffer>();
      final bindCoreGetAudioSamples = lib
          .lookup<NativeFunction<MgbaCoreGetAudioSamplesNative>>('yage_core_get_audio_samples')
          .asFunction<MgbaCoreGetAudioSamples>();
      final bindCoreSaveState = lib
          .lookup<NativeFunction<MgbaCoreSaveStateNative>>('yage_core_save_state')
          .asFunction<MgbaCoreSaveState>();
      final bindCoreLoadState = lib
          .lookup<NativeFunction<MgbaCoreLoadStateNative>>('yage_core_load_state')
          .asFunction<MgbaCoreLoadState>();
      final bindCoreGetWidth = lib
          .lookup<NativeFunction<MgbaCoreGetWidthNative>>('yage_core_get_width')
          .asFunction<MgbaCoreGetWidth>();
      final bindCoreGetHeight = lib
          .lookup<NativeFunction<MgbaCoreGetHeightNative>>('yage_core_get_height')
          .asFunction<MgbaCoreGetHeight>();
      final bindCoreGetPlatform = lib
          .lookup<NativeFunction<MgbaCoreGetPlatformNative>>('yage_core_get_platform')
          .asFunction<MgbaCoreGetPlatform>();
      final bindCoreSetSaveDir = lib
          .lookup<NativeFunction<MgbaCoreSetSaveDirNative>>('yage_core_set_save_dir')
          .asFunction<MgbaCoreSetSaveDir>();
      final bindCoreGetSramSize = lib
          .lookup<NativeFunction<MgbaCoreGetSramSizeNative>>('yage_core_get_sram_size')
          .asFunction<MgbaCoreGetSramSize>();
      final bindCoreGetSramData = lib
          .lookup<NativeFunction<MgbaCoreGetSramDataNative>>('yage_core_get_sram_data')
          .asFunction<MgbaCoreGetSramData>();
      final bindCoreSaveSram = lib
          .lookup<NativeFunction<MgbaCoreSaveSramNative>>('yage_core_save_sram')
          .asFunction<MgbaCoreSaveSram>();
      final bindCoreLoadSram = lib
          .lookup<NativeFunction<MgbaCoreLoadSramNative>>('yage_core_load_sram')
          .asFunction<MgbaCoreLoadSram>();
      final bindCoreSetVolume = lib
          .lookup<NativeFunction<MgbaCoreSetVolumeNative>>('yage_core_set_volume')
          .asFunction<MgbaCoreSetVolume>();
      final bindCoreSetAudioEnabled = lib
          .lookup<NativeFunction<MgbaCoreSetAudioEnabledNative>>('yage_core_set_audio_enabled')
          .asFunction<MgbaCoreSetAudioEnabled>();
      final bindCoreSetColorPalette = lib
          .lookup<NativeFunction<MgbaCoreSetColorPaletteNative>>('yage_core_set_color_palette')
          .asFunction<MgbaCoreSetColorPalette>();
      final bindCoreRewindInit = lib
          .lookup<NativeFunction<MgbaCoreRewindInitNative>>('yage_core_rewind_init')
          .asFunction<MgbaCoreRewindInit>();
      final bindCoreRewindDeinit = lib
          .lookup<NativeFunction<MgbaCoreRewindDeinitNative>>('yage_core_rewind_deinit')
          .asFunction<MgbaCoreRewindDeinit>();
      final bindCoreRewindPush = lib
          .lookup<NativeFunction<MgbaCoreRewindPushNative>>('yage_core_rewind_push')
          .asFunction<MgbaCoreRewindPush>();
      final bindCoreRewindPop = lib
          .lookup<NativeFunction<MgbaCoreRewindPopNative>>('yage_core_rewind_pop')
          .asFunction<MgbaCoreRewindPop>();
      final bindCoreRewindCount = lib
          .lookup<NativeFunction<MgbaCoreRewindCountNative>>('yage_core_rewind_count')
          .asFunction<MgbaCoreRewindCount>();

      // ── All lookups succeeded — commit to instance fields atomically ──
      _lib = lib;
      coreCreate = bindCoreCreate;
      coreInit = bindCoreInit;
      coreDestroy = bindCoreDestroy;
      coreLoadROM = bindCoreLoadROM;
      coreLoadBIOS = bindCoreLoadBIOS;
      coreReset = bindCoreReset;
      coreRunFrame = bindCoreRunFrame;
      coreSetKeys = bindCoreSetKeys;
      coreGetVideoBuffer = bindCoreGetVideoBuffer;
      coreGetAudioBuffer = bindCoreGetAudioBuffer;
      coreGetAudioSamples = bindCoreGetAudioSamples;
      coreSaveState = bindCoreSaveState;
      coreLoadState = bindCoreLoadState;
      coreGetWidth = bindCoreGetWidth;
      coreGetHeight = bindCoreGetHeight;
      coreGetPlatform = bindCoreGetPlatform;
      coreSetSaveDir = bindCoreSetSaveDir;
      coreGetSramSize = bindCoreGetSramSize;
      coreGetSramData = bindCoreGetSramData;
      coreSaveSram = bindCoreSaveSram;
      coreLoadSram = bindCoreLoadSram;
      coreSetVolume = bindCoreSetVolume;
      coreSetAudioEnabled = bindCoreSetAudioEnabled;
      coreSetColorPalette = bindCoreSetColorPalette;
      coreRewindInit = bindCoreRewindInit;
      coreRewindDeinit = bindCoreRewindDeinit;
      coreRewindPush = bindCoreRewindPush;
      coreRewindPop = bindCoreRewindPop;
      coreRewindCount = bindCoreRewindCount;

      _isLoaded = true;
      debugPrint('YAGE core library loaded successfully (all ${30} symbols bound)');

      // ── Optional: try to load link cable symbols ──
      // These may not exist in older builds of the native library.
      try {
        coreLinkIsSupported = lib
            .lookup<NativeFunction<MgbaCoreLinkIsSupportedNative>>('yage_core_link_is_supported')
            .asFunction<MgbaCoreLinkIsSupported>();
        coreLinkReadByte = lib
            .lookup<NativeFunction<MgbaCoreLinkReadByteNative>>('yage_core_link_read_byte')
            .asFunction<MgbaCoreLinkReadByte>();
        coreLinkWriteByte = lib
            .lookup<NativeFunction<MgbaCoreLinkWriteByteNative>>('yage_core_link_write_byte')
            .asFunction<MgbaCoreLinkWriteByte>();
        coreLinkGetTransferStatus = lib
            .lookup<NativeFunction<MgbaCoreLinkGetTransferStatusNative>>('yage_core_link_get_transfer_status')
            .asFunction<MgbaCoreLinkGetTransferStatus>();
        coreLinkExchangeData = lib
            .lookup<NativeFunction<MgbaCoreLinkExchangeDataNative>>('yage_core_link_exchange_data')
            .asFunction<MgbaCoreLinkExchangeData>();
        _linkLoaded = true;
        debugPrint('Link cable symbols loaded successfully');
      } catch (e) {
        debugPrint('Link cable symbols not available (native lib rebuild needed): $e');
        _linkLoaded = false;
      }

      return true;
    } catch (e) {
      debugPrint('Failed to load YAGE core library: $e');
      return false;
    }
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

  /// Get video buffer as RGBA pixel data.
  /// Native side stores pixels in ABGR uint32 format which maps to
  /// R,G,B,A bytes in little-endian memory — exactly what Flutter expects
  /// for PixelFormat.rgba8888.
  ///
  /// Returns a **copy** of the native buffer so the caller can safely hold
  /// the reference across frames without risking use-after-free or data
  /// corruption when the native side overwrites the buffer on the next frame.
  Uint8List? getVideoBuffer() {
    if (_corePtr == null) return null;

    final buffer = _bindings.coreGetVideoBuffer(_corePtr as Pointer<Void>);
    if (buffer == nullptr) return null;

    final byteCount = _width * _height * 4;
    // Copy native memory into a Dart-owned Uint8List so the data remains
    // valid even after the native side reuses the buffer on the next frame.
    return Uint8List.fromList(buffer.cast<Uint8>().asTypedList(byteCount));
  }

  /// Get audio samples
  (Int16List?, int) getAudioBuffer() {
    if (_corePtr == null) return (null, 0);

    final samples = _bindings.coreGetAudioSamples(_corePtr as Pointer<Void>);
    if (samples == 0) return (null, 0);

    final buffer = _bindings.coreGetAudioBuffer(_corePtr as Pointer<Void>);
    if (buffer == nullptr) return (null, 0);

    // Bulk-copy native audio samples into a Dart-owned Int16List using
    // asTypedList + Int16List.fromList instead of a manual per-element loop.
    final sampleCount = samples * 2; // Stereo: 2 channels
    final audioData = Int16List.fromList(buffer.asTypedList(sampleCount));

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

  /// Get SRAM (battery save) size
  int getSramSize() {
    if (_corePtr == null) return 0;
    return _bindings.coreGetSramSize(_corePtr as Pointer<Void>);
  }

  /// Get SRAM data pointer
  Pointer<Uint8>? getSramData() {
    if (_corePtr == null) return null;
    final ptr = _bindings.coreGetSramData(_corePtr as Pointer<Void>);
    return ptr == nullptr ? null : ptr;
  }

  /// Save SRAM to file (.sav)
  bool saveSram(String path) {
    if (_corePtr == null) return false;
    final pathPtr = path.toNativeUtf8();
    try {
      final result = _bindings.coreSaveSram(_corePtr as Pointer<Void>, pathPtr);
      return result == 0;
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Load SRAM from file (.sav)
  bool loadSram(String path) {
    if (_corePtr == null) return false;
    final pathPtr = path.toNativeUtf8();
    try {
      final result = _bindings.coreLoadSram(_corePtr as Pointer<Void>, pathPtr);
      return result == 0;
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Set audio volume (0.0 = mute, 1.0 = full)
  void setVolume(double volume) {
    if (_corePtr == null) return;
    _bindings.coreSetVolume(_corePtr as Pointer<Void>, volume.clamp(0.0, 1.0));
  }

  /// Enable or disable audio output
  void setAudioEnabled(bool enabled) {
    if (_corePtr == null) return;
    _bindings.coreSetAudioEnabled(_corePtr as Pointer<Void>, enabled ? 1 : 0);
  }

  /// Set color palette for original GB games
  /// [paletteIndex] -1 to disable (use original colors), 0+ to enable
  /// [colors] list of 4 ARGB color values [lightest, light, dark, darkest]
  void setColorPalette(int paletteIndex, List<int> colors) {
    if (_corePtr == null) return;
    _bindings.coreSetColorPalette(
      _corePtr as Pointer<Void>,
      paletteIndex,
      colors[0], colors[1], colors[2], colors[3],
    );
  }

  /// Initialize rewind ring buffer with given capacity (number of snapshots)
  int rewindInit(int capacity) {
    if (_corePtr == null) return -1;
    return _bindings.coreRewindInit(_corePtr as Pointer<Void>, capacity);
  }

  /// Free the rewind ring buffer
  void rewindDeinit() {
    if (_corePtr == null) return;
    _bindings.coreRewindDeinit(_corePtr as Pointer<Void>);
  }

  /// Push current state into the rewind ring buffer
  int rewindPush() {
    if (_corePtr == null) return -1;
    return _bindings.coreRewindPush(_corePtr as Pointer<Void>);
  }

  /// Pop and restore the most recent state from the rewind ring buffer
  int rewindPop() {
    if (_corePtr == null) return -1;
    return _bindings.coreRewindPop(_corePtr as Pointer<Void>);
  }

  /// Get the number of available rewind snapshots
  int rewindCount() {
    if (_corePtr == null) return 0;
    return _bindings.coreRewindCount(_corePtr as Pointer<Void>);
  }

  // ── Link Cable ──

  /// Check if link cable I/O registers are accessible.
  bool get isLinkSupported {
    if (_corePtr == null || !_bindings.isLinkLoaded) return false;
    return _bindings.coreLinkIsSupported!(_corePtr as Pointer<Void>) == 1;
  }

  /// Read a byte from an emulated memory address.
  int linkReadByte(int addr) {
    if (_corePtr == null || _bindings.coreLinkReadByte == null) return -1;
    return _bindings.coreLinkReadByte!(_corePtr as Pointer<Void>, addr);
  }

  /// Write a byte to an emulated memory address.
  /// Returns 0 on success, -1 on failure.
  int linkWriteByte(int addr, int value) {
    if (_corePtr == null || _bindings.coreLinkWriteByte == null) return -1;
    return _bindings.coreLinkWriteByte!(_corePtr as Pointer<Void>, addr, value);
  }

  /// Get SIO transfer status: 0=idle, 1=pending (master), -1=error.
  int linkGetTransferStatus() {
    if (_corePtr == null || _bindings.coreLinkGetTransferStatus == null) return -1;
    return _bindings.coreLinkGetTransferStatus!(_corePtr as Pointer<Void>);
  }

  /// Exchange a byte during a pending SIO transfer.
  /// Returns the outgoing byte, or -1 on error.
  int linkExchangeData(int incoming) {
    if (_corePtr == null || _bindings.coreLinkExchangeData == null) return -1;
    return _bindings.coreLinkExchangeData!(_corePtr as Pointer<Void>, incoming);
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

