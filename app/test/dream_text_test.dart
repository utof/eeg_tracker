// The dream catcher's answers as text without a phone (DECISIONS rows 250-259): the file beside each answer's WAV,
// the rule that your own edit wins over the machine's text, which answers wait to be written out (only after a
// session, never during one), a failure that keeps the WAV and says so, the audio steps before the recognizer, and
// the speech model's download. The recognizer itself is a fake here; the real one runs on the emulator
// (README "Emulator smoke test") and on the laptop (scripts/dream_text_check.py).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:eeg_tracker/dream/answer_text.dart';
import 'package:eeg_tracker/dream/rounds.dart';
import 'package:eeg_tracker/dream/speech_audio.dart';
import 'package:eeg_tracker/dream/speech_model.dart';
import 'package:eeg_tracker/dream/store.dart';
import 'package:eeg_tracker/dream/text_runner.dart';
import 'package:eeg_tracker/dream/voice.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show fileStem;
import 'package:eeg_tracker/sound/synth.dart' show wav16;
import 'package:flutter_test/flutter_test.dart';

DreamSession session(DateTime start, List<String?> answers) => DreamSession(
  start: start,
  plannedRounds: 4,
  ending: DreamEnding.wake,
  prompts: const {},
  recording: null,
  firstTimerS: 600,
  rounds: [
    for (final (i, f) in answers.indexed)
      DreamRound(
        n: i + 1,
        atS: 600.0 + 300 * i,
        at: start.add(Duration(seconds: 600 + 300 * i)),
        cause: DreamCause.timer,
        state: 'drowsy',
        answerFile: f,
        answerS: f == null ? 0 : 5,
        voiceS: f == null ? 0 : 3,
        end: f == null ? AnswerEnd.failed : AnswerEnd.silence,
        drifting: null,
        endS: 640.0 + 300 * i,
      ),
  ],
  endS: 1800,
  endWhy: DreamEnd.rounds,
);

/// A 16 kHz mono WAV of [seconds] of a quiet tone.
Uint8List tone(double seconds, {double amp = 0.01}) {
  final n = (seconds * 16000).round();
  return wav16([Float32List.fromList([for (var i = 0; i < n; i++) amp * math.sin(2 * math.pi * 220 * i / 16000)])], sampleRate: 16000);
}

/// A recognizer that hears what it is told per file, or fails.
class FakeEar implements Transcriber {
  FakeEar(this.heard, {this.fail = const {}});
  final Map<String, String> heard;
  final Set<String> fail;
  final List<String> asked = [];
  bool closed = false;
  Completer<void>? hold;

  @override
  String get model => 'fake-model';

