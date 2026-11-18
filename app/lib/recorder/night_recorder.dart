// The night loop, ported from scripts/record_night.py with its lessons (DECISIONS rows 17-21):
// - contact check at the start of the night;
// - a stalled stream is restarted; 40 s without data ends the run;
// - never an SDK call on a headband that is out of range (on the laptop that segfaulted the SDK);
// - after a drop: fresh scan, new sensor object, new file set (to_bdf.py joins a night's sets by time);
// - every SDK call has a deadline; one that blocks means the SDK is wedged, so the data is saved and the
//   app process is restarted (the phone's version of "exit and let record_night.sh start a fresh one");
// - the data is saved before every risky SDK call.
import 'dart:async';
import 'dart:io';

import 'chunk_writer.dart';
import 'contact.dart';
import 'headband.dart';
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
  List<String> _restartNotes = const [];
  int _misses = 0;

  /// Samples received per half hour of clock time (the screen's night strip).
  final Map<int, int> _slots = {};

  /// Headbands dropped while out of range. Kept, never touched again (no SDK call on a lost sensor).
  final List<Headband> abandoned = [];

  RecorderStatus get status => _status;
  bool get _stopping => _stopSignal.isCompleted;
  Future<void> get done => _done.future;

  /// Records until [stop]. [restartedBySystem]: Android restarted the service after the process died,
  /// so an active night is continued (new file set) instead of a new night begun.
  Future<void> run({required bool restartedBySystem}) async {
    try {
      await _begin(restartedBySystem);
      await _loop();
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
      _restartNotes = [
        'service restarted by Android after the app process ended',
        for (final r in await _exitReasons(prior.startMs)) 'previous process ended: $r',
      ];
    } else {
      _night = NightState(active: true, startMs: _now().millisecondsSinceEpoch);
    }
    await store.save(_night);
    _set(
      RecorderStatus(
        phase: Phase.searching,
        nightStartMs: _night.startMs,
        nightSamples: _night.samples,
        runs: _night.runs,
        contactOhms: _night.contactOhms,
        slots: Map.of(_slots),
        note: _restartNotes.isEmpty ? 'looking for the headband' : 'restarted by Android; reconnecting',
      ),
    );
  }

  Future<void> _loop() async {
    while (!_stopping) {
      _set(_status.copyWith(phase: _night.runs == 0 ? Phase.searching : Phase.reconnecting));
      final Headband? band;
      try {
        band = await _find();
      } on SdkStuck catch (e) {
        await _stuck(e, null);
        return;
      } catch (e) {
        _set(_status.copyWith(note: 'could not connect: ${_short(e)}'));
        await _pause(timing.notFoundWait);
        continue;
      }
      if (_stopping) {
        if (band != null) await _quietly(band.disconnectAndDispose);
        return;
      }
      if (band == null) {
        _misses++;
        _set(_status.copyWith(note: 'headband not found; is it on and charged?'));
        await _pause(_misses >= 6 ? timing.notFoundWaitLong : timing.notFoundWait);
        continue;
      }
      _misses = 0;
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

  Future<Headband?> _find() async {
    final search = finder.find(
      timing.scanFor,
      onFound: (name, rssi) {
        _set(_status.copyWith(phase: Phase.connecting, rssi: rssi, note: 'found $name; connecting'));
      },
    );
    final deadline = timing.scanFor + timing.connectTimeout;
    final first = await Future.any<Object?>([
      search.timeout(deadline, onTimeout: () => throw SdkStuck('scan and connect', deadline)),
      _stopSignal.future.then((_) => _stopMarker),
    ]);
    if (identical(first, _stopMarker)) {
      // A headband found after Stop must not stay connected.
      unawaited(search.then((b) => b?.disconnectAndDispose(), onError: (_) {}));
      return null;
    }
    return first as Headband?;
  }

  Future<_End> _session(Headband band, ChunkWriter w) async {
    _writer = w;
    _night = _night.copyWith(runs: _night.runs + 1);
    var lost = false;
    bool isLost() => lost;
    final rangeSub = band.rangeChanges.listen((inRange) => lost = lost || !inRange);
    StreamSubscription<List<Sample>>? sigSub;
    var end = _End.failed;
    try {
      for (final line in _restartNotes) {
        w.log(line);
      }
      _restartNotes = const [];
      final battery = await _battery(band);
      w.log(
        'connected ${band.name} ${band.address} serial ${band.serial} battery $battery% '
        'signal ${band.rssi} dBm',
      );
      await _logPhone(w);
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
      // Anything unexpected ends this run only; the night goes on with a fresh scan.
      w.log('unexpected error: ${_short(e)}');
    }
    await sigSub?.cancel();
    await rangeSub.cancel();
    return _finish(band, w, end, isLost);
  }

  void _onRows(ChunkWriter w, List<Sample> rows) {
    if (rows.isEmpty) return;
    final t = _now();
    w.addBatch(t, rows);
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
    if (!_stopping) w.log('the signal would not start; starting over with a fresh scan');
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
        w.log('headband out of range; saving and starting over with a fresh scan');
        return _End.lost;
      }
      if (++ticks % timing.ticksPerCheck != 0) continue;
      w.sync();
      await _save();
      final got = w.samplesReceived - lastTotal;
      lastTotal = w.samplesReceived;
      if (lost() || !await _inRange(band)) {
        w.log('headband out of range; saving and starting over with a fresh scan');
        return _End.lost;
      }
      final battery = await _battery(band) ?? _status.battery;
      _set(_status.copyWith(battery: battery));
      w.log('samples ${w.samplesWritten} (+$got) battery $battery%');
      stalled = got == 0 ? stalled + 1 : 0;
      if (stalled == 0) {
        if (_status.note != 'recording') _set(_status.copyWith(note: 'recording'));
        continue;
      }
      if (stalled >= timing.stallChecksToGiveUp) {
        w.log('still no data; starting over with a fresh scan');
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
    w.log('total samples ${w.samplesWritten}, ${(w.samplesWritten / sampleRateHz / 60).toStringAsFixed(1)} min');
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
      _night.copyWith(active: !(_stopping && _endNight), samples: _night.samples + live, slots: Map.of(_slots)),
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
