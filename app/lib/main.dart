import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'auto/task.dart' show runAutoWatch;
import 'dream/speech_model.dart' show parakeetNotice;
import 'logs/engine.dart' show ScreenRecords;
import 'logs/usage.dart' show Usage;
import 'logs/usage_watch.dart' show UsageGestures, UsageNavigatorObserver;
import 'phone.dart' show Phone;
import 'recorder/recorder_service.dart';
import 'share/push/task.dart' show runPushTask;
import 'sharp/prompts.dart';
import 'ui/auto_hooks.dart';
import 'ui/night_screen.dart';
import 'ui/sharp_rating_screen.dart';
import 'ui/study_screen.dart' show StudyLogScreen;
import 'ui/theme.dart';

void main() {
  final started = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();
  // the app's own log, usage and battery samples in files/logs/ (lib/logs, DECISIONS 710-719)
  ScreenRecords.start(recordingsDir: Phone.recordingsDir, power: Phone.powerMap, mainStarted: started, processAgeMs: Phone.processAge);
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

/// The push's own engine (PushJob.kt, lib/share/push/task.dart; DECISIONS 840-849).
@pragma('vm:entry-point')
Future<void> pushMain() => runPushTask();

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

  /// The home page is named by its tab (`tab:Signal`).
  final UsageNavigatorObserver _usage = UsageNavigatorObserver(
    rename: (name) => name == 'NightScreen' ? 'tab:${Usage.homeTab}' : name,
  );

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
    // the usage log (DECISIONS 713): the page on top, and taps, drags and scrolls of the app's own screens
    navigatorObservers: [_usage],
    builder: (context, child) => UsageGestures(child: child ?? const SizedBox.shrink()),
    home: const NightScreen(),
  );
}
