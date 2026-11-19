// What the app can see was done by itself (DECISIONS 340): only where it is cheap and certain, from the files each
// feature writes in the app's private `files/` folder. Each check returns one sentence for the card ("A check-in saved
// on Fri 20 Nov."), or null. Plain Dart, run off the screen's thread (Isolate.run); a damaged file only means "not
// seen". Tested on a fake app folder.
import 'dart:convert';
import 'dart:io';

import '../recorder/chunk_writer.dart' show recordBytes;
import '../recorder/nights.dart' show nightLabel;
import '../recorder/status.dart' show sampleRateHz;

typedef SeenCheck = String? Function(Directory files);

/// Card id -> its check. The cards with `auto: true` are exactly these (test/try_these_test.dart).
const Map<String, SeenCheck> seenChecks = {
  'night': _night,
  'sleep-time': _sleepTime,
  'check-in': _checkIn,
  'export': _export,
  'smart-alarm': _alarm,
  'meditation': _meditation,
  'sound': _sound,
  'nap': _nap,
  'dream': _dream,
  'dream-words': _dreamWords,
  'lucid': _lucid,
  'alpha-theta': _alphaTheta,
  'experiment': _experiment,
  'replay': _replay,
  'sharp': _sharp,
  'diy-board': _diyBoard,
  'study': _study,
};

/// The checks of [ids] (the cards not touched yet) that see something, in [ids]' order.
Map<String, String> seenByApp(Directory files, Set<String> ids) {
  final out = <String, String>{};
  for (final id in ids) {
    final check = seenChecks[id];
    if (check == null) continue;
    try {
      final s = check(files);
      if (s != null) out[id] = s;
    } on Object {
      // a file the app cannot read is not something it saw
    }
  }
  return out;
}

List<File> _files(Directory files, String dir, String suffix) {
  final d = Directory('${files.path}/$dir');
  if (!d.existsSync()) return const [];
  return [
    for (final f in d.listSync().whereType<File>())
      if (f.path.endsWith(suffix)) f,
  ]..sort((a, b) => b.path.compareTo(a.path)); // newest stamp first
}

/// `2026-11-20-071500.x` -> Fri 20 Nov; null for another name.
String? _stampDay(File f) {
  final m = RegExp(r'(\d{4})-(\d\d)-(\d\d)-\d{6}').firstMatch(f.uri.pathSegments.last);
  if (m == null) return null;
  return nightLabel(DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)));
}

String _day(String nightOf) => nightLabel(DateTime.parse(nightOf));

Map<String, dynamic>? _json(File f) {
  try {
    final j = jsonDecode(f.readAsStringSync());
    return j is Map<String, dynamic> ? j : null;
  } on Object {
    return null;
  }
}

Iterable<Map<String, dynamic>> _lines(File f) sync* {
  if (!f.existsSync()) return;
  for (final line in f.readAsLinesSync()) {
    Object? j;
    try {
      j = jsonDecode(line);
    } on FormatException {
      continue; // a line cut off by a crash
    }
    if (j is Map<String, dynamic>) yield j;
  }
}

Iterable<Map<String, dynamic>> _reports(Directory files) sync* {
  for (final f in _files(files, 'nights', '.report.json')) {
    final j = _json(f);
    if (j != null && j['scored'] == true && j['night_of'] is String) yield j;
  }
}

/// A scored night whose lights off came from the button.
String? _night(Directory files) {
  for (final r in _reports(files)) {
    final drift = r['drift_off'];
    if (drift is Map && drift['source'] == 'button') {
      return 'A night with Lights off tapped, scored: the night of ${_day(r['night_of'] as String)}.';
    }
  }
  return null;
}

/// A night scored on this phone, with the time it took.
String? _sleepTime(Directory files) {
  for (final r in _reports(files)) {
    final s = (r['scoring_s'] as num?)?.round();
    final took = s == null || s <= 0 ? '' : ' in ${s < 120 ? '$s s' : '${(s / 60).round()} min'}';
    return 'Scored on this phone$took: the night of ${_day(r['night_of'] as String)}.';
  }
  return null;
}

String? _checkIn(Directory files) {
  final f = _files(files, 'mornings', '.morning.json').firstOrNull;
  return f == null ? null : 'A check-in saved on ${_stampDay(f) ?? 'this phone'}.';
}

