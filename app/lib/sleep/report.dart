// The phone's sleep report: `files/nights/<date>.report.json`, next to `files/recordings/`, with the field names
// of the laptop's `<date>.report.json` (scripts/sleep_report.py, docs/data-format.md). The phone draws no picture
// and runs no second model, so `hypnogram`, `sleep_json`, `bdf` and `cross_check` are null; instead `stages` holds
// one character per 30 s from `data_start` (W 1 2 3 R, `-` where data was missing), as the `hypnogram` of the
// `eeg_sleep_night` event. Plain Dart: written by the scorer, read by the screens.
import 'dart:convert';
import 'dart:io';

import 'periods.dart';

/// Of the report file; a report of another version is rebuilt (the laptop's rule).
const int reportVersion = 1;
const String reportNote = 'first guess; the scorer is not yet validated on this headband';

/// The nights folder for the app's recordings folder.
Directory nightsDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/nights');

/// `2026-11-18T03:16:55+03:00`: local time with its UTC offset, as Python's `isoformat(timespec="seconds")`.
String isoLocal(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final off = l.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final m = off.inMinutes.abs();
  return '${l.year.toString().padLeft(4, '0')}-${two(l.month)}-${two(l.day)}T${two(l.hour)}:${two(l.minute)}:'
      '${two(l.second)}$sign${two(m ~/ 60)}:${two(m % 60)}';
}

const Map<String, String> _stageChar = {'W': 'W', 'N1': '1', 'N2': '2', 'N3': '3', 'R': 'R', gapStage: '-'};
const Map<String, String> _charStage = {'W': 'W', '1': 'N1', '2': 'N2', '3': 'N3', 'R': 'R', '-': gapStage};

/// One period as the screens need it.
class PeriodView {
  const PeriodView({
    required this.start,
    required this.end,
    required this.asleepMin,
    required this.lightMin,
    required this.deepMin,
    required this.dreamMin,
    required this.awakeMin,
    required this.wakeUps,
    required this.missingMin,
    this.wakeUpList = const [],
  });
  final DateTime start;
  final DateTime end;
  final double asleepMin;
  final double lightMin;
  final double deepMin;
  final double dreamMin;
  final double awakeMin;
  final int wakeUps;
  final double missingMin;

  /// Each wake-up's start and minutes awake.
  final List<(DateTime, double)> wakeUpList;
}

/// A report read back from its JSON (or just made).
class SleepReport {
  SleepReport(this.json);
  final Map<String, dynamic> json;

  String get nightOf => json['night_of'] as String;
  bool get scored => json['scored'] == true;
  DateTime get dataStart => DateTime.parse(json['data_start'] as String).toLocal();
  DateTime get dataEnd => DateTime.parse(json['data_end'] as String).toLocal();
  Map<String, dynamic> get total => (json['total'] as Map).cast<String, dynamic>();
  double get asleepMin => (total['asleep_min'] as num).toDouble();
  double get recordedMin => (total['recorded_min'] as num).toDouble();
  double get missingMin => (total['missing_min'] as num).toDouble();
  double get straySleepMin => (total['stray_sleep_min'] as num).toDouble();
  double get scoringSeconds => (json['scoring_s'] as num?)?.toDouble() ?? 0;

  /// Stages per 30 s from [dataStart]: W N1 N2 N3 R or `gap`.
  List<String> get stages => [for (final c in (json['stages'] as String? ?? '').split('')) _charStage[c] ?? gapStage];

  List<PeriodView> get periods => [
    for (final p in (json['periods'] as List).cast<Map<String, dynamic>>())
      PeriodView(
        start: DateTime.parse(p['start'] as String).toLocal(),
        end: DateTime.parse(p['end'] as String).toLocal(),
        asleepMin: (p['asleep_min'] as num).toDouble(),
        lightMin: (p['light_min'] as num).toDouble(),
        deepMin: (p['deep_min'] as num).toDouble(),
        dreamMin: (p['dream_min'] as num).toDouble(),
        awakeMin: (p['awake_min'] as num).toDouble(),
        wakeUps: (p['wake_ups'] as num).toInt(),
        missingMin: (p['missing_min'] as num).toDouble(),
        wakeUpList: [
          for (final w in (p['wake_up_list'] as List? ?? const []).whereType<Map<String, dynamic>>())
            (DateTime.parse(w['start'] as String).toLocal(), (w['awake_min'] as num).toDouble()),
        ],
      ),
  ];

  /// The `.f32` files and sizes the report was made from.
  Map<String, int> get inputs => {
    for (final i in (json['inputs'] as List? ?? const []).whereType<Map<String, dynamic>>())
      if (i['file'] is String) i['file'] as String: (i['bytes'] as num?)?.toInt() ?? 0,
  };

  /// Reads a report; null when the file is missing, damaged or not a report.
  static SleepReport? read(File f) {
    try {
      final d = jsonDecode(f.readAsStringSync());
      if (d is! Map<String, dynamic> || d['night_of'] is! String || d['total'] is! Map || d['periods'] is! List) {
        return null;
      }
      final r = SleepReport(d);
      r.dataStart;
      r.dataEnd;
      r.periods;
      r.asleepMin;
      return r;
    } on Object {
      return null;
    }
  }
}

