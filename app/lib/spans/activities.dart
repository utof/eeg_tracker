// Work, Meditate, Nap and the other sessions as activities of the recording that runs (Record first, step 4;
// DECISIONS 881, 884, 897, 980-984). An activity is a span in the recording's spans file plus the session's own live
// part, which reads the recorder's stream (headband/connection.dart `RecordingBand`): no new search, no new
// connection, no new file, no new contact check.
// One door: a screen makes its finder with `BrainBitFinder(activity: 'work')`. When the session asks that finder for
// the headband, [Activities.begin] runs first:
// - a recording runs: the recorder is asked to open the span;
// - nothing records: the recorder is started with this span as its first one (the span remembers that it started the
//   recording), exactly as Sleep starts it;
// then the session gets the recording's stream. When the session lets the headband go, [Activities.end] closes the
// span; if the activity started the recording, [ask] holds the question "Stop everything or keep recording?" for the
// app to show (ui/activity_stop.dart).
// The recorder's engine writes the span (one writer per file); this side only sends the two commands and reads the
// recorder's status. Everything here is for any headband with any number of channels: nothing looks at the samples.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../headband/connection.dart';
import '../logs/app_log.dart';
import '../recorder/status.dart' show RecordingLive;
import 'span.dart';

/// The recorder's commands for a span (the service applies them with `NightRecorder.spanCommand`).
Map<String, Object?> openSpanCommand(String kind, {String? session, bool startedRecording = false}) => {
  'kind': 'span',
  'op': 'open',
  'span_kind': kind,
  'session': ?session,
  if (startedRecording) 'started_recording': true,
};

Map<String, Object?> closeSpanCommand(String id, {String by = 'owner'}) => {'kind': 'span', 'op': 'close', 'id': id, 'by': by};

/// "Still going? Undo": opens again what the 60-minute rule ended (`RecordingLive.undoable`; DECISIONS 899, 986).
const Map<String, Object?> undoOffCommand = {'kind': 'span', 'op': 'undo_off'};

/// Why an activity could not start, in the owner's words.
class ActivityRefused implements Exception {
  const ActivityRefused(this.why);
  final String why;

  @override
  String toString() => why;
}

/// One activity while it runs.
class ActivityRun {
  ActivityRun(this.kind, {required this.startedRecording});

  /// The span kind (`work`, `meditate`, ...).
  final String kind;

  /// This activity's start also started the recorder: its Stop asks "Stop everything or keep recording?".
  final bool startedRecording;

  /// The span as the recorder wrote it (null when the recorder never answered).
  Span? span;

  /// How it ended, for the span's `ended_by`: `owner` unless the session says it ended by itself (`activity`).
  String endedBy = 'owner';
  bool over = false;

  /// The recording's id; null until its first file set opens (the headband was not found yet).
  String? get recording {
    final id = span?.recording;
    return id == null || id == '?' ? null : id;
  }

  String get word => spanWord(kind);
}

/// What the session that rides on the recording now names in its own file; null when none does.
ActivityRef? activityRef() => Activities.shared?.ref;

/// Where an activity's signal is: what its own session file names instead of a raw file of its own. It follows the
/// activity's span as the recorder tells it ([Activities] keeps the run's span current), so a session that took it
/// at its start and reads it when it saves gets the recording's id and the span's final number, not the `?-1` of a
/// start before the headband was found.
class ActivityRef {
  const ActivityRef._(this._run, this._first);
  final ActivityRun _run;
  final Span _first;

  /// The recording's id (null: the recording had not found the headband when the session was saved).
  String? get recording => _run.recording;
  String get span => (_run.span ?? _first).id;

  /// The two fields every activity's own file gets (spec section 5.3).
  Map<String, Object?> toJson() => {'recording': recording, 'span': span};
}

class Activities {
  Activities({
    required this.owner,
    required this.send,
    required this.serviceRuns,
    this.askStatus,
    this.answerWait = const Duration(seconds: 20),
    this.askEvery = const Duration(milliseconds: 400),
  }) {
    owner.status.addListener(_follow);
  }

  /// The screen's engine's activities (set in main.dart); null in the other engines and in tests that make their own.
  static Activities? shared;

  final HeadbandConnection owner;

  /// Sends a command to the recorder's engine.
  final void Function(Object message) send;

  /// Whether the recorder's service runs (its status may not have reached this engine yet).
  final Future<bool> Function() serviceRuns;

  /// Asks the recorder for its status now.
  final void Function()? askStatus;

  /// How long the recorder may take to answer with the span.
  final Duration answerWait, askEvery;

  /// Starts the recorder with [kind] as its first span (set by the Record tab, which owns starting and stopping: the
  /// permissions, the share server's hand-over, the lend of a live connection). Null when it started, else why not in
  /// the owner's words.
  Future<String?> Function(String kind)? startRecording;

  /// Stop everything: ends the recording as the Record tab's Stop does, and shows its sheet.
  Future<void> Function()? stopRecording;

  /// The activity that runs now.
  final ValueNotifier<ActivityRun?> current = ValueNotifier<ActivityRun?>(null);

  /// An activity that started the recording has ended and the recording still runs: the app asks "Stop everything
  /// or keep recording?" and sets this back to null.
  final ValueNotifier<ActivityRun?> ask = ValueNotifier<ActivityRun?>(null);

