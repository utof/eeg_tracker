// Automatic recording, phase 1 (ROADMAP row 39, DECISIONS 600-609; research
// _local/research/2026-11-20-00-auto-activity.md): what happens when something wakes the watcher (the headband came
// near, a bedtime check, the laptop started a work session, the app was opened, "Check now").
//
//  1. Nothing during a night recording or a session; nothing when the kind it guesses is "Do nothing" or quiet after
//     "Not now".
//  2. The kind from the phone's context first (rules.dart): night, work or other.
//  3. The worn check (probe.dart): contact for about 6 s and the battery. Not near or off the head: the wearing ends.
//  4. The battery guard (battery_guard.dart): a daytime session only while the headband keeps enough for tonight.
//  5. As the setting says. Start automatically: the night recorder (recording, the drift-off detector, sleep scoring
//     after Stop; no sounds, alarms or cues), or the work page with a silent session unless its chime was switched on.
//     Ask me: one quiet notification, the minutes since the check kept in memory meanwhile (preroll.dart). Yes starts
//     from when the headband was found on; Not now or no answer in 15 minutes writes nothing and keeps that kind quiet
//     for 30 minutes and the rest of the wearing. After 10 yes in a row the app offers to start that kind by itself
//     (only your tap switches it).
//  6. Every step goes into the log (log.dart).
// Sounds, alarms, cues, neurofeedback, the dream catcher and the microphone are never started from here.
import 'dart:async';
import 'dart:io';

import '../recorder/nights.dart' show dateName, nightsIn;
import '../sleep/report.dart' show isoLocal;
import '../headband/battery_estimate.dart';
import 'battery_guard.dart';
import 'bedtime.dart';
import 'laptop.dart';
import 'log.dart';
import 'preroll.dart';
import 'probe.dart';
import 'rules.dart';
import 'store.dart';

/// What woke the watcher: `presence` (the headband came near), `bedtime` (a check in the bedtime window), `laptop`,
/// `opened` (the app), `now` ("Check now" on the settings page, [force]: asks even when quiet or already asked).
class AutoTrigger {
  const AutoTrigger(this.reason, {this.force = false, this.fake});
  final String reason;
  final bool force;

  /// Debug builds only (the emulator smoke test): `worn` or `off`, a simulated headband instead of a search.
  final String? fake;
}

/// One quiet notification with its buttons ([actions]: answer id and label). A work start opens the app's work page
/// from the tap itself (Android lets a notification tap open a page, not a later step), so the question carries the
/// work session's options.
class AutoQuestion {
  const AutoQuestion({
    required this.id,
    required this.kind,
    required this.title,
    required this.text,
    required this.actions,
    this.workQuiet = true,
    this.workLimit,
  });

  final String id;
  final WearKind kind;
  final String title, text;
  final List<(String, String)> actions;
  final bool workQuiet;
  final Duration? workLimit;

  Map<String, Object?> toChannel() => {
    'id': id,
    'kind': kind.wire,
    'title': title,
    'text': text,
    'actions': [for (final (a, _) in actions) a],
    'labels': [for (final (_, l) in actions) l],
    'workQuiet': workQuiet,
    'workLimitMin': workLimit?.inMinutes,
  };
}

/// The phone's side, as the watcher needs it (the Android channel; a fake in tests).
abstract class AutoPhone {
  /// Charging, screen, Do Not Disturb, the next alarm (the laptop is read from its file).
  Future<PhoneContext> context(DateTime now);

  /// Why the headband must not be touched now (`night recording`, `session`), or null.
  Future<String?> busy();

  Future<void> ask(AutoQuestion q);

  /// Takes the question away (answered elsewhere, timed out, or a start by hand).
  Future<void> withdraw();

  /// A quiet line without buttons.
  Future<void> notice(String title, String text);

  /// "You said yes 10 times in a row: start the night automatically from now on?"
  Future<void> offer(WearKind kind);
}

/// What the watcher may start.
abstract class AutoStarter {
  /// The night recorder with [notes] for its log; an error in words, or null when it started.
  Future<String?> startNight({required List<String> notes});

  /// Opens the app's work page, which starts a session ([quiet]: no chime; [limit]: it stops itself then). False when
  /// Android did not let the app open its page from the background.
  Future<bool> openWork({required bool quiet, Duration? limit});
}

class AutoWatch {
  AutoWatch({
    required this.recordings,
    required this.check,
    required this.phone,
    required this.starter,
    this.simulate,
    DateTime Function()? clock,
    Future<void> Function(Duration)? waitFor,
  }) : _now = clock ?? DateTime.now,
       _wait = waitFor ?? Future<void>.delayed;

