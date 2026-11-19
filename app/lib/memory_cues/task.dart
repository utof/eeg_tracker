// The memory cues' evening task (DECISIONS 501): objects at places on a board, the object-location task of the classic
// sound-cue study (Rudoy 2009) that the 13-lab replication (ManyBeds) re-tests. Half the objects come with one soft
// sound, half with the other; at night only one of the two sounds is played (or none, on a silent night; plan.dart).
// In the evening: each object shown at its place with its sound, then learning rounds (place it, see where it was,
// hear its sound again; an object placed close leaves; at most 3 rounds), then the evening test (place each, no
// sound, no help). In the morning the same test again. The score is the distance between where you put an object
// and its place, in board widths: the cued half against the other half, overnight.
// Pure: a random source in, a session out; the screens run the clock and the sound, store.dart keeps the files.
import 'dart:math' as math;

import '../sleep/report.dart' show isoLocal;
import 'objects.dart';

/// Planning values (DECISIONS 501).
abstract final class TaskRule {
  /// Objects a session (half with each sound).
  static const int objects = 32;

  /// The board's height against its width; places at least [edge] from its sides and [minApart] from each other
  /// (board widths).
  static const double aspect = 1.25, edge = 0.07, minApart = 0.14;

  /// Within this of its place counts as close (about a fingertip on a phone); a close placement in learning ends that
  /// object's learning.
  static const double hitRadius = 0.15;
  static const int learnRounds = 3;

  /// Each object shown with its sound for this long in the first look, with a short gap.
  static const int studyMs = 3000, studyGapMs = 500;
}

/// A place on the board, in board widths from its top left corner (y up to [TaskRule.aspect]).
typedef BoardPoint = ({double x, double y});

/// An object, its place and its sound (0 or 1).
class MemoryItem {
  const MemoryItem({required this.object, required this.x, required this.y, required this.sound});
  final String object;
  final double x, y;
  final int sound;

  Map<String, Object?> toJson() => {'object': object, 'x': _r(x), 'y': _r(y), 'sound': sound};

  static MemoryItem? fromJson(Object? j) {
    if (j is! Map) return null;
    final o = j['object'], x = j['x'], y = j['y'], s = j['sound'];
    if (o is! String || x is! num || y is! num || (s != 0 && s != 1)) return null;
    return MemoryItem(object: o, x: x.toDouble(), y: y.toDouble(), sound: s as int);
  }
}

/// One placement while learning.
typedef Placement = ({String object, int round, double x, double y, int ms});

double _r(double v) => (v * 10000).round() / 10000;

/// An evening: the objects, how the learning went, the evening test, the loudness of each sound, and when it was
/// complete (the test and the loudness done): only a complete session can be cued at night.
class MemorySession {
  const MemorySession({
    required this.id,
    required this.made,
    required this.items,
    required this.studyOrder,
    required this.boardDp,
    this.learn = const [],
    this.evening = const {},
    this.eveningEnd,
    this.levels,
    this.mediaVolume,
    this.mediaVolumeMax,
    this.completed,
  });

  /// The session's name: when it was drawn, yyyy-MM-dd-HHmmss local time.
  final String id;
  final DateTime made;
  final List<MemoryItem> items;

  /// The order of the first look.
  final List<String> studyOrder;

  /// The board's width on the screen it was learned on (dp), for the distances in millimetres.
  final double boardDp;
  final List<Placement> learn;

  /// The evening test: where each object was put.
  final Map<String, BoardPoint> evening;
  final DateTime? eveningEnd;

  /// Each sound's "just heard" loudness, a share of the media volume.
  final List<double>? levels;
  final int? mediaVolume, mediaVolumeMax;
  final DateTime? completed;

  bool get isComplete => completed != null && levels != null && evening.length == items.length;

  MemoryItem itemOf(String object) => items.firstWhere((i) => i.object == object);

