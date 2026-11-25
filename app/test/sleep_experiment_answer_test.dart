// The evening question's three answers (DECISIONS 1082): every label sits on one line, chosen or not, at a phone's
// width with real fonts; when the three do not fit side by side (large text, a narrow phone) they stand under each
// other, still one line each. Nothing overflows.
import 'package:eeg_tracker/sleep_experiments/kinds.dart';
import 'package:eeg_tracker/ui/sleep_experiments_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

Future<void> _show(WidgetTester tester, ExperimentKind kind, Answer? value, {required double width, double scale = 1, ValueChanged<Answer>? onChanged}) async {
  tester.view.physicalSize = Size(width * 2.75, 600 * 2.75);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: MaterialApp(
        theme: nightTheme(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: AnswerQuestion(kind: kind, question: kind.question, value: value, onChanged: onChanged ?? (_) {}),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
}

List<String> _labels(ExperimentKind k) => [k.withLabel, k.withoutLabel, k.neitherLabel];

/// The label is drawn on one line.
void _oneLine(WidgetTester tester, String label) {
  final p = tester.renderObject<RenderParagraph>(find.text(label));
  final tops = {for (final b in p.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: label.length))) b.top.round()};
  expect(tops, hasLength(1), reason: '"$label" wraps');
}

void main() {
  setUpAll(loadFonts);

  for (final width in [440.0, 393.0]) {
    for (final kind in experimentKinds) {
      testWidgets('${kind.id} at ${width.round()} dp: three answers side by side, each on one line, whichever is chosen', (tester) async {
        for (final value in [null, ...Answer.values]) {
          await _show(tester, kind, value, width: width);
          for (final l in _labels(kind)) {
            _oneLine(tester, l);
          }
          final ys = {for (final l in _labels(kind)) tester.getCenter(find.text(l)).dy.round()};
          expect(ys, hasLength(1), reason: 'side by side');
        }
      });
    }
  }

  testWidgets('a 360 dp phone: every label is still one line, side by side or under each other', (tester) async {
    for (final kind in experimentKinds) {
      for (final value in [null, ...Answer.values]) {
        await _show(tester, kind, value, width: 360);
        for (final l in _labels(kind)) {
          _oneLine(tester, l);
        }
      }
    }
  });

  testWidgets('large text on a narrow phone: the answers stand under each other, one line each', (tester) async {
    final kind = kindById('caffeine_late')!;
    await _show(tester, kind, Answer.without, width: 320, scale: 1.3);
    for (final l in _labels(kind)) {
      _oneLine(tester, l);
    }
    final ys = [for (final l in _labels(kind)) tester.getCenter(find.text(l)).dy];
    expect(ys[0] < ys[1] && ys[1] < ys[2], isTrue);
    // each is as wide as the page and tall enough for a thumb
    for (final l in _labels(kind)) {
      final box = tester.getSize(find.ancestor(of: find.text(l), matching: find.byType(InkWell)).first);
      expect(box.width, 320 - 48);
      expect(box.height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('a tap gives the answer; the chosen one is said to a screen reader', (tester) async {
    final kind = kindById('alcohol')!;
    Answer? got;
    await _show(tester, kind, Answer.neither, width: 393, onChanged: (a) => got = a);
    await tester.tap(find.text('None'));
    expect(got, Answer.without);
    final handle = tester.ensureSemantics();
    expect(tester.getSemantics(find.text('1 or 2')), isSemantics(isChecked: true, isInMutuallyExclusiveGroup: true, isButton: true, hasTapAction: true, hasFocusAction: true, isFocusable: true, hasCheckedState: true, label: '1 or 2'));
    handle.dispose();
  });
}
