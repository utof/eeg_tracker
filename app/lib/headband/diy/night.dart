// A night with the DIY board, as the recorder's service runs it (recorder/recorder_service.dart): its own folder
// (`files/recordings-diy`, never among the BrainBit nights), its own finder (one UDP listener all night), its own
// timing, and none of the BrainBit's detectors (DECISIONS rows 360-369).
import 'dart:io';

import '../../recorder/night_recorder.dart' show RecorderTiming;
import '../../signal/layout.dart' show PositionsStore, signalDirFor;
import 'board.dart';
import 'settings.dart';

/// The night recorder's rules with the DIY board. A "connection" is waiting for the board's datagrams, so every try
/// listens (scanEvery 1: there is no direct way in) for a minute, with a short pause between tries (frames that
/// arrive meanwhile are kept, board.dart `keepMax`); the deadline that would call it stuck is well beyond that wait.
const RecorderTiming diyRecorderTiming = RecorderTiming(
  scanFor: Duration(seconds: 60),
  rescanFor: Duration(seconds: 60),
  connectTimeout: Duration(seconds: 120),
  notFoundWait: Duration(milliseconds: 500),
  notFoundWaitLong: Duration(seconds: 1),
  reconnectWaits: [Duration(milliseconds: 200), Duration(seconds: 1)],
  scanEvery: 1,
);

class DiyNight {
  DiyNight(this.settings, this.recordingsDir);

  final DiyBoardSettings settings;

  /// The app's `files/recordings` (the BrainBit's); the board's go beside it.
  final String recordingsDir;

  Directory get dir => diyRecordingsDirFor(recordingsDir);

  /// The board's finder: the setting's names, and the Signal tab's positions file for the header's places.
  DiyFinder finder() => DiyFinder(names: settings.names, positions: PositionsStore(signalDirFor(recordingsDir)).load());

  /// The night's first log lines.
  List<String> get notes => [
    'headband: DIY board (test), channels ${settings.names.join(' ')}; files in recordings-diy',
    "drift-off detector, hands-free, the smart alarm's sleep model, the lucid cues and the live sleep model they "
        "share off for the DIY board: they read BrainBit's O1 O2 T3 T4 (the phone's alarm itself still rings)",
  ];
}

/// The DIY board's night when "Headband: DIY board (test)" is on (files/diy-board/settings.json); null, the BrainBit,
/// when it is off or cannot be read. The recorder's service asks this once when it starts.
DiyNight? diyNightFor(String recordingsDir) {
  try {
    final s = DiyBoardStore(diyBoardDirFor(recordingsDir)).load();
    return s.useDiy ? DiyNight(s, recordingsDir) : null;
  } catch (_) {
    return null;
  }
}
