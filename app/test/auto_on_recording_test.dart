// Work on a running recording (DECISIONS 1107-1109): the laptop's work word arrives while the headband records. The
// watcher does no worn check (the recorder holds the headband); it looks at the Work setting, at "quiet after Not
// now", at the word's age, at what is marked now and at whether data is arriving, then opens the work page or asks.
// Every other trigger during a recording is still skipped as busy.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/auto/controller.dart';
import 'package:eeg_tracker/auto/laptop.dart';
import 'package:eeg_tracker/auto/log.dart';
import 'package:eeg_tracker/auto/probe.dart';
import 'package:eeg_tracker/auto/rules.dart';
import 'package:eeg_tracker/auto/store.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show Sample;
import 'package:eeg_tracker/spans/span.dart';
import 'package:flutter_test/flutter_test.dart';

class NeverCheck implements HeadbandCheck {
  int checks = 0;

  @override
  bool get holding => false;

  @override
  Future<ProbeResult> check({required bool keepIfWorn, required void Function(DateTime, List<Sample>) onBatch}) async {
    checks++;
    return const ProbeResult(near: false);
  }

  @override
  Future<void> release() async {}
}

class FakePhone implements AutoPhone {
  String? busyWith = recordingBusy;
  final List<AutoQuestion> asked = [];
  int withdrawn = 0;
  void Function(AutoQuestion q)? onAsk;

  @override
  Future<PhoneContext> context(DateTime now) async => PhoneContext(now: now);

  @override
  Future<String?> busy() async => busyWith;

  @override
  Future<void> ask(AutoQuestion q) async {
    asked.add(q);
    onAsk?.call(q);
  }

  @override
  Future<void> withdraw() async => withdrawn++;

  @override
  Future<void> notice(String title, String text) async {}

  @override
  Future<void> offer(WearKind kind) async {}
}

class FakeStarter implements AutoStarter {
  final List<({bool quiet, Duration? limit})> works = [];
  int nights = 0;
  bool workOpens = true;

  @override
  Future<String?> startNight({required List<String> notes}) async {
    nights++;
    return null;
  }

  @override
  Future<bool> openWork({required bool quiet, Duration? limit}) async {
    works.add((quiet: quiet, limit: limit));
    return workOpens;
  }
}

