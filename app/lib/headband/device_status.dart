// The one model of the headband for every screen (DECISIONS 854): the connection's state, each electrode's quality from
// the one judge (signal/quality.dart) and the headband's battery (battery_estimate.dart). The owner of the connection
// (connection.dart) keeps it current for the screen's engine; during a night it is made from the recorder's status.
// Shown by one widget, ui/device_status.dart.
import '../recorder/status.dart';
import '../signal/quality.dart';
import 'battery_estimate.dart';

enum LinkState {
  /// Nothing holds the headband.
  off,
  searching,
  connecting,
  checkingContact,

  /// Connected, no samples for a while (or none yet).
  waiting,
  live,
  reconnecting,
}

/// What uses the headband now.
enum BandUse { none, signal, session, night }

class DeviceStatus {
  const DeviceStatus({
    this.link = LinkState.off,
    this.use = BandUse.none,
    this.name = '',
    this.quality = const QualityVerdict(),
    this.battery = const BandBattery(),
    this.measuresContact = true,
    this.problem,
    this.lastData,
    this.lingering = false,
  });

  final LinkState link;
  final BandUse use;

  /// The headband's name as it gave it (empty: none yet).
  final String name;
  final QualityVerdict quality;
  final BandBattery battery;

  /// False for a board that has no contact reading (the DIY board).
  final bool measuresContact;

  /// Trouble in plain words (not found, a failure).
  final String? problem;
  final DateTime? lastData;

  /// Nobody uses the connection now; it is kept for a few minutes so the next start needs no search.
  final bool lingering;

  bool get connected => link == LinkState.live || link == LinkState.waiting || link == LinkState.checkingContact;

  /// The state in a word or two.
  String get word => switch (link) {
    LinkState.off => 'Not connected',
    LinkState.searching => 'Looking for the headband',
    LinkState.connecting => 'Connecting',
    LinkState.checkingContact => 'Checking contact',
    LinkState.waiting => 'Connected, no signal yet',
    LinkState.live => use == BandUse.night ? 'Recording' : 'Connected',
    LinkState.reconnecting => 'Headband lost, reconnecting',
  };

  DeviceStatus copyWith({
    LinkState? link,
    BandUse? use,
    String? name,
    QualityVerdict? quality,
    BandBattery? battery,
    bool? measuresContact,
    Object? problem = _keep,
    DateTime? lastData,
    bool? lingering,
  }) => DeviceStatus(
    link: link ?? this.link,
    use: use ?? this.use,
    name: name ?? this.name,
    quality: quality ?? this.quality,
    battery: battery ?? this.battery,
    measuresContact: measuresContact ?? this.measuresContact,
    problem: identical(problem, _keep) ? this.problem : problem as String?,
    lastData: lastData ?? this.lastData,
    lingering: lingering ?? this.lingering,
  );

  static const Object _keep = Object();

  /// The night as the recorder tells it: its phase, the electrodes' words as its judge sees them ([RecorderStatus.quality]
  /// while it records, else the start check's ohms), the battery from the shared track.
  static DeviceStatus fromRecorder(RecorderStatus s, {BandBattery battery = const BandBattery(), DateTime? now}) {
    final board = s.board;
    final at = s.nightStartMs > 0 ? DateTime.fromMillisecondsSinceEpoch(s.contactAtMs ?? s.nightStartMs) : null;
    final q = s.quality;
    final QualityVerdict verdict;
    if (q != null) {
      verdict = q.withOhms(s.contactOhms, s.contactOhms.isEmpty ? null : at);
    } else {
      verdict = QualityVerdict(
        electrodes: [
          for (final e in s.contactOhms.entries)
            ElectrodeQuality(name: e.key, grade: classifyOhms(e.value), ohms: e.value),
        ],
        ohmsAt: s.contactOhms.isEmpty ? null : at,
      );
    }
    final last = s.lastDataMs;
    final t = now ?? DateTime.now();
    final fresh = last != null && t.millisecondsSinceEpoch - last < 5000;
    return DeviceStatus(
      link: switch (s.phase) {
        Phase.idle || Phase.stopping => LinkState.off,
        Phase.searching => LinkState.searching,
        Phase.connecting => LinkState.connecting,
        Phase.checkingContact => LinkState.checkingContact,
        Phase.recording => fresh ? LinkState.live : LinkState.waiting,
        Phase.reconnecting => LinkState.reconnecting,
      },
      use: s.phase == Phase.idle ? BandUse.none : BandUse.night,
      quality: verdict,
      battery: battery,
      measuresContact: board == null,
      lastData: last == null ? null : DateTime.fromMillisecondsSinceEpoch(last),
    );
  }
}
