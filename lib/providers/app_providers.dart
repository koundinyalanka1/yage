import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/emulator_service.dart';
import '../services/game_library_service.dart';
import '../services/link_cable_service.dart';
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
      ],
      child: child,
    );
  }
}

