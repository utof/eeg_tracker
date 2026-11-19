// Writes the dream catcher's answers out as text (DECISIONS rows 252-253): after a session, never during one, one
// answer at a time, through a recognizer opened once per batch (in a background isolate: speech_sherpa.dart) and
// closed afterwards so its memory goes back. Each try is counted before it starts; a failure is written beside the
// WAV with its reason and the WAV stays; your edits are applied to the newest text, so they win even over a text
// that arrives while you type. The screen says when it may run ([blocked]: a dream session or a night recording)
// and calls [stop] when a session starts.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'answer_text.dart';
import 'store.dart';

/// What the recognizer heard in one answer.
class Heard {
  const Heard({required this.text, required this.audioS, required this.voiceS});
  final String text;
  final double audioS;
  final double voiceS;
}

/// The recognizer was closed while it worked (a session started).
class TranscriberClosed implements Exception {
  const TranscriberClosed();
}

abstract class Transcriber {
  /// The model's id, written with each text.
  String get model;

  /// The words in a 16 kHz mono WAV. Throws when it cannot; [TranscriberClosed] after [close].
  Future<Heard> hear(String wavPath);

  /// Frees the model; a [hear] under way ends with [TranscriberClosed].
  Future<void> close();
}

class DreamTexts extends ChangeNotifier {
  DreamTexts({required this.store, required this._open, DateTime Function()? clock, bool Function()? blocked})
    : _now = clock ?? DateTime.now,
      _blocked = blocked ?? (() => false);

  final DreamStore store;
  final Future<Transcriber> Function() _open;
  final DateTime Function() _now;
  final bool Function() _blocked;

  final Map<String, AnswerText?> _texts = {};
  Future<void>? _running;
  Transcriber? _engine;
  bool _stop = false;
  bool _disposed = false;

  /// The answer being written out now.
  String? working;

  /// Answers still to do in this batch (after [working]).
  int left = 0;

  bool get busy => _running != null;

  /// The text of [answerFile] (read from its file once, then kept up to date here), or null.
  AnswerText? of(String answerFile) => _texts.putIfAbsent(answerFile, () => readAnswerText(store.dir, answerFile));

  /// Re-reads the files (after a session wrote new answers).
  void reload() => _texts.clear();

  /// Writes out every due answer of [sessions] (newest first). A second call while one runs joins it. Never throws.
  Future<void> run(List<DreamSession> sessions) => _running ??= _batch(sessions).whenComplete(() {
    _running = null;
    working = null;
    left = 0;
    _notify();
  });

  /// Stops at once (a session is starting): the model is freed and the answer under way is called off without
  /// counting as a try.
  Future<void> stop() async {
    _stop = true;
    await _engine?.close();
  }

  /// Your words for [answerFile]; written at once.
  void edit(String answerFile, String text) => _put(answerFile, (t) => t.edit(text));

  void undoEdit(String answerFile) => _put(answerFile, (t) => t.undoEdit());

  /// Try again after 2 failed tries.
  void retry(String answerFile) => _put(answerFile, (t) => t.retry());

  void _put(String answerFile, AnswerText Function(AnswerText) change) {
    final t = change(of(answerFile) ?? AnswerText(answer: answerFile));
    _texts[answerFile] = t;
    try {
      writeAnswerText(store.dir, t);
    } catch (_) {}
    _notify();
  }

  Future<void> _batch(List<DreamSession> sessions) async {
    _stop = false;
    if (_blocked()) return;
    reload();
    final due = dueAnswers(store, sessions);
    try {
      for (final (i, f) in due.indexed) {
        if (_stop || _blocked()) return;
        working = f;
        left = due.length - i - 1;
        _put(f, (t) => t.started());
        if (!await _one(f)) return;
      }
    } finally {
      final e = _engine;
      _engine = null;
      await e?.close();
    }
  }

  /// Writes out [f]; false when the batch must end (no model, or stopped).
  Future<bool> _one(String f) async {
    Transcriber engine;
    try {
      engine = _engine ??= await _open();
    } catch (e) {
      _put(f, (t) => t.withFailure('The speech model did not load: $e'));
      return false;
    }
    final sw = Stopwatch()..start();
    try {
      final h = await engine.hear('${store.dir.path}/$f');
      if (_stop) throw const TranscriberClosed();
      final m = MachineText(text: h.text.trim(), model: engine.model, at: _now(), audioS: h.audioS, voiceS: h.voiceS, tookS: sw.elapsedMicroseconds / 1e6);
      _put(f, (t) => t.withMachine(m));
      return true;
    } on TranscriberClosed {
      _put(f, (t) => t.calledOff());
      return false;
    } catch (e) {
      if (_stop) {
        _put(f, (t) => t.calledOff());
        return false;
      }
      _put(f, (t) => t.withFailure('$e'));
      return true;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
