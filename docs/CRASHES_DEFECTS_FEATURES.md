# RetroPal — Crashes, Defects & Performance (TV & Low-End Devices)

A detailed reference for debugging, optimization, and feature planning. Use each item as a standalone prompt in separate chats.

---

## 1. CRASH RISKS

### 1.1 Async / Mounted Checks
**Prompt:** "Fix all async callbacks that may call setState or use context after the widget is unmounted in [file]. Ensure every Future.then, async gap, or Stream listener checks `mounted` or `context.mounted` before updating UI."

- **game_screen.dart**: Rcheevos event stream, overlay toasts, shortcuts help dialog, link cable dialogs — many async paths; some may lack mounted checks.
- **home_screen.dart**: Import flows, cover art batch, file picker results, navigation after async — verify all paths check `mounted` before setState.
- **settings_screen.dart**: Backup/restore, Google Drive upload, ZIP operations — long async chains; ensure `context.mounted` before Navigator/ScaffoldMessenger.
- **splash_screen.dart**: `_waitForProviders` polling loop — ensure `_navigated || !mounted` before navigation.
- **tv_file_browser.dart**: `_loadEntries`, SAF import — check `mounted` before setState after async.

### 1.2 Provider / Context in dispose
**Prompt:** "Audit all dispose() methods: ensure we never call context.read, Navigator, or any Provider lookup in dispose. Replace with early-captured references."

- **game_screen.dart**: Uses saved refs (`_emulatorRef`, `_linkCableRef`, etc.) — no context/Provider in dispose. Fixed: `_rcheevosClientRef?.shutdown()` now called before nulling ref.
- **home_screen.dart**: dispose cancels timers and disposes controllers — no context use.
- **settings_screen.dart**, **splash_screen.dart**, **achievements_screen.dart**, **tv_focusable.dart**, **game_display.dart**: dispose only disposes controllers/nodes — no context use.
- **tv_file_browser.dart**: No dispose override.
- Risk: Any widget that calls `context.read<T>()` or `Provider.of` inside dispose will throw.

### 1.3 Native / FFI Crashes
**Prompt:** "Add null checks and try-catch around all FFI/native calls in mgba_bindings.dart and rcheevos_bindings.dart. Handle symbol lookup failures and invalid pointers gracefully."

- **mgba_bindings.dart**: Wrapped `initialize`, `loadROM`, `runFrame`, `setKeys`, `getVideoBuffer`, `getAudioBuffer`, `getDisplayBuffer`, `_updateDimensions`, `setCoreLibrary`, `dispose` in try-catch. Null checks for `core == nullptr`, `buffer.address == 0`.
- **rcheevos_bindings.dart**: `_readNullableString` and `readEvent` wrapped in try-catch; null checks for `ptr.address == 0`; `dispose` guards `calloc.free`.
- **rcheevos_client.dart**: `initialize`, `shutdown`, `_submitNativeResponse`, `_drainEvents`, `_updateGameInfo` wrapped; `_safeUtf8ToString` for pointer reads; null checks for `yageCorePtr`.
- **game_display.dart**: `createGameTexture` already had try-catch; added try-catch around `destroyGameTexture` in `_destroyTexture` and dispose path.

### 1.4 Texture / ANativeWindow Lifecycle
**Prompt:** "Ensure GameDisplay and YageTextureBridge never access ANativeWindow or TextureRegistry after dispose. Add guards for disposed state and async texture creation."

- Race: Widget disposed while `_channel.invokeMethod('createGameTexture')` is in flight — already has `_isDisposed` check; verify destroy is always called.
- **YageTextureBridge.kt**: `nativeReleaseSurface` on destroy — ensure no use-after-free if Flutter disposes during frame blit.

### 1.5 Database / File I/O
**Prompt:** "Wrap all GameDatabase and file I/O in try-catch. Handle disk full, permission denied, and corrupt SQLite gracefully."

