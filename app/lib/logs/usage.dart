// How the app is used (DECISIONS 713): one JSON line per event in `files/logs/usage-<day>-<engine>.jsonl`, only on
// this phone, only while "Record how I use the app" is on. Events (`ev`):
//
//   view     the screen shown now (`screen`: a page's widget name such as `MeditationScreen`, or `tab:Signal`)
//   app      the app came to the front or left it (`state`: front / back)
//   tap      a control tapped: `screen`, `control` (its kind), `label` (its own words, digits as #, never words the
//            owner typed: own_text.dart), `id` (its key)
//   scroll   a scroll by finger: `screen`, `axis`, `dir`, `px`, `ms`, `reach` (how far down the page, 0-1)
//   drag     a drag that scrolled nothing (the 3D head, a slider): `screen`, `dir`, `px`, `ms`, `fingers`
//   feature  a feature started or stopped: `name`, `on`, `s` (how long it ran, at the stop)
//   setting  a switch or a choice changed: `key`, `value`
//   hint     a hint or question: `kind`, `step` (shown / answered / ignored; `break`: a break started, so the page
//            can say how often a break hint was followed), `answer`, `after_s`
//
// No text anybody typed, no other app's screen, nothing sent anywhere: an Android accessibility service would be
// needed to see outside the app, and there is none (DECISIONS 713). Plain Dart: the widgets that watch the screen
// are in usage_watch.dart.
import 'activity.dart';
import 'files.dart';
import 'log.dart';

abstract final class Usage {
  static void _write(String ev, Map<String, Object?> fields) =>
      Logs.current?.write(LogKind.usage, {'ev': ev, ...fields});

  /// The screen now shown; also kept for the errors' context.
  static String? _screen;
  static String? get screen => _screen;

  static void view(String screen) {
    if (screen == _screen) return;
    _screen = screen;
    Logs.current?.screen = screen;
    _write('view', {'screen': screen});
  }

  static void app({required bool front}) => _write('app', {'state': front ? 'front' : 'back'});

  /// [long]: held half a second or more.
  static void tap({required String control, String? label, String? id, bool long = false}) => _write('tap', {
    'screen': _screen,
    'control': control,
    if (label != null && label.isNotEmpty) 'label': label,
    'id': ?id,
    if (long) 'long': true,
  });

  /// The home page's tab (`Signal`); the page name when the home page is on top is `tab:<it>`.
  static String homeTab = 'Record';

  /// A tab of the home page was chosen; [current]: the home page is on top (it is, unless a page covers it).
  static void tab(String label, {bool current = true}) {
    homeTab = label;
    if (current) view('tab:$label');
  }

  static void scroll({required String axis, required String dir, required int px, required int ms, double? reach}) =>
      _write('scroll', {
        'screen': _screen,
        'axis': axis,
        'dir': dir,
        'px': px,
        'ms': ms,
        if (reach != null) 'reach': double.parse(reach.toStringAsFixed(2)),
      });

  static void drag({required String dir, required int px, required int ms, int fingers = 1}) =>
      _write('drag', {'screen': _screen, 'dir': dir, 'px': px, 'ms': ms, if (fingers > 1) 'fingers': fingers});

  static void feature(String name, {required bool on, Duration? lasted}) => _write('feature', {
    'name': name,
    'on': on,
    if (lasted != null) 's': (lasted.inMilliseconds / 1000).round(),
  });

  static void setting(String key, Object? value) => _write('setting', {'key': key, 'value': value});

  /// A hint or a question ([kind]: `work-break`, `auto-start`, `sharp`, `study`, ...): [step] `shown`, `answered`
  /// (with [answer]), `ignored` (it went away unanswered), `break` (a work break started: was a hint followed?).
  static void hint(String kind, String step, {String? answer, Duration? after, Map<String, Object?>? data}) => _write(
    'hint',
    {
      'kind': kind,
      'step': step,
      'answer': ?answer,
      if (after != null) 'after_s': (after.inMilliseconds / 1000).round(),
      ...?data,
    },
  );

  /// Every feature's start and stop in this engine goes into the usage log (and a battery sample, metrics.dart).
  static void followActivity() => Activity.listen(_onActivity);

  static void _onActivity(String name, bool on, Duration? lasted) => feature(name, on: on, lasted: lasted);

  /// Tests.
  static void reset() {
    _screen = null;
    homeTab = 'Record';
    Activity.unlisten(_onActivity);
  }
}

/// A control's own words for the log: at most 40 characters, every digit as `#`, so "Night of 18 Nov" and "Night of
/// 19 Nov" count as one control and no number the owner measured is kept with it.
String usageLabel(String text) {
  final one = text.replaceAll(RegExp(r'\s+'), ' ').trim().replaceAll(RegExp(r'\d'), '#');
  return one.length <= 40 ? one : '${one.substring(0, 39)}…';
}
