// The night loop, ported from scripts/record_night.py with its lessons (DECISIONS row 17 and rows 49-52):
// - contact check at the start of the night;
// - a stalled stream is restarted; 40 s without data ends the run;
// - never an SDK call on a headband that is out of range (on the laptop that segfaulted the SDK); the
//   one call made on a sensor that may be out of range is the state read, as on the laptop;
// - after a drop: a new sensor object and a new file set (to_bdf.py joins a night's sets by time), like
//   the laptop's fresh process. The phone reaches the same headband directly by its address, because
//   Android stops unfiltered scans while the screen is off; growing waits, every third try a scan
//   (row 49). Each drop and try goes into the .log with its time;
// - every SDK call has a deadline; one that blocks means the SDK is wedged, so the data is saved and the
//   app process is restarted (the phone's version of "exit and let record_night.sh start a fresh one");
// - the data is saved before every risky SDK call;
// - the drift-off detector runs on the batches in this isolate (live_drift.dart, DECISIONS 180-184), always behind the
//   files and inside a guard: an exception, or more than its share of time, switches it off with one log line;
// - so do the smart alarm (alarm/live_alarm.dart, DECISIONS 230-236: only from an hour before its window; the phone's
//   own alarm at the window's end never depends on it) and tonight's sound cues, one kind a night (the lucid dream
//   cues, lucid/live_cues.dart, DECISIONS 300-303, or the memory cues, memory_cues/live_cues.dart, DECISIONS 500-509;
//   the engine both use is cues/night_cues.dart), with the one live sleep model they share (sleep/night_scorer.dart,
//   DECISIONS 330): one guard with a memory limit too covers all three; an exception in the alarm or the cues costs
//   only that one;
// - a board that is not a BrainBit (the DIY board, recorder/headband.dart `OtherBoard`) gets no contact check and no
//   battery lines, and its samples never reach the drift-off detector, the smart alarm, the cues or the live sleep
//   model they share: they read O1 O2 T3 T4.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../alarm/live_alarm.dart';
import '../alarm/rule.dart';
import '../cues/night_cues.dart';
import '../headband/battery_estimate.dart';
import '../headband/lend.dart' show LentBand;
import '../headband/reconnect_ladder.dart';
import '../logs/log.dart' show AppLog;
import '../logs/metrics.dart' show Metrics;
import '../signal/quality.dart' show QualityJudge, SecondMaker;
import '../sleep/night_scorer.dart';
import 'battery.dart';
import 'chunk_writer.dart';
import 'contact.dart';
import 'header.dart';
import 'headband.dart';
import '../spans/after_restart.dart' show endedWithoutStop;
import '../spans/span.dart';
import '../spans/span_log.dart';
import 'live_drift.dart';
import 'nights.dart';
import 'packets.dart';
import 'phone_steps.dart';
import 'status.dart';
import 'watch_guard.dart';

class RecorderTiming {
  const RecorderTiming({
    this.tick = const Duration(seconds: 1),
    this.ticksPerCheck = 10,
    this.spansAway = const Duration(minutes: 60),
    this.stopAway = const Duration(hours: 6),
    this.scanFor = const Duration(seconds: 30),
    this.contactFor = const Duration(seconds: 6),
    this.settle = const Duration(seconds: 1),
    this.retryWait = const Duration(seconds: 3),
    this.sdkTimeout = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 60),
    this.notFoundWait = const Duration(seconds: 10),
    this.notFoundWaitLong = const Duration(seconds: 60),
    this.stallChecksToGiveUp = 4,
    this.startAttempts = 10,
    this.stopTimeout = const Duration(seconds: 20),
    this.reconnectWaits = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 30),
      Duration(seconds: 60),
    ],
    this.scanEvery = 3,
    this.rescanFor = const Duration(seconds: 15),
    this.ladder = const LadderTiming(),
    this.awayCheckEvery = const Duration(minutes: 1),
    this.phoneLogEvery = const Duration(minutes: 1),
    this.packetLogEvery = const Duration(minutes: 10),
    this.driftBudget = 0.02,
    this.driftBudgetAfter = const Duration(minutes: 10),
    this.rollAfter = const Duration(hours: 4),
    this.rollBytes = 128 * 1024 * 1024,
    this.rollRetry = const Duration(minutes: 5),
  });

  /// A file set open this long, or whose `.f32` holds this many bytes, is closed and the recording goes on in a new
  /// one on the same connection, without a gap (DECISIONS 1035): a recording that never drops would otherwise be one
  /// file that grows for days, which the laptop can never check and the phone can never clear. Four hours is 18 MB an
  /// hour x 4 = 72 MB for the BrainBit; the size limit is for a board with more channels or a higher rate.
  final Duration rollAfter;
  final int rollBytes;

  /// After a roll-over that could not be done (the next set's files could not be made), the next try comes this much
  /// later; the open set goes on meanwhile.
  final Duration rollRetry;

  /// Buffered samples go to the files and a status goes to the screen this often.
  final Duration tick;

  /// Every this many ticks (10 s): fsync, sample count in the log, range and stall check.
  final int ticksPerCheck;

  /// The headband lost this long: open spans are closed at the last data, and later the recording stops itself
  /// (planning values, DECISIONS 899).
  final Duration spansAway, stopAway;
  final Duration scanFor;
  final Duration contactFor;
  final Duration settle;
  final Duration retryWait;

  /// Deadline for one SDK command; past it the SDK is taken to be wedged.
  final Duration sdkTimeout;

  /// Deadline for creating the sensor (which connects), on top of [scanFor].
  final Duration connectTimeout;
  final Duration notFoundWait;

  /// After 6 scans in a row without a headband, wait this long between scans (saves battery).
  final Duration notFoundWaitLong;

  /// Checks in a row without data before the run is given up (4 x 10 s = 40 s, as on the laptop).
  final int stallChecksToGiveUp;
  final int startAttempts;
  final Duration stopTimeout;

  /// Wait before each reconnect try after a drop; the last one repeats until the ladder's stage C
  /// ([LadderTiming.waitAfter] without the headband; headband/reconnect_ladder.dart, DECISIONS 940).
  final List<Duration> reconnectWaits;

  /// The reconnect ladder's own times: when the waiting begins, the safety try, the fallback.
  final LadderTiming ladder;

  /// While the ladder waits for its next step (up to 15 minutes in stage C), the long-loss rules ([spansAway],
  /// [stopAway]) are looked at this often; between tries the loop looks at them itself (DECISIONS 1073).
  final Duration awayCheckEvery;

  /// Every this many-th reconnect try is a scan instead of a direct connection (3: direct, direct, scan).
  final int scanEvery;

  /// Scan length of a reconnect try (well under Android's 5 scan starts per 30 s).
  final Duration rescanFor;

  /// The phone battery line goes into the `.log` this often (the check that finds it due runs every 10 s).
  final Duration phoneLogEvery;

  /// The packet accounting line goes into the `.log` this often (and at the end of every run and night).
  final Duration packetLogEvery;

  /// The drift-off detector is switched off once it has taken more than this share of the time since it started,
  /// checked from [driftBudgetAfter] on (on the laptop it takes about 0.03 %).
  final double driftBudget;
  final Duration driftBudgetAfter;
}

/// An SDK call passed its deadline. Never swallowed by the ordinary error handling.
/// The sleep kit of one sleep span: the live sleep model and what listens to it.
typedef SleepKit = ({NightScorer? scorer, AlarmWatch Function(AlarmPlan plan)? alarm, CueFactory? cues});

class SdkStuck implements Exception {
  SdkStuck(this.what, this.after);
  final String what;
  final Duration after;

  @override
  String toString() => 'SDK call "$what" stuck for ${after.inSeconds} s';
}

enum _End { stopped, lost, stalled, failed, stuck }

/// The recorder's lines in the app log (lib/logs, DECISIONS 718): drops, reconnects and their times, the notes.
final AppLog _log = AppLog('recorder');

/// The one switch for "the rest of the night" (DECISIONS 1015): when the 60-minute rule has ended a Sleep stretch and
/// the headband's samples come back before Stop, the recorder opens a new sleep stretch by itself from the first new
/// sample (source `auto_resume`: the app's guess, shown as such, with Undo). False: it stays ended until the owner
/// taps Undo or Sleep.
const bool resumeSleepWhenBack = true;

