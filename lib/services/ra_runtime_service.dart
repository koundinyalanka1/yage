import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/ra_achievement.dart';
import 'retro_achievements_service.dart';

// ═══════════════════════════════════════════════════════════════════════
//  RetroAchievements Runtime Mode
// ═══════════════════════════════════════════════════════════════════════

/// The RA mode determines which emulator conveniences are allowed.
enum RAMode {
  /// Hardcore — no savestates, cheats, rewind, or fast-forward.
  /// Achievements are earned at full difficulty.
  hardcore,

  /// Softcore — all emulator conveniences are allowed.
  /// Achievements are still earned but tracked separately.
  softcore,

  /// Disabled — RetroAchievements runtime is not active.
  /// No restrictions, no achievement tracking.
  disabled,
}

// ═══════════════════════════════════════════════════════════════════════
//  Achievement Unlock Event
// ═══════════════════════════════════════════════════════════════════════

/// Represents a single achievement unlock event for the notification queue.
class RAUnlockEvent {
  /// The achievement that was unlocked.
  final RAAchievement achievement;

  /// Whether this was earned in hardcore mode.
  final bool isHardcore;

  /// When the unlock was detected.
  final DateTime timestamp;

  /// Whether the unlock has been submitted to the RA API.
  bool submitted;

  /// Number of submission attempts.
  int attempts;