/// An export that copied everything it meant to.
String? _export(Directory files) {
  for (final j in _lines(File('${files.path}/export/exports.jsonl'))) {
    if (j['complete'] != true) continue;
    final at = j['exported'] is String ? DateTime.tryParse(j['exported'] as String)?.toLocal() : null;
    return 'Exported in full${at == null ? '' : ' on ${nightLabel(at)}'}.';
  }
  return null;
}

/// The phone's alarm rang (by the smart rule, at the window's end or as the backup).
String? _alarm(Directory files) {
  for (final j in _lines(File('${files.path}/alarms/rings.jsonl'))) {
    if (j['event'] != 'ring' || j['atMs'] is! int) continue;
    final at = DateTime.fromMillisecondsSinceEpoch(j['atMs'] as int);
    final hm = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    return 'The smart alarm rang on ${nightLabel(at)} at $hm.';
  }
  return null;
}

String? _session(Directory files, String dir, String suffix, String what) {
  final f = _files(files, dir, suffix).firstOrNull;
  return f == null ? null : '$what on ${_stampDay(f) ?? 'this phone'}.';
}

String? _meditation(Directory files) => _session(files, 'meditations', '.meditation.json', 'A meditation saved');
String? _nap(Directory files) => _session(files, 'naps', '.nap.json', 'A nap saved');
String? _dream(Directory files) => _session(files, 'dream-catcher', '.dream.json', 'A dream catcher session saved');
String? _alphaTheta(Directory files) =>
    _session(files, 'alpha-theta', '.alphatheta.json', 'An alpha-theta session saved');

String? _dreamWords(Directory files) =>
    _session(files, 'dream-catcher', '.text.json', 'An answer written out as words');

/// A morning's three questions answered (files/lucid/mornings/`<stamp>`.json, `answers`): the card's last step.
String? _lucid(Directory files) {
  for (final f in _files(files, 'lucid/mornings', '.json')) {
    if (_json(f)?['answers'] is Map) return 'Lucid dream questions answered on ${_stampDay(f) ?? 'this phone'}.';
  }
  return null;
}

/// Fall asleep with the headband: the card's last step (only that session keeps its EEG as a recording).
String? _sound(Directory files) {
  for (final f in _files(files, 'sound-states', '.sound.json')) {
    if (_json(f)?['recording'] is String) {
      return 'A Fall asleep session with the headband on ${_stampDay(f) ?? 'this phone'}.';
    }
  }
  return null;
}

String? _experiment(Directory files) {
  final d = Directory('${files.path}/experiments');
  if (!d.existsSync()) return null;
  for (final e in d.listSync().whereType<Directory>()) {
    if (File('${e.path}/plan.json').existsSync()) return 'An experiment started.';
  }
  return null;
}

/// The replay check's switch (files/settings.json, lib/training/check_store.dart).
String? _replay(Directory files) =>
    _json(File('${files.path}/settings.json'))?['replayCheck'] == true ? 'Switched on.' : null;

/// Answers on two different days: the card's "answer what comes for two days".
String? _sharp(Directory files) {
  final days = <String>{};
  for (final j in _lines(File('${files.path}/sharp-hours/ratings.jsonl'))) {
    final at = j['at'] is String ? DateTime.tryParse(j['at'] as String)?.toLocal() : null;
    if (at != null) days.add('${at.year}-${at.month}-${at.day}');
  }
  return days.length >= 2 ? 'Answers on ${days.length} days.' : null;
}

/// The board recorded on this phone (files/recordings-diy, one `<I4f` record a sample at 250 Hz) for 10 minutes or
/// more in all: the card's "after 10 minutes".
String? _diyBoard(Directory files) {
  final sets = _files(files, 'recordings-diy', '.f32');
  final samples = sets.fold<int>(0, (n, f) => n + f.lengthSync() ~/ recordBytes);
  final minutes = samples / sampleRateHz / 60;
  if (minutes < 10) return null;
  return 'The board recorded ${minutes.floor()} min on this phone, the newest on ${_stampDay(sets.first) ?? 'this phone'}.';
}

/// An evening answer and a morning answer in the study log: the card's "answer both once".
String? _study(Directory files) {
  var evening = false, morning = false;
  for (final j in _lines(File('${files.path}/study-review/log.jsonl'))) {
    if (j['kind'] == 'evening') evening = true;
    if (j['kind'] == 'morning') morning = true;
  }
  return evening && morning ? 'An evening and a morning answered.' : null;
}
