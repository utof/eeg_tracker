// The replay check end to end with a fake headband: four live donor sessions first (no questions, nothing
// frozen), then the hidden schedule. A replay session plays the donor stream step for step except where a live
// gate acts (then the live neutral bed, and no bell until 4 s after it); the answers come before the report;
// nothing the screen gets or the session files hold names the kind of session.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/feedback/demo.dart';
import 'package:eeg_tracker/feedback/mapping.dart';
import 'package:eeg_tracker/meditation/controller.dart';
import 'package:eeg_tracker/meditation/store.dart';
import 'package:eeg_tracker/meditation/tracker.dart';
import 'package:eeg_tracker/sound/feedback_sound.dart';
import 'package:eeg_tracker/training/check.dart';
import 'package:eeg_tracker/training/check_store.dart';
import 'package:eeg_tracker/training/control.dart';
import 'package:eeg_tracker/ui/meditation_view.dart';
import 'package:flutter_test/flutter_test.dart' hide Finder;

import 'meditation_test.dart' show DemoBand, Finder, fast, until;

/// Keeps every glide and bell, in order.
class RecordingSound implements FeedbackSound {
  final List<double> calm = [];
  final List<int> bellsAt = [];
  @override
  Future<void> start() async {}
  @override
  void bed({required bool on}) {}
  @override
  void glide(Targets target) => calm.add(target.calm);
  @override
  void bell() => bellsAt.add(calm.length - 1);
  @override
  void cue() {}
  @override
  Future<void> stop() async {}
  @override
  Map<String, Object?> info() => {'engine': 'test'};
}

