// A recording that ended without a Stop (the phone restarted; DECISIONS 899): no service runs, yet the saved state
// still says "active". Its open spans are closed at its last saved sample (`phone_restart`), and it is marked ended,
// so its sleep spans are scored and its stop sheet can be shown. Android restarting only the app's process is not
// this: the service comes back within a minute and goes on, so nothing is closed until the data is [restartGrace] old.
import 'dart:io';

import '../recorder/chunk_writer.dart' show fileStem;
import '../recorder/headband.dart' show NightState;
import '../recorder/header.dart' show tryHeader;
import '../recorder/nights.dart' show dataEndOf, stemTime;
import 'span.dart';
import 'span_log.dart';

const Duration restartGrace = Duration(minutes: 10);

/// [state] as it should be saved now, or null when nothing is to be done (not active, or its data is too fresh to
/// tell a restarted phone from a restarting process). Call only while the recorder's service does not run.
NightState? endedWithoutStop(NightState state, Directory recordingsDir, {DateTime Function()? clock}) {
  if (!state.active) return null;
  final now = (clock ?? DateTime.now)();
  var id = state.recording;
  var last = DateTime.fromMillisecondsSinceEpoch(state.startMs);
  if (id != null && recordingsDir.existsSync()) {
    for (final f in recordingsDir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.f32') || stemTime(name) == null || name.compareTo(id) < 0) continue;
      if (tryHeader(f)?.recording != id) continue;
      final end = dataEndOf(f);
      if (end != null && end.isAfter(last)) last = end;
    }
  }
  if (now.difference(last) < restartGrace) return null;
  var spans = [for (final l in state.spans) ?Span.fromLine(l)];
  if (spans.isNotEmpty) {
    id ??= fileStem(DateTime.fromMillisecondsSinceEpoch(state.startMs));
    final log = SpanLog(spansDirFor(recordingsDir.path), clock: clock);
    final fixed = <Span>[];
    for (var k = 0; k < spans.length; k++) {
      var s = spans[k].id.startsWith('?') ? spans[k].withId('$id-${k + 1}') : spans[k];
      if (!s.closed) s = s.closedAt(last, 'phone_restart');
      if (!identical(s, spans[k])) log.write(s);
      fixed.add(s);
    }
    spans = fixed;
  }
  return state.withSleepKit(on: false).copyWith(active: false, recording: id, spans: [for (final s in spans) s.toLine(now)]);
}