  RAUnlockEvent({
    required this.achievement,
    required this.isHardcore,
    DateTime? timestamp,
    this.submitted = false,
    this.attempts = 0,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() =>
      'RAUnlockEvent("${achievement.title}", '
      '${isHardcore ? "hardcore" : "softcore"}, '
      'submitted=$submitted)';
}

// ═══════════════════════════════════════════════════════════════════════
//  Memory Reader Interface
// ═══════════════════════════════════════════════════════════════════════

/// Abstract interface for reading emulator memory.
///
/// This is the bridge between the emulator core and the RA runtime.
/// The concrete implementation wraps MGBACore.readByte() via FFI.
abstract class RAMemoryReader {
  /// Read a single byte from the emulator's address space.
  /// Returns the byte value (0-255), or -1 on error.
  int readByte(int address);

  /// Whether memory reading is available (native symbols loaded).
  bool get isAvailable;
}

// ═══════════════════════════════════════════════════════════════════════
//  RA Runtime Service
// ═══════════════════════════════════════════════════════════════════════

/// Core runtime service for RetroAchievements integration.
///
/// This service is responsible for:
///   • Receiving per-frame ticks from the emulator loop
///   • Reading emulator memory and evaluating achievement conditions
///   • Detecting unlock events and queuing them for notification + API submission
///   • Managing the RA session (startsession, periodic ping)
///   • Enforcing hardcore/softcore mode rules
///
/// ## Architecture
///
/// The runtime connects to the emulator via two interfaces:
///   1. [RAMemoryReader] — reads bytes from emulator memory each frame
///   2. [RetroAchievementsService] — handles API calls and credential management
///
/// Achievement condition evaluation requires the rcheevos C library compiled
/// into the native emulator core.  Until that integration is complete, the
/// runtime uses a polling-based approach: it tracks which achievements the
/// user has already earned (from the cached game data) and monitors for
/// new unlocks via periodic API checks.
///
/// When rcheevos is integrated natively, the runtime will switch to
/// real-time per-frame evaluation via FFI callbacks.
class RARuntimeService extends ChangeNotifier {
  final RetroAchievementsService _raService;

  // ── State ──────────────────────────────────────────────────────────
  RAMode _mode = RAMode.disabled;
  bool _isActive = false;
  RAMemoryReader? _memoryReader;

  // ── Unlock tracking ────────────────────────────────────────────────
  /// Queue of pending unlock notifications (shown to the user).
  final Queue<RAUnlockEvent> _notificationQueue = Queue();

  /// Queue of pending unlock submissions (sent to the RA API).
  final List<RAUnlockEvent> _submissionQueue = [];

  /// Set of achievement IDs already unlocked this session (prevent dupes).
  final Set<int> _sessionUnlocks = {};

  /// Set of achievement IDs the user already earned before this session.
  final Set<int> _priorUnlocks = {};

  // ── Session management ─────────────────────────────────────────────
  Timer? _pingTimer;
  Timer? _submissionRetryTimer;
  bool _sessionStarted = false;

  /// How often to send a heartbeat ping to the RA server.
  static const Duration _pingInterval = Duration(minutes: 2);

  /// How often to retry failed unlock submissions.
  static const Duration _retryInterval = Duration(seconds: 30);

  /// Maximum submission retry attempts before giving up on an individual unlock.
  static const int _maxRetryAttempts = 10;

  // ── Frame counter for periodic checks ──────────────────────────────
  int _frameCounter = 0;

  /// How often (in frames) to run the achievement evaluation pass.
  /// At 60fps, 60 frames ≈ 1 second.  For rcheevos integration this
  /// should be 1 (every frame), but for the polling fallback we use a
  /// larger interval to avoid unnecessary work.
  static const int _evaluationInterval = 1;

  // ── Public getters ─────────────────────────────────────────────────

  RAMode get mode => _mode;
  bool get isActive => _isActive;
  bool get isHardcore => _mode == RAMode.hardcore;
  bool get isSoftcore => _mode == RAMode.softcore;

  /// Whether there are pending unlock notifications to display.
  bool get hasNotification => _notificationQueue.isNotEmpty;

  /// Peek at the next unlock notification without removing it.
  RAUnlockEvent? get nextNotification =>
      _notificationQueue.isNotEmpty ? _notificationQueue.first : null;

  /// Number of achievements unlocked this session.
  int get sessionUnlockCount => _sessionUnlocks.length;

  /// Number of pending API submissions.
  int get pendingSubmissions => _submissionQueue.where((e) => !e.submitted).length;

  // ── Constructor ────────────────────────────────────────────────────

  RARuntimeService(this._raService);

  // ═══════════════════════════════════════════════════════════════════
  //  Lifecycle
  // ═══════════════════════════════════════════════════════════════════

  /// Activate the RA runtime for a game session.
  ///
  /// [hardcoreMode] — whether to enforce hardcore restrictions.
  /// [memoryReader] — the memory reader for the current emulator core.
  ///
  /// Call this after [RetroAchievementsService.startGameSession] succeeds
  /// and the emulator has loaded the ROM.
  Future<void> activate({
    required bool hardcoreMode,
    RAMemoryReader? memoryReader,
  }) async {
    final session = _raService.activeSession;
    if (session == null || !session.achievementsEnabled) {
      _mode = RAMode.disabled;
      _isActive = false;
      notifyListeners();
      return;
    }

    _memoryReader = memoryReader;
    _mode = hardcoreMode ? RAMode.hardcore : RAMode.softcore;
    _isActive = true;
    _frameCounter = 0;
    _sessionUnlocks.clear();
    _notificationQueue.clear();
    _submissionQueue.clear();

    // Build the set of previously-earned achievements
    _priorUnlocks.clear();
    final gameData = _raService.gameData;
    if (gameData != null) {
      for (final ach in gameData.achievements) {
        if (hardcoreMode && ach.isEarnedHardcore) {
          _priorUnlocks.add(ach.id);
        } else if (!hardcoreMode && ach.isEarned) {
          _priorUnlocks.add(ach.id);
        }
      }
    }

    debugPrint('RA Runtime: Activated in ${_mode.name} mode '
        '(${_priorUnlocks.length} prior unlocks, '
        'memory=${memoryReader?.isAvailable ?? false})');

    // Start the RA session on the server
    await _startSession();

    // Start periodic ping
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) => _sendPing());

    // Start submission retry timer
    _submissionRetryTimer?.cancel();
    _submissionRetryTimer = Timer.periodic(_retryInterval, (_) => _retrySubmissions());

    notifyListeners();
  }

