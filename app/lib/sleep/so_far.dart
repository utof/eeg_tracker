// "Sleep so far" (DECISIONS 640-649): the sleep chart and totals of the night while it still records, scored on the
// phone when the owner asks, and only what is new since the last look.
//
// Why it cannot be the after-night scorer's numbers: that scorer (scorer.dart, model.dart) prepares the whole night at
// once (robust scaling over every sample) and weighs AnySleep's channels by the whole night's averages (two passes),
// so every epoch of it depends on the night's end; nothing scored before Stop is ever the same number after it. So the
// night so far is scored in windows, each as a short recording of its own: the night's 64-minute stretches on a fixed
// grid from its first sample (128 epochs), each with 8 minutes of context on either side (an 80-minute window, the
// same preparation as a night's: MNE's zero-phase high-pass, 128 Hz, AnySleep's robust scaling over the window), the
// three runs averaged, each weighed by the window's own averages (AnySleep as it is, as a night of up to 87.5 minutes
// is scored). A stretch is scored once, when its window and 2 more minutes are recorded, and kept
// (`files/cache/so-far/<night>.json`); the newest minutes (the tail, up to 2 minutes behind the recording) are scored
// in an 80-minute window ending at the newest sample, again at the next look. A stretch is kept only while the
// recordings under its window stay the same (a key of the joined night's parts there): a new file set after a drop
// leaves the stretches before it alone. A night up to 74 minutes is one window from its first sample: then the tail
// is the after-night scorer's own result on the same data.
//
// Cheap: a look prepares and scores only stretches not yet kept plus the tail (3 model calls a window, about 25 for a
// whole 8-hour night at the first look, 3 to 6 at a look half an hour later); it opens the three runs once per look
// and closes them at its end. Before each model call it checks that the live sleep model is not running for the
// smart alarm or the sound cues (live_log.dart): two models in one app would compete for memory and the guard's
// 700 MB (DECISIONS 236), so the look pauses ([ScoringPaused]) and the live model's own epochs stand in for minutes
// it leaves unscored. Plain Dart (the model behind [StageRun]); the joined layout and the preparation run in background
// isolates.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../recorder/nights.dart';
import 'dsp.dart' show mneHighPassTaps;
import 'live_log.dart';
import 'live_stager.dart' show behindEpochs;
import 'model.dart';
import 'night_signal.dart';
import 'periods.dart';

export 'periods.dart' show unscoredStage;
import 'prep.dart';
import 'progress.dart' show cacheDirFor;
import 'report.dart' show PeriodView;
import 'scorer.dart' show ScoringPaused;

/// Epochs kept from a window, and its context on either side.
const int soFarKept = pieceEpochs;
const int soFarContext = contextEpochs;

/// A window: 160 epochs (80 minutes).
const int soFarWindow = soFarKept + 2 * soFarContext;

/// The chart ends this many epochs (2 minutes) behind the newest one, as the live scorer reads (DECISIONS 79).
const int soFarBehind = behindEpochs;

/// Input samples (250 Hz) in one 30 s epoch.
const int epochInputSamples = 30 * sampleRate;

/// What the kept stretches were made with; a cache of another is dropped.
const String soFarMethod = '$phoneModelId so-far 64min+8min own windows';
const int soFarVersion = 1;


/// Model input [w0, w1) and the epochs kept from it [c0, c1).
typedef SoFarWindow = ({int w0, int w1, int c0, int c1});

/// Stretch [k] of the night: kept [128 k, 128 k + 128), window from 16 epochs before to 16 after.
SoFarWindow stretchWindow(int k) =>
    (w0: math.max(0, k * soFarKept - soFarContext), w1: (k + 1) * soFarKept + soFarContext, c0: k * soFarKept, c1: (k + 1) * soFarKept);

/// Stretches whose window and 2 more minutes are recorded in a night of [epochs].
int completeStretches(int epochs) {
  final need = soFarKept + soFarContext + soFarBehind;
  return epochs < need ? 0 : (epochs - need) ~/ soFarKept + 1;
}

