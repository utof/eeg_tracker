// The one judge of electrode quality (DECISIONS 850-852), for any number of electrodes at any positions. Every screen's
// per-electrode word comes from here: the contact reading in ohms (a 6 s spot check before the stream; the BrainBit
// cannot measure it while streaming) and, while the signal streams, the signal itself.
//
// Limits (planning values from the dry-electrode research 2026-11-20, docs/evidence/signal-quality.md):
// - ohms: good up to 300 kΩ, ok up to 1 MΩ (BrainBit's own limit for a session), poor above, none = no reading or
//   infinite (off the head);
// - signal, per second and electrode: off = flat (moved under 1.4 µV) or at the amplifier's limit; wild = the signal
//   above 2 Hz swings over 500 µV; loud = over 250 µV; else calm. These are the detectors' limits (detectors.dart
//   `Quality`), now the only set.
// - your body or the electrode: a second where most electrodes (three in four, at least two) are loud or wild together
//   is "busy" (talking, chewing, moving, the forehead reference shifting): the band is on and no electrode is blamed.
//   Trouble on one electrode alone is that electrode.
// - not jumpy: while fitting (the first 5 minutes of a connection) an electrode's word gets worse after 3 of the last
//   4 s and better after 3 calm seconds; later after 20 of the last 30 s, and better after 10 s.
// - a warning only after 2 minutes of trouble on an electrode a running feature needs; never for "busy".
// - the ohms are measured again only when the signal says the contact changed (never on a timer: each check costs
//   about 7 s of signal).
import 'dart:math' as math;

import '../detectors/detectors.dart' show Quality;
import '../detectors/filters.dart';

/// An electrode's quality in one word, best first.
enum Contact { good, ok, poor, none }

abstract final class QualityLimits {
  static const double goodMaxOhms = 300e3;
  static const double okMaxOhms = 1e6;
  static const double flatUv = Quality.flatUv;
  static const double railUv = Quality.railUv;
  static const double loudUv = Quality.cleanBackUv;
  static const double wildUv = Quality.extremeUv;

  /// A busy second: at least this share of the electrodes (and at least two) loud or wild together.
  static const double sharedShare = 0.75;
  static const int fitWindowS = 4, fitWorseS = 3, fitBackS = 3;
  static const int dayWindowS = 30, dayWorseS = 20, dayBackS = 10;

  /// How long a new fit is given to settle: quick words, and the "wait a little" coaching.
  static const Duration settle = Duration(minutes: 5);

  /// Trouble on a needed electrode is worth a warning after this long.
  static const Duration warnAfter = Duration(minutes: 2);
}

/// The word for a contact reading in ohms (null, infinite or not a number: none).
Contact classifyOhms(double? ohms) {
  if (ohms == null || ohms.isNaN || ohms.isInfinite || ohms < 0) return Contact.none;
  if (ohms <= QualityLimits.goodMaxOhms) return Contact.good;
  if (ohms <= QualityLimits.okMaxOhms) return Contact.ok;
  return Contact.poor;
}

/// One second of one electrode.
enum SecondClass { calm, loud, wild, off }

/// One second of one electrode's signal: [flat] or [railed] is off; else by [swingUv], the peak to peak above 2 Hz.
SecondClass classifySecond({required bool flat, required bool railed, required double swingUv}) {
  if (flat || railed) return SecondClass.off;
  if (swingUv > QualityLimits.wildUv) return SecondClass.wild;
  if (swingUv > QualityLimits.loudUv) return SecondClass.loud;
  return SecondClass.calm;
}

/// Whether a second is "busy": most electrodes loud or wild together (never for one electrode alone).
bool sharedSecond(List<SecondClass> second) {
  final n = second.length;
  if (n < 2) return false;
  final loud = second.where((c) => c == SecondClass.loud || c == SecondClass.wild).length;
  return loud >= math.max(2, (QualityLimits.sharedShare * n).ceil());
}

/// Turns samples (µV, one row per sample, any width) into seconds for the judge: per electrode the raw range (flat),
/// the largest value (railed) and the swing above 2 Hz.
class SecondMaker {
  SecondMaker({required this.channels, this.rate = 250})
    : _hp = [for (var c = 0; c < channels; c++) Chain([highPass(Quality.qualityHpHz, sampleRate: rate)])],
      _lo = List.filled(channels, double.infinity),
      _hi = List.filled(channels, double.negativeInfinity),
      _top = List.filled(channels, 0),
      _slo = List.filled(channels, double.infinity),
      _shi = List.filled(channels, double.negativeInfinity);