void main() {
  test('donor sessions, then the schedule; a replay follows its donors and the live gates', () async {
    final root = Directory.systemTemp.createTempSync('check');
    addTearDown(() => root.deleteSync(recursive: true));
    final store = MeditationStore(Directory('${root.path}/meditations'));
    final cs = CheckStore(root, SessionKind.meditation);

    Future<(MeditationController, RecordingSound)> run(int seed, Duration length) async {
      final sound = RecordingSound();
      final c = MeditationController(
        finder: Finder([DemoBand(DemoSignal(seed))]),
        sound: () => sound,
        store: store,
        checkStore: cs,
        timing: fast,
        clock: () => DateTime.now().add(Duration(minutes: 10 * seed)), // each session its own file names
      );
      await c.start(length);
      await until(c, () => c.stage == Stage.report || c.stage == Stage.rating, max: const Duration(seconds: 40));
      return (c, sound);
    }

    for (var i = 0; i < CheckRule.donorsFirst; i++) {
      final (c, _) = await run(i + 1, const Duration(minutes: 1));
      expect(c.stage, Stage.report, reason: 'donor sessions ask nothing');
      expect(c.checkOn, isTrue);
      expect(c.checkStatus, contains('Live session ${i + 1} of 4'));
      c.dispose();
    }
    expect(cs.plan, isNull, reason: 'nothing frozen before the first randomised session');

    final seen = <Arm>{};
    for (var i = 0; i < 4 && seen.length < 2; i++) {
      final (c, sound) = await run(20 + i, const Duration(minutes: 2));
      expect(cs.plan, isNotNull);
      expect(c.stage, Stage.rating);
      expect(c.asksGuess, isTrue);
      expect(c.checkStatus, 'Check session ${i + 1} of 24-36. Results after every 12.');
      final rec = cs.records.last;
      expect(rec.index, i);
      expect(rec.arm, cs.sealed!.arms[i], reason: 'what played is what the schedule said');
      expect(rec.ratings, isNull, reason: 'kept before the answers');

      // the screen's model: no bells, no settled word, whatever the session was
      final m = meditationModel(stage: Stage.running, minutes: 2, chip: Moment.settled, bells: 7, checkOn: c.checkOn);
      expect(m.bells, isNull);
      expect(m.title, 'In session');

      // step for step: the live log's gates against what was played
      final log = jsonDecode(File('${store.dir.path}/${c.report!.logFile}').readAsStringSync()) as Map<String, Object?>;
      expect(jsonEncode(log), isNot(contains('replay')));
      final live = controlStream(log, SessionKind.meditation);
      expect(sound.calm.length, live.length, reason: 'one glide per run step');
      if (rec.arm == Arm.live) {
        for (var k = 0; k < live.length; k++) {
          expect(sound.calm[k], closeTo(live[k].level, 5e-4), reason: 'live step $k (the log keeps 3 decimals)');
        }
        expect(sound.bellsAt, [
          for (var k = 0; k < live.length; k++)
            if (live[k].reward != null) k,
        ]);
      } else {
        expect(rec.donors, isNotEmpty);
        final donor = [
          for (final d in rec.donors)
            ...controlStream(
              jsonDecode(File('${store.dir.path}/$d.session.json').readAsStringSync()) as Map<String, Object?>,
              SessionKind.meditation,
            ),
        ];
        var sinceGate = 1 << 30, followed = 0;
        final expectBells = <int>[];
        for (var k = 0; k < live.length; k++) {
          final d = donor[k % donor.length];
          if (live[k].gated) {
            sinceGate = 0;
            expect(sound.calm[k], closeTo(live[k].level, 5e-4), reason: 'gated step $k plays the live neutral bed');
          } else {
            sinceGate++;
            expect(sound.calm[k], d.level, reason: 'clean step $k plays the donor');
            if ((d.level - live[k].level).abs() > 0.01) followed++;
            if (d.reward != null && sinceGate >= 40) expectBells.add(k);
          }
        }
        expect(followed, greaterThan(100), reason: 'the replay really differs from what live would have played');
        expect(sound.bellsAt, expectBells);
      }
      c.submitRatings(const CheckRatings(calm: 4, guess: 'unsure', confidence: 0, control: 3, random: 3));
      expect(c.stage, Stage.report);
      expect(cs.records.last.ratings!.guess, 'unsure');
      seen.add(rec.arm);
      c.dispose();
    }
    expect(seen, {Arm.live, Arm.replay}, reason: 'a block of 4 holds both');
    expect(cs.reveal(), isNull, reason: 'locked until 12');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('the session that completes a set of 12 is in the replay check\'s test of the silent minutes at once', () async {
    final root = Directory.systemTemp.createTempSync('check');
    addTearDown(() => root.deleteSync(recursive: true));
    final store = MeditationStore(Directory('${root.path}/meditations'));
    final cs = CheckStore(root, SessionKind.meditation);
    Future<MeditationController> run(int seed) async {
      final c = MeditationController(
        finder: Finder([DemoBand(DemoSignal(seed))]),
        sound: SilentSound.new,
        store: store,
        checkStore: cs,
        timing: fast,
        clock: () => DateTime.now().add(Duration(minutes: 10 * seed)),
      );
      await c.start(const Duration(minutes: 1));
      await until(c, () => c.stage == Stage.report || c.stage == Stage.rating, max: const Duration(seconds: 40));
      return c;
    }

    for (var i = 0; i < CheckRule.donorsFirst; i++) {
      (await run(i + 1)).dispose();
    }
    cs.freeze(DateTime.now());
    final arms = cs.sealed!.arms;
    for (var i = 0; i < CheckRule.revealEvery - 1; i++) {
      cs.add(CheckRecord(
        index: i,
        stem: 'made-up-$i',
        start: DateTime(2026, 11, 1).add(Duration(days: i)),
        arm: arms[i],
        runS: 60,
        outcome: 0.1,
        silent: arms[i] == Arm.live ? 0.3 : 0.1,
        excludedShare: 0.1,
        asleepS: 0,
      ));
    }
    final c = await run(30);
    expect(cs.records, hasLength(CheckRule.revealEvery));
    expect(cs.records.last.silent, c.report!.silent!.alpha);
    expect(c.learning!.tested, isNotNull);
    expect(c.learning!.lines, contains(startsWith('Tested by the replay check (sessions 1-12)')));
    c.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
