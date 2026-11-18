// Export data (DECISIONS rows 150-154): everything the app keeps in its private files folder goes into the export
// folder in the same layout, new or changed files only unless "everything" is asked, with a manifest listing every
// exported file's size and SHA-256; the phone's own index decides what is new. Run against a plain folder here
// (DirectoryTarget); on the phone the same calls go through the system folder picker's grant (DataExport.kt).
//
// With EXPORT_FIXTURE=write the fixture the laptop's importer reads (analysis/tests/test_import_phone.py) is remade
// in test/fixtures/phone_export/.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:eeg_tracker/dream/store.dart';
import 'package:eeg_tracker/export/exporter.dart';
import 'package:eeg_tracker/export/store.dart';
import 'package:eeg_tracker/meditation/store.dart';
import 'package:eeg_tracker/morning/store.dart';
import 'package:eeg_tracker/sleep/onnx_runs.dart' show modelsDirFor;
import 'package:eeg_tracker/sleep/report.dart' show nightsDirFor;
import 'package:eeg_tracker/states/store.dart';
import 'package:eeg_tracker/training/control.dart' show SessionKind;
import 'package:flutter_test/flutter_test.dart';

final DateTime t0 = DateTime.utc(2026, 11, 19, 4);

/// A fake app folder: `files/` with something in every place the app writes, plus what must stay behind.
Directory fakeFiles(Directory tmp) {
  final files = Directory('${tmp.path}/files')..createSync();
  final rec = '${files.path}/recordings';
  void put(String path, List<int> bytes) {
    final f = File('${files.path}/$path')..createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    f.setLastModifiedSync(t0);
  }

  void text(String path, String s) => put(path, utf8.encode(s));
  // a synthetic night: two records (packet number, O1 O2 T3 T4 in volts), one index row, a log, a marker
  final f32 = ByteData(40);
  for (var r = 0; r < 2; r++) {
    f32.setUint32(r * 20, 7 + r, Endian.little);
    for (var c = 0; c < 4; c++) {
      f32.setFloat32(r * 20 + 4 + c * 4, 1e-5 * (c + 1) * (r + 1), Endian.little);
    }
  }
  put('recordings/2026-11-18-231200.f32', f32.buffer.asUint8List());
  final idx = ByteData(16)
    ..setFloat64(0, 1763496720.5, Endian.little)
    ..setUint64(8, 0, Endian.little);
  put('recordings/2026-11-18-231200.idx', idx.buffer.asUint8List());
  text('recordings/2026-11-18-231200.log', 'synthetic night for the export fixture\n');
  text('recordings/2026-11-18-231200.markers.jsonl', '{"t":1763496721.0,"i":1,"text":"lights off"}\n');
  String rel(Directory d) => d.path.substring(files.path.length + 1);
  text('${rel(nightsDirFor(rec))}/2026-11-18.report.json', '{"version":2,"night_of":"2026-11-18"}');
  text('${rel(morningsDirFor(rec))}/2026-11-19-071500.morning.json', '{"version":"morning-v1"}');
  text('${rel(morningsDirFor(rec))}/2026-11-19-071400.f32', 'x' * 20);
  text('${rel(meditationsDirFor(rec))}/2026-11-19-080000.meditation.json', '{"runS":600}');
  text('${rel(meditationsDirFor(rec))}/2026-11-19-080000.session.json', '{"lines":[]}');
  final at = rel(sessionsDirFor(rec, SessionKind.alphaTheta));
  text('$at/2026-11-19-090000.alphatheta.json', '{"runS":900}');
  text('$at/journal.json', '{"screening":null}');
  text('replay-check/meditation/plan.json', '{"plan":"frozen"}');
  text('replay-check/meditation/events.jsonl', '{"event":"on"}\n');
  text('settings.json', '{"replayCheck":false}');
  final dream = rel(dreamDirFor(rec));
  text('$dream/2026-11-18-230000.dream.json', '{"rounds":[]}');
  put('$dream/2026-11-18-230000-r1.wav', utf8.encode('RIFF\x24\x00\x00\x00WAVE'));
  put('$dream/prompts/theme.wav', utf8.encode('RIFF\x24\x00\x00\x00WAVE'));
  text('${rel(soundStatesDirFor(rec))}/2026-11-18-231000.sound.json', '{"version":1}');
  // stays on the phone: the model copies (from the app's own assets), half-written files, the scorer's marker,
  // and the export's own state
  text('${rel(modelsDirFor(rec))}/anysleep-run1-0011aabb.onnx', 'model');
  text('nights/2026-11-19.report.tmp', '{');
  text('nights/2026-11-19.scoring', '');
  text('sound-states/2026-11-19-230000.sound.json.tmp', '{');
  // and what Android and the plugins keep there for themselves (seen on the emulator): not the owner's data
  put('profileInstalled', [0, 0, 0, 1, 0, 0, 0, 0]);
  text('flutter_callback_cache.json', '[{"handle":-1,"representation":{"name":"recorderEntryPoint"}}]');
  return files;
}

