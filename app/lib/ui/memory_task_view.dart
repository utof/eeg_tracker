// The memory cues' evening task and morning test (DECISIONS 501, 508; DESIGN.md "Memory cues"): one board, one
// instruction line, the watch strip's cells for progress. The board is a `track` field with faint hairlines in a 4 x 5
// grid (a spatial reference to place against), the objects ink Material icons. Built from a TaskViewModel only, so
// tests render every phase; memory_cues_screen.dart runs the clock, the taps and the sound.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../memory_cues/objects.dart';
import '../memory_cues/task.dart';
import 'form_parts.dart' show Para, PinnedAction;
import 'lucid_view.dart' show StackQuestion;
import 'theme.dart';

enum TaskPhase { intro, study, learn, test, loudness, heard, done, result }

/// The morning's numbers against the evening's: objects placed close, and the mean distance in board widths.
typedef TestNumbers = ({int closeEvening, int closeMorning, double distEvening, double distMorning});

class TaskViewModel {
  const TaskViewModel({
    required this.morning,
    required this.phase,
    required this.session,
    this.object,
    this.tap,
    this.showPlace = false,
    this.close,
    this.done = const {},
    this.round = 1,
    this.loudnessSound = 0,
    this.loudnessStep = 0,
    this.heard,
    this.morningTaps = const {},
    this.numbers,
  });

  /// The morning test (no study, no learning, no loudness) rather than the evening task.
  final bool morning;
  final TaskPhase phase;
  final MemorySession session;

  /// The object shown or to place now.
  final String? object;

  /// The last tap on the board (learning's answer, or the test's mark).
  final BoardPoint? tap;

  /// Learning's answer: the object at its place, with whether the tap was close.
  final bool showPlace;
  final bool? close;

  /// Objects seen (study), learned (placed close while learning) or placed (test): their cells fill.
  final Set<String> done;
  final int round;
  final int loudnessSound, loudnessStep;
  final String? heard;
  final Map<String, BoardPoint> morningTaps;
  final TestNumbers? numbers;

  TaskViewModel copyWith({
    TaskPhase? phase,
    String? object,
    BoardPoint? tap,
    bool clearTap = false,
    bool? showPlace,
    bool? close,
    Set<String>? done,
    int? round,
    int? loudnessSound,
    int? loudnessStep,
    String? heard,
    Map<String, BoardPoint>? morningTaps,
    TestNumbers? numbers,
    MemorySession? session,
  }) => TaskViewModel(
    morning: morning,
    phase: phase ?? this.phase,
    session: session ?? this.session,
    object: object ?? this.object,
    tap: clearTap ? null : (tap ?? this.tap),
    showPlace: showPlace ?? this.showPlace,
    close: clearTap ? null : (close ?? this.close),
    done: done ?? this.done,
    round: round ?? this.round,
    loudnessSound: loudnessSound ?? this.loudnessSound,
    loudnessStep: loudnessStep ?? this.loudnessStep,
    heard: heard ?? this.heard,
    morningTaps: morningTaps ?? this.morningTaps,
    numbers: numbers ?? this.numbers,
  );
}

class TaskView extends StatelessWidget {
  const TaskView({
    super.key,
    required this.model,
    required this.onStart,
    required this.onTap,
    required this.onHeardSound,
    required this.onStop,
    required this.onHeardAnswer,
    required this.onSave,
    required this.onDone,
  });

  final TaskViewModel model;
  final VoidCallback onStart, onHeardSound, onStop, onSave, onDone;
  final ValueChanged<BoardPoint> onTap;
  final ValueChanged<String> onHeardAnswer;

