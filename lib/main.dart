import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'providers/app_providers.dart';
import 'screens/home_screen.dart';
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
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
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
      child: MaterialApp(
        title: 'RetroPal',
        debugShowCheckedModeBanner: false,
        theme: YageTheme.darkTheme,
        home: const HomeScreen(),
      ),
    );
  }
}
