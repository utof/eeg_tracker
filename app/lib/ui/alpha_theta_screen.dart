// Alpha-theta training (ROADMAP row 22; DECISIONS rows 104-107). The flow around one session:
//   first use (screening, consent, stop plan) -> setup (session number, length rule, pause, decision after 10)
//   -> check-in -> the session (the meditation's controller in its alpha-theta kind: same headband handling,
//   calibration and view) -> grounding -> after-session questions (with the replay check's guess when it applies)
//   -> alertness check -> report.
// Stop is always on the screen and does not ask: the sound fades over about 10 s, then grounding.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../alphatheta/journal.dart';
import '../alphatheta/rules.dart';
import '../meditation/controller.dart';
import '../meditation/store.dart';
import '../phone.dart';
import '../recorder/brainbit.dart';
import '../session_keeper.dart';
import '../sound/alpha_theta_sound.dart';
import '../sound/soloud_sound.dart';
import '../training/check.dart';
import '../training/check_store.dart';
import '../training/control.dart';
import 'alpha_theta_views.dart';
import 'evidence_sheet.dart';
import 'meditation_view.dart';
import 'nearby.dart';
import 'training_settings_screen.dart';

enum _Page { loading, firstUse, setup, checkIn, session, grounding, after, alertness, report }

class AlphaThetaScreen extends StatefulWidget {
  const AlphaThetaScreen({super.key});

  @override
  State<AlphaThetaScreen> createState() => _AlphaThetaScreenState();
}

