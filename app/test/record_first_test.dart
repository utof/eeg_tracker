// Record first in the recorder (DECISIONS 880-899): one recording id in every file set's header, Record alone with
// no span and no sleep kit, Sleep as a span that started the recording, spans opened and closed by command.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/alarm/rule.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/sleep/night_scorer.dart';
import 'package:eeg_tracker/spans/span.dart';
import 'package:eeg_tracker/spans/span_log.dart';
import 'package:flutter_test/flutter_test.dart';

import 'night_recorder_test.dart' show FakeBand, FakeFinder, fast;

void main() {
  group('sleep on a running recording', sleepOnARecording);
  late Directory files, dir;
  late MemoryNightStore store;
  late List<RecorderStatus> statuses;

  setUp(() {
    files = Directory.systemTemp.createTempSync('record_first_test');
    dir = Directory('${files.path}/recordings')..createSync();
    store = MemoryNightStore();
    statuses = [];
  });
  tearDown(() => files.deleteSync(recursive: true));

  NightRecorder recorder(HeadbandFinder finder, {bool sleep = true, String source = 'owner_button'}) => NightRecorder(
    finder: finder,
    dir: dir,
    store: store,
    onStatus: statuses.add,
    onStuck: (_) async {},
    timing: fast,
    watch: null,
    spanLog: SpanLog(spansDirFor(dir.path)),
    sleep: sleep,
    sleepSource: source,
  );

  List<String> stems() => [
    for (final f in dir.listSync().whereType<File>())
      if (f.path.endsWith('.f32')) f.uri.pathSegments.last.replaceFirst('.f32', ''),
  ]..sort();

  RecordingHeader header(String stem) => tryHeader(File('${dir.path}/$stem.f32'))!;

  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  test('Record alone: one recording id in every set, no span, no spans file, the sleep kit off', () async {
    final first = FakeBand('a'), second = FakeBand('b');
    final r = recorder(FakeFinder([first, second]), sleep: false);
    final running = r.run(restartedBySystem: false);
    await wait(200);
    first.goOutOfRange();
    await wait(300);
    expect(statuses.last.rec.sleep, isFalse);
    expect(statuses.last.rec.id, stems().first);
    await r.stop();
    await running;

    final sets = stems();
    expect(sets, hasLength(2));
    expect([for (final s in sets) header(s).recording], [sets.first, sets.first]);
    expect(r.spans, isEmpty);
    expect(spansDirFor(dir.path).existsSync(), isFalse);
    expect(store.state.recording, sets.first);
    expect(store.state.sleepKit, isFalse);
    // the header is still one the laptop's reader and the old readers take: only the new optional field is added
    final j = jsonDecode(File('${dir.path}/${sets.first}.header.json').readAsStringSync()) as Map;
    expect(j['recording'], sets.first);
    expect(j.containsKey('session'), isFalse);
  });

  test('Sleep: a sleep span that started the recording, closed by Stop; a line in the log and the markers', () async {
    final r = recorder(FakeFinder([FakeBand('a')]));
    final running = r.run(restartedBySystem: false);
    await wait(300);
    final id = stems().single;
    final open = statuses.last.rec.spans.single;
    expect(open.id, '$id-1');
    expect(open.kind, 'sleep');
    expect(open.closed, isFalse);
    expect(statuses.last.rec.sleep, isTrue);
    // on storage while the recording runs
    expect(readSpans(spansFileOf(spansDirFor(dir.path), id)).spans.single.closed, isFalse);
    await r.stop();
    await running;

    final s = readSpans(spansFileOf(spansDirFor(dir.path), id)).spans.single;
    expect(s.source, 'owner_button');
    expect(s.label, 'in_bed');
    expect(s.startedRecording, isTrue);
    expect(s.endedBy, 'recording_stopped');
    expect(s.end, isNotNull);
    final markers = File('${dir.path}/$id.markers.jsonl').readAsStringSync();
    expect(markers, contains('span: sleep start'));
    expect(markers, contains('span: sleep end'));
    expect(File('${dir.path}/$id.log').readAsStringSync(), contains('span: sleep end'));
  });

  test('the headband watcher\'s start: the sleep span says auto_start', () async {
    final r = recorder(FakeFinder([FakeBand('a')]), source: 'auto_start');
    final running = r.run(restartedBySystem: false);
    await wait(200);
    await r.stop();
    await running;
    expect(readSpans(spansFileOf(spansDirFor(dir.path), stems().single)).spans.single.source, 'auto_start');
  });

  test('spans by command: opened once per kind, closed by id, numbered in order', () async {
    final r = recorder(FakeFinder([FakeBand('a')]), sleep: false);
    final running = r.run(restartedBySystem: false);
    await wait(200);
    final id = stems().single;
    final work = r.openSpan('work', session: 'work-sessions/x.work.json');
    expect(r.openSpan('work').id, work.id); // the same kind already open: that span
    final unknown = r.openSpan('gardening');
    expect([work.id, unknown.id], ['$id-1', '$id-2']);
    expect(r.closeSpan(work.id)!.endedBy, 'owner');
    expect(r.closeSpan(work.id), isNull); // closed already
    expect(r.closeSpan('$id-9'), isNull);
    expect(statuses.last.rec.open()!.kind, 'gardening');
    await r.stop();
    await running;

    final back = readSpans(spansFileOf(spansDirFor(dir.path), id)).spans;
    expect([for (final s in back) (s.kind, s.endedBy, s.label)], [('work', 'owner', 'working'), ('gardening', 'recording_stopped', null)]);
    expect(back.first.session, 'work-sessions/x.work.json');
  });

  test('no headband ever found: the spans are kept under the start\'s stamp', () async {
    final r = recorder(FakeFinder([]));
    final running = r.run(restartedBySystem: false);
    await wait(100);
    expect(statuses.last.rec.id, isNull);
    expect(statuses.last.rec.spans.single.id, '?-1');
    await r.stop();
    await running;
    expect(stems(), isEmpty);
    final kept = spansIn(spansDirFor(dir.path));
    expect(kept.keys.single, matches(RegExp(r'^\d{4}-\d{2}-\d{2}-\d{6}$')));
    expect(kept.values.single.spans.single.id, '${kept.keys.single}-1');
    expect(kept.values.single.spans.single.endedBy, 'recording_stopped');
  });

  test('a service restarted by Android: the same recording id and the same open span', () async {
    final first = recorder(FakeFinder([FakeBand('a')]));
    final running = first.run(restartedBySystem: false);
    await wait(200);
    await first.stop(endNight: false); // the system destroys the service
    await running;
    final id = stems().single;
    expect(store.state.active, isTrue);
    expect(store.state.spans.single['span'], '$id-1');

    final second = recorder(FakeFinder([], direct: [FakeBand('a')]));
    final again = second.run(restartedBySystem: true);
    await wait(1100);
    expect(statuses.last.rec.openSleep!.id, '$id-1');
    await second.stop();
    await again;
    final sets = stems();
    expect(sets.length, greaterThanOrEqualTo(2));
    expect({for (final s in sets) header(s).recording}, {id});
    final s = readSpans(spansFileOf(spansDirFor(dir.path), id)).spans.single;
    expect(s.endedBy, 'recording_stopped');
  });

  test('a saved state from before Record first reads as a night: the sleep kit on, no recording id', () {
    final old = NightState.fromJson({'active': true, 'startMs': 5});
    expect(old.sleepKit, isTrue);
    expect(old.recording, isNull);
    expect(old.spans, isEmpty);
    final now = NightState.fromJson(jsonDecode(jsonEncode(const NightState(active: true, recording: 'r', sleepKit: false).toJson())));
    expect((now.recording, now.sleepKit), ('r', false));
  });
}