  MemorySession copyWith({
    double? boardDp,
    List<Placement>? learn,
    Map<String, BoardPoint>? evening,
    DateTime? eveningEnd,
    List<double>? levels,
    int? mediaVolume,
    int? mediaVolumeMax,
    DateTime? completed,
  }) => MemorySession(
    id: id,
    made: made,
    items: items,
    studyOrder: studyOrder,
    boardDp: boardDp ?? this.boardDp,
    learn: learn ?? this.learn,
    evening: evening ?? this.evening,
    eveningEnd: eveningEnd ?? this.eveningEnd,
    levels: levels ?? this.levels,
    mediaVolume: mediaVolume ?? this.mediaVolume,
    mediaVolumeMax: mediaVolumeMax ?? this.mediaVolumeMax,
    completed: completed ?? this.completed,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'made': isoLocal(made),
    'boardDp': boardDp,
    'items': [for (final i in items) i.toJson()],
    'studyOrder': studyOrder,
    'learn': [
      for (final p in learn) {'object': p.object, 'round': p.round, 'x': _r(p.x), 'y': _r(p.y), 'ms': p.ms},
    ],
    'evening': {
      for (final e in evening.entries) e.key: [_r(e.value.x), _r(e.value.y)],
    },
    'eveningEnd': eveningEnd == null ? null : isoLocal(eveningEnd!),
    'levels': levels,
    'mediaVolume': mediaVolume,
    'mediaVolumeMax': mediaVolumeMax,
    'completed': completed == null ? null : isoLocal(completed!),
  };

  static MemorySession? fromJson(Object? j) {
    if (j is! Map || j['version'] != 1) return null;
    final id = j['id'], made = DateTime.tryParse('${j['made']}')?.toLocal(), it = j['items'], so = j['studyOrder'];
    final dp = j['boardDp'];
    if (id is! String || made == null || it is! List || so is! List || dp is! num) return null;
    final items = [for (final x in it) ?MemoryItem.fromJson(x)];
    if (items.length != it.length || items.isEmpty) return null;
    final lv = j['levels'], mv = j['mediaVolume'], mm = j['mediaVolumeMax'];
    final levels = lv is List && lv.length == 2 && lv.every((v) => v is num && v > 0 && v <= 1)
        ? [for (final v in lv) (v as num).toDouble()]
        : null;
    final ev = j['evening'];
    return MemorySession(
      id: id,
      made: made,
      items: items,
      studyOrder: [for (final o in so) '$o'],
      boardDp: dp.toDouble(),
      learn: [
        if (j['learn'] is List)
          for (final p in j['learn'] as List)
            if (p is Map && p['object'] is String && p['round'] is int && p['x'] is num && p['y'] is num)
              (
                object: p['object'] as String,
                round: p['round'] as int,
                x: (p['x'] as num).toDouble(),
                y: (p['y'] as num).toDouble(),
                ms: p['ms'] is int ? p['ms'] as int : 0,
              ),
      ],
      evening: pointsFromJson(ev),
      eveningEnd: DateTime.tryParse('${j['eveningEnd']}')?.toLocal(),
      levels: levels,
      mediaVolume: mv is int ? mv : null,
      mediaVolumeMax: mm is int ? mm : null,
      completed: DateTime.tryParse('${j['completed']}')?.toLocal(),
    );
  }
}

/// `{"object": [x, y]}` as written by a session or a morning; anything else left out.
Map<String, BoardPoint> pointsFromJson(Object? j) => {
  if (j is Map)
    for (final e in j.entries)
      if (e.value is List && (e.value as List).length == 2 && (e.value as List).every((v) => v is num))
        '${e.key}': (x: ((e.value as List)[0] as num).toDouble(), y: ((e.value as List)[1] as num).toDouble()),
};