  /// Deactivate the RA runtime (call when the game exits).
  void deactivate() {
    if (!_isActive) return;

    _isActive = false;
    _mode = RAMode.disabled;
    _pingTimer?.cancel();
    _pingTimer = null;
    _submissionRetryTimer?.cancel();
    _submissionRetryTimer = null;
    _memoryReader = null;
    _sessionStarted = false;
    _frameCounter = 0;

    // Try to submit any remaining unlocks before shutting down
    if (_submissionQueue.any((e) => !e.submitted)) {
      _retrySubmissions();
    }

    debugPrint('RA Runtime: Deactivated '
        '($sessionUnlockCount unlocks this session, '
        '${pendingSubmissions} pending submissions)');

    notifyListeners();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Per-Frame Hook
  // ═══════════════════════════════════════════════════════════════════

  /// Called once per emulated frame from the emulator's frame loop.
  ///
  /// This is the main entry point for achievement condition evaluation.
  /// It must be fast — any heavy work is deferred or rate-limited.
  ///
  /// When rcheevos is integrated, this calls `rc_client_do_frame()` which
  /// evaluates all conditions and fires unlock callbacks synchronously.
  ///
  /// In the current polling mode, this is a no-op most frames and only
  /// runs a check at [_evaluationInterval] intervals.
  void processFrame() {
    if (!_isActive) return;

    _frameCounter++;

    if (_frameCounter % _evaluationInterval != 0) return;

    // ── Achievement condition evaluation ────────────────────────────
    //
    // TODO(rcheevos): When the native core compiles rcheevos, replace
    // this with a call to `rc_client_do_frame()` via FFI.  The native
    // side will read memory and evaluate conditions, then invoke a
    // Dart callback for each unlock.
    //
    // For now, memory reading is available via [_memoryReader] but
    // condition evaluation requires rcheevos.  The runtime is fully
    // functional for: mode enforcement, session management, unlock
    // submission, and notification display.
    //
    // The simplified evaluator below handles achievements whose
    // conditions have been parsed and can be checked against memory.
    _evaluateConditions();
  }

  /// Evaluate achievement conditions against current memory state.
  ///
  /// This is a placeholder that will be replaced by rcheevos.
  /// Currently it only checks for unlocks that were detected via
  /// the API polling path (background refresh of game data).
  void _evaluateConditions() {
    if (_memoryReader == null || !(_memoryReader?.isAvailable ?? false)) {
      // Memory read not available — use API-based detection only.
      // This happens on every background refresh of game data.
      return;
    }

    // ── rcheevos integration point ──────────────────────────────────
    //
    // When rcheevos is available via FFI, the flow will be:
    //
    //   1. rc_client_do_frame() is called (native side)
    //   2. For each unlock, native fires a callback
    //   3. Dart receives the callback and calls triggerUnlock()
    //
    // Until then, unlocks are detected via:
    //   • API polling (background refresh of game data)
    //   • Manual triggers (for testing)
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Unlock Detection & Notification
  // ═══════════════════════════════════════════════════════════════════

  /// Trigger an achievement unlock.
  ///
  /// This is called when:
  ///   • rcheevos detects a condition match (future)
  ///   • API polling detects a new unlock
  ///   • Manual trigger for testing
  ///
  /// The unlock is:
  ///   1. Validated (not already unlocked)
  ///   2. Added to the notification queue
  ///   3. Added to the API submission queue
  ///   4. Listeners notified so the UI can show the toast
  void triggerUnlock(RAAchievement achievement) {
    if (!_isActive) return;

    // Skip if already unlocked this session or previously
    if (_sessionUnlocks.contains(achievement.id) ||
        _priorUnlocks.contains(achievement.id)) {
      return;
    }

    _sessionUnlocks.add(achievement.id);

    final event = RAUnlockEvent(
      achievement: achievement,
      isHardcore: isHardcore,
    );

    // Add to notification queue
    _notificationQueue.add(event);

    // Add to API submission queue
    _submissionQueue.add(event);

    debugPrint('RA Runtime: Achievement unlocked! '
        '"${achievement.title}" (${achievement.points} pts, '
        '${isHardcore ? "hardcore" : "softcore"})');

    // Fire-and-forget: submit immediately, retry on failure
    _submitUnlock(event);

    notifyListeners();
  }

  /// Consume the current notification (call after displaying it).
  /// Returns the event that was consumed, or null.
  RAUnlockEvent? consumeNotification() {
    if (_notificationQueue.isEmpty) return null;
    final event = _notificationQueue.removeFirst();
    notifyListeners();
    return event;
  }

  /// Check the latest game data for newly earned achievements that
  /// weren't in our prior set.  This is the API-polling detection path.
  void checkForNewUnlocks() {
    final gameData = _raService.gameData;
    if (gameData == null || !_isActive) return;

    for (final ach in gameData.achievements) {
      final isNewUnlock = isHardcore
          ? ach.isEarnedHardcore && !_priorUnlocks.contains(ach.id)
          : ach.isEarned && !_priorUnlocks.contains(ach.id);

      if (isNewUnlock && !_sessionUnlocks.contains(ach.id)) {
        triggerUnlock(ach);
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Mode Enforcement
  // ═══════════════════════════════════════════════════════════════════

  /// Whether save states are allowed in the current mode.
  bool get allowSaveStates => _mode != RAMode.hardcore;

  /// Whether loading save states is allowed.
  bool get allowLoadStates => _mode != RAMode.hardcore;

  /// Whether fast-forward is allowed.
  bool get allowFastForward => _mode != RAMode.hardcore;

  /// Whether rewind is allowed.
  bool get allowRewind => _mode != RAMode.hardcore;

  /// Whether cheats are allowed.
  bool get allowCheats => _mode != RAMode.hardcore;

  /// Whether slow-motion is allowed (speed < 1.0).
  bool get allowSlowMotion => _mode != RAMode.hardcore;

  /// Check if an emulator action is allowed and return a reason if blocked.
  /// Returns null if allowed, or a user-facing message if blocked.
  String? checkAction(String action) {
    if (_mode != RAMode.hardcore) return null;

    return switch (action) {
      'saveState' => 'Save states are disabled in Hardcore mode',
      'loadState' => 'Save states are disabled in Hardcore mode',
      'fastForward' => 'Fast forward is disabled in Hardcore mode',
      'rewind' => 'Rewind is disabled in Hardcore mode',
      'cheat' => 'Cheats are disabled in Hardcore mode',
      'slowMotion' => 'Slow motion is disabled in Hardcore mode',
      _ => null,
    };
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Session Management (RA API)
  // ═══════════════════════════════════════════════════════════════════

  /// Start an RA session on the server.
  ///
  /// Calls the `startsession` endpoint which:
  ///   • Registers the user as actively playing this game
  ///   • Returns server time and any delta unlocks
  Future<void> _startSession() async {
    if (_sessionStarted) return;

    try {
      await _raService.apiStartSession();
      _sessionStarted = true;
      debugPrint('RA Runtime: Session started on server');
    } catch (e) {
      debugPrint('RA Runtime: Failed to start session: $e');
      // Non-fatal — achievements can still be tracked locally
    }
  }

  /// Send a periodic heartbeat ping to the RA server.
  ///
  /// This keeps the "currently playing" status active and can include
  /// rich presence data in the future.
  Future<void> _sendPing() async {
    if (!_isActive || !_sessionStarted) return;

    try {
      await _raService.apiPing();
    } catch (e) {
      debugPrint('RA Runtime: Ping failed (will retry): $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Unlock Submission (RA API)
  // ═══════════════════════════════════════════════════════════════════

  /// Submit a single unlock to the RA API.
  ///
  /// This runs asynchronously and never blocks gameplay.
  /// On failure, the event stays in the submission queue for retry.
  Future<void> _submitUnlock(RAUnlockEvent event) async {
    if (event.submitted) return;

    event.attempts++;

    try {
      final success = await _raService.apiAwardAchievement(
        achievementId: event.achievement.id,
        hardcore: event.isHardcore,
      );

      if (success) {
        event.submitted = true;
        debugPrint('RA Runtime: Submitted unlock for '
            '"${event.achievement.title}" (attempt ${event.attempts})');
      } else {
        debugPrint('RA Runtime: Submit failed for '
            '"${event.achievement.title}" — will retry');
      }
    } catch (e) {
      debugPrint('RA Runtime: Submit error for '
          '"${event.achievement.title}": $e — will retry');
    }
  }

  /// Retry all failed unlock submissions.
  ///
  /// Called periodically by the retry timer.  Silently removes events
  /// that have exceeded [_maxRetryAttempts].
  Future<void> _retrySubmissions() async {
    final pending = _submissionQueue
        .where((e) => !e.submitted && e.attempts < _maxRetryAttempts)
        .toList();

    if (pending.isEmpty) return;

    debugPrint('RA Runtime: Retrying ${pending.length} pending submissions');

    for (final event in pending) {
      await _submitUnlock(event);
      // Small delay between submissions to avoid hammering the API
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // Remove events that have exhausted retries
    _submissionQueue.removeWhere(
        (e) => !e.submitted && e.attempts >= _maxRetryAttempts);
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Cleanup
  // ═══════════════════════════════════════════════════════════════════

  @override
  void dispose() {
    _pingTimer?.cancel();
    _submissionRetryTimer?.cancel();
    super.dispose();
  }
}