  final int channels, rate;
  final List<Chain> _hp;
  final List<double> _lo, _hi, _top, _slo, _shi;
  int _n = 0;

  /// One sample; returns the finished second every [rate] samples, else null. A row of another width is ignored.
  List<SecondClass>? push(List<double> uv) {
    if (uv.length != channels) return null;
    for (var c = 0; c < channels; c++) {
      final v = uv[c], s = _hp[c].step(v);
      if (v < _lo[c]) _lo[c] = v;
      if (v > _hi[c]) _hi[c] = v;
      if (v.abs() > _top[c]) _top[c] = v.abs();
      if (s < _slo[c]) _slo[c] = s;
      if (s > _shi[c]) _shi[c] = s;
    }
    if (++_n < rate) return null;
    final out = [
      for (var c = 0; c < channels; c++)
        classifySecond(
          flat: _hi[c] - _lo[c] < QualityLimits.flatUv,
          railed: _top[c] >= QualityLimits.railUv,
          swingUv: _shi[c] - _slo[c],
        ),
    ];
    _n = 0;
    for (var c = 0; c < channels; c++) {
      _lo[c] = _slo[c] = double.infinity;
      _hi[c] = _shi[c] = double.negativeInfinity;
      _top[c] = 0;
    }
    return out;
  }
}

/// What the trouble is, when there is any.
enum Trouble {
  none,

  /// Most electrodes at once: the wearer (talking, chewing, moving) or the shared forehead reference. Not a fault.
  busy,

  /// Every electrode off: the band is off the head, or the forehead reference lost its contact.
  allOff,

  /// Some electrodes only: those electrodes.
  electrodes,
}

class ElectrodeQuality {
  const ElectrodeQuality({required this.name, required this.grade, this.ohms, this.fromSignal = false, this.troubleFor});
  final String name;
  final Contact grade;

  /// The contact reading (null: none, or off the head).
  final double? ohms;

  /// The word comes from the live signal (else from the contact reading alone).
  final bool fromSignal;

  /// How long this electrode has been poor or none without a break (null: it is not).
  final Duration? troubleFor;
}

class QualityVerdict {
  const QualityVerdict({
    this.electrodes = const [],
    this.trouble = Trouble.none,
    this.ohmsAt,
    this.contactChanged = false,
    this.settling = false,
  });

  final List<ElectrodeQuality> electrodes;
  final Trouble trouble;

  /// When the contact (ohms) was measured; null: never.
  final DateTime? ohmsAt;

  /// The signal says the contact changed since the ohms were measured: worth measuring again.
  final bool contactChanged;

  /// The fit is new (under 5 minutes): contact usually gets better by itself.
  final bool settling;

  /// Plain values for the isolate port (the night recorder's judge to the screen); the ohms travel separately.
  Map<String, Object?> toMap() => {
    'names': [for (final e in electrodes) e.name],
    'grades': [for (final e in electrodes) e.grade.index],
    'troubleS': [for (final e in electrodes) e.troubleFor?.inSeconds],
    'trouble': trouble.name,
    'changed': contactChanged,
    'settling': settling,
  };

  /// Null for anything that is not such a map.
  static QualityVerdict? fromMap(Object? m) {
    if (m is! Map) return null;
    final names = m['names'], grades = m['grades'], ts = m['troubleS'];
    if (names is! List || grades is! List || ts is! List) return null;
    if (grades.length != names.length || ts.length != names.length) return null;
    final out = <ElectrodeQuality>[];
    for (var i = 0; i < names.length; i++) {
      final n = names[i], g = grades[i], t = ts[i];
      if (n is! String || g is! int || g < 0 || g >= Contact.values.length) return null;
      out.add(
        ElectrodeQuality(
          name: n,
          grade: Contact.values[g],
          fromSignal: true,
          troubleFor: t is int ? Duration(seconds: t) : null,
        ),
      );
    }
    return QualityVerdict(
      electrodes: out,
      trouble: Trouble.values.where((t) => t.name == m['trouble']).firstOrNull ?? Trouble.none,
      contactChanged: m['changed'] == true,
      settling: m['settling'] == true,
    );
  }

  /// The same verdict with the contact reading it was made with ([ohms] per electrode name, measured [at]).
  QualityVerdict withOhms(Map<String, double?> ohms, DateTime? at) => QualityVerdict(
    electrodes: [
      for (final e in electrodes)
        ElectrodeQuality(
          name: e.name,
          grade: e.grade,
          ohms: ohms[e.name],
          fromSignal: e.fromSignal,
          troubleFor: e.troubleFor,
        ),
    ],
    trouble: trouble,
    ohmsAt: at,
    contactChanged: contactChanged,
    settling: settling,
  );

