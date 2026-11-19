// "Try these" progress (DECISIONS 340): which cards are done or skipped, the owner's notes, and what the app ticked by
// itself, app-private in `files/try-these/` and exported with everything else (Export data's "everything except",
// DECISIONS 150), so the assistant reads the notes after an import (`_local/phone/try-these/`):
//   progress.json   one entry per card the owner or the app touched: title, state, when, by whom, the note
//   events.jsonl    one line per change of state (done, skipped, reopened, seen by the app), with the note then
// A note typed without a change of state rewrites progress.json only. Plain Dart: tested on a plain folder.
import 'dart:convert';
import 'dart:io';

import '../sleep/report.dart' show isoLocal;
import 'cards.dart';

const int tryProgressVersion = 1;

/// `files/try-these` for the app's recordings folder.
Directory tryDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/try-these');

enum TryState { open, done, skipped }

class CardProgress {
  const CardProgress({this.state = TryState.open, this.at, this.byApp = false, this.seen, this.note = '', this.noteAt});

  final TryState state;

  /// When the state last changed.
  final DateTime? at;

  /// Ticked by the app (lib/try_these/seen.dart), not by a tap.
  final bool byApp;

  /// What the app saw, in a sentence ("A check-in saved on Fri 20 Nov.").
  final String? seen;
  final String note;
  final DateTime? noteAt;

  CardProgress copyWith({TryState? state, DateTime? at, bool? byApp, String? seen, String? note, DateTime? noteAt}) =>
      CardProgress(
        state: state ?? this.state,
        at: at ?? this.at,
        byApp: byApp ?? this.byApp,
        seen: seen ?? this.seen,
        note: note ?? this.note,
        noteAt: noteAt ?? this.noteAt,
      );

  Map<String, Object?> toJson(String id) => {
    'title': tryCards.where((c) => c.id == id).firstOrNull?.title,
    'state': state.name,
    'at': at == null ? null : isoLocal(at!),
    'by': byApp ? 'app' : 'owner',
    'seen': seen,
    'note': note,
    'note_changed': noteAt == null ? null : isoLocal(noteAt!),
  };

  static CardProgress? fromJson(Object? j) {
    if (j is! Map) return null;
    final state = TryState.values.where((s) => s.name == j['state']).firstOrNull;
    if (state == null) return null;
    DateTime? time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
    return CardProgress(
      state: state,
      at: time(j['at']),
      byApp: j['by'] == 'app',
      seen: j['seen'] is String ? j['seen'] as String : null,
      note: j['note'] is String ? j['note'] as String : '',
      noteAt: time(j['note_changed']),
    );
  }
}

class TryStore {
  TryStore(this.dir);
  final Directory dir;

  File get _progress => File('${dir.path}/progress.json');
  File get _events => File('${dir.path}/events.jsonl');

  /// Card id -> its progress; a card never touched has no entry. A missing or damaged file reads as nothing done.
  Map<String, CardProgress> load() {
    try {
      final j = jsonDecode(_progress.readAsStringSync());
      final cards = j is Map ? j['cards'] : null;
      if (cards is! Map) return {};
      return {
        for (final e in cards.entries)
          if (e.key is String && CardProgress.fromJson(e.value) != null)
            e.key as String: CardProgress.fromJson(e.value)!,
      };
    } on Object {
      return {};
    }
  }