/// Builds the report from the stages of a scored night. [start] is the first epoch's start; [lengthSeconds] the
/// joined night (gaps and padding included); [inputs] the `.f32` names and sizes read.
Map<String, dynamic> buildReport({
  required String nightOf,
  required DateTime built,
  required double scoringSeconds,
  required DateTime start,
  required double lengthSeconds,
  required Map<String, int> inputs,
  required String model,
  List<String>? stages,
  List<double>? confidence,
}) {
  final rep = <String, dynamic>{
    'version': reportVersion,
    'night_of': nightOf,
    'built': isoLocal(built),
    'scoring_s': (scoringSeconds * 10).round() / 10,
    'data_start': isoLocal(start),
    'data_end': isoLocal(start.add(Duration(milliseconds: (lengthSeconds * 1000).round()))),
    'inputs': [for (final e in inputs.entries) {'file': e.key, 'bytes': e.value}],
    'scored': stages != null,
    'note': reportNote,
    'validated': false,
    'rules': {'split_min': splitMin, 'min_period_sleep_min': minPeriodSleepMin, 'wake_up_over_min': wakeUpOverMin},
    'source': 'phone',
    'epoch_s': 30,
  };
  if (stages == null) {
    return rep
      ..addAll({
        'periods': <Object>[],
        'total': {
          'asleep_min': 0.0,
          'light_min': 0.0,
          'deep_min': 0.0,
          'dream_min': 0.0,
          'wake_ups': 0,
          'periods': 0,
          'recorded_min': (lengthSeconds / 6).round() / 10,
          'missing_min': 0.0,
          'stray_sleep_min': 0.0,
        },
        'hypnogram': null,
        'sleep_json': null,
        'bdf': null,
        'model': null,
        'cross_check': null,
        'stages': '',
      });
  }
  // the laptop takes the confidence from probabilities rounded to 3 decimals (sleep.json)
  final found = sleepPeriods(stages, confidence: confidence?.map(round3).toList());
  String at(int epoch) => isoLocal(start.add(Duration(seconds: 30 * epoch)));
  final periods = [
    for (final p in found.periods)
      {
        'start': at(p.first),
        'end': at(p.last + 1),
        'asleep_min': p.asleepMin,
        'light_min': p.stageMin['N1']! + p.stageMin['N2']!,
        'deep_min': p.stageMin['N3']!,
        'dream_min': p.stageMin['R']!,
        'awake_min': p.stageMin['W']!,
        'stage_min': p.stageMin,
        'wake_ups': p.wakeUps.length,
        'wake_up_list': [for (final w in p.wakeUps) {'start': at(w.epoch), 'awake_min': w.awakeMin}],
        'missing_min': p.missingMin,
        'agreement': null,
        'confidence': p.confidence,
      },
  ];
  double sum(String k) => periods.fold(0.0, (s, p) => s + (p[k] as num).toDouble());
  final gaps = stages.where((s) => s == gapStage).length;
  return rep
    ..addAll({
      'periods': periods,
      'total': {
        'asleep_min': sum('asleep_min'),
        'light_min': sum('light_min'),
        'deep_min': sum('deep_min'),
        'dream_min': sum('dream_min'),
        'wake_ups': sum('wake_ups').round(),
        'periods': periods.length,
        'recorded_min': (stages.length - gaps) * epochMinutes,
        'missing_min': gaps * epochMinutes,
        'stray_sleep_min': found.straySleepMin,
      },
      'hypnogram': null,
      'sleep_json': null,
      'bdf': null,
      'model': model,
      'cross_check': null,
      'stages': stages.map((s) => _stageChar[s] ?? '-').join(),
    });
}

/// `files/nights/`: one report per night, replaced whole (written to a temporary file, then renamed).
class NightReportStore {
  NightReportStore(this.dir);
  final Directory dir;

  File fileFor(String nightOf) => File('${dir.path}/$nightOf.report.json');

  /// Left while a night is being scored; still there at the next start means the app died while scoring.
  File markerFor(String nightOf) => File('${dir.path}/$nightOf.scoring');

  SleepReport? read(String nightOf) => SleepReport.read(fileFor(nightOf));

  void write(Map<String, dynamic> report) {
    dir.createSync(recursive: true);
    final name = report['night_of'] as String;
    final tmp = File('${dir.path}/$name.report.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(report), flush: true);
    tmp.renameSync(fileFor(name).path);
  }

  /// Every readable report, newest night first.
  List<SleepReport> all() {
    if (!dir.existsSync()) return const [];
    final out = <SleepReport>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.report.json')) continue;
      final r = SleepReport.read(f);
      if (r != null) out.add(r);
    }
    return out..sort((a, b) => b.nightOf.compareTo(a.nightOf));
  }
}

/// night_files.py `is_stale`: no report, another version, a file gone or shrunk, or 10+ minutes of new samples.
bool isStale(Map<String, int> files, SleepReport? report, {int newDataMinutes = 10}) {
  if (report == null || report.json['version'] != reportVersion) return true;
  final done = report.inputs;
  if (done.keys.any((f) => !files.containsKey(f)) || done.entries.any((e) => files[e.key]! < e.value)) return true;
  final newBytes = files.entries.fold(0, (s, e) => s + e.value - (done[e.key] ?? 0));
  return newBytes ~/ 20 >= newDataMinutes * 60 * 250;
}
