// "Headband connection" (DECISIONS rows 211-216): opened from the night screen's Headband section between nights.
// The probe of our own connection on the real headband, its plain result, and the switch between BrainBit's SDK
// (the default) and our own connection. Never while a night records or a session holds the headband: the
// headband keeps one connection. The page stays in front while the probe runs and keeps the screen on.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../headband/finder.dart' show loadOwnBle;
import '../headband/own/controller.dart';
import '../headband/own/settings.dart';
import '../headband/own/universal_transport.dart';
import '../phone.dart';
import '../sound/check_in_sound.dart' show SoloudCheckInSound;
import 'export_screen.dart' show exportBlocked;
import 'nearby.dart';
import 'own_ble_view.dart';

/// Why the headband is not free now, or null (the same rule as Export data).
Future<String?> _headbandBusy() async {
  final why = await exportBlocked();
  if (why == null) return null;
  return why.startsWith('A night')
      ? 'A night is recording. Stop it first: the headband keeps one connection.'
      : 'A session is running. Come back after it ends.';
}

class OwnBleScreen extends StatefulWidget {
  const OwnBleScreen({super.key});

  @override
  State<OwnBleScreen> createState() => _OwnBleScreenState();
}

class _OwnBleScreenState extends State<OwnBleScreen> {
  OwnBleController? _c;
  Timer? _tick;
  String? _blocked;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final rec = await Phone.recordingsDir();
      if (rec == null) throw StateError("the app's folder is not known");
      final c = OwnBleController(
        store: OwnBleStore(ownBleDirFor(rec)),
        recordings: Directory(rec),
        transport: UniversalTransport.new,
        sound: SoloudCheckInSound.new,
        before: _before,
      )..load();
      c.addListener(_onChange);
      final blocked = await _headbandBusy();
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() {
        _c = c;
        _blocked = blocked;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Asked right before a probe: the headband must be free and Bluetooth allowed.
  Future<String?> _before() async {
    final busy = await _headbandBusy();
    if (busy != null) return busy;
    try {
      final phone = await Phone.snapshot();
      if (!phone.bluetoothOn) return 'Bluetooth is off. Switch it on, then run the probe.';
      if (!await nearbyAllowed(phone.sdkInt) && !await requestNearby(phone.sdkInt)) {
        return 'The app may not use Bluetooth ("Nearby devices"). Allow it, then run the probe.';
      }
    } on PlatformException catch (e) {
      return 'The phone did not answer: ${e.message ?? e.code}';
    }
    return null;
  }

  void _onChange() {
    final c = _c;
    if (c == null || !mounted) return;
    if (c.busy && _tick == null) {
      _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) setState(() {});
      });
      unawaited(Phone.keepScreenOn(on: true).catchError((_) {}));
    } else if (!c.busy && _tick != null) {
      _tick?.cancel();
      _tick = null;
      unawaited(Phone.keepScreenOn(on: false).catchError((_) {}));
    }
    if (c.step?.cue != null && c.step!.text != null) unawaited(HapticFeedback.mediumImpact());
    setState(() {});
  }

  Future<void> _run() async {
    final c = _c;
    if (c == null) return;
    final blocked = await _headbandBusy();
    if (!mounted) return;
    setState(() => _blocked = blocked);
    if (blocked == null) await c.runProbe();
  }

  Future<void> _tryAnyway() async {
    final c = _c;
    if (c == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use our own connection without a passed probe?'),
        content: const Text(
          'It was only tested on a made-up headband so far. It may record wrong channels or nothing at all. '
          "You can switch back to BrainBit's connection here at any time.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Try anyway')),
        ],
      ),
    );
    if (yes == true) c.setUseOwn(true, anyway: true);
  }

  @override
  void dispose() {
    _tick?.cancel();
    final c = _c;
    if (c != null) {
      c.removeListener(_onChange);
      if (c.busy) unawaited(Phone.keepScreenOn(on: false).catchError((_) {}));
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (_error != null || c == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Headband connection')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error == null ? 'Reading the settings.' : 'The app could not read its folder: $_error'),
        ),
      );
    }
    final s = c.settings, p = s.probe;
    final model = OwnBleViewModel(
      useOwn: s.useOwn,
      triedAnyway: s.triedAnyway,
      signalResist: s.signalResist,
      probeAt: p?.at,
      probePassed: p?.passed ?? false,
      probeWorn: p?.worn ?? false,
      probeLine: p?.line ?? '',
      probeFolder: p?.folder,
      command5: p?.command5 ?? false,
      lines: c.lines,
      needsPairing: c.needsPairing,
      worn: c.worn,
      pairFirst: c.pairFirst,
      stage: c.stage,
      stepText: c.step?.text,
      stepName: c.step?.name,
      secondsLeft: c.secondsLeft,
      fraction: c.fraction,
      blocked: _blocked,
      message: c.message,
    );
    return PopScope(
      canPop: !c.busy, // Back waits for Stop: the probe runs from this page
      child: OwnBleView(
        model: model,
        onRun: _run,
        onReady: c.ready,
        onStop: c.stopProbe,
        onUseOwn: (on) => c.setUseOwn(on),
        onTryAnyway: _tryAnyway,
        onSignalResist: (on) => c.setSignalResist(on),
        onWorn: c.setWorn,
        onPairFirst: c.setPairFirst,
      ),
    );
  }
}

/// The night screen's entry: reads which connection is in use by itself, so the night screen's own code stays
/// as it is.
class OwnBleEntry extends StatefulWidget {
  const OwnBleEntry({super.key});

  @override
  State<OwnBleEntry> createState() => _OwnBleEntryState();
}

class _OwnBleEntryState extends State<OwnBleEntry> {
  bool _useOwn = false;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    final own = await loadOwnBle();
    if (mounted) setState(() => _useOwn = own.settings.useOwn);
  }

  Future<void> _open() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const OwnBleScreen()));
    await _read();
  }

  @override
  Widget build(BuildContext context) => OwnBleEntryView(useOwn: _useOwn, onOpen: _open);
}
