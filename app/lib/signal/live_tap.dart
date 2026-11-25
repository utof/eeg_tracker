// How the Signal view reads along with whatever already holds the headband, instead of opening a second connection
// (DECISIONS 595). Two taps:
// - [LiveTap], in the screen's isolate: every daytime session's headband link (dream/band_link.dart, the one place the
//   sessions reach the headband) says when it holds a headband, hands over each batch and its contact reading;
// - the night tap, across the isolate border: while the Signal view renews its lease, the night recorder's isolate sends
//   the batches it saves to the screen ([NightTapSender], wired in recorder/recorder_service.dart; the screen's side
//   is [nightTapBatches]). The recorder never waits for the screen and never sees the tap fail.
// Neither tap ever switches the headband into resistance mode: during a night or a session the Signal view shows the
// last contact reading instead.
import 'dart:async';
import 'dart:typed_data';

import '../logs/files.dart' show logTime;
import '../logs/metrics.dart' show Metrics;
import '../recorder/chunk_writer.dart' show Sample;
import 'live_signal.dart';

/// The screen isolate's tap on the sessions' headband links.
abstract final class LiveTap {
  static final Set<Object> _holders = {};
  static final StreamController<LiveBatch> _batches = StreamController<LiveBatch>.broadcast();
  static Map<String, double?> _ohms = const {};
  static DateTime? _ohmsAt;

  /// Links that hold a headband now (a session's, or the Signal view's own).
  static bool heldBy(Object link) => _holders.contains(link);

  /// Whether anyone but [self] holds a headband.
  static bool heldByOther([Object? self]) => _holders.any((h) => !identical(h, self));

  static void hold(Object link) => _holders.add(link);

  static void release(Object link) => _holders.remove(link);

  /// Every batch any link hands its session (BrainBit's record, µV), while someone listens.
  static Stream<LiveBatch> get batches => _batches.stream;

  /// A link's batch; costs nothing while nobody listens.
  static void publish(DateTime arrival, List<Sample> batch) {
    if (!_batches.hasListener || batch.isEmpty) return;
    _batches.add(LiveBatch.fromSamples(arrival, batch));
  }

  /// A link's contact reading (ohms per channel, null where none).
  static void contact(Map<String, double?> ohms, DateTime at) {
    if (ohms.isEmpty) return;
    _ohms = Map.unmodifiable(ohms);
    _ohmsAt = at;
    Metrics.write({'t': logTime(at), 'kind': 'contact', 'source': 'session', 'ohms': ohms}); // contact over the day
  }

  /// The newest contact reading of any link in this app run, and when it was taken.
  static ({Map<String, double?> ohms, DateTime? at}) get lastContact => (ohms: _ohms, at: _ohmsAt);

  /// Forgets everything (each test starts as a fresh app process).
  static void reset() {
    _holders.clear();
    _ohms = const {};
    _ohmsAt = null;
  }
}

/// The message kind of the night tap, both ways: from the screen `{'kind': 'signalTap', 'on': bool, 'user': word}` (the
/// lease of one user: the panel, the Signal view, the activities that ride on the recording), from the recorder
/// `{'kind': 'signalTap', 'run': stem, 'batches': [[first, atMs, [packs], [volts, n a sample], n], ...]}`. While any
/// lease holds, every sample the recorder saves is sent, in order, with its packet number (Record first, DECISIONS 897).
const String signalTapKind = 'signalTap';

/// The screen renews its lease this often while the Signal view shows the night.
const Duration nightTapRenew = Duration(seconds: 5);

/// Without a renewal the recorder stops sending after this long (the screen went away without saying so).
const Duration nightTapLease = Duration(seconds: 15);

/// The recorder gathers batches this long before one message (about 25 samples).
const Duration nightTapEvery = Duration(milliseconds: 100);

/// The tap's users: each holds a lease of its own, so one letting go never cuts the stream of another.
const String tapPanel = 'panel', tapSignal = 'signal', tapRide = 'ride';

Map<String, Object?> nightTapLeaseMessage({required bool on, String user = tapPanel}) => {
  'kind': signalTapKind,
  'on': on,
  'user': user,
};

/// Whether [data] from the screen is the tap's lease, whose and which way: null when it is something else. A lease
/// without a user (a screen of before) is the panel's.
({bool on, String user})? nightTapLeaseFrom(Object? data) {
  if (data is! Map || data['kind'] != signalTapKind || data['on'] is! bool) return null;
  final user = data['user'];
  return (on: data['on'] as bool, user: user is String && user.isNotEmpty ? user : tapPanel);
}

