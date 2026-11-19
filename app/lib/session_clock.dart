// Session time that a clock correction cannot move (DECISIONS row 462): the seconds since lights off, the 45-minute
// caps, the nap's wake and the gaps between arrivals come from a monotonic Stopwatch, while the wall clock still names
// the files and stamps the markers. Android sets the wall clock from the network now and then (after a reboot, a
// time-zone trip, a drifting clock), and a jump of minutes would otherwise wake a nap, end a session or mark a hole.

/// Elapsed time that never jumps. Only differences of [now] mean anything.
class SessionClock {
  /// [monotonic]: a test's own elapsed time. Without it, a test's [wall] clock is read through its differences (as
  /// the sessions did before), and the phone's own clock through a Stopwatch.
  SessionClock({DateTime Function()? wall, Duration Function()? monotonic})
    : _read = monotonic ?? (wall == null ? _stopwatch : () => wall().difference(_epoch));

  static final Stopwatch _sw = Stopwatch()..start();
  static Duration _stopwatch() => _sw.elapsed;
  static final DateTime _epoch = DateTime.utc(2000);

  final Duration Function() _read;

  Duration get now => _read();

  /// Seconds from [since] (a [now] read earlier) until now.
  double secondsSince(Duration since) => (_read() - since).inMicroseconds / 1e6;
}