String sessionId(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

/// A new session: [TaskRule.objects] objects not in [avoid] when the pool allows, each at a place on the board, half
/// with each sound (chosen at random, so neither the places nor the order tell the sounds apart).
MemorySession drawSession(math.Random r, DateTime made, {Set<String> avoid = const {}, double boardDp = 345}) {
  final fresh = [
    for (final o in memoryObjects)
      if (!avoid.contains(o.name)) o.name,
  ];
  final pool = fresh.length >= TaskRule.objects ? fresh : [for (final o in memoryObjects) o.name];
  pool.shuffle(r);
  final names = pool.take(TaskRule.objects).toList();
  final places = _places(r);
  final sounds = [for (var i = 0; i < TaskRule.objects; i++) i < TaskRule.objects ~/ 2 ? 0 : 1]..shuffle(r);
  final items = [
    for (var i = 0; i < TaskRule.objects; i++)
      MemoryItem(object: names[i], x: places[i].x, y: places[i].y, sound: sounds[i]),
  ];
  final order = [for (final i in items) i.object]..shuffle(r);
  return MemorySession(id: sessionId(made), made: made, items: items, studyOrder: order, boardDp: boardDp);
}

/// Places at least [TaskRule.minApart] apart, drawn one by one (a fresh start when the board fills up first).
List<BoardPoint> _places(math.Random r) {
  const lo = TaskRule.edge, hiX = 1 - TaskRule.edge, hiY = TaskRule.aspect - TaskRule.edge;
  while (true) {
    final out = <BoardPoint>[];
    var tries = 0;
    while (out.length < TaskRule.objects && tries < 20000) {
      tries++;
      final p = (x: lo + r.nextDouble() * (hiX - lo), y: lo + r.nextDouble() * (hiY - lo));
      if (out.every((q) => _dist(p, q) >= TaskRule.minApart)) out.add(p);
    }
    if (out.length == TaskRule.objects) return out;
  }
}

double _dist(BoardPoint a, BoardPoint b) => math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));

/// What an object left unplaced counts as: half the board's diagonal, about where a guess lands on average.
final double missedError = math.sqrt(1 + TaskRule.aspect * TaskRule.aspect) / 2;

/// How far [p] is from [item]'s place, in board widths.
double placementError(MemoryItem item, BoardPoint p) => _dist((x: item.x, y: item.y), p);

bool isClose(MemoryItem item, BoardPoint p) => placementError(item, p) <= TaskRule.hitRadius;

/// The mean distance of sound [sound]'s objects in a test ([taps]); an object not placed counts as [missedError].
double halfError(MemorySession s, Map<String, BoardPoint> taps, int sound) {
  final half = s.items.where((i) => i.sound == sound).toList();
  var sum = 0.0;
  for (final i in half) {
    final t = taps[i.object];
    sum += t == null ? missedError : placementError(i, t);
  }
  return sum / half.length;
}

/// The mean distance over every object.
double meanError(MemorySession s, Map<String, BoardPoint> taps) => (halfError(s, taps, 0) + halfError(s, taps, 1)) / 2;

/// Objects placed close.
int closeCount(MemorySession s, Map<String, BoardPoint> taps) => s.items.where((i) {
  final t = taps[i.object];
  return t != null && isClose(i, t);
}).length;

/// Board widths in millimetres on the screen the session was learned on (a dp is 1/160 inch).
double toMm(MemorySession s, double boardWidths) => boardWidths * s.boardDp * 25.4 / 160;

/// The learning rounds: every object once in a random order, then each round only the objects not yet placed close,
/// at most [TaskRule.learnRounds] rounds.
class LearnRounds {
  LearnRounds(this.session, this._r) {
    _queue = [for (final i in session.items) i.object]..shuffle(_r);
  }
  final MemorySession session;
  final math.Random _r;
  late List<String> _queue;
  final List<String> _missed = [];
  final List<Placement> placements = [];
  int round = 1;
  final Stopwatch _clock = Stopwatch()..start();

  /// The object to place now; null when learning is over.
  String? get current => _queue.isEmpty ? null : _queue.first;
  bool get done => _queue.isEmpty;

  /// Objects still in this round (with the current one) and later ones.
  int get left => _queue.length;

  /// The current object was put at [p]: whether it was close.
  bool place(BoardPoint p) {
    final o = _queue.removeAt(0);
    placements.add((object: o, round: round, x: p.x, y: p.y, ms: _clock.elapsedMilliseconds));
    final close = isClose(session.itemOf(o), p);
    if (!close) _missed.add(o);
    if (_queue.isEmpty && _missed.isNotEmpty && round < TaskRule.learnRounds) {
      round++;
      _queue = [..._missed]..shuffle(_r);
      _missed.clear();
    }
    return close;
  }
}
