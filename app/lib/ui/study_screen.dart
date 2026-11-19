// The study reminders page and the one-tap question (ROADMAP "Evening study, morning review", the assistant's
// proposal; DECISIONS rows 400-401): reads the files and the phone's state, saves the switch and the two times,
// hands the phone every reminder ahead (sharp-hours questions too, lib/study/arm.dart), and lays it all out with
// study_view.dart. Reached from Settings.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../phone.dart';
import '../sharp/prompts.dart';
import '../sharp/schedule.dart' show PromptKind, clockText;
import '../sharp/store.dart';
import '../sleep/report.dart';
import '../study/arm.dart';
import '../study/page.dart';
import '../study/schedule.dart';
import '../study/store.dart';
import 'evidence_sheet.dart';
import 'study_view.dart';

class StudyScreen extends StatefulWidget {
  const StudyScreen({super.key, this.recordingsDir, this.phone, this.now});
  final String? recordingsDir;
  final SharpPhone? phone;
  final DateTime Function()? now;

  @override
  State<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends State<StudyScreen> {
  late final SharpPhone _phone = widget.phone ?? ChannelSharpPhone();
  StudyPageModel? _model;
  String? _dir, _error, _loadError;

  DateTime get _now => (widget.now ?? DateTime.now)();
  StudyStore get _store => StudyStore(studyDirFor(_dir!));

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<T> _safe<T>(Future<T> Function() f, T fallback) async {
    try {
      return await f();
    } catch (_) {
      return fallback;
    }
  }

  Future<void> _quiet(Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {
      // a settings page that does not open is not worth an error on this page
    }
  }

  Future<void> _load() async {
    try {
      _dir ??= widget.recordingsDir ?? await Phone.recordingsDir();
      if (_dir == null) throw StateError("the app's folder is not known");
      final notifications = await _safe(_phone.notificationsOn, true) && await _safe(_phone.studyNotificationsOn, true);
      final xiaomi = await _safe(() async => (await Phone.snapshot()).xiaomiOs != null, false);
      // the files are read after every wait, so a slow reload never shows older settings than a later change
      final store = _store;
      final m = buildStudyPage(
        saved: store.settings(),
        sharp: SharpStore(sharpDirFor(_dir!)).settings(),
        answers: store.answers(),
        events: store.promptEvents(),
        reports: NightReportStore(nightsDirFor(_dir!)).all(),
        now: _now,
        notificationsOn: notifications,
        xiaomi: xiaomi,
      );
      if (mounted) setState(() => _model = m);
    } catch (e) {
      if (mounted) setState(() => _loadError = '$e');
    }
  }

  /// The settings as saved now (the page's model can be a reload behind).
  StudySettings get _settings => _store.settings() ?? _model?.settings ?? const StudySettings(on: false);

  /// Saves [s] (and logs [event]), hands the phone the reminders ahead, and reads everything again.
  Future<void> _apply(StudySettings s, String event) async {
    try {
      _store
        ..saveSettings(s)
        ..logEvent(_now, event, {
          'evening': s.eveningMin == null ? 'auto' : clockText(s.eveningMin!),
          'morning': s.morningMin == null ? 'auto' : clockText(s.morningMin!),
        });
      await rearmPrompts(_dir!, _phone, _now);
      _error = null;
    } on Exception catch (e) {
      _error = 'The phone did not take the reminders: $e';
    }
    await _load();
  }

  Future<void> _toggle(bool on) async {
    if (_dir == null) return;
    if (on) {
      // Android 13+: the reminders are notifications; asked once, here
      await _safe(() => Permission.notification.request(), PermissionStatus.denied);
    }
    final s = _settings, now = _now;
    await _apply(s.copyWith(on: on, firstOn: s.firstOn ?? (on ? now : null), changed: now), on ? 'on' : 'off');
  }

  Future<void> _pick({required bool evening}) async {
    final m = _model;
    if (m == null || _dir == null) return;
    final now = evening ? m.times.evening : m.times.morning;
    final t = await showTimePicker(
      context: context,
      helpText: evening ? 'Evening reminder' : 'Morning reminder',
      initialTime: TimeOfDay(hour: now ~/ 60, minute: now % 60),
    );
    if (t == null || !mounted) return;
    final minutes = t.hour * 60 + t.minute;
    final (from, until) = m.window;
    if (!timeInWindow(minutes, from, until)) {
      setState(
        () => _error =
            'Pick a time inside your waking hours, ${clockText(from)} to ${clockText(until)}: ${clockText(minutes)} is in the quiet hours.',
      );
      return;
    }
    final s = _settings, at = _now;
    await _apply(
      evening ? s.copyWith(eveningMin: minutes, changed: at) : s.copyWith(morningMin: minutes, changed: at),
      evening ? 'evening time' : 'morning time',
    );
  }

  Future<void> _auto({required bool evening}) async {
    final s = _settings;
    await _apply(
      evening ? s.copyWith(autoEvening: true, changed: _now) : s.copyWith(autoMorning: true, changed: _now),
      evening ? 'evening automatic' : 'morning automatic',
    );
  }

  Future<void> _log(PromptKind kind) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StudyLogScreen(kind: kind, recordingsDir: _dir, phone: widget.phone, now: widget.now),
      ),
    );
    await _load();
  }

  Future<void> _delete() async {
    final yes =
        await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Delete your study data?'),
            content: const Text(
              'Every answer and setting of the study reminders is deleted from this phone, and the reminders stop. '
              'Copies already exported stay where they are. This cannot be undone.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Back')),
              TextButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Delete')),
            ],
          ),
        ) ??
        false;
    if (!yes) return;
    _store.deleteAll();
    await _quiet(() => rearmPrompts(_dir!, _phone, _now));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final m = _model;
    if (m != null) {
      return StudyView(
        model: m,
        error: _error,
        onToggle: (on) => unawaited(_toggle(on)),
        onEvening: () => unawaited(_pick(evening: true)),
        onMorning: () => unawaited(_pick(evening: false)),
        onAutoEvening: () => unawaited(_auto(evening: true)),
        onAutoMorning: () => unawaited(_auto(evening: false)),
        onLogEvening: () => unawaited(_log(PromptKind.studyEvening)),
        onLogMorning: () => unawaited(_log(PromptKind.studyMorning)),
        onInfo: () => showEvidence(context, 'study-timing'),
        onNotifications: () => unawaited(_safe(() => Phone.openSettings('notifications'), false).then((_) => _load())),
        onPhoneSettings: (page) => unawaited(_quiet(() => Phone.openSettings(page))),
        onDelete: () => unawaited(_delete()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Study reminders')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(_loadError == null ? 'Reading your answers…' : 'The study log could not be read: $_loadError'),
      ),
    );
  }
}