class NightRecorder {
  NightRecorder({
    required this.finder,
    required this.dir,
    required this.store,
    required this.onStatus,
    required this.onStuck,
    this.probe,
    StepProbe? stepProbe,
    this.timing = const RecorderTiming(),
    this.watch = LiveDrift.new,
    this.scorer,
    this.alarmPlan,
    this.alarm,
    this.cues,
    this.liveLimits = const GuardLimits(),
    this.startNotes = const [],
    this.spanLog,
    this.kit,
    this.onGiveUp,
    this.onSpansEnded,
    this.onSleepResumed,
    this.resumeSleep = resumeSleepWhenBack,
    this.sleep = true,
    this.firstSpan,
    this.sleepSource = 'owner_button',
    this.bandBattery,
    this.screenOn,
    ChunkWriter Function(Directory dir, DateTime start, {RecordingHeader? header, bool inRecording, String? recording})? openSet,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now,
       _openSet = openSet ?? ChunkWriter.open,
       _steps = stepProbe == null ? null : StepLog(stepProbe, clock ?? DateTime.now);

  /// Whether the phone's screen is on (the ladder's fallback tries more often then); null: taken as off.
  final Future<bool> Function()? screenOn;

  /// The reconnect ladder (headband/reconnect_ladder.dart): it waits and names each try; the tries are made here.
  late final ReconnectLadder _ladder = ReconnectLadder(
    waits: timing.reconnectWaits,
    scanEvery: timing.scanEvery,
    timing: timing.ladder,
    waitFor: _waitFor,
    screenOn: screenOn,
    log: _note,
    clock: _now,
  );

  /// A reason to try for a lost headband right now (the app opened, the phone unlocked, Bluetooth on, "Reconnect
  /// now"). Nothing happens while the headband is there.
  void hint(ReconnectHint h) => _ladder.hint(h);

  /// The stage of the ladder while a headband is being got back; null otherwise.
  LadderStage? get ladderStage => _ladder.active ? _ladder.stage : null;

  /// A waiting connect, where the connection in use has one and direct connections are not off for tonight.
  Future<WaitingConnect?> _waitFor(BandId id) async {
    final f = finder;
    if (_night.directOff || f is! WaitingFinder) return null;
    return (f as WaitingFinder).waitFor(id);
  }

  /// The headband's battery track shared with the screens (headband/battery_estimate.dart): every gauge reading goes
  /// in. Null: none kept.
  final BandBatteryStore? bandBattery;

  /// Opens a file set ([ChunkWriter.open]; tests: storage that is full, a kill at that moment).
  final ChunkWriter Function(Directory dir, DateTime start, {RecordingHeader? header, bool inRecording, String? recording}) _openSet;

  /// The one judge of electrode quality (signal/quality.dart) over this run's signal, for the screens' status.
  QualityJudge? _judge;
  SecondMaker? _seconds;

  final HeadbandFinder finder;
  final Directory dir;

  /// The spans files' writer (`files/spans/`); null: the spans are kept in the saved state only (tests of the rest).
  final SpanLog? spanLog;

  /// A new recording starts with Sleep: a sleep span from its start (it started the recording) and the sleep kit on.
  /// False: Record alone, no span, no kit (Record first, DECISIONS 880-881).
  final bool sleep;

  /// A new recording that does not start with Sleep starts with this span (an activity pressed while nothing
  /// recorded: `work`, `meditate`, ...); like Sleep's, it remembers that it started the recording. Null: none.
  final String? firstSpan;

  /// Who started that first span: `owner_button`, or `auto_start` for the headband watcher.
  final String sleepSource;
  final NightStore store;
  final void Function(RecorderStatus status) onStatus;

  /// Called after the data is saved when an SDK call is stuck: restart the app process.
  final Future<void> Function(String reason) onStuck;
  final PhoneProbe? probe;

  /// The phone's step counter, once a minute into the `.log` (lib/recorder/phone_steps.dart); null: none,
  /// nothing logged.
  final StepLog? _steps;
  final RecorderTiming timing;

  /// Makes the live drift-off detector; null: none.
  final DriftWatch Function()? watch;

  /// Tonight's smart alarm, for a new night (a restarted one keeps the plan saved with it); null: none.
  final AlarmPlan? alarmPlan;

  /// Makes the smart alarm's live model for a plan, an hour before its window; null: none (the phone's alarm alone).
  AlarmWatch Function(AlarmPlan plan)? alarm;

  /// Lines for the night's log at its start (and again after a restart by Android): which headband, what is off.
  final List<String> startNotes;

  /// Makes tonight's sound cues for the night's start (the lucid or the memory cues, one kind a night; null from it:
  /// they are off); null: none.
  CueFactory? cues;

  /// The night's one live sleep model, which the smart alarm and the lucid cues made by [alarm] and [cues] listen to
  /// (DECISIONS 330); the recorder feeds it. Null: none (an alarm or cues with a model of their own feed it).
  NightScorer? scorer;

  /// Makes a fresh sleep kit (the live sleep model, the alarm and the cues that listen to it) for a sleep span
  /// started on the running recording: a closed model is not started again. Null: the ones given at the start are
  /// used again (tests).
  final SleepKit Function()? kit;

  /// The recording gave up after [RecorderTiming.stopAway] without any data: the service stops it.
  final void Function()? onGiveUp;

  /// The 60-minute rule ended these spans (the service tells the owner: "Still going? Undo").
  final void Function(List<Span> ended)? onSpansEnded;

  /// The recorder opened a sleep stretch by itself when the headband came back ([resumeSleepWhenBack]); the service
  /// tells the owner.
  final void Function(Span resumed)? onSleepResumed;

  /// [resumeSleepWhenBack], or a test's own choice.
  final bool resumeSleep;

  /// The one guard over the smart alarm, the lucid cues and [scorer]: an exception in the scorer, more than its share
  /// of this isolate's time (the model's own thread and the scaling isolate are not counted: they do not hold the
  /// recorder up) or the app growing by more than its limit since the guard started switches all of them off for the
  /// rest of the process with one log line (the phone's alarm still rings at the window's end).
  final GuardLimits liveLimits;
  late final WatchGuard<_LiveSleep> _live = WatchGuard(limits: liveLimits, onStop: _liveStopped);

  /// Tonight's sound cues while they run.
  CueWatch? _cueWatch;

  /// The guard switched the live sleep model off: nothing starts it again in this process.
  bool _liveOff = false;

  /// Who ran under the guard tonight (for the night's cost line).
  final Set<String> _liveWho = {};
  final DateTime Function() _now;

  RecorderStatus _status = const RecorderStatus();
  NightState _night = const NightState();
  final Completer<void> _stopSignal = Completer<void>();
  final Completer<void> _done = Completer<void>();
  bool _endNight = true;
  ChunkWriter? _writer;

  /// The open set when it goes on from the one before on the same connection ([_rollOver]): its first batch is no new
  /// file to anything that listens (no gap came before it).
  ChunkWriter? _continues;

  /// The run whose samples are already in the night's count ([_count]); a save does not add them again.
  ChunkWriter? _counted;
  int _misses = 0;

  /// Log lines waiting for the next run's `.log` (no closed run of tonight to put them in), with their times.
  List<(DateTime, String)> _notes = const [];

  /// The `.log` of the last closed run: drops and reconnect tries between runs go there.
  File? _lastLog;

  /// The drop being recovered from, and how the headband came back.
  ({int? lastDataMs, String? stem, String why})? _drop;
  ({String how, int tryNo, String by})? _via;

  /// When the phone battery line was last written (unix ms).
  int _batteryLoggedMs = 0;

  /// Packet numbers of tonight; [_packetsLoggedMs] is when its line was last written (unix ms).
  PacketAccount _packets = PacketAccount();
  int _packetsLoggedMs = 0;

  /// Samples received per half hour of clock time (the screen's night strip).
  final Map<int, int> _slots = {};

  /// Headbands dropped while out of range. Kept, never touched again (no SDK call on a lost sensor).
  final List<Headband> abandoned = [];

  /// The live drift-off detector; null while off. [_driftTime] is the time spent in it, [_driftWall] the time since
  /// it started (for its budget), [_driftUsed] whether it ran tonight (for the night's cost line).
  DriftWatch? _drift;
  final Stopwatch _driftTime = Stopwatch(), _driftWall = Stopwatch();
  int _driftSamples = 0;
  bool _driftUsed = false;

  /// Markers given before tonight's first file set opened, with their times.
  List<(DateTime, String)> _pendingMarkers = const [];

  /// [run] has loaded or begun the night. Lights off and Alarm off that come before (the service hands over what came
  /// in the first moments of a start) are kept here and applied then, so the new night cannot overwrite them.
  bool _begun = false;
  DateTime? _earlyLightsOff;
  bool _earlyAlarmOff = false;

  /// The smart alarm while its live model runs; [_alarmLast] what it showed when it finished.
  AlarmWatch? _alarm;
  bool _alarmMade = false;
  AlarmLive? _alarmLast;

  /// A board that is not a BrainBit was connected tonight: no detector, no alarm model, no lucid cues and no shared
  /// sleep model from then on.
  bool _noDetectors = false;

  RecorderStatus get status => _status;
  bool get _stopping => _stopSignal.isCompleted;
  Future<void> get done => _done.future;

  /// [run] has returned: no session is using a headband any more.
  bool get finished => _done.isCompleted;

  /// A text marker from a laptop page (Share on Wi-Fi's POST /marker), as the laptop recorder writes it: one
  /// line `{"t", "i", "text"}` in the run's `.markers.jsonl`, `i` the index of the next sample. Null while no run
  /// is open or when the line could not be written; never throws.
  ({double t, int i})? addMarker(String text) {
    final w = _writer;
    if (w == null || w.isClosed) return null;
    try {
      final t = (unixSeconds(_now()) * 1000).roundToDouble() / 1000;
      final i = w.samplesReceived;
      File('${dir.path}/${w.stem}.markers.jsonl').writeAsStringSync(
        '${jsonEncode({'t': t, 'i': i, 'text': text})}\n',
        mode: FileMode.append,
        flush: true,
      );
      return (t: t, i: i);
    } catch (_) {
      return null;
    }
  }

  /// Records until [stop]. [restartedBySystem]: Android restarted the service after the process died,
  /// so an active night is continued (new file set) instead of a new night begun.
  Future<void> run({required bool restartedBySystem}) async {
    try {
      if (!await _begin(restartedBySystem)) return;
      await _loop();
      if (_stopping && _endNight) {
        _closeSpansAtStop();
        // no file set ever opened: the spans are still a true statement about the time, kept under the start's stamp
        if (_night.recording == null && _spans.isNotEmpty) {
          _bindRecording(fileStem(DateTime.fromMillisecondsSinceEpoch(_night.startMs)));
        }
        await _logNightEnd();
      }
    } finally {
      await _steps?.stop();
      _set(_status.copyWith(phase: Phase.idle));
      if (!_done.isCompleted) _done.complete();
    }
  }

  /// Ends the run cleanly. [endNight] false (the system is destroying the service) keeps the night
  /// marked active so a restarted service continues it.
  Future<void> stop({bool endNight = true}) async {
    _endNight = endNight;
    if (!_stopSignal.isCompleted) _stopSignal.complete();
    _set(_status.copyWith(phase: Phase.stopping, note: 'stopping'));
    final a = _alarm;
    _alarm = null;
    if (a != null) {
      // stopped before the model finished: a restart may start it again (the plan stays)
      _alarmLast = a.live;
      _night = _night.copyWith(alarmScoring: false);
      await _closeAlarm(a).timeout(const Duration(seconds: 5), onTimeout: () {});
    }
    final c = _cueWatch;
    _cueWatch = null;
    if (c != null) await _closeCues(c).timeout(const Duration(seconds: 5), onTimeout: () {});
    _live.release();
    await _closeScorer().timeout(const Duration(seconds: 5), onTimeout: () {});
    await _done.future.timeout(timing.stopTimeout, onTimeout: () {});
    final w = _writer;
    if (w != null && !w.isClosed) {
      // the run did not end in time (an SDK call still blocks): its files are closed here, and counted
      w.close();
      _count(w);
    }
    await _save();
  }

  /// Android started the service by itself and the saved state holds no recording to continue: [run] began none
  /// (a start by the system never begins a recording: the last start's choice, Sleep for one, is not a new press).
  bool nothingToContinue = false;

  /// False: nothing to record ([nothingToContinue]).
  Future<bool> _begin(bool restartedBySystem) async {
    NightState prior;
    try {
      prior = await store.load();
    } catch (_) {
      prior = const NightState(); // nothing to continue: a new night
    }
    if (restartedBySystem && !prior.active) {
      _log.info('started by Android with no recording to continue: none begins');
      nothingToContinue = true;
      _night = prior;
      return false;
    }
    if (prior.active && !restartedBySystem) _endLeftActive(prior);
    if (restartedBySystem && prior.active) {
      _night = prior;
      _slots.addAll(prior.slots);
      final notes = [
        'service restarted by Android after the app process ended',
        for (final r in await _exitReasons(prior.startMs)) 'previous process ended: $r',
      ];
      if (prior.directPending) {
        _night = _night.copyWith(directPending: false, directOff: true);
        notes.add('the previous process ended during a direct connection; scans only for the rest of the night');
      }
      if (watch != null) notes.add('drift-off detector off after the restart; it starts again at Lights off');
      final plan = _plan;
      if (plan != null && prior.alarmScoring && !prior.alarmOff) {
        _night = _night.copyWith(alarmScoring: false, alarmOff: true);
        notes.add(
          'smart alarm: the app process ended while the sleep model ran, so the model stays off tonight; '
          'the phone\'s alarm still rings at ${_hm(plan.endMs)}',
        );
      }
      final t = _now();
      _notes = [for (final n in [...startNotes, ...notes]) (t, n)];
      _lastLog = _newestLog(prior.startMs);
      final stem = _lastLog?.uri.pathSegments.last.replaceFirst(RegExp(r'\.log$'), '');
      if (prior.band != null) {
        _drop = (lastDataMs: null, stem: stem, why: 'app process restarted');
        // the ladder goes on from the time of the drop, when there was one, and tries once at once
        if (_night.lostAtMs == 0) _night = _night.copyWith(lostAtMs: _now().millisecondsSinceEpoch);
        _ladder.begin(DateTime.fromMillisecondsSinceEpoch(_night.lostAtMs));
        _ladder.hint(ReconnectHint.restarted);
      }
    } else {
      final plan = alarmPlan;
      _night = NightState(
        active: true,
        startMs: _now().millisecondsSinceEpoch,
        alarmEndMs: sleep ? plan?.endMs : null,
        alarmWindowMin: sleep ? plan?.windowMin : null,
        sleepKit: sleep,
      );
      if (sleep) {
        openSpan('sleep', source: sleepSource, startedRecording: true, at: _now());
        _startDrift();
      } else if (firstSpan != null) {
        openSpan(firstSpan!, source: sleepSource, startedRecording: true, at: _now());
      }
      final t = _now();
      // the drift-off line first, then any line _startDrift kept (hands-free), then the smart alarm's
      _notes = [
        for (final n in startNotes) (t, n),
        if (_drift != null) (t, 'drift-off detector on; lights off counts from the first sample until Lights off'),
        ..._notes,
        if (plan != null && sleep)
          (
            t,
            'smart alarm set: wake by ${_hm(plan.endMs)}, window from ${_hm(plan.startMs)}; the sleep model starts at '
                '${_hm(plan.scoreFromMs)}${alarm == null ? ' (not in this build: the phone\'s alarm alone)' : ''}',
          ),
      ];
    }
    _packets = PacketAccount(_night.packets);
    _packetsLoggedMs = _now().millisecondsSinceEpoch;
    _spans = [for (final l in _night.spans) ?Span.fromLine(l)];
    if (_night.sleepKit) _startCues();
    await _save();
    _set(
      RecorderStatus(
        phase: Phase.searching,
        nightStartMs: _night.startMs,
        nightSamples: _night.samples,
        runs: _night.runs,
        contactOhms: _night.contactOhms,
        contactAtMs: _night.contactAtMs,
        slots: Map.of(_slots),
        note: restartedBySystem && prior.active ? 'restarted by Android; reconnecting' : 'looking for the headband',
      ).withDrift(lightsOffMs: _night.lightsOffMs).withAlarm(_alarmStatus()),
    );
    _begun = true;
    final early = _earlyLightsOff;
    if (early != null) lightsOff(at: early);
    if (_earlyAlarmOff) alarmOff();
    return true;
  }

  /// A new recording begins while the saved state still holds an active one (its Stop was not finished, or its
  /// service went and never came back): that one's open spans are closed at its last sample before its state is
  /// replaced, or they would stay open for good.
  void _endLeftActive(NightState prior) {
    if (spanLog == null) return;
    try {
      final ended = endedWithoutStop(prior, dir, clock: _now, grace: Duration.zero);
      if (ended != null) _log.info('a recording left active was ended before the new one', {'recording': ended.recording});
    } catch (_) {}
  }

  Future<void> _loop() async {
    while (!_stopping) {
      _away();
      if (_stopping) return;
      final Headband? band;
      try {
        band = _night.band == null ? await _search() : await _reconnectTry();
        if (band != null && !_stopping && !await _inRange(band)) {
          abandoned.add(band);
          _note('${band.name} ${band.address} answered but reports out of range; left alone');
          continue;
        }
      } on SdkStuck catch (e) {
        await _stuck(e, null);
        return;
      }
      if (band == null) continue;
      if (_stopping) {
        await _quietly(band.disconnectAndDispose);
        return;
      }
      final ChunkWriter w;
      try {
        w = _openSet(dir, _now(), header: headerOf(band), inRecording: true, recording: _night.recording);
        if (_night.recording == null) _bindRecording(w.stem);
      } catch (e) {
        _set(_status.copyWith(note: 'cannot write files: ${_short(e)}'));
        await _quietly(band.disconnectAndDispose);
        await _pause(timing.notFoundWaitLong);
        continue;
      }
      final _End end;
      try {
        end = await _session(band, w);
      } catch (e) {
        await _runFailed(_writer ?? w, e);
        continue;
      }
      if (end == _End.stuck) return;
    }
  }

  /// Nothing unexpected may end the night (the service would stay up, idle, until morning): the run's files are
  /// closed, one line says why, and after a pause (so a fault that repeats cannot spin) the loop reconnects.
  Future<void> _runFailed(ChunkWriter w, Object e) async {
    try {
      w.close();
      _lastLog = File('${dir.path}/${w.stem}.log');
      _note('the run ended on an unexpected error: ${_short(e)}; the night goes on');
      _set(_status.copyWith(phase: Phase.reconnecting, note: 'error; reconnecting'));
    } catch (_) {}
    await _pause(timing.retryWait);
  }

  /// No headband yet tonight: scan until it turns up.
  Future<Headband?> _search() async {
    _set(_status.copyWith(phase: _night.runs == 0 ? Phase.searching : Phase.reconnecting));
    try {
      final band = await _scan(timing.scanFor);
      if (band != null || _stopping) {
        _misses = 0;
        return band;
      }
      _misses++;
      _set(_status.copyWith(note: 'headband not found; is it on and charged?'));
      await _pause(_misses >= 6 ? timing.notFoundWaitLong : timing.notFoundWait);
    } on SdkStuck {
      rethrow;
    } catch (e) {
      _set(_status.copyWith(note: 'could not connect: ${_short(e)}'));
      await _pause(timing.notFoundWait);
    }
    return null;
  }

  /// One step of the reconnect ladder (headband/reconnect_ladder.dart) to get tonight's headband back after a drop or
  /// a process restart: the ladder waits and names the try; here it is made, directly by the address, or as a short
  /// scan when the ladder says so (stages A and B, every [RecorderTiming.scanEvery]-th try) and on every try once
  /// direct connections are off. In stage C the headband may also arrive by the waiting connect, with no try at all.
  Future<Headband?> _reconnectTry() async {
    final id = _night.band!;
    _ladder.begin(_night.lostAtMs > 0 ? DateTime.fromMillisecondsSinceEpoch(_night.lostAtMs) : _now());
    _set(_status.copyWith(phase: Phase.reconnecting));
    // the ladder may wait many minutes here: the 60-minute rule and the 6-hour stop are not kept waiting with it
    final away = Timer.periodic(timing.awayCheckEvery, (_) {
      if (!_stopping) _away();
    });
    final LadderStep? step;
    try {
      step = await _ladder.next(id, stop: _stopSignal.future);
    } finally {
      away.cancel();
    }
    if (step == null || _stopping) {
      final late = step?.band;
      if (late != null) await _quietly(late.disconnectAndDispose);
      return null;
    }
    final n = step.n;
    final arrived = step.band;
    if (arrived != null) {
      _via = (how: 'waiting connect', tryNo: n, by: step.by);
      _note('the headband showed up on the waiting connect (step $n)');
      return arrived;
    }
    var scan = _night.directOff || timing.scanEvery <= 1 || step.scanDue;
    var how = scan ? 'scan' : 'direct to ${id.address}';
    // the ordinary tries of stages A and B keep their old line; any other road is named
    final why = const {'quick try', 'minute try', 'app restart'}.contains(step.by) ? '' : ', ${step.by}';
    final t0 = _now();
    String took() => '${(_now().difference(t0).inMilliseconds / 1000).toStringAsFixed(1)} s';
    try {
      Headband? band;
      try {
        band = scan ? await _scan(timing.rescanFor) : await _direct(id);
      } on NeedsScan catch (e) {
        // The connection in use cannot reach this headband directly (the switch moved during the night): a scan now
        // rather than at every third try; once it connects, the night's headband is one it can reach.
        _note('reconnect try $n ($how$why): $e; scanning instead');
        scan = true;
        how = 'scan';
        band = await _scan(timing.rescanFor);
      }
      if (band != null) {
        _via = (how: scan ? 'scan' : 'direct', tryNo: n, by: step.by);
        _note('reconnect try $n ($how$why): connected after ${took()}');
        return band;
      }
      if (_stopping) return null;
      _note('reconnect try $n ($how$why): not found after ${took()}');
    } on SdkStuck {
      _note('reconnect try $n ($how$why): no answer for ${took()} (SDK stuck)');
      rethrow;
    } catch (e) {
      _note('reconnect try $n ($how$why): failed after ${took()}: ${_short(e)}');
    }
    _set(
      _status.copyWith(
        note: _ladder.stage == LadderStage.wait
            ? 'headband away ${awayText(_now().difference(_ladder.lostAt ?? _now()))}; waiting for it'
            : 'headband not found yet (try $n); trying again',
      ),
    );
    return null;
  }

  Future<Headband?> _scan(Duration scanFor) => _race(
    finder.find(
      scanFor,
      onFound: (name, rssi) {
        _set(_status.copyWith(phase: Phase.connecting, rssi: rssi, note: 'found $name; connecting'));
      },
    ),
    'scan and connect',
    scanFor + timing.connectTimeout,
  );

  /// A direct connection. The flag is saved first and stays set until the new run's first data (cleared
  /// in [_record]): if the SDK takes the process down anywhere in between (the laptop SDK crashed on
  /// reconnects), the restarted process finds it set and scans only. A blocked call leaves it set too;
  /// a plain failure clears it.
  Future<Headband?> _direct(BandId id) async {
    _night = _night.copyWith(directPending: true);
    await _save();
    final Headband? band;
    try {
      band = await _race(finder.connectDirect(id), 'direct connect', timing.connectTimeout);
    } on SdkStuck {
      rethrow;
    } catch (_) {
      await _clearDirectPending();
      rethrow;
    }
    if (band == null) await _clearDirectPending(); // stopped
    return band;
  }

  Future<void> _clearDirectPending() async {
    if (!_night.directPending) return;
    _night = _night.copyWith(directPending: false);
    await _save();
  }

  /// [attempt] with a deadline, or null as soon as Stop is pressed (a headband connected after Stop is let go).
  Future<Headband?> _race(Future<Headband?> attempt, String what, Duration deadline) async {
    final first = await Future.any<Object?>([
      attempt.timeout(deadline, onTimeout: () => throw SdkStuck(what, deadline)),
      _stopSignal.future.then((_) => _stopMarker),
    ]);
    if (identical(first, _stopMarker)) {
      unawaited(attempt.then((b) => b?.disconnectAndDispose(), onError: (_) {}));
      return null;
    }
    return first as Headband?;
  }

  Future<_End> _session(Headband band, ChunkWriter first) async {
    // the open file set: another one after a roll-over ([_rollOver]); everything below writes into the one open now
    var w = first;
    _writer = w;
    _night = _night.copyWith(runs: _night.runs + 1, band: band.id);
    _packets.startRun();
    var lost = false;
    bool isLost() => lost;
    final rangeSub = band.rangeChanges.listen((inRange) => lost = lost || !inRange);
    StreamSubscription<BandNote>? notesSub;
    StreamSubscription<List<Sample>>? sigSub;
    var end = _End.failed;
    try {
      for (final (t, line) in _notes) {
        w.log(line, at: t);
      }
      _notes = const [];
      // Our own connection and the DIY board write their drops, reconnects and lost packets into the run's log (after
      // the lines kept from before the run, so the log stays in time order), and say when the headband's packet
      // numbers start again inside the run (BrainBit's SDK has no such notes).
      if (band is BandNotes) {
        notesSub = (band as BandNotes).notes.listen((n) {
          if (n.newStream) _packets.startRun();
          if (n.line != null && !w.isClosed) w.log(n.line!);
        });
      }
      for (final (t, text) in _pendingMarkers) {
        _marker(text, t);
      }
      _pendingMarkers = const [];
      _logReconnected(w);
      await _save();
      final other = band is OtherBoard ? band as OtherBoard : null;
      final battery = other == null ? await _battery(band, streaming: band is LentBand) : null;
      final rssi = band.rssi;
      _log.info('connected ${band.name}', {'battery': battery, 'rssi': rssi, 'run': _night.runs});
      w.log(
        other == null
            ? 'connected ${band.name} ${band.address} serial ${band.serial} battery $battery% '
                  'signal ${rssi == null ? 'unknown (no scan)' : '$rssi dBm'}'
            : 'connected ${band.name} ${band.address} (no battery or signal-strength reading from this board)',
      );
      if (other != null) {
        _otherBoard(other.board);
      } else {
        _mapSites(w.header);
      }
      await _logPhone(w);
      await _logBattery(w);
      await _steps?.setup(w.log);
      _set(
        _status.copyWith(
          phase: Phase.connecting,
          rssi: band.rssi,
          battery: battery,
          runs: _night.runs,
          note: 'connected',
          board: other?.board,
        ),
      );
      final names = w.header.names;
      _judge = QualityJudge(names: names, clock: _now)..fit();
      _seconds = SecondMaker(channels: names.length);
      if (_night.contactOhms.isNotEmpty) {
        final at = _night.contactAtMs ?? _night.startMs;
        _judge!.ohms(_night.contactOhms, at: DateTime.fromMillisecondsSinceEpoch(at));
      }
      if (!_night.contactTried && other == null) await _contactCheck(band, w);
      sigSub = band.signal.listen((rows) => _onRows(w, rows));
      if (await _startSignal(band, w, isLost)) {
        w.log('recording started, 250 Hz');
        if (_markOpenSpans) {
          _markOpenSpans = false;
          for (final s in _spans) {
            if (!s.closed) _marker('span: ${s.kind} start', _now());
          }
        }
        _set(_status.copyWith(phase: Phase.recording, note: 'recording'));
        end = await _record(band, w, isLost, (next) => w = next);
      } else {
        // Stop pressed before the signal ran (during the contact check): a stop, not a drop
        end = _stopping ? _End.stopped : (lost ? _End.lost : _End.failed);
      }
    } on SdkStuck catch (e) {
      await _cancel([sigSub, rangeSub, notesSub]);
      await _stuck(e, w);
      return _End.stuck;
    } catch (e) {
      // Anything unexpected ends this run only; the night goes on with a reconnect.
      w.log('unexpected error: ${_short(e)}');
    }
    await _cancel([sigSub, rangeSub]);
    // The headband's notes are heard until the run's files close: stopping its signal and letting it go write its
    // last lines (the lost packets since its last note).
    try {
      return await _finish(band, w, end, isLost);
    } finally {
      await _cancel([notesSub]);
    }
  }

  /// Ends a run's subscriptions; a failing cancel costs nothing.
  static Future<void> _cancel(List<StreamSubscription<Object?>?> subs) async {
    for (final s in subs) {
      try {
        await s?.cancel();
      } catch (_) {}
    }
  }

  /// First line of a run that follows a drop: how the headband came back and how long the gap was so far.
  void _logReconnected(ChunkWriter w) {
    final d = _drop;
    final v = _via;
    _drop = null;
    _via = null;
    if (d == null || v == null) return;
    final last = d.lastDataMs;
    final gap = last == null ? '' : ', ${((_now().millisecondsSinceEpoch - last) / 1000).toStringAsFixed(1)} s ago';
    // which road brought it back, and after how long: after a week the log says which roads work on this phone
    final back = _ladder.backLine(v.by);
    w.log(
      'reconnected (${v.how}, try ${v.tryNo}) after a drop (${d.why}); previous run ${d.stem ?? 'unknown'}, '
      'last data ${last == null ? 'unknown' : logTime(DateTime.fromMillisecondsSinceEpoch(last))}$gap; $back',
    );
    _log.info('headband back after a drop (${d.why})', {
      'how': v.how,
      'try': v.tryNo,
      'why': d.why,
      'by': v.by,
      if (last != null) 'reconnect_ms': _now().millisecondsSinceEpoch - last,
    });
  }

  void _onRows(ChunkWriter w, List<Sample> rows) {
    if (rows.isEmpty) return;
    final t = _now();
    final firstOfFile = w.samplesReceived == 0 && !identical(w, _continues);
    if (firstOfFile) _resumeSleep(t);
    w.addBatch(t, rows);
    _packets.add(rows);
    final ms = t.millisecondsSinceEpoch;
    final slot = ms ~/ slotMs;
    _slots[slot] = (_slots[slot] ?? 0) + rows.length;
    _status = _status.copyWith(nightSamples: _status.nightSamples + rows.length, lastDataMs: ms, slots: _slots);
    _judgeRows(rows);
    // the detectors read O1 O2 T3 T4 in that order, picked by name; with them off nothing reads these
    final sites = _noDetectors ? rows : inOrder(rows, _siteMap);
    if (_drift != null) {
      _guarded((d) {
        d.add(t, sites, firstOfFile: firstOfFile);
        for (final text in d.takeEvents()) {
          _marker(text, t);
        }
      });
    }
    if (_alarm == null && !_alarmMade) _startAlarm(t);
    _live.run((_) {
      if (_night.sleepKit) scorer?.add(t, sites, firstOfFile: firstOfFile); // an exception here reaches the guard: all of it off
      _scorerLines();
      _alarmCall((a) => a.add(t, sites, firstOfFile: firstOfFile), t);
      _cueCall((c) => c.add(t, sites, firstOfFile: firstOfFile), t);
    });
    _liveTidy();
  }

  /// The run's signal through the one judge: each finished second may change an electrode's word in the status.
  void _judgeRows(List<Sample> rows) {
    final maker = _seconds, judge = _judge;
    if (maker == null || judge == null) return;
    final row = List<double>.filled(maker.channels, 0);
    var changed = false;
    for (final s in rows) {
      if (s.volts.length != row.length) return;
      for (var c = 0; c < row.length; c++) {
        row[c] = s.volts[c] * 1e6;
      }
      final sec = maker.push(row);
      if (sec != null) {
        judge.second(sec);
        changed = true;
      }
    }
    if (changed) _status = _status.copyWith(quality: judge.verdict);
  }

  /// The guard is on while the smart alarm or the cues run.
  void _liveStart(String who) {
    _liveWho.add(who);
    if (_live.watch == null) _live.start(const _LiveSleep());
  }

  /// Lets finished helpers go; with none left the guard is off until one starts again.
  void _liveTidy() {
    final c = _cueWatch;
    if (c != null && c.finished) {
      _cueWatch = null;
      unawaited(_closeCues(c));
    }
    if (_alarm == null && _cueWatch == null && _live.watch != null) _live.release();
  }

  /// The scorer's own lines (the model on, shared, off) go into the `.log`.
  void _scorerLines() {
    for (final line in scorer?.takeEvents() ?? const <String>[]) {
      _logLine(line);
    }
  }

  /// A call into the smart alarm: its exception switches it off alone, with one log line.
  void _alarmCall(void Function(AlarmWatch a) call, DateTime t) {
    final a = _alarm;
    if (a == null) return;
    try {
      call(a);
      for (final text in a.takeEvents()) {
        _marker(text, t);
      }
    } catch (e) {
      _alarmStop(_short(e));
      return;
    }
    if (identical(_alarm, a) && a.finished) _alarmFinished(a);
  }

  /// A call into the cues: their exception switches them off alone, with one log line.
  void _cueCall(void Function(CueWatch c) call, DateTime t) {
    final c = _cueWatch;
    if (c == null) return;
    try {
      call(c);
      for (final text in c.takeEvents()) {
        _marker(text, t);
      }
    } catch (e) {
      _cueWatch = null;
      _cuesStopped(_short(e), c);
    }
  }

  /// The guard switched everything off (the scorer threw, too much time or memory): one log line for all.
  void _liveStopped(String why, _LiveSleep _) {
    _liveOff = true;
    final a = _alarm, c = _cueWatch, plan = _plan;
    _alarm = null;
    _cueWatch = null;
    final who = [if (a != null) 'smart alarm', if (c != null) c.who];
    _logLine(
      '${who.isEmpty ? 'live sleep model' : who.join(' and ')} stopped: $why; '
      '${a == null ? '' : 'the phone\'s alarm still rings at ${plan == null ? 'the window\'s end' : _hm(plan.endMs)}; '}'
      'the recording goes on',
    );
    if (a != null) {
      _night = _night.copyWith(alarmScoring: false, alarmOff: true);
      _alarmLast = AlarmLive(phase: AlarmPhase.off, note: 'The sleep model was switched off ($why).');
      unawaited(_save().catchError((Object _) {}));
      unawaited(_closeAlarm(a));
      _set(_withAlarm(_status));
    }
    if (c != null) _offCues(why, c);
    unawaited(_closeScorer());
  }

  Future<void> _closeScorer() async {
    try {
      await scorer?.close();
    } catch (_) {}
  }

  /// Tonight's sound cues, when they are on; a failure here costs only the cues.
  void _startCues() {
    final make = cues;
    if (make == null || _noDetectors) return;
    try {
      final c = make(_spans.where((s) => !s.closed && s.isSleep).lastOrNull?.start.millisecondsSinceEpoch ?? _night.startMs);
      if (c == null) return;
      _cueWatch = c;
      if (!c.finished) _liveStart(c.who); // off from the start (no loudness yet): let go at the next batch
      for (final text in c.takeEvents()) {
        _marker(text, _now());
      }
    } catch (e) {
      _cueLine('sound cues could not start: ${_short(e)}; the recording goes on');
    }
  }

  /// The 10-second check of the smart alarm and the cues (the window's end, Lights off, the drift-off detector's
  /// state, the model's own state), then the guard's time and memory.
  void _checkLive() {
    if (_live.watch == null) return;
    final t = _now();
    _live.run((_) {
      _alarmCall((a) => a.check(t), t);
      _cueCall((c) => c.check(t, lightsOffMs: _night.lightsOffMs, drift: _drift?.live?.state.name), t);
      _scorerLines();
    });
    _live.checkLimits();
    _liveTidy();
    _scorerLines();
  }

  /// The cues alone failed: one log line; the smart alarm and the model it uses go on.
  void _cuesStopped(String why, CueWatch c) {
    _cueLine('${c.who} stopped: $why; the recording goes on');
    _offCues(why, c);
  }

  void _offCues(String why, CueWatch c) {
    try {
      if (c is NightCues) c.off('The recorder stopped them ($why).');
    } catch (_) {}
    unawaited(_closeCues(c));
  }

  Future<void> _closeCues(CueWatch c) async {
    try {
      await c.close();
    } catch (_) {}
  }

  /// A line in the open file set's `.log`, else beside the last closed one, else kept for the next.
  void _cueLine(String line) {
    final w = _writer;
    try {
      if (w != null && !w.isClosed) {
        w.log(line);
      } else {
        _note(line);
      }
    } catch (_) {}
  }

  /// The night screen's Lights off: a marker in the recording, kept in the saved night, and the drift-off detector
  /// starts again from the night's next 30 s epoch (after a process restart it starts here). [at]: when it was tapped,
  /// if earlier than now.
  void lightsOff({DateTime? at}) {
    if (_stopping) return;
    final t = at ?? _now();
    if (!_begun) {
      _earlyLightsOff = t;
      return;
    }
    if (!_night.sleepKit) return; // no sleep span: nothing counts from Lights off
    _night = _night.copyWith(lightsOffMs: t.millisecondsSinceEpoch);
    unawaited(_save().catchError((Object _) {})); // the next 10 s check saves it again
    _marker(lightsOffMarker, t);
    if (_drift == null && !_driftUsed) _startDrift();
    _guarded((d) => d.lightsOff(t));
    _set(_withAlarm(_withDrift(_status)));
  }

  void _startDrift() {
    final make = watch;
    if (make == null || _noDetectors) return;
    try {
      final d = _drift = make();
      _driftUsed = true;
      _driftWall.start();
      if (d is LiveDrift && d.hands != null) _note('hands-free on: a double clench marks a moment (never while probably asleep)');
    } catch (e) {
      _note('drift-off detector could not start: ${_short(e)}');
    }
  }

  /// Every call into the detector goes through here: any exception switches it off for the rest of the process with
  /// one log line, and the recording never notices.
  void _guarded(void Function(DriftWatch d) call) {
    final d = _drift;
    if (d == null) return;
    _driftTime.start();
    try {
      call(d);
      _driftSamples = d.samples;
    } catch (e) {
      _driftOff('${_short(e)}; the recording goes on');
    } finally {
      _driftTime.stop();
    }
  }

  void _driftOff(String why) {
    _drift = null;
    _driftWall.stop();
    final line = 'drift-off detector stopped: $why';
    final w = _writer;
    try {
      if (w != null && !w.isClosed) {
        w.log(line);
      } else {
        _note(line);
      }
    } catch (_) {}
  }

  /// Switched off when it has used more than its share of the time (a phone much slower than expected).
  void _checkDriftBudget() {
    if (_drift == null || _driftWall.elapsed < timing.driftBudgetAfter) return;
    final share = _driftTime.elapsedMicroseconds / max(1, _driftWall.elapsedMicroseconds);
    if (share > timing.driftBudget) {
      _driftOff(
        'it took ${(share * 100).toStringAsFixed(1)} % of the time (over ${(timing.driftBudget * 100).toStringAsFixed(1)} %); '
        'the recording goes on',
      );
    }
  }

  RecorderStatus _withDrift(RecorderStatus s) {
    final live = _drift?.live;
    return s.withDrift(drift: live?.state, lightsOffMs: _night.lightsOffMs, onsetMs: live?.onsetMs);
  }

  /// Tonight's alarm plan, from the saved night.
  AlarmPlan? get _plan {
    final end = _night.alarmEndMs, w = _night.alarmWindowMin;
    if (end == null || w == null) return null;
    try {
      return AlarmPlan(endMs: end, windowMin: w);
    } on ArgumentError {
      return null;
    }
  }

  /// Starts the smart alarm's live model once the hour before its window has come (once a process).
  void _startAlarm(DateTime now) {
    final plan = _plan, make = alarm;
    if (plan == null || make == null || _night.alarmOff || _noDetectors) return;
    final ms = now.millisecondsSinceEpoch;
    if (ms < plan.scoreFromMs || ms >= plan.endMs) return;
    _alarmMade = true;
    if (_liveOff) {
      _night = _night.copyWith(alarmOff: true);
      _alarmLast = const AlarmLive(phase: AlarmPhase.off, note: 'The sleep model was switched off earlier tonight.');
      _logLine(
        'smart alarm: the live sleep model was switched off earlier tonight, so it stays off; the phone\'s alarm rings at '
        '${_hm(plan.endMs)}',
      );
      return;
    }
    try {
      _alarm = make(plan);
      _liveStart('smart alarm');
      _night = _night.copyWith(alarmScoring: true);
      unawaited(_save().catchError((Object _) {})); // a crash from here on keeps the model off after the restart
    } catch (e) {
      _night = _night.copyWith(alarmOff: true);
      _logLine('smart alarm: the sleep model could not start: ${_short(e)}; the phone\'s alarm rings at ${_hm(plan.endMs)}');
    }
  }

  /// A board that is not a BrainBit: the drift-off detector (and its hands-free), the smart alarm's sleep model, the
  /// lucid cues and the live sleep model they share read BrainBit's O1 O2 T3 T4, so they stop for the night before the
  /// board's first sample, each with one line, and none starts again; the phone's alarm itself still rings.
  void _otherBoard(BoardLive b) => _detectorsOff(
    drift: "it reads BrainBit's O1 O2 T3 T4, not this board's ${b.names.join(' ')}",
    cues: "off with this board (the sleep model reads BrainBit's O1 O2 T3 T4); no cue plays tonight",
    cuesShort: 'off with the DIY board',
    alarmNote: "Off with the DIY board: the sleep model reads BrainBit's O1 O2 T3 T4.",
    alarm: "the sleep model is off with this board (it reads BrainBit's O1 O2 T3 T4)",
  );

  /// Where the detectors' O1 O2 T3 T4 are in this run's records (header.dart `pick`, by name); null: in that order.
  List<int>? _siteMap;

  /// The detectors read O1 O2 T3 T4 by name from the run's header; a recording without them turns them off as a board
  /// does, saying which sites it lacks (DECISIONS 630-639): never another channel in their place.
  void _mapSites(RecordingHeader h) {
    try {
      _siteMap = mapping(h, sleepSites, who: 'The drift-off detector and the live sleep model');
    } on MissingSites catch (e) {
      _siteMap = null;
      final lacks = e.missing.join(' ');
      _detectorsOff(
        drift: e.message,
        cues: 'off: the sleep model reads O1 O2 T3 T4 and this recording has no $lacks; no cue plays tonight',
        cuesShort: 'off: no $lacks in this recording',
        alarmNote: 'Off: the sleep model reads O1 O2 T3 T4; this recording has no $lacks.',
        alarm: 'the sleep model is off: it reads O1 O2 T3 T4 and this recording has no $lacks',
      );
    }
  }

  void _detectorsOff({
    required String drift,
    required String cues,
    required String cuesShort,
    required String alarmNote,
    required String alarm,
  }) {
    if (_noDetectors) return;
    _noDetectors = true;
    if (_drift != null) _driftOff(drift);
    final c = _cueWatch;
    _cueWatch = null;
    if (c != null) {
      _cueLine('${c.who}: $cues');
      _offCues(cuesShort, c);
    }
    final plan = _plan;
    if (plan != null && !_night.alarmOff) {
      final a = _alarm;
      _alarm = null;
      _night = _night.copyWith(alarmScoring: false, alarmOff: true);
      _alarmLast = AlarmLive(phase: AlarmPhase.off, note: alarmNote);
      _logLine("smart alarm: $alarm; the phone's alarm still rings at ${_hm(plan.endMs)}");
      if (a != null) unawaited(_closeAlarm(a));
    }
    // nothing is left under the guard: the shared model never gets a sample
    _live.release();
    if (scorer != null) unawaited(_closeScorer());
  }

  /// The model is done (it woke you, the window ended, or it gave up by itself). What it says after that (the early
  /// ring's answer comes from the phone later: a failure) goes into the night like its other lines.
  void _alarmFinished(AlarmWatch a) {
    _alarmLast = a.live;
    _alarm = null;
    _night = _night.copyWith(alarmScoring: false, alarmOff: true);
    unawaited(_save().catchError((Object _) {}));
    unawaited(
      _closeAlarm(a).then((_) {
        try {
          for (final text in a.takeEvents()) {
            _marker(text, _now());
          }
        } catch (_) {}
      }),
    );
  }

  /// The alarm alone failed: one log line; the cues and the model they use go on.
  void _alarmStop(String why) {
    final a = _alarm;
    final plan = _plan;
    _alarm = null;
    _night = _night.copyWith(alarmScoring: false, alarmOff: true);
    _alarmLast = AlarmLive(phase: AlarmPhase.off, note: 'The sleep model was switched off ($why).');
    unawaited(_save().catchError((Object _) {}));
    _logLine(
      'smart alarm stopped: $why; the phone\'s alarm still rings at ${plan == null ? 'the window\'s end' : _hm(plan.endMs)}; '
      'the recording goes on',
    );
    if (a != null) unawaited(_closeAlarm(a));
  }

