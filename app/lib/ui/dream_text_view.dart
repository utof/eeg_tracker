// The dream catcher's answers as text (DECISIONS rows 254-255; .impeccable/surfaces/app-lib-ui-dream-screen-dart.md,
// "Addition 2026-11-19"): the words inside each answer's clip row, and the "Answers as text" section that gets the
// speech model onto the phone. Plain view models, so every state renders in tests.
import 'package:flutter/material.dart';

import '../dream/answer_text.dart';
import 'export_view.dart' show CopyStrip;
import 'theme.dart';

/// Where an answer's words are.
enum WordsState {
  /// No speech model on the phone: nothing is shown.
  none,

  /// Waits for its turn after the session.
  waiting,

  /// Being written out now.
  working,

  /// Written out (or typed by you).
  done,

  /// The last try failed; [AnswerWords.giveUp]: no more tries until Try again.
  failed,
}

class AnswerWords {
  const AnswerWords(this.state, {this.text = '', this.edited = false, this.why, this.giveUp = false});
  final WordsState state;

  /// What is shown: your words when [edited], else the phone's.
  final String text;
  final bool edited;
  final String? why;
  final bool giveUp;
}

/// The speech model on the phone.
enum SpeechState { absent, downloading, ready, failed }

class SpeechInfo {
  const SpeechInfo(this.state, {this.bytes = 0, this.total = 0, this.message});
  final SpeechState state;

  /// Bytes on the phone and in all (downloading), or the model's size.
  final int bytes;
  final int total;

  /// Why a download failed.
  final String? message;
}

String megabytes(int bytes) => '${(bytes / 1e6).round()} MB';

/// The words of one answer, inside its clip row (between its detail lines and the note).
class WordsBlock extends StatelessWidget {
  const WordsBlock({super.key, required this.words, required this.onChanged, required this.onUndo, required this.onRetry});
  final AnswerWords words;
  final ValueChanged<String> onChanged;
  final VoidCallback onUndo;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme, w = words;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4);
    Widget line(String s) => Padding(padding: const EdgeInsets.only(top: 8), child: Text(s, style: muted));
    switch (w.state) {
      case WordsState.none:
        return const SizedBox.shrink();
      case WordsState.waiting:
        return line('Words: waiting to be written out.');
      case WordsState.working:
        return Semantics(liveRegion: true, child: line('Words: writing out…'));
      case WordsState.failed:
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2, right: 8),
                    child: Icon(Icons.warning_amber_rounded, size: 18, color: Night.caution),
                  ),
                  Expanded(
                    child: Text(
                      'Could not write this out: ${w.why ?? 'unknown error'}. The recording is kept'
                      '${w.giveUp ? '.' : '; it tries again next time.'}',
                      style: text.bodyMedium?.copyWith(color: Night.caution, height: 1.4),
                    ),
                  ),
                ],
              ),
              if (w.giveUp)
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                  child: const Text('Try again'),
                ),
            ],
          ),
        );
      case WordsState.done:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      w.edited
                          ? 'Your words'
                          : w.text.isEmpty
                          ? 'No words heard.'
                          : 'Words heard by the phone',
                      style: muted,
                    ),
                  ),
                ),
                if (w.edited)
                  TextButton(
                    onPressed: onUndo,
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                    child: const Text('Undo edit'),
                  ),
              ],
            ),
            _WordsField(text: w.text, edited: w.edited, onChanged: onChanged),
          ],
        );
    }
  }
}

/// Your words, saved as you type (a ruled field like the note's).
class _WordsField extends StatefulWidget {
  const _WordsField({required this.text, required this.edited, required this.onChanged});
  final String text;
  final bool edited;
  final ValueChanged<String> onChanged;

  @override
  State<_WordsField> createState() => _WordsFieldState();
}

class _WordsFieldState extends State<_WordsField> {
  late final TextEditingController _c = TextEditingController(text: widget.text);

  bool _focused = false;