  @override
  Widget build(BuildContext context) {
    final m = model;
    return Scaffold(
      appBar: AppBar(title: Text(m.morning ? 'Morning test' : 'Evening task')),
      body: switch (m.phase) {
        TaskPhase.intro => _intro(context),
        TaskPhase.study || TaskPhase.learn || TaskPhase.test => _board(context),
        TaskPhase.loudness => _loudness(context),
        TaskPhase.heard => _heard(context),
        TaskPhase.done => _done(context),
        TaskPhase.result => _result(context),
      },
      bottomNavigationBar: PinnedAction(child: _action()),
    );
  }

  Widget _action() {
    final m = model;
    return switch (m.phase) {
      TaskPhase.intro => FilledButton.icon(
        onPressed: onStart,
        icon: const Icon(Icons.grid_view_outlined),
        label: const Text('Start'),
      ),
      TaskPhase.study ||
      TaskPhase.learn ||
      TaskPhase.test => OutlinedButton(onPressed: onStop, child: const Text('Stop')),
      TaskPhase.loudness => Row(
        children: [
          Expanded(
            flex: 3,
            child: FilledButton(onPressed: onHeardSound, child: const Text('I hear it')),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: OutlinedButton(onPressed: onStop, child: const Text('Stop')),
          ),
        ],
      ),
      TaskPhase.heard => FilledButton(
        onPressed: m.heard == null ? null : onSave,
        child: Text(m.heard == null ? 'Answer the question' : 'Save'),
      ),
      TaskPhase.done || TaskPhase.result => FilledButton(onPressed: onDone, child: const Text('Done')),
    };
  }

