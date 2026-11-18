// Alpha-theta without a phone: the rules (screening, pauses, length, the decision after 10, alertness, the
// reaction test), the notebook on disk, the per-step engine on the demo signal (rewards, lines, an exact replay of
// the log), and whole sessions through the controller with a fake headband (report, saved files, the sleep guard
// fading the bed and waking you).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/alphatheta/engine.dart';
import 'package:eeg_tracker/alphatheta/journal.dart';
import 'package:eeg_tracker/alphatheta/rules.dart';
import 'package:eeg_tracker/feedback/demo.dart';
import 'package:eeg_tracker/meditation/controller.dart';
import 'package:eeg_tracker/meditation/store.dart';
import 'package:eeg_tracker/meditation/tracker.dart';
import 'package:eeg_tracker/sound/feedback_sound.dart';
import 'package:eeg_tracker/sound/session_sound.dart';
import 'package:eeg_tracker/training/control.dart';
import 'package:flutter_test/flutter_test.dart' hide Finder;

import 'meditation_test.dart' show DemoBand, Finder, fast, until;

AfterSession after({int distress = 2, String memories = 'none', bool unreal = false, bool seizure = false}) =>
    AfterSession(distress: distress, memories: memories, unreal: unreal, seizure: seizure, control: 3);

/// A demo session through the engine: eyes open 30 s, then closed; alpha slows to [slowHz] from [slowFrom] s.
AlphaThetaEngine runDemo({
  required double seconds,
  int seed = 7,
  double slowFrom = 1e9,
  double slowHz = 6.5,
  int chunk = 250,
}) {
  final e = AlphaThetaEngine(), demo = DemoSignal(seed);
  while (e.core.n < seconds * 250) {
    demo.eyes = demo.t < 30 ? 'open' : 'closed';
    demo.alphaHz = demo.t >= slowFrom ? slowHz : 10;
    e.push(demo.next(chunk));
  }
  return e;
}

List<Map<String, Object?>> atLines(AlphaThetaEngine e) => [
  for (final l in e.core.log.lines)
    if (l['type'] == 'at') l,
];

