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
//   own alarm at the window's end never depends on it) and the lucid dream cues (lucid/live_cues.dart, DECISIONS
//   300-303), with the one live sleep model they share (sleep/night_scorer.dart, DECISIONS 330): one guard with a
//   memory limit too covers all three; an exception in the alarm or the cues costs only that one.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../alarm/live_alarm.dart';
import '../alarm/rule.dart';
import '../lucid/live_cues.dart';
import '../sleep/night_scorer.dart';
import 'battery.dart';
import 'chunk_writer.dart';
import 'contact.dart';
import 'headband.dart';
import 'live_drift.dart';
import 'nights.dart';
import 'packets.dart';
import 'status.dart';
import 'watch_guard.dart';

class RecorderTiming {
  const RecorderTiming({
    this.tick = const Duration(seconds: 1),
    this.ticksPerCheck = 10,
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
    this.phoneLogEvery = const Duration(minutes: 1),
    this.packetLogEvery = const Duration(minutes: 10),
    this.driftBudget = 0.02,
    this.driftBudgetAfter = const Duration(minutes: 10),
  });

  /// Buffered samples go to the files and a status goes to the screen this often.
  final Duration tick;

  /// Every this many ticks (10 s): fsync, sample count in the log, range and stall check.
  final int ticksPerCheck;
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

  /// Wait before each reconnect try after a drop; the last one repeats until the headband is back.
  final List<Duration> reconnectWaits;

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
class SdkStuck implements Exception {
  SdkStuck(this.what, this.after);
  final String what;
  final Duration after;

  @override
  String toString() => 'SDK call "$what" stuck for ${after.inSeconds} s';
}

enum _End { stopped, lost, stalled, failed, stuck }

class NightRecorder {
  NightRecorder({
    required this.finder,
    required this.dir,
    required this.store,
    required this.onStatus,
    required this.onStuck,
    this.probe,
    this.timing = const RecorderTiming(),
    this.watch = LiveDrift.new,
    this.scorer,
    this.alarmPlan,
    this.alarm,
    this.cues,
    this.liveLimits = const GuardLimits(),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final HeadbandFinder finder;
  final Directory dir;
  final NightStore store;
  final void Function(RecorderStatus status) onStatus;

  /// Called after the data is saved when an SDK call is stuck: restart the app process.
  final Future<void> Function(String reason) onStuck;
  final PhoneProbe? probe;
  final RecorderTiming timing;

  /// Makes the live drift-off detector; null: none.
  final DriftWatch Function()? watch;

  /// Tonight's smart alarm, for a new night (a restarted one keeps the plan saved with it); null: none.
  final AlarmPlan? alarmPlan;

  /// Makes the smart alarm's live model for a plan, an hour before its window; null: none (the phone's alarm alone).
  final AlarmWatch Function(AlarmPlan plan)? alarm;

  /// Makes tonight's lucid dream cues for the night's start (null from it: they are off); null: none.
  final CueFactory? cues;

  /// The night's one live sleep model, which the smart alarm and the lucid cues made by [alarm] and [cues] listen to
  /// (DECISIONS 330); the recorder feeds it. Null: none (an alarm or cues with a model of their own feed it).
  final NightScorer? scorer;

  /// The one guard over the smart alarm, the lucid cues and [scorer]: an exception in the scorer, more than its share
  /// of this isolate's time (the model's own thread and the scaling isolate are not counted: they do not hold the
  /// recorder up) or the app growing by more than its limit since the guard started switches all of them off for the
  /// rest of the process with one log line (the phone's alarm still rings at the window's end).
  final GuardLimits liveLimits;
  late final WatchGuard<_LiveSleep> _live = WatchGuard(limits: liveLimits, onStop: _liveStopped);

  /// Tonight's lucid dream cues while they run.
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
  int _misses = 0;

  /// Log lines waiting for the next run's `.log` (no closed run of tonight to put them in), with their times.
  List<(DateTime, String)> _notes = const [];

  /// The `.log` of the last closed run: drops and reconnect tries between runs go there.
  File? _lastLog;

  /// The drop being recovered from, and how the headband came back.
  ({int? lastDataMs, String? stem, String why})? _drop;
  ({String how, int tryNo})? _via;

  /// When the phone battery line was last written (unix ms).
  int _batteryLoggedMs = 0;

  /// Packet numbers of tonight; [_packetsLoggedMs] is when its line was last written (unix ms).
  PacketAccount _packets = PacketAccount();
  int _packetsLoggedMs = 0;

  /// Reconnect tries since the last run that recorded anything.
  int _tries = 0;

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
      await _begin(restartedBySystem);
      await _loop();
      if (_stopping && _endNight) await _logNightEnd();
    } finally {
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
    _writer?.close();
    await _save();
  }

  Future<void> _begin(bool restartedBySystem) async {
    NightState prior;
    try {
      prior = await store.load();
    } catch (_) {
      prior = const NightState(); // nothing to continue: a new night
    }
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
      _notes = [for (final n in notes) (t, n)];
      _lastLog = _newestLog(prior.startMs);
      final stem = _lastLog?.uri.pathSegments.last.replaceFirst(RegExp(r'\.log$'), '');
      if (prior.band != null) _drop = (lastDataMs: null, stem: stem, why: 'app process restarted');
    } else {
      final plan = alarmPlan;
      _night = NightState(
        active: true,
        startMs: _now().millisecondsSinceEpoch,
        alarmEndMs: plan?.endMs,
        alarmWindowMin: plan?.windowMin,
      );
      _startDrift();
      final t = _now();
      // the drift-off line first, then any line _startDrift kept (hands-free), then the smart alarm's
      _notes = [
        if (_drift != null) (t, 'drift-off detector on; lights off counts from the first sample until Lights off'),
        ..._notes,
        if (plan != null)
          (
            t,
            'smart alarm set: wake by ${_hm(plan.endMs)}, window from ${_hm(plan.startMs)}; the sleep model starts at '
                '${_hm(plan.scoreFromMs)}${alarm == null ? ' (not in this build: the phone\'s alarm alone)' : ''}',
          ),
      ];
    }
    _packets = PacketAccount(_night.packets);
    _packetsLoggedMs = _now().millisecondsSinceEpoch;
    _startCues();
    await _save();
    _set(
      RecorderStatus(
        phase: Phase.searching,
        nightStartMs: _night.startMs,
        nightSamples: _night.samples,
        runs: _night.runs,
        contactOhms: _night.contactOhms,
        slots: Map.of(_slots),
        note: restartedBySystem && prior.active ? 'restarted by Android; reconnecting' : 'looking for the headband',
      ).withDrift(lightsOffMs: _night.lightsOffMs).withAlarm(_alarmStatus()),
    );
    _begun = true;
    final early = _earlyLightsOff;
    if (early != null) lightsOff(at: early);
    if (_earlyAlarmOff) alarmOff();
  }