  Future<void> _closeAlarm(AlarmWatch a) async {
    try {
      await a.close();
    } catch (_) {}
  }

  /// The night screen's Alarm off: the live model stops; the screen takes the phone's alarm away itself.
  void alarmOff() {
    if (!_begun) {
      _earlyAlarmOff = true; // the plan is known once the night is
      return;
    }
    if (_plan == null || _alarmLast?.note == 'Turned off.') return;
    final a = _alarm;
    _alarm = null;
    _night = _night.copyWith(alarmScoring: false, alarmOff: true);
    _alarmLast = const AlarmLive(phase: AlarmPhase.off, note: 'Turned off.');
    unawaited(_save().catchError((Object _) {}));
    _marker('smart alarm: turned off', _now());
    if (a != null) unawaited(_closeAlarm(a));
    _liveTidy();
    _set(_withAlarm(_status));
  }

  AlarmStatus? _alarmStatus() {
    final plan = _plan;
    if (plan == null) return null;
    final live = _alarm?.live ?? _alarmLast;
    final phase = live?.phase ?? (_night.alarmOff ? AlarmPhase.off : AlarmPhase.waiting);
    final wake = live?.wake;
    return AlarmStatus(
      endMs: plan.endMs,
      windowMin: plan.windowMin,
      phase: phase.name,
      stage: live?.stage,
      wakeMs: wake?.atMs,
      why: wake == null ? null : alarmWhyName(wake.why),
      note: live?.note ??
          (phase == AlarmPhase.off && live == null
              ? (alarm == null ? 'Not in this build.' : 'The sleep model stopped earlier tonight.')
              : null),
    );
  }

