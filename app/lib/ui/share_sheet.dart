// Share on Wi-Fi (DECISIONS rows 220-229): the row in the night screen's "Your data" section, and the sheet with
// what the laptop needs: the address, the code, the same two as a QR code, and the two commands. Inside
// DESIGN.md: hairlines and label-left / value-right log rows, no cards; the QR code is the one light field, in the
// parchment ink instead of white, because a camera needs the contrast.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart';

import '../share/control.dart';
import '../share/link.dart';
import '../share/protocol.dart';
import 'theme.dart';

/// The switch, the sentence under it and, while on, the way to the sheet.
class ShareRow extends StatelessWidget {
  const ShareRow({super.key, required this.line, required this.onChanged, required this.onDetails});
  final ShareLine line;
  final ValueChanged<bool>? onChanged;
  final VoidCallback? onDetails;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MergeSemantics(
          child: InkWell(
            onTap: onChanged == null ? null : () => onChanged!(!line.on),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Row(
                children: [
                  Icon(line.on ? Icons.wifi_tethering : Icons.wifi_tethering_off, size: 22, color: line.on ? Night.live : Night.inkMuted),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Share on Wi-Fi', style: text.titleMedium)),
                  const SizedBox(width: 12),
                  Switch(value: line.on, onChanged: onChanged),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 34),
          child: Text(line.text, style: line.warn ? muted?.copyWith(color: Night.caution) : muted),
        ),
        if (line.on)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: onDetails, child: const Text('Address and code')),
          ),
      ],
    );
  }
}

class ShareSheetModel {
  const ShareSheetModel({
    required this.address,
    required this.port,
    required this.token,
    required this.until,
    required this.night,
    this.laptop,
  });

  /// `192.168.1.23`; null while no Wi-Fi address is known (the commands then use the cable: [cableCommand]).
  final String? address;
  final int port;
  final String token;

  /// When sharing turns itself off.
  final DateTime until;

  /// A night is recording (the recorder serves, screen off or on); else the app serves while it is open.
  final bool night;

  /// The paired laptop (DECISIONS rows 530-539), told where this phone is while sharing is on.
  final PairedLaptop? laptop;

  String get hostPort => '${address ?? '127.0.0.1'}:$port';

  /// Over a USB cable the laptop reaches the phone itself at 127.0.0.1 (DECISIONS row 563).
  String get cableCommand => 'adb forward tcp:$port tcp:$port';
  String get pagesCommand => 'python3 scripts/page_server.py --recorder http://$hostPort --token $token';
  String get pullCommand => 'python3 scripts/pull_phone.py http://$hostPort --token $token';
}

