import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'auto/task.dart' show runAutoWatch;
import 'dream/speech_model.dart' show parakeetNotice;
import 'recorder/recorder_service.dart';
import 'sharp/prompts.dart';
import 'ui/auto_hooks.dart';
import 'ui/night_screen.dart';
import 'ui/sharp_rating_screen.dart';
import 'ui/study_screen.dart' show StudyLogScreen;
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort(); // status messages from the recorder isolate
  initRecorderService();
  // AnySleep's weights ship in the APK (assets/models); its MIT licence travels with them.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['AnySleep (sleep model)'], await rootBundle.loadString('assets/models/LICENSE-AnySleep.txt'));
    // the dream catcher's speech to text: Silero's voice detector ships in the APK; the speech model is a download
    yield LicenseEntryWithLineBreaks(['Silero VAD (voice detector)'], await rootBundle.loadString('assets/models/LICENSE-silero-vad.txt'));
    yield const LicenseEntryWithLineBreaks(['Parakeet TDT 0.6B v3 (speech model, downloaded)'], parakeetNotice);
  });
  runApp(const EegTrackerApp());
}

/// The headband watcher's own engine (AutoWatchService.kt, lib/auto/task.dart; DECISIONS 600).
@pragma('vm:entry-point')
Future<void> autoWatchMain() => runAutoWatch();

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
  late final AutoHooks _auto = AutoHooks(_navigator); // the headband watcher (lib/auto, DECISIONS 600)
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    // A tap on a sharp-hours question or a study reminder opens it (DECISIONS rows 283, 401): at a cold start, and while the app runs.
    _sharp.onOpen = () => unawaited(_openQuestion());
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_openQuestion()));
    _auto.install();
  }

  @override
  void dispose() {
    _auto.dispose();
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
        await nav.push(
          MaterialPageRoute<void>(
            builder: (_) => launch.kind.isStudy ? StudyLogScreen(kind: launch.kind, launch: launch) : SharpRatingScreen(launch: launch),
          ),
        );
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