  RecorderStatus _withAlarm(RecorderStatus s) => s.withAlarm(_alarmStatus());

  /// A line in the open file set's `.log`, else beside the last closed one, else kept for the next.
  void _logLine(String line) {
    final w = _writer;
    try {
      if (w != null && !w.isClosed) {
        w.log(line);
      } else {
        _note(line);
      }
    } catch (_) {}
  }

  /// A marker (`.markers.jsonl`, an annotation in the night's BDF) and a `.log` line: in the open file set, else beside
  /// the last closed one, else kept for tonight's first. Never throws.
  void _marker(String text, DateTime at) {
    try {
      final w = _writer;
      final ({String stem, int i})? into = w != null && !w.isClosed
          ? (stem: w.stem, i: w.samplesReceived)
          : _lastLog == null
          ? null
          : (stem: _lastLog!.path.substring(_lastLog!.parent.path.length + 1, _lastLog!.path.length - 4), i: _closedSamples());
      if (into == null) {
        _pendingMarkers = [..._pendingMarkers, (at, text)];
        return;
      }
      File('${dir.path}/${into.stem}.markers.jsonl').writeAsStringSync(
        '${jsonEncode({'t': unixSeconds(at), 'i': into.i, 'text': text})}\n',
        mode: FileMode.append,
        flush: true,
      );
      if (w != null && !w.isClosed) {
        w.log(text, at: at);
      } else {
        appendLogLine(_lastLog!, text, at);
      }
    } catch (_) {}
  }

