// The switch (DECISIONS row 211): every screen and the night recorder ask this one finder for the headband; it
// hands the work to BrainBit's SDK (the default) or to our own connection (headband/own/), as the setting
// "Use our own connection (test)" says (files/own-ble/settings.json). The choice is made when the headband is
// first asked for and holds for this finder's life: one session, or one run of the recorder's service.
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../phone.dart';
import '../recorder/brainbit.dart' show SdkFinder;
import '../recorder/headband.dart';
import 'own/own_headband.dart';
import 'own/settings.dart';
import 'own/universal_transport.dart';

/// The settings of our own connection for this app, or the defaults (SDK) when they cannot be read. Works in the
/// screen's engine and in the recorder service's (both have the app's phone channel).
Future<({OwnBleSettings settings, OwnBleStore? store, Directory? recordings})> loadOwnBle() async {
  try {
    final rec = await Phone.recordingsDir();
    if (rec == null) return (settings: const OwnBleSettings(), store: null, recordings: null);
    final store = OwnBleStore(ownBleDirFor(rec));
    return (settings: store.load(), store: store, recordings: Directory(rec));
  } catch (e) {
    debugPrint("own BLE: the settings could not be read ($e); BrainBit's SDK is used");
    return (settings: const OwnBleSettings(), store: null, recordings: null);
  }
}

/// Our own connection as the app uses it: the saved address, else the one in the newest recorder log (the
/// headband the SDK recorded with), else a scan by name; every headband reached is remembered.
OwnFinder ownFinderFor(OwnBleSettings settings, OwnBleStore? store, Directory? recordings) {
  var s = settings;
  if (s.address == null && recordings != null) {
    final known = knownAddress(recordings);
    if (known != null) s = s.copyWith(address: known);
  }
  return OwnFinder(transport: UniversalTransport(), settings: s, remember: store?.remember);
}

class BrainBitFinder implements HeadbandFinder {
  BrainBitFinder({Future<HeadbandFinder> Function()? pick}) : _pickWith = pick ?? _default;

  final Future<HeadbandFinder> Function() _pickWith;
  Future<HeadbandFinder>? _picked;
  HeadbandFinder? _finder;

  /// True once our own connection was chosen (null before the first use).
  bool? get usesOwn => _finder == null ? null : _finder is OwnFinder;

  static Future<HeadbandFinder> _default() async {
    final own = await loadOwnBle();
    return choose(own.settings, own.store, own.recordings);
  }

  /// BrainBit's SDK unless the switch is on.
  static HeadbandFinder choose(OwnBleSettings settings, OwnBleStore? store, Directory? recordings) =>
      settings.useOwn ? ownFinderFor(settings, store, recordings) : SdkFinder();

  Future<HeadbandFinder> _pick() => _picked ??= _pickWith().then((f) => _finder = f);

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async =>
      (await _pick()).find(scanFor, onFound: onFound);

  @override
  Future<Headband> connectDirect(BandId id) async => (await _pick()).connectDirect(id);

  /// End of a session or a night. [anyLost]: a headband was left out of range (the SDK's scanner is then left
  /// alone; our own connection has nothing to free).
  void dispose({required bool anyLost}) {
    final f = _finder;
    if (f is SdkFinder) f.dispose(anyLost: anyLost);
    if (f is OwnFinder) f.dispose();
    _picked = null;
    _finder = null;
  }
}