/// FNV-1a 64 of [s], in hex: a short key for a long description.
String _fnv64(String s) {
  var h = 0xcbf29ce484222325;
  for (final u in utf8.encode(s)) {
    h = (h ^ u) * 0x100000001b3; // wraps at 64 bits on the phone's VM
  }
  return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

String _name(File f) => f.uri.pathSegments.last;

/// What samples [s0, s1) of the joined night are made of (the files and records there, the gaps and what they hold):
/// equal keys, equal samples.
String windowKey(NightLayout l, int s0, int s1) {
  final b = StringBuffer('${l.startUnix} $s0-$s1');
  Run? prev;
  var end = 0;
  for (final p in l.parts) {
    end = math.max(end, p.at + p.length);
    if (p.at >= s1) break;
    final run = p.run;
    final lo = math.max(p.at, s0), hi = math.min(p.at + p.length, s1);
    if (lo < hi) {
      if (run != null) {
        b.write(' r ${_name(run.file)} ${run.first + lo - p.at} ${hi - lo} @$lo');
      } else {
        b.write(' h ${hi - lo} @$lo ${prev == null ? 'next' : '${_name(prev.file)} ${prev.first + prev.count - 1}'}');
      }
    }
    if (run != null) prev = run;
  }
  if (s1 > end && prev != null) b.write(' end ${prev.first + prev.count - 1}');
  return _fnv64(b.toString());
}

/// The night so far as a look needs it: the newest night, its joined layout, complete epochs, and the keys of its
/// complete stretches and of the tail's window.
class SoFarPlan {
  SoFarPlan({
    required this.night,
    required this.files,
    required this.layout,
    required this.epochs,
    required this.keys,
    required this.tailKey,
  });

  final String night;
  final int files;
  final NightLayout layout;
  final int epochs;
  final List<String> keys;
  final String tailKey;

  int get startUnix => layout.startUnix;
  int get complete => keys.length;

  /// The tail's window starts here: 160 epochs (fewer at the start) ending at the newest complete epoch.
  int get tailWindowFrom => math.max(0, epochs - soFarWindow);
}

/// The newest night in [recordingsDir], if it has data that arrived at or after [sinceMs] (the night that records now;
/// null: any). The `.idx` files are read, not the samples.
SoFarPlan? planSoFar(String recordingsDir, int? sinceMs) {
  final nights = nightsIn(Directory(recordingsDir));
  if (nights.isEmpty) return null;
  final n = nights.first;
  if (n.recordings.isEmpty || (sinceMs != null && n.end.millisecondsSinceEpoch < sinceMs)) return null;
  final layout = joinLayout(n.recordings);
  final epochs = layout.samples ~/ epochInputSamples;
  final complete = completeStretches(epochs);
  return SoFarPlan(
    night: n.name,
    files: n.recordings.length,
    layout: layout,
    epochs: epochs,
    keys: [
      for (var k = 0; k < complete; k++)
        windowKey(layout, stretchWindow(k).w0 * epochInputSamples, stretchWindow(k).w1 * epochInputSamples),
    ],
    tailKey: '$epochs ${windowKey(layout, math.max(0, epochs - soFarWindow) * epochInputSamples, layout.samples)}',
  );
}

typedef PlanFn = Future<SoFarPlan?> Function(String recordingsDir, int? sinceMs);
typedef WindowPrepFn = Future<ModelInput?> Function(NightLayout layout, int w0, int w1, int toSample);

Future<SoFarPlan?> planInBackground(String recordingsDir, int? sinceMs) =>
    Isolate.run(() => planSoFar(recordingsDir, sinceMs), debugName: 'so-far-plan');

Future<ModelInput?> prepareWindowInBackground(NightLayout layout, int w0, int w1, int toSample) =>
    Isolate.run(() => prepareWindow(layout, w0, w1, toSample), debugName: 'so-far-prep');

/// The model's input for epochs [w0, w1) of the joined night, prepared as a recording of its own made of samples
/// [w0 * 7500, toSample): a night's preparation (prep.dart), so with w0 = 0 and [toSample] the night's last sample it
/// is exactly [prepareNight]'s input for the night so far. Null under 5 minutes.
ModelInput? prepareWindow(NightLayout layout, int w0, int w1, int toSample) {
  final epochs = w1 - w0;
  final from = w0 * epochInputSamples;
  if (epochs < minEpochs || toSample < w1 * epochInputSamples) return null;
  final taps = mneHighPassTaps(highPassHz, sampleRate.toDouble());
  final channels = <Float32List>[];
  final pct = <List<double>>[];
  for (var c = 0; c < 4; c++) {
    final scaled = prepareChannel(layout.channelRange(c, from, toSample), taps);
    pct.add(scaled.percentiles);
    channels.add(Float32List.fromList(Float64List.sublistView(scaled.signal, 0, epochs * epochSamples)));
  }
  final missing = layout.bad.where((b) => b.text == 'BAD_gap').fold(
    0,
    (s, b) => s + math.max(0, math.min(b.at + b.samples, toSample) - math.max(b.at, from)),
  );
  return ModelInput(
    startUnix: layout.startUnix + 30 * w0,
    epochs: epochs,
    gap: gapEpochs(layout, w1).sublist(w0),
    channels: channels,
    percentiles: pct,
    recordedSamples: toSample - from,
    missingSamples: missing,
  );
}

const Map<String, String> _char = {'W': 'W', 'N1': '1', 'N2': '2', 'N3': '3', 'R': 'R', gapStage: '-'};
const Map<String, String> _stage = {'W': 'W', '1': 'N1', '2': 'N2', '3': 'N3', 'R': 'R', '-': gapStage};

String _letters(List<String> stages) => stages.map((s) => _char[s] ?? '-').join();
bool _isLetters(String s) => s.split('').every(_stage.containsKey);

/// A kept stretch or the tail: its key and one letter per kept epoch (W 1 2 3 R, `-` for a gap).
typedef KeptStages = ({String key, String stages});

/// What the looks of one night have scored so far (`files/cache/so-far/<night>.json`).
class SoFarCache {
  SoFarCache({
    required this.night,
    required this.startUnix,
    Map<int, KeptStages>? stretches,
    this.tail,
    this.tailFrom = 0,
    this.seconds = 0,
    this.looks = 0,
    this.calls = 0,
  }) : stretches = stretches ?? {};

  final String night;

  /// The joined night's first sample (unix s): epoch e starts 30 e after it.
  final int startUnix;

  /// Kept stretches by number.
  final Map<int, KeptStages> stretches;

  /// The newest minutes at the last look, from epoch [tailFrom].
  KeptStages? tail;
  int tailFrom;

  /// Working time, looks and model calls over the night.
  double seconds;
  int looks;
  int calls;

  Map<String, Object?> toJson() => {
    'version': soFarVersion,
    'method': soFarMethod,
    'night': night,
    'start_unix': startUnix,
    'seconds': (seconds * 10).round() / 10,
    'looks': looks,
    'calls': calls,
    'stretches': [
      for (final e in stretches.entries) {'k': e.key, 'key': e.value.key, 'stages': e.value.stages},
    ],
    'tail': tail == null ? null : {'from': tailFrom, 'key': tail!.key, 'stages': tail!.stages},
  };

  /// A cache read back, or null when it is not one of this method (damaged, another version or method).
  static SoFarCache? fromJson(Object? j) {
    if (j is! Map || j['version'] != soFarVersion || j['method'] != soFarMethod) return null;
    final night = j['night'], start = j['start_unix'], seconds = j['seconds'], looks = j['looks'], calls = j['calls'];
    final list = j['stretches'], tail = j['tail'];
    if (night is! String || start is! int || seconds is! num || looks is! int || calls is! int || list is! List) {
      return null;
    }
    final kept = <int, KeptStages>{};
    for (final s in list) {
      if (s is! Map) return null;
      final k = s['k'], key = s['key'], st = s['stages'];
      if (k is! int || k < 0 || key is! String || st is! String || st.length != soFarKept || !_isLetters(st)) return null;
      kept[k] = (key: key, stages: st);
    }
    KeptStages? t;
    var from = 0;
    if (tail != null) {
      if (tail is! Map) return null;
      final f = tail['from'], key = tail['key'], st = tail['stages'];
      if (f is! int || f < 0 || key is! String || st is! String || st.isEmpty || !_isLetters(st)) return null;
      t = (key: key, stages: st);
      from = f;
    }
    return SoFarCache(
      night: night,
      startUnix: start,
      stretches: kept,
      tail: t,
      tailFrom: from,
      seconds: seconds.toDouble(),
      looks: looks,
      calls: calls,
    );
  }
}

/// `files/cache/so-far/`.
Directory soFarDirFor(String recordingsDir) => Directory('${cacheDirFor(recordingsDir).path}/so-far');

class SoFarStore {
  SoFarStore(this.dir);
  final Directory dir;

  File fileFor(String night) => File('${dir.path}/$night.json');

  SoFarCache? read(String night) {
    try {
      final f = fileFor(night);
      if (!f.existsSync()) return null;
      final c = SoFarCache.fromJson(jsonDecode(f.readAsStringSync()));
      return c?.night == night ? c : null;
    } on Object {
      return null;
    }
  }

  /// The newest night's cache (by name), or null.
  SoFarCache? newest() {
    if (!dir.existsSync()) return null;
    final names = [
      for (final f in dir.listSync().whereType<File>())
        if (f.path.endsWith('.json')) _name(f).substring(0, _name(f).length - 5),
    ]..sort();
    return names.isEmpty ? null : read(names.last);
  }

  void write(SoFarCache c) {
    dir.createSync(recursive: true);
    final tmp = File('${dir.path}/${c.night}.json.tmp');
    tmp.writeAsStringSync(jsonEncode(c.toJson()), flush: true);
    tmp.renameSync(fileFor(c.night).path);
  }

  /// Removes every cache but [keep]'s (a night that has ended has its report; the cache is never needed again).
  void tidy({String? keep}) {
    if (!dir.existsSync()) return;
    for (final f in dir.listSync().whereType<File>()) {
      if (keep != null && _name(f) == '$keep.json') continue;
      try {
        f.deleteSync();
      } on FileSystemException {
        // gone already
      }
    }
  }
}

/// The night so far as the screen shows it: one stage per 30 s from [start] up to [end] (W N1 N2 N3 R, `gap`, or
/// [unscoredStage]), and the totals of the after-night report's rules over them.
class SoFarResult {
  SoFarResult({
    required this.night,
    required this.start,
    required this.stages,
    this.liveEpochs = 0,
    this.seconds = 0,
    this.looks = 0,
    this.calls = 0,
  });

  final String night;
  final DateTime start;
  final List<String> stages;

  /// Epochs the live sleep model's readings stand in for (the look paused while it ran).
  final int liveEpochs;

  /// Working time, looks and model calls so far tonight.
  final double seconds;
  final int looks;
  final int calls;

  DateTime get end => start.add(Duration(seconds: 30 * stages.length));
  int get unscored => stages.where((s) => s == unscoredStage).length;

  late final ({List<SleepPeriod> periods, double straySleepMin}) _found = sleepPeriods(stages);

  DateTime _at(int epoch) => start.add(Duration(seconds: 30 * epoch));

  /// The sleep periods (10+ minutes asleep, apart by 60+ minutes), as the report's page shows them.
  late final List<PeriodView> periods = [
    for (final p in _found.periods)
      PeriodView(
        start: _at(p.first),
        end: _at(p.last + 1),
        asleepMin: p.asleepMin,
        lightMin: p.stageMin['N1']! + p.stageMin['N2']!,
        deepMin: p.stageMin['N3']!,
        dreamMin: p.stageMin['R']!,
        awakeMin: p.stageMin['W']!,
        wakeUps: p.wakeUps.length,
        missingMin: p.missingMin,
        wakeUpList: [for (final w in p.wakeUps) (_at(w.epoch), w.awakeMin)],
      ),
  ];

  /// (first, last) epoch of each period, for the chart.
  List<(int, int)> get bands => [for (final p in _found.periods) (p.first, p.last)];

  double _sum(double Function(PeriodView p) f) => periods.fold(0.0, (s, p) => s + f(p));
  double get asleepMin => _sum((p) => p.asleepMin);
  double get lightMin => _sum((p) => p.lightMin);
  double get deepMin => _sum((p) => p.deepMin);
  double get dreamMin => _sum((p) => p.dreamMin);

  /// Awake inside the sleep periods.
  double get awakeMin => _sum((p) => p.awakeMin);
  int get wakeUps => periods.fold(0, (s, p) => s + p.wakeUps);
  double get straySleepMin => _found.straySleepMin;
  double get missingMin => stages.where((s) => s == gapStage).length * epochMinutes;

  /// The first sleep period's start, or null before one.
  DateTime? get fellAsleep => periods.isEmpty ? null : periods.first.start;
}

/// The stages a cache and the live model's epochs give: kept stretches first, then the tail, then the live model's
/// epochs where neither has scored.
SoFarResult resultOf(SoFarCache c, Map<int, String> live) {
  final own = <int, String>{};
  var end = 0;
  final t = c.tail;
  if (t != null) {
    for (var i = 0; i < t.stages.length; i++) {
      own[c.tailFrom + i] = _stage[t.stages[i]]!;
    }
    end = c.tailFrom + t.stages.length;
  }
  for (final e in c.stretches.entries) {
    final c0 = e.key * soFarKept;
    for (var i = 0; i < e.value.stages.length; i++) {
      own[c0 + i] = _stage[e.value.stages[i]]!;
    }
    end = math.max(end, c0 + e.value.stages.length);
  }
  final standIn = <int, String>{};
  for (final e in live.entries) {
    final at = e.key / 1000 - c.startUnix;
    final epoch = (at / 30).round();
    if (epoch < 0 || (at - 30 * epoch).abs() > 15) continue;
    standIn[epoch] = e.value;
    end = math.max(end, epoch + 1);
  }
  var used = 0;
  final stages = List.filled(end, unscoredStage);
  for (var e = 0; e < end; e++) {
    final o = own[e], l = standIn[e];
    if (o != null) {
      stages[e] = o;
    } else if (l != null) {
      stages[e] = l;
      used++;
    }
  }
  return SoFarResult(
    night: c.night,
    start: DateTime.fromMillisecondsSinceEpoch(c.startUnix * 1000),
    stages: stages,
    liveEpochs: used,
    seconds: c.seconds,
    looks: c.looks,
    calls: c.calls,
  );
}

/// The three runs, opened once per look and closed at its end.
class _Runs {
  _Runs(this.open, this.close, this.count);
  final Future<StageRun> Function(int run) open;
  final Future<void> Function(StageRun run)? close;
  final int count;
  final Map<int, StageRun> _open = {};
  int calls = 0;

  /// The runs' mean softmax over [input] weighed by its own averages: what [stageProbabilities] gives for an input of
  /// one piece, number for number.
  Future<Float64List> probabilities(ModelInput input, Future<void> Function() between) async {
    final n = input.epochs;
    final x = input.interleaved(0, n);
    final sum = Float64List(n * 5);
    for (var r = 1; r <= count; r++) {
      await between();
      final run = _open[r] ??= await open(r);
      final z = await run.logits(x, n);
      if (z.length != n * 5) throw StateError('the model gave ${z.length} values for $n epochs');
      for (var e = 0; e < n; e++) {
        addSoftmax(z, e * 5, sum, e * 5);
      }
      calls++;
    }
    for (var i = 0; i < sum.length; i++) {
      sum[i] /= count;
    }
    return sum;
  }

  Future<void> closeAll() async {
    for (final r in _open.values) {
      try {
        await close?.call(r);
      } catch (_) {}
    }
    _open.clear();
  }
}

class SoFarScorer {
  SoFarScorer({
    required this.recordingsDir,
    required this.openRun,
    this.closeRun,
    this.runCount = 3,
    this.plan = planInBackground,
    this.prepare = prepareWindowInBackground,
    this.log,
    SoFarStore? store,
    Directory? liveDir,
    DateTime Function()? clock,
  }) : store = store ?? SoFarStore(soFarDirFor(recordingsDir.path)),
       liveDir = liveDir ?? liveStagesDirFor(recordingsDir.path),
       _now = clock ?? DateTime.now;

  final Directory recordingsDir;
  final Future<StageRun> Function(int run) openRun;
  final Future<void> Function(StageRun run)? closeRun;
  final int runCount;
  final PlanFn plan;
  final WindowPrepFn prepare;

  /// One line per look (logcat on the phone: tag `flutter`).
  final void Function(String line)? log;
  final SoFarStore store;

  /// Where the night's live sleep model writes its lines (live_log.dart).
  final Directory liveDir;
  final DateTime Function() _now;

  /// The newest result: after each scored window, and after a look that paused.
  SoFarResult? latest;

  /// What the newest cache and the live model's lines show, without scoring (the page opens on it). [sinceMs]: the
  /// night that records now started then; an older night's cache is not shown.
  SoFarResult? cached({int? sinceMs}) {
    final c = store.newest();
    if (c == null) return null;
    final r = resultOf(c, _live(c.startUnix).epochs);
    if (sinceMs != null && r.end.millisecondsSinceEpoch < sinceMs) return null;
    return latest = r;
  }

  LiveLook _live(int startUnix) =>
      readLiveStages(liveDir, fromMs: startUnix * 1000, nowMs: _now().millisecondsSinceEpoch);

  /// Who the live sleep model runs for now, or null.
  String? liveModelFor() => readLiveStages(
    liveDir,
    fromMs: _now().millisecondsSinceEpoch - liveFresh.inMilliseconds,
    nowMs: _now().millisecondsSinceEpoch,
  ).runningFor;

  /// One look: scores the stretches not yet kept and the newest minutes of the night that records since [sinceMs],
  /// and returns the night so far (null: nothing recorded yet tonight). Before each model call [between] runs (it may
  /// throw [ScoringPaused]: the page closed, the night stopped) and the live model is checked: while it runs the look
  /// throws [ScoringPaused] with its reason. What was scored before a pause or a failure stays.
  Future<SoFarResult?> update({
    int? sinceMs,
    void Function(String step)? progress,
    Future<void> Function()? between,
  }) async {
    final sw = Stopwatch()..start();
    Future<void> mayGo() async {
      await between?.call();
      final who = liveModelFor();
      if (who != null) throw ScoringPaused('the live sleep model runs for the $who');
    }

    await mayGo();
    final p = await plan(recordingsDir.path, sinceMs);
    if (p == null) return latest = null;
    final saved = store.read(p.night);
    final c = saved != null && saved.startUnix == p.startUnix
        ? saved
        : SoFarCache(night: p.night, startUnix: p.startUnix);
    // a stretch whose recordings changed under its window (a new file set after a drop, a file that shrank) goes
    c.stretches.removeWhere((k, s) => k >= p.complete || s.key != p.keys[k]);
    final due = [
      for (var k = 0; k < p.complete; k++)
        if (!c.stretches.containsKey(k)) k,
    ];
    final c0 = p.complete * soFarKept, to = p.epochs - soFarBehind;
    final tailDue = p.epochs >= minEpochs && to > c0 && c.tail?.key != p.tailKey;
    final windows = due.length + (tailDue ? 1 : 0);
    c.looks++;
    final runs = _Runs(openRun, closeRun, runCount);
    final calls0 = c.calls;
    void keep() {
      c
        ..seconds += sw.elapsedMicroseconds / 1e6
        ..calls = calls0 + runs.calls;
      sw.reset();
      store.write(c);
      latest = resultOf(c, _live(c.startUnix).epochs);
    }

    String clock(int epoch) {
      final t = DateTime.fromMillisecondsSinceEpoch((p.startUnix + 30 * epoch) * 1000);
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }

    var done = 0;
    Future<String> score(int w0, int w1, int toSample, int k0, int k1) async {
      done++;
      progress?.call('Scoring ${clock(k0)} to ${clock(k1)}${windows > 1 ? ' ($done of $windows)' : ''}');
      await mayGo();
      final input = await prepare(p.layout, w0, w1, toSample);
      if (input == null) throw StateError('the window $w0-$w1 could not be prepared');
      final List<String> stages;
      if (input.gap.where((g) => g).length * 2 > input.epochs) {
        stages = List.filled(input.epochs, gapStage); // mostly lost: its scaling would be noise (DECISIONS 172)
      } else {
        stages = stagesOf(await runs.probabilities(input, mayGo), input.gap).stages;
      }
      return _letters(stages.sublist(k0 - w0, k1 - w0));
    }

    try {
      for (final k in due) {
        final w = stretchWindow(k);
        c.stretches[k] = (key: p.keys[k], stages: await score(w.w0, w.w1, w.w1 * epochInputSamples, w.c0, w.c1));
        keep();
      }
      if (tailDue) {
        c
          ..tail = (key: p.tailKey, stages: await score(p.tailWindowFrom, p.epochs, p.layout.samples, c0, to))
          ..tailFrom = c0;
        keep();
      }
      keep();
      log?.call(
        'sleep so far of ${p.night}: $windows windows, ${runs.calls} model calls in '
        '${(c.seconds).toStringAsFixed(1)} s over ${c.looks} looks; scored to ${clock(to)}',
      );
      return latest;
    } on ScoringPaused catch (e) {
      keep();
      log?.call('sleep so far of ${p.night}: paused (${e.why}) after ${runs.calls} model calls');
      rethrow;
    } catch (e) {
      try {
        keep();
      } catch (_) {}
      log?.call('sleep so far of ${p.night}: failed: $e');
      rethrow;
    } finally {
      await runs.closeAll();
    }
  }
}