  /// Samples in the last closed run's `.f32`.
  int _closedSamples() {
    final log = _lastLog;
    if (log == null) return 0;
    return recordsIn(File('${log.path.substring(0, log.path.length - 4)}.f32')); // packed or not, by its header
  }

  Future<void> _contactCheck(Headband band, ChunkWriter w) async {
    // a connection that is already live comes with the reading in force: no new check, no pause (DECISIONS 855-856)
    final known = band is KnownContact ? (band as KnownContact).knownContact : null;
    if (known != null) {
      final at = known.at.millisecondsSinceEpoch;
      _night = _night.copyWith(contactTried: true, contactOhms: known.ohms, contactAtMs: at);
      w.log('contact ohms ${ohmsLine(known.ohms)} (measured ${logTime(known.at)} on the live connection; not measured again)');
      Metrics.write({'kind': 'contact', 'source': 'night', 'ohms': known.ohms});
      _judge?.ohms(known.ohms, at: known.at);
      _set(_status.copyWith(contactOhms: known.ohms, contactAtMs: at));
      await _save();
      return;
    }
    if (band is LentBand) {
      // a live connection the screen never measured contact on (or whose reading no longer holds): it cannot be
      // measured from here (that would pause the screen's stream, and no resistance ever comes over the lend), so
      // nothing is waited for. Not counted as tonight's check: a connection of the recorder's own still gets one.
      // (The owner's night of 2026-11-25 00:36 waited 6 s here and wrote "no resistance data arrived".)
      w.log('no contact reading on the live connection; not measured now');
      return;
    }
    _set(_status.copyWith(phase: Phase.checkingContact, note: 'checking contact'));
    final last = <String, double>{};
    final sub = band.resistance.listen(last.addAll);
    try {
      await _sdk('start resist', band.startResist);
      await _pause(timing.contactFor);
      await _sdk('stop resist', band.stopResist);
    } on SdkStuck {
      rethrow;
    } catch (e) {
      w.log('contact check failed: ${_short(e)}');
    } finally {
      await sub.cancel();
    }
    // Tried once a night only: on the laptop a stream started right after a check once sent nothing.
    final ohms = <String, double?>{for (final n in channelNames) n: last[n]};
    _night = _night.copyWith(
      contactTried: true,
      contactOhms: last.isEmpty ? const {} : ohms,
      contactAtMs: _now().millisecondsSinceEpoch,
    );
    if (last.isEmpty) {
      w.log('contact check: no resistance data arrived');
    } else {
      w.log('contact ohms ${ohmsLine(ohms)}');
      Metrics.write({'kind': 'contact', 'source': 'night', 'ohms': ohms});
      _judge?.ohms(ohms, at: _now());
      _set(_status.copyWith(contactOhms: ohms, contactAtMs: _night.contactAtMs));
    }
    await _save();
    await _pause(timing.settle);
  }

