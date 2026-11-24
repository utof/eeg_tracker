// What the recorder isolate tells the screen, about once a second. Plain maps cross the isolate port.
import '../detectors/drift_off.dart' show DriftState;
import '../spans/span.dart' show Span;
import 'contact.dart';

enum Phase { idle, searching, connecting, checkingContact, recording, reconnecting, stopping }

const int sampleRateHz = 250;

/// Length of one cell of the night strip: half an hour of clock time.
const int slotMs = 30 * 60 * 1000;

class RecorderStatus {
  const RecorderStatus({
    this.phase = Phase.idle,
    this.nightStartMs = 0,
    this.nightSamples = 0,
    this.lastDataMs,
    this.rssi,
    this.battery,
    this.contactOhms = const {},
    this.runs = 0,
    this.note = '',
    this.slots = const {},
    this.sentMs = 0,
    this.drift,
    this.lightsOffMs,
    this.driftOnsetMs,
    this.alarm,
    this.board,
    this.rec = const RecordingLive(),
    this.quality,
    this.contactAtMs,
  });

  /// The recording's id, whether a sleep span runs, and its spans (Record first).
  final RecordingLive rec;

  final Phase phase;

  /// Each electrode's word from the recorder's judge while it records (signal/quality.dart); null before.
  final QualityVerdict? quality;

  /// When [contactOhms] was measured (unix ms); null: at the night's start.
  final int? contactAtMs;

  /// When Start was pressed (unix ms); 0 when no night is running.
  final int nightStartMs;

  /// Samples saved this night, all file sets together.
  final int nightSamples;

  /// Arrival time of the newest batch (unix ms).
  final int? lastDataMs;

  /// Signal strength in dBm, as the scan saw it before connecting (the SDK gives no live value).
  final int? rssi;

  /// Headband battery in percent.
  final int? battery;

  /// From the start-of-night contact check; null = no reading or off the head (infinite).
  final Map<String, double?> contactOhms;

  /// File sets written this night (a new one after every drop or restart).
  final int runs;

  /// Last notable event in plain words.
  final String note;

  /// Samples received per half hour of clock time (key = unix ms ~/ 30 min).
  final Map<int, int> slots;

  final int sentMs;

  /// The live drift-off detector's state (live_drift.dart); null while it is off.
  final DriftState? drift;

  /// When Lights off was tapped tonight (unix ms); null while lights off counts from the night's first sample.
  final int? lightsOffMs;

  /// The detector's first "probably asleep" onset since lights off (unix ms).
  final int? driftOnsetMs;

  /// Tonight's smart alarm (alarm/live_alarm.dart); null without one.
  final AlarmStatus? alarm;

  /// The DIY board's channels, mode and levels while one is connected (headband/diy/); null for the BrainBit.
  final BoardLive? board;

  double get minutesRecorded => nightSamples / sampleRateHz / 60;

  Contact contactOf(String channel) => classifyOhms(contactOhms[channel]);

  bool get hasContact => contactOhms.isNotEmpty;

  RecorderStatus copyWith({
    Phase? phase,
    int? nightStartMs,
    int? nightSamples,
    int? lastDataMs,
    int? rssi,
    int? battery,
    Map<String, double?>? contactOhms,
    int? runs,
    String? note,
    Map<int, int>? slots,
    BoardLive? board,
    RecordingLive? rec,
    QualityVerdict? quality,
    int? contactAtMs,
  }) => RecorderStatus(
    phase: phase ?? this.phase,
    nightStartMs: nightStartMs ?? this.nightStartMs,
    nightSamples: nightSamples ?? this.nightSamples,
    lastDataMs: lastDataMs ?? this.lastDataMs,
    rssi: rssi ?? this.rssi,
    battery: battery ?? this.battery,
    contactOhms: contactOhms ?? this.contactOhms,
    runs: runs ?? this.runs,
    note: note ?? this.note,
    slots: slots ?? this.slots,
    sentMs: sentMs,
    drift: drift,
    lightsOffMs: lightsOffMs,
    driftOnsetMs: driftOnsetMs,
    alarm: alarm,
    board: board ?? this.board,
    rec: rec ?? this.rec,
    quality: quality ?? this.quality,
    contactAtMs: contactAtMs ?? this.contactAtMs,
  );

  /// The same status with the smart alarm replaced (null: none).
  RecorderStatus withAlarm(AlarmStatus? alarm) => RecorderStatus(
    phase: phase,
    nightStartMs: nightStartMs,
    nightSamples: nightSamples,
    lastDataMs: lastDataMs,
    rssi: rssi,
    battery: battery,
    contactOhms: contactOhms,
    runs: runs,
    note: note,
    slots: slots,
    sentMs: sentMs,
    drift: drift,
    lightsOffMs: lightsOffMs,
    driftOnsetMs: driftOnsetMs,
    alarm: alarm,
    board: board,
    rec: rec,
    quality: quality,
    contactAtMs: contactAtMs,
  );

