// A night started while the headband is already connected and streaming in the screen's engine (DECISIONS 856). The
// SDK's headband object cannot cross to the recorder's engine (each engine has its own plugin instance, DECISIONS 451),
// so the connection is lent: the owner (connection.dart) keeps it and sends every batch to the recorder, which records
// it through a [LentBand] exactly as it records a headband of its own. No search, no new connection, no new contact
// check: the reading already in force comes along with its time.
// The lend ends at the first trouble: the headband drops ([lendLost]), the lender is gone, no batch for the recorder's
// stall time while the lender lives, or the run ends for any other reason. Then the recorder takes the headband over
// on its own proven path (direct to its address, every third try a scan, DECISIONS 49), after telling the owner to
// let go ([LendMessage.take]) and waiting at most [LendFinder.takeWait] for its answer. A night that is stopped while
// lent leaves the connection with the owner ([LendMessage.endKeep]).
// The lender is gone (DECISIONS 1029): while it lends, the owner says [lendAlive] every second, whether or not samples
// come. A recorder that hears nothing at all for [LendFinder.lenderGoneAfter] knows the screen's engine no longer
// exists (the app was swiped away; nothing closes a channel then) and reconnects at once, without restarting a
// stream nobody sends and without waiting for an answer to "let go". A lender that lives and a silent headband is the
// other case: the recorder restarts the stream as it does on its own connection.
// Messages are plain maps (`kind: lend`): they cross the isolate port.
import 'dart:async';
import 'dart:typed_data';

import '../recorder/chunk_writer.dart' show Sample;
import '../recorder/headband.dart';

const String lendKind = 'lend';

/// What the screen's engine saves for the recorder at Start.
class LendOffer {
  const LendOffer({required this.band, required this.names, this.ohms = const {}, this.ohmsAtMs, this.gauge});
  final BandId band;
  final List<String> names;

  /// The contact reading in force (empty: none; the recorder then checks contact itself on its first own connection).
  final Map<String, double?> ohms;
  final int? ohmsAtMs;

  /// The headband's battery gauge at the offer.
  final int? gauge;

  Map<String, Object?> toJson() => {
    'band': band.toJson(),
    'names': names,
    'ohms': {for (final e in ohms.entries) e.key: e.value == null || !e.value!.isFinite ? null : e.value},
    'ohmsAtMs': ohmsAtMs,
    'gauge': gauge,
    'madeMs': DateTime.now().millisecondsSinceEpoch,
  };

  /// Null unless [j] is an offer made within the last [maxAge] (an old one is from a start that never happened).
  static LendOffer? fromJson(Object? j, {DateTime? now, Duration maxAge = const Duration(seconds: 30)}) {
    if (j is! Map) return null;
    final band = BandId.fromJson(j['band']);
    final names = j['names'], ohms = j['ohms'], made = j['madeMs'];
    if (band == null || names is! List || made is! int) return null;
    final age = (now ?? DateTime.now()).millisecondsSinceEpoch - made;
    if (age < 0 || age > maxAge.inMilliseconds) return null;
    return LendOffer(
      band: band,
      names: [for (final n in names) '$n'],
      ohms: ohms is Map ? {for (final e in ohms.entries) '${e.key}': (e.value as num?)?.toDouble()} : const {},
      ohmsAtMs: (j['ohmsAtMs'] as num?)?.toInt(),
      gauge: (j['gauge'] as num?)?.toInt(),
    );
  }
}

// ---- the screen to the recorder ------------------------------------------------------------------------------------

/// One batch: the packet numbers, the volts (channel by channel per sample) and the channel count; [gauge] rides along.
Map<String, Object?> lendBatch(List<Sample> batch, {int? gauge}) {
  final n = batch.first.volts.length;
  return {
    'kind': lendKind,
    'packs': <int>[for (final s in batch) s.pack],
    'volts': <double>[
      for (final s in batch) ...s.volts,
    ],
    'n': n,
    'gauge': ?gauge,
  };
}

/// The headband went out of range, or nothing is lent (any more).
const Map<String, Object> lendLost = {'kind': lendKind, 'lost': true};