  Future<bool> _startSignal(Headband band, ChunkWriter w, bool Function() lost) async {
    for (var attempt = 1; attempt <= timing.startAttempts; attempt++) {
      if (_stopping || lost()) return false;
      try {
        await _sdk('start signal', band.startSignal);
        return true;
      } on SdkStuck {
        rethrow;
      } catch (e) {
        w.log('start failed ($attempt/${timing.startAttempts}): ${_short(e)}');
        await _pause(timing.retryWait);
      }
    }
    if (!_stopping) w.log('the signal would not start; reconnecting');
    return false;
  }

  Future<_End> _record(Headband band, ChunkWriter w, bool Function() lost, void Function(ChunkWriter next) rolled) async {
    var ticks = 0;
    var lastTotal = w.samplesReceived;
    var stalled = 0;
    final other = band is OtherBoard ? band as OtherBoard : null;
    while (true) {
      await _pause(timing.tick);
      w.append();
      _set(_withAlarm(_withDrift(other == null ? _status : _status.copyWith(board: other.board))));
      if (_stopping) return _End.stopped;
      if (lost()) {
        w.log(_lenderGone(band) ? lenderGoneLine : 'headband out of range; saving');
        return _End.lost;
      }
      if (++ticks % timing.ticksPerCheck != 0) continue;
      w.sync();
      _checkDriftBudget();
      _checkLive();
      await _save();
      final got = w.samplesReceived - lastTotal;
      lastTotal = w.samplesReceived;
      if (got > 0) await _clearDirectPending(); // a direct connection has proved itself
      if (lost() || !await _inRange(band)) {
        w.log(_lenderGone(band) ? lenderGoneLine : 'headband out of range; saving');
        return _End.lost;
      }
      if (other == null) {
        final battery = await _battery(band) ?? _status.battery;
        _set(_status.copyWith(battery: battery));
        w.log('samples ${w.samplesWritten} (+$got) battery $battery%');
      } else {
        w.log('samples ${w.samplesWritten} (+$got)');
      }
      if (_rollDue(w)) {
        final next = _rollOver(w);
        if (next != null) {
          w = next;
          rolled(next);
          lastTotal = 0;
          await _save();
        }
      }
      if (_now().millisecondsSinceEpoch - _batteryLoggedMs >= timing.phoneLogEvery.inMilliseconds) {
        await _logBattery(w);
      }
      await _steps?.tick(w.log);
      if (_now().millisecondsSinceEpoch - _packetsLoggedMs >= timing.packetLogEvery.inMilliseconds) {
        _logPackets(w);
      }
      stalled = got == 0 ? stalled + 1 : 0;
      if (stalled == 0) {
        if (_status.note != 'recording') _set(_status.copyWith(note: 'recording'));
        continue;
      }
      if (stalled >= timing.stallChecksToGiveUp) {
        w.log('still no data; reconnecting');
        return _End.stalled;
      }
      if (band is MendsDrops) {
        w.log('no data; the headband is mending the link itself (check $stalled)');
        _set(_status.copyWith(note: 'no data; the headband is reconnecting'));
      } else {
        await _restartStream(band, w, stalled);
      }
    }
  }

  /// The open set has reached its time or size ([RecorderTiming.rollAfter], [RecorderTiming.rollBytes]).
  bool _rollDue(ChunkWriter w) =>
      !_stopping &&
      w.samplesWritten > 0 &&
      (_rollFailedAt == null || _now().difference(_rollFailedAt!) >= timing.rollRetry) &&
      (_now().difference(w.opened) >= timing.rollAfter || w.bytesWritten >= timing.rollBytes);

  /// When a roll-over last failed; null: none since the last one that worked.
  DateTime? _rollFailedAt;

  /// The recording goes on in a new file set of the same recording, on the same connection (DECISIONS 1035-1036): the
  /// way a new set follows a drop, without the drop. Nothing waits in here, so no batch can arrive between the steps:
  /// every sample is in the old set or in the new one, never in both and never in neither.
  /// 1. the old set's samples go to disk (a failure, storage full: no roll-over, it stays open and is tried again);
  /// 2. the new set's files are made (a failure: the same);
  /// 3. the old set is closed, with nothing left in memory to lose, and the new one takes over.
  /// A kill after step 2 leaves the old set whole and an empty new one; the restarted service opens a third.
  /// Returns the new set, or null when the old one goes on.
  ChunkWriter? _rollOver(ChunkWriter old) {
    try {
      old.sync();
    } catch (e) {
      _rollFailedAt = _now();
      old.log('could not save the newest data: ${_short(e)}; the next file set waits');
      return null;
    }
    final ChunkWriter next;
    try {
      next = _openSet(dir, _now(), header: old.header, inRecording: true, recording: _night.recording);
    } catch (e) {
      _rollFailedAt = _now();
      old.log('could not start the next file set: ${_short(e)}; this one goes on');
      return null;
    }
    _rollFailedAt = null;
    // the set that fills up has data in it ([_rollDue]), so the headband is back for the ladder too: a drop before
    // the new set's first batch is a new drop, counted from the first step (DECISIONS 1070)
    _bandIsBack();
    _logPackets(old);
    old.log('total samples ${old.samplesWritten}, ${(old.samplesWritten / sampleRateHz / 60).toStringAsFixed(1)} min');
    old.log('file set full; the recording goes on without a gap in ${next.stem}');
    old.close();
    _count(old);
    next.log('continues ${old.stem} without a gap (same connection; a new file set every '
        '${(timing.rollAfter.inMinutes / 60).toStringAsFixed(1)} h or ${timing.rollBytes ~/ (1024 * 1024)} MB)');
    _writer = next;
    _continues = next;
    _log.info('the recording goes on in a new file set', {'from': old.stem, 'to': next.stem, 'samples': old.samplesWritten});
    return next;
  }

  /// The connection has recorded something since the last drop: the reconnect ladder ends, and the next drop starts
  /// from the shortest wait. Called for a run that closes with samples and at a roll-over (the run's samples are then
  /// in the set that was closed, not in the open one).
  void _bandIsBack() {
    _ladder.end();
    _night = _night.copyWith(lostAtMs: 0);
  }

  /// The run was on a connection lent by the screen's engine, and that engine no longer exists (headband/lend.dart).
  static bool _lenderGone(Headband band) => band is LentBand && band.lenderGone;

  /// The run's log line for that.
  static const String lenderGoneLine = 'the screen that lent the connection is gone; saving and reconnecting at once';

  Future<void> _restartStream(Headband band, ChunkWriter w, int attempt) async {
    w.log('no data, state inRange; restarting stream (try $attempt)');
    _set(_status.copyWith(note: 'no data; restarting the stream'));
    w.sync(); // save first: the calls below are the risky ones
    try {
      await _sdk('stop signal', band.stopSignal);
    } on SdkStuck {
      rethrow;
    } catch (_) {}
    await _pause(timing.settle);
    try {
      await _sdk('start signal', band.startSignal);
      w.log('stream restarted');
    } on SdkStuck {
      rethrow;
    } catch (e) {
      w.log('stream restart failed: ${_short(e)}');
    }
  }

