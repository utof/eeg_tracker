// The sharp-hours page (ROADMAP "Sharp-hours log", the assistant's proposal; DECISIONS rows 280-289): reads the
// files and the phone's state, saves the switch, the window and the count, hands the phone the moments ahead, and
// lays it all out with sharp_hours_view.dart. Reached from the Trends page.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../phone.dart';
import '../sharp/hours.dart';
import '../sharp/page.dart';
import '../sharp/prompts.dart';
import '../sharp/schedule.dart';
import '../sharp/store.dart';
import '../study/arm.dart' show rearmPrompts;
import '../wearer/wearer.dart' show ownNightReports;
import 'evidence_sheet.dart';
import 'sharp_hours_view.dart';
import 'sharp_rating_screen.dart';

class SharpHoursScreen extends StatefulWidget {
  const SharpHoursScreen({super.key, this.recordingsDir, this.phone, this.now});
  final String? recordingsDir;
  final SharpPhone? phone;
  final DateTime Function()? now;

  @override
  State<SharpHoursScreen> createState() => _SharpHoursScreenState();
}

class _SharpHoursScreenState extends State<SharpHoursScreen> {
  late final SharpPhone _phone = widget.phone ?? ChannelSharpPhone();
  SharpPageModel? _model;
  String? _dir, _error, _loadError;
  SharpAxis _axis = SharpAxis.clock;
  final String _seed = SharpStore.newSeed();

  DateTime get _now => (widget.now ?? DateTime.now)();
  SharpStore get _store => SharpStore(sharpDirFor(_dir!));

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
      final notifications = await _safe(_phone.notificationsOn, true);
      final xiaomi = await _safe(() async => (await Phone.snapshot()).xiaomiOs != null, false);
      // the files are read after every wait, so a slow reload never shows older settings than a later change
      final store = _store;
      final m = buildSharpPage(
        saved: store.settings(),
        ratings: store.ratings(),
        reactions: store.reactions(),
        events: store.promptEvents(),
        // the wake-ups and sleep pressure come from the owner's own nights (not one someone else wore, DECISIONS 377)
        reports: ownNightReports(_dir!),
        now: _now,
        seed: _seed,
        notificationsOn: notifications,
        xiaomi: xiaomi,
      );
      if (mounted) setState(() => _model = m);
    } catch (e) {
      if (mounted) setState(() => _loadError = '$e');
    }
  }

  /// The settings as saved now (the page's model can be a reload behind), or what switching on would use.
  SharpSettings? get _settings => _dir == null ? null : (_store.settings() ?? _model?.settings);

  /// Saves [s] (and logs [event]), hands the phone the moments ahead, and reads everything again.
  Future<void> _apply(SharpSettings s, String event) async {
    try {
      _store
        ..saveSettings(s)
        ..logEvent(_now, event, {'per_day': s.perDay, 'awake_from': clockText(s.fromMin), 'awake_until': clockText(s.untilMin)});
      await rearmPrompts(_dir!, _phone, _now);
      _error = null;
    } on Exception catch (e) {
      _error = 'The phone did not take the questions: $e';
    }
    await _load();
  }

  Future<void> _toggle(bool on) async {
    if (_settings == null) return;
    if (on) {
      // Android 13+: the questions are notifications; asked once, here
      await _safe(() => Permission.notification.request(), PermissionStatus.denied);
    }
    final s = _settings!, now = _now;
    await _apply(s.copyWith(on: on, firstOn: s.firstOn ?? (on ? now : null), changed: now), on ? 'on' : 'off');
  }

  Future<void> _window() async {
    final s = _settings;
    if (s == null) return;
    final from = await showTimePicker(
      context: context,
      helpText: 'Awake from',
      initialTime: TimeOfDay(hour: s.fromMin ~/ 60, minute: s.fromMin % 60),
    );
    if (from == null || !mounted) return;
    final until = await showTimePicker(
      context: context,
      helpText: 'Until',
      initialTime: TimeOfDay(hour: s.untilMin ~/ 60, minute: s.untilMin % 60),
    );
    if (until == null || !mounted) return;
    final f = from.hour * 60 + from.minute, u = until.hour * 60 + until.minute;
    if (!windowOk(f, u)) {
      setState(() => _error = 'Keep at least 4 hours awake and 4 quiet hours: ${clockText(f)} to ${clockText(u)} does not.');
      return;
    }
    await _apply(_settings!.copyWith(fromMin: f, untilMin: u, changed: _now), 'window');
  }

  Future<void> _perDay(int n) async {
    final s = _settings;
    if (s == null || n == s.perDay) return;
    await _apply(s.copyWith(perDay: n, changed: _now), 'per day');
  }

  Future<void> _rate() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SharpRatingScreen(recordingsDir: _dir)));
    await _load();
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Delete your sharp-hours data?'),
            content: const Text(
              'Every answer, reaction test and setting of the sharp-hours log is deleted from this phone, and the '
              'questions stop. Copies already exported stay where they are. This cannot be undone.',
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
      return SharpHoursView(
        model: m,
        axis: _axis,
        error: _error,
        onAxis: (a) => setState(() => _axis = a),
        onToggle: (on) => unawaited(_toggle(on)),
        onWindow: () => unawaited(_window()),
        onPerDay: (n) => unawaited(_perDay(n)),
        onRate: () => unawaited(_rate()),
        onInfo: () => showEvidence(context, 'sharp-hours'),
        onNotifications: () => unawaited(_safe(() => Phone.openSettings('notifications'), false).then((_) => _load())),
        onPhoneSettings: (page) => unawaited(_quiet(() => Phone.openSettings(page))),
        onSound: () => unawaited(_quiet(_phone.openChannelSettings)),
        onDelete: () => unawaited(_delete()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Sharp hours')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(_loadError == null ? 'Reading your answers…' : 'The sharp-hours log could not be read: $_loadError'),
      ),
    );
  }
}
