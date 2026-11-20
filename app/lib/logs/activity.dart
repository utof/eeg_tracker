// What runs now in this Flutter engine (DECISIONS 715): the battery samples carry it, so the Battery page can say what
// each feature costs, and the usage log gets each feature's start and its length. Every subsystem marks itself with
// one line: `Activity.begin('signal')` ... `Activity.end('signal')`, or `Activity.during('scoring', () => work())`.
// Counted: two holders of the same feature keep it on until both let go. One registry per engine (a Dart isolate's
// statics); the Battery page joins the engines' samples by time.

/// The features the app marks, with the words the pages use. A name not listed here is shown as it is; a session is
/// `session:<its notification title>`.
const Map<String, String> featureLabels = {
  'app-open': 'App open on the screen',
  'night': 'Night recording',
  'headband': 'Headband link',
  'live-model': 'Live sleep model',
  'cues': 'Sound cues at night',
  'share': 'Share on Wi-Fi',
  'wifi-lock': 'Wi-Fi kept awake',
  'signal': 'Signal tab',
  'scoring': 'Sleep scoring',
  'packing': 'Packing old nights',
  'export': 'Export data',
  'auto-check': 'Headband check (auto-start)',
  'session': 'A session',
};

/// The words for [feature] (`session:Meditation` -> `Meditation session`).
String featureLabel(String feature) {
  if (feature.startsWith('session:')) return '${feature.substring('session:'.length)} session';
  return featureLabels[feature] ?? feature;
}

typedef ActivityListener = void Function(String feature, bool on, Duration? lasted);

abstract final class Activity {
  static final Map<String, int> _holders = {};
  static final Map<String, DateTime> _since = {};
  static final List<ActivityListener> _listeners = [];

  /// The clock (tests set a fake one).
  static DateTime Function() clock = DateTime.now;

  /// The features on now, sorted.
  static List<String> get active => (_holders.keys.toList()..sort());

  static bool isOn(String feature) => _holders.containsKey(feature);

  /// When [feature] came on, or null.
  static DateTime? since(String feature) => _since[feature];

  static void begin(String feature) {
    final n = _holders[feature] ?? 0;
    _holders[feature] = n + 1;
    if (n == 0) {
      _since[feature] = clock();
      _tell(feature, true, null);
    }
  }

  static void end(String feature) {
    final n = _holders[feature];
    if (n == null) return;
    if (n > 1) {
      _holders[feature] = n - 1;
      return;
    }
    _holders.remove(feature);
    final from = _since.remove(feature);
    _tell(feature, false, from == null ? null : clock().difference(from));
  }

  /// [begin] when [on], else [end]; for a switch that may be set twice in a row ("on" again keeps one holder).
  static void set(String feature, {required bool on}) {
    if (on == isOn(feature)) return;
    on ? begin(feature) : end(feature);
  }

  /// Runs [work] with [feature] on.
  static Future<T> during<T>(String feature, Future<T> Function() work) async {
    begin(feature);
    try {
      return await work();
    } finally {
      end(feature);
    }
  }

  static void listen(ActivityListener l) => _listeners.add(l);
  static void unlisten(ActivityListener l) => _listeners.remove(l);

  static void _tell(String feature, bool on, Duration? lasted) {
    for (final l in List.of(_listeners)) {
      try {
        l(feature, on, lasted);
      } catch (_) {}
    }
  }

  /// Tests: nothing on, nobody listening, the real clock.
  static void reset() {
    _holders.clear();
    _since.clear();
    _listeners.clear();
    clock = DateTime.now;
  }
}
