// The switch "Count steps with the phone while recording" on the Settings page (DECISIONS 800-809). Off unless the
// owner switches it on; switching on asks Android's Physical activity permission and stays off when it is refused.
// The setting is the file `files/steps/settings.json` (lib/recorder/phone_steps.dart), which the recorder's engine
// reads when a run starts. A stateful piece of its own so the Settings page's state stays as it is.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../phone.dart';
import '../recorder/phone_steps.dart';
import 'records_parts.dart' show RecordSwitch;
import 'theme.dart';

class PhoneStepsSwitch extends StatefulWidget {
  const PhoneStepsSwitch({super.key, required this.settings, this.ask, this.openSettings, this.now});
  final StepSettings settings;

  /// Asks for the Physical activity permission; tests give their own answer.
  final Future<PermissionStatus> Function()? ask;

  /// Opens the app's page in the phone's settings.
  final Future<void> Function()? openSettings;
  final DateTime Function()? now;

  @override
  State<PhoneStepsSwitch> createState() => _PhoneStepsSwitchState();
}

class _PhoneStepsSwitchState extends State<PhoneStepsSwitch> {
  late bool _on = widget.settings.on;

  /// Why the switch stayed off, and whether the phone will not ask again.
  String? _refused;
  bool _blocked = false;

  Future<void> _set(bool on) async {
    if (!on) return _save(false);
    final status = await (widget.ask ?? Permission.activityRecognition.request)();
    if (!mounted) return;
    if (status.isGranted || status.isLimited) {
      setState(() => _refused = null);
      return _save(true);
    }
    setState(() {
      _refused = 'Still off: the phone did not allow Physical activity for this app.';
      _blocked = status.isPermanentlyDenied || status.isRestricted;
    });
  }

  void _save(bool on) {
    try {
      widget.settings.setOn(on, widget.now?.call() ?? DateTime.now());
      setState(() {
        _on = on;
        _refused = null;
        _blocked = false;
      });
    } catch (e) {
      setState(() => _refused = 'The setting could not be saved: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          RecordSwitch(
            title: 'Count steps with the phone while recording',
            line:
                "While the headband records, the phone's own step counter is written down once a minute, so walks can "
                'be checked against it. Works best with the phone in a trouser pocket. Needs the Physical activity '
                'permission; nothing leaves the phone.',
            value: _on,
            onChanged: (on) => unawaited(_set(on)),
          ),
          if (_refused != null) ...[
            const SizedBox(height: 8),
            Text(_refused!, style: text.bodyLarge?.copyWith(color: Night.caution, height: 1.4)),
            if (_blocked)
              TextButton(
                onPressed: () => unawaited((widget.openSettings ?? () => Phone.openSettings('appDetails'))()),
                child: const Text("Open the app's settings"),
              ),
          ],
        ],
      ),
    );
  }
}
