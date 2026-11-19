// The sharp-hours question (.impeccable/surfaces/app-lib-ui-sharp-hours-screen-dart.md; DECISIONS rows 284-285):
// "How sharp do you feel right now?" as five full-width rows, Very sharp at the top; one tap saves. Then, when the
// question suggested it (or you ask for it, up to 3 a day), alpha-theta's 1-minute reaction test. One decision on
// the screen at a time. Opened by tapping the notification, or Rate now on the Sharp hours page.
import 'dart:async';

import 'package:flutter/material.dart';

import '../alphatheta/rules.dart' show ReactionTest;
import '../phone.dart';
import '../sharp/page.dart' show testsToday;
import '../sharp/prompts.dart';
import '../sharp/schedule.dart';
import '../sharp/store.dart';
import 'form_parts.dart' show PinnedAction;
import 'reaction_test.dart';
import 'theme.dart';

enum QuestionStage { ask, saved, test }

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// The muted line under the question.
String askedWords(SharpLaunch? l) => l == null
    ? 'Rated from the page, not a question: it counts, but random questions tell more.'
    : 'Asked at ${_clock(l.shown ?? l.planned)}. One tap saves.';

class SharpQuestionView extends StatelessWidget {
  const SharpQuestionView({
    super.key,
    required this.stage,
    this.launch,
    this.saved,
    this.canTest = false,
    this.tested = false,
    this.onRate,
    this.onTest,
    this.onTestDone,
    this.onDone,
    this.error,
    this.testSeed,
  });

  final QuestionStage stage;
  final SharpLaunch? launch;
  final SharpRating? saved;

  /// A test may still be offered today; [tested]: one was finished on this page.
  final bool canTest, tested;
  final ValueChanged<int>? onRate;
  final VoidCallback? onTest, onDone;
  final ValueChanged<ReactionTest>? onTestDone;
  final String? error;
  final int? testSeed;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.45);
    final s = saved;
    final body = switch (stage) {
      QuestionStage.ask => <Widget>[
        Text('How sharp do you feel right now?', style: text.headlineSmall?.copyWith(height: 1.25)),
        const SizedBox(height: 8),
        Text(askedWords(launch), style: muted),
        const SizedBox(height: 20),
        for (var v = 5; v >= 1; v--) ...[
          if (v < 5) const SizedBox(height: 8),
          _ScaleRow(value: v, onTap: onRate == null ? null : () => onRate!(v)),
        ],
      ],
      QuestionStage.saved => <Widget>[
        Text('Saved: ${s!.sharp}, ${sharpWords[s.sharp - 1]}.', style: text.headlineSmall?.copyWith(height: 1.25)),
        const SizedBox(height: 8),
        Text('At ${_clock(s.at)}. Thank you; that is all.', style: muted),
        if (canTest) ...[
          const SizedBox(height: 24),
          Text(
            'If you have a minute: a reaction test measures your speed apart from how you feel.',
            style: text.bodyLarge?.copyWith(height: 1.45),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(onPressed: onTest, icon: const Icon(Icons.timer_outlined), label: const Text('1-minute reaction test')),
        ],
      ],
      QuestionStage.test => <Widget>[
        Text(
          tested ? 'Reaction test done.' : (launch?.test == true ? 'Now the 1-minute reaction test' : 'The 1-minute reaction test'),
          style: text.headlineSmall?.copyWith(height: 1.25),
        ),
        const SizedBox(height: 8),
        Text(
          'Saved: ${s!.sharp}, ${sharpWords[s.sharp - 1]}. The test is optional.',
          style: muted,
        ),
        const SizedBox(height: 20),
        ReactionPanel(onDone: (_) {}, onTest: onTestDone, seed: testSeed),
      ],
    };
    return Scaffold(
      appBar: AppBar(title: Text('Sharp hours', style: text.titleMedium?.copyWith(color: Night.inkMuted))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        children: [
          ...body,
          if (error != null) ...[const SizedBox(height: 16), Text(error!, style: text.bodyLarge?.copyWith(color: Night.problem))],
        ],
      ),
      // the test's own Start is the step forward; until a test is done, leaving is a skip, not the action
      bottomNavigationBar: switch (stage) {
        QuestionStage.ask => null,
        QuestionStage.test when !tested => PinnedAction(child: OutlinedButton(onPressed: onDone, child: const Text('Skip the test'))),
        _ => PinnedAction(child: FilledButton(onPressed: onDone, child: const Text('Done'))),
      },
    );
  }
}

/// One answer: the number in tabular figures and its word, a full-width 64 dp row.
class _ScaleRow extends StatelessWidget {
  const _ScaleRow({required this.value, this.onTap});
  final int value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Night.rule),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
      child: Row(
        children: [
          SizedBox(width: 36, child: Text('$value', style: text.titleLarge?.copyWith(fontFeatures: tabular))),
          Expanded(child: Text(sharpWords[value - 1], style: text.titleMedium?.copyWith(fontWeight: FontWeight.w400))),
        ],
      ),
    );
  }
}

/// The question page with its saving: a tap writes the rating at once (so leaving the page keeps it), a finished
/// test writes its line too.
class SharpRatingScreen extends StatefulWidget {
  const SharpRatingScreen({super.key, this.launch, this.recordingsDir, this.now});
  final SharpLaunch? launch;
  final String? recordingsDir;
  final DateTime Function()? now;

  @override
  State<SharpRatingScreen> createState() => _SharpRatingScreenState();
}

class _SharpRatingScreenState extends State<SharpRatingScreen> {
  QuestionStage _stage = QuestionStage.ask;
  SharpRating? _saved;
  bool _tested = false, _canTest = false;
  String? _error;

  DateTime get _now => (widget.now ?? DateTime.now)();

  Future<SharpStore> _store() async {
    final dir = widget.recordingsDir ?? await Phone.recordingsDir();
    if (dir == null) throw StateError("the app's folder is not known");
    return SharpStore(sharpDirFor(dir));
  }

  Future<void> _rate(int v) async {
    if (_saved != null) return;
    try {
      final store = await _store();
      final l = widget.launch;
      final r = SharpRating(at: _now, sharp: v, prompt: l?.planned, shown: l?.shown, testAsked: l?.test ?? false);
      store.addRating(r);
      final can = testsToday(store.reactions(), r.at) < SharpRule.testsMax;
      if (!mounted) return;
      setState(() {
        _saved = r;
        _canTest = can;
        _stage = l?.test == true && can ? QuestionStage.test : QuestionStage.saved;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Not saved: $e');
    }
  }

  Future<void> _testDone(ReactionTest t) async {
    final r = _saved;
    if (r == null) return;
    try {
      (await _store()).addReaction(SharpReaction(at: _now, ratingAt: r.at, timesMs: List.of(t.times), falseStarts: t.falseStarts, lengthS: t.lengthS));
      if (mounted) setState(() => _tested = true);
    } catch (e) {
      if (mounted) setState(() => _error = 'The test was not saved: $e');
    }
  }

  @override
  Widget build(BuildContext context) => SharpQuestionView(
    stage: _stage,
    launch: widget.launch,
    saved: _saved,
    canTest: _canTest,
    tested: _tested,
    error: _error,
    onRate: (v) => unawaited(_rate(v)),
    onTest: () => setState(() => _stage = QuestionStage.test),
    onTestDone: (t) => unawaited(_testDone(t)),
    onDone: () => Navigator.of(context).maybePop(),
  );
}
