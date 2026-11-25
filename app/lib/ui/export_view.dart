// The Export data page's layout (.impeccable/surfaces/app-lib-ui-export-screen-dart.md): the handoff from this
// phone to the folder to the laptop. A status word and sentence, what is new as two readouts, the copy strip (the
// watch strip's cells filling with what has reached the folder), the route as three numbered log rows, Export
// everything, and the one action pinned at the bottom. Built from an ExportViewModel only, so tests render it.
import 'package:flutter/material.dart';

import '../export/exporter.dart' show ExportOutcome, ExportProgress;
import '../export/store.dart';
import 'form_parts.dart' show Para, PinnedAction;
import 'meditation_view.dart' show MarkShape, StateMark;
import 'parts.dart';
import 'theme.dart';

/// Cells in the copy strip.
const int copyCells = 16;

class ExportViewModel {
  const ExportViewModel({
    required this.now,
    this.folderLabel,
    this.folderUsable = true,
    this.phoneFiles = 0,
    this.phoneBytes = 0,
    this.pendingFiles = 0,
    this.pendingBytes = 0,
    this.lastComplete,
    this.progress,
    this.outcome,
    this.stopping = false,
    this.blocked,
    this.loading = false,
  });

  final DateTime now;

  /// The picked folder (`Download/EEG`); null before the first pick.
  final String? folderLabel;

  /// False when the app lost its permission to write there.
  final bool folderUsable;

  /// Everything the app keeps that leaves the phone, and what the next "Export new" would copy.
  final int phoneFiles, phoneBytes, pendingFiles, pendingBytes;
  final DateTime? lastComplete;

  /// Set while copying.
  final ExportProgress? progress;

  /// The export that just ended.
  final ExportOutcome? outcome;
  final bool stopping;

  /// Why nothing may be exported now (a night records, a session holds the headband), or null.
  final String? blocked;
  final bool loading;

  bool get exporting => progress != null;
  bool get hasFolder => folderLabel != null && folderUsable;

  /// Bytes of the phone's data in the export folder, now (copying included).
  int get exportedBytes => (phoneBytes - pendingBytes + (progress?.bytesDone ?? 0)).clamp(0, phoneBytes);
}

typedef ExportStatus = ({String title, String sentence, MarkShape mark, Color color});

String _files(int n) => n == 1 ? '1 file' : '$n files';

/// Title, sentence and mark for the page. Pure, so it is tested without a phone.
ExportStatus describeExport(ExportViewModel m) {
  final p = m.progress, o = m.outcome, folder = '${m.folderLabel}/$exportFolderName';
  if (p != null) {
    return (
      title: m.stopping ? 'Stopping' : 'Exporting',
      sentence: m.stopping
          ? 'Stopping after this file. What is copied stays, and the list says what is still to come.'
          : 'Copying ${p.path}. Keep the app open; Stop keeps what is copied.',
      mark: MarkShape.filled,
      color: Night.live,
    );
  }
  if (m.blocked != null) return (title: 'Not now', sentence: m.blocked!, mark: MarkShape.ring, color: Night.caution);
  if (m.folderLabel == null) {
    return (
      title: 'No folder yet',
      sentence: 'Pick the folder once: Download/EEG (make it in the picker) or your Syncthing folder.',
      mark: MarkShape.ring,
      color: Night.inkMuted,
    );
  }
  if (!m.folderUsable) {
    return (
      title: 'Folder lost',
      sentence: 'The app may no longer write to ${m.folderLabel}. Pick the folder again.',
      mark: MarkShape.ringedDot,
      color: Night.caution,
    );
  }
  if (o != null && o.complete) {
    // a recording runs: the file set it writes now is left for the next export (DECISIONS 1040)
    final open = o.stillWritten.isEmpty ? '' : ' The part of the recording that is being written now comes with the next export.';
    return (
      title: 'Exported',
      sentence: o.files == 0
          ? 'Nothing new: $folder already has everything. Its list of files was written again.$open'
          : '${_files(o.files)} (${sizeText(o.bytes)}) copied into $folder, with the list of every file '
                '(manifest.json) for the laptop to check.$open',
      mark: MarkShape.filled,
      color: Night.live,
    );
  }
  if (o != null) {
    final kept = o.files == 0 ? 'Nothing was copied.' : '${_files(o.files)} copied are kept and listed.';
    return (
      title: 'Export stopped',
      sentence: o.error == null
          ? 'Stopped. $kept Export new copies the rest.'
          : 'It stopped: ${o.error}. $kept Export new copies the rest.',
      mark: MarkShape.ringedDot,
      color: o.error == null ? Night.caution : Night.problem,
    );
  }
  final line = exportLine(
    lastComplete: m.lastComplete,
    pendingFiles: m.pendingFiles,
    pendingBytes: m.pendingBytes,
    now: m.now,
  );
  if (m.lastComplete == null) {
    return (
      title: 'Never exported',
      sentence: m.pendingFiles == 0 ? 'Nothing to export yet.' : line!.text,
      mark: m.pendingFiles == 0 ? MarkShape.ring : MarkShape.ringedDot,
      color: m.pendingFiles == 0 ? Night.inkMuted : Night.caution,
    );
  }
  if (m.pendingFiles == 0) return (title: 'Up to date', sentence: line!.text, mark: MarkShape.filled, color: Night.live);
  return line!.warn
      ? (title: 'Export due', sentence: line.text, mark: MarkShape.ringedDot, color: Night.caution)
      : (title: 'New data', sentence: line.text, mark: MarkShape.ring, color: Night.inkMuted);
}