// ---- step 2: Sleep on a running recording, the headband gone for long ----------------------------------------------

class _Scorer implements NightScorer {
  int adds = 0, closes = 0;
  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #add) adds++;
    if (i.memberName == #close) {
      closes++;
      return Future<void>.value();
    }
    if (i.memberName == #takeEvents) return const <String>[];
    return null;
  }
}

void sleepOnARecording() {
  late Directory files, dir;
  late MemoryNightStore store;
  late List<RecorderStatus> statuses;
  var now = DateTime(2026, 11, 21, 11, 2);
  DateTime clock() => now;

  setUp(() {
    files = Directory.systemTemp.createTempSync('record_first_test');
    dir = Directory('${files.path}/recordings')..createSync();
    store = MemoryNightStore();
    statuses = [];
    now = DateTime(2026, 11, 21, 11, 2);
  });
  tearDown(() => files.deleteSync(recursive: true));

  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));
  SpansFile spans() => spansIn(spansDirFor(dir.path)).values.single;

  test('Sleep 3 hours into a recording: a span from then, a fresh kit, the alarm at the span; Stop sleep keeps recording', () async {
    final kits = <_Scorer>[];
    final band = FakeBand('a');
    final r = NightRecorder(
      finder: FakeFinder([band]),
      dir: dir,
      store: store,
      onStatus: statuses.add,
      onStuck: (_) async {},
      timing: fast,
      watch: null,
      clock: clock,
      spanLog: SpanLog(spansDirFor(dir.path), clock: clock),
      sleep: false,
      kit: () {
        kits.add(_Scorer());
        return (scorer: kits.last, alarm: null, cues: null);
      },
    );
    final running = r.run(restartedBySystem: false);
    await wait(200);
    expect(statuses.last.rec.sleep, isFalse);
    expect(statuses.last.alarm, isNull);
    now = now.add(const Duration(hours: 3));
    final plan = AlarmPlan(endMs: now.add(const Duration(hours: 8)).millisecondsSinceEpoch, windowMin: 30);
    final span = r.startSleep(plan: plan)!;
    expect(span.start, now);
    expect(span.startedRecording, isFalse);
    expect(r.startSleep(kind: 'nap')!.id, span.id); // Sleep and Nap never run together
    expect(kits, hasLength(1));
    expect(statuses.last.rec.sleep, isTrue);
    expect(statuses.last.alarm!.endMs, plan.endMs);
    r.lightsOff();
    await wait(50);
    expect(store.state.sleepKit, isTrue);
    expect(statuses.last.lightsOffMs, now.millisecondsSinceEpoch);

    now = now.add(const Duration(hours: 7));
    final before = band.emitted;
    final closed = (await r.stopSleep())!;
    expect(closed.end, now);
    expect(closed.endedBy, 'owner');
    expect(kits.single.closes, 1);
    expect(statuses.last.rec.sleep, isFalse);
    expect(statuses.last.alarm, isNull);
    expect(statuses.last.lightsOffMs, isNull);
    await wait(150);
    expect(band.emitted, greaterThan(before)); // the recording goes on
    expect(statuses.last.phase, Phase.recording);

    // a second sleep in the same recording gets its own span and its own model
    final second = r.startSleep(kind: 'nap')!;
    expect(second.id, isNot(span.id));
    expect(kits, hasLength(2));
    await r.stop();
    await running;
    expect([for (final s in spans().spans) (s.kind, s.endedBy)], [('sleep', 'owner'), ('nap', 'recording_stopped')]);
    expect(Directory(dir.path).listSync().where((f) => f.path.endsWith('.f32')), hasLength(1));
  });

  test('the headband gone 60 minutes: open spans end at the last data; 6 hours: the recording stops itself', () async {
    final band = FakeBand('a');
    var gaveUp = 0;
    late NightRecorder r;
    r = NightRecorder(
      finder: FakeFinder([band]),
      dir: dir,
      store: store,
      onStatus: statuses.add,
      onStuck: (_) async {},
      timing: fast,
      watch: null,
      clock: clock,
      spanLog: SpanLog(spansDirFor(dir.path), clock: clock),
      onGiveUp: () {
        gaveUp++;
        r.stop();
      },
    );
    final running = r.run(restartedBySystem: false);
    await wait(200);
    r.openSpan('work');
    final lastData = now;
    band.goOutOfRange();
    await wait(100);
    expect(statuses.last.rec.spans.every((s) => !s.closed), isTrue); // a short loss: the spans stay open
    now = now.add(const Duration(minutes: 61));
    await wait(150);
    final after = statuses.last.rec;
    expect([for (final s in after.spans) (s.kind, s.endedBy, s.end)], [('sleep', 'headband_off', lastData), ('work', 'headband_off', lastData)]);
    expect(after.sleep, isFalse);
    expect(gaveUp, 0);
    now = now.add(const Duration(hours: 5));
    await wait(150);
    await running;
    expect(gaveUp, 1);
    expect(store.state.active, isFalse);
    expect(File('${dir.path}/${after.id}.log').readAsStringSync(), contains('no data for 6 h: the recording stops itself'));
  });
}