String sha(List<int> b) => sha256.convert(b).toString();

Map<String, Object?> manifestOf(Directory target) =>
    jsonDecode(File('${target.path}/$exportFolderName/manifest.json').readAsStringSync()) as Map<String, Object?>;

List<Map<String, Object?>> entries(Map<String, Object?> m) => (m['files']! as List).cast<Map<String, Object?>>();

/// A target that fails or changes things on the [n]th copy, to see what a broken export leaves.
class FlakyTarget extends DirectoryTarget {
  FlakyTarget(super.parent, {required this.at, this.fail = false, this.touch});
  final int at;
  final bool fail;
  final File? touch;
  int copies = 0;

  @override
  Future<Copied> copy(File source, String path) async {
    if (++copies == at) {
      if (fail) throw const FileSystemException('the folder is gone');
      touch?.writeAsStringSync('changed while it was copied', mode: FileMode.append);
    }
    return super.copy(source, path);
  }
}

void main() {
  late Directory tmp, files, out;
  var now = DateTime(2026, 11, 19, 7, 42, 10);
  DateTime clock() => now;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('export_test');
    files = fakeFiles(tmp);
    out = Directory('${tmp.path}/Download/EEG')..createSync(recursive: true);
    now = DateTime(2026, 11, 19, 7, 42, 10);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ExportOutcome> export({bool everything = false, ExportTarget? target, bool Function()? stop}) => runExport(
    filesDir: files,
    target: target ?? DirectoryTarget(out),
    everything: everything,
    clock: clock,
    stopRequested: stop,
  );

  group('what is exported', () {
    test('every place the app writes, in its own layout; models, temporary files, markers and Android\'s own files stay', () {
      final paths = [for (final f in storedFiles(files)) f.path];
      expect(paths, [
        'alpha-theta/2026-11-19-090000.alphatheta.json',
        'alpha-theta/journal.json',
        'dream-catcher/2026-11-18-230000-r1.wav',
        'dream-catcher/2026-11-18-230000.dream.json',
        'dream-catcher/prompts/theme.wav',
        'meditations/2026-11-19-080000.meditation.json',
        'meditations/2026-11-19-080000.session.json',
        'mornings/2026-11-19-071400.f32',
        'mornings/2026-11-19-071500.morning.json',
        'nights/2026-11-18.report.json',
        'recordings/2026-11-18-231200.f32',
        'recordings/2026-11-18-231200.idx',
        'recordings/2026-11-18-231200.log',
        'recordings/2026-11-18-231200.markers.jsonl',
        'replay-check/meditation/events.jsonl',
        'replay-check/meditation/plan.json',
        'settings.json',
        'sound-states/2026-11-18-231000.sound.json',
      ]);
      expect(storedFiles(files).first.bytes, '{"runS":900}'.length);
      expect(storedFiles(files).first.modifiedMs, t0.millisecondsSinceEpoch);
    });
  });

  group('an export', () {
    test('the first copies everything, unchanged, with a manifest of sizes and SHA-256', () async {
      final r = await export();
      expect(r.complete, isTrue);
      expect(r.error, isNull);
      expect(r.files, 18);
      final m = manifestOf(out);
      expect(m['format'], 'eeg-tracker-phone-export');
      expect(m['version'], 1);
      expect(m['mode'], 'new');
      expect(m['complete'], isTrue);
      expect(m['not_exported'], isEmpty);
      expect(m['exported'], '2026-11-19T07:42:10${_offset(now)}');
      final list = entries(m);
      expect(list, hasLength(18));
      for (final e in list) {
        final copy = File('${out.path}/$exportFolderName/${e['path']}').readAsBytesSync();
        final original = File('${files.path}/${e['path']}').readAsBytesSync();
        expect(copy, original, reason: '${e['path']}');
        expect(e['sha256'], sha(original));
        expect(e['bytes'], original.length);
        expect(e['modified_ms'], t0.millisecondsSinceEpoch);
        expect(e['written'], m['exported']);
        expect(e.containsKey('on_phone'), isFalse);
      }
      expect((m['totals']! as Map)['files'], 18);
      expect(Directory('${out.path}/$exportFolderName/models').existsSync(), isFalse);
      final log = File('${out.path}/$exportFolderName/exports.jsonl').readAsLinesSync();
      expect(log, hasLength(1));
      expect(jsonDecode(log.single), containsPair('files', 18));
      expect(ExportStore(files).load().lastComplete, now);
    });

    test('the next copies only what is new or changed; the manifest still lists everything', () async {
      await export();
      now = now.add(const Duration(days: 1));
      expect((await export()).files, 0);
      File('${files.path}/meditations/2026-11-19-080000.meditation.json')
        ..writeAsStringSync('{"runS":600,"note":"calm"}')
        ..setLastModifiedSync(t0.add(const Duration(hours: 5)));
      File('${files.path}/meditations/2026-11-20-080000.meditation.json').writeAsStringSync('{"runS":300}');
      now = now.add(const Duration(minutes: 5));
      final r = await export();
      expect(r.files, 2);
      final list = entries(manifestOf(out));
      expect(list, hasLength(19));
      final changed = list.singleWhere((e) => e['path'] == 'meditations/2026-11-19-080000.meditation.json');
      expect(changed['sha256'], sha(utf8.encode('{"runS":600,"note":"calm"}')));
      expect(changed['written'], manifestOf(out)['exported']);
      final old = list.singleWhere((e) => e['path'] == 'settings.json');
      expect(old['written'], '2026-11-19T07:42:10${_offset(now)}');
      expect(File('${out.path}/$exportFolderName/exports.jsonl').readAsLinesSync(), hasLength(3));
    });

    test('everything copies every file again', () async {
      await export();
      final r = await export(everything: true);
      expect(r.files, 18);
      expect(manifestOf(out)['mode'], 'everything');
    });

    test('stopped early: the manifest names what is still only on the phone, and the next export finishes it',
        () async {
      var n = 0;
      final r = await export(stop: () => ++n > 5);
      expect(r.complete, isFalse);
      expect(r.files, 5);
      final m = manifestOf(out);
      expect(m['complete'], isFalse);
      expect(entries(m), hasLength(5));
      expect(m['not_exported'], hasLength(13));
      expect(ExportStore(files).load().lastComplete, isNull);
      final again = await export();
      expect(again.files, 13);
      expect(manifestOf(out)['complete'], isTrue);
    });

    test('a folder that fails mid-way: what was copied is kept, the error is said, nothing is lost', () async {
      final r = await export(target: FlakyTarget(out, at: 4, fail: true));
      expect(r.error, contains('the folder is gone'));
      expect(r.files, 3);
      expect(manifestOf(out)['not_exported'], hasLength(15));
      expect((await export()).files, 15);
    });

    test('a file that changes while it is copied is copied again next time', () async {
      final journal = File('${files.path}/alpha-theta/journal.json');
      await export(target: FlakyTarget(out, at: 2, touch: journal));
      final r = await export();
      expect(r.files, 1);
      final e = entries(manifestOf(out)).singleWhere((e) => e['path'] == 'alpha-theta/journal.json');
      expect(e['sha256'], sha(journal.readAsBytesSync()));
    });

    test('a file the phone no longer has stays listed, marked as gone from the phone', () async {
      await export();
      File('${files.path}/dream-catcher/prompts/theme.wav').deleteSync();
      await export();
      final e = entries(manifestOf(out)).singleWhere((e) => e['path'] == 'dream-catcher/prompts/theme.wav');
      expect(e['on_phone'], isFalse);
    });

    test('a new folder starts again: everything goes there', () async {
      await export();
      final store = ExportStore(files);
      store.chooseFolder('content://tree/one', 'Download/EEG');
      await export();
      store.chooseFolder('content://tree/two', 'Sync/EEG');
      expect(store.load().lastComplete, isNull);
      final other = Directory('${tmp.path}/Sync')..createSync();
      expect((await export(target: DirectoryTarget(other))).files, 18);
      store.chooseFolder('content://tree/two', 'Sync/EEG'); // the same folder again changes nothing
      expect(store.load().lastComplete, isNotNull);
    });

    test('the phone_export fixture the laptop importer reads', () async {
      final fixture = Directory('test/fixtures/phone_export');
      if (Platform.environment['EXPORT_FIXTURE'] == 'write') {
        if (fixture.existsSync()) fixture.deleteSync(recursive: true);
        fixture.createSync(recursive: true);
        await export(target: DirectoryTarget(fixture));
        ExportStore(files).dir.deleteSync(recursive: true); // the next export starts afresh, like the fixture's
      }
      await export();
      final made = Directory('${out.path}/$exportFolderName');
      final kept = Directory('${fixture.path}/$exportFolderName');
      String norm(String s) => s.replaceAll(RegExp(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d'), 'TIME');
      for (final f in made.listSync(recursive: true).whereType<File>()) {
        final rel = f.path.substring(made.path.length + 1);
        final other = File('${kept.path}/$rel');
        expect(other.existsSync(), isTrue, reason: '$rel is missing from the fixture: run with EXPORT_FIXTURE=write');
        if (rel.endsWith('.json') || rel.endsWith('.jsonl')) {
          expect(norm(other.readAsStringSync()), norm(f.readAsStringSync()), reason: rel);
        } else {
          expect(other.readAsBytesSync(), f.readAsBytesSync(), reason: rel);
        }
      }
      expect(kept.listSync(recursive: true).whereType<File>().length, made.listSync(recursive: true).whereType<File>().length);
    });
  });

  group('the reminder on the main screen', () {
    final now = DateTime(2026, 11, 22, 20);
    test('never exported, with something to export: a warning', () {
      final l = exportLine(lastComplete: null, pendingFiles: 12, pendingBytes: 3e8.toInt(), now: now)!;
      expect(l.text, 'Never exported: all of it is only on this phone.');
      expect(l.warn, isTrue);
      expect(exportLine(lastComplete: null, pendingFiles: 0, pendingBytes: 0, now: now), isNull);
    });

    test('recent: a plain line', () {
      final today = exportLine(lastComplete: DateTime(2026, 11, 22, 7), pendingFiles: 0, pendingBytes: 0, now: now)!;
      expect(today.text, 'Last export today; nothing new since.');
      expect(today.warn, isFalse);
      final y = exportLine(lastComplete: DateTime(2026, 11, 21, 23), pendingFiles: 3, pendingBytes: 2400000, now: now)!;
      expect(y.text, 'Last export yesterday; 3 new files (2.4\u00a0MB) since.');
      expect(y.warn, isFalse);
    });

    test('3 days or more with new files: a warning that says what is at risk', () {
      final l = exportLine(lastComplete: DateTime(2026, 11, 19, 9), pendingFiles: 37, pendingBytes: 210000000, now: now)!;
      expect(l.text, 'Last export 3 days ago: 37 new files (210\u00a0MB) are only on this phone.');
      expect(l.warn, isTrue);
      final quiet = exportLine(lastComplete: DateTime(2026, 11, 10), pendingFiles: 0, pendingBytes: 0, now: now)!;
      expect(quiet.warn, isFalse);
      expect(quiet.text, 'Last export 12 days ago; nothing new since.');
    });
  });

  test('pending: what the next export would copy', () async {
    expect(pendingExport(files), (files: 18, bytes: storedFiles(files).fold(0, (s, f) => s + f.bytes), lastComplete: null));
    await export();
    expect(pendingExport(files), (files: 0, bytes: 0, lastComplete: now));
    ExportStore(files).chooseFolder('content://tree/one', 'Download/EEG');
    final sum = summarizeExport(files);
    expect((sum.phoneFiles, sum.pendingFiles, sum.folderLabel), (18, 18, 'Download/EEG'));
    expect(sum.phoneBytes, sum.pendingBytes);
  });
}

String _offset(DateTime t) {
  final o = t.timeZoneOffset;
  final m = o.inMinutes.abs();
  return '${o.isNegative ? '-' : '+'}${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
}
