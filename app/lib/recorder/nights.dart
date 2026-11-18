// The nights kept on the phone, for Export. A night is every file set whose run started in the same
// noon-to-noon day: the evening's date is the start minus 12 hours, as `night_of` in docs/data-format.md.
import 'dart:io';

import 'chunk_writer.dart';

final RegExp _stem = RegExp(r'^(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})\.');

/// Start of the run that wrote [fileName] (`2026-11-18-231200.f32` and its `.idx`, `.log`), or null for any
/// other file.
DateTime? stemTime(String fileName) {
  final m = _stem.firstMatch(fileName);
  if (m == null) return null;
  final p = [for (var i = 1; i <= 6; i++) int.parse(m[i]!)];
  final t = DateTime(p[0], p[1], p[2], p[3], p[4], p[5]);
  // DateTime rolls impossible values over (month 13 = next January); such a name is not ours.
  return '${fileStem(t)}.' == m[0] ? t : null;
}

/// The evening's date of a run that started at [t].
DateTime nightOf(DateTime t) {
  final shifted = t.subtract(const Duration(hours: 12));
  return DateTime(shifted.year, shifted.month, shifted.day);
}

class NightFiles {
  NightFiles(this.nightOf, this.files);

  /// The evening's date.
  final DateTime nightOf;

  /// Every file of the night, oldest run first.
  final List<File> files;

  /// Start of the first run.
  DateTime get start => stemTime(files.first.uri.pathSegments.last)!;

  /// File sets (one per recorder run: a new one after every drop or restart).
  int get runs => files.where((f) => f.path.endsWith('.f32')).length;

  int get bytes => files.fold(0, (sum, f) => sum + f.lengthSync());

  /// Name of the folder an export creates, e.g. `eeg-night-2026-11-18`.
  String get folderName =>
      'eeg-night-${nightOf.year.toString().padLeft(4, '0')}-${_two(nightOf.month)}-${_two(nightOf.day)}';
}

/// The nights in [dir], newest first.
List<NightFiles> nightsIn(Directory dir) {
  if (!dir.existsSync()) return const [];
  final byNight = <DateTime, List<File>>{};
  for (final f in dir.listSync().whereType<File>()) {
    final t = stemTime(f.uri.pathSegments.last);
    if (t != null) byNight.putIfAbsent(nightOf(t), () => []).add(f);
  }
  return [
    for (final e in byNight.entries)
      NightFiles(e.key, e.value..sort((a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last))),
  ]..sort((a, b) => b.nightOf.compareTo(a.nightOf));
}

const List<String> _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const List<String> _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// `Wed 18 Nov`.
String nightLabel(DateTime d) => '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';

String _two(int v) => v.toString().padLeft(2, '0');