  /// The app's recordings folder (its parent holds `auto-start/`).
  final String recordings;
  final HeadbandCheck check;
  final AutoPhone phone;
  final AutoStarter starter;

  /// Debug builds: a simulated headband for a trigger with [AutoTrigger.fake].
  final HeadbandCheck Function(String fake)? simulate;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _wait;

  late final AutoStore store = AutoStore(autoDirFor(recordings));
  late final AutoLog log = AutoLog(store.dir);
  late final LaptopStore laptop = LaptopStore(store.dir);

  /// The headband's battery track shared with the card and the recorder (headband/battery_estimate.dart).
  late final BandBatteryStore bandBattery = BandBatteryStore.forRecordings(recordings);

  /// The charge to count with: [gauge], a new connection's reading, goes into the track, and the track's estimate is
  /// the answer (the gauge itself when the track has none). Null without a reading: "not known", as before.
  int? _believed(int? gauge, DateTime now) {
    if (gauge == null) return null;
    try {
      return bandBattery.note(gauge, now, streaming: false).now.percent ?? gauge;
    } catch (_) {
      return gauge;
    }
  }

  HeadbandCheck? _check;

  /// The check in flight, until it has let go of the headband or kept it.
  Future<ProbeResult>? _inCheck;
  Completer<String>? _answer;
  String? _questionId;
  bool _releasing = false;

  /// A question is waiting for its answer.
  bool get asking => _answer != null;

  /// The bedtime window now.
  UsualNight usual() => usualNight(recordedNights(Directory(recordings), _now()), store.settings());

  /// The checks to arm for the next 24 hours (none when every kind is "Do nothing").
  List<DateTime> nextChecks() => store.settings().allOff ? const [] : bedtimeChecks(usual(), _now());

  /// An answer from the notification (or the app). Ignored unless it answers the open question.
  void answer(String id, String answer) {
    final a = _answer;
    if (a != null && !a.isCompleted && id == _questionId) a.complete(answer);
  }

  /// A check in flight that is released stops at its next step (probe.dart); a start by hand waits at most this long
  /// for it to let go (Android's side answers the start by hand after 8 s whatever happens).
  static const Duration releaseWait = Duration(seconds: 6);

  /// A start by hand (or the Signal tab) needs the headband: let go of it now, withdraw the question, keep nothing.
  /// Returns once a check in flight has let go too, so the caller's search does not meet the watcher's connection.
  Future<void> release() async {
    _releasing = true;
    final a = _answer;
    if (a != null && !a.isCompleted) a.complete('released');
    final going = _inCheck;
    await _check?.release();
    if (going != null) {
      try {
        await going.timeout(releaseWait);
      } catch (_) {}
    }
  }

  /// The answer to the "start it automatically?" offer.
  void offerAnswer(WearKind kind, {required bool accept}) {
    if (accept) store.saveSettings(store.settings().withChoice(kind, AutoChoice.start));
    log.add(_now(), 'offer_answer', {'kind': kind.wire, 'accept': accept});
  }

  void _skip(DateTime now, AutoTrigger t, String why) => log.add(now, 'skipped', {'trigger': t.reason, 'why': why});

