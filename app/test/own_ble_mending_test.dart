// Our own connection's headband object while it mends a drop (lib/headband/own/own_headband.dart), with connection
// tries that take a while, as on a phone: what it writes into the night's log when the signal is stopped or started
// in the middle of a drop.
import 'package:eeg_tracker/headband/own/own_headband.dart';
import 'package:eeg_tracker/headband/own/settings.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:flutter_test/flutter_test.dart';

import 'own_ble/fake_headband.dart';
import 'own_ble/slow_connect.dart';

const _ms = Duration(milliseconds: 1);

Future<void> waitFor(bool Function() done, {Duration max = const Duration(seconds: 8)}) async {
  final t0 = DateTime.now();
  while (!done()) {
    if (DateTime.now().difference(t0) > max) fail('timed out waiting');
    await Future<void>.delayed(_ms * 5);
  }
}

void main() {
  late FakeHeadband hb;
  late SlowConnect slow;
  late OwnHeadband band;
  late List<String> notes;

  late OwnFinder finder;

  /// A headband object reached directly; its notes go to [notes]. Its tries take 200 ms while the headband is away.
  Future<void> connect({Duration healFor = const Duration(seconds: 3)}) async {
    hb = FakeHeadband();
    slow = SlowConnect(hb, whileAway: _ms * 200);
    finder = OwnFinder(
      transport: slow,
      settings: const OwnBleSettings(address: fakeAddress, name: 'BB Black'),
      timing: OwnTiming(
        callTimeout: _ms * 300,
        healFor: healFor,
        stall: _ms * 150,
        backoffs: [_ms * 10],
        contactFor: _ms * 30,
        notesEvery: const Duration(seconds: 10),
        poll: _ms * 5,
        stopWait: _ms * 20,
      ),
    );
    band = await finder.connectDirect(const BandId(name: 'BB Black', address: fakeAddress)) as OwnHeadband;
    notes = [];
    band.notes.listen((n) {
      if (n.line != null) notes.add(n.line!);
    });
  }

  tearDown(() => band.disconnectAndDispose());

  test('a try that fails after the signal was stopped does not claim to hand over or to try again', () async {
    await connect(healFor: _ms * 100);
    await band.startSignal();
    await waitFor(() => hb.packets > 20);
    hb.dropFor = const Duration(seconds: 2);
    hb.drop();
    await waitFor(() => slow.inFlight == 1); // the object's reconnect try is under way
    await band.stopSignal(); // waits 20 ms; the try goes on by itself
    final from = notes.length;
    await waitFor(() => slow.inFlight == 0);
    await Future<void>.delayed(_ms * 50);
    final after = notes.sublist(from);
    expect(after.where((l) => l.contains('handing over') || l.contains('trying again')), isEmpty, reason: '$after');
    expect(after, contains(contains('no further tries: the signal was stopped')));
    expect(await band.isInRange(), isTrue, reason: 'stopped, not given up');
  });

  test('a reconnect that completes while the signal is being stopped is said, and the next drop is timed alone',
      () async {
    await connect();
    await band.startSignal();
    await waitFor(() => hb.packets > 20);
    hb.dropFor = _ms * 50;
    hb.drop();
    await waitFor(() => slow.inFlight == 1); // the headband is back before this try ends
    await band.stopSignal();
    await waitFor(() => slow.inFlight == 0 && hb.link != null);
    await Future<void>.delayed(_ms * 50);
    expect(notes, contains(matches(RegExp(r'^reconnected after 0\.\d s away'))), reason: '$notes');

    await band.startSignal(); // on the link the stopped try opened
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final packets = hb.packets;
    hb.drop();
    await waitFor(() => hb.packets > packets + 20);
    final last = notes.lastWhere((l) => l.startsWith('reconnected after'));
    expect(last, matches(RegExp(r'^reconnected after 0\.\d s away')), reason: 'timed from the first drop: $notes');
  });

  test('a signal started on a link that dropped meanwhile says so, not "0.0 s away"', () async {
    await connect();
    hb.dropFor = _ms * 50;
    hb.drop(); // no signal yet (as during the contact check)
    await Future<void>.delayed(_ms * 100);
    await band.startSignal();
    await waitFor(() => notes.any((l) => l.startsWith('reconnected')));
    final line = notes.firstWhere((l) => l.startsWith('reconnected'));
    expect(line, isNot(contains('0.0 s away')));
    expect(line, startsWith('reconnected (try 1) after the link closed while the signal was off'));
  });

  group('one connection try at a time (a let-go object\'s try cannot be cancelled)', () {
    /// The recorder gives a stalled run up while the object is still mending: it lets the object go (its try goes on
    /// by itself) and reaches the same headband with a new object.
    Future<void> replaceWhileATryRuns() async {
      await band.startSignal();
      await waitFor(() => hb.packets > 20);
      hb.drop();
      await waitFor(() => slow.inFlight == 1);
      await band.disconnectAndDispose();
      band = await finder.connectDirect(const BandId(name: 'BB Black', address: fakeAddress)) as OwnHeadband;
    }

    test('the headband stays away: the new object\'s try starts after the old one\'s ended', () async {
      await connect();
      hb.dropFor = _ms * 600;
      await expectLater(replaceWhileATryRuns(), throwsA(anything)); // still away: the new try fails too
      expect(slow.most, 1, reason: 'two tries for one address at once');
    });

    test('the old try connects late: the new one waits until that link is let go', () async {
      await connect();
      hb.dropFor = _ms * 100; // back before the old try ends
      await replaceWhileATryRuns();
      expect(slow.most, 1, reason: 'a try started while the old object still held a link');
      expect(hb.link, isNotNull);
      expect(await band.isInRange(), isTrue);
    });
  });
}
