import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'providers/app_providers.dart';
import 'screens/home_screen.dart';
import 'services/settings_service.dart';
import 'utils/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
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
            home: const HomeScreen(),
          );
        },
      ),
    );
  }
}