  Future<void> handle(AutoTrigger t) async {
    final now = _now();
    final s = store.settings();
    if (s.allOff && !t.force) return _skip(now, t, 'every kind is Do nothing');
    final busy = await phone.busy();
    if (busy != null) return _skip(now, t, 'busy: $busy');
    if (_answer != null) return _skip(now, t, 'a question is open');
    final ended = _lastData();
    if (!t.force && ended != null && now.difference(ended) < AutoRule.afterRecording) {
      return _skip(now, t, 'a recording ended at ${_hm(ended)}');
    }
    _releasing = false;
    final w = usualNight(recordedNights(Directory(recordings), now), s);
    final c = await phone.context(now);
    final ctx = PhoneContext(
      now: now,
      charging: c.charging,
      screenOn: c.screenOn,
      screenOffSince: c.screenOffSince,
      dnd: c.dnd,
      laptop: laptop.load(),
      nextAlarm: c.nextAlarm,
    );
    final guess = guessKind(ctx, w);
    final kind = guess.kind;
    var choice = s.choice(kind);
    var st = store.state();
    if (t.force && choice == AutoChoice.nothing) choice = AutoChoice.ask;
    if (choice == AutoChoice.nothing) return _skip(now, t, 'Do nothing (${kind.wire})');
    if (!t.force && st.quiet(kind, now)) return _skip(now, t, 'quiet after Not now (${kind.wire})');
    final handled = !t.force && st.wornSince != null && st.askedThisWearing.contains(kind);
    // the minutes are kept only where a night could follow: a work session records no raw signal
    final keep = choice == AutoChoice.ask && !handled && kind != WearKind.work;
    final fake = t.fake, sim = simulate;
    final probe = _check = fake != null && sim != null ? sim(fake) : check;
    if (_releasing) return _skip(now, t, 'let go: a start by hand'); // it came while the phone was read
    final preroll = Preroll();
    final checking = _inCheck = probe.check(keepIfWorn: keep, onBatch: preroll.add);
    final ProbeResult result;
    try {
      result = await checking;
    } finally {
      _inCheck = null;
    }
    log.add(now, 'check', {
      'trigger': t.reason,
      ...result.toLog(),
      'guess': kind.wire,
      'reasons': guess.reasons,
      'choice': choice.wire,
      'window': w.windowText,
      'phone': {
        'charging': ctx.charging,
        'screen_on': ctx.screenOn,
        if (ctx.screenOffSince != null) 'screen_off_min': now.difference(ctx.screenOffSince!).inMinutes,
        'dnd': ctx.dnd,
        if (ctx.laptop != null) 'laptop': {'working': ctx.laptop!.working, 'at': isoLocal(ctx.laptop!.at)},
        if (ctx.nextAlarm != null) 'next_alarm': isoLocal(ctx.nextAlarm!),
      },
    });
    if (_releasing) {
      await probe.release();
      log.add(_now(), 'released', {'kind': kind.wire});
      return;
    }
    if (!result.near || result.worn == false) {
      await probe.release();
      store.saveState(st.copyWith(wornSince: () => null, askedThisWearing: const {}));
      return;
    }
    if (result.worn == null) return probe.release(); // contact not readable: never taken as worn
    st = st.copyWith(wornSince: () => st.wornSince ?? now);
    if (handled) {
      await probe.release();
      store.saveState(st);
      return _skip(now, t, 'asked this wearing (${kind.wire})');
    }
    // the charge the guard counts with is the headband card's estimate (the one battery rule, DECISIONS 946): the
    // check's own reading goes into the shared track first; a gauge that sticks does not refuse or allow anything
    final charge = _believed(result.battery, now);
    final guard = guardBattery(kind, charge, now, w);
    if (guard.charge) {
      // too little for tonight by the estimate: one notice a day. Only the stopping rule (BatteryRule.onlyWarns
      // off) also refuses the session.
      if (!guard.allowed) await probe.release();
      log.add(now, guard.allowed ? 'warned' : 'declined', {
        'kind': kind.wire,
        'why': guard.note,
        'battery': result.battery,
        'estimate': charge,
      });
      final day = dateName(now);
      if (st.chargeNoticeDay != day) {
        await phone.notice(
          'Charge the headband for tonight',
          'It is at about $charge %; tonight needs about ${nightNeedPct(w)} %. '
              '${guard.allowed ? 'Charge it when you can.' : 'Nothing is recorded now.'}',
        );
        st = st.copyWith(chargeNoticeDay: day);
      }
      if (!guard.allowed) {
        store.saveState(st);
        return;
      }
    }
    store.saveState(st.copyWith(askedThisWearing: {...st.askedThisWearing, kind}));
    if (choice == AutoChoice.start) {
      await probe.release();
      if (kind == WearKind.night) return _startNightAuto(now, guess, guard);
      final opened = await starter.openWork(quiet: !s.workChime, limit: guard.limit);
      log.add(_now(), 'start', {
        'kind': kind.wire,
        'how': 'automatic',
        'quiet': !s.workChime,
        'limit_min': guard.limit?.inMinutes,
        if (!opened) 'error': 'Android did not let the app open its page',
      });
      if (opened) return;
    }
    await _ask(kind, now, probe, preroll, guard, s);
  }

  Future<void> _startNightAuto(DateTime found, KindGuess guess, BatteryVerdict guard) async {
    final err = await starter.startNight(
      notes: [
        'started automatically: the headband was found on at ${_hm(found)} (${guess.reasons.join(', ')}); recording '
            'and silent analysis only: no sounds, alarms or cues tonight',
        if (guard.note != null) guard.note!,
      ],
    );
    log.add(_now(), 'start', {'kind': WearKind.night.wire, 'how': 'automatic', 'error': ?err});
  }

  static String _hm(DateTime t) => clockText(t.hour * 60 + t.minute);

  /// The newest recording's last data, or null.
  DateTime? _lastData() {
    try {
      return nightsIn(Directory(recordings)).firstOrNull?.lastData;
    } catch (_) {
      return null;
    }
  }

