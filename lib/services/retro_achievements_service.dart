import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/game_rom.dart';
import '../models/ra_achievement.dart';

// ═══════════════════════════════════════════════════════════════════════
//  RetroAchievements Console ID mapping
// ═══════════════════════════════════════════════════════════════════════

/// Maps internal [GamePlatform] values to RetroAchievements console IDs.
///
/// Official RA console IDs for supported platforms:
///   • Game Boy       → 4
///   • Game Boy Advance → 5
///   • Game Boy Color → 6
class RAConsoleId {
  RAConsoleId._();

  static const int gameBoy = 4;
  static const int gameBoyAdvance = 5;
  static const int gameBoyColor = 6;

  /// Resolve [GamePlatform] → RA console ID.
  /// Returns `null` for unknown / unsupported platforms.
  static int? fromPlatform(GamePlatform platform) {
    return switch (platform) {
      GamePlatform.gb  => gameBoy,
      GamePlatform.gba => gameBoyAdvance,
      GamePlatform.gbc => gameBoyColor,
      GamePlatform.unknown => null,
    };
  }

  /// Human-readable label for a console ID (for debug / logging).
  static String label(int id) {
    return switch (id) {
      gameBoy        => 'Game Boy',
      gameBoyAdvance => 'Game Boy Advance',
      gameBoyColor   => 'Game Boy Color',
      _              => 'Unknown ($id)',
    };
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Game session tracking
// ═══════════════════════════════════════════════════════════════════════

/// Tracks the RetroAchievements state for the currently loaded game.
class RAGameSession {
  /// The RA-assigned game ID (> 0 means achievements are available).
  final int gameId;

  /// The MD5 hash that was sent to the API.
  final String romHash;

  /// The RA console ID used.
  final int consoleId;

  /// Whether achievements are enabled for this session.
  /// `true` when [gameId] > 0 and the user is logged in.
  final bool achievementsEnabled;

  const RAGameSession({
    required this.gameId,
    required this.romHash,
    required this.consoleId,
    required this.achievementsEnabled,
  });

  @override
  String toString() =>
      'RAGameSession(gameId=$gameId, hash=$romHash, '
      'console=${RAConsoleId.label(consoleId)}, '
      'achievements=${achievementsEnabled ? "ON" : "OFF"})';
}

/// Represents the authenticated RetroAchievements user profile.
class RAUserProfile {
  final String username;
  final String profileImageUrl;
  final int totalPoints;
  final int totalSoftcorePoints;
  final int totalTruePoints;
  final String memberSince;
  final String? motto;

  const RAUserProfile({
    required this.username,
    required this.profileImageUrl,
    required this.totalPoints,
    required this.totalSoftcorePoints,
    required this.totalTruePoints,
    required this.memberSince,
    this.motto,
  });

  factory RAUserProfile.fromJson(Map<String, dynamic> json) {
    return RAUserProfile(
      username: json['User'] as String? ?? '',
      profileImageUrl:
          'https://retroachievements.org${json['UserPic'] as String? ?? ''}',
      totalPoints: _toInt(json['TotalPoints']),
      totalSoftcorePoints: _toInt(json['TotalSoftcorePoints']),
      totalTruePoints: _toInt(json['TotalTruePoints']),
      memberSince: json['MemberSince'] as String? ?? '',
      motto: json['Motto'] as String?,
    );
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

/// Result of a login attempt.
class RALoginResult {
  final bool success;
  final String? errorMessage;
  final RAUserProfile? profile;

  const RALoginResult._({
    required this.success,
    this.errorMessage,
    this.profile,
  });

  factory RALoginResult.ok(RAUserProfile profile) =>
      RALoginResult._(success: true, profile: profile);

  factory RALoginResult.error(String message) =>
      RALoginResult._(success: false, errorMessage: message);
}

/// Service for managing RetroAchievements authentication and state.
///
/// Credentials (username + web API key) are stored in Android Keystore /
/// iOS Keychain via [FlutterSecureStorage]. No password is ever used.
class RetroAchievementsService extends ChangeNotifier {
  // ── Secure storage keys ──────────────────────────────────────────────
  static const String _keyUsername = 'ra_username';
  static const String _keyApiKey = 'ra_api_key';

  // ── RA API ───────────────────────────────────────────────────────────
  static const String _baseUrl = 'https://retroachievements.org/API';

  // ── Secure storage instance ──────────────────────────────────────────
  // AndroidOptions: use encrypted shared prefs backed by the Android Keystore.
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // ── State ────────────────────────────────────────────────────────────
  bool _isLoggedIn = false;
  bool _isLoading = false;
  String? _username;
  RAUserProfile? _profile;
  String? _lastError;

  // ── Game session state ──────────────────────────────────────────────
  RAGameSession? _activeSession;
  bool _isResolvingGame = false;

  // ── Achievement data state ─────────────────────────────────────────
  RAGameData? _gameData;
  bool _isLoadingGameData = false;

  // ── Cache config ───────────────────────────────────────────────────
  /// Achievement data older than this is considered stale and will be
  /// refreshed in the background on next launch.  Stale data is still
  /// served immediately — the user is never blocked.
  static const Duration _cacheMaxAge = Duration(hours: 24);

  bool get isLoggedIn => _isLoggedIn;
  bool get isLoading => _isLoading;
  String? get username => _username;
  RAUserProfile? get profile => _profile;

  /// The last error message from login / init, or `null` if no error.
  /// Cleared on successful login, logout, or explicit [clearError].
  String? get lastError => _lastError;

  /// The active game session, if a ROM has been identified.
  RAGameSession? get activeSession => _activeSession;

  /// Whether we are currently resolving a game ID for a loaded ROM.
  bool get isResolvingGame => _isResolvingGame;

  /// Achievement metadata for the current game, or `null` if not yet loaded.
  RAGameData? get gameData => _gameData;

  /// Whether achievement data is currently being fetched from API / disk.
  bool get isLoadingGameData => _isLoadingGameData;

  /// Convenience: are achievements enabled for the current session?
  bool get achievementsEnabled => _activeSession?.achievementsEnabled ?? false;

  // ── Initialisation (call once at app start) ──────────────────────────

  /// Loads persisted credentials from secure storage and silently
  /// re-validates them against the RA API.  If validation fails the
  /// user is logged out automatically.
  Future<void> initialize() async {
    _isLoading = true;
    _lastError = null;
    notifyListeners();

    try {
      final storedUser = await _storage.read(key: _keyUsername);
      final storedKey = await _storage.read(key: _keyApiKey);

      if (storedUser != null &&
          storedUser.isNotEmpty &&
          storedKey != null &&
          storedKey.isNotEmpty) {
        // Re-validate stored credentials
        final result = await _fetchUserProfile(storedUser, storedKey);
        if (result.success) {
          _username = storedUser;
          _profile = result.profile;
          _isLoggedIn = true;
          _lastError = null;
        } else {
          // Credentials stale / revoked → wipe them
          _lastError = result.errorMessage ?? 'API key invalid or revoked.';
          await _clearCredentials();
        }
      }
    } catch (e) {
      debugPrint('RA init error: $e');
      _lastError = 'Initialization error: $e';
      // Don't crash – just stay logged out
    }

    _isLoading = false;
    notifyListeners();
  }

  // ── Login ────────────────────────────────────────────────────────────

  /// Attempt to log in with the given [username] and [apiKey].
  ///
  /// Calls `API_GetUserProfile` to validate the credentials.  On success
  /// the credentials are persisted to secure storage and the service
  /// transitions to the *logged-in* state.
  Future<RALoginResult> login(String username, String apiKey) async {
    if (username.trim().isEmpty || apiKey.trim().isEmpty) {
      return RALoginResult.error('Username and API key are required.');
    }

    _isLoading = true;
    notifyListeners();

    try {
      final result = await _fetchUserProfile(username.trim(), apiKey.trim());

      if (result.success) {
        // Persist to secure storage
        await _storage.write(key: _keyUsername, value: username.trim());
        await _storage.write(key: _keyApiKey, value: apiKey.trim());

        _username = username.trim();
        _profile = result.profile;
        _isLoggedIn = true;
        _lastError = null;
      } else {
        _lastError = result.errorMessage;
      }

      _isLoading = false;
      notifyListeners();
      return result;
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      return RALoginResult.error('Unexpected error: $e');
    }
  }

  // ── Logout ───────────────────────────────────────────────────────────

  /// Wipe stored credentials, clear achievement cache, and reset state.
  Future<void> logout() async {
    await _clearCredentials();
    await _clearCachedGameData();
    _username = null;
    _profile = null;
    _isLoggedIn = false;
    _activeSession = null;
    _gameData = null;
    _lastError = null;
    notifyListeners();
  }

  /// Clear the last error state (e.g. after the user acknowledges it).
  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  // ── Credential helpers ───────────────────────────────────────────────

  /// Read the stored API key (needed by other services that call the RA API).
  Future<String?> getApiKey() async {
    return _storage.read(key: _keyApiKey);
  }

  Future<void> _clearCredentials() async {
    await _storage.delete(key: _keyUsername);
    await _storage.delete(key: _keyApiKey);
  }

  // ── API call ─────────────────────────────────────────────────────────

  /// Calls `API_GetUserProfile` and returns a [RALoginResult].
  ///
  /// API request structure:
  /// ```
  /// GET https://retroachievements.org/API/API_GetUserProfile.php
  ///   ?z=<username>     ← authenticating user
  ///   &y=<apiKey>       ← web API key (NOT password)
  ///   &u=<username>     ← user to look up (same user)
  /// ```
  ///
  /// A successful response is JSON containing at least the `User` field.
  /// An error or invalid credentials return an HTTP error code or a JSON
  /// body without the expected fields.
  static Future<RALoginResult> _fetchUserProfile(
    String username,
    String apiKey,
  ) async {
    final uri = Uri.parse('$_baseUrl/API_GetUserProfile.php').replace(
      queryParameters: {
        'z': username,
        'y': apiKey,
        'u': username,
      },
    );

    try {
      final response = await http.get(uri).timeout(
        const Duration(seconds: 15),
      );

      if (response.statusCode == 401 || response.statusCode == 403) {
        return RALoginResult.error(
          'Invalid credentials. Please double-check your username and API key.',
        );
      }

      if (response.statusCode != 200) {
        return RALoginResult.error(
          'Server error (HTTP ${response.statusCode}). Try again later.',
        );
      }

      // Parse JSON body
      final dynamic body = jsonDecode(response.body);

      if (body is! Map<String, dynamic>) {
        return RALoginResult.error(
          'Invalid response from RetroAchievements. Check your API key.',
        );
      }

      // The API returns an object with an 'Error' key on bad credentials
      if (body.containsKey('Error')) {
        return RALoginResult.error(
          body['Error'] as String? ??
              'Authentication failed. Verify your API key.',
        );
      }

      // Must contain 'User' to be a valid profile
      if (!body.containsKey('User') || (body['User'] as String?) == null) {
        return RALoginResult.error(
          'Invalid response — user not found. Check your username.',
        );
      }

      final profile = RAUserProfile.fromJson(body);
      return RALoginResult.ok(profile);
    } on http.ClientException {
      return RALoginResult.error(
        'Network error. Check your internet connection and try again.',
      );
    } on FormatException {
      return RALoginResult.error(
        'Unexpected response format from RetroAchievements.',
      );
    } catch (e) {
      if (e.toString().contains('TimeoutException')) {
        return RALoginResult.error(
          'Connection timed out. Please try again.',
        );
      }
      return RALoginResult.error('Connection failed: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Game Detection — ROM hash + API_GetGameID
  // ═══════════════════════════════════════════════════════════════════════

  /// Start a RetroAchievements session for the given [rom].
  ///
  /// Steps performed (all locally except the final API call):
  ///   1. Map [GameRom.platform] → RA console ID.
  ///   2. Compute the RA-compatible MD5 hash of the ROM file **locally**.
  ///      No ROM data is uploaded — only the 32-char hex hash is sent.
  ///   3. Call `API_GetGameID` with the console ID and ROM hash.
  ///   4. If a valid game ID (> 0) is returned, enable achievements.
  ///      Otherwise disable them silently for this game.
  ///
  /// The session is stored in [activeSession] and listeners are notified.
  /// If the user is not logged in, the session is still created but
  /// achievements are marked as disabled.
  Future<void> startGameSession(GameRom rom) async {
    // ── 1. Console ID ─────────────────────────────────────────────────
    final consoleId = RAConsoleId.fromPlatform(rom.platform);
    if (consoleId == null) {
      debugPrint('RA: Unsupported platform ${rom.platformName} — '
          'achievements disabled');
      _activeSession = null;
      notifyListeners();
      return;
    }

    _isResolvingGame = true;
    notifyListeners();

    try {
      // ── 2. Compute ROM hash (local only, no upload) ───────────────
      final romHash = await computeRAHash(rom.path);
      if (romHash == null) {
        debugPrint('RA: Failed to hash ROM ${rom.name} — '
            'achievements disabled');
        _activeSession = null;
        _isResolvingGame = false;
        notifyListeners();
        return;
      }

      debugPrint('RA: ROM hash for "${rom.name}" '
          '[${RAConsoleId.label(consoleId)}] = $romHash');

      // ── 3. Resolve Game ID via API ────────────────────────────────
      final gameId = await _resolveGameId(romHash);

      // ── 4. Build session ──────────────────────────────────────────
      final enabled = gameId > 0 && _isLoggedIn;
      _activeSession = RAGameSession(
        gameId: gameId,
        romHash: romHash,
        consoleId: consoleId,
        achievementsEnabled: enabled,
      );

      if (gameId > 0) {
        debugPrint('RA: Game identified — ID=$gameId, '
            'achievements=${enabled ? "ENABLED" : "DISABLED (not logged in)"}');
      } else {
        debugPrint('RA: No game found for hash $romHash — '
            'achievements disabled');
      }
    } catch (e) {
      debugPrint('RA: Error during game detection: $e — '
          'achievements disabled');
      _activeSession = null;
    }

    _isResolvingGame = false;
    notifyListeners();

    // ── 5. Load achievement data (async, never blocks gameplay) ──────
    if (_activeSession != null &&
        _activeSession!.gameId > 0 &&
        _isLoggedIn) {
      // Fire-and-forget: loads from cache first, then refreshes in bg
      _loadGameData(_activeSession!.gameId);
    }
  }

  /// End the current game session (call when the ROM is unloaded).
  void endGameSession() {
    if (_activeSession == null && _gameData == null) return;
    debugPrint('RA: Session ended for game ID=${_activeSession?.gameId}');
    _activeSession = null;
    _gameData = null;
    _isResolvingGame = false;
    _isLoadingGameData = false;
    notifyListeners();
  }

  // ── ROM Hashing ─────────────────────────────────────────────────────

  /// Compute the RetroAchievements-compatible hash for a ROM file.
  ///
  /// **Hashing rules (per RA spec):**
  ///   • **Game Boy (GB):**  MD5 of the entire ROM file.
  ///   • **Game Boy Color (GBC):**  MD5 of the entire ROM file.
  ///   • **Game Boy Advance (GBA):**  MD5 of the entire ROM file.
  ///
  /// All hashing is done **locally** — no ROM data leaves the device.
  /// Returns the lowercase 32-character hex MD5 string, or `null` on
  /// error (file not found, read failure, etc.).
  static Future<String?> computeRAHash(String romPath) async {
    try {
      final file = File(romPath);
      if (!await file.exists()) {
        debugPrint('RA hash: file not found — $romPath');
        return null;
      }

      // Stream the file through MD5 to avoid loading the entire ROM
      // into memory at once (GBA ROMs can be up to 32 MB).
      final digest = await md5.bind(file.openRead()).first;
      return digest.toString(); // lowercase hex string
    } catch (e) {
      debugPrint('RA hash error: $e');
      return null;
    }
  }

  // ── API_GetGameID ───────────────────────────────────────────────────

  /// Call the RetroAchievements game-ID resolution endpoint.
  ///
  /// ```
  /// GET https://retroachievements.org/dorequest.php
  ///   ?r=gameid
  ///   &m=<md5hash>
  /// ```
  ///
  /// Returns the numeric game ID (> 0) on success, or `0` if the hash
  /// is not recognised.  Network / parse errors also return `0` so that
  /// achievements are silently disabled rather than crashing the app.
  Future<int> _resolveGameId(String hash) async {
    final uri = Uri.parse(
      'https://retroachievements.org/dorequest.php',
    ).replace(
      queryParameters: {
        'r': 'gameid',
        'm': hash,
      },
    );

    try {
      final response = await http.get(uri).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode != 200) {
        debugPrint('RA API_GetGameID: HTTP ${response.statusCode}');
        return 0;
      }

      final dynamic body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) {
        debugPrint('RA API_GetGameID: unexpected response format');
        return 0;
      }

      final success = body['Success'] as bool? ?? false;
      if (!success) {
        debugPrint('RA API_GetGameID: Success=false');
        return 0;
      }

      final gameId = _parseGameId(body['GameID']);
      return gameId;
    } on http.ClientException catch (e) {
      debugPrint('RA API_GetGameID network error: $e');
      return 0;
    } on FormatException catch (e) {
      debugPrint('RA API_GetGameID parse error: $e');
      return 0;
    } catch (e) {
      if (e.toString().contains('TimeoutException')) {
        debugPrint('RA API_GetGameID: timed out');
      } else {
        debugPrint('RA API_GetGameID error: $e');
      }
      return 0;
    }
  }

  /// Parse a game ID from the API response (may be int or String).
  static int _parseGameId(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Achievement Metadata — cache-first loading with background refresh
  // ═══════════════════════════════════════════════════════════════════════
  //
  //  Refresh policy:
  //  ┌──────────────────────────────────────────────────────────────────┐
  //  │ Cache state        │ Action                                     │
  //  ├────────────────────┼────────────────────────────────────────────│
  //  │ No cache           │ Fetch from API, cache result               │
  //  │ Cache < 24 h old   │ Serve cache, no network call               │
  //  │ Cache ≥ 24 h old   │ Serve cache immediately, refresh in bg     │
  //  │ Network failure    │ Serve cache (any age), or null if no cache │
  //  └──────────────────────────────────────────────────────────────────┘
  //
  //  Badge images are NOT pre-fetched. The model exposes URL getters
  //  (badgeUrl / badgeLockedUrl) that the UI loads lazily on demand
  //  via Image.network() or any caching image widget.

  /// Load achievement metadata for the given [gameId].
  ///
  /// 1. Try disk cache first (instant).
  /// 2. If cache is fresh (< 24 h) → done.
  /// 3. If cache is stale or missing → fetch from API in the background.
  /// 4. On API failure with existing cache → keep stale data.
  ///
  /// Never blocks the calling code — the UI reacts via [notifyListeners].
  Future<void> _loadGameData(int gameId) async {
    _isLoadingGameData = true;
    notifyListeners();

    try {
      // ── 1. Try disk cache ───────────────────────────────────────────
      final cached = await _readCachedGameData(gameId);

      if (cached != null) {
        _gameData = cached;
        _isLoadingGameData = false;
        notifyListeners();
        debugPrint('RA: Loaded ${cached.achievements.length} achievements '
            'from cache for game $gameId '
            '(age: ${DateTime.now().difference(cached.fetchedAt).inMinutes}m)');

        // ── 2. If fresh → we're done ────────────────────────────────
        if (!cached.isStale) return;

        // ── 3. Stale → background refresh ───────────────────────────
        debugPrint('RA: Cache stale for game $gameId — refreshing in bg');
        _backgroundRefresh(gameId);
        return;
      }

      // ── 4. No cache → must fetch ─────────────────────────────────
      debugPrint('RA: No cache for game $gameId — fetching from API');
      final fresh = await _fetchGameDataFromApi(gameId);
      if (fresh != null) {
        _gameData = fresh;
        await _writeCachedGameData(gameId, fresh);
        debugPrint('RA: Fetched ${fresh.achievements.length} achievements '
            'for game $gameId');
      } else {
        debugPrint('RA: Failed to fetch achievements for game $gameId');
      }
    } catch (e) {
      debugPrint('RA: Error loading game data: $e');
    }

    _isLoadingGameData = false;
    notifyListeners();
  }

  /// Refresh game data in the background (fire-and-forget).
  ///
  /// On success the in-memory [_gameData] and disk cache are updated,
  /// and listeners are notified so the UI can react.  On failure the
  /// existing (stale) cache is silently kept.
  void _backgroundRefresh(int gameId) {
    _fetchGameDataFromApi(gameId).then((fresh) async {
      if (fresh == null) return;

      // Only apply if the session hasn't changed since we started
      if (_activeSession?.gameId != gameId) return;

      _gameData = fresh;
      await _writeCachedGameData(gameId, fresh);
      notifyListeners();
      debugPrint('RA: Background refresh complete for game $gameId '
          '(${fresh.achievements.length} achievements)');
    }).catchError((e) {
      debugPrint('RA: Background refresh failed for game $gameId: $e');
    });
  }

  /// Force a fresh fetch and cache update for the current game.
  ///
  /// Call this from the UI when the user explicitly requests a refresh
  /// (e.g. pull-to-refresh on an achievements screen).
  Future<void> refreshGameData() async {
    final gameId = _activeSession?.gameId;
    if (gameId == null || gameId <= 0 || !_isLoggedIn) return;

    _isLoadingGameData = true;
    notifyListeners();

    try {
      final fresh = await _fetchGameDataFromApi(gameId);
      if (fresh != null) {
        _gameData = fresh;
        await _writeCachedGameData(gameId, fresh);
      }
    } catch (e) {
      debugPrint('RA: Manual refresh failed: $e');
    }

    _isLoadingGameData = false;
    notifyListeners();
  }

  // ── API_GetGameInfoExtended ─────────────────────────────────────────

  /// Fetch full game metadata (including achievements and user progress)
  /// from the RA API.
  ///
  /// ```
  /// GET https://retroachievements.org/API/API_GetGameInfoExtended.php
  ///   ?z=<username>
  ///   &y=<apiKey>
  ///   &i=<gameId>
  /// ```
  ///
  /// Returns [RAGameData] on success, or `null` on any failure.
  /// All errors are caught and logged — the caller never sees an exception.
  Future<RAGameData?> _fetchGameDataFromApi(int gameId) async {
    final apiKey = await getApiKey();
    if (_username == null || apiKey == null) {
      debugPrint('RA API_GetGame: not logged in');
      return null;
    }

    final uri = Uri.parse('$_baseUrl/API_GetGameInfoExtended.php').replace(
      queryParameters: {
        'z': _username!,
        'y': apiKey,
        'i': gameId.toString(),
      },
    );

    try {
      final response = await http.get(uri).timeout(
        const Duration(seconds: 15),
      );

      if (response.statusCode != 200) {
        debugPrint('RA API_GetGame: HTTP ${response.statusCode}');
        return null;
      }

      final dynamic body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) {
        debugPrint('RA API_GetGame: unexpected response format');
        return null;
      }

      if (body.containsKey('Error')) {
        debugPrint('RA API_GetGame: ${body['Error']}');
        return null;
      }

      // Inject fetchedAt timestamp before parsing
      body['fetchedAt'] = DateTime.now().toIso8601String();

      return RAGameData.fromJson(body);
    } on http.ClientException catch (e) {
      debugPrint('RA API_GetGame network error: $e');
      return null;
    } on FormatException catch (e) {
      debugPrint('RA API_GetGame parse error: $e');
      return null;
    } catch (e) {
      if (e.toString().contains('TimeoutException')) {
        debugPrint('RA API_GetGame: timed out');
      } else {
        debugPrint('RA API_GetGame error: $e');
      }
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Disk cache — JSON files per game, scoped to the logged-in user
  // ═══════════════════════════════════════════════════════════════════════
  //
  //  Cache directory layout:
  //    <appSupport>/ra_cache/<username>/game_<gameId>.json
  //
  //  Per-user scoping ensures that:
  //    • User A's earned-achievement timestamps don't bleed into User B
  //    • Logging out + logging in as a different user gets fresh data
  //    • Cache files are small (~5–50 KB each) and self-contained

  /// Resolve the cache directory for the current user, creating it if needed.
  Future<Directory> _getCacheDir() async {
    final appDir = await getApplicationSupportDirectory();
    final user = _username ?? '_anonymous';
    final dir = Directory(p.join(appDir.path, 'ra_cache', user));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// File path for a game's cached achievement data.
  Future<String> _cacheFilePath(int gameId) async {
    final dir = await _getCacheDir();
    return p.join(dir.path, 'game_$gameId.json');
  }

  /// Read cached [RAGameData] from disk, or `null` if not found / corrupt.
  Future<RAGameData?> _readCachedGameData(int gameId) async {
    try {
      final path = await _cacheFilePath(gameId);
      final file = File(path);
      if (!file.existsSync()) return null;

      final jsonString = await file.readAsString();
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return RAGameData.fromJson(json);
    } catch (e) {
      debugPrint('RA cache read error (game $gameId): $e');
      return null;
    }
  }

  /// Write [RAGameData] to disk cache.
  Future<void> _writeCachedGameData(int gameId, RAGameData data) async {
    try {
      final path = await _cacheFilePath(gameId);
      final jsonString = jsonEncode(data.toJson());
      await File(path).writeAsString(jsonString);
      debugPrint('RA: Cached achievement data for game $gameId '
          '(${jsonString.length} bytes)');
    } catch (e) {
      debugPrint('RA cache write error (game $gameId): $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Runtime API — Session, Ping, Award
  // ═══════════════════════════════════════════════════════════════════════
  //
  //  These are called by [RARuntimeService] during gameplay.
  //  All calls are fire-and-forget and must never block the frame loop.

  /// Start a play session on the RA server.
  ///
  /// ```
  /// GET https://retroachievements.org/dorequest.php
  ///   ?r=startsession
  ///   &u=<username>
  ///   &t=<apiKey>
  ///   &g=<gameId>
  /// ```
  Future<void> apiStartSession() async {
    final session = _activeSession;
    if (session == null || !_isLoggedIn) return;

    final apiKey = await getApiKey();
    if (apiKey == null || _username == null) return;

    final uri = Uri.parse(
      'https://retroachievements.org/dorequest.php',
    ).replace(queryParameters: {
      'r': 'startsession',
      'u': _username!,
      't': apiKey,
      'g': session.gameId.toString(),
    });

    try {
      final response = await http.get(uri).timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode == 200) {
        debugPrint('RA API: startsession OK');
      } else {
        debugPrint('RA API: startsession HTTP ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('RA API: startsession error: $e');
    }
  }

  /// Send a heartbeat ping to the RA server.
  ///
  /// ```
  /// GET https://retroachievements.org/dorequest.php
  ///   ?r=ping
  ///   &u=<username>
  ///   &t=<apiKey>
  ///   &g=<gameId>
  /// ```
  Future<void> apiPing() async {
    final session = _activeSession;
    if (session == null || !_isLoggedIn) return;

    final apiKey = await getApiKey();
    if (apiKey == null || _username == null) return;

    final uri = Uri.parse(
      'https://retroachievements.org/dorequest.php',
    ).replace(queryParameters: {
      'r': 'ping',
      'u': _username!,
      't': apiKey,
      'g': session.gameId.toString(),
    });

    try {
      await http.get(uri).timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('RA API: ping error: $e');
    }
  }

  /// Submit an achievement unlock to the RA server.
  ///
  /// ```
  /// GET https://retroachievements.org/dorequest.php
  ///   ?r=awardachievement
  ///   &u=<username>
  ///   &t=<apiKey>
  ///   &a=<achievementId>
  ///   &h=<1 for hardcore, 0 for softcore>
  /// ```
  ///
  /// Returns `true` if the server accepted the unlock.
  Future<bool> apiAwardAchievement({
    required int achievementId,
    required bool hardcore,
  }) async {
    if (!_isLoggedIn) return false;

    final apiKey = await getApiKey();
    if (apiKey == null || _username == null) return false;

    final uri = Uri.parse(
      'https://retroachievements.org/dorequest.php',
    ).replace(queryParameters: {
      'r': 'awardachievement',
      'u': _username!,
      't': apiKey,
      'a': achievementId.toString(),
      'h': hardcore ? '1' : '0',
    });

    try {
      final response = await http.get(uri).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode != 200) {
        debugPrint('RA API: awardachievement HTTP ${response.statusCode}');
        return false;
      }

      final dynamic body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) {
        final success = body['Success'] as bool? ?? false;
        return success;
      }
      return false;
    } catch (e) {
      debugPrint('RA API: awardachievement error: $e');
      return false;
    }
  }

  /// Delete all cached achievement data for the current user.
  ///
  /// Called on logout so that the next user gets a clean slate.
  Future<void> _clearCachedGameData() async {
    try {
      final dir = await _getCacheDir();
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
        debugPrint('RA: Cleared achievement cache');
      }
    } catch (e) {
      debugPrint('RA cache clear error: $e');
    }
  }
}
