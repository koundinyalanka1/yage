import 'dart:async';
import 'dart:collection';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/rcheevos_bindings.dart';

// ═══════════════════════════════════════════════════════════════════════
//  RcheevosClient — Manages the native rcheevos rc_client lifecycle
// ═══════════════════════════════════════════════════════════════════════
//
//  Architecture:
//
//    ┌────────────┐   Dart HTTP   ┌─────────────┐   FFI   ┌──────────┐
//    │   RA API   │ ◄────────────►│ RcheevosClient│◄──────►│yage_core │
//    │  (server)  │               │   (Dart)     │        │  (C/FFI) │
//    └────────────┘               └─────────────┘        └──────────┘
//
//  The HTTP bridge:
//    1. rc_client (C) calls server_call → queues HTTP request in C
//    2. Dart polls pending requests via Timer
//    3. Dart makes HTTP request using http package
//    4. Dart submits response back to C via FFI
//    5. rc_client processes the response and fires events
//
//  Events:
//    rc_client fires events (achievement triggered, etc.) → queued in C
//    Dart polls for events and emits them via a Stream.
//
// ═══════════════════════════════════════════════════════════════════════

/// User-Agent string for the emulator.
/// This identifies the emulator to RetroAchievements.
const String _emulatorUserAgent = 'YAGE/1.0';

/// Client for the native rcheevos integration.
///
/// This service owns the rc_client lifecycle and provides:
///   • Login / logout
///   • Game loading / unloading
///   • Per-frame processing (called from emulator loop)
///   • Event stream for achievement unlocks
///   • HTTP bridge between rc_client and Dart
class RcheevosClient extends ChangeNotifier {
  final RcheevosBindings _bindings;

  // ── State ──────────────────────────────────────────────────────────
  bool _initialized = false;
  bool _loggedIn = false;
  bool _gameLoaded = false;
  String? _gameTitle;
  int _gameId = 0;
  String? _gameBadgeUrl;

  // ── Adaptive polling ───────────────────────────────────────────────
  //  A single one-shot Timer replaces the two 60 Hz periodic timers.
  //  The poll interval starts fast when there is work and backs off
  //  to a slow rate when idle — saving CPU & battery.
  Timer? _pollTimer;
  bool _polling = false;          // guards against re-entrant polls
  int _consecutiveIdlePolls = 0;  // tracks empty poll cycles

  static const int _pollFastMs   = 16;   // ~60 Hz — active
  static const int _pollSlowMs   = 500;  //  2 Hz — idle
  static const int _idleThreshold = 10;  // # of empty cycles before slow

  // ── Event stream ───────────────────────────────────────────────────
  final _eventController = StreamController<RcEvent>.broadcast();

  // ── Notification queue (for UI) ────────────────────────────────────
  final Queue<RcEvent> _notificationQueue = Queue();

  // ── Public getters ─────────────────────────────────────────────────
  bool get isInitialized => _initialized;
  bool get isLoggedIn => _loggedIn;
  bool get isGameLoaded => _gameLoaded;
  String? get gameTitle => _gameTitle;
  int get gameId => _gameId;
  String? get gameBadgeUrl => _gameBadgeUrl;

  /// Stream of events from rc_client (achievement triggered, etc.).
  Stream<RcEvent> get events => _eventController.stream;

  /// Whether there are pending notifications to display.
  bool get hasNotification => _notificationQueue.isNotEmpty;

  /// Peek at the next notification.
  RcEvent? get nextNotification =>
      _notificationQueue.isNotEmpty ? _notificationQueue.first : null;

  /// Consume the current notification.
  RcEvent? consumeNotification() {
    if (_notificationQueue.isEmpty) return null;
    return _notificationQueue.removeFirst();
  }

  // ── Constructor ────────────────────────────────────────────────────

  RcheevosClient(this._bindings);

  // ═══════════════════════════════════════════════════════════════════
  //  Lifecycle
  // ═══════════════════════════════════════════════════════════════════

