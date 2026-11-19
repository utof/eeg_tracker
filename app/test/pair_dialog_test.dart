// "Connect to this laptop?" (lib/ui/pair_dialog.dart, DECISIONS rows 530-539): nothing is sent before Connect,
// Connect pairs with the link's laptop, and each failure says what to do in plain words. Also the share sheet's
// paired-laptop line.
import 'package:eeg_tracker/share/control.dart';
import 'package:eeg_tracker/share/link.dart';
import 'package:eeg_tracker/ui/pair_dialog.dart';
import 'package:eeg_tracker/ui/share_sheet.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const raw = 'eegtracker://pair?h=192.168.1.10&p=8771&s=AbCdEfGhIjKlMnOpQrStUv&n=my-laptop';
const laptop = PairedLaptop(host: '192.168.1.10', port: 8771, key: 'k-k-k-k-k-k-k-k-k-k-k-k-k-k-k-k-k', name: 'my-laptop');

void main() {
  late List<PairLink> asked;
  PairOutcome? result;
  var returned = false;

  Future<void> open(WidgetTester t, String link, PairOutcome answer) async {
    asked = [];
    result = null;
    returned = false;
    await t.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await confirmPairing(context, link, (l) async {
                  asked.add(l);
                  await Future<void>.delayed(const Duration(milliseconds: 50));
                  return answer;
                });
                returned = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  testWidgets('asks first; Not now sends nothing', (t) async {
    await open(t, raw, (laptop: laptop, failure: null));
    expect(find.text('Connect to this laptop?'), findsOneWidget);
    expect(find.text('my-laptop at 192.168.1.10'), findsOneWidget);
    expect(find.textContaining('over this Wi-Fi only'), findsOneWidget);
    await t.tap(find.text('Not now'));
    await t.pumpAndSettle();
    expect(asked, isEmpty);
    expect(returned, isTrue);
    expect(result, isNull);
  });

  testWidgets('Connect pairs with the link\'s laptop and says what happens now', (t) async {
    await open(t, raw, (laptop: laptop, failure: null));
    await t.tap(find.text('Connect'));
    await t.pump();
    expect(find.text('Asking the laptop…'), findsOneWidget);
    await t.pumpAndSettle();
    expect(asked.single.host, '192.168.1.10');
    expect(asked.single.code, 'AbCdEfGhIjKlMnOpQrStUv');
    expect(find.text('Connected'), findsOneWidget);
    expect(find.textContaining('finds this phone by itself'), findsOneWidget);
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    expect(result?.laptop, laptop);
  });

  for (final f in LinkFailure.values) {
    testWidgets('a failure in plain words: ${f.name}', (t) async {
      await open(t, raw, (laptop: null, failure: f));
      await t.tap(find.text('Connect'));
      await t.pumpAndSettle();
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text(pairFailureText(f)), findsOneWidget);
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
      expect(result?.failure, f);
    });
  }

  testWidgets('a link that is not a laptop code is said so, and nothing is asked', (t) async {
    await open(t, 'eegtracker://pair?h=8.8.8.8&p=8771&s=AbCdEfGhIjKlMnOpQrStUv', (laptop: laptop, failure: null));
    expect(find.text('Not a laptop code'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    expect(asked, isEmpty);
  });

  test('the words for each failure say what to do', () {
    expect(pairFailureText(LinkFailure.noAnswer), contains('same Wi-Fi'));
    expect(pairFailureText(LinkFailure.expired), contains('Press Enter'));
    expect(pairFailureText(LinkFailure.wrongLaptop), contains('nothing was sent'));
  });

  testWidgets('the share sheet names the paired laptop and can forget it', (t) async {
    var forgot = 0;
    Future<void> sheet(PairedLaptop? l) => t.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: Scaffold(
          body: ShareSheet(
            model: ShareSheetModel(address: '192.168.1.23', port: 8765, token: 'abcdefghjkmn', until: DateTime(2026, 11, 23, 10, 5), night: false, laptop: l),
            onForgetLaptop: () => forgot++,
          ),
        ),
      ),
    );
    await sheet(null);
    await t.scrollUntilVisible(find.textContaining('scripts/phone_link.py and point this phone'), 100, scrollable: find.byType(Scrollable).first);
    expect(find.text('Forget this laptop'), findsNothing);
    await sheet(laptop);
    await t.scrollUntilVisible(find.text('Laptop'), -100, scrollable: find.byType(Scrollable).first);
    expect(find.text('my-laptop'), findsOneWidget);
    await t.scrollUntilVisible(find.textContaining('Paired with my-laptop'), 100, scrollable: find.byType(Scrollable).first);
    await t.scrollUntilVisible(find.text('Forget this laptop'), 100, scrollable: find.byType(Scrollable).first);
    await t.scrollUntilVisible(find.textContaining('my-laptop is told the new one'), 100, scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('Forget this laptop'));
    expect(forgot, 1);
  });
}
