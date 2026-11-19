// A finder and a headband the test answers by hand, for Stop and Start in the middle of a session's start
// (review 2026-11-19, findings 1 and 9): every search waits until the test answers it, and a headband's stream start
// waits for the test's gate.
import 'dart:async';

import 'package:eeg_tracker/recorder/chunk_writer.dart' show Sample;
import 'package:eeg_tracker/recorder/headband.dart';

/// Every search waits until the test answers it: `finds[i].complete(band)` (or null: none found).
class GateFinder implements HeadbandFinder {
  final List<Completer<Headband?>> finds = [];

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    final c = Completer<Headband?>();
    finds.add(c);
    final band = await c.future;
    if (band != null) onFound?.call(band.name, -60);
    return band;
  }

  @override
  Future<Headband> connectDirect(BandId id) async => throw StateError('out of range');
}

/// [inner], whose stream start waits for [gate] (the SDK slow to answer the start command). The command then succeeds;
/// a headband disconnected meanwhile streams nothing.
class SlowStart implements Headband {
  SlowStart(this.inner);
  final Headband inner;
  final Completer<void> gate = Completer<void>();

  /// The start command was sent (and waits for [gate]).
  bool asked = false;
  bool disconnected = false;

  @override
  Future<void> startSignal() async {
    asked = true;
    await gate.future;
    if (!disconnected) await inner.startSignal();
  }

  @override
  Future<void> disconnectAndDispose() {
    disconnected = true;
    return inner.disconnectAndDispose();
  }

  @override
  String get name => inner.name;
  @override
  String get address => inner.address;
  @override
  String get serial => inner.serial;
  @override
  BandId get id => inner.id;
  @override
  int? get rssi => inner.rssi;
  @override
  Stream<List<Sample>> get signal => inner.signal;
  @override
  Stream<Map<String, double>> get resistance => inner.resistance;
  @override
  Stream<bool> get rangeChanges => inner.rangeChanges;
  @override
  Future<void> stopSignal() => inner.stopSignal();
  @override
  Future<void> startResist() => inner.startResist();
  @override
  Future<void> stopResist() => inner.stopResist();
  @override
  Future<bool> isInRange() => inner.isInRange();
  @override
  Future<int> battery() => inner.battery();
}
