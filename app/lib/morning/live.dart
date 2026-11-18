// The contact step of the check-in, as the laptop page grades it (scripts/web/morning-core.js `gradeChannel`):
// one word per electrode from its contact reading and the last 4 s of its signal (mean removed): no contact or a
// flat line = "not touching", a spread over 60 µV = "noisy", over 30 µV = "fair", else "good".
import 'dart:math' as math;

enum Grade { good, fair, bad }

/// Seconds of signal the grade looks at (the page's live state holds the last 4 s).
const double gradeWindowS = 4;

/// Standard deviation after removing the mean (µV); 0 for no samples.
double spreadOf(List<double> x) {
  if (x.isEmpty) return 0;
  final m = x.reduce((a, b) => a + b) / x.length;
  return math.sqrt(x.fold(0.0, (s, v) => s + (v - m) * (v - m)) / x.length);
}

({Grade grade, String word, double spread}) gradeChannel(double? ohms, List<double>? x) {
  final s = x == null ? 0.0 : spreadOf(x);
  final m = x == null || x.isEmpty ? 0.0 : x.reduce((a, b) => a + b) / x.length;
  final flat = x == null || x.length < 10 || x.map((v) => (v - m).abs()).reduce(math.max) < 0.5;
  if (ohms == null || flat) return (grade: Grade.bad, word: 'not touching', spread: s);
  if (s > 60) return (grade: Grade.bad, word: 'noisy', spread: s);
  if (s > 30) return (grade: Grade.fair, word: 'fair', spread: s);
  return (grade: Grade.good, word: 'good', spread: s);
}
