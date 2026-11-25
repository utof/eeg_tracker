// The confirmation questions' one door (owner, 2026-11-20: "a lot of times I forget what happened even a few hours
// back, so best if the app asks right away"; DECISIONS 860-869). Everything else in the app talks to this class:
//
//   register(estimates)                 a detector's one call: "I think this happened then"
//   pending()                           the card: every open question (a notification takes only a batch of them)
//   pendingFor(recording, start, end)   the open questions of one recording (the stop sheet's "What was this recording?")
//   answer / undo / note                Yes, No, Not sure; take it back; a few words of your own
//   settle(recording, label, start, end) the stop sheet says a chip already answered it: never asked again
//   refresh()                           gather what the detectors left on disk, rewrite the labels file, arm the phone
//
// Until answered, a detector's output is an estimate, not a label. Yes makes a truth label that it happened (the
// times stay the detector's unless you set them), No a label that it was not so, Not sure is kept as its own answer
// and makes no label; none is asked twice. A question nobody answered is written down as that, never as Yes or No. Works offline: all of it is files in
// `files/confirm/` (store.dart) that the normal copy to the laptop takes.
import 'dart:async';
import 'dart:io';

import 'package:shared_labels/shared_labels.dart';

import '../archive/tags.dart';
import 'phone.dart';
import 'sources.dart';

class ConfirmQuestions {
  ConfirmQuestions(this.filesDir, {this.phone, DateTime Function()? clock})
    : store = ConfirmStore(filesDir),
      _clock = clock ?? DateTime.now;

  final Directory filesDir;
  final ConfirmStore store;

  /// The notification side; null: no notifications (tests, the stop sheet's own instance).
  final ConfirmPhone? phone;
  final DateTime Function() _clock;

  /// Called for each Yes with the estimate and the answer as it was kept: after "Yes, but the times are off" the
  /// answer holds the times you set (record-first's sleep stretches hook in here).
  static void Function(Estimate estimate, Answered answer)? onYes;

  /// The stretches you labelled yourself: every Archive tag (the stop sheet's chips are tags too).
  List<Labelled> labelled() {
    final dir = archiveDirFor(filesDir);
    if (!dir.existsSync()) return const [];
    final tags = TagStore(filesDir);
    return [
      for (final f in dir.listSync().whereType<File>())
        if (f.path.endsWith(tagsSuffix))
          for (final t in tags.tags(f.uri.pathSegments.last.replaceAll(tagsSuffix, ''))) (start: t.start, end: t.end, word: t.label),
    ];
  }

  /// The other app's say on when a push may go out (queue.dart [OtherAsker]); null: nobody else asks. The link to
  /// utof_tracker will set it.
  static OtherAsker? otherApp;

  /// The cards for [picks]: 1 in 5 is blind, drawn by the estimate's id (or made blind by rule), unless [guessShown];
  /// the times are asked about only on the stretch's own day.
  List<ConfirmQuestion> _questions(List<Pick> picks, DateTime now, ConfirmState state, {bool guessShown = false}) => [
    for (final p in picks)
      () {
        final e = p.estimate;
        final exact = timesAsked(e, now);
        final blind = !guessShown && (state.forcedBlind.contains(e.id) || blindByDraw(e.id));
        final guess = questionOf(e, now, exact: exact);
        return ConfirmQuestion(
          e,
          blind ? blindQuestionOf(e, now, exact: exact) : guess,
          p.why,
          kind: blind ? CardKind.blind : CardKind.normal,
          exactTimes: exact,
          guessText: guess,
        );
      }(),
  ];

  /// A detector's one call. Returns how many estimates were new.
  int register(Iterable<Estimate> estimates) => store.register(estimates);

  /// The card's batch; empty when switched off.
  List<ConfirmQuestion> pending() {
    final now = _clock();
    final state = store.read();
    final got = _questions(cardBatch(state, store.settings(), now, labelled: labelled()), now, state);
    quickChecksWaiting.value = got.length;
    return got;
  }

  /// What else was found around the card's questions, for the timeline of "Yes, but the times are off".
  List<Estimate> around() => store.read().estimates.values.toList();

