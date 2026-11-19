// The switch between BrainBit's SDK and our own connection, and what our connection remembers:
// `files/own-ble/settings.json` in the app's private folder (read by the screen and by the night recorder's
// service, each in its own isolate; it leaves the phone with Export data like everything else).
// BrainBit's SDK stays the default until the probe has passed on the real headband (DECISIONS rows 211, 215).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'protocol.dart';

/// What the last probe found, in short (the full result is in its own folder).
class ProbeNote {
  const ProbeNote({
    required this.at,
    required this.passed,
    required this.worn,
    required this.command5,
    required this.folder,
    this.line = '',
  });

  /// When it ran, as the result folder's stamp (`2026-11-19-081500`).
  final String at;

  /// Everything our connection needs worked, and the channel order is settled (worn runs only).
  final bool passed;

  /// The headband was on the head (channel order and alpha checked), not lying on the desk.
  final bool worn;

  /// Command 5 gave signal and contact together.
  final bool command5;

  /// Relative to `files/`: `own-ble/probe/<stamp>`.
  final String folder;

  /// One plain sentence for the page.
  final String line;

  Map<String, Object?> toJson() => {
    'at': at,
    'passed': passed,
    'worn': worn,
    'command5': command5,
    'folder': folder,
    'line': line,
  };

  static ProbeNote? fromJson(Object? j) {
    if (j is! Map || j['at'] is! String || j['folder'] is! String) return null;
    return ProbeNote(
      at: j['at'] as String,
      passed: j['passed'] == true,
      worn: j['worn'] == true,
      command5: j['command5'] == true,
      folder: j['folder'] as String,
      line: j['line'] is String ? j['line'] as String : '',
    );
  }
}

class OwnBleSettings {
  const OwnBleSettings({
    this.useOwn = false,
    this.triedAnyway = false,
    this.signalResist = false,
    this.pair = false,
    this.address,
    this.name,
    this.layout,
    this.probe,
  });

  /// The switch "Use our own connection (test)". Off = BrainBit's SDK.
  final bool useOwn;

  /// The switch was turned on without a passed probe ("try anyway").
  final bool triedAnyway;

  /// Signal and contact together all the time (command 5); only offered once the probe saw it work.
  final bool signalResist;

  /// Bond with the headband when connecting (only if the probe showed it is needed).
  final bool pair;

  /// The headband our connection reached last: connected to directly, without a scan.
  final String? address;
  final String? name;

  /// Channel order and gain the probe settled; null = the defaults in protocol.dart.
  final Layout? layout;
  final ProbeNote? probe;

  /// The switch may be offered without "try anyway".
  bool get probePassed => probe?.passed ?? false;

  OwnBleSettings copyWith({
    bool? useOwn,
    bool? triedAnyway,
    bool? signalResist,
    bool? pair,
    String? address,
    String? name,
    Layout? layout,
    ProbeNote? probe,
  }) => OwnBleSettings(
    useOwn: useOwn ?? this.useOwn,
    triedAnyway: triedAnyway ?? this.triedAnyway,
    signalResist: signalResist ?? this.signalResist,
    pair: pair ?? this.pair,
    address: address ?? this.address,
    name: name ?? this.name,
    layout: layout ?? this.layout,
    probe: probe ?? this.probe,
  );

  Map<String, Object?> toJson() => {
    'useOwn': useOwn,
    'triedAnyway': triedAnyway,
    'signalResist': signalResist,
    'pair': pair,
    'address': address,
    'name': name,
    'layout': layout?.toJson(),
    'probe': probe?.toJson(),
  };

  static OwnBleSettings fromJson(Object? j) {
    if (j is! Map) return const OwnBleSettings();
    final address = j['address'], name = j['name'];
    return OwnBleSettings(
      useOwn: j['useOwn'] == true,
      triedAnyway: j['triedAnyway'] == true,
      signalResist: j['signalResist'] == true,
      pair: j['pair'] == true,
      address: address is String && address.isNotEmpty ? address : null,
      name: name is String && name.isNotEmpty ? name : null,
      layout: Layout.fromJson(j['layout']),
      probe: ProbeNote.fromJson(j['probe']),
    );
  }
}

/// `files/own-ble` for the app's recordings folder (`files/recordings`).
Directory ownBleDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/own-ble');

class OwnBleStore {
  OwnBleStore(this.dir);

  /// `files/own-ble`.
  final Directory dir;

  File get file => File('${dir.path}/settings.json');

  /// Where the probe keeps its results: one folder per run.
  Directory get probeDir => Directory('${dir.path}/probe');

  /// The saved settings; the defaults (SDK) when there are none or the file is damaged.
  OwnBleSettings load() => _read() ?? const OwnBleSettings();

  /// The saved settings, the defaults when there is no file yet, null when the file cannot be read or is damaged.
  OwnBleSettings? _read() {
    try {
      return OwnBleSettings.fromJson(jsonDecode(file.readAsStringSync()));
    } on PathNotFoundException {
      return const OwnBleSettings();
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Written to a temporary file of its own, then renamed, so a reader never sees half a file (the screen and the
  /// recorder's service each save from their own isolate).
  void save(OwnBleSettings s) {
    dir.createSync(recursive: true);
    final tmp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}.tmp');
    tmp.writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(s.toJson())}\n', flush: true);
    tmp.renameSync(file.path);
  }

  /// Remembers the headband our connection reached (the other settings as they are on disk now). Settings that
  /// cannot be read are left as they are: writing the defaults over them would switch our connection off and lose
  /// the channel order for good, while the next read may well work.
  void remember(String address, String name) {
    final now = _read();
    if (now == null) return;
    if (now.address == address && (name.isEmpty || now.name == name)) return;
    save(now.copyWith(address: address, name: name.isEmpty ? null : name));
  }
}

final RegExp _macRe = RegExp(r'\b([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})\b');

/// The headband's address from the newest recorder logs (`... connected <name> <address> serial ...`), so our
/// connection can go straight to the headband the SDK recorded with. Null when no log names one.
String? knownAddress(Directory recordings, {int newest = 60}) {
  final List<File> logs;
  try {
    logs = [
      for (final f in recordings.listSync().whereType<File>())
        if (f.path.endsWith('.log')) f,
    ]..sort((a, b) => b.path.compareTo(a.path)); // names are time stamps
  } on FileSystemException {
    return null;
  }
  for (final f in logs.take(newest)) {
    final List<String> lines;
    try {
      lines = const LineSplitter().convert(f.readAsStringSync());
    } on FileSystemException {
      continue;
    } on FormatException {
      continue;
    }
    for (final line in lines.take(20)) {
      final parts = line.split(' ');
      if (parts.length < 3 || parts[1] != 'connected') continue;
      final m = _macRe.firstMatch(parts.skip(2).join(' '));
      if (m != null) return m.group(1)!.toUpperCase();
    }
  }
  return null;
}
