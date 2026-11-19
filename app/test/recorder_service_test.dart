// The recorder service's task handler (lib/recorder/recorder_service.dart) between the screen's messages and the
// night recorder: the platform channels it uses (the app's phone channel, the plugin's methods, shared preferences)
// are answered here; the headband is a finder that never finds one. Share on Wi-Fi runs for real (isolate, socket).
import 'dart:async';
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

  setUp(() {
    files = Directory.systemTemp.createTempSync('recorder_service_test');
    Directory('${files.path}/recordings').createSync();
    prefs = {};
    dirAnswer = Completer<void>()..complete();
    toMain = [];
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

  RecorderTaskHandler handler(NoBand band) => RecorderTaskHandler(finder: () => band, cues: (_, _) => (_) => null);

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
