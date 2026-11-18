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
// - the data is saved before every risky SDK call.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'battery.dart';
import 'chunk_writer.dart';
import 'contact.dart';
import 'headband.dart';
import 'nights.dart';
import 'packets.dart';
import 'status.dart';

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
    await _done.future.timeout(timing.stopTimeout, onTimeout: () {});
    _writer?.close();
    await _save();
  }

  Future<void> _begin(bool restartedBySystem) async {
    final prior = await store.load();
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
      final t = _now();
      _notes = [for (final n in notes) (t, n)];
      _lastLog = _newestLog(prior.startMs);
      final stem = _lastLog?.uri.pathSegments.last.replaceFirst(RegExp(r'\.log$'), '');
      if (prior.band != null) _drop = (lastDataMs: null, stem: stem, why: 'app process restarted');
    } else {
      _night = NightState(active: true, startMs: _now().millisecondsSinceEpoch);
    }
    _packets = PacketAccount(_night.packets);
    _packetsLoggedMs = _now().millisecondsSinceEpoch;
    await store.save(_night);
    _set(
      RecorderStatus(
        phase: Phase.searching,
        nightStartMs: _night.startMs,
        nightSamples: _night.samples,
        runs: _night.runs,
        contactOhms: _night.contactOhms,
        slots: Map.of(_slots),
        note: _notes.isEmpty ? 'looking for the headband' : 'restarted by Android; reconnecting',
      ),
    );
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
      if (await _session(band, w) == _End.stuck) return;
    }
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
    StreamSubscription<List<Sample>>? sigSub;
    var end = _End.failed;
    try {
      for (final (t, line) in _notes) {
        w.log(line, at: t);
      }
      _notes = const [];
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
      await sigSub?.cancel();
      await rangeSub.cancel();
      await _stuck(e, w);
      return _End.stuck;
    } catch (e) {
      // Anything unexpected ends this run only; the night goes on with a reconnect.
      w.log('unexpected error: ${_short(e)}');
    }
    await sigSub?.cancel();
    await rangeSub.cancel();
    return _finish(band, w, end, isLost);
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
    w.addBatch(t, rows);
    _packets.add(rows);
    final ms = t.millisecondsSinceEpoch;
    final slot = ms ~/ slotMs;
    _slots[slot] = (_slots[slot] ?? 0) + rows.length;
    _status = _status.copyWith(nightSamples: _status.nightSamples + rows.length, lastDataMs: ms, slots: _slots);
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
      _set(_status);
      if (_stopping) return _End.stopped;
      if (lost()) {
        w.log('headband out of range; saving');
        return _End.lost;
      }
      if (++ticks % timing.ticksPerCheck != 0) continue;
      w.sync();
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
      await _restartStream(band, w, stalled);
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
    w.sync();
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
  void note(String message) {
    try {
      final w = _writer;
      if (w != null && !w.isClosed) {
        w.log(message);
      } else {
        _note(message);
      }
    } catch (_) {}
  }

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
      w.sync();
      _night = _night.copyWith(samples: _night.samples + w.samplesWritten);
      w.log('$e; saved${_stopping ? '' : ', restarting the app process'}');
      w.close();
    }
    await _save();
    if (_stopping) return;
    _set(_status.copyWith(phase: Phase.reconnecting, note: 'Bluetooth stuck; restarting the recorder'));
    await onStuck(e.toString());
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
    await _save();
  }

  Future<void> _quietly(Future<void> Function() call) async {
    try {
      await call().timeout(timing.sdkTimeout);
    } catch (_) {}
  }

  /// Persists the night. It stays "active" unless the user ended it, so a restart continues it.
  Future<void> _save() async {
    final w = _writer;
    final live = w == null || w.isClosed ? 0 : w.samplesWritten;
    await store.save(
      _night.copyWith(
        active: !(_stopping && _endNight),
        samples: _night.samples + live,
        slots: Map.of(_slots),
        packets: _packets.counts,
      ),
    );
  }

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

String _short(Object e) {
  final s = e.toString().replaceAll('\n', ' ');
  return s.length > 160 ? '${s.substring(0, 160)}...' : s;
}