void main() {
  test('screening, consent and the checklist are plain and complete', () {
    expect(screeningItems, hasLength(9));
    expect(
      screeningItems.join(' '),
      allOf(contains('PTSD'), contains('seizures'), contains('suicide'), contains('trauma therapy')),
    );
    expect(sideEffectItems, hasLength(7));
    expect(
      consentText.join(' '),
      allOf(contains('strong memories'), contains('not treatment'), contains('1 in 5'), contains('stop')),
    );
  });

  test('length: the first 3 sessions 15 min, then 20 or 25; after 10 a decision', () {
    expect(lengthChoices(0), [15]);
    expect(lengthChoices(2), [15]);
    expect(lengthChoices(3), [20, 25]);
    expect(needsDecision(9, null), isFalse);
    expect(needsDecision(10, null), isTrue);
    expect(needsDecision(14, DateTime(2026, 12, 1)), isFalse);
  });

  test('pause rules: distress, dissociation, seizure, memories twice, a side effect into the next day', () {
    expect(pauseReason(afters: [after()]), isNull);
    expect(pauseReason(afters: [after(distress: 7)]), contains('7 of 10'));
    expect(pauseReason(afters: [after(distress: 6)]), isNull);
    expect(pauseReason(afters: [after(unreal: true)]), contains('unreal'));
    expect(pauseReason(afters: [after(seizure: true)]), contains('doctor'));
    expect(
      pauseReason(afters: [after(memories: 'distressing')]),
      isNull,
      reason: 'once is not twice',
    );
    expect(
      pauseReason(
        afters: [
          after(memories: 'distressing'),
          after(memories: 'pleasant'),
        ],
      ),
      isNull,
    );
    expect(
      pauseReason(
        afters: [
          after(memories: 'distressing'),
          after(memories: 'distressing'),
        ],
      ),
      contains('two sessions'),
    );
    expect(
      pauseReason(
        before: const CheckIn(sleepiness: 3, distress: 2, effects: {1}, lasted: true),
        afters: const [],
      ),
      contains('next day'),
    );
    expect(pauseReason(before: const CheckIn(sleepiness: 3, distress: 8), afters: const []), contains('8 of 10'));
    expect(
      pauseReason(
        before: const CheckIn(sleepiness: 3, distress: 2, effects: {1}),
        afters: const [],
      ),
      isNull,
    );
  });

  test('alertness: slower than usual by over 10 %, or sleepy, says do not drive yet', () {
    final ok = alertness(medianMs: 320, usualMs: [300, 310, 290], sleepiness: 4);
    expect(ok.ok, isTrue);
    expect(ok.words, contains('your usual 300 ms'));
    final slow = alertness(medianMs: 340, usualMs: [300, 310, 290], sleepiness: 4);
    expect(slow.ok, isFalse);
    expect(slow.words, allOf(contains('Do not drive or cycle'), contains('10 minutes')));
    expect(alertness(medianMs: 300, usualMs: [300], sleepiness: 7).words, contains('sleepy'));
    expect(
      alertness(medianMs: 480, usualMs: const [], sleepiness: 3).ok,
      isTrue,
      reason: 'no usual yet: 500 ms is the line',
    );
    expect(alertness(medianMs: 520, usualMs: const [], sleepiness: 3).ok, isFalse);
  });

  test('reaction test: waits of 2-5 s, anticipations are false starts, median of at least 5 taps', () {
    final t = ReactionTest(seed: 1);
    final waits = [for (var i = 0; i < 200; i++) t.nextWaitMs()];
    expect(waits.every((w) => w >= 2000 && w <= 5000), isTrue);
    for (final ms in [250, 80, 300, 280, 320]) {
      t.tap(ms);
    }
    expect(t.median, isNull, reason: '4 counted taps');
    t.tap(2000);
    t.tap(260);
    expect(t.falseStarts, 1);
    expect(t.times, [250, 300, 280, 320, 1500, 260]);
    expect(t.median, 290);
    expect(t.lapses, 1);
  });

  test('notebook: profile and entries round trip; a resume is not undone by the same old answers', () {
    final dir = Directory.systemTemp.createTempSync('at');
    addTearDown(() => dir.deleteSync(recursive: true));
    final j = AtJournal(dir)..load();
    expect(j.profile.ready, isFalse);
    j.profile = j.profile.copyWith(
      screened: DateTime(2026, 11, 18),
      consented: DateTime(2026, 11, 18),
      contact: 'Anna 123',
    );
    j.entries.add(
      AtEntry(at: DateTime(2026, 11, 18, 21), before: const CheckIn(sleepiness: 4, distress: 1), beforeMs: 300),
    );
    j.entries[0] = j.entries[0].copyWith(stem: '2026-11-18-210000', complete: true, after: after(distress: 8));
    expect(j.applyPauseRules(DateTime(2026, 11, 18, 21, 30), afterSession: true), contains('8 of 10'));
    expect(j.profile.paused, isTrue);
    j.save();
    final back = AtJournal(dir)..load();
    expect(back.profile.contact, 'Anna 123');
    expect(back.profile.pausedWhy, contains('8 of 10'));
    expect(back.done, 1);
    expect(back.usualMs, [300]);
    expect(back.afters.single.distress, 8);
    back.profile = back.profile.copyWith(resume: true);
    expect(back.applyPauseRules(DateTime(2026, 11, 20), before: const CheckIn(sleepiness: 3, distress: 1)), isNull);
    expect(back.profile.paused, isFalse, reason: 'the check-in does not re-read the old after-session answers');
  });

  test('rewards: 1 s above, at most one per band every 2.5 s, theta wins a tie, gates give none', () {
    final r = AtRewards();
    final out = <String?>[];
    for (var i = 0; i < 60; i++) {
      out.add(r.update(gated: false, alphaAbove: true, thetaAbove: true));
    }
    expect(out[9], 'gong', reason: 'both due at the 10th step: the gong');
    expect(out.where((x) => x == 'chime').length, greaterThan(0));
    final at = [
      for (var i = 0; i < out.length; i++)
        if (out[i] != null) (i, out[i]),
    ];
    for (final band in ['chime', 'gong']) {
      final steps = [
        for (final (i, x) in at)
          if (x == band) i,
      ];
      for (var k = 1; k < steps.length; k++) {
        expect(steps[k] - steps[k - 1], greaterThanOrEqualTo(25), reason: '$band gap');
      }
    }
    final g = AtRewards();
    for (var i = 0; i < 40; i++) {
      expect(g.update(gated: i % 8 == 0, alphaAbove: true), i % 8 == 0 ? isNull : anything);
    }
    final none = AtRewards();
    expect(
      [for (var i = 0; i < 50; i++) none.update(gated: i % 9 == 0, alphaAbove: true)].whereType<String>(),
      isEmpty,
      reason: 'a gate every 0.9 s never lets 1 s pass',
    );
  });

  test('band line: raised after a block above its aim, lowered below, held between', () {
    final up = BandLine('alpha', 1, 0.2, AtRule.alphaAim);
    Map<String, Object?>? end;
    for (var i = 0; i < 1800; i++) {
      end = up.update(true, i) ?? end;
    }
    expect(end!['moved'], 1);
    expect(up.line, closeTo(1.03, 1e-12));
    final down = BandLine('theta', 1, 0.2, AtRule.thetaAim);
    for (var i = 0; i < 1800; i++) {
      down.update(i % 5 == 0, i);
    }
    expect(down.line, closeTo(0.97, 1e-12), reason: '20 % above is under the 30-40 % aim');
    final held = BandLine('theta', 1, 0.2, AtRule.thetaAim);
    for (var i = 0; i < 1800; i++) {
      held.update(i % 20 < 7 ? true : false, i);
    }
    expect(held.line, 1, reason: '35 % above is inside the aim');
  });

  test('engine: a demo session logs its control stream and replays line for line, whatever the chunking', () {
    final e = runDemo(seconds: 330, chunk: 250);
    final saved = jsonDecode(jsonEncode(e.core.log.toJson())) as Map<String, Object?>;
    expect((saved['header']! as Map)['protocol'], 'alpha-theta');
    for (final chunk in [37, 1000]) {
      final again = replayAlphaTheta(saved, chunk);
      expect(jsonEncode(again.core.log.lines), jsonEncode(saved['lines']), reason: 'chunk $chunk');
    }
    final at = atLines(e);
    expect(controlStream(saved, SessionKind.alphaTheta).length, at.length);
    expect(at.length, closeTo((330 - 90) * 10, 50), reason: 'one per step of the run');
    expect(saved['lines'], contains(predicate((Object? l) => l is Map && l['type'] == 'at-block')));
    expect(at.where((l) => l['g'] == 1 && l['r'] != null), isEmpty, reason: 'no reward under a gate');
  });

  test('engine: alpha slowing into the theta band moves the mix to the ocean and rings gongs', () {
    final e = runDemo(seconds: 420, slowFrom: 270, seed: 3);
    final at = atLines(e);
    double meanMix(bool late) {
      final m = [
        for (final l in at)
          if (l['g'] != 1 && ((l['n']! as int) >= 300 * 250) == late) (l['mix']! as num).toDouble(),
      ];
      return m.reduce((a, b) => a + b) / m.length;
    }

    expect(meanMix(true), greaterThan(meanMix(false) + 0.2));
    double gongsPerMin(int from, int to) =>
        at.where((l) => (l['n']! as int) >= from * 250 && (l['n']! as int) < to * 250 && l['r'] == 'gong').length /
        ((to - from) / 60);
    expect(gongsPerMin(300, 420), greaterThan(gongsPerMin(90, 270)));
    expect(gongsPerMin(300, 420), lessThanOrEqualTo(24), reason: 'at most one every 2.5 s');
    final drowsySteps = {
      for (final l in e.core.log.lines)
        if (l['type'] == 'step' && l['v'] == 'drowsy') l['n'],
    };
    expect(drowsySteps, isNotEmpty, reason: 'slowed alpha trips the core\'s drowsy gate');
    final gatedThen = at.where((l) => drowsySteps.contains(l['n']) && l['g'] == 1).length;
    expect(gatedThen, 0, reason: "the core's drowsy gate does not gate alpha-theta");
  });

  test(
    'a whole alpha-theta session: calibration, stream and ocean, rewards, rating stage, files that replay',
    () async {
      final dir = Directory.systemTemp.createTempSync('at');
      addTearDown(() => dir.deleteSync(recursive: true));
      final sound = SilentSessionSound();
      final c = MeditationController(
        finder: Finder([DemoBand(DemoSignal(7))]),
        sound: SilentSound.new,
        alphaThetaSound: () => sound,
        store: MeditationStore(dir, kind: SessionKind.alphaTheta),
        timing: fast,
      );
      await c.start(const Duration(minutes: 2), kind: SessionKind.alphaTheta);
      await until(c, () => c.stage == Stage.rating);
      expect(c.asksGuess, isFalse);
      expect(sound.cues, 3);
      expect((sound.rewards['chime'] ?? 0) + (sound.rewards['gong'] ?? 0), greaterThan(0));
      final r = c.report!;
      expect(r.kind, SessionKind.alphaTheta);
      expect(r.at!['chimes'], sound.rewards['chime'] ?? 0);
      expect(r.at!['gongs'], sound.rewards['gong'] ?? 0);
      expect(r.bells, (r.at!['chimes']! as int) + (r.at!['gongs']! as int));
      expect(r.outcome, isNotNull);
      final saved = MeditationStore(dir, kind: SessionKind.alphaTheta).list();
      expect(saved.single.toJson(), r.toJson());
      expect(dir.listSync().where((f) => f.path.endsWith('.alphatheta.json')), hasLength(1));
      expect(MeditationStore(dir).list(), isEmpty, reason: 'not a meditation');
      final log = jsonDecode(File('${dir.path}/${r.logFile}').readAsStringSync()) as Map<String, Object?>;
      expect(jsonEncode(replayAlphaTheta(log).core.log.lines), jsonEncode(log['lines']));
      c.submitRatings(null);
      expect(c.stage, Stage.report);
      c.dispose();
    },
  );

  test('sleep guard: probably asleep fades the bed and plays the wake cue, kept out of the measures', () async {
    final demo = DemoSignal(11)
      ..blinks = false
      ..jawBursts = false
      ..wanders = false;
    final fade = Timer.periodic(const Duration(milliseconds: 1), (_) => demo.alphaGain = demo.t > 150 ? 0.1 : 1);
    addTearDown(fade.cancel);
    final sound = SilentSessionSound();
    var faded = false;
    final c = MeditationController(
      finder: Finder([DemoBand(demo)]),
      sound: SilentSound.new,
      alphaThetaSound: () => sound,
      timing: fast,
    );
    c.addListener(() {
      if (c.asleepGuard && sound.bedOn == false) faded = true;
    });
    await c.start(const Duration(minutes: 6), kind: SessionKind.alphaTheta);
    await until(c, () => c.stage == Stage.rating, max: const Duration(seconds: 60));
    expect(faded, isTrue);
    expect(sound.wakes, greaterThanOrEqualTo(1));
    expect(c.tally!.asleepS, greaterThan(30));
    expect(c.session!.log.info.any((i) => i['event'] == 'asleep: bed faded'), isTrue);
    c.dispose();
  });

  test('comparison: alpha-theta compares theta time above its line, not settled time', () {
    MeditationSummary at(DateTime d, double thetaS) => MeditationSummary(
      kind: SessionKind.alphaTheta,
      start: d,
      lengthMin: 15,
      runS: 900,
      complete: true,
      settledS: 800,
      longestSettledS: 60,
      bells: 40,
      restless: {for (final r in Restless.values) r: 0},
      drifting: 0,
      drowsyS: 0,
      calm: const [0.5],
      iafHz: 10,
      note: '',
      logFile: '',
      at: {'thetaS': thetaS, 'countedS': 600.0},
    );
    final earlier = [for (var d = 1; d <= 4; d++) at(DateTime(2026, 11, d), 120.0 + 30 * d)];
    final line = compareWithEarlier(at(DateTime(2026, 11, 9), 300), earlier).line;
    expect(line, startsWith('Theta above its line 50 % of the awake time: above the range of your last 4 sessions (25-40 %)'));
    expect(line, isNot(contains('Settled')));
  });
}
