import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'recorder/recorder_service.dart';
import 'ui/night_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort(); // status messages from the recorder isolate
  initRecorderService();
  runApp(const EegTrackerApp());
}

class EegTrackerApp extends StatelessWidget {
  const EegTrackerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'EEG Tracker',
    debugShowCheckedModeBanner: false,
    theme: nightTheme(),
    home: const NightScreen(),
  );
}
