// Keeps a sound session alive while the phone is locked (DECISIONS rows 190-196). On the phone this is a small
// Android foreground service (SessionService.kt: "playing sound", plus "connected device" with the headband and
// "microphone" for the dream catcher), a wake lock and a notification with Stop. The session itself stays in the
// screen's engine; the keeper only stops Android from freezing or silencing it. Never the night recorder's service.
// It also asks Android for the sound (audio focus, DECISIONS row 468) and tells the session when a call or another
// app takes it and when it comes back, so the session can go quiet meanwhile instead of playing on through a call.
import 'dart:async';

import 'package:flutter/services.dart';

/// Android's audio focus, as a session sees it.
enum FocusChange {
  /// Another app's sound took over for good (music, a video): no "back" may come.
  lost,

  /// A call or a voice prompt for a while: "back" comes after it.
  paused,

  /// A short sound (a notification): Android lowers this session's sound by itself.
  duck,

  /// The sound is this session's again.
  back,
}

/// What a session needs kept, and the words on its notification.
class KeepSpec {
  const KeepSpec({
    required this.title,
    this.text = 'Session running',
    this.headband = false,
    this.microphone = false,
    this.focus = true,
    this.button,
  });

  /// The notification's title ("Fall asleep", "Meditation").
  final String title;
  final String text;

  /// The session streams the headband (Bluetooth must go on with the screen off).
  final bool headband;

  /// The session records answers later, with the phone possibly locked (the dream catcher).
  final bool microphone;

  /// Ask for the sound (audio focus): other apps' sound pauses, and [SessionKeeper.onFocus] hears of calls. False for
  /// a session that plays nothing for a long time (the nap until its wake).
  final bool focus;

  /// A second button on the card beside Stop, with these words (the work session's "Back" while on a break); its tap
  /// reaches [SessionKeeper.onButton]. Null: Stop only.
  final String? button;
}

abstract class SessionKeeper {
  /// Starts keeping the session; call it while the app is on screen. True when the phone may now be locked: the
  /// service runs with everything [spec] asked for. False (never an error): keep the screen on as before.
  Future<bool> hold(KeepSpec spec);

  /// Ends it (harmless when nothing is held).
  Future<void> release();

  /// Stop was tapped on the notification or the lock screen.
  void Function()? onStop;

  /// The card's second button ([KeepSpec.button]) was tapped.
  void Function()? onButton;

  /// A call or another app took the sound, or it came back (only with [KeepSpec.focus]).
  void Function(FocusChange change)? onFocus;
}

/// The phone's keeper. One per screen; only the one that held last gets the Stop tap and may release.
class PhoneSessionKeeper implements SessionKeeper {
  static const MethodChannel _channel = MethodChannel('eeg_tracker/session');
  static PhoneSessionKeeper? _holder;
  static bool _listening = false;

  /// One call at a time, in order: a release must not overtake the hold before it.
  static Future<void> _queue = Future<void>.value();

  @override
  void Function()? onStop;

  @override
  void Function()? onButton;

  @override
  void Function(FocusChange change)? onFocus;

  static const Map<String, FocusChange> _focusWords = {
    'loss': FocusChange.lost,
    'lossTransient': FocusChange.paused,
    'duck': FocusChange.duck,
    'gain': FocusChange.back,
  };

  static Future<T> _next<T>(Future<T> Function() call) {
    final done = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await call());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  @override
  Future<bool> hold(KeepSpec spec) {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'stopTapped') _holder?.onStop?.call();
        if (call.method == 'buttonTapped') _holder?.onButton?.call();
        final focus = call.method == 'focus' ? _focusWords[call.arguments] : null;
        if (focus != null) _holder?.onFocus?.call(focus);
      });
    }
    _holder = this;
    return _next(() async {
      try {
        final kept = await _channel.invokeListMethod<String>('hold', {
          'title': spec.title,
          'text': spec.text,
          'headband': spec.headband,
          'microphone': spec.microphone,
          'focus': spec.focus,
          'button': ?spec.button,
        });
        if (kept == null) return false;
        return (!spec.headband || kept.contains('headband')) && (!spec.microphone || kept.contains('microphone'));
      } on PlatformException {
        return false;
      } on MissingPluginException {
        return false; // not Android, or a test without the channel
      }
    });
  }

  @override
  Future<void> release() {
    if (!identical(_holder, this)) return Future<void>.value();
    _holder = null;
    return _next(() async {
      if (_holder != null) return; // another session took over meanwhile
      try {
        await _channel.invokeMethod<void>('release');
      } on PlatformException {
        // nothing to release
      } on MissingPluginException {
        // not Android
      }
    });
  }
}

/// For tests: remembers what was asked. [grant] false plays a phone that refuses the service.
class FakeSessionKeeper implements SessionKeeper {
  FakeSessionKeeper({this.grant = true, List<String>? log}) : log = log ?? [];
  bool grant;

  /// 'hold' and 'release' in the order they came (shared with other fakes to check an order).
  final List<String> log;
  KeepSpec? spec;
  bool held = false;

  @override
  void Function()? onStop;

  @override
  void Function()? onButton;

  @override
  void Function(FocusChange change)? onFocus;

  @override
  Future<bool> hold(KeepSpec spec) async {
    this.spec = spec;
    held = true;
    log.add('hold');
    return grant;
  }

  @override
  Future<void> release() async {
    if (!held) return;
    held = false;
    log.add('release');
  }
}