  @override
  void didUpdateWidget(_WordsField old) {
    super.didUpdateWidget(old);
    // an edit undone, or the phone's text arriving while you are not typing: show it
    final undone = old.edited && !widget.edited;
    if (widget.text != _c.text && (undone || !_focused)) _c.text = widget.text;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    onFocusChange: (f) => _focused = f,
    child: TextField(
      controller: _c,
      onChanged: widget.onChanged,
      minLines: 1,
      maxLines: 8,
      textCapitalization: TextCapitalization.sentences,
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.4),
      decoration: const InputDecoration(
        hintText: 'Type what you said',
        hintStyle: TextStyle(color: Night.inkMuted),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(vertical: 10),
        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Night.rule)),
        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Night.inkMuted)),
      ),
    ),
  );
}

/// "Answers as text": what it does, and the speech model's download, progress, readiness or failure.
class SpeechSection extends StatelessWidget {
  const SpeechSection({super.key, required this.info, required this.onDownload, required this.onStop, required this.onDelete});
  final SpeechInfo info;
  final VoidCallback onDownload;
  final VoidCallback onStop;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme, i = info;
    final body = text.bodyLarge?.copyWith(height: 1.4);
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4, fontFeatures: tabular);
    final size = megabytes(i.total);
    final children = <Widget>[
      Text(
        i.state == SpeechState.ready
            ? 'After each session the phone writes your answers out as words, Russian or English, here on the '
                  'phone. Nothing leaves it. Fix any word in its box; your version is kept.'
            : 'The phone can write your answers out as words after each session, Russian or English. It needs a '
                  'speech model of $size, downloaded once; then everything happens on this phone and nothing '
                  'leaves it.',
        style: body,
      ),
      const SizedBox(height: 14),
    ];
    switch (i.state) {
      case SpeechState.absent:
        children.addAll([
          OutlinedButton.icon(
            onPressed: onDownload,
            icon: const Icon(Icons.download_rounded),
            label: Text(i.bytes > 0 ? 'Go on (${megabytes(i.bytes)} of $size here)' : 'Download ($size)'),
          ),
          const SizedBox(height: 6),
          Text('Use Wi-Fi: it is large.', style: muted),
        ]);
      case SpeechState.downloading:
        final share = i.total <= 0 ? 0 : (i.bytes / i.total * 100).floor();
        children.addAll([
          Semantics(
            label: '$share percent downloaded',
            excludeSemantics: true,
            child: CopyStrip(done: i.bytes, total: i.total, live: true),
          ),
          const SizedBox(height: 10),
          Text('Downloading: ${megabytes(i.bytes)} of $size. Keep this page open.', style: muted),
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: onStop, icon: const Icon(Icons.stop_rounded), label: const Text('Stop')),
        ]);
      case SpeechState.failed:
        children.addAll([
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2, right: 8),
                child: Icon(Icons.warning_amber_rounded, size: 18, color: Night.caution),
              ),
              Expanded(
                child: Text(
                  i.message ?? 'The download stopped.',
                  style: text.bodyMedium?.copyWith(color: Night.caution, height: 1.4),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onDownload,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(i.bytes > 0 ? 'Go on (${megabytes(i.bytes)} of $size here)' : 'Try again'),
          ),
        ]);
      case SpeechState.ready:
        children.add(
          Row(
            children: [
              Expanded(child: Text('Speech model on this phone · $size', style: muted)),
              TextButton(onPressed: onDelete, child: const Text('Delete')),
            ],
          ),
        );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

/// The words block's state for an answer: [t] its text file (null: none yet), [modelReady] the speech model is on
/// the phone, [working] it is being written out now.
AnswerWords wordsFor(AnswerText? t, {required bool modelReady, required bool working}) {
  if (working) return const AnswerWords(WordsState.working);
  if (t != null && t.shown != null) return AnswerWords(WordsState.done, text: t.shown!, edited: t.edited != null);
  if (t != null && t.failed != null) return AnswerWords(WordsState.failed, why: t.failed, giveUp: !t.due);
  return modelReady ? const AnswerWords(WordsState.waiting) : const AnswerWords(WordsState.none);
}