- **game_database.dart**: `getAllGames`, `addGame`, migrations — uncaught SQLiteException can crash.
- **game_library_service.dart**: `File(path).existsSync()` in loop — large libraries may hit ANR on slow storage.
- **cover_art_service.dart**: HTTP, file writes — network/timeout can throw.

### 1.6 Firebase / Crashlytics
**Prompt:** "Ensure Firebase.initializeApp and Crashlytics are wrapped so missing google-services.json or config does not crash on startup."

- **main.dart**: `Firebase.initializeApp()` — fails if config missing; consider try-catch and fallback.

---

## 2. DEFECTS / BUGS

### 2.1 GameScreen dispose — rcheevosClientRef
**Prompt:** "In game_screen.dart dispose, _rcheevosClientRef is set to null before shutdown() is called. Fix the order so shutdown() uses the ref before nulling."

- Current: `_rcheevosClientRef?.shutdown()` then `_rcheevosClientRef = null` — order is correct. Verify no other refs are nulled before use.

### 2.2 TvDetector Initialize Timing
**Prompt:** "TvDetector.initialize() is async but isTV is read synchronously. Ensure SplashScreen waits for it before any TvDetector.isTV access. If not, add a fallback for first-frame reads."

- **tv_detector.dart**: `_checked` and `_isTV` — if `initialize()` not awaited, first read may be false.

### 2.3 Focus Restoration on TV
**Prompt:** "On Android TV, when returning from GameScreen or Settings to HomeScreen, focus may not restore to the last focused game card. Verify _shouldRestoreFocus and _lastFocusedGameIndex logic."

- **home_screen.dart**: `_shouldRestoreFocus`, `_lastFocusedGameIndex`, `AutofocusIndex` — complex; ensure correct after back navigation.

### 2.4 Rewind Buffer Memory
**Prompt:** "Rewind uses in-memory save states. On low-RAM devices, large rewind buffers can cause OOM. Add a device memory check or cap."

- **emulator_service.dart**: `_initRewind`, `rewindBufferSeconds` — configurable; default may be too high for 1–2 GB RAM devices.

### 2.5 Cover Art Index Memory
**Prompt:** "CoverArtService loads full game-name indices (~200 KB per platform) into memory. With 5 platforms, ~1 MB. On low-end devices, consider lazy loading or LRU eviction."

- **cover_art_service.dart**: `_indexCache`, `_indexNormCache` — never cleared; grows with platform count.

### 2.6 ListView.builder Without Cache Extent
**Prompt:** "HomeScreen uses GridView.builder and ListView.builder. Add cacheExtent for smoother scrolling on TV and low-end devices. Consider itemCount for very large libraries."

- **home_screen.dart**: `GridView.builder`, `ListView.separated` — default cacheExtent; may need tuning for 500+ games.

### 2.7 dir.listSync on Large Directories
**Prompt:** "TvFileBrowser uses dir.listSync() which blocks the UI thread. For directories with thousands of files, this can cause ANR. Use isolate or compute."

- **tv_file_browser.dart**: `_loadEntries`, `_dirItemCount` — `listSync()` blocks.

---

## 3. PERFORMANCE — TV & LOW-END DEVICES

### 3.1 Frame Loop — Dart vs Native
**Prompt:** "On low-end devices, the Dart Timer-based frame loop may cause jank. Verify native frame loop is used when available (Android, Linux, macOS) and that it is preferred over the Dart path."

- **emulator_service.dart**: `_canUseNativeFrameLoop`, `_startFrameLoop` — native thread preferred; ensure it's always used on supported platforms.

### 3.2 Texture vs decodeImageFromPixels
**Prompt:** "GameDisplay falls back to decodeImageFromPixels when texture creation fails. On low-end devices, this path allocates Uint8List and ui.Image every frame — causes GC pressure and jank. Consider reducing resolution or frame rate for fallback."