/// The one-tap question, with its saving: a tap writes the answer at once (so leaving the page keeps it) and hands
/// the phone the reminders again (an answered one is not rung twice; a "no" drops the next morning's).
class StudyLogScreen extends StatefulWidget {
  const StudyLogScreen({super.key, required this.kind, this.launch, this.recordingsDir, this.phone, this.now});

  /// [PromptKind.studyEvening] or [PromptKind.studyMorning].
  final PromptKind kind;
  final SharpLaunch? launch;
  final String? recordingsDir;
  final SharpPhone? phone;
  final DateTime Function()? now;

  @override
  State<StudyLogScreen> createState() => _StudyLogScreenState();
}

class _StudyLogScreenState extends State<StudyLogScreen> {
  StudyStage _stage = StudyStage.ask;
  StudyAnswer? _saved;
  String? _error;

  DateTime get _now => (widget.now ?? DateTime.now)();

  Future<void> _save(StudyAnswer a) async {
    if (_saved != null) return;
    try {
      final dir = widget.recordingsDir ?? await Phone.recordingsDir();
      if (dir == null) throw StateError("the app's folder is not known");
      StudyStore(studyDirFor(dir)).addAnswer(a);
      if (mounted) {
        setState(() {
          _saved = a;
          _stage = StudyStage.saved;
        });
      }
      try {
        await rearmPrompts(dir, widget.phone ?? ChannelSharpPhone(), _now);
      } catch (_) {
        // no channel (tests, a desktop harness): the answer is saved, the next app start arms the rest
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Not saved: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.launch;
    return StudyLogView(
      kind: widget.kind,
      stage: _stage,
      asked: l == null ? null : (l.shown ?? l.planned),
      saved: _saved,
      error: _error,
      onStudied: (yes) =>
          unawaited(_save(StudyAnswer.evening(at: _now, studied: yes, prompt: l?.planned, shown: l?.shown))),
      onRecall: (r) => unawaited(_save(StudyAnswer.morning(at: _now, recall: r, prompt: l?.planned, shown: l?.shown))),
      onNotYet: () => Navigator.of(context).maybePop(),
      onDone: () => Navigator.of(context).maybePop(),
    );
  }
}
