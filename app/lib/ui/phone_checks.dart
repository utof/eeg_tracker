// Phone settings that decide whether a night survives (docs/research/android-overnight-ble-xiaomi.md,
// section 5 checklist), each with one way to fix it.
import 'package:flutter/material.dart';

import '../phone.dart';
import 'theme.dart';

/// What a fix button does; the screen maps these to permission requests or settings pages.
enum FixAction {
  requestNearby,
  bluetoothSettings,
  requestNotifications,
  batteryOptimisation,
  appDetails,
  batterySaver,
  xiaomiAutostart,
  xiaomiBatterySaver,
  xiaomiDone,
  wifiSettings,
  vpnSettings,
}

class PhoneCheck {
  const PhoneCheck(this.text, this.fixes, {this.serious = true});
  final String text;
  final List<(String, FixAction)> fixes;

  /// false: a reminder Android cannot verify (Xiaomi), shown calmer than a known problem.
  final bool serious;
}

/// [bluetooth] false: the DIY board is chosen (it comes over Wi-Fi), so Nearby devices and Bluetooth are not needed.
/// [wifi]: Wi-Fi has to stay up all night (Share on Wi-Fi is on, or the DIY board), so what may turn it off with the
/// screen off is named too (DECISIONS 613; the owner's Xiaomi left Wi-Fi soon after the screen went off, 2026-11-20).
List<PhoneCheck> phoneChecks({
  required PhoneSnapshot phone,
  required bool nearbyAllowed,
  required bool xiaomiDone,
  bool bluetooth = true,
  bool wifi = false,
}) => [
  if (bluetooth && !nearbyAllowed)
    const PhoneCheck('Nearby devices is not allowed, so the app cannot find the headband.', [
      ('Allow', FixAction.requestNearby),
    ]),
  if (bluetooth && !phone.bluetoothOn) const PhoneCheck('Bluetooth is off.', [('Turn on', FixAction.bluetoothSettings)]),
  if (!phone.ignoringBatteryOptimizations)
    const PhoneCheck('Battery optimisation is on for this app. It can stop the recording at night.', [
      ('Turn off', FixAction.batteryOptimisation),
    ]),
  if (phone.backgroundRestricted)
    const PhoneCheck('Background use is restricted for this app.', [('Open settings', FixAction.appDetails)]),
  if (!phone.notificationsEnabled)
    const PhoneCheck('Notifications are off. Android may stop a recorder that cannot show its notice.', [
      ('Allow', FixAction.requestNotifications),
    ]),
  if (phone.powerSaveMode)
    PhoneCheck(
      wifi
          ? 'Battery saver is on. It can stop the recording and turn Wi-Fi off while the screen is off.'
          : 'Battery saver is on. It can stop the recording.',
      const [('Open settings', FixAction.batterySaver)],
    ),
  if (wifi && (phone.wifiSleepPolicy == 0 || phone.wifiSleepPolicy == 1))
    PhoneCheck(
      phone.wifiSleepPolicy == 1
          ? 'Wi-Fi is set to sleep when the screen is off unless the phone charges, so the laptop can lose the phone '
                'at night. In the Wi-Fi settings, set "Keep Wi-Fi on during sleep" to Always if the phone has it.'
          : 'Wi-Fi is set to sleep when the screen is off, so the laptop can lose the phone at night. In the Wi-Fi '
                'settings, set "Keep Wi-Fi on during sleep" to Always if the phone has it.',
      const [('Wi-Fi settings', FixAction.wifiSettings)],
    ),
  if (wifi && phone.vpnActive)
    const PhoneCheck(
      'A VPN is on. If the laptop cannot reach the phone at night, let the VPN app bypass the local network, or turn '
      'off its "Block connections without VPN".',
      [('VPN settings', FixAction.vpnSettings)],
      serious: false,
    ),
  if ((phone.standbyBucket ?? 0) >= 45)
    const PhoneCheck('Android has put this app in its restricted group.', [('Open settings', FixAction.appDetails)]),
  if (phone.xiaomiOs != null && !xiaomiDone)
    const PhoneCheck(
      'Xiaomi: turn on Autostart, set Battery saver to No restrictions, and lock the app in Recents. '
      'Android cannot tell the app whether this is done.',
      [
        ('Autostart', FixAction.xiaomiAutostart),
        ('Battery saver', FixAction.xiaomiBatterySaver),
        ('Done', FixAction.xiaomiDone),
      ],
      serious: false,
    ),
];

class PhoneChecksList extends StatelessWidget {
  const PhoneChecksList({super.key, required this.checks, required this.onFix});
  final List<PhoneCheck> checks;
  final void Function(FixAction action) onFix;

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyLarge;
    if (checks.isEmpty) {
      return Row(
        children: [
          const Icon(Icons.check_circle_outline, color: Night.live, size: 22),
          const SizedBox(width: 12),
          Expanded(child: Text('Phone settings look right for a night.', style: body)),
        ],
      );
    }
    return Column(
      children: [
        for (var i = 0; i < checks.length; i++) ...[if (i > 0) const Divider(height: 24), _CheckRow(checks[i], onFix)],
      ],
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow(this.check, this.onFix);
  final PhoneCheck check;
  final void Function(FixAction action) onFix;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                check.serious ? Icons.error_outline : Icons.info_outline,
                color: check.serious ? Night.caution : Night.inkMuted,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(check.text, style: Theme.of(context).textTheme.bodyLarge)),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              for (final (label, action) in check.fixes)
                TextButton(
                  onPressed: () => onFix(action),
                  style: TextButton.styleFrom(foregroundColor: check.serious ? Night.caution : Night.ink),
                  child: Text(label),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