  static final AppLog _log = AppLog('spans');

  /// The running recording as the recorder last told it.
  RecordingLive? get recording => owner.recording;

  /// What the running activity's own file names as its signal; null when no activity rides on a recording. Read
  /// from the recorder's status now, not from the activity's start: a span opened before the headband was found is
  /// `?-1` with no recording until the first file set opens, and is numbered again then.
  ActivityRef? get ref {
    final run = current.value;
    if (run == null || run.over) return null;
    _follow();
    final span = run.span;
    return span == null ? null : ActivityRef._(run, span);
  }

  /// The running activity's span as the recorder has it now (its id changes once: when the recording gets its own).
  void _follow() {
    final run = current.value;
    if (run == null || run.over) return;
    final now = owner.recording?.open(run.kind);
    if (now != null) run.span = now;
  }

  /// Starts [kind] as an activity: its span is open on the running recording when this returns (the recorder is
  /// started first when nothing records). Throws [ActivityRefused] when it could not.
  Future<ActivityRun> begin(String kind) async {
    final before = current.value;
    if (before != null && !before.over) await end(before, by: 'other_activity');
    ask.value = null; // a new start answers an old question: the recording is wanted
    var running = owner.nightRuns || owner.lending;
    if (!running) {
      try {
        running = await serviceRuns();
      } catch (_) {}
    }
    final ActivityRun run;
    if (running) {
      final rec = await _recording();
      // one activity at a time (DECISIONS 983): a sleep or a nap that is marked is ended by its own Stop first
      final sleep = rec?.openSleep;
      if (sleep != null && sleep.kind != kind) {
        final at = '${sleep.start.hour.toString().padLeft(2, '0')}:${sleep.start.minute.toString().padLeft(2, '0')}';
        throw ActivityRefused(
          '${spanWord(sleep.kind)} is marked since $at. Stop sleep on the Record tab first, then start ${spanWord(kind)}.',
        );
      }
      // a span whose session is gone (its screen was closed, the app restarted) ends when the next activity starts
      for (final other in rec?.spans ?? const <Span>[]) {
        if (!other.closed && other.kind != kind) send(closeSpanCommand(other.id, by: leftOpen));
      }
      run = ActivityRun(kind, startedRecording: false);
      send(openSpanCommand(kind));
    } else {
      final start = startRecording;
      if (start == null) throw const ActivityRefused('The recorder cannot be started from here. Press Record first.');
      final why = await start(kind);
      if (why != null) throw ActivityRefused(why);
      run = ActivityRun(kind, startedRecording: true);
    }
    final span = await _spanOf(kind);
    if (span == null) {
      _log.warn('the recorder did not answer with the span', data: {'kind': kind, 'started': run.startedRecording});
      throw const ActivityRefused('The recorder did not answer. Look at the Record tab, then try again.');
    }
    run.span = span;
    current.value = run;
    _log.info('activity started', {'kind': kind, 'span': span.id, 'started_recording': run.startedRecording});
    return run;
  }

  /// The running recording once the recorder has told it (its service may run before its first status arrives here).
  Future<RecordingLive?> _recording() async {
    final sw = Stopwatch()..start();
    while (owner.recording == null && sw.elapsed < answerWait) {
      askStatus?.call();
      await Future<void>.delayed(askEvery);
    }
    return owner.recording;
  }

  /// The open span of [kind] in the recorder's status, asked for until it shows or [answerWait] is over.
  Future<Span?> _spanOf(String kind) async {
    final sw = Stopwatch()..start();
    while (true) {
      final span = owner.recording?.open(kind);
      if (span != null) return span;
      if (sw.elapsed >= answerWait) return null;
      askStatus?.call();
      await Future<void>.delayed(askEvery);
    }
  }

  /// Ends [run]: its span is closed on the recording (when that still runs), and when it started the recording the
  /// question waits in [ask].
  Future<void> end(ActivityRun run, {String? by}) async {
    if (run.over) return;
    run.over = true;
    if (identical(current.value, run)) current.value = null;
    final how = by ?? run.endedBy;
    final span = run.span;
    final rec = owner.recording;
    // the id may have changed since the start (a span opened before the headband was found is numbered again)
    final open = rec?.open(run.kind);
    if (open != null) run.span = open;
    final stillRuns = rec != null && open != null;
    if (span != null && stillRuns) send(closeSpanCommand(open.id, by: how));
    _log.info('activity ended', {'kind': run.kind, 'span': span?.id, 'by': how, 'recording_runs': stillRuns});
    if (stillRuns && run.startedRecording && how != 'other_activity') ask.value = run;
  }

  /// Stop of the recording was pressed (call it before the recorder is told): the activity that is alive ends here,
  /// by the owner; whatever else is still marked then was left open, and the recorder says so.
  void recordingStops() {
    final run = current.value;
    if (run == null || run.over) return;
    final open = owner.recording?.open(run.kind);
    if (open != null) send(closeSpanCommand(open.id, by: 'owner'));
  }

  /// The answer to [ask]: stop everything, or keep recording.
  Future<void> answer({required bool stopEverything}) async {
    final run = ask.value;
    ask.value = null;
    if (run == null) return;
    _log.info('after the activity', {'kind': run.kind, 'choice': stopEverything ? 'stop everything' : 'keep recording'});
    if (stopEverything) await stopRecording?.call();
  }
}
