import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'recorder/recorder_service.dart';
import 'sharp/prompts.dart';
import 'ui/night_screen.dart';
import 'ui/sharp_rating_screen.dart';
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

class EegTrackerApp extends StatefulWidget {
  const EegTrackerApp({super.key, this.sharp});

  /// The sharp-hours questions' channel (a fake in tests).
  final SharpPhone? sharp;

  @override
  State<EegTrackerApp> createState() => _EegTrackerAppState();
}

class _EegTrackerAppState extends State<EegTrackerApp> {
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();
  late final SharpPhone _sharp = widget.sharp ?? ChannelSharpPhone();
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    // A tap on a sharp-hours question opens it (DECISIONS row 283): at a cold start, and while the app runs.
    _sharp.onOpen = () => unawaited(_openQuestion());
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_openQuestion()));
  }

  @override
  void dispose() {
    _sharp.onOpen = null;
    super.dispose();
  }

  Future<void> _openQuestion() async {
    if (_asking) return;
    _asking = true;
    try {
      final launch = await _sharp.takeLaunch();
      final nav = _navigator.currentState;
      if (launch != null && nav != null) {
        await nav.push(MaterialPageRoute<void>(builder: (_) => SharpRatingScreen(launch: launch)));
      }
    } catch (_) {
      // no channel (tests, a desktop harness): nothing to open
    } finally {
      _asking = false;
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'EEG Tracker',
    navigatorKey: _navigator,
    debugShowCheckedModeBanner: false,
    theme: nightTheme(),
    home: const NightScreen(),
  );
}
