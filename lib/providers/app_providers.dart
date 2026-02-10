import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/rcheevos_bindings.dart';
import '../services/emulator_service.dart';
import '../services/game_database.dart';
import '../services/game_library_service.dart';
import '../services/link_cable_service.dart';
import '../services/ra_runtime_service.dart';
import '../services/rcheevos_client.dart';
import '../services/retro_achievements_service.dart';
import '../services/settings_service.dart';

/// Provider setup for the application.
///
/// [gameDatabase] must be opened before this widget is built (see main.dart).
class AppProviders extends StatelessWidget {
  final GameDatabase gameDatabase;
  final Widget child;

  const AppProviders({
    super.key,
    required this.gameDatabase,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsService()..load()),
        ChangeNotifierProvider(
          create: (_) => GameLibraryService(gameDatabase)..initialize(),
        ),
        ChangeNotifierProvider(create: (_) => EmulatorService()),
        ChangeNotifierProvider(create: (_) => LinkCableService()),
        ChangeNotifierProvider(create: (_) => RetroAchievementsService()..initialize()),
        // Mode enforcement only — no longer depends on RA service.
        ChangeNotifierProvider(create: (_) => RARuntimeService()),
        // Native rcheevos client — loads bindings eagerly, but
        // initialization (rc_init) happens later when the emulator core
        // is ready.
        ChangeNotifierProvider(create: (_) {
          final bindings = RcheevosBindings()..load();
          return RcheevosClient(bindings);
        }),
      ],
      child: child,
    );
  }
}
