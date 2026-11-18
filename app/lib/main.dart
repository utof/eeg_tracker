import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'recorder/recorder_service.dart';
import 'ui/night_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort(); // status messages from the recorder isolate
  initRecorderService();
  // AnySleep's weights ship in the APK (assets/models); its MIT licence travels with them.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['AnySleep (sleep model)'], await rootBundle.loadString('assets/models/LICENSE-AnySleep.txt'));
  });
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
