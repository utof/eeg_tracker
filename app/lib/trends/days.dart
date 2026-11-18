// What counts as a day in the trends (DECISIONS row 121): a day runs from 04:00 to 04:00 local time, so a
// meditation at 2 a.m. still belongs to the evening before it; a night counts for the day you woke from it (the
// end of its last sleep period). Days are keys like `2026-11-18`.

/// Hours after midnight at which a new day starts.
const int dayStartHour = 4;

String _two(int v) => v.toString().padLeft(2, '0');

String _key(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

/// The day [t] (local time) belongs to.
String dayKey(DateTime t) {
  final l = t.toLocal().subtract(const Duration(hours: dayStartHour));
  return _key(l);
}

/// The day a night belongs to: the day of its final wake-up.
String wakeDay(DateTime finalWake) => dayKey(finalWake);

/// Noon of a day key, local time (safe from daylight-saving edges for date arithmetic).
DateTime dayNoon(String key) {
  final p = key.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2], 12);
}

String addDays(String key, int n) {
  final d = dayNoon(key);
  return _key(DateTime(d.year, d.month, d.day + n, 12));
}

/// Whole days from [a] to [b] (positive when b is later).
int daysBetween(String a, String b) =>
    (DateTime.utc(dayNoon(b).year, dayNoon(b).month, dayNoon(b).day)
                .difference(DateTime.utc(dayNoon(a).year, dayNoon(a).month, dayNoon(a).day))
                .inHours /
            24)
        .round();

const List<String> _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const List<String> _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String weekdayShort(String key) => _weekdays[dayNoon(key).weekday - 1];

/// `Wed 18 Nov`.
String dayLabel(String key) {
  final d = dayNoon(key);
  return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
}

/// The last [n] day keys up to and including [last], oldest first.
List<String> lastDays(String last, int n) => [for (var k = n - 1; k >= 0; k--) addDays(last, -k)];