class _AlphaThetaScreenState extends State<AlphaThetaScreen> {
  final BrainBitFinder _finder = BrainBitFinder();
  late final MeditationController _c = MeditationController(
    finder: _finder,
    sound: () => SoloudSound(),
    alphaThetaSound: SoloudAlphaThetaSound.new,
  );
  _Page _page = _Page.loading;
  AtJournal? _journal;
  String? _recordings;
  String? _checkPreview;
  int _minutes = AtDose.shortMin;
  bool _nightRunning = false;
  bool _screenOn = false;
  final SessionKeeper _keeper = PhoneSessionKeeper();
  String _message = '';
  Stage _lastStage = Stage.setup;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final rec = await Phone.recordingsDir();
      if (rec != null) {
        _recordings = rec;
        final dir = sessionsDirFor(rec, SessionKind.alphaTheta);
        _c.store = MeditationStore(dir, kind: SessionKind.alphaTheta);
        _journal = AtJournal(dir)..load();
        _loadCheck();
      }
    } catch (_) {}
    final running = await FlutterForegroundTask.isRunningService;
    if (!mounted) return;
    setState(() {
      _nightRunning = running;
      _page = _journal?.profile.ready == true ? _Page.setup : _Page.firstUse;
      _minutes = lengthChoices(_journal?.done ?? 0).first;
    });
  }

  void _loadCheck() {
    final rec = _recordings, store = _c.store;
    if (rec == null || store == null || _c.active) return;
    final files = filesDirFor(rec);
    final cs = SettingsStore(files).load().replayCheck ? CheckStore(files, SessionKind.alphaTheta) : null;
    _c.checkStore = cs;
    _checkPreview = cs == null ? null : previewStatus(cs, donorCandidates(store, store.list()));
  }

  DateTime _now() => DateTime.now();

  void _save() {
    try {
      _journal?.save();
    } catch (e) {
      _say('Your answers could not be saved: $e');
    }
  }

  void _changed() {
    if (!mounted) return;
    final stage = _c.stage;
    if (stage != _lastStage) {
      _lastStage = stage;
      _screen(on: _c.active);
      if (!_c.active) _finder.dispose(anyLost: _c.leftLost);
      if (_page == _Page.session) {
        if (stage == Stage.rating) {
          _keepSession();
          _page = _Page.grounding;
        } else if (stage == Stage.setup) {
          _message = _c.message;
          _page = _Page.setup;
        }
      }
    }
    setState(() {});
  }

  /// The saved session's files go into the journal's entry for today's check-in.
  void _keepSession() {
    final j = _journal, r = _c.report;
    if (j == null || r == null || j.entries.isEmpty) return;
    final stem = r.logFile.replaceAll('.session.json', '');
    j.entries[j.entries.length - 1] = j.entries.last.copyWith(stem: stem, complete: r.complete);
    _save();
  }

  /// As for meditation: screen kept on, and the session survives a phone you lock yourself (DECISIONS row 194).
  void _screen({required bool on}) {
    if (_screenOn == on) return;
    _screenOn = on;
    unawaited(Phone.keepScreenOn(on: on).catchError((Object _) {}));
    _keeper.onStop = () => unawaited(_c.stop());
    unawaited(
      on
          ? _keeper.hold(const KeepSpec(title: 'Alpha-theta', text: 'Session running', headband: true))
          : _keeper.release(),
    );
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _c.dispose();
    _screen(on: false);
    super.dispose();
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm(String title, String body, String yes) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: Text(yes)),
          ],
        ),
      ) ==
      true;

  // ---- actions ----

  void _agree(String contact, String grounding) {
    final j = _journal;
    if (j == null) return _say('The app\'s folder is not known yet, so nothing can be saved. Try again.');
    final now = _now();
    j.profile = j.profile.copyWith(screened: now, consented: now, contact: contact, grounding: grounding);
    _save();
    setState(() => _page = _Page.setup);
  }

  Future<void> _resume() async {
    final j = _journal;
    if (j == null) return;
    final ok = await _confirm(
      'Resume alpha-theta?',
      'Only after talking it over with a professional. If anything like a seizure happened, see a doctor first.',
      'Resume',
    );
    if (!ok) return;
    j.profile = j.profile.copyWith(resume: true);
    _save();
    setState(() {});
  }

  Future<void> _decide() async {
    final j = _journal;
    if (j == null) return;
    final ok = await _confirm(
      'Go on past 10 sessions?',
      'The research used about 10 sessions in healthy people. Going on is your choice; the same checks stay.',
      'Go on',
    );
    if (!ok) return;
    j.profile = j.profile.copyWith(decidedPast10: _now());
    _save();
    setState(() {});
  }

  Future<void> _openSettings() async {
    final rec = _recordings;
    if (rec == null) return;
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => TrainingSettingsScreen(recordingsDir: rec)));
    if (mounted) setState(_loadCheck);
  }

  Future<void> _start(CheckIn checkIn, int? reactionMs) async {
    final j = _journal;
    if (j == null) return;
    final now = _now();
    j.entries.add(AtEntry(at: now, before: checkIn, beforeMs: reactionMs));
    final why = j.applyPauseRules(now, before: checkIn);
    _save();
    if (why != null) {
      setState(() => _page = _Page.setup);
      return;
    }
    if (await FlutterForegroundTask.isRunningService) {
      setState(() {
        _nightRunning = true;
        _page = _Page.setup;
      });
      return;
    }
    final phone = await Phone.snapshot().catchError((Object _) => const PhoneSnapshot({}));
    if (!await nearbyAllowed(phone.sdkInt) && !await requestNearby(phone.sdkInt)) {
      _say('Allow Nearby devices first: without it the headband cannot be found.');
      return;
    }
    if (!phone.bluetoothOn) {
      _say('Turn Bluetooth on, then start.');
      await Phone.openSettings('bluetooth');
      return;
    }
    if (phone.sdkInt >= 33) await FlutterForegroundTask.requestNotificationPermission();
    _loadCheck();
    setState(() => _page = _Page.session);
    await _c.start(Duration(minutes: _minutes), kind: SessionKind.alphaTheta);
  }

  void _afterSaved(AfterSession after, CheckRatings? ratings) {
    final j = _journal;
    if (j != null && j.entries.isNotEmpty) {
      j.entries[j.entries.length - 1] = j.entries.last.copyWith(after: after);
      j.applyPauseRules(_now(), afterSession: true);
      _save();
    }
    final r = ratings;
    _c.submitRatings(
      r == null
          ? null
          : CheckRatings(
              calm: r.calm,
              guess: r.guess,
              confidence: r.confidence,
              control: after.control,
              random: r.random,
            ),
    );
    setState(() => _page = _Page.alertness);
  }

  void _alertDone(int? ms, bool? ok) {
    final j = _journal;
    if (j != null && j.entries.isNotEmpty) {
      j.entries[j.entries.length - 1] = j.entries.last.copyWith(alertMs: ms, alertOk: ok);
      _save();
    }
    setState(() => _page = _Page.report);
  }

  void _done() {
    _c.again();
    setState(() {
      _message = '';
      _minutes = lengthChoices(_journal?.done ?? 0).contains(_minutes)
          ? _minutes
          : lengthChoices(_journal?.done ?? 0).first;
      _page = _Page.setup;
    });
  }

  @override
  Widget build(BuildContext context) {
    void info() => showEvidence(context, 'alpha-theta');
    final j = _journal;
    switch (_page) {
      case _Page.loading:
        return const Scaffold(body: SizedBox.shrink());
      case _Page.firstUse:
        return AtFirstUseView(onAgree: _agree, onInfo: info);
      case _Page.setup:
        final done = j?.done ?? 0;
        return AtSetupView(
          model: AtSetupModel(
            done: done,
            minutes: _minutes,
            lengths: lengthChoices(done),
            pausedWhy: j?.profile.pausedWhy,
            needsDecision: needsDecision(done, j?.profile.decidedPast10),
            checkOn: _c.checkStore != null,
            checkStatus: _checkPreview,
            contact: j?.profile.contact ?? '',
            grounding: j?.profile.grounding ?? defaultGrounding,
            nightRunning: _nightRunning,
            message: _message,
          ),
          onMinutes: (v) => setState(() => _minutes = v),
          onCheckIn: () => setState(() => _page = _Page.checkIn),
          onResume: _resume,
          onDecide: _decide,
          onInfo: info,
          onSettings: _openSettings,
        );
      case _Page.checkIn:
        return AtCheckInView(
          firstSession: (j?.entries.isEmpty ?? true),
          needReaction: (j?.usualMs.length ?? 0) < 3,
          onStart: _start,
          onBack: () => setState(() => _page = _Page.setup),
        );
      case _Page.grounding:
        return AtGroundingView(
          ownRoutine: j?.profile.grounding ?? '',
          onDone: () => setState(() => _page = _Page.after),
        );
      case _Page.after:
        return AtAfterView(asksGuess: _c.asksGuess, onSave: _afterSaved);
      case _Page.alertness:
        return AtAlertnessView(usualMs: j?.usualMs ?? const [], onDone: _alertDone);
      case _Page.session:
      case _Page.report:
        return _session(context, info);
    }
  }

  Widget _session(BuildContext context, VoidCallback info) {
    final c = _c, j = _journal;
    final paused = j?.profile.pausedWhy;
    final notes = [
      ?c.saveNote,
      if (_page == _Page.report && paused != null)
        'Alpha-theta is paused: $paused Please talk to a professional before the next session.',
    ];
    final model = meditationModel(
      stage: c.stage,
      minutes: c.length.inMinutes,
      message: c.message,
      chip: c.chip,
      calPhase: c.calPhase,
      calSecondsLeft: c.calSecondsLeft,
      calNeedsClean: c.calNeedsClean,
      runSeconds: c.runSeconds,
      bells: c.bells,
      contact: c.contact,
      soundNote: c.soundNote,
      saveNote: notes.isEmpty ? null : notes.join(' '),
      report: c.report,
      comparison: c.comparison,
      earlier: c.earlier,
      kind: SessionKind.alphaTheta,
      checkOn: c.checkOn,
      checkStatus: c.checkStatus,
      asleepGuard: c.asleepGuard,
    );
    return PopScope(
      canPop: !c.active,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await c.stop();
      },
      child: MeditationView(
        model: model,
        onMinutes: (_) {},
        onStart: () => unawaited(_c.start(Duration(minutes: _minutes), kind: SessionKind.alphaTheta)), // try again
        onStop: () => unawaited(c.stop()),
        onDone: _done,
        onInfo: info,
      ),
    );
  }
}