/// `210`, `MB` as readout parts.
List<(String, bool)> _sizeParts(int bytes) {
  final t = sizeText(bytes).split(' ');
  return [(t[0], true), (' ${t[1]}', false)];
}

class ExportView extends StatelessWidget {
  const ExportView({
    super.key,
    required this.model,
    this.onPick,
    this.onExportNew,
    this.onExportAll,
    this.onStop,
  });

  final ExportViewModel model;
  final VoidCallback? onPick;
  final VoidCallback? onExportNew;
  final VoidCallback? onExportAll;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final text = Theme.of(context).textTheme;
    final s = describeExport(m);
    final idle = !m.exporting && m.blocked == null && !m.loading;
    return Scaffold(
      appBar: AppBar(title: Text('Export data', style: text.titleMedium?.copyWith(color: Night.ink))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          Semantics(
            liveRegion: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    StateMark(shape: s.mark, color: s.color),
                    const SizedBox(width: 14),
                    Expanded(child: Text(m.loading ? 'Reading' : s.title, style: text.displaySmall)),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  m.loading ? 'Counting what the app keeps.' : s.sentence,
                  style: text.bodyLarge?.copyWith(
                    color: s.color == Night.caution || s.color == Night.problem ? s.color : Night.inkMuted,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          if (!m.loading) ...[
            const SizedBox(height: 28),
            _Readouts(m),
            const SizedBox(height: 24),
            CopyStrip(done: m.exportedBytes, total: m.phoneBytes, live: m.exporting),
            const SizedBox(height: 10),
            Text(
              m.phoneBytes == 0
                  ? 'Nothing kept on this phone yet.'
                  : m.exportedBytes == 0
                  ? '${sizeText(m.phoneBytes)} on this phone; none of it exported yet.'
                  : '${sizeText(m.phoneBytes)} on this phone; ${sizeText(m.exportedBytes)} of it exported.',
              style: text.bodyMedium?.copyWith(color: Night.inkMuted),
            ),
          ],
          const SectionHeading('Where it goes'),
          _Stop(
            number: 1,
            title: 'This phone',
            body: m.loading
                ? 'Kept inside the app, where other apps cannot read it. Exporting copies; nothing is deleted.'
                : '${_files(m.phoneFiles)}, ${sizeText(m.phoneBytes)}, kept inside the app where other apps cannot '
                      'read them. Exporting copies them; nothing is deleted.',
          ),
          const Divider(height: 33),
          _Stop(
            number: 2,
            title: m.folderLabel == null ? 'Folder: not picked yet' : '${m.folderLabel}/$exportFolderName',
            body: m.folderLabel == null
                ? 'Pick it once: Download/EEG, or your Syncthing folder so it reaches the laptop by itself.'
                : 'Each export adds what is new here, and a list of every file with its checksum. With your '
                      'Syncthing folder it reaches the laptop by itself.',
            action: m.folderLabel == null || m.exporting
                ? null
                : TextButton(onPressed: idle ? onPick : null, child: const Text('Change folder')),
          ),
          const Divider(height: 33),
          const _Stop(
            number: 3,
            title: 'Laptop',
            body: 'Syncthing brings the folder over, or adb pull, or a USB cable. There, scripts/import_phone.py '
                'checks every file against the list and copies it in.',
          ),
          const SectionHeading('Everything again'),
          const Para(
            'Copies every file again: for a new folder, or when the laptop says something is missing.',
            color: Night.inkMuted,
            top: 0,
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: idle && m.hasFolder ? onExportAll : null,
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Export everything'),
          ),
        ],
      ),
      bottomNavigationBar: PinnedAction(child: _Action(m, onPick: onPick, onExportNew: onExportNew, onStop: onStop)),
    );
  }
}

