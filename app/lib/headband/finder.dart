// The switch (DECISIONS row 211): every screen and the night recorder ask this one finder for the headband; it
// hands the work to BrainBit's SDK (the default) or to our own connection (headband/own/), as the setting
// "Use our own connection (test)" says (files/own-ble/settings.json). The choice is made when the headband is
// first asked for and holds for this finder's life: one session, or one run of the recorder's service.
// With "Headband: DIY board (test)" on (files/diy-board/settings.json, DECISIONS rows 360-369) every session gets a
// refusal in plain words (they read BrainBit's O1 O2 T3 T4); only the recorder's service records the board, with a
// finder of its own (diy/night.dart).
// Only in a replay build (`--dart-define=EEG_REPLAY=true`, never the owner's) a plan in `files/replay/` replaces the
// headband with a replayed recording (replay.dart, DECISIONS 730-739); a normal build has no such path at all.
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../phone.dart';
import '../recorder/brainbit.dart' show SdkFinder;
import '../recorder/headband.dart';
import 'connection.dart';
import 'diy/board.dart' show DiyFinder;
import 'diy/settings.dart';
import 'own/own_headband.dart';
import 'replay.dart' show ReplayFinder, replayBuild, replayFinderFor;
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

/// The device choice for this app, or the default (the BrainBit) when it cannot be read. Works in the screen's engine
/// and in the recorder service's.
Future<({DiyBoardSettings settings, DiyBoardStore? store})> loadDiyBoard() async {
  try {
    final rec = await Phone.recordingsDir();
    if (rec == null) return (settings: const DiyBoardSettings(), store: null);
    final store = DiyBoardStore(diyBoardDirFor(rec));
    return (settings: store.load(), store: store);
  } catch (_) {
    return (settings: const DiyBoardSettings(), store: null);
  }
}

/// Why a session cannot use the DIY board.
class NotForDiyBoard implements Exception {
  const NotForDiyBoard();

  @override
  String toString() =>
      "The DIY board (test) is chosen as the headband. This needs the BrainBit: it reads O1 O2 T3 T4. Switch back to "
      'BrainBit on the Headband connection page.';
}

/// What every session's finder is while the DIY board is chosen: a refusal, never a scan.
class DiyRefusal implements HeadbandFinder {
  const DiyRefusal();

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async =>
      throw const NotForDiyBoard();

  @override
  Future<Headband> connectDirect(BandId id) async => throw const NotForDiyBoard();
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

class BrainBitFinder implements HeadbandFinder, WaitingFinder {
  /// [recorder]: the recorder's service asks (only it may record a replay whose layout is not the BrainBit's).
  /// In the screen's engine a finder made without [pick] is a door to the one connection (headband/connection.dart,
  /// DECISIONS 855): its headbands are handles to the connection every screen shares, and [dispose] leaves that
  /// connection to its owner. [own]: a finder of its own all the same (the owner's real one).
  BrainBitFinder({Future<HeadbandFinder> Function()? pick, bool recorder = false, bool own = false})
    : _pickWith = pick ?? (() => _default(recorder: recorder)),
      _shared = pick == null && !recorder && !own ? HeadbandConnection.shared : null;

  final Future<HeadbandFinder> Function() _pickWith;

  /// The one connection's owner, when this finder is a door to it.
  final HeadbandConnection? _shared;
  Future<HeadbandFinder>? _picked;
  HeadbandFinder? _finder;

  /// Called before a finder's first search in this engine: the screen's engine makes the headband watcher let go of a
  /// headband it holds while asking (lib/auto, DECISIONS 600); null in the recorder's and the watcher's own engines.
  static Future<void> Function()? beforeUse;

  /// True once our own connection was chosen (null before the first use).
  bool? get usesOwn => _finder == null ? null : _finder is OwnFinder;

  /// True once the DIY board's finder was chosen (only the recorder's service picks it; null before the first use).
  bool? get usesDiy => _finder == null ? null : _finder is DiyFinder;

  static Future<HeadbandFinder> _default({bool recorder = false}) async {
    if (replayBuild) {
      final rec = await Phone.recordingsDir();
      final replay = rec == null ? null : replayFinderFor(rec, forSessions: !recorder);
      if (replay != null) return replay;
    }
    final diy = await loadDiyBoard();
    final own = await loadOwnBle();
    return chooseFor(own.settings, own.store, own.recordings, diy.settings);
  }

  /// BrainBit's SDK unless the switch is on.
  static HeadbandFinder choose(OwnBleSettings settings, OwnBleStore? store, Directory? recordings) =>
      settings.useOwn ? ownFinderFor(settings, store, recordings) : SdkFinder();

  /// A session's finder: a refusal while the DIY board is chosen, else [choose].
  static HeadbandFinder chooseFor(OwnBleSettings settings, OwnBleStore? store, Directory? recordings, DiyBoardSettings diy) =>
      diy.useDiy ? const DiyRefusal() : choose(settings, store, recordings);

  Future<HeadbandFinder> _pick() => _picked ??= () async {
    final shared = _shared;
    if (shared != null) return _finder = shared.finder; // the owner's real finder asks the watcher to let go
    try {
      await beforeUse?.call();
    } catch (_) {}
    return _finder = await _pickWith();
  }();

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async =>
      (await _pick()).find(scanFor, onFound: onFound);

  @override
  Future<Headband> connectDirect(BandId id) async => (await _pick()).connectDirect(id);

  /// A waiting connect when the connection in use has one (our own connection); null with BrainBit's SDK, the DIY
  /// board and a replay.
  @override
  Future<WaitingConnect?> waitFor(BandId id) async {
    final f = await _pick();
    return f is WaitingFinder ? (f as WaitingFinder).waitFor(id) : null;
  }

  /// End of a session or a night. [anyLost]: a headband was left out of range (the SDK's scanner is then left
  /// alone; our own connection has nothing to free).
  void dispose({required bool anyLost}) {
    final f = _finder;
    if (f is SdkFinder) f.dispose(anyLost: anyLost);
    if (f is OwnFinder) f.dispose();
    if (f is DiyFinder) f.dispose();
    if (replayBuild && f is ReplayFinder) f.dispose();
    _picked = null;
    _finder = null;
  }
}
