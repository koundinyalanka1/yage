import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/game_library_service.dart';
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

    // ── Run platform init in parallel with provider readiness ──────
    await Future.wait([
      TvDetector.initialize(),
      // Wait for providers that were already started by AppProviders
      _waitForProviders(),
    ]);

    // ── Enforce minimum display time (1.5 s for branding) ─────────
    final elapsed = stopwatch.elapsedMilliseconds;
    const minDisplayMs = 1500;
    if (elapsed < minDisplayMs) {
      await Future.delayed(Duration(milliseconds: minDisplayMs - elapsed));
    }
    if (!mounted) return;

    _goToHome();
  }

  /// Waits for the providers that are already initialising (kicked off in
  /// [AppProviders]) to finish. Uses explicit ready futures instead of polling.
  Future<void> _waitForProviders() async {
    final settings = context.read<SettingsService>();
    final library = context.read<GameLibraryService>();
    final ra = context.read<RetroAchievementsService>();

    await Future.wait([
      settings.whenLoaded,
      library.whenReady,
      ra.whenReady,
    ]);
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
    final colors = AppColorTheme.of(context);
    return Scaffold(
      backgroundColor: colors.backgroundDark,
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
                      color: colors.primary.withAlpha(120),
                      blurRadius: 40,
                      spreadRadius: 4,
                    ),
                    BoxShadow(
                      color: colors.accent.withAlpha(60),
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
                  color: colors.textPrimary,
                  letterSpacing: 4,
                ),
              ),

              const SizedBox(height: 8),

              // ── Tagline ──────────────────────────────────────────
              Text(
                'Classic GB · GBC · GBA · NES · SNES Games',
                style: TextStyle(
                  fontSize: 13,
                  color: colors.textMuted,
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
                  color: colors.primary.withAlpha(180),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
