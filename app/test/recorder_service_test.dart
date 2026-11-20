// The recorder service's task handler (lib/recorder/recorder_service.dart) between the screen's messages and the
// night recorder: the platform channels it uses (the app's phone channel, the plugin's methods, shared preferences)
// are answered here; the headband is a finder that never finds one. Share on Wi-Fi runs for real (isolate, socket).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/recorder_service.dart';
import 'package:eeg_tracker/share/protocol.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';

const token = 'abcdefghjkmn';

class NoBand implements HeadbandFinder {
  int finds = 0;

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    finds++;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return null;
  }

  @override
  Future<Headband> connectDirect(BandId id) async => throw StateError('Sensor not founded');
}

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

/// Whether something listens on [port] of this machine's loopback.
Future<bool> listening(int port) async {
  try {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 1));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> until(bool Function() ok, {Duration within = const Duration(seconds: 15)}) async {
  final sw = Stopwatch()..start();
  while (!ok() && sw.elapsed < within) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory files;
  late Map<String, Object> prefs;
  late Completer<void> dirAnswer;
  late List<Object?> toMain;
  late List<Map<Object?, Object?>> locks;
  late int wifiReads;

  setUp(() {
    files = Directory.systemTemp.createTempSync('recorder_service_test');
    Directory('${files.path}/recordings').createSync();
    prefs = {};
    dirAnswer = Completer<void>()..complete();
    toMain = [];
    locks = [];
    wifiReads = 0;
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/shared_preferences'), (call) async {
      final args = call.arguments is Map ? call.arguments as Map : const <Object?, Object?>{};
      switch (call.method) {
        case 'getAll':
        case 'getAllWithPrefix':
        case 'getAllWithParameters':
          final prefix = args['prefix'] as String? ?? '';
          return {
            for (final e in prefs.entries)
              if (e.key.startsWith(prefix)) e.key: e.value,
          };
        case 'remove':
          prefs.remove(args['key']);
          return true;
        default:
          if (call.method.startsWith('set')) {
            prefs[args['key'] as String] = args['value'] as Object;
            return true;
          }
          return true;
      }
    });
    messenger.setMockMethodCallHandler(const MethodChannel('eeg_tracker/phone'), (call) async {
      if (call.method == 'recordingsDir') {
        await dirAnswer.future;
        return '${files.path}/recordings';
      }
      if (call.method == 'wifiLock') locks.add(call.arguments as Map<Object?, Object?>);
      if (call.method == 'wifiState') {
        wifiReads++;
        return {'enabled': true, 'connected': true, 'route': 'wifi', 'lock': locks.lastOrNull?['on'] == true};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_foreground_task/methods'), (_) async => null);
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.addTaskDataCallback(toMain.add);
  });

  tearDown(() {
    FlutterForegroundTask.removeTaskDataCallback(toMain.add);
    files.deleteSync(recursive: true);
  });

  RecorderTaskHandler handler(NoBand band) =>
      RecorderTaskHandler(finder: () => band, cues: (_, _) => (_) => null, wifiEvery: const Duration(milliseconds: 50));

  Map<String, Object?> share(ShareConfig c) => {'kind': 'share', 'config': c.toJson()};

  test('Stop that arrives while the service is still starting ends it: no recorder starts afterwards', () async {
    dirAnswer = Completer<void>();
    final band = NoBand();
    final h = handler(band);
    final starting = h.onStart(DateTime.now(), TaskStarter.developer);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    h.onReceiveData(stopCommand);
    await until(() => toMain.any((m) => m is Map && m['kind'] == 'stopped'));
    dirAnswer.complete();
    await starting;
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(toMain.where((m) => m is Map && m['kind'] == 'stopped'), hasLength(1));
    expect(band.finds, 0, reason: 'a night recorder started after Stop');
    expect((await loadNight()).active, isFalse);
    await h.onDestroy(DateTime.now(), false);
  });

  test('Lights off sent while the service is still starting is kept for the night, not dropped', () async {
    dirAnswer = Completer<void>();
    final h = handler(NoBand());
    final starting = h.onStart(DateTime.now(), TaskStarter.developer);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final sent = DateTime.now().millisecondsSinceEpoch;
    h.onReceiveData(lightsOffCommand);
    dirAnswer.complete();
    await starting;
    var saved = await loadNight();
    for (var i = 0; i < 100 && saved.lightsOffMs == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      saved = await loadNight();
    }
    expect(saved.active, isTrue);
    expect(saved.lightsOffMs, inInclusiveRange(sent, sent + 1000));
    await h.onDestroy(DateTime.now(), false);
  });

  test('a night the headband watcher started makes no sound cues, neither the lucid nor the memory cues', () async {
    // The night's one cue factory is the one-kind-a-night choice of the lucid and the memory cues (DECISIONS 507);
    // automatic means recording and silent analysis only (DECISIONS 604), so neither kind may be made.
    expect(RecorderTaskHandler().cues, nightCuesWith);
    final made = <String>[];
    RecorderTaskHandler cueing() => RecorderTaskHandler(
      finder: NoBand.new,
      cues: (dir, _) {
        made.add(dir);
        return (_) => null;
      },
    );
    // the watcher's start keeps its lines for the night's log under this key (startRecorderService's autoNotes)
    await FlutterForegroundTask.saveData(key: 'autoStart', value: jsonEncode(['started automatically: test']));
    final auto = cueing();
    await auto.onStart(DateTime.now(), TaskStarter.developer);
    expect(made, isEmpty, reason: 'sound cues were made for a night the watcher started');
    await auto.onDestroy(DateTime.now(), false);

    // a start by hand removes the key: tonight's cues are made as before
    await FlutterForegroundTask.removeData(key: 'autoStart');
    final byHand = cueing();
    await byHand.onStart(DateTime.now(), TaskStarter.developer);
    expect(made, ['${files.path}/recordings']);
    await byHand.onDestroy(DateTime.now(), false);
  });

  test('a wedged SDK: the native restart ends the process; Dart exits only if it is still alive 2 s later', () async {
    // PhoneChannel.kt arms the restart alarm and answers at once; its killProcess comes 300 ms later.
    final exits = <int>[];
    final sw = Stopwatch()..start();
    final ending = restartAppProcess(restart: (_) async {}, exitProcess: exits.add);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(exits, isEmpty, reason: "Dart's exit ran before the native kill had its chance");
    await ending;
    expect(exits, [3]);
    expect(sw.elapsed, greaterThanOrEqualTo(const Duration(seconds: 2)));

    // A native call that fails cannot end the process: Dart exits at once.
    final failed = <int>[];
    await restartAppProcess(
      restart: (_) async => throw StateError('no channel'),
      exitProcess: failed.add,
    ).timeout(const Duration(milliseconds: 500));
    expect(failed, [3]);
  });

  test('Share on Wi-Fi during a night holds the Wi-Fi lock as the recorder; off and Stop let go; the Wi-Fi watch runs until Stop', () async {
    final port = await freePort();
    final on = ShareConfig(token: token, port: port).switchedOn(DateTime.now().millisecondsSinceEpoch);
    final h = handler(NoBand());
    await h.onStart(DateTime.now(), TaskStarter.developer);
    expect(wifiReads, greaterThan(0), reason: 'the Wi-Fi watch looks at the start of the night');
    h.onReceiveData(share(on));
    await until(() => locks.lastOrNull?['on'] == true);
    expect(locks.last, {'on': true, 'who': 'recorder'});
    h.onReceiveData(share(on.switchedOff()));
    await until(() => locks.last['on'] == false);
    expect(locks.last, {'on': false, 'who': 'recorder'});
    h.onReceiveData(share(on));
    await until(() => locks.last['on'] == true);

    h.onReceiveData(stopCommand);
    await until(() => toMain.any((m) => m is Map && m['kind'] == 'stopped') && locks.last['on'] == false);
    expect(locks.last, {'on': false, 'who': 'recorder'});
    expect(locks.map((c) => c['who']).toSet(), {'recorder'});
    expect(wifiReads, greaterThan(3), reason: 'the Wi-Fi watch looks on its period through the night');
    final seen = wifiReads;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(wifiReads, seen, reason: 'the Wi-Fi watch stops with the night');
    await h.onDestroy(DateTime.now(), false);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('the share switch moved on, off and on again within a second leaves one server, the last one asked', () async {
    final port = await freePort();
    final on = ShareConfig(token: token, port: port).switchedOn(DateTime.now().millisecondsSinceEpoch);
    final h = handler(NoBand());
    await h.onStart(DateTime.now(), TaskStarter.developer);
    h.onReceiveData(share(on));
    h.onReceiveData(share(on.switchedOff()));
    h.onReceiveData(share(on));
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(await listening(port), isTrue);

    h.onReceiveData(share(on.switchedOff()));
    var free = false;
    for (var i = 0; i < 60 && !free; i++) {
      free = !await listening(port);
      if (!free) await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(free, isTrue, reason: 'a share server nobody can stop still holds the port');
    await h.onDestroy(DateTime.now(), false);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
