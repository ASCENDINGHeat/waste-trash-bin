import 'package:google_fonts/google_fonts.dart';

import 'lib.dart';

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
      title: 'W.A.S.T.E.',
      debugShowCheckedModeBanner: true, //! change it in the release app
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
          textTheme: GoogleFonts.poppinsTextTheme(
            ThemeData(brightness: Brightness.dark).textTheme,
          )),
      home: MainShell(service: service),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.service});

  final WasteConnectionService service;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(
          "Dashboard",
          style: TextStyle(
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
            fontSize: 20,
          ),
        ),
        actions: [
          IconButton(
            tooltip: "Notifications",
            icon: const Icon(Icons.notifications),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => NotificationPage(service: widget.service))),
          ),
          IconButton(
            tooltip: "Settings",
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsPage())),
          )
        ],
      ),
      body: MainPage(service: widget.service),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddDeviceSheet,
        tooltip: "Add Device",
        child: const Icon(Icons.add),
      ),
    );
  }

  void _showAddDeviceSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: false,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: EdgeInsets.all(96),
        child: const Text(
          "Add New Device",
          style: TextStyle(fontSize: 24),
        ),
      ),
    );
  }
}