/// The lender's sign of life, on every tick of the owner's own clock (a second) while it lends.
const Map<String, Object> lendAlive = {'kind': lendKind, 'alive': true};

/// The owner has let the headband go: the recorder may reach it.
const Map<String, Object> lendReleased = {'kind': lendKind, 'released': true};

// ---- the recorder to the screen ------------------------------------------------------------------------------------

enum LendMessage {
  /// The recorder listens: send the batches (again: the stream stalled, restart it).
  start,

  /// The run ended while lent (the night was stopped): keep the connection.
  endKeep,

  /// The recorder reaches the headband itself now: let it go and answer [lendReleased].
  take,
}

Map<String, Object> lendToScreen(LendMessage m) => {'kind': lendKind, 'say': m.name};

/// The recorder's lend message in [data], or null when it is something else.
LendMessage? lendFromNight(Object? data) {
  if (data is! Map || data['kind'] != lendKind) return null;
  return LendMessage.values.where((m) => m.name == data['say']).firstOrNull;
}

/// The samples of a [lendBatch] message, or null (not one, or damaged).
List<Sample>? _samples(Map<Object?, Object?> m) {
  final packs = m['packs'], volts = m['volts'], n = m['n'];
  if (packs is! List || volts is! List || n is! int || n < 1 || packs.isEmpty) return null;
  if (volts.length != packs.length * n) return null;
  final out = <Sample>[];
  for (var i = 0; i < packs.length; i++) {
    final p = packs[i];
    if (p is! int) return null;
    final v = Float64List(n);
    for (var c = 0; c < n; c++) {
      final x = volts[i * n + c];
      if (x is! num) return null;
      v[c] = x.toDouble();
    }
    out.add(Sample(p, v));
  }
  return out;
}

/// The recorder's finder for a night that may start lent: the first search returns the lent connection when there is an
/// offer; every later try (and every try without one) goes to [inner], after the owner was told to let go.
class LendFinder implements HeadbandFinder {
  LendFinder({
    required this.inner,
    required this.toScreen,
    LendOffer? offer,
    this.takeWait = const Duration(seconds: 4),
    this.lenderGoneAfter = const Duration(seconds: 4),
    this.lenderCheckEvery = const Duration(seconds: 1),
  }) : _offer = offer; // ignore: prefer_initializing_formals

  final HeadbandFinder inner;
  final void Function(Object message) toScreen;

  /// How long the recorder waits for the owner's "released" before it reaches the headband anyway.
  final Duration takeWait;

  /// Nothing at all from the lender (no batch, no [lendAlive]) for this long, counted in looks [lenderCheckEvery]
  /// apart: it is gone. Four missed signs of life; the real phone's 59-second gap was three stream restarts on such
  /// a connection (2026-11-25).
  final Duration lenderGoneAfter, lenderCheckEvery;
  LendOffer? _offer;
  LentBand? _lent;
  bool _taken = false;
  Completer<void>? _released;

  /// The offer was used: this night began on a lent connection.
  bool get wasLent => _lent != null;

  /// Everything the screen sends with `kind: lend`.
  void onMessage(Object? data) {
    if (data is! Map || data['kind'] != lendKind) return;
    if (data['released'] == true) {
      final r = _released;
      if (r != null && !r.isCompleted) r.complete();
      return;
    }
    final band = _lent;
    if (band == null || band._ended) return;
    band._heard();
    if (data['lost'] == true) return band._lost();
    final g = data['gauge'];
    if (g is int) band._gauge = g;
    final samples = _samples(data);
    if (samples != null) band._add(samples);
  }

  /// The owner is told to let go, once; waits for its answer at most [takeWait] (it may be gone).
  Future<void> _take() async {
    if (_taken) return;
    _taken = true;
    _offer = null;
    final r = _released = Completer<void>();
    try {
      toScreen(lendToScreen(LendMessage.take));
    } catch (_) {
      return; // no screen: nothing holds the headband there
    }
    if (_lent?.lenderGone ?? false) return; // nobody is there to answer
    await r.future.timeout(takeWait, onTimeout: () {});
  }

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    final offer = _offer;
    if (offer != null && _lent == null) {
      _offer = null;
      onFound?.call(offer.band.name, 0);
      return _lent = LentBand._(this, offer);
    }
    await _take();
    return inner.find(scanFor, onFound: onFound);
  }

  @override
  Future<Headband> connectDirect(BandId id) async {
    await _take();
    return inner.connectDirect(id);
  }
}