/// The recorder's side of the night tap: gathers what the recorder saves while the lease holds and hands it to [send]
/// every [nightTapEvery] ([flush], driven by the recorder's isolate). Never throws into the recording.
class NightTapSender {
  NightTapSender({required this.send, DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final void Function(Object message) send;
  final DateTime Function() _now;
  final Map<String, DateTime> _until = {};
  String? _run;
  final List<List<Object?>> _held = [];
  int _heldSamples = 0;

  /// [user] asked for the tap ([on]), renewed it, or let it go. What was gathered goes out first when the last one
  /// lets go: a user never loses samples it held a lease for.
  void lease({required bool on, String user = tapPanel}) {
    if (on) {
      _until[user] = _now().add(nightTapLease);
    } else if (_until.remove(user) != null && _until.isEmpty) {
      flush();
    }
  }

  /// Whether any lease holds now.
  bool get on {
    if (_until.isEmpty) return false;
    final now = _now();
    _until.removeWhere((_, u) => now.isAfter(u));
    if (_until.isEmpty) {
      _held.clear();
      _heldSamples = 0;
      return false;
    }
    return true;
  }

  /// A batch as the recorder buffers it (ChunkWriter's tap): its run, the index of its first sample, when it arrived.
  void add(String run, int first, DateTime arrival, List<Sample> samples) {
    if (!on || samples.isEmpty) return;
    if (_run != null && run != _run) flush();
    _run = run;
    // plain lists: the recorder runs in another engine, whose messages may carry only plain values
    final packs = <int>[for (final x in samples) x.pack];
    final n = samples.first.volts.length; // one recording: every sample as wide as its header says
    final volts = <double>[
      for (final x in samples) ...x.volts,
    ];
    _held.add([first, arrival.millisecondsSinceEpoch, packs, volts, n]);
    _heldSamples += samples.length;
    // a stalled timer never lets the list grow without end: about 4 s at most
    if (_heldSamples > 1000) flush();
  }

  /// Sends what was gathered as one message.
  void flush() {
    if (_held.isEmpty) return;
    final msg = {'kind': signalTapKind, 'run': _run, 'batches': List<Object?>.of(_held)};
    _held.clear();
    _heldSamples = 0;
    try {
      send(msg);
    } catch (_) {
      // the screen is gone: the tap ends, the recording goes on
      _until.clear();
    }
  }
}

/// The screen's side: the batches in a night tap message (µV), or null when [data] is something else. A damaged entry
/// is skipped.
List<LiveBatch>? nightTapBatches(Object? data) {
  if (data is! Map || data['kind'] != signalTapKind || data['batches'] is! List) return null;
  final run = data['run'] is String ? data['run'] as String : null;
  final out = <LiveBatch>[];
  for (final b in data['batches'] as List) {
    if (b is! List || b.length != 5) continue;
    final first = b[0], at = b[1], packs = b[2], volts = b[3], n = b[4];
    if (first is! int || at is! int || packs is! List || volts is! List || n is! int || n < 1) continue;
    if (volts.length != packs.length * n || packs.isEmpty) continue;
    if (!packs.every((p) => p is int) || !volts.every((v) => v is num)) continue;
    final uv = Float32List(volts.length);
    for (var i = 0; i < volts.length; i++) {
      uv[i] = (volts[i] as num).toDouble() * 1e6;
    }
    out.add(
      LiveBatch(
        arrival: DateTime.fromMillisecondsSinceEpoch(at),
        values: uv,
        channels: n,
        packs: Int32List.fromList(packs.cast<int>()),
        first: first,
        run: run,
      ),
    );
  }
  return out;
}

/// The screen's side for the activities that ride on the recording: the samples in a night tap message as the
/// headband gave them (volts, any number of channels), batch by batch in order; null when [data] is something else.
List<List<Sample>>? nightTapSamples(Object? data) {
  if (data is! Map || data['kind'] != signalTapKind || data['batches'] is! List) return null;
  final out = <List<Sample>>[];
  for (final b in data['batches'] as List) {
    if (b is! List || b.length != 5) continue;
    final packs = b[2], volts = b[3], n = b[4];
    if (packs is! List || volts is! List || n is! int || n < 1) continue;
    if (volts.length != packs.length * n || packs.isEmpty) continue;
    if (!packs.every((p) => p is int) || !volts.every((v) => v is num)) continue;
    out.add([
      for (var i = 0; i < packs.length; i++)
        Sample(packs[i] as int, Float64List.fromList([for (var c = 0; c < n; c++) (volts[i * n + c] as num).toDouble()])),
    ]);
  }
  return out;
}
