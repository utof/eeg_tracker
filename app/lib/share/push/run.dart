// One push (DECISIONS 840-849): the phone sends the paired laptop what it lacks, with no server and no notification.
//
// Android's job (PushJob.kt) runs this about every 15 minutes on Wi-Fi and soon after a recording ends; it also runs
// during a recording, so the laptop's copy keeps growing even when nothing can reach the phone's own server.
// 1. Only with Share on Wi-Fi on and a laptop paired, on a Wi-Fi network, to an address inside that network.
// 2. `hello`: the laptop proves the pairing's key and says whether it is on the network where it paired. Only then
//    is this the home Wi-Fi (DECISIONS 752's rule, asked from the phone's side); nothing about the files is said
//    before that.
// 3. `begin`: the phone's list (the one Share on Wi-Fi serves) and its open questions before deleting; the laptop
//    answers which bytes it lacks. 4. `chunk`: those bytes, at most 4 MB a request, never a file the phone is asking
//    about. 5. `commit`: the laptop checks and files them by pull_phone.py's own rules and answers with its acks and
//    proofs, which the phone takes exactly as it takes `POST /ack` and `POST /recheck`.
// A push cut off anywhere loses nothing: the laptop keeps what arrived and the next one goes on from there.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../recorder/acks.dart' show ackPathOf;
import '../../recorder/recheck.dart';
import '../isolate.dart' show writeCopied;
import '../protocol.dart';
import '../server.dart';
import 'client.dart';
import 'plan.dart';
import 'state.dart';

/// How a run ended, in plain words for the log.
typedef PushResult = ({bool sent, String why, int files, int bytes, int acked});

/// Makes the client for a laptop address (tests give their own).
typedef PushClientMaker = PushClient Function(String key, String host);

/// A run uploads for at most this long (Android gives a job about ten minutes), then lets the laptop file what came.
const Duration pushUploadFor = Duration(minutes: 6);

PushClient _client(String key, String host) => PushClient(key: key, host: host, port: pushPort);

/// Runs one push now. [soon]: asked for by the app (a recording ended), not the regular job. Never throws.
Future<PushResult> runPush({
  required String filesDir,
  required ShareConfig config,
  required WifiNets wifi,
  required bool soon,
  int? sharePort,
  PushClientMaker client = _client,
  DateTime Function() clock = DateTime.now,
  Duration uploadFor = pushUploadFor,
  Future<bool> Function(String host)? reachable,
  void Function(String line)? log,
}) async {
  PushResult skip(String why) => (sent: false, why: why, files: 0, bytes: 0, acked: 0);
  final nowMs = clock().millisecondsSinceEpoch;
  final laptop = config.laptop;
  if (laptop == null || !config.activeAt(nowMs)) return skip('sharing is off or no laptop is paired');
  final nets = parseLanNets(wifi.nets);
  if (nets.isEmpty) return skip('not on Wi-Fi');
  var state = PushState.read(filesDir);
  if (!pushDue(state, nowMs, soon: soon)) return skip('too soon after the last try');
  state = state.started(nowMs)..write(filesDir);

  PushResult failed(String why) {
    state = state.failed(why)..write(filesDir);
    return skip(why);
  }

  PushClient? c;
  try {
    // where the laptop is: where it last asked from, where it paired, then a look around the network
    String? notHome;
    for (final host in laptopCandidates(readLaptopAt(filesDir), laptop.host, nets)) {
      final found = await _greet(client(laptop.key, host));
      if (found.client != null) {
        c = found.client;
        break;
      }
      notHome ??= found.notHome;
    }
    if (c == null && notHome == null && sweepDue(state, nowMs)) {
      state = state.swept(nowMs)..write(filesDir);
      final skipHosts = {...laptopCandidates(readLaptopAt(filesDir), laptop.host, nets)};
      for (final host in await _answering([for (final n in nets) ...sweepAddresses(n, skip: skipHosts)], reachable)) {
        final found = await _greet(client(laptop.key, host));
        if (found.client != null) {
          c = found.client;
          writeLaptopAt(filesDir, host);
          break;
        }
      }
    }
    if (c == null) return failed(notHome ?? 'the laptop did not answer on this Wi-Fi');

    final server = ShareServer(
      filesDir: Directory(filesDir),
      token: config.token,
      key: laptop.key,
      hashCache: File('$filesDir/cache/share-hashes.json'),
    );
    final list = await server.fileList();
    final asks = server.questions()['asks'] as List? ?? const [];
    final begun = await c.begin(list, asks, sharePort);
    final session = begun['session'];
    if (session is! String) return failed('the laptop gave no session');
    final listed = listedBytes(list);
    final held = RecheckStore(Directory(filesDir)).open().keys.toSet();
    final wants = usableWants(begun['want'], {
      for (final e in listed.entries)
        if (!held.contains(ackPathOf(e.key))) e.key: e.value,
    });
    final max = begun['max_chunk'] is int ? begun['max_chunk'] as int : pushChunkMax;
    final until = clock().add(uploadFor);
    var sentBytes = 0, sentFiles = 0, cut = false;
    for (final w in wants) {
      if (cut) break;
      final done = await _sendFile(c, session, filesDir, w, listed[w.path]!, max, () => clock().isAfter(until));
      sentBytes += done.bytes;
      if (done.whole) sentFiles++;
      cut = done.cut;
    }
    final committed = await c.commit(session);
    final acks = committed['acks'], proofs = committed['proofs'];
    var acked = 0;
    if (acks is List && acks.isNotEmpty) {
      final r = await server.takeAcks(utf8.encode(jsonEncode({'v': 1, 'files': acks})));
      acked = (r.json['acked'] as List?)?.length ?? 0;
    }
    if (proofs is List && proofs.isNotEmpty) server.takeProofs(utf8.encode(jsonEncode({'v': 1, 'proofs': proofs})));
    final end = clock().millisecondsSinceEpoch;
    state = state.sent(end, sentFiles, sentBytes)..write(filesDir);
    if (sentBytes > 0 || acked > 0) writeCopied(filesDir, end, 'laptop');
    log?.call('sent to the laptop: $sentFiles files, ${(sentBytes / 1e6).toStringAsFixed(1)} MB${cut ? ' (more next time)' : ''}');
    return (sent: true, why: cut ? 'more next time' : '', files: sentFiles, bytes: sentBytes, acked: acked);
  } on PushError catch (e) {
    return failed(switch (e.failure) {
      PushFailure.noAnswer => 'the laptop stopped answering',
      PushFailure.notTheLaptop => 'the answer did not prove the pairing',
      PushFailure.busy => 'the laptop is busy copying',
      PushFailure.refused => 'the laptop refused: ${e.why}',
    });
  } catch (e) {
    return failed('failed: ${'$e'.length > 120 ? '$e'.substring(0, 120) : e}');
  } finally {
    c?.close();
  }
}

