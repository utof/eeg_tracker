// The laptop's command-line tools run with plain `dart run tool/<name>.dart` (no Flutter engine): the replay
// scenarios for the pre-install check (tool/precheck.py), the night preparation and extras, the live checks and the
// work check (app/README.md, docs/detectors.md). Nothing they import may reach Flutter or dart:ui, or `dart run`
// stops at compiling (integration 18: the app log's AppLog, added to recorder/packed.dart, pulled Flutter into all six).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every library [tool] imports or exports, directly or not, as `dart:` / `package:` names and app files.
Map<String, String?> importClosure(String tool) {
  final lib = Directory('lib').absolute.uri;
  final directive = RegExp(r"^(?:import|export)\s+'([^']+)'", multiLine: true);
  final from = <String, String?>{};
  final todo = <(Uri, String?)>[(File(tool).absolute.uri, null)];
  while (todo.isNotEmpty) {
    final (uri, by) = todo.removeLast();
    final key = uri.isScheme('file') ? uri.toFilePath() : uri.toString();
    if (from.containsKey(key)) continue;
    from[key] = by;
    if (!uri.isScheme('file')) continue;
    for (final m in directive.allMatches(File.fromUri(uri).readAsStringSync())) {
      final u = Uri.parse(m.group(1)!);
      final next = u.isScheme('package') && u.pathSegments.first == 'eeg_tracker'
          ? lib.resolve(u.pathSegments.skip(1).join('/'))
          : u.hasScheme
          ? u
          : uri.resolveUri(u);
      todo.add((next, key));
    }
  }
  return from;
}

void main() {
  const tools = [
    'tool/replay_scenario.dart',
    'tool/prep_night.dart',
    'tool/night_extras.dart',
    'tool/live_night.dart',
    'tool/live_drift.dart',
    'tool/work_check.dart',
  ];
  for (final tool in tools) {
    test('$tool runs without Flutter: nothing it imports reaches package:flutter or dart:ui', () {
      final from = importClosure(tool);
      final flutter = from.keys.where((k) => k.startsWith('package:flutter/') || k == 'dart:ui').toList();
      String chain(String k) => [for (String? p = k; p != null; p = from[p]) p.split('/').last].join(' <- ');
      expect(flutter.map(chain).toList(), isEmpty);
      expect(from.length, greaterThan(3), reason: 'the walk found the tool and what it imports (a check on the check)');
    });
  }
}