void main() {
  late Directory tmp;
  late AutoStore store;
  late FakePhone phone;
  late FakeStarter starter;
  late NeverCheck check;
  late AutoWatch w;
  late DateTime now;
  RunningRecording? running;

  Map<String, Object?> last(String event) => AutoLog(store.dir).events().lastWhere((e) => e['event'] == event);
  List<String> skips() => [
    for (final e in AutoLog(store.dir).events())
      if (e['event'] == 'skipped') '${e['why']}',
  ];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('auto-on-rec');
    final rec = Directory('${tmp.path}/recordings')..createSync();
    store = AutoStore(autoDirFor(rec.path));
    phone = FakePhone();
    starter = FakeStarter();
    check = NeverCheck();
    now = DateTime(2026, 11, 26, 10, 0);
    running = (id: '2026-11-26-080000', lastData: now.subtract(const Duration(seconds: 20)), open: const <Span>[]);
    w = AutoWatch(
      recordings: rec.path,
      check: check,
      phone: phone,
      starter: starter,
      clock: () => now,
      waitFor: (_) => Completer<void>().future,
      running: () => running,
    );
    LaptopStore(store.dir).save(LaptopWork(working: true, at: now.subtract(const Duration(minutes: 1))));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('Automatic: the work page is opened on the recording, silently, with no worn check', () async {
    store.saveSettings(const AutoSettings().withChoice(WearKind.work, AutoChoice.start));
    await w.handle(const AutoTrigger('laptop'));
    expect(check.checks, 0, reason: 'the recorder holds the headband');
    expect(starter.works.single.quiet, isTrue);
    expect(starter.works.single.limit, isNull);
    expect(starter.nights, 0);
    expect(phone.asked, isEmpty);
    final start = last('start');
    expect(start['kind'], 'work');
    expect(start['how'], 'automatic');
    expect(start['recording'], '2026-11-26-080000');
    expect(last('check')['on_recording'], '2026-11-26-080000');
    expect(last('check')['guess'], 'work');
  });

  test('Automatic with the chime switched on is not quiet', () async {
    store.saveSettings(const AutoSettings().withChoice(WearKind.work, AutoChoice.start).withChime(true));
    await w.handle(const AutoTrigger('laptop'));
    expect(starter.works.single.quiet, isFalse);
  });

  test('Ask me (the default): one question in plain words; Start is logged, nothing is opened by the watcher', () async {
    phone.onAsk = (q) => scheduleMicrotask(() => w.answer(q.id, 'yes'));
    await w.handle(const AutoTrigger('laptop'));
    final q = phone.asked.single;
    expect(q.kind, WearKind.work);
    expect(q.title, 'The laptop says you are working');
    expect(q.text, startsWith('Work session on this recording?'));
    expect(q.actions, const [('yes', 'Start'), ('no', 'Not now')]);
    expect(starter.works, isEmpty, reason: 'the tap itself opens the work page');
    expect(last('answer')['answer'], 'yes');
    expect(last('start')['how'], 'yes');
    expect(last('start')['recording'], '2026-11-26-080000');
    expect(phone.withdrawn, 1);
  });

  test('Not now: quiet for 30 minutes, then asked again', () async {
    phone.onAsk = (q) => scheduleMicrotask(() => w.answer(q.id, 'no'));
    await w.handle(const AutoTrigger('laptop'));
    expect(phone.asked, hasLength(1));
    now = now.add(const Duration(minutes: 10));
    LaptopStore(store.dir).save(LaptopWork(working: true, at: now));
    running = (id: '2026-11-26-080000', lastData: now, open: const <Span>[]);
    await w.handle(const AutoTrigger('laptop'));
    expect(phone.asked, hasLength(1));
    expect(skips().last, 'quiet after Not now (work)');
    now = now.add(const Duration(minutes: 25));
    LaptopStore(store.dir).save(LaptopWork(working: true, at: now));
    running = (id: '2026-11-26-080000', lastData: now, open: const <Span>[]);
    await w.handle(const AutoTrigger('laptop'));
    expect(phone.asked, hasLength(2));
  });

  test('Do nothing: nothing happens', () async {
    store.saveSettings(const AutoSettings().withChoice(WearKind.work, AutoChoice.nothing));
    await w.handle(const AutoTrigger('laptop'));
    expect(starter.works, isEmpty);
    expect(phone.asked, isEmpty);
    expect(skips().last, 'Do nothing (work)');
  });

  test('something is marked now (sleep, a work session, anything): nothing happens', () async {
    store.saveSettings(const AutoSettings().withChoice(WearKind.work, AutoChoice.start));
    running = (
      id: '2026-11-26-080000',
      lastData: now,
      open: [Span(id: '2026-11-26-080000-1', kind: 'sleep', start: now.subtract(const Duration(hours: 1)), source: 'owner_button')],
    );
    await w.handle(const AutoTrigger('laptop'));
    expect(starter.works, isEmpty);
    expect(phone.asked, isEmpty);
    expect(skips().last, 'marked now: sleep');
  });

  test('no data in the last 2 minutes (the headband is away): nothing happens', () async {
    store.saveSettings(const AutoSettings().withChoice(WearKind.work, AutoChoice.start));
    running = (id: '2026-11-26-080000', lastData: now.subtract(const Duration(minutes: 3)), open: const <Span>[]);
    await w.handle(const AutoTrigger('laptop'));
    expect(starter.works, isEmpty);
    expect(skips().last, 'no data from the headband in the last 2 minutes');
  });

  test('the laptop\'s word is old or says "not working": nothing happens', () async {
    store.saveSettings(const AutoSettings().withChoice(WearKind.work, AutoChoice.start));
    LaptopStore(store.dir).save(LaptopWork(working: true, at: now.subtract(const Duration(minutes: 16))));
    await w.handle(const AutoTrigger('laptop'));
    LaptopStore(store.dir).save(LaptopWork(working: false, at: now));
    await w.handle(const AutoTrigger('laptop'));
    expect(starter.works, isEmpty);
    expect(skips(), everyElement('the laptop does not say "working" now'));
  });

  test('no running recording is found in the files: nothing happens', () async {
    store.saveSettings(const AutoSettings().withChoice(WearKind.work, AutoChoice.start));
    running = null;
    await w.handle(const AutoTrigger('laptop'));
    expect(starter.works, isEmpty);
    expect(skips().last, 'the running recording was not found');
  });

  test('Android would not open the work page: it asks instead', () async {
    store.saveSettings(const AutoSettings().withChoice(WearKind.work, AutoChoice.start));
    starter.workOpens = false;
    phone.onAsk = (q) => scheduleMicrotask(() => w.answer(q.id, 'none'));
    await w.handle(const AutoTrigger('laptop'));
    expect(phone.asked.single.title, 'The laptop says you are working');
    expect(last('start')['error'], 'Android did not let the app open its page');
  });

  test('every other trigger during a recording is still skipped, and so is a laptop word during a session', () async {
    store.saveSettings(const AutoSettings().withChoice(WearKind.work, AutoChoice.start));
    for (final r in const ['presence', 'bedtime', 'opened']) {
      await w.handle(AutoTrigger(r));
    }
    phone.busyWith = 'session';
    await w.handle(const AutoTrigger('laptop'));
    expect(starter.works, isEmpty);
    expect(phone.asked, isEmpty);
    expect(skips(), [
      'busy: night recording',
      'busy: night recording',
      'busy: night recording',
      'busy: session',
    ]);
  });

  test('the running recording is read from the files: the newest set, its id, its open marks', () {
    final rec = Directory('${tmp.path}/recordings');
    expect(runningRecordingOf(rec), isNull);
    File('${rec.path}/2026-11-26-080000.f32').writeAsBytesSync(List<int>.filled(16 * 250, 0));
    final spans = spansDirFor(rec.path)..createSync(recursive: true);
    final open = Span(id: '2026-11-26-080000-2', kind: 'meditate', start: DateTime(2026, 11, 26, 9, 30), source: 'owner_button');
    final closed = Span(
      id: '2026-11-26-080000-1',
      kind: 'work',
      start: DateTime(2026, 11, 26, 8, 30),
      end: DateTime(2026, 11, 26, 9),
      source: 'owner_button',
    );
    spansFileOf(spans, '2026-11-26-080000').writeAsStringSync('${jsonEncode(closed.toLine(DateTime(2026, 11, 26, 9)))}\n${jsonEncode(open.toLine(DateTime(2026, 11, 26, 9, 30)))}\n');
    final r = runningRecordingOf(rec)!;
    expect(r.id, '2026-11-26-080000');
    expect([for (final s in r.open) s.kind], ['meditate']);
    expect(r.lastData, isNotNull);
  });
}
