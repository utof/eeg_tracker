// The confirmation questions' one door (owner, 2026-11-20: "a lot of times I forget what happened even a few hours
// back, so best if the app asks right away"; DECISIONS 860-869). Everything else in the app talks to this class:
//
//   register(estimates)                 a detector's one call: "I think this happened then"
//   pending()                           the card's batch: the few most valuable open questions
//   pendingFor(recording, start, end)   the open questions of one recording (the stop sheet's "What was this recording?")
//   answer / undo / note                Yes, No, Not sure; take it back; a few words of your own
//   settle(recording, label, start, end) the stop sheet says a chip already answered it: never asked again
//   refresh()                           gather what the detectors left on disk, rewrite the labels file, arm the phone
//
// Until answered, a detector's output is an estimate, not a label. Yes makes a truth label over the estimate's
// stretch, No a label that it was not so, Not sure nothing; none is asked twice. Works offline: all of it is files in
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

  /// Called for each Yes with the estimate (record-first's sleep stretches hook in here).
  static void Function(Estimate estimate)? onYes;

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

  List<ConfirmQuestion> _questions(List<Pick> picks, DateTime now) => [
    for (final p in picks) ConfirmQuestion(p.estimate, questionOf(p.estimate, now), p.why),
  ];

  /// A detector's one call. Returns how many estimates were new.
  int register(Iterable<Estimate> estimates) => store.register(estimates);

  /// The card's batch; empty when switched off.
  List<ConfirmQuestion> pending() {
    final now = _clock();
    return _questions(cardBatch(store.read(), store.settings(), now, labelled: labelled()), now);
  }

  /// The open questions of recording [recordingId] between [start] and [end], most valuable first up to [max], in time
  /// order: the stop sheet shows them under its chips, whatever the switch or the hour.
  List<ConfirmQuestion> pendingFor(String recordingId, DateTime start, DateTime end, {int max = 5}) {
    final now = _clock();
    final state = store.read();
    final open = [
      for (final e in openEstimates(state, now, labelled: labelled(), recording: recordingId))
        if (!e.end.isBefore(start) && !e.start.isAfter(end)) e,
    ];
    return _questions(pickBatch(open, state, max), now);
  }

  void answer(String estimateId, Answer a, {AnswerVia via = AnswerVia.card}) {
    final state = store.read();
    if (state.answered(estimateId)) return;
    store.answer(estimateId, a, via: via, at: _clock());
    _afterChange();
    final p = phone;
    if (p != null) unawaited(p.answered(estimateId).catchError((Object _) {}).then((_) => plan()));
    final e = state.estimates[estimateId];
    if (a == Answer.yes && e != null) onYes?.call(e);
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

  /// Arms the next notification batch, or cancels the one waiting when nothing is left to ask.
  Future<void> plan() async {
    final now = _clock();
    store.settleArmed(now);
    final state = store.read();
    final settings = store.settings();
    final batch = notificationBatch(state, settings, now, labelled: labelled());
    final at = planTime(batch, state, settings, now);
    final p = phone;
    if (at == null) {
      if (store.armed() != null) {
        store.saveArmed(null);
        await p?.arm(now, const [], const []).catchError((Object _) {});
      }
      return;
    }
    final ids = [for (final b in batch) b.estimate.id];
    final old = store.armed();
    if (old != null && old.at == at && old.ids.join(' ') == ids.join(' ')) return;
    store.saveArmed(Armed(at, ids, {for (final b in batch) b.estimate.id: b.why}));
    // the words as read at the batch's moment ("yesterday" counts from then)
    await p?.arm(at, ids, [for (final b in batch) questionOf(b.estimate, at)]).catchError((Object _) {});
  }
}
