// The "i" notes: bundled from docs/evidence through the assets/evidence link, and read as simple text.
import 'package:eeg_tracker/ui/evidence_sheet.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every evidence note is in the app bundle', () async {
    for (final name in [
      'meditation-feedback',
      'brain-sound',
      'jaw-and-blinks',
      'sleep-recording',
      'dream-catcher',
      'sound-for-states',
      'self-experiments',
      'nap-coach',
      'hands-free',
      'smart-alarm',
      'unusual-for-you',
      'sharp-hours',
      'lucid-cues',
      'was-this-you',
      'study-timing',
      'work-session',
      'memory-cues',
      'auto-start',
      'signal-quality',
      'confirm-questions',
      'asking',
      'share-on-wifi',
      'walking',
      'pulse',
      'record-first',
    ]) {
      final md = await rootBundle.loadString('assets/evidence/$name.md');
      expect(md, startsWith('# '), reason: name);
    }
  });

  test('the meditation note parses into headings, bullets and paragraphs; links keep text and site', () async {
    final blocks = parseMarkdown(await loadEvidence('meditation-feedback'));
    expect(blocks.first, isA<MdHeading>());
    expect(blocks.first.plain, 'Meditation feedback');
    final headings = [
      for (final b in blocks)
        if (b is MdHeading && b.level == 2) b.plain,
    ];
    expect(headings, containsAll(['What it does', 'Where the data does not support it', 'Sources']));
    final bullets = blocks.whereType<MdBullet>().toList();
    expect(bullets.length, greaterThan(10));
    expect(bullets.any((b) => b.plain.contains('g = -0.16')), isTrue, reason: 'continuation lines join the bullet');
    final link = bullets.expand((b) => b.spans).firstWhere((s) => s.url != null);
    expect(link.url, startsWith('https://'));
    expect(siteOf('https://www.jmir.org/2025/1/e68204'), 'jmir.org');
    expect(blocks.whereType<MdParagraph>().any((p) => p.plain.startsWith('Checked:')), isTrue);
  });

  test('inline marks: bold, code and links; nothing else is touched', () {
    final s = parseInline('a **b** `c` [d](https://e.org/x) [f](javascript:x)');
    expect([for (final x in s) x.text], ['a ', 'b', ' ', 'c', ' ', 'd', ' [f](javascript:x)']);
    expect(s[1].bold, isTrue);
    expect(s[5].url, 'https://e.org/x');
  });

  testWidgets('the note renders as text without overflow', (tester) async {
    // real file reads need runAsync inside a widget test (its clock is fake)
    final md = (await tester.runAsync(() => rootBundle.loadString('assets/evidence/meditation-feedback.md')))!;
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: Scaffold(body: EvidenceText(markdown: md)),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Meditation feedback', findRichText: true), findsWidgets);
  });
}