/// The laptop at one address: a client when it proved the key and is at home; [notHome] when it proved the key
/// elsewhere (then nowhere else is asked); neither when nothing or something else answered.
Future<({PushClient? client, String? notHome})> _greet(PushClient c) async {
  try {
    if (await c.hello()) return (client: c, notHome: null);
    c.close();
    return (client: null, notHome: 'the laptop is not on its home network');
  } on PushError catch (e) {
    c.close();
    // a refusal that proved the key is the paired laptop's own word: nowhere else is asked
    final word = e.failure != PushFailure.refused
        ? null
        : e.why == 'time'
        ? 'the phone\'s and the laptop\'s clocks differ by more than 5 minutes'
        : e.why == 'not at home'
        ? 'the laptop is not on its home network'
        : 'the laptop refused: ${e.why}';
    return (client: null, notHome: word);
  }
}

/// The addresses of [hosts] where the receiver's port takes a connection (32 at a time, 300 ms each).
Future<List<String>> _answering(List<String> hosts, Future<bool> Function(String host)? reachable) async {
  final probe = reachable ?? _open;
  final out = <String>[];
  for (var k = 0; k < hosts.length; k += 32) {
    final part = hosts.sublist(k, k + 32 > hosts.length ? hosts.length : k + 32);
    final got = await Future.wait(part.map(probe));
    for (var i = 0; i < part.length; i++) {
      if (got[i]) out.add(part[i]);
    }
    if (out.length >= 4) break; // a home network has one laptop; four doors are enough to ask
  }
  return out;
}

Future<bool> _open(String host) async {
  try {
    (await Socket.connect(host, pushPort, timeout: const Duration(milliseconds: 300))).destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Sends what the laptop lacks of one file. [whole]: all of it arrived; [cut]: the time ran out, or the laptop
/// stopped answering this file's requests in a way the next push sorts out.
Future<({int bytes, bool whole, bool cut})> _sendFile(
  PushClient c,
  String session,
  String filesDir,
  PushWant w,
  int bytes,
  int max,
  bool Function() late,
) async {
  RandomAccessFile? f;
  var sent = 0;
  try {
    f = await File('$filesDir/${w.path}').open();
    var want = w;
    var retried = false;
    for (var at = want.from + want.have; at < bytes;) {
      if (late()) return (bytes: sent, whole: false, cut: true);
      final n = bytes - at < max ? bytes - at : max;
      await f.setPosition(at);
      final data = await f.read(n);
      if (data.length != n) return (bytes: sent, whole: false, cut: false); // shorter than listed: the next list says
      try {
        await c.chunk(session, want.path, at, data);
      } on PushError catch (e) {
        final staged = e.json?['staged'];
        if (e.failure == PushFailure.refused && e.why == 'offset' && staged is int && !retried && want.from + staged < bytes) {
          retried = true; // the laptop holds another amount than it said (an answer was lost): go on from there
          want = (path: want.path, from: want.from, have: staged);
          at = want.from + staged;
          continue;
        }
        if (e.failure == PushFailure.refused) return (bytes: sent, whole: false, cut: false); // this file only
        rethrow;
      }
      sent += n;
      at += n;
    }
    return (bytes: sent, whole: true, cut: false);
  } on FileSystemException {
    return (bytes: sent, whole: false, cut: false); // gone or unreadable meanwhile
  } finally {
    await f?.close();
  }
}
