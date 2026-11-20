// The switches of the app's records (DECISIONS 713, 715): `files/logs/settings.json`. Every engine reads it when it
// starts its records; the pages write it. A missing or broken file means the defaults.
import 'dart:convert';
import 'dart:io';

class LogSettings {
  const LogSettings({this.usage = true, this.battery = true, this.detailed = false});

  /// "Record how I use the app": screens, taps, scrolls, features, hints. On by default (the owner asked for it,
  /// 2026-11-20); everything stays on the phone.
  final bool usage;

  /// "Measure battery": the phone's battery, CPU and memory every 1-2 minutes while the app is open or a feature
  /// runs. On by default (a read of Android's battery numbers costs nothing measurable).
  final bool battery;

  /// The app log's fine lines too (more detail for a hunt, more writing).
  final bool detailed;

  LogSettings copyWith({bool? usage, bool? battery, bool? detailed}) =>
      LogSettings(usage: usage ?? this.usage, battery: battery ?? this.battery, detailed: detailed ?? this.detailed);

  Map<String, Object?> toJson() => {'version': 1, 'usage': usage, 'battery': battery, 'detailed': detailed};

  static LogSettings fromJson(Object? j) {
    if (j is! Map) return const LogSettings();
    return LogSettings(usage: j['usage'] != false, battery: j['battery'] != false, detailed: j['detailed'] == true);
  }

  static File fileIn(Directory logsDir) => File('${logsDir.path}/settings.json');

  /// Never throws: the defaults when the file is missing or cannot be read.
  static LogSettings load(Directory logsDir) {
    try {
      final f = fileIn(logsDir);
      if (!f.existsSync()) return const LogSettings();
      return fromJson(jsonDecode(f.readAsStringSync()));
    } catch (_) {
      return const LogSettings();
    }
  }

  /// Written through a temporary file, so a reader never sees half of it.
  void save(Directory logsDir) {
    logsDir.createSync(recursive: true);
    final f = fileIn(logsDir);
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(toJson()), flush: true);
    tmp.renameSync(f.path);
  }
}
