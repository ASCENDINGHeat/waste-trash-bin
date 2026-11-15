import 'package:flutter/material.dart';
import 'screens/dashboard_screen.dart';
import 'services/waste_connection_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final connectionService = WasteConnectionService();
  await connectionService.init();
  runApp(WasteCompanionApp(service: connectionService));
}

class WasteCompanionApp extends StatelessWidget {
  final WasteConnectionService service;

  const WasteCompanionApp({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'W.A.S.T.E. Companion',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.tealAccent,
          brightness: Brightness.dark,
          surface: const Color(0xFF0E1318),
        ),
        scaffoldBackgroundColor: const Color(0xFF090D11),
      ),
      home: DashboardScreen(service: service),
    );
  }
}
