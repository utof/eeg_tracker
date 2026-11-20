// Which headband the app uses (BrainBit, the default, or the owner's DIY ADS1299 board as a test) and the board's
// channel names: `files/diy-board/settings.json` in the app's private folder, read by the Headband connection page,
// the night screen and the recorder's service (each in its own isolate); it leaves the phone with Export data.
// The board's nights go to `files/recordings-diy/`, never among the BrainBit nights in `files/recordings/`: the
// sleep report, the morning check-in and the detectors read BrainBit's O1 O2 T3 T4 only (DECISIONS rows 358, 360-369).
import 'dart:convert';
import 'dart:io';

/// The breadboard's planned electrodes on CH1-CH4, as on the laptop (scripts/montages/diy-breadboard-4.json; a plan:
/// today's firmware records the chip's own test signal or shorted inputs, whatever the names say).
const List<String> defaultDiyNames = ['O1', 'O2', 'Fz', 'Fp1'];

/// The channel counts the board's frames carry (E9: the ADS1299-4, -6 and -8). The phone records any of them, each in a
/// record as wide as its channels with a header that names them (DECISIONS 630-639; until 2026-11-20 the 4-channel
/// chip only, row 363).
const List<int> diyChannelCounts = [4, 6, 8];

/// A channel name as the laptop's recorder accepts it (scripts/record_diy.py `NAME_RE`).
final RegExp diyNameRe = RegExp(r'^[A-Za-z0-9_.\-]{1,16}$');

/// The names a person typed: separated by commas and/or spaces.
List<String> parseDiyNames(String text) => [
  for (final p in text.split(RegExp(r'[,\s]+'))) if (p.trim().isNotEmpty) p.trim(),
];

/// Why [names] cannot be used, in a sentence, or null when they can.
String? diyNamesProblem(List<String> names) {
  if (!diyChannelCounts.contains(names.length)) {
    return 'Give 4, 6 or 8 names, one for each of the board\'s channels from CH1, e.g. O1, O2, Fz, Fp1.';
  }
  final bad = names.where((n) => !diyNameRe.hasMatch(n)).toList();
  if (bad.isNotEmpty) return 'Use letters, digits, _ . or - only, up to 16 each (not: ${bad.join(', ')}).';
  if (names.toSet().length != names.length) return 'Each channel needs its own name.';
  return null;
}

class DiyBoardSettings {
  const DiyBoardSettings({this.useDiy = false, this.names = defaultDiyNames});

  /// "Headband: DIY board (test)". Off = the BrainBit.
  final bool useDiy;

  /// CH1..'s names in the files and on the night screen (4, 6 or 8). A board with another count records as Ch1..ChN.
  final List<String> names;

  DiyBoardSettings copyWith({bool? useDiy, List<String>? names}) =>
      DiyBoardSettings(useDiy: useDiy ?? this.useDiy, names: names ?? this.names);

  Map<String, Object?> toJson() => {'useDiy': useDiy, 'names': names};

  /// The defaults for anything missing or unusable (names that fail [diyNamesProblem]).
  static DiyBoardSettings fromJson(Object? j) {
    if (j is! Map) return const DiyBoardSettings();
    final raw = j['names'];
    final names = raw is List && raw.every((n) => n is String) ? raw.cast<String>().toList() : null;
    return DiyBoardSettings(
      useDiy: j['useDiy'] == true,
      names: names != null && diyNamesProblem(names) == null ? List.unmodifiable(names) : defaultDiyNames,
    );
  }
}

/// `files/diy-board` for the app's recordings folder (`files/recordings`).
Directory diyBoardDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/diy-board');

/// `files/recordings-diy`: the board's nights, apart from the BrainBit's.
Directory diyRecordingsDirFor(String recordingsDir) =>
    Directory('${Directory(recordingsDir).parent.path}/recordings-diy');

class DiyBoardStore {
  DiyBoardStore(this.dir);

  /// `files/diy-board`.
  final Directory dir;

  File get file => File('${dir.path}/settings.json');

  /// The saved settings; the defaults (BrainBit) when there are none or the file is damaged.
  DiyBoardSettings load() {
    try {
      return DiyBoardSettings.fromJson(jsonDecode(file.readAsStringSync()));
    } on FileSystemException {
      return const DiyBoardSettings();
    } on FormatException {
      return const DiyBoardSettings();
    }
  }

  /// Written to a temporary file, then renamed, so a reader never sees half a file.
  void save(DiyBoardSettings s) {
    dir.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(s.toJson())}\n', flush: true);
    tmp.renameSync(file.path);
  }
}