  Contact gradeOf(String name) =>
      electrodes.where((e) => e.name == name).map((e) => e.grade).firstOrNull ?? Contact.none;

  /// The electrodes in trouble (poor or none), by name.
  List<String> get troubled => [
    for (final e in electrodes)
      if (e.grade == Contact.poor || e.grade == Contact.none) e.name,
  ];

  /// Of [needed] (a running feature's electrodes; null: all), those in trouble for [QualityLimits.warnAfter] or longer.
  /// Never while the trouble is shared ("busy"): that is the wearer, not an electrode.
  List<String> worthWarning([Iterable<String>? needed]) {
    if (trouble == Trouble.busy) return const [];
    final want = needed?.toSet();
    return [
      for (final e in electrodes)
        if ((want == null || want.contains(e.name)) && (e.troubleFor ?? Duration.zero) >= QualityLimits.warnAfter) e.name,
    ];
  }

  /// One plain sentence about the trouble, or null when there is none.
  String? get words => switch (trouble) {
    Trouble.none => null,
    Trouble.busy =>
      'All electrodes are busy at once: you are moving, talking or chewing, or the band shifted. The band is on.',
    Trouble.allOff => 'No electrode touches: the band is off the head, or the forehead contact is lost.',
    Trouble.electrodes => _electrodeWords(),
  };

  String _electrodeWords() {
    final t = troubled;
    final who = t.length == 1 ? t.first : '${t.sublist(0, t.length - 1).join(', ')} and ${t.last}';
    return '$who: ${t.length == 1 ? 'this electrode has' : 'these electrodes have'} poor contact. '
        'Part the hair under ${t.length == 1 ? 'it' : 'them'} and press ${t.length == 1 ? 'it' : 'them'} to the skin.';
  }

  /// What to do now, or null: wait while a new fit settles; measure again when the contact changed.
  String? get coaching {
    if (trouble == Trouble.allOff) return null;
    final imperfect = electrodes.any((e) => e.grade != Contact.good);
    if (settling && imperfect) {
      return 'Contact usually gets better by itself in 2 to 5 minutes. Wait a little before you adjust the band.';
    }
    if (contactChanged) return 'The signal changed since the contact was measured.';
    return null;
  }
}

/// The judge. Feed it the contact reading ([ohms]) and the signal's seconds ([second], from a [SecondMaker]); read
/// [verdict]. [fitFrom] is when this fit began (a connection, a reconnect): for [QualityLimits.settle] after it the
/// words move quickly.
class QualityJudge {
  QualityJudge({required List<String> names, DateTime Function()? clock})
    : names = List.unmodifiable(names),
      _now = clock ?? DateTime.now,
      _signal = List.filled(names.length, null),
      _since = List.filled(names.length, null);

  final List<String> names;
  final DateTime Function() _now;

  /// The last seconds, newest last (at most the day window).
  final List<List<SecondClass>> _seconds = [];
  final List<bool> _shared = [];

  /// The signal's word per electrode (null before the first full window).
  final List<Contact?> _signal;

  /// Since when each electrode is in trouble.
  final List<DateTime?> _since;
  Map<String, double?> _ohms = const {};
  DateTime? _ohmsAt;
  DateTime? _fitFrom;
  bool _changed = false;

  /// A new fit: the old seconds say nothing about now.
  void fit({DateTime? at}) {
    _fitFrom = at ?? _now();
    _seconds.clear();
    _shared.clear();
    _signal.fillRange(0, _signal.length, null);
    _since.fillRange(0, _since.length, null);
  }

  /// A contact reading: ohms per electrode name (null: no contact). It restarts "changed since".
  void ohms(Map<String, double?> ohms, {DateTime? at}) {
    _ohms = Map.unmodifiable(ohms);
    _ohmsAt = at ?? _now();
    _changed = false;
  }

  bool get _fitting {
    final f = _fitFrom;
    return f == null || _now().difference(f) < QualityLimits.settle;
  }