  @override
  Future<Heard> hear(String wavPath) async {
    final name = wavPath.split('/').last;
    asked.add(name);
    final h = hold;
    if (h != null) await h.future;
    if (closed) throw const TranscriberClosed();
    if (fail.contains(name)) throw StateError('out of memory');
    return Heard(text: heard[name] ?? '', audioS: 5, voiceS: 3);
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  late Directory tmp;
  late DreamStore store;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dream_text');
    store = DreamStore(Directory('${tmp.path}/dream-catcher'))..dir.createSync(recursive: true);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  final at = DateTime(2026, 11, 19, 1, 30, 5);

  group('the text file', () {
    test('sits beside the WAV, survives the file, and damaged or foreign files read as none', () {
      final stem = fileStem(at);
      expect(textFileName('$stem-r2.wav'), '$stem-r2.text.json');
      final t = AnswerText(answer: '$stem-r2.wav').started().withMachine(
        MachineText(text: 'Я видел дерево', model: 'm', at: at, audioS: 6.04, voiceS: 3.96, tookS: 1.234),
      );
      writeAnswerText(store.dir, t);
      final f = File('${store.dir.path}/$stem-r2.text.json');
      final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      expect(j['version'], 1);
      expect(j['answer'], '$stem-r2.wav');
      expect((j['machine']! as Map)['text'], 'Я видел дерево');
      expect((j['machine']! as Map)['audioS'], 6.0);
      expect(j['edited'], isNull);
      final back = readAnswerText(store.dir, '$stem-r2.wav')!;
      expect((back.shown, back.machine!.model, back.machine!.voiceS, back.tries, back.due), ('Я видел дерево', 'm', 4.0, 1, false));

      f.writeAsStringSync('{"version": 1, "answer": "../x.wav"}');
      expect(readAnswerText(store.dir, '$stem-r2.wav'), isNull);
      f.writeAsStringSync('not json');
      expect(readAnswerText(store.dir, '$stem-r2.wav'), isNull);
      expect(readAnswerText(store.dir, '$stem-r9.wav'), isNull);
    });

    test('your edit wins over the machine text, is kept apart from it, and an edit back to it is no edit', () {
      var t = AnswerText(answer: 'a-r1.wav').edit('a staircase of books');
      expect((t.shown, t.edited, t.machine), ('a staircase of books', 'a staircase of books', null));
      t = t.started().withMachine(MachineText(text: 'a staircase of boots', model: 'm', at: at, audioS: 4, voiceS: 3, tookS: 1));
      expect((t.shown, t.machine!.text), ('a staircase of books', 'a staircase of boots'));
      final back = AnswerText.fromJson(jsonDecode(jsonEncode(t.toJson())))!;
      expect((back.shown, back.machine!.text, back.edited), ('a staircase of books', 'a staircase of boots', 'a staircase of books'));
      expect(t.edit(' a staircase of boots ').edited, isNull);
      expect(t.edit('').shown, '', reason: 'clearing the words is an edit too: nothing was said');
      expect(t.undoEdit().shown, 'a staircase of boots');
    });

    test('a failure keeps what there was and says why; tries count, and Try again starts over', () {
      var t = AnswerText(answer: 'a-r1.wav').started();
      expect(t.due, true, reason: 'started but not finished: the app stopped; one more try');
      expect(t.stalled, true);
      t = t.withFailure('out of memory');
      expect((t.failed, t.tries, t.due, t.stalled), ('out of memory', 1, true, false));
      t = t.started().withFailure('out of memory');
      expect((t.tries, t.due), (2, false));
      t = t.retry();
      expect((t.tries, t.failed, t.due), (0, null, true));
    });
  });

  group('what waits to be written out', () {
    test('every recorded answer without text, newest session first; done, given-up and missing ones skipped', () {
      final older = session(at.subtract(const Duration(days: 1)), ['${fileStem(at.subtract(const Duration(days: 1)))}-r1.wav']);
      final stem = fileStem(at);
      final newer = session(at, ['$stem-r1.wav', null, '$stem-r3.wav', '$stem-r4.wav']);
      for (final s in [older, newer]) {
        for (final r in s.rounds) {
          if (r.answerFile != null) File('${store.dir.path}/${r.answerFile}').writeAsBytesSync(tone(1));
        }
      }
      writeAnswerText(store.dir, AnswerText(answer: '$stem-r3.wav').started().withMachine(
        MachineText(text: 'done', model: 'm', at: at, audioS: 1, voiceS: 1, tookS: 1),
      ));
      writeAnswerText(store.dir, AnswerText(answer: '$stem-r4.wav').started().withFailure('x').started().withFailure('x'));
      final due = dueAnswers(store, [older, newer]..sort((a, b) => b.start.compareTo(a.start)));
      expect(due, ['$stem-r1.wav', '${fileStem(at.subtract(const Duration(days: 1)))}-r1.wav']);
    });
  });

  group('writing them out', () {
    late DreamSession s;
    late String r1, r2, r3;
    setUp(() {
      final stem = fileStem(at);
      (r1, r2, r3) = ('$stem-r1.wav', '$stem-r2.wav', '$stem-r3.wav');
      s = session(at, [r1, r2, r3]);
      for (final f in [r1, r2, r3]) {
        File('${store.dir.path}/$f').writeAsBytesSync(tone(1));
      }
    });

    test('one engine for the batch, each text saved beside its WAV, closed afterwards', () async {
      final ear = FakeEar({r1: 'a tree out of the water', r3: 'дерево'});
      var opened = 0;
      final texts = DreamTexts(store: store, open: () async {
        opened++;
        return ear;
      }, clock: () => at);
      await texts.run([s]);
      expect((opened, ear.closed), (1, true));
      expect(ear.asked, [r1, r2, r3]);
      expect(readAnswerText(store.dir, r1)!.shown, 'a tree out of the water');
      expect(readAnswerText(store.dir, r2)!.shown, '', reason: 'nothing heard: an empty text, not a failure');
      expect(texts.of(r3)!.machine!.text, 'дерево');
      await texts.run([s]);
      expect(opened, 1, reason: 'nothing left to do: the model is not even loaded');
    });

    test('a failure keeps the WAV and says so; the others go on', () async {
      final texts = DreamTexts(store: store, open: () async => FakeEar({r1: 'one', r3: 'three'}, fail: {r2}), clock: () => at);
      await texts.run([s]);
      final t = readAnswerText(store.dir, r2)!;
      expect((t.machine, t.tries), (null, 1));
      expect(t.failed, contains('out of memory'));
      expect(File('${store.dir.path}/$r2').existsSync(), true);
      expect(readAnswerText(store.dir, r3)!.shown, 'three');
    });

    test('a model that does not load: the first answer says why and the batch stops', () async {
      final texts = DreamTexts(store: store, open: () async => throw const FileSystemException('no file'), clock: () => at);
      await texts.run([s]);
      expect(readAnswerText(store.dir, r1)!.failed, contains('speech model did not load'));
      expect(readAnswerText(store.dir, r2), isNull);
    });

    test('your edit while the machine works wins; a second run while one goes is the same run', () async {
      final ear = FakeEar({r1: 'boots'})..hold = Completer<void>();
      final texts = DreamTexts(store: store, open: () async => ear, clock: () => at);
      final a = texts.run([s]), b = texts.run([s]);
      await pumpEventQueue();
      expect(texts.working, r1);
      texts.edit(r1, 'books');
      ear.hold!.complete();
      await Future.wait([a, b]);
      final t = readAnswerText(store.dir, r1)!;
      expect((t.shown, t.machine!.text), ('books', 'boots'));
      expect(ear.asked, [r1, r2, r3], reason: 'each answer once');
    });

    test('never during a session: blocked, nothing runs; a session starting mid-batch stops it at once, no try lost', () async {
      var blocked = true;
      final ear = FakeEar({r1: 'one'});
      final texts = DreamTexts(store: store, open: () async => ear, clock: () => at, blocked: () => blocked);
      await texts.run([s]);
      expect(ear.asked, isEmpty);

      blocked = false;
      ear.hold = Completer<void>();
      final run = texts.run([s]);
      await pumpEventQueue();
      expect(texts.working, r1);
      blocked = true;
      await texts.stop();
      ear.hold!.complete();
      await run;
      expect((ear.closed, texts.working), (true, null));
      final t = readAnswerText(store.dir, r1)!;
      expect((t.tries, t.failed, t.due), (0, null, true), reason: 'stopped by a session, not a failed try');
      expect(readAnswerText(store.dir, r2), isNull);
    });
  });

  group('the audio before the recognizer', () {
    test('a 16 kHz mono WAV reads as samples, also with the size a recorder stopped hard leaves unset', () {
      final f = File('${tmp.path}/a.wav')..writeAsBytesSync(tone(0.5, amp: 0.5));
      final x = readWav16k(f);
      expect(x.length, 8000);
      expect(x.reduce(math.max), closeTo(0.5, 0.001));
      final b = f.readAsBytesSync();
      ByteData.sublistView(b).setUint32(40, 0xFFFFFFFF, Endian.little);
      f.writeAsBytesSync(b);
      expect(readWav16k(f).length, 8000);
      File('${tmp.path}/b.wav').writeAsBytesSync(wav16([Float32List(800)], sampleRate: 8000));
      expect(() => readWav16k(File('${tmp.path}/b.wav')), throwsA(isA<FormatException>()));
      expect(() => readWav16k(File('${tmp.path}/none.wav')), throwsA(isA<FileSystemException>()));
    });

    test('a quiet answer is raised to a -3 dBFS peak, at most +30 dB, never lowered', () {
      double peak(Float32List x) => x.map((v) => v.abs()).reduce(math.max);
      expect(peak(levelUp(Float32List.fromList([0.01, -0.05, 0.02]))), closeTo(0.708, 0.001));
      expect(peak(levelUp(Float32List.fromList([0.0001, -0.0002]))), closeTo(0.0002 * 31.62, 0.0001));
      expect(peak(levelUp(Float32List.fromList([0.9, -0.2]))), closeTo(0.9, 1e-6));
      expect(levelUp(Float32List(4)), Float32List(4));
    });

    test('the voice detector\'s parts are widened by a quarter second each side, overlaps merged, inside the clip', () {
      expect(voicedSpans([(8000, 16000), (30000, 3000), (45000, 1000)], 48000), [(4000, 37000), (41000, 48000)]);
      expect(voicedSpans([(100, 50)], 1000), [(0, 1000)]);
      expect(voicedSpans(const [], 1000), isEmpty);
    });

    test('the voiced parts are joined with 0.3 s of silence; none: nothing to recognise', () {
      final joined = joinVoiced([Float32List.fromList([1, 1]), Float32List.fromList([2])]);
      expect(joined.length, 2 + 4800 + 1 + 4800);
      expect((joined[0], joined[2], joined[4802]), (1.0, 0.0, 2.0));
      expect(joinVoiced(const []), isEmpty);
    });
  });

  group('the speech model on the phone', () {
    final files = [for (final (n, body) in [('a.onnx', 'encoder bytes'), ('tokens.txt', 'x y z')]) (n, utf8.encode(body))];
    SpeechModelSpec spec() => SpeechModelSpec(
      id: 'test-model',
      label: 'Test',
      base: 'https://example.invalid/m/',
      files: [for (final (n, b) in files) ModelFile(n, b.length, sha256.convert(b).toString())],
    );

    test('ready only with every file there, of its size and checked; a download fetches, checks and keeps them', () async {
      final m = SpeechModelStore(Directory('${tmp.path}/models'), spec(), fetch: (uri, from) async {
        final b = files.firstWhere((f) => uri.path.endsWith(f.$1)).$2;
        return FetchReply(Stream.value(b.sublist(from)), from);
      });
      expect(m.ready, false);
      final seen = <double>[];
      await m.download(onProgress: seen.add);
      expect(m.ready, true);
      expect(seen.last, 1.0);
      expect(File('${tmp.path}/models/test-model/a.onnx').readAsStringSync(), 'encoder bytes');
      File('${tmp.path}/models/test-model/tokens.txt').writeAsStringSync('x y');
      expect(m.ready, false, reason: 'a file of the wrong size');
      m.delete();
      expect(Directory('${tmp.path}/models/test-model').existsSync(), false);
    });

    test('a damaged download is thrown away and said; an interrupted one resumes where it stopped', () async {
      var calls = <int>[];
      final bad = SpeechModelStore(Directory('${tmp.path}/models'), spec(), fetch: (uri, from) async {
        return FetchReply(Stream.value(utf8.encode('encoder bytez').sublist(from)), from);
      });
      await expectLater(bad.download(), throwsA(isA<ModelDownloadError>()));
      expect(bad.ready, false);
      expect(Directory('${tmp.path}/models/test-model').listSync().whereType<File>().where((f) => f.path.endsWith('a.onnx')), isEmpty);

      final part = File('${tmp.path}/models/test-model/a.onnx.part')..writeAsBytesSync(utf8.encode('encoder'));
      expect(part.existsSync(), true);
      final good = SpeechModelStore(Directory('${tmp.path}/models'), spec(), fetch: (uri, from) async {
        calls.add(from);
        final b = files.firstWhere((f) => uri.path.endsWith(f.$1)).$2;
        return FetchReply(Stream.value(b.sublist(from)), from);
      });
      await good.download();
      expect(good.ready, true);
      expect(calls, [7, 0], reason: 'a.onnx from byte 7, tokens.txt from the start');
      calls = [];
    });

    test('a failure in plain words', () {
      expect(downloadProblem(const SocketException('Failed host lookup')), startsWith('No connection to the download server'));
      expect(downloadProblem(const ModelDownloadError('The server answered 404. Try again later.')), 'The server answered 404. Try again later.');
      expect(downloadProblem(const FileSystemException('write failed', 'x', OSError('No space left on device', 28))), contains('No space left'));
    });

    test('Stop ends a download and keeps the part for later', () async {
      final gate = StreamController<List<int>>();
      final m = SpeechModelStore(Directory('${tmp.path}/models'), spec(), fetch: (uri, from) async => FetchReply(gate.stream, from));
      final d = m.download();
      await pumpEventQueue();
      gate.add(utf8.encode('enc'));
      await pumpEventQueue();
      m.cancel();
      await expectLater(d, throwsA(isA<ModelDownloadCancelled>()));
      expect(File('${tmp.path}/models/test-model/a.onnx.part').lengthSync(), 3);
      expect(m.ready, false);
      unawaited(gate.close());
    });
  });
}
