// The real Export data screen, not only its view: it reads the app's folder in a background isolate when it opens.
// On the emulator (2026-11-18) that read failed with "object is unsendable": the closure handed to Isolate.run
// shared its scope with the screen's setState closures, so it tried to send the whole screen along. The platform
// channels are faked here; the isolate is real.
import 'dart:io';

import 'package:eeg_tracker/ui/export_screen.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('opens on a real folder: the summary arrives, no error', (tester) async {
    final files = Directory.systemTemp.createTempSync('export_screen_');
    addTearDown(() => files.deleteSync(recursive: true));
    Directory('${files.path}/recordings').createSync();
    File('${files.path}/recordings/2026-11-18-015825.log').writeAsStringSync('a run without samples\n');

    final messenger = tester.binding.defaultBinaryMessenger;
    const phone = MethodChannel('eeg_tracker/phone');
    const service = MethodChannel('flutter_foreground_task/methods');
    messenger.setMockMethodCallHandler(
      phone,
      (call) async => call.method == 'recordingsDir' ? '${files.path}/recordings' : null,
    );
    messenger.setMockMethodCallHandler(service, (call) async => call.method == 'isRunningService' ? false : null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(phone, null);
      messenger.setMockMethodCallHandler(service, null);
    });

    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: const ExportScreen()));
    final done = find.text('No folder yet');
    final failed = find.textContaining('could not read its folder');
    for (var i = 0; i < 100 && done.evaluate().isEmpty && failed.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(failed, findsNothing);
    expect(done, findsOneWidget);
  });
}