  Widget _intro(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.45);
    if (model.morning) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        children: [
          Text('Where was each one?', style: text.headlineSmall),
          Para(
            'The same ${TaskRule.objects} objects as last evening, one at a time. Tap where it sat. No help and no '
            'sound this time. About 2 minutes.',
          ),
          Para('Then one question about the night.', color: Night.inkMuted),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        Text('Learn where ${TaskRule.objects} objects sit', style: text.headlineSmall),
        Para('About 12 minutes, before Start night. Four steps:', color: Night.inkMuted),
        const SizedBox(height: 8),
        const _Step(
          1,
          'Look',
          'Each object appears at its place with a soft sound: a bell for some, a knock for others.',
        ),
        const _Step(2, 'Learn', 'Put each one back. You see where it was and hear its sound again. Up to 3 rounds.'),
        const _Step(3, 'Test', 'Put each one back once more, with no help and no sound.'),
        const _Step(
          4,
          'Loudness',
          'Put the phone where it stays tonight and lie down. Tap when you just hear each sound.',
          last: true,
        ),
        const SizedBox(height: 16),
        Text(
          'Set the phone\'s media volume now so the sound is soft but clear, and leave it there for the night.',
          style: muted,
        ),
      ],
    );
  }

  Widget _board(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    final obj = m.object == null ? null : memoryObject(m.object!);
    final item = m.object == null ? null : m.session.itemOf(m.object!);
    final (String line, String sub) = switch (m.phase) {
      TaskPhase.study => ('Look where it sits.', ''),
      TaskPhase.learn when m.showPlace => (
        m.close == true ? 'Close. Here it was.' : 'Here it was.',
        'Round ${m.round} of ${TaskRule.learnRounds}',
      ),
      TaskPhase.learn => ('Where was it? Tap its place.', 'Round ${m.round} of ${TaskRule.learnRounds}'),
      _ => ('Where was it? Tap its place.', ''),
    };
    final marks = <BoardMark>[
      if (m.phase == TaskPhase.study && item != null) BoardMark.object(item.object, (x: item.x, y: item.y)),
      if (m.phase == TaskPhase.learn && m.showPlace && item != null) ...[
        BoardMark.place((x: item.x, y: item.y)),
        if (m.tap != null) BoardMark.line((x: item.x, y: item.y), m.tap!),
        BoardMark.object(item.object, (x: item.x, y: item.y)),
      ],
      if ((m.phase == TaskPhase.test || (m.phase == TaskPhase.learn && !m.showPlace)) && m.tap != null)
        BoardMark.tap(m.tap!),
    ];
    final asking = m.phase != TaskPhase.study && !m.showPlace;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TaskCells(
            objects: [for (final i in m.session.items) i.object],
            done: m.done,
            current: m.object,
            label: switch (m.phase) {
              TaskPhase.study => 'Seen',
              TaskPhase.learn => 'Learned',
              _ => 'Placed',
            },
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              if (m.phase != TaskPhase.study) ...[
                SizedBox(
                  width: 56,
                  height: 56,
                  child: obj == null
                      ? null
                      : Icon(
                          obj.icon,
                          key: asking ? const ValueKey('memory-tray') : null,
                          size: 44,
                          color: asking ? Night.ink : Night.inkMuted,
                          semanticLabel: obj.name,
                        ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(line, style: text.titleMedium),
                    Text(
                      sub,
                      style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: MemoryBoard(marks: marks, onTap: asking ? onTap : null),
            ),
          ),
        ],
      ),
    );
  }

  Widget _loudness(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    final name = m.loudnessSound == 0 ? 'the bell' : 'the knock';
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        Text('Tap "I hear it" as soon as you hear $name.', style: text.headlineSmall),
        Para(
          'Lie down with the phone where it stays tonight. The sound plays every few seconds, a little louder each '
          'time. Tonight it plays a little quieter than where you tap.',
          color: Night.inkMuted,
        ),
        const SizedBox(height: 24),
        Text(
          'Sound ${m.loudnessSound + 1} of 2, try ${m.loudnessStep}',
          style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
        ),
      ],
    );
  }

  Widget _heard(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        Text('One question about the night', style: text.headlineSmall),
        StackQuestion<String>(
          question: 'Did you hear a sound in the night?',
          choices: const [
            ('no', 'No'),
            ('yes', 'Yes, I think so'),
            ('woke', 'Yes, it woke me'),
            ('unsure', 'Not sure'),
          ],
          value: m.heard,
          onChanged: onHeardAnswer,
        ),
      ],
    );
  }

  Widget _done(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        Text('Ready for tonight', style: text.headlineSmall),
        const Para(
          'Start the night within 3 hours. The sounds play only in light or deep sleep, quietly, in the first hours, '
          'and some nights not at all. You are not told which.',
        ),
        const Para('Tomorrow morning: the same board again, about 2 minutes.', color: Night.inkMuted),
      ],
    );
  }

  Widget _result(BuildContext context) {
    final m = model, text = Theme.of(context).textTheme, n = m.numbers;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        Text('Saved', style: text.headlineSmall),
        if (n != null) ...[
          const SizedBox(height: 12),
          const _Row3('', 'Evening', 'Morning', head: true),
          _Row3('Placed close, of ${TaskRule.objects}', '${n.closeEvening}', '${n.closeMorning}'),
          _Row3(
            'Distance on average, % of the board',
            boardPercent(n.distEvening).replaceAll(' %', ''),
            boardPercent(n.distMorning).replaceAll(' %', ''),
            last: true,
          ),
        ],
        const SizedBox(height: 20),
        DriftBoard(session: m.session, taps: m.morningTaps),
        const SizedBox(height: 10),
        Text(
          'Each object at its place; the line runs to where you put it this morning.',
          style: text.bodyMedium?.copyWith(color: Night.inkMuted),
        ),
        const Para(
          'Which half had a sound last night, if any, stays hidden until night 12. One night says little: forgetting '
          'overnight is normal.',
          color: Night.inkMuted,
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.n, this.title, this.text, {this.last = false});
  final int n;
  final String title, text;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: last
          ? null
          : const BoxDecoration(
              border: Border(bottom: BorderSide(color: Night.rule)),
            ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Text(
              '$n',
              style: t.titleMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.titleMedium),
                const SizedBox(height: 2),
                Text(text, style: t.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A label, then two values right-aligned in tabular figures (the evening, the morning).
class _Row3 extends StatelessWidget {
  const _Row3(this.label, this.a, this.b, {this.head = false, this.last = false});
  final String label, a, b;
  final bool head, last;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final num = head ? t.bodyMedium?.copyWith(color: Night.inkMuted) : t.titleMedium?.copyWith(fontFeatures: tabular);
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: last
          ? null
          : const BoxDecoration(
              border: Border(bottom: BorderSide(color: Night.rule)),
            ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 10,
            child: Text(label, style: t.bodyLarge?.copyWith(color: Night.inkMuted)),
          ),
          Expanded(
            flex: 5,
            child: Text(a, textAlign: TextAlign.right, style: num),
          ),
          Expanded(
            flex: 5,
            child: Text(b, textAlign: TextAlign.right, style: num),
          ),
        ],
      ),
    );
  }
}

