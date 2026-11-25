// "When I put the headband on" (ROADMAP row 39, DECISIONS 600-609): loads and saves the choices, re-arms the bedtime
// checks after a change, has Android watch for the headband (its companion feature: not the laptop's pairing), and runs
// a check on request. Layout in auto_start_view.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../auto/bedtime.dart';
import '../auto/channel.dart';
import '../auto/log.dart';
import '../auto/store.dart';
import '../phone.dart';
import 'auto_start_view.dart';
import 'evidence_sheet.dart';

/// The kinds whose "start it automatically?" offer has not been answered, while they still ask.
Set<WearKind> openOffers(AutoLog log, AutoSettings s) {
  final open = <WearKind>{};
  for (final e in log.events()) {
    final k = WearKind.fromWire(e['kind']);
    if (k == null) continue;
    if (e['event'] == 'offer') open.add(k);
    if (e['event'] == 'offer_answer') open.remove(k);
  }
  return {
    for (final k in open)
      if (s.choice(k) == AutoChoice.ask) k,
  };
}

class AutoStartScreen extends StatefulWidget {
  const AutoStartScreen({super.key, this.recordings, this.watch});

  /// For tests: the recordings folder and the phone's answers; null: the phone's own.
  final String? recordings;
  final Future<WatchStatus> Function()? watch;

  @override
  State<AutoStartScreen> createState() => _AutoStartScreenState();
}

class _AutoStartScreenState extends State<AutoStartScreen> {
  String? _rec;
  AutoStore? _store;
  AutoStartModel _model = const AutoStartModel();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({String? message}) async {
    String? rec = widget.recordings;
    if (rec == null) {
      try {
        rec = await Phone.recordingsDir();
      } catch (_) {
        rec = null;
      }
    }
    final status = await (widget.watch ?? AutoChannel.status)();
    if (!mounted) return;
    if (rec == null) {
      setState(() => _model = AutoStartModel(status: status, error: 'The app\'s folder is not known yet, so nothing can be saved.'));
      return;
    }
    final store = _store = AutoStore(autoDirFor(rec));
    _rec = rec;
    final s = store.settings();
    final log = AutoLog(store.dir);
    setState(
      () => _model = AutoStartModel(
        settings: s,
        usual: usualNight(recordedNights(Directory(rec!), DateTime.now()), s),
        status: status,
        stats: log.stats(),
        offers: openOffers(log, s),
        message: message,
      ),
    );
  }

  /// Saves [s], arms the bedtime checks it implies, and shows it.
  Future<void> _save(AutoSettings s, {String? message}) async {
    final store = _store, rec = _rec;
    if (store == null || rec == null) return;
    try {
      store.saveSettings(s);
    } catch (e) {
      setState(() => _model = AutoStartModel(settings: _model.settings, usual: _model.usual, status: _model.status, error: 'Not saved: $e'));
      return;
    }
    final now = DateTime.now();
    await AutoChannel.armBedtime(s.allOff ? const [] : bedtimeChecks(usualNight(recordedNights(Directory(rec), now), s), now));
    await _load(message: message);
  }

  Future<void> _offer(WearKind k, bool accept) async {
    final store = _store;
    if (store == null) return;
    AutoLog(store.dir).add(DateTime.now(), 'offer_answer', {'kind': k.wire, 'accept': accept, 'from': 'settings'});
    await _save(accept ? store.settings().withChoice(k, AutoChoice.start) : store.settings());
  }

  Future<void> _bedtime() async {
    final s = _model.settings, w = _model.usual;
    TimeOfDay tod(int m) => TimeOfDay(hour: m ~/ 60, minute: m % 60);
    final bed = await showTimePicker(context: context, initialTime: tod(w.bedMin), helpText: 'Your usual bedtime');
    if (bed == null || !mounted) return;
    final wake = await showTimePicker(context: context, initialTime: tod(w.wakeMin), helpText: 'Your usual wake-up');
    if (wake == null) return;
    await _save(s.withBedtime(bed.hour * 60 + bed.minute, wake.hour * 60 + wake.minute));
  }

  Future<void> _pair() async {
    final err = await AutoChannel.pair();
    await _load(message: err == null ? 'Android now watches for the headband and tells the app when it is near.' : null);
    if (err != null && mounted) {
      setState(() => _model = AutoStartModel(
        settings: _model.settings,
        usual: _model.usual,
        status: _model.status,
        stats: _model.stats,
        offers: _model.offers,
        error: 'Android could not start watching for the headband: $err',
      ));
    }
  }

  Future<void> _forget() async {
    await AutoChannel.forget();
    await _load(message: 'Android no longer watches for the headband. The app checks when you open it and in the bedtime window.');
  }

  Future<void> _checkNow() async {
    await AutoChannel.requestCheck('now');
    await _load(message: 'Checking. If the headband is on, a notification asks (or it starts, as set above).');
  }

  @override
  Widget build(BuildContext context) => AutoStartView(
    model: _model,
    onChoice: (k, c) => unawaited(_save(_model.settings.withChoice(k, c))),
    onChime: (on) => unawaited(_save(_model.settings.withChime(on))),
    onBedtime: () => unawaited(_bedtime()),
    onUseNights: () => unawaited(_save(_model.settings.withBedtime(null, null))),
    onPair: () => unawaited(_pair()),
    onForget: () => unawaited(_forget()),
    onCheckNow: () => unawaited(_checkNow()),
    onOffer: (k, accept) => unawaited(_offer(k, accept)),
    onInfo: () => showEvidence(context, 'auto-start'),
  );
}