  /// The same status with the drift-off fields replaced (null clears them).
  RecorderStatus withDrift({DriftState? drift, int? lightsOffMs, int? onsetMs}) => RecorderStatus(
    phase: phase,
    nightStartMs: nightStartMs,
    nightSamples: nightSamples,
    lastDataMs: lastDataMs,
    rssi: rssi,
    battery: battery,
    contactOhms: contactOhms,
    runs: runs,
    note: note,
    slots: slots,
    sentMs: sentMs,
    drift: drift,
    lightsOffMs: lightsOffMs,
    driftOnsetMs: onsetMs,
    alarm: alarm,
    board: board,
    rec: rec,
    quality: quality,
    contactAtMs: contactAtMs,
  );

  Map<String, Object?> toMap({required int nowMs}) => {
    'kind': 'status',
    'phase': phase.name,
    'nightStartMs': nightStartMs,
    'nightSamples': nightSamples,
    'lastDataMs': lastDataMs,
    'rssi': rssi,
    'battery': battery,
    'contact': [for (final n in channelNames) _finite(contactOhms[n])],
    'contactKnown': contactOhms.isNotEmpty,
    'runs': runs,
    'note': note,
    'slots': [
      for (final e in slots.entries) ...[e.key, e.value],
    ],
    'sentMs': nowMs,
    'drift': drift?.name,
    'lightsOffMs': lightsOffMs,
    'driftOnsetMs': driftOnsetMs,
    'alarm': alarm?.toMap(),
    'board': board?.toMap(),
    'rec': rec.toMap(),
    'quality': quality?.toMap(),
    'contactAtMs': contactAtMs,
  };

  /// Parses a message from the recorder; returns null for anything else.
  static RecorderStatus? fromMap(Object? data) {
    if (data is! Map || data['kind'] != 'status') return null;
    final phase = Phase.values.where((p) => p.name == data['phase']).firstOrNull ?? Phase.idle;
    final contact = data['contact'];
    final flat = data['slots'];
    final known = data['contactKnown'] == true && contact is List && contact.length == channelNames.length;
    return RecorderStatus(
      phase: phase,
      nightStartMs: _int(data['nightStartMs']) ?? 0,
      nightSamples: _int(data['nightSamples']) ?? 0,
      lastDataMs: _int(data['lastDataMs']),
      rssi: _int(data['rssi']),
      battery: _int(data['battery']),
      contactOhms: known
          ? {for (var i = 0; i < channelNames.length; i++) channelNames[i]: _double(contact[i])}
          : const {},
      runs: _int(data['runs']) ?? 0,
      note: data['note'] is String ? data['note'] as String : '',
      slots: flat is List && flat.length.isEven
          ? {
              for (var i = 0; i + 1 < flat.length; i += 2)
                if (flat[i] is int && flat[i + 1] is int) flat[i] as int: flat[i + 1] as int,
            }
          : const {},
      sentMs: _int(data['sentMs']) ?? 0,
      drift: DriftState.values.where((d) => d.name == data['drift']).firstOrNull,
      lightsOffMs: _int(data['lightsOffMs']),
      driftOnsetMs: _int(data['driftOnsetMs']),
      alarm: AlarmStatus.fromMap(data['alarm']),
      board: BoardLive.fromMap(data['board']),
      rec: RecordingLive.fromMap(data['rec']),
      quality: QualityVerdict.fromMap(data['quality']),
      contactAtMs: _int(data['contactAtMs']),
    );
  }
}

/// The DIY board as the night screen sees it (headband/diy/board.dart): its channel names, what it records ("test
/// signal: ... not EEG"), each channel's swing over the last second, and its link.
class BoardLive {
  const BoardLive({
    required this.names,
    required this.mode,
    required this.modeText,
    required this.notEeg,
    this.levelsUv = const [],
    this.fs = sampleRateHz,
    this.link = '',
    this.sender,
    this.lost = 0,
    this.boardMissed = 0,
    this.bad = 0,
  });

  /// CH1.. in order, from the montage setting.
  final List<String> names;

  /// `test`, `short`, `synthetic` or `electrodes`, and the sentence for it.
  final String mode;
  final String modeText;

  /// The chip records its own test signal, its shorted inputs or made-up data: whatever the names say, not EEG.
  final bool notEeg;

  /// Peak to peak over the last second per channel in microvolts; null before the first second.
  final List<double?> levelsUv;

  /// The board's samples a second.
  final int fs;

