// Your answers as truth labels (DECISIONS 861, 866): the truth schema of scripts/truth.py, one row per Yes or No, as
// tab-separated text pandas reads as it is. A Yes says the estimate's stretch was what the detector thought
// (`present` 1); a No says it was not (`present` 0: the detector was wrong there, as useful to know). Not sure makes no
// row. The laptop builds the same rows from estimates.jsonl and answers.jsonl (truth.py `confirm_rows`); one golden
// file checks both. Plain Dart.
import 'time.dart';
import 'estimate.dart';
import 'store.dart';

const List<String> labelColumns = [
  'label_id', 'start', 'end', 'recording', 'kind', 'label', 'value', 'unit', 'source', 'confidence', 'created',
  'supersedes', 'owner_words', 'context', 'present', 'estimate_id', //
];

/// The vocabulary's source of an answer: the stop sheet's own, or the app's question.
String sourceOf(String via) => via == AnswerVia.stopSheet.wire ? 'owner_stop_sheet' : 'owner_app_prompt';

/// What the detector said, for people and agents reading the row.
String contextOf(Estimate e) =>
    'the app asked; ${e.detector} (${e.version}) said ${e.label.id}'
    '${e.confidence == null ? '' : ', confidence ${e.confidence!.toStringAsFixed(2)}'}';

/// One answered estimate as a row; null for Not sure.
Map<String, String>? labelRow(Estimate e, Answered a) {
  if (a.answer == Answer.skip) return null;
  final yes = a.answer == Answer.yes;
  return {
    'label_id': 'confirm:${e.id.substring(4)}',
    'start': isoLocal(e.start),
    'end': isoLocal(e.end),
    'recording': e.recording ?? '',
    'kind': e.label.kind,
    'label': e.label.id,
    'value': '',
    'unit': '',
    'source': sourceOf(a.via),
    'confidence': yes ? e.yesMeans.name : 'certain',
    'created': isoLocal(a.at),
    'supersedes': '',
    'owner_words': a.note == null ? a.answer.word : '${a.answer.word}: ${a.note}',
    'context': contextOf(e),
    'present': yes ? '1' : '0',
    'estimate_id': e.id,
  };
}

/// A cell as Python's csv writes it with its minimal quoting (and pandas reads by default).
String tsvCell(String v) => RegExp('[\t\n\r"]').hasMatch(v) ? '"${v.replaceAll('"', '""')}"' : v;

/// The whole labels file: a header, then the rows by start time, then id.
String labelsTsv(ConfirmState state) {
  final rows = <Map<String, String>>[
    for (final a in state.answers.entries)
      if (state.estimates[a.key] != null) ?labelRow(state.estimates[a.key]!, a.value),
  ]..sort((a, b) {
      final t = DateTime.parse(a['start']!).compareTo(DateTime.parse(b['start']!));
      return t != 0 ? t : a['label_id']!.compareTo(b['label_id']!);
    });
  final out = StringBuffer('${labelColumns.join('\t')}\n');
  for (final r in rows) {
    out.writeln([for (final c in labelColumns) tsvCell(r[c] ?? '')].join('\t'));
  }
  return out.toString();
}
