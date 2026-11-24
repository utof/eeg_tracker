// "If the headband is lost" on the Headband connection page (DECISIONS 857): the notice on or off, and after how many
// minutes without data it comes (5 to 10). Kept in files/headband/settings.json (headband/lost_watch.dart), which the
// recorder's engine reads at each loss.
import 'dart:io';

import 'package:flutter/material.dart';

import '../headband/lost_watch.dart';
import '../phone.dart';
import 'theme.dart';

class LostNoticeSetting extends StatefulWidget {
  const LostNoticeSetting({super.key, this.file});

  /// The settings file; null: the app's own (asked from the phone).
  final File? file;

  @override
  State<LostNoticeSetting> createState() => _LostNoticeSettingState();
}

class _LostNoticeSettingState extends State<LostNoticeSetting> {
  File? _file;
  LostSettings _s = const LostSettings();

  @override
  void initState() {
    super.initState();
    _file = widget.file;
    if (_file != null) {
      _s = LostSettings.load(_file!);
    } else {
      _find();
    }
  }

  Future<void> _find() async {
    try {
      final rec = await Phone.recordingsDir();
      if (rec == null || !mounted) return;
      final f = LostSettings.fileFor(rec);
      setState(() {
        _file = f;
        _s = LostSettings.load(f);
      });
    } catch (_) {
      // no phone (a test): the defaults show, nothing is saved
    }
  }

  void _set(LostSettings s) {
    setState(() => _s = s);
    final f = _file;
    if (f != null) s.save(f);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _s.on,
          onChanged: (on) => _set(LostSettings(afterMin: _s.afterMin, on: on)),
          title: Text('Tell me when the headband is lost', style: text.bodyLarge),
          subtitle: Text(
            'During a recording or a session: one notice when no data has come for ${_s.afterMin} minutes, one when it '
            'is back, and one when its battery is nearly empty. Never after you tap Stop. The paired laptop shows the '
            'same.',
            style: muted,
          ),
        ),
        if (_s.on) ...[
          const SizedBox(height: 4),
          Text('After how many minutes', style: muted),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (var m = LostSettings.minMin; m <= LostSettings.maxMin; m++)
                ChoiceChip(
                  label: Text('$m'),
                  selected: _s.afterMin == m,
                  onSelected: (_) => _set(LostSettings(afterMin: m, on: _s.on)),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