  void _save(Map<String, CardProgress> all, DateTime at) {
    dir.createSync(recursive: true);
    final tmp = File('${_progress.path}.tmp');
    final body = {
      'version': tryProgressVersion,
      'changed': isoLocal(at),
      'cards': {for (final e in all.entries) e.key: e.value.toJson(e.key)},
    };
    tmp.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(body), flush: true);
    tmp.renameSync(_progress.path);
  }

  void _log(String id, String event, DateTime at, CardProgress p) {
    dir.createSync(recursive: true);
    final line = {
      'at': isoLocal(at),
      'card': id,
      'title': tryCards.where((c) => c.id == id).firstOrNull?.title,
      'event': event,
      if (p.seen != null && p.byApp) 'seen': p.seen,
      if (p.note.isNotEmpty) 'note': p.note,
    };
    _events.writeAsStringSync('${jsonEncode(line)}\n', mode: FileMode.append, flush: true);
  }

  /// Done, Skip, or back to open ("Not done yet"); [note] replaces the note when given.
  CardProgress mark(String id, TryState state, {required DateTime at, String? note}) {
    final all = load();
    final old = all[id] ?? const CardProgress();
    final next = CardProgress(
      state: state,
      at: at,
      note: note ?? old.note,
      noteAt: note != null && note != old.note ? at : old.noteAt,
    );
    all[id] = next;
    _save(all, at);
    _log(id, state == TryState.open ? 'reopened' : state.name, at, next);
    return next;
  }

  /// The note as typed (saved a moment after the last key); no log line.
  void setNote(String id, String note, {required DateTime at}) {
    final all = load();
    final old = all[id] ?? const CardProgress();
    if (old.note == note && all.containsKey(id)) return;
    all[id] = old.copyWith(note: note, noteAt: at);
    _save(all, at);
  }

  /// Ticks the cards the app saw done ([seen]: id -> what it saw), only those nobody has touched yet: a card the owner
  /// skipped or reopened stays as he left it. Returns the ids it ticked.
  List<String> applySeen(Map<String, String> seen, {required DateTime at}) {
    final all = load();
    final ticked = [
      for (final id in seen.keys)
        if (!all.containsKey(id)) id,
    ];
    if (ticked.isEmpty) return ticked;
    for (final id in ticked) {
      all[id] = CardProgress(state: TryState.done, at: at, byApp: true, seen: seen[id]);
    }
    _save(all, at);
    for (final id in ticked) {
      _log(id, 'seen by the app', at, all[id]!);
    }
    return ticked;
  }
}

/// A cell of the try ledger: one per card, in card order.
enum LedgerMark { done, skipped, next, open }

/// The page from the cards and the progress: the tally, the next stop, the open cards by group, the finished ones.
class TryPage {
  TryPage._(this.cards, this.progress, this.next, this.groups, this.finished);

  final List<TryCard> cards;
  final Map<String, CardProgress> progress;

  /// The first open card, or null when every card is done or skipped.
  final TryCard? next;

  /// Open cards by group, in order; a group with none open is left out.
  final List<({TryGroup group, List<TryCard> cards})> groups;

  /// Done and skipped cards, in card order.
  final List<TryCard> finished;

  TryState stateOf(String id) => progress[id]?.state ?? TryState.open;
  int get total => cards.length;
  int get tried => cards.where((c) => stateOf(c.id) == TryState.done).length;
  int get skipped => cards.where((c) => stateOf(c.id) == TryState.skipped).length;
  String get tally => '$tried of $total tried';

  /// The card's number: its place in the order, from 1.
  int number(String id) => cards.indexWhere((c) => c.id == id) + 1;

  LedgerMark mark(String id) => switch (stateOf(id)) {
    TryState.done => LedgerMark.done,
    TryState.skipped => LedgerMark.skipped,
    TryState.open => id == next?.id ? LedgerMark.next : LedgerMark.open,
  };
}

TryPage buildTryPage(List<TryCard> cards, Map<String, CardProgress> progress) {
  TryState state(TryCard c) => progress[c.id]?.state ?? TryState.open;
  final open = [
    for (final c in cards)
      if (state(c) == TryState.open) c,
  ];
  return TryPage._(
    cards,
    progress,
    open.firstOrNull,
    [
      for (final g in TryGroup.values)
        if (open.any((c) => c.group == g))
          (
            group: g,
            cards: [
              for (final c in open)
                if (c.group == g) c,
            ],
          ),
    ],
    [
      for (final c in cards)
        if (state(c) != TryState.open) c,
    ],
  );
}

/// The main screen's line under "Try these": the tally and the next stop; [page] null before the progress is read.
String entryLine(TryPage? page) {
  if (page == null) {
    return '${tryCards.length} things in the app to try, one at a time, with what to tell the assistant.';
  }
  final next = page.next;
  if (next == null) {
    return 'All ${page.total} ${page.skipped == 0 ? 'tried' : 'tried or skipped'}. Your notes go out with Export data.';
  }
  return '${page.tally}. Next: ${next.title}, ${next.takes.toLowerCase()}.';
}
