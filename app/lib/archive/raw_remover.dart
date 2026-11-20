// What the Archive needs from the phone's one safe-delete helper (the owner's rules, 2026-11-20: a recording the laptop
// holds a checked copy of goes with one tap; one that exists only on this phone is the Danger zone's, twice confirmed;
// statistics stay unless "Everything" is picked there; DECISIONS 700-709).
//
// The helper is `recorder/remove.dart` with the laptop's acks (`recorder/acks.dart`, DECISIONS 690-699), the same code
// the Storage page and the move to the laptop use. The Archive talks to it through [RawRemover] alone (its tests can
// stand in for it), and [PhoneRawRemover] is that interface over the helper (DECISIONS 708):
// - a set's raw files are its samples (`<stamp>.f32`, or `.f32.gz` after a day) and its index (`<stamp>.idx`); its
//   `.log`, `.header.json` and `.markers.jsonl` and every report and summary made from it stay;
// - `<stamp>.removed.json` is written before the first file goes, so the nights keep their shape and the sleep
//   scoring never scores a night again from what is left;
// - refused in words, nothing deleted: no raw files left, a file being read on the phone or written in the last hour,
//   or (asked for) not every raw file checked on the laptop as it is now (`files/transfer/acks.json`). Without any ack
//   the phone has no word from any laptop.
import 'dart:io';

import '../recorder/acks.dart' show AckStore, LaptopCopy, ackedNow;
import '../recorder/packed.dart' show plainFileOf, rawOnDisk;
import '../recorder/remove.dart' as helper;

export '../recorder/nights.dart' show dataEndOf;
export '../recorder/remove.dart' show removeSettled, removedRecordFile, removedSuffix, whyByHand;

/// The laptop's word on a file, or a recording.
enum OnLaptop {
  /// It holds a checked copy of it as it is now.
  yes,

  /// It said nothing about it, or about other bytes.
  no,

  /// The phone has no word from any laptop (no acks at all): treated as [no] for deleting.
  unknown,
}

typedef RemoveResult = ({bool removed, String? refused, int freedBytes});

/// The Archive's view of the safe-delete helper.
abstract interface class RawRemover {
  /// The laptop's word on the phone's file [path] (relative to `files/`, `recordings/2026-11-18-231200.f32.gz`).
  OnLaptop onLaptop(String path);

  /// Why the raw files of the set of [f32] (its plain name) cannot go now, in words; null when they can.
  String? whyNotRaw(File f32, {required bool onlyIfOnLaptop, required DateTime now});

  /// Removes the set's samples and index, its record written first; refused in words with nothing deleted.
  RemoveResult removeRaw(File f32, {required bool onlyIfOnLaptop, required DateTime now});

  /// The set of [f32] lost its raw files: when its data ended and whether the laptop held them; null when it did not.
  ({DateTime? end, bool onLaptop})? removedOf(File f32);
}

/// [RawRemover] over the phone's safe-delete helper (`recorder/remove.dart`) and the laptop's acks, read once.
class PhoneRawRemover implements RawRemover {
  PhoneRawRemover(this.filesDir) : _acks = AckStore(filesDir).load();
  final Directory filesDir;
  final Map<String, LaptopCopy> _acks;

  @override
  OnLaptop onLaptop(String path) {
    if (_acks.isEmpty) return OnLaptop.unknown;
    return ackedNow(_acks, path, File('${filesDir.path}/$path')) ? OnLaptop.yes : OnLaptop.no;
  }

  /// The raw files of [f32]'s set on the phone: its samples (plain or packed) and its index.
  List<File> rawFilesOf(File f32) => helper.rawFilesOf(f32);

  @override
  String? whyNotRaw(File f32, {required bool onlyIfOnLaptop, required DateTime now}) =>
      helper.whyNotRemove(f32, onlyIfOnLaptop: onlyIfOnLaptop, acks: _acks, now: now);

  @override
  RemoveResult removeRaw(File f32, {required bool onlyIfOnLaptop, required DateTime now}) =>
      helper.removeRaw(f32, onlyIfOnLaptop: onlyIfOnLaptop, acks: _acks, why: helper.whyByHand, now: now);

  @override
  ({DateTime? end, bool onLaptop})? removedOf(File f32) {
    if (rawOnDisk(plainFileOf(f32)) != null) return null;
    final r = helper.removedRecordOf(f32);
    if (r == null) return null;
    final end = r.endMs;
    return (end: end == null ? null : DateTime.fromMillisecondsSinceEpoch(end), onLaptop: r.onLaptop);
  }
}
