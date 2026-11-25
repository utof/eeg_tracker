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
import 'package:eeg_tracker/spans/activities.dart' show undoOffCommand;
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
    // an activity still marked at Stop was left open (its page had gone): the recorder says so
    expect([for (final s in back) (s.kind, s.endedBy, s.label)], [('work', 'owner', 'working'), ('gardening', 'left_open', null)]);
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
    // a span pressed now, with the headband still away, is not the rule's to end: its 60 minutes start at the press
    final pressed = now;
    r.openSpan('meditate');
    await wait(150);
    expect(statuses.last.rec.open('meditate'), isNotNull, reason: 'ended a minute after it was pressed');
    now = now.add(const Duration(minutes: 59));
    await wait(150);
    expect(statuses.last.rec.open('meditate'), isNotNull);
    now = now.add(const Duration(minutes: 2));
    await wait(150);
    final late = statuses.last.rec.spans.last;
    expect((late.kind, late.endedBy, late.end), ('meditate', 'headband_off', pressed), reason: 'no data in it: it ends where it began');
    now = now.add(const Duration(hours: 4));
    await wait(150);
    await running;
    expect(gaveUp, 1);
    expect(store.state.active, isFalse);
    expect(File('${dir.path}/${after.id}.log').readAsStringSync(), contains('no data for 6 h: the recording stops itself'));
  });

  test('"Still going? Undo" after the 60-minute rule: what it ended is open again, the sleep kit back on', () async {
    final first = FakeBand('a');
    final ended = <List<Span>>[];
    final r = NightRecorder(
      finder: FakeFinder([first]),
      dir: dir,
      store: store,
      onStatus: statuses.add,
      onStuck: (_) async {},
      timing: fast,
      watch: null,
      clock: clock,
      spanLog: SpanLog(spansDirFor(dir.path), clock: clock),
      onSpansEnded: ended.add,
    );
    final running = r.run(restartedBySystem: false);
    await wait(200);
    r.openSpan('work');
    final lastData = now;
    first.goOutOfRange();
    await wait(100);
    expect(statuses.last.rec.undoable, isEmpty);
    now = now.add(const Duration(minutes: 61));
    await wait(150);
    // the rule ended both, told whoever shows the notice, and offers Undo
    expect([for (final s in ended.single) (s.kind, s.end)], [('sleep', lastData), ('work', lastData)]);
    expect([for (final s in statuses.last.rec.undoable) s.kind], ['sleep', 'work']);
    expect(statuses.last.rec.sleep, isFalse);

    r.spanCommand(undoOffCommand);
    final back = statuses.last.rec;
    expect([for (final s in back.spans) (s.kind, s.closed, s.endedBy)], [('sleep', false, null), ('work', false, null)]);
    expect(back.spans.map((s) => s.id), ended.single.map((s) => s.id), reason: 'the same spans, not new ones');
    expect(back.sleep, isTrue, reason: 'the sleep kit is attached again');
    expect(back.undoable, isEmpty);
    final file = spans();
    expect([for (final s in file.spans) (s.kind, s.end)], [('sleep', null), ('work', null)], reason: 'the last line per span wins');
    // the headband is still away: many loop turns later the Undo still stands, and nothing new was told
    await wait(200);
    now = now.add(const Duration(minutes: 30));
    await wait(200);
    expect([for (final s in statuses.last.rec.spans) (s.kind, s.closed)], [('sleep', false), ('work', false)], reason: 'the rule undid the Undo');
    expect(statuses.last.rec.sleep, isTrue);
    expect(ended, hasLength(1), reason: 'a second "Headband off for 60 minutes" notice');
    // another 60 minutes without the headband after the Undo: the rule speaks again, and ends them at the same last data
    now = now.add(const Duration(minutes: 31));
    await wait(200);
    expect(ended, hasLength(2));
    expect([for (final s in statuses.last.rec.spans) (s.kind, s.endedBy, s.end)], [('sleep', 'headband_off', lastData), ('work', 'headband_off', lastData)]);
    await r.stop();
    await running;
    expect(File('${dir.path}/${back.id}.log').readAsStringSync(), contains('Undo: sleep, work go on'));
  });

  test('Sleep pressed after the headband was away for over an hour stays marked (the evening: dinner, a shower, then bed)', () async {
    final band = FakeBand('a'), again = FakeBand('b');
    final finder = FakeFinder([band]);
    final ended = <List<Span>>[];
    final r = NightRecorder(
      finder: finder,
      dir: dir,
      store: store,
      onStatus: statuses.add,
      onStuck: (_) async {},
      timing: fast,
      watch: null,
      clock: clock,
      spanLog: SpanLog(spansDirFor(dir.path), clock: clock),
      onSpansEnded: ended.add,
      sleep: false,
    );
    final running = r.run(restartedBySystem: false);
    await wait(200);
    band.goOutOfRange();
    await wait(100);
    now = now.add(const Duration(minutes: 90));
    await wait(150);
    final pressed = now;
    final sleep = r.startSleep()!;
    await wait(300); // many loop turns with the headband still not back
    expect(statuses.last.rec.openSleep?.id, sleep.id, reason: 'Sleep was ended within a minute of the press');
    expect(statuses.last.rec.sleep, isTrue, reason: 'the sleep kit was taken off');
    expect(ended, isEmpty, reason: 'a "Headband off for 60 minutes" notice for a span pressed a moment ago');
    // the headband is back ten minutes later: the night goes on in that span
    now = now.add(const Duration(minutes: 10));
    finder.bands.add(again);
    await wait(300);
    expect(statuses.last.phase, Phase.recording);
    expect(statuses.last.rec.openSleep?.start, pressed);
    await r.stop();
    await running;
    expect(spans().spans.single.endedBy, 'recording_stopped');
  });

  // ---- the rest of the night after the 60-minute rule (DECISIONS 1015) ----

  /// A recording whose headband was lost for 61 minutes; [also]: a span opened beside what the start opened.
  Future<({NightRecorder r, Future<void> running, FakeFinder finder, DateTime lastData, List<Span> resumed})> lostAnHour({
    bool sleep = true,
    String? also,
    bool resume = true,
  }) async {
    final band = FakeBand('a');
    final finder = FakeFinder([band]);
    final resumed = <Span>[];
    final r = NightRecorder(
      finder: finder,
      dir: dir,
      store: store,
      onStatus: statuses.add,
      onStuck: (_) async {},
      timing: fast,
      watch: null,
      clock: clock,
      spanLog: SpanLog(spansDirFor(dir.path), clock: clock),
      onSleepResumed: resumed.add,
      sleep: sleep,
      resumeSleep: resume,
    );
    final running = r.run(restartedBySystem: false);
    await wait(200);
    if (also != null) r.openSpan(also);
    final lastData = now;
    band.goOutOfRange();
    await wait(100);
    now = now.add(const Duration(minutes: 61));
    await wait(150);
    expect(statuses.last.rec.spans.every((s) => s.endedBy == 'headband_off'), isTrue);
    return (r: r, running: running, finder: finder, lastData: lastData, resumed: resumed);
  }

  test('the 60-minute rule ended Sleep and the headband comes back: the app opens a new sleep stretch by itself from '
      'the first new sample, marked as its own guess', () async {
    final w = await lostAnHour();
    now = now.add(const Duration(minutes: 40));
    final back = now;
    w.finder.bands.add(FakeBand('b'));
    await wait(300);
    final rec = statuses.last.rec;
    expect(statuses.last.phase, Phase.recording);
    expect([for (final s in rec.spans) (s.kind, s.source, s.end, s.endedBy)], [
      ('sleep', 'owner_button', w.lastData, 'headband_off'),
      ('sleep', 'auto_resume', null, null),
    ]);
    expect(rec.spans.last.start, back, reason: 'from the first new sample: the gap stays a gap');
    expect(rec.sleep, isTrue, reason: 'the sleep kit is on again');
    expect(rec.resumed?.id, rec.spans.last.id);
    expect(rec.undoable, isEmpty);
    expect(w.resumed.single.id, rec.spans.last.id, reason: 'told once');
    await wait(200);
    expect(w.resumed, hasLength(1));
    expect(statuses.last.rec.spans, hasLength(2));
    await w.r.stop();
    await w.running;
    final file = spans().spans;
    expect([for (final s in file) (s.source, s.endedBy)], [('owner_button', 'headband_off'), ('auto_resume', 'recording_stopped')]);
    expect(File('${dir.path}/${rec.id}.log').readAsStringSync() + dir.listSync().whereType<File>().where((f) => f.path.endsWith('.log')).map((f) => f.readAsStringSync()).join(),
        contains('sleep goes on by itself'));
  });

  test('Undo of the app\'s own resume: that stretch ends where it began, the sleep kit is off, and it is not opened again', () async {
    final w = await lostAnHour();
    now = now.add(const Duration(minutes: 5));
    final back = now;
    w.finder.bands.add(FakeBand('b'));
    await wait(300);
    expect(statuses.last.rec.resumed, isNotNull);
    now = now.add(const Duration(minutes: 20));
    w.r.spanCommand(undoOffCommand);
    final rec = statuses.last.rec;
    expect([for (final s in rec.spans) (s.source, s.end, s.endedBy)], [
      ('owner_button', w.lastData, 'headband_off'),
      ('auto_resume', back, 'undone'),
    ]);
    expect(rec.sleep, isFalse);
    expect(rec.resumed, isNull);
    await wait(200); // samples keep coming
    expect(statuses.last.rec.spans, hasLength(2), reason: 'resumed again after the owner said no');
    expect(statuses.last.rec.sleep, isFalse);
    await w.r.stop();
    await w.running;
  });

  test('only Sleep is resumed: Work ended by the 60-minute rule stays ended when the headband comes back', () async {
    final w = await lostAnHour(sleep: false, also: 'work');
    w.finder.bands.add(FakeBand('b'));
    await wait(300);
    expect(statuses.last.phase, Phase.recording);
    expect([for (final s in statuses.last.rec.spans) (s.kind, s.endedBy)], [('work', 'headband_off')]);
    expect(w.resumed, isEmpty);
    await w.r.stop();
    await w.running;
  });

  test('the owner\'s Undo before the headband is back leaves nothing to resume; and the switch turns resuming off', () async {
    final w = await lostAnHour();
    w.r.spanCommand(undoOffCommand);
    w.finder.bands.add(FakeBand('b'));
    await wait(300);
    expect([for (final s in statuses.last.rec.spans) (s.source, s.closed)], [('owner_button', false)]);
    expect(w.resumed, isEmpty);
    await w.r.stop();
    await w.running;
    statuses.clear();
    store = MemoryNightStore();
    for (final f in dir.listSync()) {
      f.deleteSync(recursive: true);
    }
    final off = await lostAnHour(resume: false);
    off.finder.bands.add(FakeBand('c'));
    await wait(300);
    expect(statuses.last.phase, Phase.recording);
    expect([for (final s in statuses.last.rec.spans) (s.source, s.endedBy)], [('owner_button', 'headband_off')]);
    expect(statuses.last.rec.undoable, hasLength(1), reason: 'the rule\'s own Undo is still offered');
    await off.r.stop();
    await off.running;
  });

  test('Work left marked by a closed app is ended by Stop at the recording\'s last sample, and says it was left open', () async {
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
    );
    final running = r.run(restartedBySystem: false);
    await wait(200);
    r.startSleep(kind: 'nap');
    r.openSpan('work'); // marked beside the nap, as its own page would
    now = now.add(const Duration(minutes: 5));
    await wait(100);
    final lastData = now;
    band.goOutOfRange();
    await wait(100);
    now = now.add(const Duration(minutes: 30)); // the headband has been away half an hour when Stop is pressed
    final stopAt = now;
    await r.stop();
    await running;
    final got = [for (final s in spans().spans) (s.kind, s.endedBy, s.end)];
    expect(got, [('nap', 'recording_stopped', stopAt), ('work', 'left_open', lastData)]);
  });

  test('Sleep pressed while an activity is still marked ends that activity: one at a time', () async {
    final r = NightRecorder(
      finder: FakeFinder([FakeBand('a')]),
      dir: dir,
      store: store,
      onStatus: statuses.add,
      onStuck: (_) async {},
      timing: fast,
      watch: null,
      clock: clock,
      spanLog: SpanLog(spansDirFor(dir.path), clock: clock),
      sleep: false,
    );
    final running = r.run(restartedBySystem: false);
    await wait(200);
    r.openSpan('work'); // its page was closed: the span stayed open
    now = now.add(const Duration(minutes: 30));
    r.startSleep();
    expect([for (final s in statuses.last.rec.spans) (s.kind, s.closed, s.endedBy)], [('work', true, 'other_activity'), ('sleep', false, null)]);
    expect(statuses.last.rec.spans.first.end, now);
    await r.stop();
    await running;
  });

  test('the notices: what the 60-minute rule ended, and a recording that stopped itself', () {
    final at = DateTime(2026, 11, 25, 14, 5);
    Span off(int n, String kind) => Span(id: 'r-$n', kind: kind, start: at.subtract(const Duration(hours: 1)), end: at, endedBy: 'headband_off', source: 'owner_button');
    final one = spansEndedNotice([off(1, 'work')], awayMinutes: 60);
    expect(one.title, 'Headband off for 60 minutes');
    expect(one.text, 'Work was ended at 14:05, the last moment with a signal. Still going? Open the app and tap Undo.');
    expect(spansEndedNotice([off(1, 'sleep'), off(2, 'work')], awayMinutes: 60).text, startsWith('Sleep and Work were ended at 14:05'));
    expect(undoLine([off(1, 'work')]), 'Work ended at 14:05: the headband was off for an hour. Still going?');
    expect(undoLine(const []), isNull);
    final stopped = recordingStoppedNotice(awayHours: 6);
    expect(stopped.title, 'Recording stopped');
    expect(stopped.text, contains('6 hours'));
    expect(stopped.text, contains('What was this recording?'));
  });

  test('Undo is not offered once something else was marked after the rule, or for an end you made', () async {
    final at = DateTime(2026, 11, 25, 14, 5);
    Span span(int n, String kind, {DateTime? end, String? by, DateTime? start}) =>
        Span(id: 'r-$n', kind: kind, start: start ?? at.subtract(const Duration(hours: 1)), end: end, endedBy: by, source: 'owner_button');
    final off = span(1, 'work', end: at, by: 'headband_off');
    expect(RecordingLive(id: 'r', spans: [off]).undoable, [off]);
    expect(RecordingLive(id: 'r', spans: [span(1, 'work', end: at, by: 'owner')]).undoable, isEmpty);
    expect(
      RecordingLive(id: 'r', spans: [off, span(2, 'meditate', start: at.add(const Duration(minutes: 90)))]).undoable,
      isEmpty,
      reason: 'you went on to something else',
    );
    // an older headband_off end is not offered again beside a newer one
    final older = span(1, 'sleep', end: at.subtract(const Duration(hours: 5)), by: 'headband_off', start: at.subtract(const Duration(hours: 9)));
    final newer = span(2, 'work', end: at, by: 'headband_off');
    expect(RecordingLive(id: 'r', spans: [older, newer]).undoable, [newer]);
  });
}
