// The "Headband connection" page's logic, without widgets: the settings (which connection the app uses), running
// the probe step by step, and the rule for the switch: our own connection is only offered after a passed probe,
// or with an explicit "try anyway" (DECISIONS row 215). BrainBit's SDK stays the default.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../sound/check_in_sound.dart' show CheckInSound;
import 'probe.dart';
import 'settings.dart';
import 'transport.dart';

enum OwnStage { idle, connecting, waitingReady, running }

class OwnBleController extends ChangeNotifier {
  OwnBleController({
    required this.store,
    required this.recordings,
    required this.transport,
    this.sound,
    this.before,
    this.timeScale = 1,
    DateTime Function()? clock,
    DateTime Function()? probeClock,
  }) : _now = clock ?? DateTime.now,
       _probeClock = probeClock; // ignore: prefer_initializing_formals (a private field behind a public name)

  final OwnBleStore store;

  /// `files/recordings`: the address of the headband the SDK recorded with, and a recording to compare with.
  final Directory recordings;
  final BleTransport Function() transport;

  /// The probe's tones (eyes closed, eyes open, next step); null or failing to start: it runs silently.
  final CheckInSound Function()? sound;

  /// Asked before a probe starts: a reason not to (a night records, Bluetooth permission refused) or null.
  final Future<String?> Function()? before;
  final double timeScale;
  final DateTime Function() _now;
  final DateTime Function()? _probeClock;

  OwnBleSettings settings = const OwnBleSettings();
  OwnStage stage = OwnStage.idle;

  /// The step on the page while the probe runs, and when it began.
  ProbeStep? step;
  DateTime? stepStarted;

  /// The last probe's checks, one sentence each: (yes / no / not settled, words).
  List<(bool?, String)> lines = const [];

  /// The last probe asked for pairing.
  bool needsPairing = false;

  /// Why the probe did not start, or another plain note; empty when there is none.
  String message = '';

  /// Options of the next run.
  bool worn = true;
  bool pairFirst = false;

  BandProbe? _probe;
  Completer<void>? _ready;
  CheckInSound? _sound;
  bool _disposed = false;

  bool get busy => stage != OwnStage.idle;

  /// Seconds left of the current step (0 when it has no length).
  double get secondsLeft {
    final s = step, at = stepStarted;
    if (s == null || at == null || s.seconds <= 0) return 0;
    final left = s.seconds - _now().difference(at).inMilliseconds / 1000;
    return left < 0 ? 0 : left / (timeScale <= 0 ? 1 : timeScale);
  }

