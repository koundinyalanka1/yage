import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'providers/app_providers.dart';
import 'screens/splash_screen.dart';
import 'services/settings_service.dart';
import 'utils/theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Firebase (must be first — Crashlytics needs it) ────────────────
  await Firebase.initializeApp();

  if (!kDebugMode) {
    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
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
    systemNavigationBarColor: Color(0xFF0D0D1A), // YageColors.backgroundDark default
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // Everything else (TV detection, notifications, provider init)
  // happens inside the SplashScreen so the user sees branding immediately.
  runApp(const RetroPalApp());
}

class RetroPalApp extends StatelessWidget {
  const RetroPalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AppProviders(
      child: Consumer<SettingsService>(
        builder: (context, settingsService, _) {
          // Apply the selected theme before building the MaterialApp
          final theme = AppThemes.getById(settingsService.settings.selectedTheme);
          YageColors.setTheme(theme);

          // Update system nav bar color to match theme
          SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            systemNavigationBarColor: YageColors.backgroundDark,
            systemNavigationBarIconBrightness: Brightness.light,
          ));

          return MaterialApp(
            title: 'RetroPal',
            debugShowCheckedModeBanner: false,
            theme: YageTheme.darkTheme,
            home: const SplashScreen(),
          );
        },
      ),
    );
  }
}
