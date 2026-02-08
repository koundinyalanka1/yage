import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/emulator_service.dart';
import '../services/game_library_service.dart';
import '../services/link_cable_service.dart';
import '../services/ra_runtime_service.dart';
import '../services/retro_achievements_service.dart';
import '../services/settings_service.dart';

/// Provider setup for the application
class AppProviders extends StatelessWidget {
  final Widget child;

  const AppProviders({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsService()..load()),
        ChangeNotifierProvider(create: (_) => GameLibraryService()..initialize()),
        ChangeNotifierProvider(create: (_) => EmulatorService()),
        ChangeNotifierProvider(create: (_) => LinkCableService()),
        ChangeNotifierProvider(create: (_) => RetroAchievementsService()..initialize()),
      ],
      // RARuntimeService depends on RetroAchievementsService, so it sits
      // in a nested provider that can read the RA service from context.
      child: Consumer<RetroAchievementsService>(
        builder: (context, raService, _) {
          return ChangeNotifierProvider(
            create: (_) => RARuntimeService(raService),
            child: child,
          );
        },
      ),
    );
  }
}

