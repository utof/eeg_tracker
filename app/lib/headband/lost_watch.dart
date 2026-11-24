// The headband-lost notices (DECISIONS 857; owner, 2026-11-20). During a night or a session, when no data has come
// from the headband for N minutes (5 to 10, chosen on the Headband connection page; 5 by default), the phone shows one
// notice; when data returns, one "back" notice; and one when the headband's battery is estimated empty. Never after
// Stop: a recording or session that ended on purpose expects no data. The laptop's tray shows the same as a desktop
// notice from the phone's /state (`alert`), when the phone is paired and reachable and the tray's notifications are on.
// Pure timing here; the phone's notification and /state are handed in.
import 'dart:convert';
import 'dart:io';

enum BandNoticeKind { lost, back, battery }

class BandNotice {
  const BandNotice({required this.kind, required this.at, required this.title, required this.text});
  final BandNoticeKind kind;
  final DateTime at;
  final String title;
  final String text;

  /// For /state's `alert` (scripts/laptop_work.py reads it): the kind, when (unix seconds) and the words.
  Map<String, Object?> toMap() => {
    'kind': kind.name,
    'at': at.millisecondsSinceEpoch ~/ 1000,
    'title': title,
    'text': text,
  };
}

/// The setting, in `files/headband/settings.json` (read by the screen's engine and the recorder's).
class LostSettings {
  const LostSettings({this.afterMin = defaultMin, this.on = true});
  static const int minMin = 5, maxMin = 10, defaultMin = 5;

  /// Minutes without data before the notice.
  final int afterMin;
  final bool on;

  Duration get after => Duration(minutes: afterMin.clamp(minMin, maxMin));

  static File fileFor(String recordingsDir) => File('${Directory(recordingsDir).parent.path}/headband/settings.json');

  static LostSettings load(File f) {
    try {
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map) return const LostSettings();
      final m = j['lostAfterMin'];
      return LostSettings(afterMin: m is int ? m.clamp(minMin, maxMin) : defaultMin, on: j['lostNotice'] != false);
    } catch (_) {
      return const LostSettings();
    }
  }

  void save(File f) {
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({'lostAfterMin': afterMin, 'lostNotice': on}));
    } catch (_) {}
  }
}

/// Watches one engine's recording or session. Call [update] about every second.
class LostWatch {
  LostWatch({required this.settings, required this.tell, required this.what, DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  /// Read at each loss, so a change on the settings page counts from the next one.
  final LostSettings Function() settings;
  final void Function(BandNotice notice) tell;

  /// What waits for the headband, for the words: "The recording", "The session".
  final String what;
  final DateTime Function() _now;
  DateTime? _quietFrom;
  bool _told = false;
  Duration? _after;

  /// The "lost" notice was given and the headband is not back yet.
  bool get told => _told;

  /// [expecting]: a night or session runs and was not stopped; [dataFresh]: a batch came in the last seconds.
  /// [batteryEmpty]: the battery estimate is at empty (for the lost notice's words).
  void update({required bool expecting, required bool dataFresh, bool batteryEmpty = false}) {
    final now = _now();
    if (!expecting) {
      // stopped on purpose, or nothing runs: no notice, and none about "back" later
      _quietFrom = null;
      _told = false;
      return;
    }
    if (dataFresh) {
      if (_told) {
        final from = _quietFrom;
        final min = from == null ? null : now.difference(from).inMinutes;
        tell(
          BandNotice(
            kind: BandNoticeKind.back,
            at: now,
            title: 'Headband is back',
            text: min == null ? 'Data is coming in again.' : 'Data is coming in again after $min min.',
          ),
        );
      }
      _quietFrom = null;
      _told = false;
      return;
    }
    final from = _quietFrom ??= now;
    if (_told) return;
    final s = settings();
    final after = _after ??= s.after;
    if (!s.on || now.difference(from) < after) return;
    _told = true;
    _after = null;
    tell(
      BandNotice(
        kind: BandNoticeKind.lost,
        at: now,
        title: 'Headband lost',
        text:
            'No data from the headband for ${after.inMinutes} min. $what waits for it.'
            '${batteryEmpty ? ' Its battery is probably empty.' : ' Is it on your head and charged?'}',
      ),
    );
  }

  /// The battery estimate reached empty (the caller makes sure of once per charge).
  void batteryEmpty(int? percent) => tell(
    BandNotice(
      kind: BandNoticeKind.battery,
      at: _now(),
      title: 'Headband battery nearly empty',
      text: 'About ${percent ?? 5} % left by our estimate. Charge it soon.',
    ),
  );
}