  /// Closes a run. Data first; SDK calls only for a headband that is still in range.
  Future<_End> _finish(Headband band, ChunkWriter w, _End end, bool Function() lost) async {
    _syncQuietly(w);
    _count(w);
    _status = _status.copyWith(nightSamples: _night.samples);
    _logPackets(w);
    w.log('total samples ${w.samplesWritten}, ${(w.samplesWritten / sampleRateHz / 60).toStringAsFixed(1)} min');
    if (w.samplesWritten > 0) _bandIsBack();
    if (end != _End.stopped) _logDrop(w, end, lenderGone: _lenderGone(band));
    try {
      if (end == _End.lost || lost() || !await _inRange(band)) {
        abandoned.add(band);
        if (end != _End.lost) w.log('headband out of range; leaving it without SDK calls');
      } else {
        try {
          await _sdk('stop signal', band.stopSignal);
          w.log(band is OtherBoard ? 'stopped' : 'stopped, battery ${await _battery(band)}%');
        } on SdkStuck {
          rethrow;
        } catch (e) {
          w.log('stop failed: ${_short(e)}');
        }
        try {
          await _sdk('disconnect', band.disconnectAndDispose);
        } on SdkStuck {
          rethrow;
        } catch (_) {}
      }
    } on SdkStuck catch (e) {
      w.log('closing: $e');
      w.close();
      await _stuck(e, null);
      return _End.stuck;
    }
    w.close();
    _lastLog = File('${dir.path}/${w.stem}.log');
    await _save();
    if (end != _End.stopped) {
      _set(
        _status.copyWith(
          phase: Phase.reconnecting,
          note: end == _End.lost ? 'headband lost; reconnecting' : 'no data; reconnecting',
        ),
      );
    }
    return end;
  }

  /// The drop line in the run's own `.log`; the reconnect tries follow it there.
  void _logDrop(ChunkWriter w, _End end, {bool lenderGone = false}) {
    final why = switch (end) {
      _End.lost when lenderGone => 'lender gone',
      _End.lost => 'out of range',
      _End.stalled => 'no data',
      _ => 'run failed',
    };
    final last = _status.lastDataMs;
    w.log(
      'drop ($why); last data ${last == null ? 'none' : logTime(DateTime.fromMillisecondsSinceEpoch(last))}; reconnecting',
    );
    _drop = (lastDataMs: last, stem: w.stem, why: why);
    // kept with the night, so a restarted process goes on at the right stage of the ladder
    if (_night.lostAtMs == 0) _night = _night.copyWith(lostAtMs: last ?? _now().millisecondsSinceEpoch);
    _log.warn('headband link dropped: $why', data: {'stem': w.stem, 'last_data_ms': last});
  }

  /// A line for the night's log from outside the loop (Share on Wi-Fi going on or off): into the open run's
  /// `.log`, else as [_note]. Never throws.
  void note(String message) => _logLine(message);

  /// A line for the night's log between runs, with its own time: into the last closed run's `.log`, or,
  /// before tonight has one, kept for the next run's `.log`.
  void _note(String message) {
    _log.info(message);
    final t = _now();
    final log = _lastLog;
    if (log != null) {
      try {
        appendLogLine(log, message, t);
        return;
      } catch (_) {}
    }
    _notes = [..._notes, (t, message)];
  }

  /// The newest `.log` of tonight in [dir] (a restarted process continues the night's log there).
  File? _newestLog(int sinceMs) {
    try {
      final logs = [
        for (final f in dir.listSync().whereType<File>())
          if (f.path.endsWith('.log') &&
              (stemTime(f.uri.pathSegments.last)?.millisecondsSinceEpoch ?? 0) >= sinceMs - 1000)
            f,
      ]..sort((a, b) => a.path.compareTo(b.path));
      return logs.isEmpty ? null : logs.last;
    } catch (_) {
      return null;
    }
  }

  /// An SDK call blocked: save, then let the app restart its process (unless the user is stopping).
  Future<void> _stuck(SdkStuck e, ChunkWriter? w) async {
    if (w != null && !w.isClosed) {
      _syncQuietly(w);
      _count(w);
      w.log('$e; saved${_stopping ? '' : ', restarting the app process'}');
      w.close();
    }
    await _save();
    if (_stopping) return;
    _set(_status.copyWith(phase: Phase.reconnecting, note: 'Bluetooth stuck; restarting the recorder'));
    await onStuck(e.toString());
  }

  /// Adds a run's samples to the night's count, once whichever way the run ends (closed by the loop, by a stuck SDK
  /// call, or by a Stop that could not wait for it).
  void _count(ChunkWriter w) {
    if (identical(_counted, w)) return;
    _counted = w;
    _night = _night.copyWith(samples: _night.samples + w.samplesWritten);
  }

  /// [ChunkWriter.sync] where a failure (storage full) must not stop what follows: the headband is still let go
  /// properly and the night goes on. The `.log` says so when it can.
  void _syncQuietly(ChunkWriter w) {
    try {
      w.sync();
    } catch (e) {
      w.log('could not save the newest data: ${_short(e)}');
    }
  }

  Future<T> _sdk<T>(String what, Future<T> Function() call) =>
      call().timeout(timing.sdkTimeout, onTimeout: () => throw SdkStuck(what, timing.sdkTimeout));