- **game_display.dart**: Double-buffer pool helps; but decodeImageFromPixels is still CPU-heavy.

### 3.3 OpenSL Audio Buffer Size
**Prompt:** "OpenSL uses 2 buffers × 256 frames. On low-end devices, increase buffer count or size to reduce underruns. Tune PREBUFFER_SAMPLES and latency cap."

- **yage_libretro.c**: `AUDIO_BUFFER_FRAMES`, `g_overflow_count` — underruns cause audio pops.

### 3.4 Game Library — Full List in Memory
**Prompt:** "GameLibraryService holds all games in memory. For 1000+ ROMs, consider pagination or filtering at DB level to reduce memory and rebuild cost."

- **game_library_service.dart**: `_games` — full list; filtering and sorting on every access.

### 3.5 Game Card Rebuilds
**Prompt:** "GameCard widgets may rebuild excessively when parent rebuilds. Add const constructors where possible and use RepaintBoundary for game cards in list/grid."

- **game_card.dart**: `CachedNetworkImage` for cover art — verify cache; avoid unnecessary rebuilds.

### 3.6 TV — D-pad Navigation Performance
**Prompt:** "On TV, FocusTraversal and TvFocusable cause many rebuilds when moving focus. Ensure focus nodes are stable and avoid unnecessary setState during focus changes."

- **tv_focusable.dart**: `onFocusChanged` triggers parent rebuilds; `SingleTickerProviderStateMixin` for pulse — ensure it's disposed.

### 3.7 ProGuard / R8
**Prompt:** "Release build uses minifyEnabled and shrinkResources. Verify ProGuard rules keep all native JNI methods, Provider classes, and JSON serialization models. Test release build on TV and low-end device."

- **proguard-rules.pro**: Check for `-keep` and `-dontwarn` for Firebase, FFI, etc.

### 3.8 Image Filtering
**Prompt:** "GameDisplay enableFiltering uses ImageFilter.linearToSrgbGamma which is expensive. On low-end devices, offer a 'low quality' or 'no filter' option to reduce GPU load."

- **game_display.dart**: `enableFiltering` — consider disabling for performance mode.

---

## 4. TV-SPECIFIC ISSUES

### 4.1 No Touch — Virtual Gamepad Hidden
**Prompt:** "On TV, virtual gamepad is hidden by default. If user has no remote/gamepad, they cannot start a game. Add a way to show controls or detect 'no input device' and show overlay."

- **game_screen.dart**: `_showControls = false` when `TvDetector.isTV` — user may be stuck.

### 4.2 Leanback Launcher
**Prompt:** "Ensure Android TV manifest has proper leanback and touchscreen flags. Verify game mode config for low latency."

- **AndroidManifest.xml**, **game_mode_config.xml** — check `android:isGame`, `android:supportsController`.

### 4.3 TV File Browser — SAF
**Prompt:** "On Android TV, file picker uses SAF. Legacy READ_EXTERNAL_STORAGE for Android ≤12. Handle permission denial and empty folder gracefully."

- **MainActivity.kt**: `importRomsFromFolder`, `requestStoragePermission` — handle user denial.

### 4.4 TV — Landscape Lock
**Prompt:** "On TV, orientation is locked to landscape. Ensure GameScreen and HomeScreen layouts work correctly in landscape. Verify virtual gamepad and menu positioning."

- **game_screen.dart**: `SystemChrome.setPreferredOrientations` for TV — landscape only.

### 4.5 TV — D-pad Double-Tap
**Prompt:** "On some TV remotes, D-pad can register double-taps. Add debouncing or ignore rapid repeats for navigation."

- **tv_focusable.dart**, **home_screen.dart**: Key events — may need debounce.

---

## 5. USEFUL FEATURES (Performance & UX)

### 5.1 Performance Mode
**Prompt:** "Add a 'Performance mode' or 'Low-end device' setting that disables rewind, reduces audio buffer, disables image filtering, and uses lower resolution scaling for texture fallback."

