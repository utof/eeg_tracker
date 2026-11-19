// The sound-control stream: what one analysis step (0.1 s) of a session told the sound to do. Both session
// kinds reduce to it: meditation (the bed's calm, jaw roughness, a bell) and alpha-theta (the stream-to-ocean
// mix, roughness, a chime or a gong). The replay check (DECISIONS rows 100-103) replays this stream from one
// of your own earlier live sessions, never the raw EEG, so the reward rate matches by itself.
import '../feedback/session.dart' show stepS;

/// The two kinds of training session. [name] is the word used in files.
enum SessionKind {
  meditation('meditation'),
  alphaTheta('alpha-theta');

  const SessionKind(this.name);
  final String name;

  static SessionKind? byName(Object? s) {
    for (final k in values) {
      if (k.name == s) return k;
    }
    return null;
  }
}

/// One step of the stream. [level]: the bed's main setting, 0..1 (meditation: calm; alpha-theta: 0 = stream,
/// 1 = ocean). [rough]: jaw tension roughening the sound, 0..1. [reward]: null, 'bell', 'chime' or 'gong'.
/// [gated]: a muscle, blink, signal, drowsiness (meditation) or sleep gate held the sound neutral.
typedef Control = ({double level, double rough, String? reward, bool gated});

const Set<String> rewardNames = {'bell', 'chime', 'gong'};

/// The run part of a saved session log (SessionLog.toJson()) as a control stream: for meditation the core's
/// step lines after its 'calibration' line, up to where the sound stopped for the silent minutes (the app's
/// 'silentBlock' note; meditation/silent_block.dart), for alpha-theta its 'at' lines. Throws [FormatException]
/// when the file is not a session of that kind.
List<Control> controlStream(Map<String, Object?> saved, SessionKind kind) {
  final lines = saved['lines'], header = saved['header'];
  if (lines is! List || header is! Map) throw const FormatException('not a session file');
  final protocol = header['protocol'] ?? SessionKind.meditation.name;
  if (protocol != kind.name) {
    throw FormatException('a ${protocol is String ? protocol : '?'} session, not ${kind.name}');
  }
  final out = <Control>[];
  final soundUntil = _silentFrom(saved['info']);
  var run = false;
  for (final e in lines) {
    if (e is! Map) continue;
    final type = e['type'];
    if (kind == SessionKind.meditation) {
      if (type == 'calibration') run = true;
      if (!run || type != 'step') continue;
      final n = e['n'];
      if (soundUntil != null && n is int && n > soundUntil) break;
      out.add((
        level: _unit(e['calm']),
        rough: _unit(e['rough']),
        reward: e['ring'] == 1 ? 'bell' : null,
        gated: e['v'] != null || e['q'] != 'good',
      ));
    } else if (type == 'at') {
      final r = e['r'];
      out.add((
        level: _unit(e['mix']),
        rough: _unit(e['rough']),
        reward: r is String && rewardNames.contains(r) ? r : null,
        gated: e['g'] == 1,
      ));
    }
  }
  return out;
}

/// The sample after which the sound stopped for the silent minutes, or null (none in this session).
int? _silentFrom(Object? info) {
  if (info is! List) return null;
  for (final i in info) {
    if (i is! Map) continue;
    final b = i['silentBlock'];
    if (b is Map && b['fromN'] is int) return b['fromN'] as int;
  }
  return null;
}

double _unit(Object? v) {
  if (v is! num || !v.isFinite) throw const FormatException('session file: a sound setting is not a number');
  return v.toDouble().clamp(0.0, 1.0);
}

/// Seconds a control stream lasts.
double streamSeconds(List<Control> s) => s.length * stepS;

/// Rewards per minute in a control stream (0 for an empty one).
double rewardsPerMinute(List<Control> s) =>
    s.isEmpty ? 0 : s.where((c) => c.reward != null).length / (streamSeconds(s) / 60);
