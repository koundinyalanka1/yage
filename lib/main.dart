import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'providers/app_providers.dart';
import 'screens/splash_screen.dart';
import 'services/game_database.dart';
import 'services/settings_service.dart';
import 'services/ad_service.dart';
import 'utils/device_memory.dart';
import 'utils/theme.dart';
import 'utils/tv_detector.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── SQLite FFI for desktop (Windows / Linux) ─────────────────────
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // ── Firebase (must be first — Crashlytics needs it) ────────────────
  try {
    await Firebase.initializeApp();

    if (!kDebugMode) {
      FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
      PlatformDispatcher.instance.onError = (error, stack) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };
    }
  } catch (e) {
    debugPrint('Firebase init failed — running without analytics: $e');
  }

  // ── Open the game library database ────────────────────────────────
  final gameDatabase = GameDatabase();
  try {
    await gameDatabase.open();
  } catch (e) {
    debugPrint('Database open failed: $e');
    rethrow;
  }

  // ── System UI (safe to set before the first frame) ─────────────────
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0D0D1A), // default backgroundDark
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // Initialize TV detection before any widget reads TvDetector.isTV.
  await TvDetector.initialize();

  // Cache device memory for rewind buffer sizing (avoids OOM on low-RAM devices).
  await initDeviceMemory();

  // Initialize AdMob (mobile only, skip on TV to prevent crashes).
  if (!TvDetector.isTV) {
    await AdService.instance.initialize();
  }

  runApp(RetroPalApp(gameDatabase: gameDatabase));
}

class RetroPalApp extends StatelessWidget {
  final GameDatabase gameDatabase;

  const RetroPalApp({super.key, required this.gameDatabase});

  @override
  Widget build(BuildContext context) {
    return AppProviders(
      gameDatabase: gameDatabase,
      child: Consumer<SettingsService>(
        builder: (context, settingsService, _) {
          final colors = AppThemes.getById(settingsService.settings.selectedTheme);

          // Update system nav bar color to match theme
          SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            systemNavigationBarColor: colors.backgroundDark,
            systemNavigationBarIconBrightness: Brightness.light,
          ));

          // The AppColorTheme is stored as a ThemeExtension inside the
          // ThemeData.  Widgets access it via AppColorTheme.of(context)
          // which calls Theme.of(context) — so they rebuild automatically
          // when the theme changes.  No ValueKey hack needed.
          // Map typical Android TV remote and gamepad "Select" buttons to standard activation.
          // This makes all standard Flutter buttons (FilledButton, TextButton, ListTile, etc.)
          // clickable via D-Pad Center or Gamepad A.
          return Shortcuts(
            shortcuts: <LogicalKeySet, Intent>{
              LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
              LogicalKeySet(LogicalKeyboardKey.gameButtonA): const ActivateIntent(),
              LogicalKeySet(LogicalKeyboardKey.gameButtonStart): const ActivateIntent(),
              LogicalKeySet(LogicalKeyboardKey.numpadEnter): const ActivateIntent(),
            },
            child: MaterialApp(
              title: 'RetroPal',
              debugShowCheckedModeBanner: false,
              theme: YageTheme.darkTheme(colors),
              home: const SplashScreen(),
            ),
          );
        },
      ),
    );
  }
}