class _Readouts extends StatelessWidget {
  const _Readouts(this.m);
  final ExportViewModel m;

  @override
  Widget build(BuildContext context) {
    final p = m.progress, o = m.outcome;
    final List<Widget> pair;
    if (p != null) {
      pair = [
        Readout(parts: [('${p.done}', true), (' of ${p.total}', false)], label: 'files copied'),
        Readout(parts: _sizeParts(p.bytesDone), label: 'of ${sizeText(p.bytesTotal)} copied'),
      ];
    } else if (o != null) {
      pair = [
        Readout(parts: [('${o.files}', true), (o.files == 1 ? ' file' : ' files', false)], label: 'copied just now'),
        Readout(parts: _sizeParts(o.bytes), label: 'copied just now'),
      ];
    } else {
      final label = m.lastComplete == null ? 'to export' : 'new since the last export';
      pair = [
        Readout(parts: [('${m.pendingFiles}', true), (m.pendingFiles == 1 ? ' file' : ' files', false)], label: label),
        Readout(parts: _sizeParts(m.pendingBytes), label: 'to copy'),
      ];
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [Expanded(child: pair[0]), const VerticalDivider(width: 33), Expanded(child: pair[1])],
      ),
    );
  }
}

/// The copy strip: the watch strip's cells, filling from the left with the share of the phone's data that has
/// reached the export folder; while copying, the cell in progress is outlined green.
class CopyStrip extends StatelessWidget {
  const CopyStrip({super.key, required this.done, required this.total, this.live = false});
  final int done, total;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final share = total <= 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    final filled = share * copyCells;
    return Semantics(
      label: '${(share * 100).floor()} percent exported',
      child: Row(
        children: [
          for (var i = 0; i < copyCells; i++) ...[
            if (i > 0) SizedBox(width: i % 4 == 0 ? 10 : 6),
            Expanded(
              child: _Cell(fill: (filled - i).clamp(0.0, 1.0), current: live && share < 1 && i == filled.floor()),
            ),
          ],
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.fill, required this.current});
  final double fill;
  final bool current;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1,
    child: Container(
      decoration: BoxDecoration(
        color: Night.track,
        borderRadius: BorderRadius.circular(6),
        border: current ? Border.all(color: Night.live, width: 2) : null,
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(heightFactor: fill, widthFactor: 1, child: const ColoredBox(color: Night.saved)),
    ),
  );
}

/// One stop on the route: a numbered cell, its name, one plain paragraph, an optional text button.
class _Stop extends StatelessWidget {
  const _Stop({required this.number, required this.title, required this.body, this.action});
  final int number;
  final String title, body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: Night.rule, borderRadius: BorderRadius.circular(6)),
                child: Text('$number', style: text.titleSmall?.copyWith(fontFeatures: tabular)),
              ),
              const SizedBox(width: 14),
              Expanded(child: Text(title, style: text.titleLarge)),
            ],
          ),
          const SizedBox(height: 10),
          Text(body, style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4)),
          if (action != null) Align(alignment: Alignment.centerRight, child: action),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.m, {required this.onPick, required this.onExportNew, required this.onStop});
  final ExportViewModel m;
  final VoidCallback? onPick, onExportNew, onStop;

  @override
  Widget build(BuildContext context) {
    if (m.exporting) {
      return OutlinedButton.icon(
        onPressed: m.stopping ? null : onStop,
        icon: const Icon(Icons.stop_rounded),
        label: Text(m.stopping ? 'Stopping…' : 'Stop'),
      );
    }
    final ready = m.blocked == null && !m.loading;
    if (!m.hasFolder) {
      return FilledButton.icon(
        onPressed: ready ? onPick : null,
        icon: const Icon(Icons.create_new_folder_outlined),
        label: Text(m.folderLabel == null ? 'Pick a folder' : 'Pick the folder again'),
      );
    }
    return FilledButton.icon(
      onPressed: ready ? onExportNew : null,
      icon: const Icon(Icons.drive_folder_upload_outlined),
      label: const Text('Export new'),
    );
  }
}
