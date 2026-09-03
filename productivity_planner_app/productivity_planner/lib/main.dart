import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'controllers/queue_controller.dart';
import 'controllers/task_controller.dart';
import 'controllers/settings_controller.dart';
import 'database/auto_backup_service.dart';
import 'database/database_helper.dart';
import '/pages/home_page.dart';
import 'pages/queues_page.dart';
import 'pages/settings_page.dart';

/// Starts the app after making sure Flutter and the local database are ready.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseHelper().init();
  // Snapshot on launch as well as on exit, so an unclean shutdown still leaves
  // a recent backup behind.
  await AutoBackupService().run();
  runApp(const MyApp());
}

/// Root widget for the Productivity Planner app.
///
/// Sets up the app-wide controllers and applies user settings such as theme,
/// colors, and font size.
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

/// Holds the app-wide state and writes a backup when the app is closing.
class _MyAppState extends State<MyApp> {
  /// Watches for the window close request so data can be snapshotted first.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await AutoBackupService().run();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => QueueController()),
        ChangeNotifierProvider(create: (_) => TaskController()),
        ChangeNotifierProvider(create: (_) => SettingsController()),
      ],
      child: Consumer<SettingsController>(
        builder: (context, settings, _) {
          return MaterialApp(
  debugShowCheckedModeBanner: false,
  title: 'Productivity Planner',
  theme: ThemeData(
    brightness: settings.isDarkMode ? Brightness.dark : Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: settings.primaryColor,
      brightness: settings.isDarkMode ? Brightness.dark : Brightness.light,
      background: settings.backgroundColor,
    ),
    scaffoldBackgroundColor: settings.backgroundColor,
    cardColor: settings.backgroundColor,
    cardTheme: CardThemeData(
      color: settings.backgroundColor,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: settings.backgroundColor,
    ),
    textTheme: ThemeData(
      brightness: settings.isDarkMode ? Brightness.dark : Brightness.light,
    ).textTheme.apply(
      bodyColor: settings.textColor,
      displayColor: settings.textColor,
      decorationColor: settings.textColor,
    ),
    iconTheme: IconThemeData(color: settings.textColor),
  ),
  builder: (context, child) {
    // Apply the global font-size setting to all text.
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(
        textScaler: TextScaler.linear(settings.fontScale),
      ),
      child: child!,
    );
  },
  home: const MyHomePage(title: 'Productivity Planner'),
);
        },
      ),
    );
  }
}

/// Pages available from the bottom navigation bar.
enum AppPage { home, queues, settings }

/// Main navigation shell for the app.
///
/// Displays the app bar, selected page content, and bottom navigation bar.
class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  /// Title shown in the app bar.
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

/// Tracks the selected bottom navigation page.
class _MyHomePageState extends State<MyHomePage> {
  AppPage currentPage = AppPage.home;

  /// Forces the Home page to rebuild when the Home tab is selected again.
  ///
  /// This keeps task counts and lists up to date after changes made on other pages.
  int _homeRefreshKey = 0;

  @override
  Widget build(BuildContext context) {
    Widget body;
    switch (currentPage) {
      case AppPage.home:
        body = HomePage(key: ValueKey('home_$_homeRefreshKey'));
        break;
      case AppPage.queues:
        body = const QueuesPage();
        break;
      case AppPage.settings:
        body = const SettingsPage();
        break;
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
        centerTitle: true,
      ),
      body: body,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: AppPage.values.indexOf(currentPage),
        onTap: (index) {
          setState(() {
            final selected = AppPage.values[index];
            // Re-enter Home fresh so its counts and lists are always current.
            if (selected == AppPage.home) _homeRefreshKey++;
            currentPage = selected;
          });
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.list), label: 'Queues'),
          BottomNavigationBarItem(
              icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}