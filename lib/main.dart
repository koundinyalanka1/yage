import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'providers/app_providers.dart';
import 'screens/home_screen.dart';
import 'services/settings_service.dart';
import 'utils/theme.dart';
import 'utils/tv_detector.dart';

const _deviceChannel = MethodChannel('com.yourmateapps.retropal/device');

/// Check whether storage permission is already granted.
Future<bool> _hasStoragePermission() async {
  try {
    return await _deviceChannel.invokeMethod<bool>('hasStoragePermission') ?? false;
  } catch (_) {
    // Not on Android or channel unavailable — treat as granted
    return true;
  }
}

/// Actually request the system-level storage permission.
/// On Android 11+ this opens the "All files access" settings page.
/// On older versions it requests READ/WRITE_EXTERNAL_STORAGE.
Future<void> _requestStoragePermission() async {
  try {
    await _deviceChannel.invokeMethod<bool>('requestStoragePermission');
  } catch (_) {
    // Not on Android or channel unavailable — ignore
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp();

  // Forward Flutter errors to Crashlytics (release builds only)
  if (!kDebugMode) {
    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  }

  // Detect Android TV before building the UI
  await TvDetector.initialize();

  // Allow all orientations
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // Set status bar style
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: YageColors.backgroundDark,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

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
            // On TV, skip the permission gate (TV file browser handles it on demand).
            home: TvDetector.isTV
                ? const HomeScreen()
                : const _StoragePermissionGate(),
          );
        },
      ),
    );
  }
}

/// Gate widget that checks storage permission on first launch.
///
/// If permission is already granted it shows [HomeScreen] immediately.
/// Otherwise it displays a friendly explanation dialog and only triggers
/// the system permission prompt when the user taps "Continue".
class _StoragePermissionGate extends StatefulWidget {
  const _StoragePermissionGate();

  @override
  State<_StoragePermissionGate> createState() => _StoragePermissionGateState();
}

class _StoragePermissionGateState extends State<_StoragePermissionGate>
    with WidgetsBindingObserver {
  bool _granted = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-check when the user returns from the system settings page
  /// (Android 11+ "All files access" opens an external activity).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_granted) {
      _checkPermission();
    }
  }

  Future<void> _checkPermission() async {
    final has = await _hasStoragePermission();
    if (mounted) {
      setState(() {
        _granted = has;
        _checking = false;
      });
    }
  }

  Future<void> _onContinuePressed() async {
    await _requestStoragePermission();
    // After the system prompt / settings page, re-check
    await _checkPermission();
  }

  @override
  Widget build(BuildContext context) {
    // Still checking — show nothing (or a brief splash)
    if (_checking) {
      return Scaffold(
        backgroundColor: YageColors.backgroundDark,
        body: Center(
          child: CircularProgressIndicator(color: YageColors.primary),
        ),
      );
    }

    // Permission granted — show the normal home screen
    if (_granted) {
      return const HomeScreen();
    }

    // Permission not granted — show explanation screen
    return _PermissionRequestScreen(
      onContinue: _onContinuePressed,
      onSkip: () {
        // Let user skip and enter the app anyway (limited functionality)
        setState(() => _granted = true);
      },
    );
  }
}

/// Full-screen permission explanation with app branding.
class _PermissionRequestScreen extends StatelessWidget {
  final VoidCallback onContinue;
  final VoidCallback onSkip;

  const _PermissionRequestScreen({
    required this.onContinue,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YageColors.backgroundDark,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              const Spacer(flex: 2),

              // App icon
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [YageColors.primary, YageColors.accent],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: YageColors.primary.withAlpha(100),
                      blurRadius: 24,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    'Y',
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.bold,
                      color: YageColors.backgroundDark,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Title
              Text(
                'Welcome to RetroPal',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: YageColors.textPrimary,
                  letterSpacing: 1,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Your retro gaming companion',
                style: TextStyle(
                  fontSize: 14,
                  color: YageColors.textMuted,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 40),

              // Explanation card
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: YageColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: YageColors.surfaceLight,
                    width: 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.folder_outlined,
                          color: YageColors.accent,
                          size: 22,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Storage Access Required',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: YageColors.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'RetroPal needs access to your files so it can:',
                      style: TextStyle(
                        fontSize: 13,
                        color: YageColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _BulletPoint(
                      icon: Icons.sports_esports,
                      text: 'Load your game ROM files (.gba, .gbc, .gb)',
                    ),
                    const SizedBox(height: 8),
                    _BulletPoint(
                      icon: Icons.save,
                      text: 'Save and restore your game progress',
                    ),
                    const SizedBox(height: 8),
                    _BulletPoint(
                      icon: Icons.image_outlined,
                      text: 'Store cover artwork and screenshots',
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Your files are never uploaded or shared. Everything stays on your device.',
                      style: TextStyle(
                        fontSize: 11,
                        color: YageColors.textMuted,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(flex: 2),

              // Continue button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: onContinue,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: YageColors.primary,
                    foregroundColor: YageColors.textPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 4,
                  ),
                  child: const Text(
                    'Continue',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Skip option
              TextButton(
                onPressed: onSkip,
                child: Text(
                  'Skip for now',
                  style: TextStyle(
                    fontSize: 13,
                    color: YageColors.textMuted,
                  ),
                ),
              ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single bullet-point row used in the permission explanation.
class _BulletPoint extends StatelessWidget {
  final IconData icon;
  final String text;

  const _BulletPoint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: YageColors.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: YageColors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}