  /// How the frames arrive (`UDP port 9000 ...`) and from whom.
  final String link;
  final String? sender;

  /// Samples missing in this capture, of those the board's own misses, and damaged datagrams.
  final int lost;
  final int boardMissed;
  final int bad;

  Map<String, Object?> toMap() => {
    'names': names,
    'mode': mode,
    'modeText': modeText,
    'notEeg': notEeg,
    'levelsUv': [for (final v in levelsUv) v == null || v.isNaN || v.isInfinite ? null : v],
    'fs': fs,
    'link': link,
    'sender': sender,
    'lost': lost,
    'boardMissed': boardMissed,
    'bad': bad,
  };

  static BoardLive? fromMap(Object? m) {
    if (m is! Map || m['names'] is! List || m['mode'] is! String) return null;
    final names = [for (final n in m['names'] as List) if (n is String) n];
    final levels = m['levelsUv'];
    return BoardLive(
      names: names,
      mode: m['mode'] as String,
      modeText: m['modeText'] is String ? m['modeText'] as String : '',
      notEeg: m['notEeg'] != false,
      levelsUv: levels is List ? [for (final v in levels) _double(v)] : const [],
      fs: m['fs'] is int && (m['fs'] as int) > 0 ? m['fs'] as int : sampleRateHz,
      link: m['link'] is String ? m['link'] as String : '',
      sender: m['sender'] is String ? m['sender'] as String : null,
      lost: _int(m['lost']) ?? 0,
      boardMissed: _int(m['boardMissed']) ?? 0,
      bad: _int(m['bad']) ?? 0,
    );
  }
}

/// The smart alarm as the screen sees it: the window, what the live model does, and the wake.
class AlarmStatus {
  const AlarmStatus({required this.endMs, required this.windowMin, required this.phase, this.stage, this.wakeMs, this.why, this.note});

  /// Wake by (unix ms), and the window's minutes before it.
  final int endMs;
  final int windowMin;

  /// `waiting`, `scoring`, `woke`, `ended`, `off` (alarm/live_alarm.dart `AlarmPhase`).
  final String phase;

  /// The newest live stage, 2 minutes behind (W N1 N2 N3 R gap).
  final String? stage;

  /// When the rule woke you and why (`light`, `dream`, `awake`, `window end`).
  final int? wakeMs;
  final String? why;

  /// Why the live model is off, in a sentence.
  final String? note;

  Map<String, Object?> toMap() => {
    'endMs': endMs,
    'windowMin': windowMin,
    'phase': phase,
    'stage': stage,
    'wakeMs': wakeMs,
    'why': why,
    'note': note,
  };

  static AlarmStatus? fromMap(Object? m) {
    if (m is! Map || m['endMs'] is! int || m['windowMin'] is! int || m['phase'] is! String) return null;
    return AlarmStatus(
      endMs: m['endMs'] as int,
      windowMin: m['windowMin'] as int,
      phase: m['phase'] as String,
      stage: m['stage'] is String ? m['stage'] as String : null,
      wakeMs: _int(m['wakeMs']),
      why: m['why'] is String ? m['why'] as String : null,
      note: m['note'] is String ? m['note'] as String : null,
    );
  }
}

double? _finite(double? v) => v == null || v.isNaN || v.isInfinite ? null : v;
int? _int(Object? v) => v is num ? v.toInt() : null;
double? _double(Object? v) => v is num ? v.toDouble() : null;

/// The running recording as the screen needs it (Record first, DECISIONS 880-899): its id (null until its first file
/// set opens), whether the sleep kit is attached, and its spans in order.
class RecordingLive {
  const RecordingLive({this.id, this.sleep = true, this.spans = const []});

  final String? id;

  /// The sleep kit runs: a sleep span is open. A status from a recorder of before reads as true.
  final bool sleep;
  final List<Span> spans;

  /// The open span of [kind], or of any kind.
  Span? open([String? kind]) => spans.where((s) => !s.closed && (kind == null || s.kind == kind)).lastOrNull;

  /// The open sleep span (kind `sleep` or `nap`).
  Span? get openSleep => spans.where((s) => !s.closed && s.isSleep).lastOrNull;

  Map<String, Object?> toMap() => {
    'id': id,
    'sleep': sleep,
    'spans': [for (final s in spans) s.toLine(s.start)],
  };

  static RecordingLive fromMap(Object? m) {
    if (m is! Map) return const RecordingLive();
    final l = m['spans'];
    return RecordingLive(
      id: m['id'] is String ? m['id'] as String : null,
      sleep: m['sleep'] != false,
      spans: [
        if (l is List)
          for (final x in l)
            if (x is Map) ?Span.fromLine(x),
      ],
    );
  }
}