  /// The open questions of recording [recordingId] between [start] and [end], most valuable first up to [max], in time
  /// order: the stop sheet shows them under its chips, whatever the switch or the hour.
  List<ConfirmQuestion> pendingFor(String recordingId, DateTime start, DateTime end, {int max = 5}) {
    final now = _clock();
    final state = store.read();
    final open = [
      for (final e in openEstimates(state, now, labelled: labelled(), recording: recordingId))
        if (!e.end.isBefore(start) && !e.start.isAfter(end)) e,
    ];
    return _questions(pickBatch(open, state, max), now, state, guessShown: true);
  }

  /// Called for every answer with the estimate and what was answered: [Answered.timesConfirmed] says whether the
  /// times are yours ([Answered.start], [Answered.end]) or still the detector's; a blind card's answer has
  /// [Answered.said].
  static void Function(Estimate estimate, Answered answer)? onAnswered;

  /// Your answer. [card] and [shown]: the card that asked and when it came on screen. [start] and [end] with a Yes:
  /// the times you set ("Yes, but the times are off"); without them a Yes says only that it happened. [said] and
  /// [words]: a blind card's answer ([Answer.said]).
  void answer(
    String estimateId,
    Answer a, {
    AnswerVia via = AnswerVia.card,
    CardKind? card,
    DateTime? shown,
    DateTime? start,
    DateTime? end,
    Label? said,
    String? words,
  }) {
    final state = store.read();
    if (state.answered(estimateId)) return;
    final e = state.estimates[estimateId];
    final label = said ?? (a == Answer.said && words != null ? Label.named(words) : null);
    store.answer(estimateId, a, via: via, at: _clock(), card: card, shown: shown, estimate: e, start: start, end: end, said: label, words: words);
    _afterChange();
    final p = phone;
    if (p != null) unawaited(p.answered(estimateId).catchError((Object _) {}).then((_) => plan()));
    if (e == null) return;
    final kept = store.read().answers[estimateId];
    if (kept == null) return;
    if (a == Answer.yes) onYes?.call(e, kept);
    onAnswered?.call(e, kept);
  }

  /// Takes an answer back; the question is open again.
  void undo(String estimateId) {
    store.undo(estimateId, at: _clock());
    _afterChange();
  }

  /// A few words beside the answer (kept verbatim in the label's `owner_words`).
  void note(String estimateId, String words) {
    if (cleanNote(words).isEmpty) return;
    store.note(estimateId, words, at: _clock());
    _afterChange();
  }

  /// The stop sheet's chip already said it: every open estimate of [recordingId] with [label] that lies mostly inside
  /// [start]..[end] gets [answer] (source `owner_stop_sheet`) and is never asked. "Awake the whole time" settles the
  /// recording's sleep estimates as No; "Walked 17:00-17:40" a walk inside those times as Yes. Returns how many.
  int settle(String recordingId, Label label, DateTime start, DateTime end, {Answer answer = Answer.yes}) {
    final now = _clock();
    final state = store.read();
    var n = 0;
    for (final e in state.estimates.values) {
      if (e.recording != recordingId || !e.label.sameAs(label) || state.answered(e.id)) continue;
      final lo = e.start.isAfter(start) ? e.start : start, hi = e.end.isBefore(end) ? e.end : end;
      final inside = hi.isAfter(lo) ? hi.difference(lo).inSeconds : 0;
      if (inside * 2 < e.length.inSeconds || e.length.inSeconds == 0) continue;
      store.answer(e.id, answer, via: AnswerVia.stopSheet, at: now);
      final p = phone;
      if (p != null) unawaited(p.answered(e.id).catchError((Object _) {}));
      n++;
    }
    if (n > 0) _afterChange();
    return n;
  }

  ConfirmSettings get settings => store.settings();

  Future<void> saveSettings(ConfirmSettings s) async {
    store.saveSettings(s);
    await plan();
  }

  /// Rewrites the two tables another app or a spreadsheet reads (DECISIONS 869): the labels, and every estimate with
  /// its answer.
  void _afterChange() {
    final state = store.read();
    store.writeLabels(labelsTsv(state));
    store.writeEstimates(estimatesTsv(state));
  }

