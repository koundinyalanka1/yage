import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/game_library_service.dart';
import '../services/notification_service.dart';
import '../services/retro_achievements_service.dart';
import '../services/settings_service.dart';
import '../utils/theme.dart';
import '../utils/tv_detector.dart';
import 'home_screen.dart';

/// Splash screen shown at app startup.
///
/// Responsibilities:
///   1. Display branding (logo + app name) immediately.
///   2. Run initialisation tasks in parallel:
///      • Detect Android TV
///      • Initialize notification service & request permission
///   3. Wait for providers that were already kicked off by [AppProviders]:
///      • [SettingsService.load]
///      • [GameLibraryService.initialize]
///      • [RetroAchievementsService.initialize]
///   4. Navigate to [HomeScreen] once everything is ready.
///
/// A minimum display time of 1.5 s ensures the logo is seen even when
/// everything loads instantly (cached data on subsequent launches).
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  bool _navigated = false;

  @override
  void initState() {
    super.initState();

    // Fade-in animation for the logo / text
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _fadeController.forward();

    // Kick off async init after the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    final stopwatch = Stopwatch()..start();

    // ── Run platform + permission init in parallel ─────────────────
    await Future.wait([
      TvDetector.initialize(),
      NotificationService().initialize(),
      // Wait for providers that were already started by AppProviders
      _waitForProviders(),
    ]);

    // ── Enforce minimum display time (1.5 s for branding) ─────────
    final elapsed = stopwatch.elapsedMilliseconds;
    const minDisplayMs = 1500;
    if (elapsed < minDisplayMs) {
      await Future.delayed(Duration(milliseconds: minDisplayMs - elapsed));
    }

    _goToHome();
  }

  /// Polls the providers that are already initialising (kicked off in
  /// [AppProviders]) and returns when they are all ready.
  ///
  /// Uses a simple polling loop with a short sleep rather than adding
  /// listeners, because the providers usually finish within a few hundred
  /// milliseconds and this keeps the code straightforward.
  Future<void> _waitForProviders() async {
    final settings = context.read<SettingsService>();
    final library = context.read<GameLibraryService>();
    final ra = context.read<RetroAchievementsService>();

    // Poll until all three are done (typically < 500 ms)
    while (true) {
      final settingsReady = settings.isLoaded;
      final libraryReady = !library.isLoading;
      final raReady = !ra.isLoading;

      if (settingsReady && libraryReady && raReady) break;
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  void _goToHome() {
    if (_navigated || !mounted) return;
    _navigated = true;

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, a1, a2) => const HomeScreen(),
        transitionsBuilder: (_, animation, a3, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  // ═════════════════════════════════════════════════════════════════════
  //  UI
  // ═════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YageColors.backgroundDark,
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Glowing app icon ─────────────────────────────────
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(32),
                  boxShadow: [
                    BoxShadow(
                      color: YageColors.primary.withAlpha(120),
                      blurRadius: 40,
                      spreadRadius: 4,
                    ),
                    BoxShadow(
                      color: YageColors.accent.withAlpha(60),
                      blurRadius: 60,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(32),
                  child: Image.asset(
                    'assets/images/app_icon.png',
                    width: 120,
                    height: 120,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),

              const SizedBox(height: 28),

              // ── App name ─────────────────────────────────────────
              Text(
                'RetroPal',
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  color: YageColors.textPrimary,
                  letterSpacing: 4,
                ),
              ),

              const SizedBox(height: 8),

              // ── Tagline ──────────────────────────────────────────
              Text(
                'Classic GB · GBC · GBA Games',
                style: TextStyle(
                  fontSize: 13,
                  color: YageColors.textMuted,
                  letterSpacing: 1.5,
                ),
              ),

              const SizedBox(height: 48),

              // ── Subtle loading indicator ─────────────────────────
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: YageColors.primary.withAlpha(180),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