  /// Battery in percent, or null if the read failed (a stuck read still counts as stuck).
  /// [streaming] false: a new connection's first reading (the gauge is believed most then, battery_estimate.dart).
  Future<int?> _battery(Headband band, {bool streaming = true}) async {
    try {
      final g = await _sdk('battery', band.battery);
      try {
        bandBattery?.note(g, _now(), streaming: streaming);
      } catch (_) {}
      return g;
    } on SdkStuck {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// A failed state read is taken as "lost", so no further SDK call goes to that headband.
  Future<bool> _inRange(Headband band) async {
    try {
      return await _sdk('state', band.isInRange);
    } on SdkStuck {
      rethrow;
    } catch (_) {
      return false;
    }
  }

  Future<void> _logPhone(ChunkWriter w) async {
    try {
      final power = await probe?.powerLine();
      if (power != null) w.log('phone $power');
    } catch (_) {}
  }

  /// The packet accounting line, from the whole night so far.
  void _logPackets(ChunkWriter w) {
    _packetsLoggedMs = _now().millisecondsSinceEpoch;
    w.log(_packets.counts.logLine());
  }

  /// One phone battery line in the run's `.log`, and the reading kept for the end-of-night drain. A phone
  /// that gives no numbers, or a slow channel call, only costs the line.
  Future<void> _logBattery(ChunkWriter w) async {
    _batteryLoggedMs = _now().millisecondsSinceEpoch;
    final b = await _readBattery();
    if (b == null) return;
    _night = _night.copyWith(phoneBattery: _night.phoneBattery.add(b, _now().millisecondsSinceEpoch));
    w.log('phone ${b.logLine()}');
  }

  Future<PhoneBattery?> _readBattery() async {
    try {
      return await probe?.battery().timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    }
  }

  /// The night was ended by the user: one last reading and the drain per hour, into the last run's `.log`.
  Future<void> _logNightEnd() async {
    final b = await _readBattery();
    if (b != null) {
      _night = _night.copyWith(phoneBattery: _night.phoneBattery.add(b, _now().millisecondsSinceEpoch));
      _note('phone ${b.logLine()}');
    }
    _note('end of night, ${_packets.counts.logLine()}');
    _note(_night.phoneBattery.summaryLine());
    if (_live.used) {
      // one line for the guard's helpers; with both, they shared one model
      final names = [if (_liveWho.contains('smart alarm')) 'smart alarm', ..._liveWho.where((w) => w != 'smart alarm')];
      final who = names.length > 1
          ? '${names.join(' and ')}, one sleep model:'
          : names.single == 'smart alarm'
          ? 'smart alarm: sleep model'
          : '${names.single}:';
      _note(
        '$who ${(_live.spent.inMicroseconds / 1e6).toStringAsFixed(2)} s of the recorder\'s time over '
        '${(_live.ran.inMicroseconds / 6e7).toStringAsFixed(1)} min',
      );
    }
    if (_driftUsed) {
      final hours = _driftSamples / sampleRateHz / 3600;
      final work = _driftTime.elapsedMicroseconds / 1e6;
      _note(
        'drift-off detector: ${work.toStringAsFixed(2)} s of work for ${hours.toStringAsFixed(2)} h of signal'
        '${hours > 0 ? ' (${(work / hours).toStringAsFixed(2)} s an hour)' : ''}${_drift == null ? ', then stopped' : ''}',
      );
      final d = _drift;
      final h = d is LiveDrift ? d.hands : null;
      if (h != null) _note('hands-free: ${h.heard} moments marked, ${h.ignoredAsleep} double clenches ignored while probably asleep');
    }
    await _save();
  }

  Future<void> _quietly(Future<void> Function() call) async {
    try {
      await call().timeout(timing.sdkTimeout);
    } catch (_) {}
  }

  /// Persists the night. It stays "active" unless the user ended it, so a restart continues it. Never throws: the
  /// saved night only helps a restarted process, and a store that fails must not cost the recording (one log line).
  /// One save at a time, in the order asked, each with the night as it is when it starts: two in flight could land
  /// in the other order (SharedPreferences commits on a pool of threads) and leave an older state saved. A save that
  /// takes over 10 s counts as failed, so the next can go.
  Future<void> _save() => _saves = _saves.then((_) => _saveNow());
  Future<void> _saves = Future<void>.value();

  Future<void> _saveNow() async {
    final w = _writer;
    final live = w == null || w.isClosed || identical(w, _counted) ? 0 : w.samplesWritten;
    try {
      await store
          .save(
            _night.copyWith(
              active: !(_stopping && _endNight),
              samples: _night.samples + live,
              slots: Map.of(_slots),
              packets: _packets.counts,
            ),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      if (_saveFailed) return;
      _saveFailed = true;
      _logLine('could not save the night state: ${_short(e)}; the recording goes on');
    }
  }

  bool _saveFailed = false;

  Future<List<String>> _exitReasons(int sinceMs) async {
    try {
      return await probe?.exitReasons(sinceMs) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// Waits [d], or less if Stop is pressed.
  Future<void> _pause(Duration d) => Future.any([Future<void>.delayed(d), _stopSignal.future]);

  void _set(RecorderStatus s) {
    _status = s.copyWith(rec: RecordingLive(id: _night.recording, sleep: _night.sleepKit, spans: _spans, band: _night.band?.name));
    onStatus(_status);
  }

  // ---- spans (Record first, DECISIONS 880-899) -----------------------------------------------------------------

  /// Sleep (or Nap) on the running recording: a sleep span from now and the sleep kit attached, with [plan] as its
  /// smart alarm. An open sleep span is returned as it is (Sleep and Nap never run together). Null before the
  /// recording has begun or once it stops.
  Span? startSleep({String kind = 'sleep', AlarmPlan? plan, String source = 'owner_button'}) {
    if (!_begun || _stopping) return null;
    final open = _spans.where((s) => !s.closed && s.isSleep).lastOrNull;
    if (open != null) return open;
    final t = _now();
    // one at a time (DECISIONS 983): an activity still marked (its page was closed) ends where the sleep starts
    for (final s in [..._spans]) {
      if (!s.closed) closeSpan(s.id, by: 'other_activity', at: t);
    }
    _attachKit(plan);
    final span = openSpan(kind, source: source, at: t);
    _startDrift();
    _startCues();
    _logLine(
      'sleep kit on for ${span.id}'
      '${plan == null ? '' : '; smart alarm set: wake by ${_hm(plan.endMs)}, window from ${_hm(plan.startMs)}'}',
    );
    _set(_withAlarm(_withDrift(_status)));
    return span;
  }

  /// A fresh sleep kit for a sleep span that starts (or goes on after Undo): the live model, the alarm, the cues.
  void _attachKit(AlarmPlan? plan) {
    final make = kit;
    if (make != null && !_noDetectors) {
      final k = make();
      scorer = k.scorer;
      alarm = k.alarm;
      cues = k.cues;
    }
    _night = _night.withSleepKit(on: true, alarmEndMs: plan?.endMs, alarmWindowMin: plan?.windowMin);
    _alarmMade = false;
    _alarmLast = null;
    _driftUsed = false;
  }

  /// The rest of the night (DECISIONS 1015): the 60-minute rule ended a Sleep stretch, nothing was marked since, and
  /// the headband's samples are back ([at]: the first of them). A new sleep stretch opens from that sample, with the
  /// sleep kit (no smart alarm: its window went with the old kit); the hour without data stays a gap between the
  /// two. It is the app's guess (source `auto_resume`): the owner is told, and Undo takes it away. Work and the
  /// other activities are not resumed.
  void _resumeSleep(DateTime at) {
    if (!resumeSleep || !_begun || _stopping) return;
    final ended = RecordingLive(id: _night.recording, spans: _spans).undoable;
    if (!ended.any((s) => s.kind == 'sleep')) return;
    _attachKit(null);
    final span = openSpan('sleep', source: 'auto_resume', at: at);
    _startDrift();
    _startCues();
    _logLine('the headband is back: sleep goes on by itself from here in a new stretch ${span.id} (the app\'s guess; Undo takes it away)');
    onSleepResumed?.call(span);
  }

  /// Undo of [_resumeSleep]: the stretch the app opened by itself ends where it began (no length: it gives no night
  /// and no report), `ended_by: undone`, and the sleep kit comes off.
  List<Span> _undoResume(Span resumed) {
    final closed = closeSpan(resumed.id, by: 'undone', at: resumed.start);
    unawaited(_detachKit());
    _logLine('Undo: the stretch the app opened by itself (${resumed.id}) is taken away');
    _set(_withAlarm(_withDrift(_status)));
    return [?closed];
  }

  /// "Still going? Undo": the spans the 60-minute rule ended last are open again, as if it had not ended them
  /// (their own start, no end); a sleep span gets a fresh sleep kit, without its smart alarm (that window has
  /// passed or was turned off with the kit). Empty when there is nothing to undo. When the app has since opened a
  /// sleep stretch by itself ([_resumeSleep]), Undo takes that one away instead.
  List<Span> undoHeadbandOff() {
    if (!_begun || _stopping) return const [];
    final resumed = RecordingLive(id: _night.recording, spans: _spans).resumed;
    if (resumed != null) return _undoResume(resumed);
    final back = RecordingLive(id: _night.recording, spans: _spans).undoable;
    if (back.isEmpty) return const [];
    final open = <Span>[];
    for (final s in back) {
      final again = s.reopened();
      _saidOnMs[_spans.indexWhere((x) => x.id == s.id)] = _now().millisecondsSinceEpoch;
      _putSpan(again);
      if (_night.recording != null) _marker('span: ${s.kind} start (again: Undo)', _now());
      open.add(again);
    }
    if (open.any((s) => s.isSleep)) {
      _attachKit(null);
      _startDrift();
      _startCues();
    }
    _logLine('Undo: ${[for (final s in open) s.kind].join(', ')} go${open.length == 1 ? 'es' : ''} on');
    _set(_withAlarm(_withDrift(_status)));
    return open;
  }

  /// Stop sleep: the open sleep span is closed and the sleep kit detached; the recording goes on. Null without one.
  Future<Span?> stopSleep({String by = 'owner', DateTime? at}) async {
    final open = _spans.where((s) => !s.closed && s.isSleep).lastOrNull;
    if (open == null) return null;
    final closed = closeSpan(open.id, by: by, at: at);
    await _detachKit();
    _logLine('sleep kit off after ${open.id}');
    _set(_withAlarm(_withDrift(_status)));
    return closed;
  }

  Future<void> _detachKit() async {
    if (!_night.sleepKit) return;
    _night = _night.withSleepKit(on: false);
    final a = _alarm;
    _alarm = null;
    _alarmLast = null;
    if (a != null) await _closeAlarm(a).timeout(const Duration(seconds: 5), onTimeout: () {});
    final c = _cueWatch;
    _cueWatch = null;
    if (c != null) await _closeCues(c).timeout(const Duration(seconds: 5), onTimeout: () {});
    _live.release();
    await _closeScorer().timeout(const Duration(seconds: 5), onTimeout: () {});
    if (_drift != null) {
      _drift = null;
      _driftWall.stop();
    }
    unawaited(_save().catchError((Object _) {}));
  }

  /// The headband has been lost for a long time (DECISIONS 899, 1014). An open span is closed at the last data ("you
  /// were doing this" is no longer known) once the headband has been away for [RecorderTiming.spansAway] counted from
  /// the latest of: the last data, the span's own start (Sleep pressed while the headband is away is the owner saying
  /// "now"), and the owner's Undo of this rule ([_saidOnMs]). The sleep kit is detached when no sleep span stays
  /// open. After [RecorderTiming.stopAway] the recording stops itself (through the service when it gave [onGiveUp]).
  /// A process that has no data yet counts from its own start.
  void _away() {
    final last = _status.lastDataMs;
    final nowMs = _now().millisecondsSinceEpoch;
    final gone = nowMs - (last ?? (_awayFromMs ??= nowMs));
    final due = <String>[
      if (last != null && gone >= timing.spansAway.inMilliseconds)
        for (var k = 0; k < _spans.length; k++)
          if (!_spans[k].closed &&
              nowMs - max(last, max(_spans[k].start.millisecondsSinceEpoch, _saidOnMs[k] ?? 0)) >=
                  timing.spansAway.inMilliseconds)
            _spans[k].id,
    ];
    if (last != null && due.isNotEmpty) {
      final at = DateTime.fromMillisecondsSinceEpoch(last);
      _note('no data for ${timing.spansAway.inMinutes} min: what was marked ends at the last data');
      for (final id in due) {
        closeSpan(id, by: 'headband_off', at: at);
      }
      onSpansEnded?.call([for (final s in _spans) if (due.contains(s.id)) s]);
      if (!_spans.any((s) => !s.closed && s.isSleep)) unawaited(_detachKit());
      _set(_withAlarm(_withDrift(_status)));
    }
    if (gone < timing.stopAway.inMilliseconds || _gaveUp) return;
    _gaveUp = true;
    _note('no data for ${timing.stopAway.inHours} h: the recording stops itself');
    final giveUp = onGiveUp;
    giveUp == null ? unawaited(stop()) : giveUp();
  }

  bool _gaveUp = false;

  /// When the owner undid the 60-minute rule for a span (by its place in [_spans]; unix ms): the rule counts that
  /// span's 60 minutes from then.
  final Map<int, int> _saidOnMs = {};

  /// The spans opened before the first file set still need their line in its log and markers.
  bool _markOpenSpans = false;
  int? _awayFromMs;

  /// The recording's spans in order, as last written.
  List<Span> _spans = const [];

  List<Span> get spans => _spans;

  /// Opens a span of [kind] now (or [at]); the same kind already open is returned as it is. Its line is on storage
  /// before this returns (once the recording has its id: until the first file set opens it waits in the saved state).
  Span openSpan(String kind, {String source = 'owner_button', bool startedRecording = false, String? session, DateTime? at}) {
    final open = _spans.where((s) => !s.closed && s.kind == kind).lastOrNull;
    if (open != null) return open;
    final t = at ?? _now();
    final span = Span(
      id: '${_night.recording ?? '?'}-${_spans.length + 1}',
      kind: kind,
      label: spanLabels[kind],
      start: t,
      source: source,
      startedRecording: startedRecording,
      session: session,
    );
    _putSpan(span);
    // before the first file set there is no log to write into in time order: the line comes when the set opens
    if (_night.recording != null) _marker('span: $kind start', t);
    return span;
  }

  /// A span command of the screen applied (spans/activities.dart `openSpanCommand`, `closeSpanCommand`): the span it
  /// opened or closed, or null when it did nothing.
  Span? spanCommand(Map<Object?, Object?> data) {
    final kind = data['span_kind'], id = data['id'], by = data['by'], session = data['session'];
    if (data['op'] == 'open' && kind is String && kind.isNotEmpty) {
      return openSpan(kind, session: session is String ? session : null, startedRecording: data['started_recording'] == true);
    }
    if (data['op'] == 'close' && id is String) return closeSpan(id, by: by is String ? by : 'owner');
    if (data['op'] == 'undo_off') return undoHeadbandOff().firstOrNull;
    return null;
  }

  /// Closes the open span [id] now (or [at]); null when there is none.
  Span? closeSpan(String id, {String by = 'owner', DateTime? at}) {
    final s = _spans.where((s) => s.id == id && !s.closed).firstOrNull;
    if (s == null) return null;
    final t = at ?? _now();
    final closed = s.closedAt(t, by);
    _putSpan(closed);
    _marker('span: ${s.kind} end', t);
    return closed;
  }

  /// Stop of the recording. A sleep stretch ends now, by the Stop you pressed (`recording_stopped`). An activity that
  /// is still marked was left open (a session that is alive is ended by the screen before Stop, spans/activities.dart
  /// `recordingStops`): it ends at the recording's last sample and says so (`left_open`), so nobody reads its end as
  /// the time you stopped doing it (DECISIONS 1017).
  void _closeSpansAtStop() {
    final now = _now();
    final last = _status.lastDataMs;
    final lastData = last == null ? now : DateTime.fromMillisecondsSinceEpoch(last);
    for (final s in [..._spans]) {
      if (s.closed) continue;
      s.isSleep ? closeSpan(s.id, by: 'recording_stopped', at: now) : closeSpan(s.id, by: leftOpen, at: lastData);
    }
  }

  void _putSpan(Span span) {
    final i = _spans.indexWhere((s) => s.id == span.id);
    _spans = [
      for (var k = 0; k < _spans.length; k++) k == i ? span : _spans[k],
      if (i < 0) span,
    ];
    _spansChanged();
    if (_night.recording != null) _writeSpan(span);
    if (_begun) _set(_status);
  }

  void _spansChanged() {
    final made = _now();
    _night = _night.copyWith(spans: [for (final s in _spans) s.toLine(made)]);
    unawaited(_save().catchError((Object _) {}));
  }

  void _writeSpan(Span span) {
    try {
      spanLog?.write(span);
    } catch (e) {
      _logLine('could not write the span ${span.id}: ${_short(e)}; the recording goes on');
    }
  }

  /// The recording got its id (its first file set's stem): the spans opened before that get their ids and their lines.
  void _bindRecording(String id) {
    _night = _night.copyWith(recording: id);
    _spans = [for (var k = 0; k < _spans.length; k++) _spans[k].withId('$id-${k + 1}')];
    _spansChanged();
    for (final s in _spans) {
      _writeSpan(s);
    }
    _markOpenSpans = true;
    if (_begun) _set(_status);
  }
}

const Object _stopMarker = Object();

String _hm(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

String _short(Object e) {
  final s = e.toString().replaceAll('\n', ' ');
  return s.length > 160 ? '${s.substring(0, 160)}...' : s;
}

/// What the one live-sleep guard watches (DECISIONS 330): the smart alarm, the lucid cues and their shared model, all
/// held by the recorder itself.
final class _LiveSleep {
  const _LiveSleep();
}
