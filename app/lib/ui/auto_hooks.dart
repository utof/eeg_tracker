// The headband watcher's hooks in the app's screen (lib/auto, DECISIONS 600): a start by hand makes the watcher let go
// of a headband it holds while asking; opening the app runs a check and arms the bedtime checks; a tap on the watcher's
// notification opens the work page (which starts the session) or the "When I put the headband on" page.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../auto/bedtime.dart';
import '../auto/channel.dart';
import '../auto/store.dart';
import '../auto/work_start.dart';
import '../headband/finder.dart';
import '../phone.dart';
import 'auto_start_screen.dart';
import 'work_screen.dart';

class AutoHooks with WidgetsBindingObserver {
  AutoHooks(this.navigator);
  final GlobalKey<NavigatorState> navigator;

  /// At most one "app opened" check every 5 minutes.
  static const Duration openedEvery = Duration(minutes: 5);
  DateTime? _lastOpened;
  bool _opening = false;

  void install() {
    BrainBitFinder.beforeUse = AutoChannel.release;
    AutoChannel.listen(() => unawaited(_launch()));
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _launch();
      await _opened();
    });
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    BrainBitFinder.beforeUse = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_opened());
  }

  /// The app came to the front: arm the bedtime checks, and ask for a check (the watcher decides whether one runs).
  Future<void> _opened() async {
    final now = DateTime.now();
    final last = _lastOpened;
    if (last != null && now.difference(last) < openedEvery) return;
    _lastOpened = now;
    try {
      final rec = await Phone.recordingsDir();
      if (rec == null) return;
      final s = AutoStore(autoDirFor(rec)).settings();
      await AutoChannel.armBedtime(s.allOff ? const [] : bedtimeChecks(usualNight(recordedNights(Directory(rec), now), s), now));
      if (!s.allOff) await AutoChannel.requestCheck('opened');
    } catch (_) {
      // no channel (tests, a desktop harness) or no folder yet: nothing to watch
    }
  }

  Future<void> _launch() async {
    if (_opening) return;
    _opening = true;
    try {
      final l = await AutoChannel.takeLaunch();
      final nav = navigator.currentState;
      if (l == null || nav == null) return;
      _lastOpened = DateTime.now(); // the tap is the check's answer: no second check now
      if (l.action == 'work') {
        unawaited(AutoChannel.workOpened());
        unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => WorkScreen(auto: AutoWorkStart(quiet: l.quiet, limit: l.limit)))));
      } else if (l.action == 'settings') {
        unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const AutoStartScreen())));
      }
    } catch (_) {
      // nothing to open
    } finally {
      _opening = false;
    }
  }
}