  AutoQuestion _question(WearKind kind, String id, DateTime found, BatteryVerdict guard, AutoSettings s) {
    final said = guard.note?.replaceFirst(RegExp(r'\.$'), '');
    final note = said == null ? '' : ' ${said[0].toUpperCase()}${said.substring(1)}.';
    final quiet = !s.workChime;
    return switch (kind) {
      WearKind.night => AutoQuestion(
        id: id,
        kind: kind,
        title: 'Headband on. Start the night?',
        text: 'Recording only, no sounds. It counts from ${_hm(found)}.$note',
        actions: const [('yes', 'Start the night'), ('no', 'Not now')],
      ),
      WearKind.work => AutoQuestion(
        id: id,
        kind: kind,
        title: 'Headband on. Start a work session?',
        text: '${quiet ? 'Hints on the screen, no chime.' : 'Hints with the chime.'}$note',
        actions: const [('yes', 'Start'), ('no', 'Not now')],
        workQuiet: quiet,
        workLimit: guard.limit,
      ),
      WearKind.other => AutoQuestion(
        id: id,
        kind: kind,
        title: 'Headband on. What are you doing?',
        text: 'Nothing is recorded until you choose.$note',
        actions: const [('night', 'Night'), ('work', 'Work session'), ('no', 'Not now')],
        workQuiet: quiet,
        workLimit: guard.limit,
      ),
    };
  }

  Future<void> _ask(WearKind kind, DateTime found, HeadbandCheck probe, Preroll preroll, BatteryVerdict guard, AutoSettings s) async {
    final id = isoLocal(found);
    final q = _question(kind, id, found, guard, s);
    final answer = _answer = Completer<String>();
    _questionId = id;
    await phone.ask(q);
    final askedAt = _now();
    log.add(askedAt, 'question', {'kind': kind.wire, 'text': q.title});
    final a = await Future.any([answer.future, _wait(AutoRule.askFor).then((_) => 'none')]);
    _answer = null;
    _questionId = null;
    await phone.withdraw();
    final at = _now();
    log.add(at, 'answer', {'kind': kind.wire, 'answer': a, 'after_s': at.difference(askedAt).inSeconds});
    var st = store.state();
    if (a == 'yes' && kind == WearKind.night || a == 'night') {
      final span = preroll.span;
      String? stem;
      try {
        stem = preroll.write(Directory(recordings), [
          (found, 'auto-start: the headband was found on (check at ${_hm(found)}); these minutes were kept in memory while the app asked'),
          (at, 'auto-start: answered "${a == 'yes' ? 'Start the night' : 'Night'}" at ${_hm(at)}; the night recorder starts next'),
        ]);
      } catch (e) {
        log.add(at, 'start', {'kind': 'night', 'how': 'yes', 'error': 'the kept minutes could not be saved: $e'});
      }
      await probe.release();
      final err = await starter.startNight(
        notes: [
          'started after "Yes" to "${q.title}" (asked ${_hm(askedAt)}, answered ${_hm(at)}); recording and silent '
              'analysis only: no sounds, alarms or cues tonight',
          if (stem != null) 'the minutes from ${_hm(preroll.first ?? found)} were kept while asking: run $stem',
        ],
      );
      log.add(_now(), 'start', {
        'kind': 'night',
        'how': 'yes',
        'preroll_s': span.inSeconds,
        'stem': stem,
        'error': ?err,
      });
    } else {
      preroll.clear();
      await probe.release();
      if (a == 'yes' || a == 'work') {
        // the tap itself opened the work page, which starts the session
        log.add(at, 'start', {'kind': 'work', 'how': 'yes', 'quiet': q.workQuiet, 'limit_min': q.workLimit?.inMinutes});
      } else if (a == 'no' || a == 'none') {
        st = st.copyWith(quietUntil: {...st.quietUntil, kind: at.add(AutoRule.quietAfterNo)});
      }
    }
    if (kind != WearKind.other) st = _streak(st, kind, a, at);
    store.saveState(st);
  }

  /// Yes counts up, "Not now" starts again, no answer and a start by hand leave it. The offer comes once a streak.
  AutoState _streak(AutoState st, WearKind kind, String a, DateTime at) {
    if (a == 'no') {
      return st.copyWith(yesStreak: {...st.yesStreak, kind: 0}, offered: {...st.offered}..remove(kind));
    }
    if (a != 'yes') return st;
    final n = (st.yesStreak[kind] ?? 0) + 1;
    st = st.copyWith(yesStreak: {...st.yesStreak, kind: n});
    if (n >= AutoRule.offerAfterYes && !st.offered.contains(kind) && store.settings().choice(kind) == AutoChoice.ask) {
      unawaited(phone.offer(kind));
      log.add(at, 'offer', {'kind': kind.wire, 'yes_in_a_row': n});
      st = st.copyWith(offered: {...st.offered, kind});
    }
    return st;
  }
}
