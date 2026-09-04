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
  // Check for newer data from another computer BEFORE writing anything. A
  // launch snapshot taken first would be the newest file in the shared folder
  // and would bury the very snapshot being offered.
  final incoming = await AutoBackupService().findIncoming();
  if (incoming == null) {
    // Nothing to load, so snapshot on launch as well as on exit; an unclean
    // shutdown then still leaves a recent backup behind.
    await AutoBackupService().run();
  }
  runApp(MyApp(incoming: incoming));
}

/// Root widget for the Productivity Planner app.
///
/// Sets up the app-wide controllers and applies user settings such as theme,
/// colors, and font size.
class MyApp extends StatefulWidget {
  const MyApp({super.key, this.incoming});

  /// Newer data found from another computer, offered once at startup.
  final IncomingSnapshot? incoming;

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
  home: MyHomePage(
    title: 'Productivity Planner',
    incoming: widget.incoming,
  ),
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
  const MyHomePage({super.key, required this.title, this.incoming});

  /// Title shown in the app bar.
  final String title;

  /// Newer data from another computer, offered once after the first frame.
  final IncomingSnapshot? incoming;

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
  void initState() {
    super.initState();
    final incoming = widget.incoming;
    if (incoming != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _offerIncoming(incoming),
      );
    }
  }

  /// Asks whether to replace this computer's data with a newer snapshot from
  /// another one.
  ///
  /// Replacing the whole database is destructive and cannot be merged, so it
  /// is always confirmed. This computer's current data is snapshotted either
  /// way, which both preserves it before an import and records the decision so
  /// the same file is not offered again.
  Future<void> _offerIncoming(IncomingSnapshot incoming) async {
    final load = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Newer data available'),
        content: Text(
          'A backup from ${incoming.machine} (${incoming.whenLabel}) has '
          '${incoming.queueCount} queues and ${incoming.taskCount} tasks.\n\n'
          'Loading it replaces everything on this computer. A backup of what '
          'is here now is saved first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep this computer\'s'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Load'),
          ),
        ],
      ),
    );

    // Save this computer's current state before touching anything.
    await AutoBackupService().run();
    if (load != true) return;

    try {
      await DatabaseHelper().importData(incoming.data);
      if (!mounted) return;
      context.read<QueueController>().loadQueues();
      setState(() => _homeRefreshKey++);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Loaded data from ${incoming.machine}.')),
      );
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load that backup: $e')),
      );
    }
  }

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