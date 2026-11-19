// "Headband connection" (DECISIONS rows 211-216): opened from the night screen's Headband section between nights.
// The probe of our own connection on the real headband, its plain result, and the switch between BrainBit's SDK
// (the default) and our own connection. Never while a night records or a session holds the headband: the
// headband keeps one connection. The page stays in front while the probe runs and keeps the screen on.
// Above them, the device choice "Headband: BrainBit / DIY board (test)" (DECISIONS rows 360-369), locked the same way.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../headband/diy/settings.dart';
import '../headband/finder.dart' show loadDiyBoard, loadOwnBle;
import '../share/protocol.dart' show lanAddresses, parseLanNets;
import '../headband/own/controller.dart';
import '../headband/own/settings.dart';
import '../headband/own/universal_transport.dart';
import '../phone.dart';
import '../sound/check_in_sound.dart' show SoloudCheckInSound;
import 'export_screen.dart' show exportBlocked;
import 'diy_board_view.dart' show DiyPageModel;
import 'nearby.dart';
import 'own_ble_view.dart';

/// This phone's Wi-Fi address now (the board's UDP_HOST), or null when it has none: Android's own answer first,
/// Dart's interface list when Android has none (DECISIONS row 561).
Future<String?> phoneWifiAddress() async {
  try {
    final mine = parseLanNets((await Phone.wifiNets().timeout(const Duration(seconds: 3))).nets);
    if (mine.isNotEmpty) return mine.first.address.address;
  } catch (_) {}
  try {
    final found = lanAddresses(await NetworkInterface.list(type: InternetAddressType.IPv4));
    return found.isEmpty ? null : found.first.address;
  } catch (_) {
    return null;
  }
}

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
  DiyBoardStore? _diyStore;
  DiyBoardSettings _diy = const DiyBoardSettings();
  String? _address;

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
      final diyStore = DiyBoardStore(diyBoardDirFor(rec));
      final diy = diyStore.load();
      final address = await phoneWifiAddress();
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() {
        _c = c;
        _blocked = blocked;
        _diyStore = diyStore;
        _diy = diy;
        _address = address;
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

  /// The device choice; never while a night records or a session holds the headband.
  Future<void> _setDevice(bool diy) async {
    final blocked = await _headbandBusy();
    final address = await phoneWifiAddress();
    if (!mounted) return;
    setState(() {
      _blocked = blocked;
      _address = address;
    });
    if (blocked != null) return;
    _saveDiy(_diy.copyWith(useDiy: diy));
  }

  void _setNames(List<String> names) => _saveDiy(_diy.copyWith(names: names));

  void _saveDiy(DiyBoardSettings next) {
    try {
      _diyStore?.save(next);
      setState(() => _diy = next);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('The setting could not be saved: $e')));
    }
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
      diy: DiyPageModel(useDiy: _diy.useDiy, names: _diy.names, address: _address),
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
        onDevice: _setDevice,
        onNames: _setNames,
      ),
    );
  }
}

/// The night screen's entry: reads which connection is in use by itself, so the night screen's own code stays
/// as it is.
class OwnBleEntry extends StatefulWidget {
  const OwnBleEntry({super.key, this.onReturn, this.diy});

  /// Back from the page: the device choice may have changed.
  final VoidCallback? onReturn;

  /// The night screen's own reading of the device choice (the line agrees with the block above it); null: read here.
  final bool? diy;

  @override
  State<OwnBleEntry> createState() => _OwnBleEntryState();
}

class _OwnBleEntryState extends State<OwnBleEntry> {
  bool _useOwn = false;
  bool _useDiy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    final own = await loadOwnBle();
    final diy = await loadDiyBoard();
    if (mounted) {
      setState(() {
        _useOwn = own.settings.useOwn;
        _useDiy = diy.settings.useDiy;
      });
    }
  }

  Future<void> _open() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const OwnBleScreen()));
    await _read();
    widget.onReturn?.call();
  }

  @override
  Widget build(BuildContext context) => OwnBleEntryView(useOwn: _useOwn, useDiy: widget.diy ?? _useDiy, onOpen: _open);
}
