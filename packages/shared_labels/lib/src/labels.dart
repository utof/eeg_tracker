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

/// The columns of the estimates table, the laptop's `estimates.tsv` (scripts/data_book.py ESTIMATE_COLUMNS).
const List<String> estimateColumns = [
  'estimate_id', 'start', 'end', 'recording', 'kind', 'label', 'detector', 'detector_version', 'confidence',
  'yes_means', 'made', 'answer', 'answered', 'via', 'label_id', 'owner_words', //
];

/// A number as the laptop's tables write it: three decimals at most, no trailing zeros.
String tsvNumber(double v) {
  final s = v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return s == '-0' ? '0' : s;
}

/// Every estimate with what you answered (`yes`, `no`, `skip` for Not sure, or empty: not answered yet), by start
/// time, then id: the table another app takes so it does not ask the same thing again.
String estimatesTsv(ConfirmState state) {
  final rows = <Map<String, String>>[
    for (final e in state.estimates.values)
      () {
        final a = state.answers[e.id];
        return {
          'estimate_id': e.id,
          'start': isoLocal(e.start),
          'end': isoLocal(e.end),
          'recording': e.recording ?? '',
          'kind': e.label.kind,
          'label': e.label.id,
          'detector': e.detector,
          'detector_version': e.version,
          'confidence': e.confidence == null ? '' : tsvNumber(e.confidence!),
          'yes_means': e.yesMeans.name,
          'made': isoLocal(e.made),
          'answer': a?.answer.name ?? '',
          'answered': a == null ? '' : isoLocal(a.at),
          'via': a?.via ?? '',
          'label_id': a == null || a.answer == Answer.skip ? '' : 'confirm:${e.id.substring(4)}',
          'owner_words': a?.note ?? '',
        };
      }(),
  ]..sort((a, b) {
      final t = a['start']!.compareTo(b['start']!);
      return t != 0 ? t : a['estimate_id']!.compareTo(b['estimate_id']!);
    });
  final out = StringBuffer('${estimateColumns.join('\t')}\n');
  for (final r in rows) {
    // the data book's cell rule: text as it is, a tab or a line break inside it a space (no quoting)
    out.writeln([for (final c in estimateColumns) (r[c] ?? '').replaceAll(RegExp(r'[\t\r\n]'), ' ')].join('\t'));
  }
  return out.toString();
}
