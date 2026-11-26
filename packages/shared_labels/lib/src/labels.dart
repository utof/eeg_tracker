// Your answers as truth labels (DECISIONS 861, 866): the truth schema of scripts/truth.py, one row per Yes or No, as
// tab-separated text pandas reads as it is. A Yes says it happened (`present` 1; `times_confirmed` says whether the
// start and end are yours or still the detector's); a No says it did not (`present` 0: the detector was wrong there, as
// useful to know). Not sure makes no row, and neither does a question nobody answered. The laptop builds the same rows from estimates.jsonl and answers.jsonl (truth.py `confirm_rows`); one golden
// file checks both. Plain Dart.
import 'time.dart';
import 'estimate.dart';
import 'store.dart';

const List<String> labelColumns = [
  'label_id', 'start', 'end', 'recording', 'kind', 'label', 'value', 'unit', 'source', 'confidence', 'created',
  'supersedes', 'owner_words', 'context', 'present', 'estimate_id', 'times_confirmed', //
];

/// The vocabulary's source of an answer: the stop sheet's own, or the app's question.
String sourceOf(String via) => via == AnswerVia.stopSheet.wire ? 'owner_stop_sheet' : 'owner_app_prompt';

/// What the detector said, for people and agents reading the row.
String contextOf(Estimate e, {bool blind = false, bool choice = false}) =>
    '${choice ? 'the app asked to pick ${choiceWords(e)}' : (blind ? 'the app asked without showing its guess' : 'the app asked')}; '
    '${e.detector} (${e.version}) said ${e.label.id}'
    '${e.confidence == null ? '' : ', confidence ${e.confidence!.toStringAsFixed(2)}'}';

/// One answered estimate as a row; null for Not sure, and for a blind card's words that name no label.
///
/// `times_confirmed` says whose the start and end are. 0: the detector's. A plain Yes means "it happened", not "these
/// times are right", so its `confidence` is `likely` (the vocabulary's "the times are rough") and nothing may take
/// the row's edges as truth. 1: you set them yourself ("Yes, but the times are off"), and the row carries your times.
/// A blind card's answer is a row of the label you picked, whatever the detector had guessed.
Map<String, String>? labelRow(Estimate e, Answered a) {
  final label = a.answer == Answer.said ? a.said : e.label;
  if (a.answer == Answer.skip || label == null) return null;
  final set = a.timesConfirmed;
  final words = switch (a.answer) {
    Answer.said => a.words ?? label.id,
    _ => set ? 'Yes, with my times' : a.answer.word,
  };
  return {
    'label_id': 'confirm:${e.id.substring(4)}',
    'start': isoLocal(set ? a.start! : e.start),
    'end': isoLocal(set ? a.end! : e.end),
    'recording': e.recording ?? '',
    'kind': label.kind,
    'label': label.id,
    'value': '',
    'unit': '',
    'source': sourceOf(a.via),
    'confidence': a.answer == Answer.no ? 'certain' : (set ? e.yesMeans.name : 'likely'),
    'created': isoLocal(a.at),
    'supersedes': '',
    'owner_words': a.note == null ? words : '$words: ${a.note}',
    'context': contextOf(e, blind: a.answer == Answer.said, choice: a.answer == Answer.said && a.card == CardKind.choice),
    'present': a.answer == Answer.no ? '0' : '1',
    'estimate_id': e.id,
    'times_confirmed': set ? '1' : '0',
  };
}

/// A cell as Python's csv writes it with its minimal quoting (and pandas reads by default).
String tsvCell(String v) => RegExp('[\t\n\r"]').hasMatch(v) ? '"${v.replaceAll('"', '""')}"' : v;

/// A Yes that is no label any more: its estimate is in [takenAway] (the stretch the Yes made was taken away later).
bool _yesTakenAway(String estimateId, Answered a, Set<String> takenAway) => a.answer == Answer.yes && takenAway.contains(estimateId);

/// The whole labels file: a header, then the rows by start time, then id. [takenAway]: the estimates whose Yes made a
/// stretch you took away afterwards; such a Yes has no row while that lasts (the columns are the same).
String labelsTsv(ConfirmState state, {Set<String> takenAway = const {}}) {
  final rows = <Map<String, String>>[
    for (final a in state.answers.entries)
      if (state.estimates[a.key] != null && !_yesTakenAway(a.key, a.value, takenAway)) ?labelRow(state.estimates[a.key]!, a.value),
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
  'yes_means', 'made', 'answer', 'answered', 'via', 'label_id', 'owner_words', 'card', 'said', 'agrees',
  'times_confirmed', 'confirmed_start', 'confirmed_end', 'shown', 'seconds_to_answer', 'age_min', 'why_not', //
];

/// A number as the laptop's tables write it: three decimals at most, no trailing zeros.
String tsvNumber(double v) {
  final s = v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return s == '-0' ? '0' : s;
}

/// Every estimate with what you answered, by start time, then id: the table another app takes so it does not ask the
/// same thing again, and the one the monthly self-check reads (scripts/asking_check.py).
///
/// `answer`: `yes`, `no`, `not_sure` (its own answer: no label), `said` (a blind card: `said` is the label you picked,
/// `agrees` 1 when it is what the detector thought, 0 when not), `not_answered` (no answer came, `why_not` says why;
/// never read as Yes or No), or empty: still waiting. `label` and `confidence` are the detector's guess; `card` what
/// the card showed (`normal`, `blind`, `choice`: two words to pick from, `said` is the one picked, `agrees` empty); `times_confirmed` 1 only when you set the times yourself, which are then
/// `confirmed_start` and `confirmed_end` (`start` and `end` stay the detector's).
///
/// [takenAway] as in [labelsTsv]: such a Yes stays `yes` (it was said) and its `label_id` is empty, as in the laptop's
/// table.
String estimatesTsv(ConfirmState state, {Set<String> takenAway = const {}}) {
  final rows = <Map<String, String>>[
    for (final e in state.estimates.values)
      () {
        final a = state.answers[e.id];
        final none = a == null ? state.unanswered[e.id] : null;
        final agrees = a?.agrees(e.label);
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
          'answer': a?.answer.wire ?? (none == null ? '' : notAnsweredWire),
          'answered': a != null ? isoLocal(a.at) : (none == null ? '' : isoLocal(none.at)),
          'via': a?.via ?? none?.via ?? '',
          'label_id': a == null || labelRow(e, a) == null || _yesTakenAway(e.id, a, takenAway) ? '' : 'confirm:${e.id.substring(4)}',
          'owner_words': [?a?.words, ?a?.note].join(': '),
          'card': a?.card?.name ?? '',
          'said': a?.said?.id ?? '',
          'agrees': agrees == null ? '' : (agrees ? '1' : '0'),
          'times_confirmed': a == null || a.answer != Answer.yes ? '' : (a.timesConfirmed ? '1' : '0'),
          'confirmed_start': a != null && a.timesConfirmed ? isoLocal(a.start!) : '',
          'confirmed_end': a != null && a.timesConfirmed ? isoLocal(a.end!) : '',
          'shown': a?.shown == null ? '' : isoLocal(a!.shown!),
          'seconds_to_answer': a?.seconds == null ? '' : tsvNumber(a!.seconds!),
          'age_min': a?.ageMin == null ? '' : '${a!.ageMin}',
          'why_not': none?.why.wire ?? '',
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