  /// How far the whole probe is, 0..1.
  double get fraction {
    final s = step, at = stepStarted;
    if (s == null || s.total <= 0) return 0;
    final into = at == null || s.seconds <= 0 ? 0.0 : (_now().difference(at).inMilliseconds / 1000) / s.seconds;
    final planned = s.seconds / (timeScale <= 0 ? 1 : timeScale);
    return ((s.index + planned * into.clamp(0, 1)) / s.total).clamp(0, 1).toDouble();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Reads the settings and the last probe's sentences.
  void load() {
    settings = store.load();
    pairFirst = settings.pair;
    lines = _savedLines(settings.probe);
    _changed();
  }

  List<(bool?, String)> _savedLines(ProbeNote? note) {
    if (note == null) return const [];
    try {
      final f = File('${store.dir.parent.path}/${note.folder}/summary.json');
      final plain = (jsonDecode(f.readAsStringSync()) as Map)['plain'] as Map?;
      needsPairing = plain?['needs_pairing'] == true;
      return [
        for (final l in (plain?['lines'] as List?) ?? const [])
          if (l is String && l.contains(': '))
            (
              switch (l.substring(0, l.indexOf(': '))) {
                'yes' => true,
                'NO' => false,
                _ => null,
              },
              l.substring(l.indexOf(': ') + 2),
            ),
      ];
    } on FileSystemException {
      return const [];
    } on FormatException {
      return const [];
    }
  }

  void setWorn(bool v) {
    if (busy) return;
    worn = v;
    _changed();
  }

  void setPairFirst(bool v) {
    if (busy) return;
    pairFirst = v;
    _changed();
  }

  /// The switch. On needs a passed probe, or [anyway] (the owner's explicit choice). True when it was set.
  bool setUseOwn(bool on, {bool anyway = false}) {
    final now = store.load();
    if (on && !now.probePassed && !anyway) {
      message = 'Run the probe first, or choose "Try anyway".';
      _changed();
      return false;
    }
    settings = OwnBleSettings(
      useOwn: on,
      triedAnyway: on && !now.probePassed,
      signalResist: on && now.signalResist,
      pair: now.pair,
      address: now.address ?? (on ? knownAddress(recordings) : null),
      name: now.name,
      layout: now.layout,
      probe: now.probe,
    );
    store.save(settings);
    message = '';
    _changed();
    return true;
  }

  /// "Measure contact all night": only with our own connection on and a probe that saw command 5 work.
  bool setSignalResist(bool on) {
    final now = store.load();
    if (on && !(now.useOwn && (now.probe?.command5 ?? false))) return false;
    settings = now.copyWith(signalResist: on);
    store.save(settings);
    _changed();
    return true;
  }

  /// Runs the probe to its end (or to Stop) and saves what it found. Returns the result, or null when it did
  /// not start.
  Future<ProbeResult?> runProbe() async {
    if (busy) return null;
    final why = await before?.call();
    if (why != null) {
      message = why;
      _changed();
      return null;
    }
    message = '';
    stage = OwnStage.connecting;
    step = null;
    stepStarted = null;
    _changed();
    final s = store.load();
    try {
      final snd = sound?.call();
      await snd?.start();
      _sound = snd;
    } catch (_) {
      _sound = null; // no audio: the page still shows every step
    }
    final ready = _ready = Completer<void>();
    final probe = _probe = BandProbe(
      transport: transport(),
      folder: store.probeDir,
      address: s.address ?? knownAddress(recordings),
      name: s.name,
      layout: s.layout,
      worn: worn,
      pair: pairFirst,
      onStep: _onStep,
      ready: () => ready.future,
      sdkRef: newestSdkRecording(recordings),
      timeScale: timeScale,
      clock: _probeClock,
    );
    final result = await probe.run();
    _probe = null;
    try {
      await _sound?.stop();
    } catch (_) {}
    _sound = null;
    final v = result.verdict;
    final address = result.summary['address'], name = result.summary['name'];
    final reached = result.summary['service'] != null;
    final was = store.load();
    settings = OwnBleSettings(
      useOwn: was.useOwn,
      triedAnyway: was.triedAnyway && !v.passed,
      signalResist: was.signalResist && v.command5,
      pair: reached && result.summary['error'] == null ? pairFirst : was.pair,
      address: reached && address is String ? address : was.address,
      name: reached && name is String && name.isNotEmpty ? name : was.name,
      layout: v.layout ?? was.layout,
      probe: result.note(),
    );
    store.save(settings);
    lines = v.lines;
    needsPairing = v.needsPairing;
    if (v.needsPairing) pairFirst = true;
    stage = OwnStage.idle;
    step = null;
    stepStarted = null;
    _changed();
    return result;
  }

  void _onStep(ProbeStep s) {
    step = s;
    stepStarted = _now();
    if (s.name == 'ready') {
      stage = OwnStage.waitingReady;
    } else if (s.name != 'done') {
      stage = OwnStage.running;
    }
    try {
      switch (s.cue) {
        case ProbeCue.closeEyes:
          _sound?.close();
        case ProbeCue.openEyes:
          _sound?.open();
        case ProbeCue.next:
          _sound?.end();
        case ProbeCue.none:
          break;
      }
    } catch (_) {}
    _changed();
  }

  /// The owner has the headband on.
  void ready() {
    final r = _ready;
    if (r != null && !r.isCompleted) r.complete();
  }

  /// Ends the probe at once; what it has so far is still saved.
  void stopProbe() => _probe?.cancel();

  @override
  void dispose() {
    _disposed = true;
    _probe?.cancel();
    super.dispose();
  }
}