  Future<void> _loop() async {
    while (!_stopping) {
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
        w = ChunkWriter.open(dir, _now());
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
        await _runFailed(w, e);
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

  /// One try to get tonight's headband back after a drop or a process restart: directly by its address
  /// after a growing wait; every [RecorderTiming.scanEvery]-th try, or every try once direct connections
  /// are off, a short scan instead.
  Future<Headband?> _reconnectTry() async {
    final id = _night.band!;
    final n = ++_tries;
    final waits = timing.reconnectWaits;
    _set(_status.copyWith(phase: Phase.reconnecting));
    await _pause(waits.isEmpty ? Duration.zero : waits[min(n, waits.length) - 1]);
    if (_stopping) return null;
    final scan = _night.directOff || timing.scanEvery <= 1 || n % timing.scanEvery == 0;
    final how = scan ? 'scan' : 'direct to ${id.address}';
    final t0 = _now();
    String took() => '${(_now().difference(t0).inMilliseconds / 1000).toStringAsFixed(1)} s';
    try {
      final band = scan ? await _scan(timing.rescanFor) : await _direct(id);
      if (band != null) {
        _via = (how: scan ? 'scan' : 'direct', tryNo: n);
        _note('reconnect try $n ($how): connected after ${took()}');
        return band;
      }
      if (_stopping) return null;
      _note('reconnect try $n ($how): not found after ${took()}');
    } on SdkStuck {
      _note('reconnect try $n ($how): no answer for ${took()} (SDK stuck)');
      rethrow;
    } catch (e) {
      _note('reconnect try $n ($how): failed after ${took()}: ${_short(e)}');
    }
    _set(_status.copyWith(note: 'headband not found yet (try $n); trying again'));
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

  Future<_End> _session(Headband band, ChunkWriter w) async {
    _writer = w;
    _night = _night.copyWith(runs: _night.runs + 1, band: band.id);
    _packets.startRun();
    var lost = false;
    bool isLost() => lost;
    final rangeSub = band.rangeChanges.listen((inRange) => lost = lost || !inRange);
    // Our own connection writes its drops, reconnects and lost packets into the run's log, and says when the
    // headband's packet numbers start again inside the run (BrainBit's SDK has no such notes).
    final notesSub = band is BandNotes
        ? (band as BandNotes).notes.listen((n) {
            if (n.newStream) _packets.startRun();
            if (n.line != null && !w.isClosed) w.log(n.line!);
          })
        : null;
    StreamSubscription<List<Sample>>? sigSub;
    var end = _End.failed;
    try {
      for (final (t, line) in _notes) {
        w.log(line, at: t);
      }
      _notes = const [];
      for (final (t, text) in _pendingMarkers) {
        _marker(text, t);
      }
      _pendingMarkers = const [];
      _logReconnected(w);
      await _save();
      final battery = await _battery(band);
      final rssi = band.rssi;
      w.log(
        'connected ${band.name} ${band.address} serial ${band.serial} battery $battery% '
        'signal ${rssi == null ? 'unknown (no scan)' : '$rssi dBm'}',
      );
      await _logPhone(w);
      await _logBattery(w);
      _set(
        _status.copyWith(
          phase: Phase.connecting,
          rssi: band.rssi,
          battery: battery,
          runs: _night.runs,
          note: 'connected',
        ),
      );
      if (!_night.contactTried) await _contactCheck(band, w);
      sigSub = band.signal.listen((rows) => _onRows(w, rows));
      if (await _startSignal(band, w, isLost)) {
        w.log('recording started, 250 Hz');
        _set(_status.copyWith(phase: Phase.recording, note: 'recording'));
        end = await _record(band, w, isLost);
      } else {
        end = lost ? _End.lost : _End.failed;
      }
    } on SdkStuck catch (e) {
      await _cancel([sigSub, rangeSub, notesSub]);
      await _stuck(e, w);
      return _End.stuck;
    } catch (e) {
      // Anything unexpected ends this run only; the night goes on with a reconnect.
      w.log('unexpected error: ${_short(e)}');
    }
    await _cancel([sigSub, rangeSub, notesSub]);
    return _finish(band, w, end, isLost);
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
    w.log(
      'reconnected (${v.how}, try ${v.tryNo}) after a drop (${d.why}); previous run ${d.stem ?? 'unknown'}, '
      'last data ${last == null ? 'unknown' : logTime(DateTime.fromMillisecondsSinceEpoch(last))}$gap',
    );
  }

  void _onRows(ChunkWriter w, List<Sample> rows) {
    if (rows.isEmpty) return;
    final t = _now();
    final firstOfFile = w.samplesReceived == 0;
    w.addBatch(t, rows);
    _packets.add(rows);
    final ms = t.millisecondsSinceEpoch;
    final slot = ms ~/ slotMs;
    _slots[slot] = (_slots[slot] ?? 0) + rows.length;
    _status = _status.copyWith(nightSamples: _status.nightSamples + rows.length, lastDataMs: ms, slots: _slots);
    if (_drift != null) {
      _guarded((d) {
        d.add(t, rows, firstOfFile: firstOfFile);
        for (final text in d.takeEvents()) {
          _marker(text, t);
        }
      });
    }
    if (_alarm == null && !_alarmMade) _startAlarm(t);
    _live.run((_) {
      scorer?.add(t, rows, firstOfFile: firstOfFile); // an exception here reaches the guard: all of it off
      _scorerLines();
      _alarmCall((a) => a.add(t, rows, firstOfFile: firstOfFile), t);
      _cueCall((c) => c.add(t, rows, firstOfFile: firstOfFile), t);
    });
    _liveTidy();
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

  /// A call into the lucid cues: their exception switches them off alone, with one log line.
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
    final who = [if (a != null) 'smart alarm', if (c != null) 'lucid cues'];
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

  /// Tonight's lucid dream cues, when they are on; a failure here costs only the cues.
  void _startCues() {
    final make = cues;
    if (make == null) return;
    try {
      final c = make(_night.startMs);
      if (c == null) return;
      _cueWatch = c;
      if (!c.finished) _liveStart('lucid cues'); // off from the start (no loudness yet): let go at the next batch
      for (final text in c.takeEvents()) {
        _marker(text, _now());
      }
    } catch (e) {
      _cueLine('lucid cues could not start: ${_short(e)}; the recording goes on');
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
    _cueLine('lucid cues stopped: $why; the recording goes on');
    _offCues(why, c);
  }

  void _offCues(String why, CueWatch c) {
    try {
      if (c is LiveCues) c.off('The recorder stopped them ($why).');
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
    _night = _night.copyWith(lightsOffMs: t.millisecondsSinceEpoch);
    unawaited(_save().catchError((Object _) {})); // the next 10 s check saves it again
    _marker(lightsOffMarker, t);
    if (_drift == null && !_driftUsed) _startDrift();
    _guarded((d) => d.lightsOff(t));
    _set(_withAlarm(_withDrift(_status)));
  }

  void _startDrift() {
    final make = watch;
    if (make == null) return;
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
    if (plan == null || make == null || _night.alarmOff) return;
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
    final f = File('${log.path.substring(0, log.path.length - 4)}.f32');
    return f.existsSync() ? f.lengthSync() ~/ recordBytes : 0;
  }

  Future<void> _contactCheck(Headband band, ChunkWriter w) async {
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
    _night = _night.copyWith(contactTried: true, contactOhms: last.isEmpty ? const {} : ohms);
    if (last.isEmpty) {
      w.log('contact check: no resistance data arrived');
    } else {
      w.log('contact ohms ${ohmsLine(ohms)}');
      _set(_status.copyWith(contactOhms: ohms));
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

  Future<_End> _record(Headband band, ChunkWriter w, bool Function() lost) async {
    var ticks = 0;
    var lastTotal = w.samplesReceived;
    var stalled = 0;
    while (true) {
      await _pause(timing.tick);
      w.append();
      _set(_withAlarm(_withDrift(_status)));
      if (_stopping) return _End.stopped;
      if (lost()) {
        w.log('headband out of range; saving');
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
        w.log('headband out of range; saving');
        return _End.lost;
      }
      final battery = await _battery(band) ?? _status.battery;
      _set(_status.copyWith(battery: battery));
      w.log('samples ${w.samplesWritten} (+$got) battery $battery%');
      if (_now().millisecondsSinceEpoch - _batteryLoggedMs >= timing.phoneLogEvery.inMilliseconds) {
        await _logBattery(w);
      }
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
    _night = _night.copyWith(samples: _night.samples + w.samplesWritten);
    _status = _status.copyWith(nightSamples: _night.samples);
    _logPackets(w);
    w.log('total samples ${w.samplesWritten}, ${(w.samplesWritten / sampleRateHz / 60).toStringAsFixed(1)} min');
    if (end != _End.stopped) _logDrop(w, end);
    if (w.samplesWritten > 0) _tries = 0; // a run that recorded something restarts the waits from the shortest
    try {
      if (end == _End.lost || lost() || !await _inRange(band)) {
        abandoned.add(band);
        if (end != _End.lost) w.log('headband out of range; leaving it without SDK calls');
      } else {
        try {
          await _sdk('stop signal', band.stopSignal);
          w.log('stopped, battery ${await _battery(band)}%');
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
  void _logDrop(ChunkWriter w, _End end) {
    final why = switch (end) {
      _End.lost => 'out of range',
      _End.stalled => 'no data',
      _ => 'run failed',
    };
    final last = _status.lastDataMs;
    w.log(
      'drop ($why); last data ${last == null ? 'none' : logTime(DateTime.fromMillisecondsSinceEpoch(last))}; reconnecting',
    );
    _drop = (lastDataMs: last, stem: w.stem, why: why);
  }

  /// A line for the night's log from outside the loop (Share on Wi-Fi going on or off): into the open run's
  /// `.log`, else as [_note]. Never throws.
  void note(String message) => _logLine(message);

  /// A line for the night's log between runs, with its own time: into the last closed run's `.log`, or,
  /// before tonight has one, kept for the next run's `.log`.
  void _note(String message) {
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
      _night = _night.copyWith(samples: _night.samples + w.samplesWritten);
      w.log('$e; saved${_stopping ? '' : ', restarting the app process'}');
      w.close();
    }
    await _save();
    if (_stopping) return;
    _set(_status.copyWith(phase: Phase.reconnecting, note: 'Bluetooth stuck; restarting the recorder'));
    await onStuck(e.toString());
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
  Future<int?> _battery(Headband band) async {
    try {
      return await _sdk('battery', band.battery);
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
      final who = _liveWho.length > 1
          ? 'smart alarm and lucid cues, one sleep model:'
          : _liveWho.contains('smart alarm')
          ? 'smart alarm: sleep model'
          : 'lucid cues:';
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
  Future<void> _save() async {
    final w = _writer;
    final live = w == null || w.isClosed ? 0 : w.samplesWritten;
    try {
      await store.save(
        _night.copyWith(
          active: !(_stopping && _endNight),
          samples: _night.samples + live,
          slots: Map.of(_slots),
          packets: _packets.counts,
        ),
      );
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
    _status = s;
    onStatus(s);
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
