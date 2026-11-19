// One audio engine for the sounds that share it (DECISIONS row 465). flutter_soloud is one engine per app: a sound that
// closed the engine when it stopped closed it for everyone. On the sound-for-states screen a Listen preview still
// fading out did exactly that to the session that had just started on it, which then played silence for its whole
// length. Now each sound takes a share and gives it back: the first share opens the engine, the last one closes it, a
// sound that holds no share closes nothing, and takes and gives run one at a time.
import 'dart:async';

class EngineShare {
  EngineShare({required this.isUp, required this.close});

  /// The engine is open now.
  final bool Function() isUp;

  /// Closes the engine (every voice and source with it).
  final Future<void> Function() close;

  final Set<Object> _users = {};
  Future<void> _queue = Future<void>.value();

  /// Sounds holding a share now.
  int get users => _users.length;

  /// [user] takes a share; [open] opens the engine when it is not open yet (an error gives no share).
  Future<void> take(Object user, Future<void> Function() open) => _serial(() async {
    if (!isUp()) await open();
    _users.add(user);
  });

  /// [user] gives its share back (harmless when it holds none); the last share closes the engine.
  Future<void> give(Object user) => _serial(() async {
    if (!_users.remove(user) || _users.isNotEmpty) return;
    if (isUp()) await close();
  });

  Future<void> _serial(Future<void> Function() call) {
    final done = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        await call();
        done.complete();
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }
}
