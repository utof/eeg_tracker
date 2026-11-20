// Pairing with a laptop by one scan (DECISIONS rows 530-539): the laptop's QR code opens the app with a pair link
// (PairLinkActivity.kt hands it over through "eeg_tracker/link"), and this asks "Connect to this laptop?" before
// anything is sent. Inside DESIGN.md: the app's plain dialogs, words before buttons.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../share/control.dart';
import '../share/link.dart';

/// The pair link the app was opened with, once.
abstract class PairInbox {
  Future<String?> take();

  /// Called when a link arrives while the app runs.
  set onOpen(void Function()? f);
}

class ChannelPairInbox implements PairInbox {
  static const MethodChannel _channel = MethodChannel('eeg_tracker/link');

  @override
  Future<String?> take() => _channel.invokeMethod<String>('take');

  @override
  set onOpen(void Function()? f) => _channel.setMethodCallHandler(
    f == null
        ? null
        : (call) async {
            if (call.method == 'open') f();
            return null;
          },
  );
}

/// Asks about [raw] and, on Connect, runs [pair] (ShareControl.pair). Returns how it ended; null when not asked
/// through to the end (Not now, or not a pair link).
Future<PairOutcome?> confirmPairing(BuildContext context, String raw, Future<PairOutcome> Function(PairLink link) pair) =>
    showDialog<PairOutcome>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => PairDialog(link: PairLink.parse(raw), pair: pair),
    );

/// Why a pairing did not work, in the owner's words.
String pairFailureText(LinkFailure f) => switch (f) {
  LinkFailure.noAnswer =>
    'The laptop did not answer. Are the phone and the laptop on the same Wi-Fi, and is the laptop\'s window still '
        'open? A VPN on the phone can also stand in the way.',
  LinkFailure.expired =>
    'That code has expired: each one works once, for 5 minutes. Press Enter in the laptop\'s window and scan the new '
        'one.',
  LinkFailure.wrongLaptop =>
    'That is not the laptop that showed the code, so nothing was sent. Scan the code on your own laptop\'s screen.',
  LinkFailure.oldLaptop =>
    'The laptop\'s scripts are older than this app. Update them on the laptop (the same version as this app), then '
        'scan a new code.',
  LinkFailure.refused || LinkFailure.bad => 'The laptop said no. Scan a new code and try again.',
};

class PairDialog extends StatefulWidget {
  const PairDialog({super.key, required this.link, required this.pair});

  /// Null when the app was opened with something that is not a pair link.
  final PairLink? link;
  final Future<PairOutcome> Function(PairLink link) pair;

  @override
  State<PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<PairDialog> {
  bool _busy = false;
  PairOutcome? _outcome;

  Future<void> _connect(PairLink link) async {
    setState(() => _busy = true);
    PairOutcome outcome;
    try {
      outcome = await widget.pair(link);
    } catch (_) {
      outcome = (laptop: null, failure: LinkFailure.bad);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _outcome = outcome;
    });
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final outcome = _outcome;
    if (link == null) {
      return AlertDialog(
        title: const Text('Not a laptop code'),
        content: const Text(
          'This link is not a code from the EEG Tracker laptop command. On the laptop run '
          'python3 scripts/phone_link.py and scan the code it shows.',
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      );
    }
    if (_busy) {
      return const AlertDialog(
        title: Text('Connecting'),
        content: Row(
          children: [
            SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
            SizedBox(width: 16),
            Expanded(child: Text('Asking the laptop…')),
          ],
        ),
      );
    }
    if (outcome != null) {
      final laptop = outcome.laptop;
      return AlertDialog(
        title: Text(laptop != null ? 'Connected' : 'Not connected'),
        content: Text(
          laptop != null
              ? 'Connected to ${laptop.name}. Share on Wi-Fi is on: the laptop copies your recordings every 2 minutes '
                    'and can show your live signal. Next time it finds this phone by itself whenever Share on Wi-Fi is on.'
              : pairFailureText(outcome.failure ?? LinkFailure.bad),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context, outcome), child: const Text('OK'))],
      );
    }
    return AlertDialog(
      title: const Text('Connect to this laptop?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${link.name} at ${link.host}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          const Text(
            'It will copy your recordings and can show your live signal, over this Wi-Fi only. Share on Wi-Fi turns '
            'on (it turns itself off after 12 hours, as always).',
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Not now')),
        TextButton(onPressed: () => _connect(link), child: const Text('Connect')),
      ],
    );
  }
}