/// Progress as the watch strip's own cells: one per object, two rows of 16 with a wider gap every 8, `saved` when
/// done, the current one outlined green, `track` still to come; a muted label and the count above.
class TaskCells extends StatelessWidget {
  const TaskCells({super.key, required this.objects, required this.done, required this.current, required this.label});
  final List<String> objects;
  final Set<String> done;
  final String? current;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    // the current object fills the next free cell; done ones fill from the left
    final count = objects.where(done.contains).length;
    return Semantics(
      label: '$label: $count of ${objects.length}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(label, style: t.bodyMedium?.copyWith(color: Night.inkMuted)),
              const Spacer(),
              Text('$count of ${objects.length}', style: t.bodyMedium?.copyWith(fontFeatures: tabular)),
            ],
          ),
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (context, c) {
              const gap = 3.0, blockGap = 9.0, perRow = 16;
              final cell = ((c.maxWidth - 14 * gap - blockGap) / perRow).clamp(8.0, 20.0);
              final rows = (objects.length / perRow).ceil();
              return Column(
                children: [
                  for (var r = 0; r < rows; r++)
                    Padding(
                      padding: EdgeInsets.only(bottom: r == rows - 1 ? 0 : 4),
                      child: Row(
                        children: [
                          for (var j = 0; j < perRow && r * perRow + j < objects.length; j++) ...[
                            if (j > 0) SizedBox(width: j % 8 == 0 ? blockGap : gap),
                            _cell(r * perRow + j, count, cell),
                          ],
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _cell(int i, int count, double size) {
    final filled = i < count, isCurrent = current != null && i == count;
    return Container(
      width: size,
      height: size * 0.8,
      decoration: BoxDecoration(
        color: filled ? Night.saved : Night.track,
        borderRadius: BorderRadius.circular(3),
        border: isCurrent ? Border.all(color: Night.live, width: 1.5) : null,
      ),
    );
  }
}

/// One thing drawn on the board.
class BoardMark {
  const BoardMark.object(this.object, this.at) : to = null, kind = 0;
  const BoardMark.tap(this.at) : object = null, to = null, kind = 1;
  const BoardMark.line(this.at, BoardPoint this.to) : object = null, kind = 2;
  const BoardMark.place(this.at) : object = null, to = null, kind = 3;
  final String? object;
  final BoardPoint at;
  final BoardPoint? to;

  /// 0 an object (ink icon), 1 a tap (small ink dot), 2 a hairline from the ring around [at] to a dot at [to] (none
  /// when [to] is inside the ring: put right on its place), 3 a place (an ink-muted ring just outside the icon).
  final int kind;
}

/// The board: a `track` field with faint hairlines in a 4 x 5 grid, as wide as it can be while its height (1.25 of its
/// width) fits; [onTap] gives the place tapped in board widths.
class MemoryBoard extends StatelessWidget {
  const MemoryBoard({super.key, required this.marks, this.onTap, this.maxHeight});
  final List<BoardMark> marks;
  final ValueChanged<BoardPoint>? onTap;
  final double? maxHeight;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final h = math.min(c.maxHeight, maxHeight ?? double.infinity);
      final w = math.min(c.maxWidth, h.isFinite ? h / TaskRule.aspect : c.maxWidth);
      final icon = w * 0.1;
      final sized = SizedBox(
        width: w,
        height: w * TaskRule.aspect,
        child: Stack(
          clipBehavior: Clip.antiAlias,
          children: [
            Positioned.fill(child: CustomPaint(painter: _BoardPainter(marks, w))),
            for (final mk in marks)
              if (mk.kind == 0 && memoryObject(mk.object!) != null)
                Positioned(
                  left: mk.at.x * w - icon / 2,
                  top: mk.at.y * w - icon / 2,
                  child: Icon(memoryObject(mk.object!)!.icon, size: icon, color: Night.ink, semanticLabel: mk.object),
                ),
          ],
        ),
      );
      // its own size inside a stretching column, centred
      final board = Align(alignment: Alignment.topCenter, heightFactor: 1, child: sized);
      if (onTap == null) return board;
      return Align(
        alignment: Alignment.topCenter,
        heightFactor: 1,
        child: Semantics(
          label: 'The board: tap where the object sat',
          button: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => onTap!((
              x: (d.localPosition.dx / w).clamp(0.0, 1.0),
              y: (d.localPosition.dy / w).clamp(0.0, TaskRule.aspect),
            )),
            child: sized,
          ),
        ),
      );
    },
  );
}

/// The place ring's radius on a board [w] wide: just outside the icon (a tenth of the width) by 3 dp.
double boardRing(double w) => w * 0.05 + 3;

class _BoardPainter extends CustomPainter {
  _BoardPainter(this.marks, this.w);
  final List<BoardMark> marks;
  final double w;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6));
    canvas.clipRRect(r); // a dot at the edge stays on the board
    canvas.drawRRect(r, Paint()..color = Night.track);
    final grid = Paint()
      ..color = Night.rule.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      canvas.drawLine(Offset(size.width * i / 4, 0), Offset(size.width * i / 4, size.height), grid);
    }
    for (var i = 1; i < 5; i++) {
      canvas.drawLine(Offset(0, size.height * i / 5), Offset(size.width, size.height * i / 5), grid);
    }
    Offset o(BoardPoint p) => Offset(p.x * w, p.y * w);
    final ring = boardRing(w);
    for (final m in marks) {
      switch (m.kind) {
        case 2:
          final a = o(m.at), b = o(m.to!), d = b - a;
          if (d.distance <= ring) break; // put right on its place: the ring says it
          canvas.drawLine(
            a + d / d.distance * ring,
            b,
            Paint()
              ..color = Night.inkMuted
              ..strokeWidth = 1.5,
          );
          canvas.drawCircle(b, 4, Paint()..color = Night.ink);
        case 1:
          canvas.drawCircle(o(m.at), 4, Paint()..color = Night.ink);
        case 3:
          canvas.drawCircle(
            o(m.at),
            ring,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = Night.inkMuted,
          );
      }
    }
  }

  @override
  bool shouldRepaint(_BoardPainter old) => old.marks != marks || old.w != w;
}

/// Where memory drifted overnight (the page's signature): each object at its place in a faint ring, a hairline from
/// the ring to where it was put in the morning test and a dot there; no colour for either half.
class DriftBoard extends StatelessWidget {
  const DriftBoard({super.key, required this.session, required this.taps, this.maxHeight});
  final MemorySession session;
  final Map<String, BoardPoint> taps;
  final double? maxHeight;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: maxHeight,
    child: MemoryBoard(
      maxHeight: maxHeight,
      marks: [
        for (final i in session.items) ...[
          BoardMark.place((x: i.x, y: i.y)),
          if (taps[i.object] != null) BoardMark.line((x: i.x, y: i.y), taps[i.object]!),
        ],
        for (final i in session.items) BoardMark.object(i.object, (x: i.x, y: i.y)),
      ],
    ),
  );
}
