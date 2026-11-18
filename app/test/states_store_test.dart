// Sound for states: one JSON file per session in the app's private folder (docs/data-format.md), so a later stats
// engine can compare sounds per state. Round trip, damaged and foreign files skipped, newest first, the rating.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/states/presets.dart';
import 'package:eeg_tracker/states/readout.dart';
import 'package:eeg_tracker/states/store.dart';
import 'package:flutter_test/flutter_test.dart';

SoundSession session(DateTime start, {SoundState state = SoundState.relax, Beat beat = Beat.pulsed, int? rating}) => SoundSession(
  start: start,
  plan: SoundPlan.of(state, beat: beat),
  headband: HeadbandUse.used,
  contact: const {'O1': 4.2e5, 'O2': null},
  recording: state == SoundState.asleep ? '2026-11-18-231200' : null,
  soundStartS: 64,
  baselineS: 58,
  fadeFromS: 644,
  offAtS: 664,
  endS: 664.4,
  end: SoundEnd.time,
  drift: const {'epochs': 'baa'},
  epochs: const [ReadSummary(0, 28, 1.1, 0.9, 2.4), ReadSummary(1, 30, 1.25, 0.85, 2.1)],
  summary: const ReadSummary(0, 58, 1.2, 0.87, 2.2),
  events: const [(s: 0, text: 'quiet minute'), (s: 64, text: 'sound on')],
  stalls: 0,
  engine: const {'engine': 'flutter_soloud'},
  rating: rating,
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sound-states'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('round-trips every field; numbers rounded for reading', () {
    final s = session(DateTime(2026, 11, 18, 23, 12, 5), state: SoundState.asleep, rating: 4);
    final back = SoundSession.fromJson(jsonDecode(jsonEncode(s.toJson())))!;
    expect(back.toJson(), s.toJson());
    expect(back.plan.state, SoundState.asleep);
    expect(back.summary!.alpha, 1.2);
    expect(back.epochs.length, 2);
    expect(back.rating, 4);
    expect(back.events.last.text, 'sound on');
    expect(s.toJson()['version'], SoundSession.version);
    expect(s.fileName, '2026-11-18-231205.sound.json');
  });

  test('refuses damaged sessions instead of guessing', () {
    final good = session(DateTime(2026, 11, 18, 9)).toJson();
    expect(SoundSession.fromJson({...good, 'version': 99}), isNull);
    expect(SoundSession.fromJson({...good, 'plan': {'state': 'x'}}), isNull);
    expect(SoundSession.fromJson({...good, 'start': 'yesterday'}), isNull);
    expect(SoundSession.fromJson({...good, 'rating': 9}), isNull);
    expect(SoundSession.fromJson({...good, 'headband': 'borrowed'}), isNull);
    expect(SoundSession.fromJson({...good, 'end': 'exploded'}), isNull);
    expect(SoundSession.fromJson([1, 2]), isNull);
  });

  test('the store keeps one file per session, lists newest first and skips what it cannot read', () {
    final st = SoundStore(dir);
    st.save(session(DateTime(2026, 11, 17, 22)));
    st.save(session(DateTime(2026, 11, 18, 23), state: SoundState.asleep, beat: Beat.none));
    File('${dir.path}/2026-11-19-000000.sound.json').writeAsStringSync('{broken');
    File('${dir.path}/notes.txt').writeAsStringSync('x');
    final list = st.list();
    expect(list.map((s) => s.start), [DateTime(2026, 11, 18, 23), DateTime(2026, 11, 17, 22)]);
    expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
  });

  test('"Screen: Stays on" is remembered next to the sessions and is not taken for one', () {
    final dir = Directory.systemTemp.createTempSync('sound');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = SoundStore(Directory('${dir.path}/sound-states'));
    expect(store.screenStaysOn, isFalse, reason: 'by default the phone can be locked');
    store.screenStaysOn = true;
    expect(SoundStore(store.dir).screenStaysOn, isTrue);
    expect(store.list(), isEmpty);
    File('${store.dir.path}/settings.json').writeAsStringSync('{broken');
    expect(store.screenStaysOn, isFalse);
  });

  test('a rating given later is saved into the same file', () {
    final st = SoundStore(dir);
    final s = session(DateTime(2026, 11, 18, 23));
    st.save(s);
    s.rating = 2;
    st.save(s);
    expect(st.list().single.rating, 2);
    expect(dir.listSync().length, 1);
  });

  test('the folder sits next to the recordings, like the other sessions', () {
    expect(soundStatesDirFor('/data/files/recordings').path, '/data/files/sound-states');
  });
}
