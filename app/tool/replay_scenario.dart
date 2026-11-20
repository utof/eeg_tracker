// Writes the replay headband's made-up recordings (lib/headband/replay_scenarios.dart, DECISIONS 730-739) to a folder,
// for the emulator check (tool/precheck.py) or a look on the laptop:
//   cd app && dart run tool/replay_scenario.dart <scenario|all|list> <out folder>
// Each scenario goes to `<out>/<name>/<stamp>.f32 .idx .log .header.json`; the last line printed per scenario is
// `<name> <name>/<stamp>.f32 <seconds>`. Made-up signals only: nothing of the owner's.
import 'dart:io';

import 'package:eeg_tracker/headband/replay_scenarios.dart';

void main(List<String> args) {
  if (args.isNotEmpty && args.first == 'list') {
    for (final s in scenarios.values) {
      stdout.writeln('${s.name.padRight(20)} ${s.header.describe}, ${s.header.sampleRate} Hz: ${s.about}');
    }
    return;
  }
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/replay_scenario.dart <${scenarios.keys.join('|')}|all|list> <out folder>');
    exit(2);
  }
  final names = args[0] == 'all' ? scenarios.keys.toList() : [args[0]];
  for (final name in names) {
    final s = scenarios[name];
    if (s == null) {
      stderr.writeln('no scenario $name (try: list)');
      exit(2);
    }
    final dir = Directory('${args[1]}/$name');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    final f32 = writeScenario(dir, s);
    stdout.writeln('$name $name/${f32.uri.pathSegments.last} ${s.seconds.round()}');
  }
}
