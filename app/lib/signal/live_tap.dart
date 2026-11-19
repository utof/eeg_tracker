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

/// The message kind of the night tap, both ways: from the screen `{'kind': 'signalTap', 'on': bool}` (the lease), from
/// the recorder `{'kind': 'signalTap', 'run': stem, 'batches': [[first, atMs, [packs], [volts 4 a sample]], ...]}`.
const String signalTapKind = 'signalTap';

/// The screen renews its lease this often while the Signal view shows the night.
const Duration nightTapRenew = Duration(seconds: 5);

/// Without a renewal the recorder stops sending after this long (the screen went away without saying so).
const Duration nightTapLease = Duration(seconds: 15);

/// The recorder gathers batches this long before one message (about 25 samples).
const Duration nightTapEvery = Duration(milliseconds: 100);

Map<String, Object?> nightTapLeaseMessage({required bool on}) => {'kind': signalTapKind, 'on': on};

/// Whether [data] from the screen is the tap's lease, and which way: null when it is something else.
bool? nightTapLeaseFrom(Object? data) =>
    data is Map && data['kind'] == signalTapKind && data['on'] is bool ? data['on'] as bool : null;

/// The recorder's side of the night tap: gathers what the recorder saves while the lease holds and hands it to [send]
/// every [nightTapEvery] ([flush], driven by the recorder's isolate). Never throws into the recording.
class NightTapSender {
  NightTapSender({required this.send, DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final void Function(Object message) send;
  final DateTime Function() _now;
  DateTime? _until;
  String? _run;
  final List<List<Object?>> _held = [];
  int _heldSamples = 0;

  /// The screen asked for the tap ([on]) or let it go.
  void lease({required bool on}) {
    _until = on ? _now().add(nightTapLease) : null;
    if (!on) {
      _held.clear();
      _heldSamples = 0;
    }
  }

  /// Whether the lease holds now.
  bool get on {
    final u = _until;
    if (u == null) return false;
    if (_now().isAfter(u)) {
      _until = null;
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
    final volts = <double>[
      for (final x in samples) ...[x.o1, x.o2, x.t3, x.t4],
    ];
    _held.add([first, arrival.millisecondsSinceEpoch, packs, volts]);
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
      _until = null;
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
    if (b is! List || b.length != 4) continue;
    final first = b[0], at = b[1], packs = b[2], volts = b[3];
    if (first is! int || at is! int || packs is! List || volts is! List) continue;
    if (volts.length != packs.length * 4 || packs.isEmpty) continue;
    if (!packs.every((p) => p is int) || !volts.every((v) => v is num)) continue;
    final uv = Float32List(volts.length);
    for (var i = 0; i < volts.length; i++) {
      uv[i] = (volts[i] as num).toDouble() * 1e6;
    }
    out.add(
      LiveBatch(
        arrival: DateTime.fromMillisecondsSinceEpoch(at),
        values: uv,
        channels: 4,
        packs: Int32List.fromList(packs.cast<int>()),
        first: first,
        run: run,
      ),
    );
  }
  return out;
}