  /// Initialize rc_client with the YageCore pointer.
  ///
  /// [yageCorePtr] is the native `Pointer<Void>` to the YageCore struct.
  /// Must be called after the emulator core is created and initialized.
  bool initialize(Pointer<Void> yageCorePtr) {
    if (!_bindings.isLoaded) {
      debugPrint('RcheevosClient: bindings not loaded');
      return false;
    }

    final result = _bindings.rcInit!(yageCorePtr);
    if (result != 0) {
      debugPrint('RcheevosClient: rc_init failed ($result)');
      return false;
    }

    _initialized = true;

    // Start polling for HTTP requests and events
    _startPolling();

    debugPrint('RcheevosClient: initialized');
    notifyListeners();
    return true;
  }

  /// Destroy rc_client and stop all polling.
  void shutdown() {
    _stopPolling();

    if (_initialized && _bindings.isLoaded) {
      _bindings.rcDestroy!();
    }

    _initialized = false;
    _loggedIn = false;
    _gameLoaded = false;
    _gameTitle = null;
    _gameId = 0;
    _gameBadgeUrl = null;
    _notificationQueue.clear();

    debugPrint('RcheevosClient: shutdown');
    notifyListeners();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Configuration
  // ═══════════════════════════════════════════════════════════════════

  /// Set hardcore mode (must be called before loading a game).
  void setHardcoreEnabled(bool enabled) {
    if (!_initialized) return;
    _bindings.rcSetHardcore!(enabled ? 1 : 0);
  }

  /// Set encore mode (re-earn previously unlocked achievements).
  void setEncoreEnabled(bool enabled) {
    if (!_initialized) return;
    _bindings.rcSetEncore!(enabled ? 1 : 0);
  }

  /// Get the rcheevos user-agent clause.
  String? getUserAgentClause() {
    if (!_initialized) return null;
    final buf = calloc<Uint8>(256).cast<Utf8>();
    try {
      final len = _bindings.rcGetUserAgentClause!(buf, 256);
      if (len > 0) return buf.toDartString();
      return null;
    } finally {
      calloc.free(buf);
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  User / Session
  // ═══════════════════════════════════════════════════════════════════

  /// Begin login with username + connect token.
  ///
  /// This is non-blocking. Login completion is delivered via the
  /// event stream (loginSuccess or loginFailed).
  void beginLogin(String username, String token) {
    if (!_initialized) return;

    final usernamePtr = username.toNativeUtf8();
    final tokenPtr = token.toNativeUtf8();
    try {
      _bindings.rcBeginLogin!(usernamePtr, tokenPtr);
      debugPrint('RcheevosClient: login started for $username');
    } finally {
      calloc.free(usernamePtr);
      calloc.free(tokenPtr);
    }

    // Login enqueues HTTP requests — wake the poller immediately.
    _wakeUp();
  }

  /// Logout the current user.
  void logout() {
    if (!_initialized) return;
    _bindings.rcLogout!();
    _loggedIn = false;
    notifyListeners();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Game
  // ═══════════════════════════════════════════════════════════════════

  /// Begin loading a game by MD5 hash.
  ///
  /// This is non-blocking. Game load completion is delivered via the
  /// event stream (gameLoadSuccess or gameLoadFailed).
  void beginLoadGame(String hash) {
    if (!_initialized) return;

    final hashPtr = hash.toNativeUtf8();
    try {
      _bindings.rcBeginLoadGame!(hashPtr);
      debugPrint('RcheevosClient: game load started for hash $hash');
    } finally {
      calloc.free(hashPtr);
    }

    // Game load enqueues HTTP requests — wake the poller immediately.
    _wakeUp();
  }

  /// Unload the current game.
  void unloadGame() {
    if (!_initialized) return;
    _bindings.rcUnloadGame!();
    _gameLoaded = false;
    _gameTitle = null;
    _gameId = 0;
    _gameBadgeUrl = null;
    _notificationQueue.clear();
    notifyListeners();
  }

  /// Reset the runtime (when emulated system resets).
  void reset() {
    if (!_initialized) return;
    _bindings.rcReset!();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Frame Processing
  // ═══════════════════════════════════════════════════════════════════

  /// Process one emulated frame.
  ///
  /// Call this once per frame from the emulator loop.
  /// It evaluates achievement conditions and fires events.
  /// Events generated by condition evaluation are drained inline
  /// so there is no latency waiting for the next poll cycle.
  void doFrame() {
    if (!_initialized || !_gameLoaded) return;
    _bindings.rcDoFrame!();
    // Drain events that doFrame may have queued (achievement triggers, etc.)
    _drainEvents();
  }

  /// Process periodic tasks (pings, retries) when paused.
  void idle() {
    if (!_initialized) return;
    _bindings.rcIdle!();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Achievement Info
  // ═══════════════════════════════════════════════════════════════════

  /// Get achievement counts for the loaded game.
  ({int total, int unlocked, int totalPoints, int unlockedPoints})
      getAchievementSummary() {
    if (!_initialized || !_gameLoaded) {
      return (total: 0, unlocked: 0, totalPoints: 0, unlockedPoints: 0);
    }
    return (
      total: _bindings.rcGetAchievementCount!(),
      unlocked: _bindings.rcGetUnlockedCount!(),
      totalPoints: _bindings.rcGetTotalPoints!(),
      unlockedPoints: _bindings.rcGetUnlockedPoints!(),
    );
  }

  /// Whether hardcore mode is currently enabled in rc_client.
  bool get isHardcoreEnabled {
    if (!_initialized) return false;
    return _bindings.rcGetHardcoreEnabled!() != 0;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  HTTP Bridge
  // ═══════════════════════════════════════════════════════════════════

  // ── Adaptive poll lifecycle ─────────────────────────────────────────

  /// Begin polling. Resets backoff so the first cycle runs immediately.
  void _startPolling() {
    _consecutiveIdlePolls = 0;
    _schedulePoll(Duration.zero);
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Schedule the next one-shot poll after [delay].
  void _schedulePoll(Duration delay) {
    _pollTimer?.cancel();
    if (!_initialized) return;
    _pollTimer = Timer(delay, _pollCycle);
  }

  /// Wake up the poller — call after any action that is expected to
  /// enqueue HTTP requests on the native side (login, load game, …).
  void _wakeUp() {
    _consecutiveIdlePolls = 0;
    if (!_polling) {
      _schedulePoll(Duration.zero);
    }
    // If _polling is true the current cycle will see the reset counter
    // and stay at the fast rate.
  }

  /// One poll cycle: fulfil at most one HTTP request, then drain events.
  /// Schedules itself again at an adaptive interval.
  Future<void> _pollCycle() async {
    if (!_initialized || _polling) return;
    _polling = true;

    bool didWork = false;
    try {
      // ── HTTP request ────────────────────────────────────────────
      didWork = await _processOneRequest();

      // ── Events (may have been queued by the response above) ────
      didWork |= _drainEvents();
    } finally {
      _polling = false;
    }

    if (!_initialized) return;

    // ── Schedule next cycle with adaptive back-off ────────────────
    if (didWork) {
      _consecutiveIdlePolls = 0;
      _schedulePoll(const Duration(milliseconds: _pollFastMs));
    } else {
      _consecutiveIdlePolls++;
      final ms = _consecutiveIdlePolls >= _idleThreshold
          ? _pollSlowMs
          : _pollFastMs;
      _schedulePoll(Duration(milliseconds: ms));
    }
  }

  // ── HTTP bridge ────────────────────────────────────────────────────

  /// Attempt to fulfil one pending HTTP request from rc_client.
  /// Returns `true` if a request was found and processed.
  Future<bool> _processOneRequest() async {
    if (!_initialized) return false;

    final requestId = _bindings.rcGetPendingRequest!();
    if (requestId == 0) return false;

    try {
      // Get request details
      final urlPtr = _bindings.rcGetRequestUrl!(requestId);
      if (urlPtr == nullptr) return false;
      final url = urlPtr.toDartString();

      final postDataPtr = _bindings.rcGetRequestPostData!(requestId);
      final postData =
          postDataPtr != nullptr ? postDataPtr.toDartString() : null;

      final contentTypePtr = _bindings.rcGetRequestContentType!(requestId);
      final contentType =
          contentTypePtr != nullptr ? contentTypePtr.toDartString() : null;

      // Build user-agent
      final rcClause = getUserAgentClause() ?? '';
      final userAgent = '$_emulatorUserAgent $rcClause'.trim();

      debugPrint('RcheevosClient HTTP: ${postData != null ? "POST" : "GET"} '
          '$url (id=$requestId)');

      // Make the HTTP request
      http.Response response;
      try {
        final uri = Uri.parse(url);
        final headers = <String, String>{
          'User-Agent': userAgent,
        };

        if (postData != null) {
          headers['Content-Type'] =
              contentType ?? 'application/x-www-form-urlencoded';
          response = await http
              .post(uri, headers: headers, body: postData)
              .timeout(const Duration(seconds: 15));
        } else {
          response = await http
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 15));
        }
      } catch (e) {
        debugPrint('RcheevosClient HTTP: request failed: $e');
        _submitNativeResponse(requestId, null, 0, -1);
        return true; // we did work (attempted the request)
      }

      // Submit response back to rc_client
      _submitNativeResponse(
        requestId,
        response.body,
        response.body.length,
        response.statusCode,
      );
    } catch (e) {
      debugPrint('RcheevosClient HTTP bridge error: $e');
    }

    return true;
  }

  /// Submit an HTTP response back to the native rc_client.
  void _submitNativeResponse(
      int requestId, String? body, int bodyLength, int httpStatus) {
    if (!_initialized) return;

    if (body != null && body.isNotEmpty) {
      final bodyPtr = body.toNativeUtf8();
      try {
        _bindings.rcSubmitResponse!(
            requestId, bodyPtr, body.length, httpStatus);
      } finally {
        calloc.free(bodyPtr);
      }
    } else {
      _bindings.rcSubmitResponse!(requestId, nullptr.cast<Utf8>(), 0, httpStatus);
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Event Processing
  // ═══════════════════════════════════════════════════════════════════

  /// Drain all queued events from the native side.
  /// Returns `true` if at least one event was processed.
  bool _drainEvents() {
    if (!_initialized) return false;

    bool didWork = false;
    while (_bindings.rcHasPendingEvent!() != 0) {
      // Read event into buffer
      final result =
          _bindings.rcGetPendingEvent!(_bindings.eventBuffer!);
      if (result == 0) break;

      // Parse the event
      final event = _bindings.readEvent();
      if (event == null) {
        _bindings.rcConsumeEvent!();
        continue;
      }

      debugPrint('RcheevosClient event: $event');

      // Handle state changes
      _handleEvent(event);

      // Emit to stream
      _eventController.add(event);

      // Consume the event
      _bindings.rcConsumeEvent!();
      didWork = true;
    }
    return didWork;
  }

  /// Handle state changes based on events.
  void _handleEvent(RcEvent event) {
    switch (event.type) {
      case RcEventType.loginSuccess:
        _loggedIn = true;
        notifyListeners();
        break;

      case RcEventType.loginFailed:
        _loggedIn = false;
        notifyListeners();
        break;

      case RcEventType.gameLoadSuccess:
        _gameLoaded = true;
        // Read game info from native
        _updateGameInfo();
        notifyListeners();
        break;

      case RcEventType.gameLoadFailed:
        _gameLoaded = false;
        _gameTitle = null;
        _gameId = 0;
        _gameBadgeUrl = null;
        notifyListeners();
        break;

      case RcEventType.achievementTriggered:
        // Add to notification queue for UI display
        _notificationQueue.add(event);
        notifyListeners();
        break;

      case RcEventType.gameCompleted:
        _notificationQueue.add(event);
        notifyListeners();
        break;

      case RcEventType.serverError:
        debugPrint('RcheevosClient: Server error: ${event.errorMessage}');
        break;

      case RcEventType.disconnected:
        debugPrint('RcheevosClient: Disconnected from server');
        break;

      case RcEventType.reconnected:
        debugPrint('RcheevosClient: Reconnected to server');
        break;
    }
  }

  /// Update cached game info from native.
  void _updateGameInfo() {
    if (!_initialized) return;

    final titlePtr = _bindings.rcGetGameTitle!();
    _gameTitle =
        titlePtr != nullptr ? titlePtr.toDartString() : null;

    _gameId = _bindings.rcGetGameId!();

    final badgePtr = _bindings.rcGetGameBadgeUrl!();
    _gameBadgeUrl =
        badgePtr != nullptr ? badgePtr.toDartString() : null;

    debugPrint('RcheevosClient: Game info updated — '
        'title="$_gameTitle", id=$_gameId');
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Cleanup
  // ═══════════════════════════════════════════════════════════════════

  @override
  void dispose() {
    shutdown();
    _eventController.close();
    _bindings.dispose();
    super.dispose();
  }
}
