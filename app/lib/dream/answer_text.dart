// The dream catcher's spoken answers as text (DECISIONS rows 250-259): one small file beside each answer's WAV in
// `files/dream-catcher/`, `<stamp>-r<n>.text.json` (docs/data-format.md):
//   machine  what the phone's speech-to-text heard: the text (empty: no words heard), the model, when, seconds of
//            audio and of voice, and how long it took; null until it has worked
//   edited   your own words for the answer when you changed them: shown instead, and never overwritten by the
//            machine (a later, better model may write `machine` again; your edit stays)
//   tries    attempts so far, counted when one starts (so an app that dies mid-way counts it too); after 2 the
//            answer waits for Try again
//   failed   why the last try did not work; the WAV is always kept
// Pure apart from reading and writing that file.
import 'dart:convert';
import 'dart:io';

import 'store.dart';

/// Attempts before an answer waits for Try again.
const int maxTextTries = 2;

/// `<stamp>-r<n>.text.json` for the answer `<stamp>-r<n>.wav`.
String textFileName(String answerFile) => '${answerFile.substring(0, answerFile.length - 4)}.text.json';

double _tenth(double v) => (v * 10).round() / 10;
double? _num(Object? v) => v is num && v.isFinite && v >= 0 ? v.toDouble() : null;

class MachineText {
  const MachineText({
    required this.text,
    required this.model,
    required this.at,
    required this.audioS,
    required this.voiceS,
    required this.tookS,
  });

  /// What was heard; empty when no words were.
  final String text;

  /// The speech model's id (SpeechModelSpec.id).
  final String model;
  final DateTime at;

  /// Seconds in the WAV, seconds the voice detector kept, seconds the phone took.
  final double audioS;
  final double voiceS;
  final double tookS;

  Map<String, Object?> toJson() => {
    'text': text,
    'model': model,
    'at': at.toIso8601String(),
    'audioS': _tenth(audioS),
    'voiceS': _tenth(voiceS),
    'tookS': _tenth(tookS),
  };

  static MachineText? fromJson(Object? j) {
    if (j is! Map) return null;
    final text = j['text'], model = j['model'], at = DateTime.tryParse('${j['at']}');
    final audioS = _num(j['audioS']), voiceS = _num(j['voiceS']), tookS = _num(j['tookS']);
    if (text is! String || model is! String || at == null || audioS == null || voiceS == null || tookS == null) {
      return null;
    }
    return MachineText(text: text, model: model, at: at, audioS: audioS, voiceS: voiceS, tookS: tookS);
  }
}

class AnswerText {
  const AnswerText({required this.answer, this.machine, this.edited, this.tries = 0, this.failed});

  static const int version = 1;

  /// The answer's WAV in the same folder.
  final String answer;
  final MachineText? machine;
  final String? edited;
  final int tries;
  final String? failed;

  /// What the list shows: your words when you changed them, else the machine's (null: none yet).
  String? get shown => edited ?? machine?.text;

  /// Waits to be written out.
  bool get due => machine == null && tries < maxTextTries;

  /// A try started and never ended: the app stopped while it worked.
  bool get stalled => machine == null && tries > 0 && failed == null;

  AnswerText _copy({MachineText? machine, String? edited, bool clearEdit = false, int? tries, String? failed, bool clearFailed = false}) =>
      AnswerText(
        answer: answer,
        machine: machine ?? this.machine,
        edited: clearEdit ? null : edited ?? this.edited,
        tries: tries ?? this.tries,
        failed: clearFailed ? null : failed ?? this.failed,
      );

  /// A try starts.
  AnswerText started() => _copy(tries: tries + 1, clearFailed: true);

  /// A try was called off before its end (a session started): it does not count.
  AnswerText calledOff() => _copy(tries: tries > 0 ? tries - 1 : 0);

  AnswerText withMachine(MachineText m) => _copy(machine: m, clearFailed: true);
  AnswerText withFailure(String why) => _copy(failed: why);

  /// Your words; the machine's own text again is no edit.
  AnswerText edit(String text) {
    final m = machine;
    if (m != null && text.trim() == m.text.trim()) return _copy(clearEdit: true);
    return _copy(edited: text);
  }

  AnswerText undoEdit() => _copy(clearEdit: true);

  /// Try again: the tries start over.
  AnswerText retry() => _copy(tries: 0, clearFailed: true);

  Map<String, Object?> toJson() => {
    'version': version,
    'answer': answer,
    'machine': machine?.toJson(),
    'edited': edited,
    'tries': tries,
    'failed': failed,
  };

  static AnswerText? fromJson(Object? j) {
    if (j is! Map || j['version'] != version) return null;
    final answer = j['answer'], edited = j['edited'], tries = j['tries'], failed = j['failed'], m = j['machine'];
    if (answer is! String || answer.contains('/') || !answer.endsWith('.wav')) return null;
    if ((edited != null && edited is! String) || (failed != null && failed is! String)) return null;
    if (tries is! int || tries < 0) return null;
    final machine = MachineText.fromJson(m);
    if (m != null && machine == null) return null;
    return AnswerText(answer: answer, machine: machine, edited: edited as String?, tries: tries, failed: failed as String?);
  }
}

/// The text of [answerFile] in [dir], or null when there is none or it cannot be read.
AnswerText? readAnswerText(Directory dir, String answerFile) {
  final f = File('${dir.path}/${textFileName(answerFile)}');
  try {
    if (!f.existsSync()) return null;
    final t = AnswerText.fromJson(jsonDecode(f.readAsStringSync()));
    return t != null && t.answer == answerFile ? t : null;
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
}

/// Writes [t] beside its WAV (under a temporary name, then renamed).
void writeAnswerText(Directory dir, AnswerText t) {
  final f = File('${dir.path}/${textFileName(t.answer)}'), tmp = File('${f.path}.tmp');
  tmp.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(t.toJson()), flush: true);
  tmp.renameSync(f.path);
}

/// Answers waiting to be written out, in [sessions]' order (newest first as `DreamStore.list` gives them), each
/// round's in turn: a WAV on the phone and no text yet, or one whose last try failed or stopped, under 2 tries.
List<String> dueAnswers(DreamStore store, List<DreamSession> sessions) => [
  for (final s in sessions)
    for (final r in s.rounds)
      if (r.answerFile case final f? when File('${store.dir.path}/$f').existsSync())
        if (readAnswerText(store.dir, f)?.due ?? true) f,
];