/// The lent connection as the recorder sees it: a headband whose samples come from the screen's engine.
class LentBand implements Headband, KnownContact {
  LentBand._(this._finder, this._offer) : _gauge = _offer.gauge;
  final LendFinder _finder;
  final LendOffer _offer;
  final StreamController<List<Sample>> _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final StreamController<bool> _range = StreamController<bool>.broadcast(sync: true);
  int? _gauge;
  bool _ended = false;
  bool _isLost = false;
  Timer? _watch;
  int _silentLooks = 0;
  bool _lenderGone = false;

  /// The lender (the screen's engine) no longer exists: nothing came from it for [LendFinder.lenderGoneAfter].
  bool get lenderGone => _lenderGone;

  /// Something came from the lender: it lives.
  void _heard() => _silentLooks = 0;

  /// Looks every [LendFinder.lenderCheckEvery] whether the lender was heard since the last look. Counted in looks,
  /// not by the clock: when the whole process slept, lender and recorder slept together.
  void _watchLender() => _watch ??= Timer.periodic(_finder.lenderCheckEvery, (_) {
    if (_ended || _isLost) return _stopWatch();
    _silentLooks++;
    if (_finder.lenderCheckEvery * _silentLooks < _finder.lenderGoneAfter) return;
    _lenderGone = true;
    _lost();
  });

  void _stopWatch() {
    _watch?.cancel();
    _watch = null;
  }

  @override
  String get name => _offer.band.name;
  @override
  String get address => _offer.band.address;
  @override
  String get serial => _offer.band.serial;
  @override
  BandId get id => _offer.band;
  @override
  int? get rssi => null;
  @override
  Stream<List<Sample>> get signal => _signal.stream;
  @override
  Stream<Map<String, double>> get resistance => const Stream.empty();
  @override
  Stream<bool> get rangeChanges => _range.stream;

  @override
  ({Map<String, double?> ohms, DateTime at})? get knownContact {
    final at = _offer.ohmsAtMs;
    if (at == null || _offer.ohms.isEmpty) return null;
    return (ohms: _offer.ohms, at: DateTime.fromMillisecondsSinceEpoch(at));
  }

  void _add(List<Sample> samples) {
    if (!_ended && !_isLost) _signal.add(samples);
  }

  void _lost() {
    if (_isLost || _ended) return;
    _isLost = true;
    _stopWatch();
    _range.add(false);
  }

  void _say(LendMessage m) {
    try {
      _finder.toScreen(lendToScreen(m));
    } catch (_) {
      _lost(); // no screen any more: nothing will come
    }
  }

  @override
  Future<void> startSignal() async {
    _say(LendMessage.start);
    if (!_isLost && !_ended) _watchLender();
  }

  /// The owner keeps its stream (other screens read it); the recorder's restart is its next [startSignal].
  @override
  Future<void> stopSignal() async {}

  /// Not on a lent connection (it would pause the screen's stream): the recorder checks contact on its own connection.
  @override
  Future<void> startResist() async {}
  @override
  Future<void> stopResist() async {}
  @override
  Future<bool> isInRange() async => !_isLost && !_ended;

  @override
  Future<int> battery() async => _gauge ?? (throw StateError('no battery reading on the lent connection'));

  /// The run on the lent connection is over. Stopped: the owner keeps the connection. Anything else: the recorder's next
  /// try tells the owner to let go ([LendFinder._take]).
  @override
  Future<void> disconnectAndDispose() async {
    if (_ended) return;
    _ended = true;
    _stopWatch();
    if (!_isLost && !_finder._taken) _say(LendMessage.endKeep);
    unawaited(_signal.close());
    unawaited(_range.close());
  }
}