  /// One second of every electrode, in [names]' order (another length is ignored).
  void second(List<SecondClass> s) {
    if (s.length != names.length) return;
    _fitFrom ??= _now();
    _seconds.add(List.unmodifiable(s));
    _shared.add(sharedSecond(s));
    if (_seconds.length > QualityLimits.dayWindowS) {
      _seconds.removeAt(0);
      _shared.removeAt(0);
    }
    final fitting = _fitting;
    final window = fitting ? QualityLimits.fitWindowS : QualityLimits.dayWindowS;
    final worse = fitting ? QualityLimits.fitWorseS : QualityLimits.dayWorseS;
    final back = fitting ? QualityLimits.fitBackS : QualityLimits.dayBackS;
    if (_seconds.length < QualityLimits.fitWindowS) return;
    final from = math.max(0, _seconds.length - window);
    final now = _now();
    for (var c = 0; c < names.length; c++) {
      final cand = _candidate(c, from, math.min(worse, _seconds.length - from));
      final was = _signal[c];
      var next = cand;
      if (was != null && cand.index < was.index) {
        // better only once the last seconds were all better than the word shown
        final tail = math.max(0, _seconds.length - back);
        var worst = cand;
        for (var i = tail; i < _seconds.length; i++) {
          final g = _gradeOfSecond(_seconds[i][c], _shared[i]);
          if (g.index > worst.index) worst = g;
        }
        next = _seconds.length - tail >= back ? worst : was;
        if (next.index > was.index) next = was;
      }
      if (was != null && next != was && _ohmsAt != null) _changed = true;
      _signal[c] = next;
      final bad = next == Contact.poor || next == Contact.none;
      _since[c] = bad ? (_since[c] ?? now) : null;
    }
  }

  /// A second's word for one electrode: a busy second is never held against it.
  static Contact _gradeOfSecond(SecondClass c, bool shared) => switch (c) {
    SecondClass.off => Contact.none,
    SecondClass.wild => shared ? Contact.good : Contact.poor,
    SecondClass.loud => shared ? Contact.good : Contact.ok,
    SecondClass.calm => Contact.good,
  };

  /// The worst word that at least [need] of the seconds from [from] reach.
  Contact _candidate(int c, int from, int need) {
    final counts = List.filled(Contact.values.length, 0);
    for (var i = from; i < _seconds.length; i++) {
      counts[_gradeOfSecond(_seconds[i][c], _shared[i]).index]++;
    }
    var atLeast = 0;
    for (var g = Contact.values.length - 1; g > 0; g--) {
      atLeast += counts[g];
      if (atLeast >= need) return Contact.values[g];
    }
    return Contact.good;
  }

  QualityVerdict get verdict {
    final now = _now();
    final hasSignal = _signal.any((g) => g != null);
    final electrodes = <ElectrodeQuality>[];
    for (var c = 0; c < names.length; c++) {
      final name = names[c];
      final measured = _ohms.containsKey(name);
      final byOhms = measured ? classifyOhms(_ohms[name]) : null;
      final bySignal = _signal[c];
      // the signal decides once there is one; a contact reading still in force may only make the word worse
      Contact grade;
      if (bySignal == null) {
        grade = byOhms ?? Contact.none;
      } else if (byOhms != null && !_changed && byOhms != Contact.none && byOhms.index > bySignal.index) {
        grade = byOhms;
      } else {
        grade = bySignal;
      }
      final since = _since[c];
      electrodes.add(
        ElectrodeQuality(
          name: name,
          grade: grade,
          ohms: _ohms[name],
          fromSignal: bySignal != null,
          troubleFor: since == null ? null : now.difference(since),
        ),
      );
    }
    return QualityVerdict(
      electrodes: electrodes,
      trouble: _trouble(electrodes, hasSignal),
      ohmsAt: _ohmsAt,
      contactChanged: _changed,
      settling: hasSignal && _fitting,
    );
  }

  Trouble _trouble(List<ElectrodeQuality> e, bool hasSignal) {
    if (e.isEmpty) return Trouble.none;
    if (hasSignal && _shared.isNotEmpty) {
      // busy now: at least half of the last 4 s
      final from = math.max(0, _shared.length - QualityLimits.fitWindowS);
      final busy = _shared.sublist(from).where((b) => b).length;
      if (busy * 2 >= _shared.length - from) return Trouble.busy;
    }
    final bad = e.where((x) => x.grade == Contact.poor || x.grade == Contact.none).length;
    if (bad == 0) return Trouble.none;
    if (e.length > 1 && e.every((x) => x.grade == Contact.none)) return Trouble.allOff;
    if (e.length == 1 && e.first.grade == Contact.none) return Trouble.allOff;
    return Trouble.electrodes;
  }
}

/// '820 kΩ', '1.4 MΩ', 'off' (infinite: off the head), '–' (no reading).
String formatOhms(double? ohms) {
  if (ohms == null || ohms.isNaN || ohms < 0) return '–';
  if (ohms.isInfinite) return 'off';
  if (ohms < 1e3) return '${ohms.round()} Ω';
  if (ohms < 1e6) return '${(ohms / 1e3).round()} kΩ';
  return '${(ohms / 1e6).toStringAsFixed(1)} MΩ';
}
