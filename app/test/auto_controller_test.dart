// Automatic recording, phase 1 (DECISIONS 600-609): what the watcher does when something wakes it (a presence event, a
// bedtime check, the laptop, the app opened), with fakes for the headband check, the phone, the clock and the
// notification answers. "Not now" writes nothing; "Yes" starts the night at the real start; the battery guard; the
// offer after 10 yes in a row; never during a recording or a session.
import 'dart:async';
import 'dart:io';

import 'package:eeg_tracker/auto/controller.dart';
import 'package:eeg_tracker/auto/laptop.dart';
import 'package:eeg_tracker/auto/log.dart';
import 'package:eeg_tracker/auto/probe.dart';
import 'package:eeg_tracker/auto/rules.dart';
import 'package:eeg_tracker/auto/store.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show ChunkWriter, Sample;
import 'package:flutter_test/flutter_test.dart';

List<Sample> batch(int first) => [
  for (var i = 0; i < 8; i++) (pack: first + i, o1: 1e-5, o2: 2e-5, t3: -1e-5, t4: 3e-6),
];

/// The headband check: what it finds, and the batches it streams while held.
class FakeCheck implements HeadbandCheck {
  FakeCheck(this.result);
  ProbeResult result;
  final List<bool> keeps = [];
  int checks = 0, releases = 0;
  void Function(DateTime, List<Sample>)? _sink;

  @override
  bool get holding => _sink != null;

  @override
  Future<ProbeResult> check({required bool keepIfWorn, required void Function(DateTime, List<Sample>) onBatch}) async {
    checks++;
    keeps.add(keepIfWorn);
    if (keepIfWorn && result.worn == true) _sink = onBatch;
    return result;
  }

  void stream(DateTime t, int first) => _sink?.call(t, batch(first));

  @override
  Future<void> release() async {
    if (_sink != null) releases++;
    _sink = null;
  }
}

class FakePhone implements AutoPhone {
  PhoneContext Function(DateTime now) ctx = (now) => PhoneContext(now: now);
  String? busyWith;
  final List<AutoQuestion> asked = [];
  final List<(String, String)> notices = [];
  final List<WearKind> offers = [];
  int withdrawn = 0;
  void Function(AutoQuestion q)? onAsk;

  @override
  Future<PhoneContext> context(DateTime now) async => ctx(now);

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
  Future<void> notice(String title, String text) async => notices.add((title, text));

  @override
  Future<void> offer(WearKind kind) async => offers.add(kind);
}

class FakeStarter implements AutoStarter {
  final List<List<String>> nights = [];
  final List<({bool quiet, Duration? limit})> works = [];
  bool workOpens = true;

  @override
  Future<String?> startNight({required List<String> notes}) async {
    nights.add(notes);
    return null;
  }

  @override
  Future<bool> openWork({required bool quiet, Duration? limit}) async {
    works.add((quiet: quiet, limit: limit));
    return workOpens;
  }
}

const ProbeResult wornBand = ProbeResult(
  near: true,
  worn: true,
  how: 'resistance',
  ohms: {'O1': 400e3, 'O2': 600e3, 'T3': 900e3, 'T4': 1.2e6},
  battery: 100,
  name: 'BB Black',
);

const ProbeResult offHead = ProbeResult(
  near: true,
  worn: false,
  how: 'resistance',
  ohms: {'O1': null, 'O2': null, 'T3': null, 'T4': null},
  battery: 100,
  name: 'BB Black',
);

const ProbeResult notNear = ProbeResult(near: false);

