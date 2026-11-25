// "Stop everything or keep recording?": asked when an activity that started the recording has ended and the
// recording still runs (Record first, DECISIONS 884 and 980). Stop everything is the filled button, as on Sleep's
// Stop: nobody records by accident. The question is the app's, not a page's: it shows over whatever page is open.
import 'dart:async';

import 'package:flutter/material.dart';

import '../spans/activities.dart';

/// Listens to [Activities.ask] for the app's life and shows the question on [navigator].
class ActivityStopAsker {
  ActivityStopAsker(this.activities, this.navigator);
  final Activities activities;
  final GlobalKey<NavigatorState> navigator;
  bool _showing = false;

  void install() => activities.ask.addListener(_changed);

  void dispose() => activities.ask.removeListener(_changed);

  void _changed() {
    if (activities.ask.value != null) unawaited(_show());
  }

  Future<void> _show() async {
    if (_showing) return;
    final context = navigator.currentContext;
    final run = activities.ask.value;
    if (context == null || run == null) return;
    _showing = true;
    try {
      final all = await showActivityStop(context, run.word);
      // the question was answered another way meanwhile (a new activity started: the recording is wanted)
      if (!identical(activities.ask.value, run)) return;
      await activities.answer(stopEverything: all ?? false);
    } finally {
      _showing = false;
    }
  }
}

/// The two-button sheet: true = Stop everything, false = Keep recording.
Future<bool?> showActivityStop(BuildContext context, String word) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (c) => AlertDialog(
    title: Text('$word has ended'),
    content: Text(
      '$word started this recording. Stop everything ends the recording too. Keep recording: the headband goes on '
      'recording until you press Stop on the Record tab.',
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep recording')),
      FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Stop everything')),
    ],
  ),
);