### 5.2 Game Library Pagination
**Prompt:** "Implement pagination or virtualized loading for the game library when count > 100. Load only visible items + cache extent."

### 5.3 Cover Art Thumbnail Size
**Prompt:** "Allow downloading smaller cover art thumbnails for low-end devices to reduce memory and disk cache size."

### 5.4 Frame Skip Option
**Prompt:** "Add a frame skip option (e.g. 1/2, 1/3) for low-end devices that cannot maintain 60 fps. Trade smoothness for playability."

### 5.5 Audio Latency
**Prompt:** "Add a 'Low latency audio' option that reduces buffer size for responsive sound, at the cost of underrun risk on slow devices."

### 5.6 TV — On-Screen Keyboard
**Prompt:** "On TV, search and text input need an on-screen keyboard. Ensure Flutter's keyboard or platform keyboard works. Add fallback for TV without keyboard."

### 5.7 Memory Warning
**Prompt:** "Listen for memory pressure (e.g. WidgetsBindingObserver, or platform channel) and reduce rewind buffer or clear cover art cache when low."

### 5.8 Startup Time
**Prompt:** "Measure and reduce splash screen startup time. Defer non-critical init (e.g. RetroAchievements, cover art index) until after first paint."

### 5.9 Background Audio
**Prompt:** "When app is backgrounded, pause emulator and optionally keep audio muted. Ensure no audio continues when paused (wakelock off)."

### 5.10 Battery / Thermal
**Prompt:** "On mobile, consider reducing turbo speed or capping FPS when battery is low or device is hot. Add thermal throttling option."

---

## 6. NATIVE / C SPECIFIC

### 6.1 g_keys Race
**Prompt:** "In yage_libretro.c, g_keys is written from Dart thread and read from native frame loop thread. Use atomic_uint32_t or memory barrier to avoid torn reads."

### 6.2 Ring Buffer Overflow
**Prompt:** "Audio ring buffer can overflow on slow devices. Increase RING_BUFFER_SIZE or add backpressure when buffer is full."

### 6.3 Video Buffer Realloc
**Prompt:** "video_refresh_callback reallocates g_video_buffer when resolution changes. Ensure no use during realloc. Consider lock or double-buffer."

### 6.4 Unhandled RETRO_ENVIRONMENT
**Prompt:** "Log and handle any remaining unhandled RETRO_ENVIRONMENT commands. Some cores may require them for correct behavior."

---

## 7. TESTING PROMPTS

### 7.1
"Test RetroPal on an Android TV device with 1 GB RAM. Identify crashes, ANRs, and audio/video issues."

### 7.2
"Test RetroPal with a large library (500+ games). Measure memory usage, scroll performance, and startup time."

### 7.3
"Test RetroPal with a Bluetooth gamepad. Verify focus, auto-hide controls, and reconnection after disconnect."

### 7.4
"Test RetroPal on an Android 12 device with no SIM and no Google account. Verify Firebase and Crashlytics do not crash."

### 7.5
"Test NES and SNES games with virtual gamepad. Verify all buttons (A, B, Start, Select, D-pad) work and audio plays."

### 7.6
"Test rapid navigation: Home → Game → Back → Settings → Back. Verify no memory leaks and focus restoration."

---

## 8. QUICK REFERENCE

| Area | File(s) | Risk |
|------|---------|------|
| Async/mounted | game_screen, home_screen, settings_screen | High |
| Native/FFI | mgba_bindings, rcheevos_bindings | High |
| Texture lifecycle | game_display, YageTextureBridge.kt | Medium |
| DB/File I/O | game_database, game_library_service | Medium |
| TV focus | home_screen, tv_focusable | Medium |
| Memory | cover_art, rewind, game list | Medium |
| List sync | tv_file_browser | Medium |
| Audio | yage_libretro.c | Low |
| g_keys atomic | yage_libretro.c | Low |
