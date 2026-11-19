// Handing the phone the moments ahead (DECISIONS row 283), and the question a notification tap opened.
import 'dart:io';

import 'package:eeg_tracker/sharp/prompts.dart';
import 'package:eeg_tracker/sharp/schedule.dart';
import 'package:eeg_tracker/sharp/store.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSharpPhone implements SharpPhone {
  final List<List<PlannedPrompt>> armed = [];
  SharpLaunch? launch;
  bool notifications = true, studyNotifications = true;
  int channelSettings = 0;

  @override
  Future<void> arm(List<PlannedPrompt> prompts) async => armed.add(prompts);

  @override
  Future<SharpLaunch?> takeLaunch() async {
    final l = launch;
    launch = null;
    return l;
  }

  @override
  Future<bool> notificationsOn() async => notifications;

  @override
  Future<bool> studyNotificationsOn() async => studyNotifications;

  @override
  Future<void> openChannelSettings() async => channelSettings++;

  @override
  set onOpen(void Function()? f) {}
}

void main() {
  late Directory tmp;
  late SharpStore store;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sharp');
    store = SharpStore(Directory('${tmp.path}/sharp-hours'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));
  final now = DateTime(2026, 11, 20, 15);

  test('never set up or off: nothing armed (an empty list cancels)', () async {
    final phone = FakeSharpPhone();
    await rearmSharp(store, phone, now);
    store.saveSettings(const SharpSettings(on: false, perDay: 4, fromMin: 600, untilMin: 1320, seed: 'x'));
    await rearmSharp(store, phone, now);
    expect(phone.armed, [isEmpty, isEmpty]);
  });

  test('on: the next 14 days of moments, from now', () async {
    final phone = FakeSharpPhone();
    const s = SharpSettings(on: true, perDay: 4, fromMin: 600, untilMin: 1320, seed: 'x');
    store.saveSettings(s);
    await rearmSharp(store, phone, now);
    final p = phone.armed.single;
    expect(p.first.at.isAfter(now), isTrue);
    expect(p.length, upcomingPrompts(now, s).length);
    expect(p.length, greaterThanOrEqualTo(14 * 4));
  });

  test('a launch from the Android side: planned and shown times, the test flag; anything else is refused', () {
    final l = SharpLaunch.fromMap({'planned': 1763640000000, 'shown': 1763640120000, 'test': true})!;
    expect(l.planned, DateTime.fromMillisecondsSinceEpoch(1763640000000));
    expect(l.shown, DateTime.fromMillisecondsSinceEpoch(1763640120000));
    expect(l.test, isTrue);
    expect(SharpLaunch.fromMap({'planned': 1763640000000, 'shown': 0})!.shown, isNull);
    expect(SharpLaunch.fromMap({'planned': 0}), isNull);
    expect(SharpLaunch.fromMap(null), isNull);
    expect(SharpLaunch.fromMap({'planned': '1763640000000'}), isNull);
  });

  test('a launch says what asked: a sharp question unless the Android side names a study reminder', () {
    expect(SharpLaunch.fromMap({'planned': 1763640000000})!.kind, PromptKind.sharp);
    expect(SharpLaunch.fromMap({'planned': 1763640000000, 'kind': 'study_evening'})!.kind, PromptKind.studyEvening);
    expect(SharpLaunch.fromMap({'planned': 1763640000000, 'kind': 'study_morning'})!.kind, PromptKind.studyMorning);
    expect(SharpLaunch.fromMap({'planned': 1763640000000, 'kind': 'nonsense'})!.kind, PromptKind.sharp);
  });
}
