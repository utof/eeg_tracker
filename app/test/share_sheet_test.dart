// The Share on Wi-Fi sheet keeps the code to itself (DECISIONS 754) and says where a paired phone shares (752): the
// QR code holds the address only, the sheet asks Android to keep it out of screenshots and the recent-apps preview
// while it is open, the laptop commands take the code from the environment (not the command line), and a paired
// phone's sheet says home, allowed here, or paused, when the laptop last copied, and has "Share here for 12 hours".
import 'package:eeg_tracker/share/link.dart';
import 'package:eeg_tracker/ui/share_sheet.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const token = 'kq7m2xwp9dfh';
const laptop = PairedLaptop(host: '192.168.1.10', port: 8771, key: 'k', name: 'my-laptop');

void main() {
  final secure = <bool>[];
  setUp(() {
    secure.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('eeg_tracker/window'),
      (call) async {
        if (call.method == 'secure') secure.add((call.arguments as Map)['on'] == true);
        return null;
      },
    );
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('eeg_tracker/window'), null),
  );

  Future<void> show(
    WidgetTester t, {
    PairedLaptop? paired,
    String here = '',
    DateTime? hereUntil,
    String copied = 'Nothing copied yet.',
    ValueChanged<bool>? onShareHere,
  }) {
    t.view.physicalSize = const Size(1080, 6000); // the whole sheet at once (it is a lazy list)
    t.view.devicePixelRatio = 2.5;
    addTearDown(t.view.reset);
    return t.pumpWidget(
    MaterialApp(
      theme: nightTheme(),
      home: Scaffold(
        body: ShareSheet(
          model: ShareSheetModel(
            address: '192.168.1.23',
            port: 8765,
            token: token,
            until: DateTime(2026, 11, 23, 10, 5),
            night: false,
            laptop: paired,
            here: here,
            hereUntil: hereUntil,
            copied: copied,
          ),
          onShareHere: onShareHere,
        ),
      ),
    ),
  );
  }

  testWidgets('the QR code holds the address only: the code stays on this screen', (t) async {
    await show(t);
    final qr = t.widget<QrBox>(find.byType(QrBox));
    expect(qr.data, 'http://192.168.1.23:8765/');
    expect(qr.data.contains(token), isFalse);
    expect(find.text('The address, for a camera. The code is not in it.'), findsOneWidget);
  });

  testWidgets('no screenshots of the sheet while it is open', (t) async {
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    await t.pump();
    secure.clear();
    await show(t);
    expect(secure, [true]);
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(secure, [true, false]);
  });

  testWidgets('the laptop commands take the code from the environment, never from the command line', (t) async {
    await show(t);
    expect(find.textContaining('EEG_PHONE_TOKEN=$token python3 scripts/pull_phone.py http://192.168.1.23:8765'), findsOneWidget);
    expect(find.textContaining('EEG_PHONE_TOKEN=$token python3 scripts/page_server.py --recorder http://192.168.1.23:8765'), findsOneWidget);
    expect(find.textContaining('--token'), findsNothing);
  });

  testWidgets('paired, away from home: paused, and one tap shares here for 12 hours', (t) async {
    final asked = <bool>[];
    await show(t, paired: laptop, here: 'waiting', onShareHere: asked.add);
    expect(find.textContaining('Paused on this Wi-Fi'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Share here for 12 hours'), 100, scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('Share here for 12 hours'));
    expect(asked, [true]);
  });

  testWidgets('paired, allowed here: until when, and a way to stop it', (t) async {
    final asked = <bool>[];
    await show(t, paired: laptop, here: 'here', hereUntil: DateTime(2026, 11, 23, 2, 5), onShareHere: asked.add);
    expect(find.textContaining('Shared on this Wi-Fi until 02:05'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Stop sharing here'), 100, scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('Stop sharing here'));
    expect(asked, [false]);
  });

  testWidgets('paired, at home: says so, and when the laptop last copied', (t) async {
    await show(t, paired: laptop, here: 'home', copied: 'Last copied by my-laptop at 14:05.');
    expect(find.textContaining('Your home Wi-Fi: my-laptop said so'), findsOneWidget);
    expect(find.text('Last copied by my-laptop at 14:05.'), findsOneWidget);
    expect(find.text('Share here for 12 hours'), findsNothing);
  });
}
