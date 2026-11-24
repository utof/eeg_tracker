/// `2026-11-18T03:16:55+03:00`: local time with its UTC offset, to the second, as Python's
/// `isoformat(timespec="seconds")` writes it.
String isoLocal(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final off = l.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final m = off.inMinutes.abs();
  return '${l.year.toString().padLeft(4, '0')}-${two(l.month)}-${two(l.day)}T${two(l.hour)}:${two(l.minute)}:'
      '${two(l.second)}$sign${two(m ~/ 60)}:${two(m % 60)}';
}
