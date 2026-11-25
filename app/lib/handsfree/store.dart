// Hands-free controls (ROADMAP "Hands-free controls", DECISIONS 240-249): the switch and the owner's calibration,
// kept in the app's private folder like everything else and exported whole by Export data (its "everything except"
// rule takes `hands-free/` as it is).
//
//   files/hands-free/settings.json      {"on": bool, "changed": iso}: the one switch, off by default
//   files/hands-free/calibration.json   the newest calibration: the tuned settings and every cued try
//   files/hands-free/events.jsonl       one line per change (switched on or off, calibrated)
//
// Each file is written under a temporary name and then renamed, so a cut-off write leaves the old one. A missing or
// damaged file reads as "off" and "not calibrated": the gestures then never act.
import 'dart:convert';
import 'dart:io';

import '../detectors/gestures.dart';
import '../sleep/report.dart' show isoLocal;

const String handsFreeFolder = 'hands-free';

/// The newest calibration, as saved.
class CalibrationRecord {
  const CalibrationRecord({
    required this.made,
    required this.settings,
    required this.tries,
    required this.clenchSeen,
    required this.glanceSeen,
    required this.leftKnown,
    required this.others,
    this.recording,
    this.span,
  });

  final DateTime made;

  /// The tuned settings; [GestureSettings.clenchOn] and [GestureSettings.glanceOn] say which gesture is usable.
  final GestureSettings settings;
  final List<TryResult> tries;
  final int clenchSeen, glanceSeen;
  final bool leftKnown;

  /// Gestures recognised outside the cued windows (0 is right).
  final int others;

  /// The calibration's EEG in `recordings/` (its stem), if it was kept.
  final String? recording;

  /// The span of the day's recording this session ran on as an activity (spans/activities.dart): then [recording]
  /// is that recording's id and the session's signal is its samples inside the span; null: a session of its own.
  final String? span;

  bool get usable => settings.clenchOn || settings.glanceOn;

  factory CalibrationRecord.of(GestureCalibration c, DateTime made, {String? recording, String? span}) => CalibrationRecord(
    made: made,
    settings: c.settings,
    tries: c.tries,
    clenchSeen: c.clenchSeen,
    glanceSeen: c.glanceSeen,
    leftKnown: c.leftKnown,
    others: c.others,
    recording: recording,
    span: span,
  );

  Map<String, Object?> toJson() => {
    'made': isoLocal(made),
    'settings': settings.toJson(),
    'tries': [for (final t in tries) t.toJson()],
    'clenchSeen': clenchSeen,
    'glanceSeen': glanceSeen,
    'leftKnown': leftKnown,
    'others': others,
    'recording': recording,
    'span': ?span,
    'rules': {
      'clenchShare': GestureRule.calShareClench,
      'glanceShare': GestureRule.calShareGlance,
      'need': GestureRule.calNeed,
      'burstTicks': [GestureRule.burstMin, GestureRule.burstMax],
      'pauseTicks': [GestureRule.pauseMin, GestureRule.pauseMax],
      'quietTicks': GestureRule.quietTicks,
      'glanceStepSamples': GestureRule.glanceStep,
    },
  };

  /// Throws [FormatException] for anything that is not a calibration this app wrote.
  static CalibrationRecord fromJson(Object? j) {
    if (j is! Map) throw const FormatException('calibration: not an object');
    final made = DateTime.tryParse('${j['made']}')?.toLocal();
    final tries = j['tries'], cs = j['clenchSeen'], gs = j['glanceSeen'], lk = j['leftKnown'], o = j['others'];
    final rec = j['recording'];
    if (made == null || tries is! List || cs is! int || gs is! int || lk is! bool || o is! int || (rec != null && rec is! String)) {
      throw const FormatException('calibration: missing or wrong fields');
    }
    return CalibrationRecord(
      made: made,
      settings: GestureSettings.fromJson(j['settings']),
      tries: [for (final t in tries) _try(t)],
      clenchSeen: cs,
      glanceSeen: gs,
      leftKnown: lk,
      others: o,
      recording: rec as String?,
      span: j['span'] is String ? j['span'] as String : null,
    );
  }

  static TryResult _try(Object? t) {
    if (t is! Map) throw const FormatException('calibration try: not an object');
    final kind = GestureKind.values.where((k) => k.name == t['kind']).firstOrNull;
    final cue = t['cue'], level = t['level'], sign = t['sign'], why = t['why'];
    if (kind == null || cue is! int || (level != null && level is! num) || sign is! int || why is! String) {
      throw const FormatException('calibration try: wrong fields');
    }
    return TryResult(kind, cue, (level as num?)?.toDouble(), sign, why);
  }
}

/// The switch and the calibration, read together.
class HandsFreeState {
  const HandsFreeState({this.on = false, this.calibration});
  final bool on;
  final CalibrationRecord? calibration;

  /// What the sessions use: the calibrated settings while the switch is on and a gesture is usable, else null.
  GestureSettings? get active {
    final c = calibration;
    return on && c != null && c.usable ? c.settings : null;
  }
}

class HandsFreeStore {
  HandsFreeStore(this.filesDir);
  final Directory filesDir;

  Directory get dir => Directory('${filesDir.path}/$handsFreeFolder');
  File get _settings => File('${dir.path}/settings.json');
  File get _calibration => File('${dir.path}/calibration.json');
  File get _events => File('${dir.path}/events.jsonl');

  HandsFreeState load() {
    var on = false;
    CalibrationRecord? cal;
    try {
      final j = jsonDecode(_settings.readAsStringSync());
      on = j is Map && j['on'] == true;
    } on FileSystemException {
      // never switched
    } on FormatException {
      // damaged: off
    }
    try {
      cal = CalibrationRecord.fromJson(jsonDecode(_calibration.readAsStringSync()));
    } on FileSystemException {
      // never calibrated
    } on FormatException {
      // damaged: not calibrated
    }
    return HandsFreeState(on: on, calibration: cal);
  }

  void setOn(bool on, DateTime at) {
    _write(_settings, {'on': on, 'changed': isoLocal(at)});
    _event(at, on ? 'switched on' : 'switched off');
  }

  void saveCalibration(CalibrationRecord c) {
    _write(_calibration, c.toJson());
    _event(
      c.made,
      'calibrated: double clench ${c.clenchSeen} of 3 (${c.settings.clenchOn ? 'on' : 'off'}), look left then right '
      '${c.glanceSeen} of 3 (${c.settings.glanceOn ? 'on' : 'off'}${c.leftKnown ? '' : ', either way'})',
    );
  }

  void _write(File f, Map<String, Object?> j) {
    dir.createSync(recursive: true);
    final tmp = File('${f.path}.tmp')..writeAsStringSync(const JsonEncoder.withIndent(' ').convert(j), flush: true);
    tmp.renameSync(f.path);
  }

  void _event(DateTime at, String text) {
    dir.createSync(recursive: true);
    _events.writeAsStringSync('${jsonEncode({'at': isoLocal(at), 'event': text})}\n', mode: FileMode.append, flush: true);
  }
}

/// What the night recorder uses (DECISIONS 247): the owner's calibrated settings while the switch is on and the double
/// clench is usable, else null. Never throws: a failure here must not cost the drift-off detector.
GestureSettings? nightGestures(Directory filesDir) {
  try {
    final s = HandsFreeStore(filesDir).load().active;
    return s != null && s.clenchOn ? s : null;
  } catch (_) {
    return null;
  }
}
