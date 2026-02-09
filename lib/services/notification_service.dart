import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import '../models/ra_achievement.dart';

/// Service for displaying system notifications for RetroAchievements events.
///
/// Uses [FlutterLocalNotificationsPlugin] to show rich notifications with
/// achievement badge images, titles, and descriptions.
///
/// Two types of notifications:
///   1. **Session status** — "X / Y achievements" when RA connects to a game.
///   2. **Achievement unlock** — badge image + title + description on unlock.
class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _permissionGranted = false;

  /// Notification channel IDs
  static const String _channelId = 'ra_achievements';
  static const String _channelName = 'Achievements';
  static const String _channelDesc =
      'RetroAchievements unlock and progress notifications';

  /// Notification IDs (fixed IDs for status, incremented for unlocks)
  static const int _statusNotificationId = 1000;
  int _nextUnlockId = 2000;

  bool get isInitialized => _initialized;
  bool get hasPermission => _permissionGranted;

  // ═══════════════════════════════════════════════════════════════════════
  //  Initialization
  // ═══════════════════════════════════════════════════════════════════════

  /// Initialize the notification plugin and request permission.
  ///
  /// Call this once at app startup (e.g. in main.dart).
  Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
    );

    await _plugin.initialize(initSettings);
    _initialized = true;

    // Request notification permission (Android 13+)
    await requestPermission();
  }

  /// Request notification permission from the user.
  ///
  /// On Android 13+ (API 33), this shows the system permission dialog.
  /// On older versions, permission is granted by default.
  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) {
      _permissionGranted = true;
      return true;
    }

    final status = await Permission.notification.request();
    _permissionGranted = status.isGranted;

    debugPrint('Notification permission: $_permissionGranted '
        '(status: $status)');

    return _permissionGranted;
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  RA Session Status Notification
  // ═══════════════════════════════════════════════════════════════════════

  /// Show a notification with the current achievement progress for a game.
  ///
  /// Example: "Pokemon FireRed — 5 / 42 achievements (120 / 500 pts)"
  Future<void> showAchievementStatus({
    required String gameTitle,
    required int earned,
    required int total,
    required int earnedPoints,
    required int totalPoints,
    required bool isHardcore,
  }) async {
    if (!_initialized || !_permissionGranted) return;

    final mode = isHardcore ? ' [Hardcore]' : '';
    final body = '$earned / $total achievements • '
        '$earnedPoints / $totalPoints pts$mode';

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      icon: '@mipmap/ic_launcher',
      ongoing: false,
      autoCancel: true,
      category: AndroidNotificationCategory.status,
    );

    await _plugin.show(
      _statusNotificationId,
      '🏆 $gameTitle',
      body,
      NotificationDetails(android: androidDetails),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Achievement Unlock Notification
  // ═══════════════════════════════════════════════════════════════════════

  /// Show a rich notification when an achievement is unlocked.
  ///
  /// Downloads the badge image from the RA CDN and shows it as a
  /// large icon in the notification. Falls back to text-only if the
  /// download fails.
  Future<void> showAchievementUnlock({
    required RAAchievement achievement,
    required bool isHardcore,
  }) async {
    if (!_initialized || !_permissionGranted) return;

    final mode = isHardcore ? ' [Hardcore]' : '';
    final title = '🏆 Achievement Unlocked!$mode';
    final body = '${achievement.title} — ${achievement.description}\n'
        '${achievement.points} pts';

    // Try to download badge image for the large icon
    ByteArrayAndroidBitmap? largeIcon;
    try {
      final response = await http
          .get(Uri.parse(achievement.badgeUrl))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        largeIcon = ByteArrayAndroidBitmap(
          Uint8List.fromList(response.bodyBytes),
        );
      }
    } catch (e) {
      debugPrint('Notification: Failed to download badge: $e');
    }

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      largeIcon: largeIcon,
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: title,
      ),
      autoCancel: true,
      category: AndroidNotificationCategory.event,
    );

    final id = _nextUnlockId++;
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(android: androidDetails),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Dismiss
  // ═══════════════════════════════════════════════════════════════════════

  /// Dismiss the session status notification (e.g. when leaving a game).
  Future<void> dismissStatus() async {
    if (!_initialized) return;
    await _plugin.cancel(_statusNotificationId);
  }

  /// Dismiss all notifications from this app.
  Future<void> dismissAll() async {
    if (!_initialized) return;
    await _plugin.cancelAll();
  }
}