class ShareSheet extends StatelessWidget {
  const ShareSheet({super.key, required this.model, this.onNewToken, this.onForgetLaptop});
  final ShareSheetModel model;
  final VoidCallback? onNewToken;
  final VoidCallback? onForgetLaptop;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    final address = m.address;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        children: [
          Text('Share on Wi-Fi', style: text.titleLarge),
          const SizedBox(height: 10),
          Text(
            'Any device on this Wi-Fi that has the code can read your recordings; nothing can change or delete '
            'them. Not encrypted: use it on your home Wi-Fi only. Nothing goes to the internet.',
            style: muted,
          ),
          const SizedBox(height: 20),
          const Divider(),
          _Line(
            'Address',
            address == null ? 'not found' : m.hostPort,
            color: address == null ? Night.caution : Night.ink,
            copy: address == null ? null : 'http://${m.hostPort}',
          ),
          const Divider(),
          _Line('Code', m.token, copy: m.token),
          const Divider(),
          // paired with a laptop: sharing has no end time (DECISIONS 675)
          m.laptop != null ? const _Line('Turns off', 'only when you switch it off') : _Line('Turns off at', clockText(m.until)),
          const Divider(),
          if (m.laptop != null) ...[
            _Line('Laptop', m.laptop!.name),
            const Divider(),
          ],
          const SizedBox(height: 14),
          Text(
            address == null
                ? 'No Wi-Fi address found. Join your home Wi-Fi: it appears here within a minute. A USB cable works '
                      'without it (below).'
                : m.night
                ? (m.laptop != null
                      ? 'It keeps answering with the screen off while the night records; after Stop, while this app is open.'
                      : 'It keeps answering with the screen off while the night records, and for 15 minutes after Stop.')
                // no notification keeps the app running for sharing between nights (DECISIONS 678)
                : 'Between nights it answers while this app is open or a session runs. In the background the phone may '
                      'pause it: the laptop copies what it missed the next time the app is open or records.',
            style: address == null ? muted?.copyWith(color: Night.caution) : muted,
          ),
          const SizedBox(height: 10),
          Text(
            'If the laptop cannot reach the phone, nothing is lost: the night stays on the phone and the laptop copies '
            'what it missed once it reaches the phone again. Some phones turn Wi-Fi off with the screen off: the Phone '
            'section of the Night tab names the settings to check.',
            style: muted,
          ),
          if (address != null) ...[
            const SizedBox(height: 24),
            Center(
              child: Semantics(
                label: 'QR code with the address and the code',
                image: true,
                child: QrBox(shareUrl(address, m.port, m.token), size: 208),
              ),
            ),
            const SizedBox(height: 10),
            Text('The address and the code together, for a camera.', style: text.bodyMedium?.copyWith(color: Night.inkMuted), textAlign: TextAlign.center),
          ],
          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 20),
          Text('On the laptop', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
          const SizedBox(height: 10),
          Text(
            m.laptop != null
                ? 'Paired with ${m.laptop!.name}: this phone tells it where it is while sharing is on. On the laptop '
                      'run python3 scripts/phone_link.py.'
                : 'Easiest: on the laptop run python3 scripts/phone_link.py and point this phone\'s camera at the code '
                      'it shows. Nothing to type.',
            style: muted,
          ),
          if (m.laptop != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onForgetLaptop, child: const Text('Forget this laptop')),
            ),
          const SizedBox(height: 14),
          if (address == null) ...[
            Text('Phone on a USB cable, first:', style: muted),
            const SizedBox(height: 4),
            SelectableText(m.cableCommand, style: text.bodyMedium?.copyWith(height: 1.4)),
            const SizedBox(height: 14),
          ],
          Text('Or by hand, the live pages:', style: muted),
          const SizedBox(height: 4),
          SelectableText(m.pagesCommand, style: text.bodyMedium?.copyWith(height: 1.4)),
          const SizedBox(height: 14),
          Text('A copy of the files every 2 minutes:', style: muted),
          const SizedBox(height: 4),
          SelectableText(m.pullCommand, style: text.bodyMedium?.copyWith(height: 1.4)),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: onNewToken, child: const Text('New code')),
          ),
          Text(
            m.laptop != null
                ? 'A new code shuts out every laptop that has the old one. ${m.laptop!.name} is told the new one: '
                      'forget it first to shut it out too.'
                : 'A new code shuts out every laptop that has the old one.',
            style: text.bodyMedium?.copyWith(color: Night.inkMuted),
          ),
        ],
      ),
    );
  }
}

/// Label left, value right in tabular figures; a long-press or the icon copies it.
class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.color = Night.ink, this.copy});
  final String label;
  final String value;
  final Color color;
  final String? copy;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = copy;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        children: [
          Text(label, style: text.bodyLarge?.copyWith(color: Night.inkMuted)),
          const SizedBox(width: 16),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: text.titleLarge?.copyWith(color: color, fontFeatures: tabular, letterSpacing: 0.5),
              ),
            ),
          ),
          if (c != null)
            IconButton(
              tooltip: 'Copy ${label.toLowerCase()}',
              icon: const Icon(Icons.copy_outlined, size: 20, color: Night.inkMuted),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: c));
                if (context.mounted) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$label copied.')));
                }
              },
            )
          else
            const SizedBox(width: 48),
        ],
      ),
    );
  }
}

/// A QR code: `ground` modules on a parchment field with the quiet margin a scanner needs.
class QrBox extends StatelessWidget {
  const QrBox(this.data, {super.key, this.size = 208});
  final String data;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _QrPainter(QrImage(QrCode(payload: QrPayload.fromString(data))))),
  );
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);
  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)), Paint()..color = Night.ink);
    final n = image.moduleCount;
    final cell = (size.width / (n + 8)).floorToDouble(); // 4 quiet modules on every side, whole pixels
    final origin = (size.width - cell * n) / 2;
    final dark = Paint()
      ..color = Night.ground
      ..isAntiAlias = false;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (image.isDark(r, c)) canvas.drawRect(Rect.fromLTWH(origin + c * cell, origin + r * cell, cell, cell), dark);
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}
