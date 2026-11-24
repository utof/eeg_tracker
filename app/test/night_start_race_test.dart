// Start night and the screen's refreshes (integration 14, DECISIONS 620-629): closing Android's notification question
// at Start brings the app back, and the refresh that follows asks "is a night recording?" before the recorder's
// service runs. Acting on that "no" brought the app's own Share on Wi-Fi server back for half a second while the
// recorder's server waited for the port. The screen now acts on a "no night" only when no Start began since the
// refresh asked, and none was under way when it asked.
import 'dart:io';
import 'dart:isolate';

import 'package:eeg_tracker/share/control.dart';
import 'package:eeg_tracker/share/isolate.dart';
import 'package:eeg_tracker/share/protocol.dart';
import 'package:eeg_tracker/ui/night_screen.dart' show NightStartGate;
import 'package:flutter_test/flutter_test.dart';

Future<void> _fakeServer(List<Object?> args) async {
  (args[0]! as SendPort).send(['up', <String>['192.168.1.23', '127.0.0.1'], args[3]]);
  await Future<void>.delayed(const Duration(hours: 1));
}

void main() {
  test('the gate: a refresh begun before or during a Start is not trusted, one begun after it is', () {
    final g = NightStartGate();
    final before = g.token;
    expect(g.trusts(before), isTrue);
    g.begin();
    expect(g.starting, isTrue);
    expect(g.trusts(before), isFalse, reason: 'asked before the Start began');
    final during = g.token;
    expect(g.trusts(during), isFalse);
    g.end();
    expect(g.trusts(during), isFalse, reason: 'asked while the Start ran: its answer may predate the service');
    expect(g.trusts(before), isFalse);
    final after = g.token;
    expect(g.trusts(after), isTrue);
  });

  group('the share server around a Start', () {
    late Directory files;
    late ShareConfig saved;
    late ShareControl share;
    setUp(() async {
      files = Directory.systemTemp.createTempSync('night_start_race');
      saved = const ShareConfig();
      share = ShareControl(
        load: () async => saved,
        save: (x) async => saved = x,
        sendToRecorder: (_) {},
        keepScreenOn: (_) async {},
        clock: () => DateTime(2099, 11, 22, 22, 5),
        host: (dir, onChange, wifiLock) =>
            ShareHost(filesDir: dir, onLog: (_) {}, onChange: onChange, entry: _fakeServer, wifiLock: wifiLock),
      );
      await share.sync(night: false, filesDir: files.path);
      await share.setOn(true);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(share.status.up, isTrue);
    });
    tearDown(() async {
      await share.setOn(false);
      share.dispose();
      files.deleteSync(recursive: true);
    });

    /// The screen's refresh as it ends: Share on Wi-Fi follows the "is a night recording?" it asked at [token],
    /// unless the gate says not to act on a "no".
    Future<void> refreshEnds(NightStartGate gate, int token, {required bool running}) async {
      if (running || gate.trusts(token)) await share.sync(night: running, filesDir: files.path);
    }

    test('the refresh from the closed notification question does not bring the server back', () async {
      final gate = NightStartGate();
      gate.begin(); // Start night tapped
      final resumed = gate.token; // the notification question closes: the app is back, a refresh asks
      await share.beforeNight(); // the Start lets go of the port before the recorder's service starts
      await refreshEnds(gate, resumed, running: false); // "no night": the service is not up yet
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(share.status.up, isFalse, reason: 'the port stays free for the recorder');
      gate.end();
      await refreshEnds(gate, resumed, running: false); // the same refresh, ending only after the Start
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(share.status.up, isFalse);
      await refreshEnds(gate, gate.token, running: true); // the refresh after the Start: the night records
      expect(share.status.up, isFalse);
    });

    test('a Start that failed: the next refresh serves again', () async {
      final gate = NightStartGate()..begin();
      await share.beforeNight();
      gate.end(); // the recorder did not start
      await refreshEnds(gate, gate.token, running: false);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(share.status.up, isTrue);
    });
  });
}