  /// Gathers the estimates the detectors left on disk ([collect], default: sleep reports and walk files) and rewrites
  /// the labels file (the notification's buttons write answers while the app is closed). Plain file work, fit for a
  /// background isolate. Returns how many estimates were new.
  int gather({List<Estimate> Function(Directory filesDir)? collect}) {
    final added = store.register((collect ?? collectEstimates)(filesDir));
    if (added > 0 || store.answersFile.existsSync()) _afterChange();
    return added;
  }

  /// [gather], then the next notification is planned. Called when the app opens or returns, after a recording stops
  /// and after a detector's pass.
  Future<int> refresh({List<Estimate> Function(Directory filesDir)? collect}) async {
    final added = gather(collect: collect);
    await plan();
    return added;
  }

  /// Writes down which questions nobody answered and are now closed (too old to ask), each once, with why. Stored apart
  /// from the answers: silence is never a Yes or a No. Returns how many.
  int close() {
    final now = _clock();
    final state = store.read();
    var n = 0;
    void write(Estimate e, WhyNot why) {
      store.notAnswered(e.id, why, via: state.notified.contains(e.id) ? AnswerVia.notification : AnswerVia.card, at: now);
      n++;
    }

    for (final e in state.estimates.values) {
      final why = closedWhy(e, state, now);
      if (why != null) write(e, why);
    }
    if (n > 0) _afterChange();
    return n;
  }

  /// Arms the next notification batch, or cancels the one waiting when nothing is left to ask.
  Future<void> plan() async {
    final now = _clock();
    store.settleArmed(now);
    close();
    final state = store.read();
    final settings = store.settings();
    final rules = _backoff(state, settings, now);
    final batch = notificationBatch(state, settings, now, labelled: labelled());
    final at = planTime(batch, state, settings, now, backoff: rules, other: otherApp);
    final p = phone;
    if (at == null) {
      if (store.armed() != null) {
        store.saveArmed(null);
        await p?.arm(now, const [], const []).catchError((Object _) {});
      }
      return;
    }
    final ids = [for (final b in batch) b.estimate.id];
    final blind = rules.blindNext ? ids : const <String>[];
    final old = store.armed();
    if (old != null && old.at == at && old.ids.join(' ') == ids.join(' ') && old.blind.join(' ') == blind.join(' ')) return;
    if (blind.isNotEmpty && (old == null || old.blind.isEmpty)) {
      store.logBackoff('blind_batch', '${BackoffRule.autopilotBatches} batches in a row were all Yes within about a second a card', at: now);
    }
    store.saveArmed(Armed(at, ids, {for (final b in batch) b.estimate.id: b.why}, blind));
    // the words as read at the batch's moment ("yesterday" counts from then)
    final cards = _questions(batch, at, store.read());
    await p
        ?.arm(at, ids, [for (final c in cards) c.text], cards: [
          for (final c in cards)
            {
              'card': c.kind.name,
              'yes': c.kind == CardKind.blind ? '' : c.yes,
              'no': c.kind == CardKind.blind ? '' : c.no,
              'guess': c.estimate.label.id,
              'confidence': c.estimate.confidence,
              'end_ms': c.estimate.end.millisecondsSinceEpoch,
            },
        ])
        .catchError((Object _) {});
  }

  /// The back-off rules as of [now] (backoff.dart); each step is written down once with its reason.
  Backoff _backoff(ConfirmState state, ConfirmSettings settings, DateTime now) {
    final b = backoffOf(state, now, maxPerDay: settings.perDay);
    final steps = [for (final e in state.events) if (e.event == 'backoff') e];
    final level = steps.where((e) => const ['pause', 'one_a_day', 'normal'].contains(e.step)).lastOrNull?.step ?? 'normal';
    if (b.startsPause) {
      store.logBackoff('pause', b.reason, at: now, until: b.pausedUntil);
    } else if (b.step != level) {
      store.logBackoff(b.step, b.reason.isEmpty ? 'the answers are back' : b.reason, at: now);
    }
    for (final h in b.skipHours.entries) {
      if (steps.any((e) => e.step == 'skip_hour' && e.hour == h.key && e.until == h.value)) continue;
      store.logBackoff('skip_hour', '${BackoffRule.dismissalsInARow} batches in a row were swiped away in this hour', at: now, until: h.value, hour: h.key);
    }
    return b;
  }
}
