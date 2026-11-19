// Before a session whose only cue is a sound (the nap's wake cue, the check-in's tone to open your eyes): the media
// volume and where the sound goes are read, and anything that would keep the cue from being heard is said in a dialog
// with a way to go on anyway (DECISIONS row 466; sound/audio_route.dart's cueCheck).
import 'package:flutter/material.dart';

import '../sound/audio_route.dart';

/// True when the session may start: nothing to say, or the owner chose to go on. [cue]: "the wake cue"; [go]: the
/// button that goes on ("Lights off anyway").
Future<bool> confirmCueSound(
  BuildContext context, {
  required String cue,
  required String go,
  double floor = wakeVolumeFloor,
  AudioRouteSource? routes,
  Future<MediaVolume?> Function() volume = phoneMediaVolume,
  Duration wait = const Duration(seconds: 2),
}) async {
  final src = routes ?? PhoneAudioRoute();
  Future<MediaVolume?> level() async {
    try {
      return await volume().timeout(wait);
    } catch (_) {
      return null; // the phone did not say: nothing is warned about
    }
  }

  Future<AudioRoute> route() async {
    try {
      return await src.current().timeout(wait);
    } catch (_) {
      return AudioRoute.unknown;
    }
  }

  final (v, r) = await (level(), route()).wait;
  final warning = cueCheck(volume: v, route: r, cue: cue, floor: floor);
  if (warning == null) return true;
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Check the sound'),
      content: Text(warning),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: Text(go)),
      ],
    ),
  );
  return ok == true;
}