void main() {
  late Directory tmp;
  late String rec;
  late AutoStore store;
  late FakeCheck check;
  late FakePhone phone;
  late FakeStarter starter;
  late DateTime now;
  late Completer<void> askTimeout;
  late AutoWatch w;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('autowatch');
    rec = '${tmp.path}/recordings';
    store = AutoStore(autoDirFor(rec));
    check = FakeCheck(wornBand);
    phone = FakePhone();
    starter = FakeStarter();
    now = DateTime(2026, 11, 20, 22, 30); // inside the default bedtime window (21:00 to 07:00)
    askTimeout = Completer<void>();
    w = AutoWatch(
      recordings: rec,
      check: check,
      phone: phone,
      starter: starter,
      clock: () => now,
      waitFor: (_) => askTimeout.future,
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  List<String> events() => [for (final e in AutoLog(store.dir).events()) e['event'] as String];
  Map<String, Object?> last(String event) => AutoLog(store.dir).events().lastWhere((e) => e['event'] == event);
  bool recordingsWritten() => Directory(rec).existsSync() && Directory(rec).listSync().isNotEmpty;

  /// Runs [trigger] until the question is posted, then answers it.
  Future<void> answered(AutoTrigger trigger, String answer, {void Function()? meanwhile}) async {
    phone.onAsk = (q) => scheduleMicrotask(() {
      meanwhile?.call();
      w.answer(q.id, answer);
    });
    await w.handle(trigger);
  }

  group('asking (the default)', () {
    test('a presence event at bedtime: a check, then one quiet question for the night', () async {
      phone.onAsk = (q) => scheduleMicrotask(() => w.answer(q.id, 'no'));
      await w.handle(const AutoTrigger('presence'));
      expect(check.checks, 1);
      expect(check.keeps, [true], reason: 'kept while asking');
      final q = phone.asked.single;
      expect(q.kind, WearKind.night);
      expect(q.title, 'Headband on. Start the night?');
      expect([for (final a in q.actions) a.$2], ['Start the night', 'Not now']);
      final c = last('check');
      expect((c['trigger'], c['worn'], c['guess'], c['choice'], c['battery']), ('presence', true, 'night', 'ask', 100));
      expect(c['reasons'], ['bedtime window (21:00-07:00)']);
    });

    test('"Not now" writes nothing, lets the headband go, and no question about the night for 30 minutes', () async {
      await answered(const AutoTrigger('bedtime'), 'no', meanwhile: () {
        for (var i = 0; i < 50; i++) {
          check.stream(now.add(Duration(milliseconds: 32 * i)), i * 8);
        }
      });
      expect(recordingsWritten(), isFalse);
      expect(starter.nights, isEmpty);
      expect(check.releases, 1);
      expect(last('answer')['answer'], 'no');
      expect(store.state().quiet(WearKind.night, now.add(const Duration(minutes: 29))), isTrue);
      expect(events(), ['check', 'question', 'answer']);
      // 20 minutes later: quiet, not even a check
      now = now.add(const Duration(minutes: 20));
      await w.handle(const AutoTrigger('bedtime'));
      expect(check.checks, 1);
      expect(last('skipped')['why'], 'quiet after Not now (night)');
    });

    test('no answer in 15 minutes counts like Not now, logged as none; nothing is written', () async {
      phone.onAsk = (q) => scheduleMicrotask(() {
        check.stream(now, 0);
        askTimeout.complete();
      });
      await w.handle(const AutoTrigger('bedtime'));
      expect(last('answer')['answer'], 'none');
      expect(recordingsWritten(), isFalse);
      expect(starter.nights, isEmpty);
      expect(store.state().quiet(WearKind.night, now.add(const Duration(minutes: 1))), isTrue);
    });

    test('"Yes" writes the kept minutes as the night\'s first run, then starts the recorder', () async {
      final found = now;
      await answered(const AutoTrigger('bedtime'), 'yes', meanwhile: () {
        for (var i = 0; i < 10; i++) {
          check.stream(found.add(Duration(milliseconds: 32 * i)), i * 8);
        }
        now = now.add(const Duration(minutes: 3));
      });
      final files = Directory(rec).listSync().map((f) => f.uri.pathSegments.last).toList()..sort();
      expect(files, ['2026-11-20-223000.f32', '2026-11-20-223000.idx', '2026-11-20-223000.log']);
      expect(File('$rec/2026-11-20-223000.f32').lengthSync(), 80 * 20);
      expect(check.releases, 1, reason: 'let go before the recorder looks for it');
      final notes = starter.nights.single;
      expect(notes.join('\n'), contains('started after "Yes"'));
      expect(notes.join('\n'), contains('2026-11-20-223000'));
      final s = last('start');
      expect((s['kind'], s['how'], s['stem']), ('night', 'yes', '2026-11-20-223000'));
      expect(store.state().yesStreak[WearKind.night], 1);
    });

    test('a start by hand while it asks: the headband is let go, the question withdrawn, nothing written', () async {
      phone.onAsk = (q) => scheduleMicrotask(() {
        check.stream(now, 0);
        unawaited(w.release());
      });
      await w.handle(const AutoTrigger('presence'));
      expect(check.releases, 1);
      expect(phone.withdrawn, greaterThanOrEqualTo(1));
      expect(recordingsWritten(), isFalse);
      expect(starter.nights, isEmpty);
      expect(last('answer')['answer'], 'released');
    });

    test('one question per wearing: still on 10 minutes later, no second question; off then on, asked again', () async {
      await answered(const AutoTrigger('bedtime'), 'none'); // no answer: quiet 30 min
      now = now.add(const Duration(minutes: 40));
      await w.handle(const AutoTrigger('bedtime'));
      expect(phone.asked, hasLength(1));
      expect(check.keeps.last, isFalse, reason: 'only to see whether the wearing goes on');
      expect(last('skipped')['why'], 'asked this wearing (night)');
      check.result = offHead;
      now = now.add(const Duration(minutes: 10));
      await w.handle(const AutoTrigger('bedtime'));
      expect(store.state().wornSince, isNull);
      check.result = wornBand;
      now = now.add(const Duration(minutes: 10));
      await answered(const AutoTrigger('bedtime'), 'no');
      expect(phone.asked, hasLength(2));
    });

    test('"Check now" asks even in the same wearing and in the quiet time', () async {
      await answered(const AutoTrigger('bedtime'), 'no');
      now = now.add(const Duration(minutes: 5));
      await answered(const AutoTrigger('now', force: true), 'no');
      expect(phone.asked, hasLength(2));
    });

    test('"other": the owner names it (night or work) or says not now', () async {
      now = DateTime(2026, 11, 20, 14, 0);
      await answered(const AutoTrigger('opened'), 'work');
      final q = phone.asked.single;
      expect(q.kind, WearKind.other);
      expect([for (final a in q.actions) a.$1], ['night', 'work', 'no']);
      expect(last('answer')['answer'], 'work');
      expect(last('start')['kind'], 'work');
      expect(recordingsWritten(), isFalse);
    });
  });

  group('starting automatically', () {
    test('the night: no question; the recorder starts with a note that says so; the check let go first', () async {
      store.saveSettings(const AutoSettings().withChoice(WearKind.night, AutoChoice.start));
      await w.handle(const AutoTrigger('bedtime'));
      expect(phone.asked, isEmpty);
      expect(check.keeps, [false]);
      expect(starter.nights.single.first, startsWith('started automatically'));
      expect(starter.nights.single.join(' '), contains('no sounds'));
      expect(last('start')['how'], 'automatic');
      expect(recordingsWritten(), isFalse, reason: 'the recorder writes; the watcher keeps nothing');
    });

    test('a work session: the laptop says work; silent unless the chime was switched on; the battery sets its end', () async {
      store.saveSettings(const AutoSettings().withChoice(WearKind.work, AutoChoice.start));
      now = DateTime(2026, 11, 20, 10, 0);
      LaptopStore(store.dir).save(LaptopWork(working: true, at: now.subtract(const Duration(minutes: 2))));
      check.result = wornBand.withBattery(80);
      await w.handle(const AutoTrigger('laptop'));
      expect(starter.works.single.quiet, isTrue);
      expect(starter.works.single.limit, const Duration(hours: 6, minutes: 30));
      store.saveSettings(store.settings().withChime(true));
      now = now.add(const Duration(hours: 2));
      check.result = offHead;
      await w.handle(const AutoTrigger('laptop')); // a new wearing
      check.result = wornBand.withBattery(80);
      LaptopStore(store.dir).save(LaptopWork(working: true, at: now));
      await w.handle(const AutoTrigger('laptop'));
      expect(starter.works.last.quiet, isFalse);
    });

    test('Android would not open the work page: it asks instead', () async {
      store.saveSettings(const AutoSettings().withChoice(WearKind.work, AutoChoice.start));
      now = DateTime(2026, 11, 20, 10, 0);
      LaptopStore(store.dir).save(LaptopWork(working: true, at: now));
      starter.workOpens = false;
      await answered(const AutoTrigger('laptop'), 'none');
      expect(phone.asked.single.kind, WearKind.work);
      expect(last('start')['error'], 'Android did not let the app open its page');
    });
  });

  group('the battery guard', () {
    test('daytime, too little for tonight: no question, no start; one "charge" line a day', () async {
      now = DateTime(2026, 11, 20, 20, 0);
      store.saveSettings(const AutoSettings(bedMin: 0, wakeMin: 8 * 60)); // window from 22:00
      check.result = wornBand.withBattery(60);
      await w.handle(const AutoTrigger('opened'));
      expect(phone.asked, isEmpty);
      expect(last('declined')['why'], 'Charge the headband for tonight.');
      expect(phone.notices.single.$1, 'Charge the headband for tonight');
      check.result = offHead;
      now = now.add(const Duration(minutes: 5));
      await w.handle(const AutoTrigger('opened'));
      check.result = wornBand.withBattery(60);
      now = now.add(const Duration(minutes: 5));
      await w.handle(const AutoTrigger('opened'));
      expect(phone.notices, hasLength(1), reason: 'once a day');
    });

    test('a night is never refused for the battery; the question says how long it lasts', () async {
      check.result = wornBand.withBattery(30);
      await answered(const AutoTrigger('bedtime'), 'no');
      expect(phone.asked.single.text, contains('about 3 h'));
    });
  });

  group('the offer after 10 yes in a row', () {
    Future<void> yesNight() async {
      check.result = offHead;
      now = now.add(const Duration(minutes: 10));
      await w.handle(const AutoTrigger('bedtime')); // ends the wearing
      check.result = wornBand;
      now = now.add(const Duration(minutes: 10));
      await answered(const AutoTrigger('bedtime'), 'yes');
    }

    test('offered once at the 10th yes; "Not now" sets the count back', () async {
      for (var i = 0; i < 9; i++) {
        await yesNight();
      }
      expect(phone.offers, isEmpty);
      await yesNight();
      expect(phone.offers, [WearKind.night]);
      expect(last('offer')['kind'], 'night');
      await yesNight();
      expect(phone.offers, hasLength(1), reason: 'once per streak');
      check.result = offHead;
      now = now.add(const Duration(minutes: 10));
      await w.handle(const AutoTrigger('bedtime'));
      check.result = wornBand;
      now = now.add(const Duration(minutes: 10));
      await answered(const AutoTrigger('bedtime'), 'no');
      expect(store.state().yesStreak[WearKind.night], 0);
      expect(store.state().offered, isEmpty);
    });

    test('taking the offer switches that kind to automatic; refusing keeps asking', () async {
      w.offerAnswer(WearKind.night, accept: false);
      expect(store.settings().choice(WearKind.night), AutoChoice.ask);
      w.offerAnswer(WearKind.night, accept: true);
      expect(store.settings().choice(WearKind.night), AutoChoice.start);
      expect([for (final e in AutoLog(store.dir).events()) if (e['event'] == 'offer_answer') e['accept']], [false, true]);
    });
  });

  group('when it does not check at all', () {
    test('during a night recording or a session: skipped, the headband untouched', () async {
      phone.busyWith = 'night recording';
      await w.handle(const AutoTrigger('presence'));
      expect(check.checks, 0);
      expect(last('skipped')['why'], 'busy: night recording');
    });

    test('"Do nothing" for the kind it guesses: no check', () async {
      store.saveSettings(const AutoSettings().withChoice(WearKind.night, AutoChoice.nothing));
      await w.handle(const AutoTrigger('bedtime'));
      expect(check.checks, 0);
      expect(last('skipped')['why'], 'Do nothing (night)');
    });

    test('the headband not near, or off the head: no question, the wearing ends', () async {
      check.result = notNear;
      await w.handle(const AutoTrigger('bedtime'));
      check.result = offHead;
      await w.handle(const AutoTrigger('bedtime'));
      expect(phone.asked, isEmpty);
      expect([for (final e in AutoLog(store.dir).events()) e['worn']], [null, false]);
      expect(store.state().wornSince, isNull);
    });

    test('within 30 minutes of a recording\'s last data (a night just stopped): no check, unless asked by hand', () async {
      ChunkWriter.open(Directory(rec), now.subtract(const Duration(hours: 8)))
        ..addBatch(now.subtract(const Duration(minutes: 10)), batch(0))
        ..close();
      await w.handle(const AutoTrigger('opened'));
      expect(check.checks, 0);
      expect(last('skipped')['why'], 'a recording ended at 22:20');
      await answered(const AutoTrigger('now', force: true), 'no');
      expect(check.checks, 1);
      store.saveState(const AutoState()); // forget that "Not now"
      now = now.add(const Duration(minutes: 25));
      await w.handle(const AutoTrigger('bedtime'));
      expect(check.checks, 2, reason: '35 minutes after');
    });

    test('contact not readable: not taken as worn', () async {
      check.result = const ProbeResult(near: true, worn: null, how: 'none', battery: 90);
      await w.handle(const AutoTrigger('bedtime'));
      expect(phone.asked, isEmpty);
      expect(starter.nights, isEmpty);
    });
  });
}
