import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:web/web.dart' as web;

/// Resolves a `pubspec.yaml` asset key (e.g. `assets/sounds/x.wav`) to the
/// URL Flutter Web actually serves it at. Flutter Web buckets every bundled
/// asset under an extra `assets/` prefix (confirmed against a real build's
/// output tree: `assets/sounds/x.wav` ends up at `assets/assets/sounds/x.wav`
/// relative to `index.html`) — this mirrors that without needing an async
/// asset-manifest lookup, since [AudioPlaybackService.unlock] must set this
/// synchronously inside a user-gesture callstack.
String _webAssetUrl(String assetKey) => 'assets/$assetKey';

/// Owns all TTS/cue playback.
///
/// Two independent, separately-confirmed iOS Safari constraints shaped this
/// design (see `app/README.md` for the two regressions that led here):
///
/// 1. **A single, never-recreated `<audio>` element, once played from a
///    real user gesture, can have its `src` reassigned and be `play()`ed
///    again indefinitely — no further gesture required.** This is the
///    standard, widely-documented iOS "unlock" pattern. The `audioplayers`
///    package (used originally) instead destroys and recreates the
///    underlying `<audio>` element on every source change, which defeats
///    this and was the root cause of "long replies don't autoplay".
/// 2. **iOS Safari's mute (ring/silent) switch and volume buttons are only
///    respected by playback through a real `<audio>`/`<video>` element —
///    never by the Web Audio API** (`AudioContext`/`GainNode`); a
///    `GainNode`'s gain is a purely internal, relative scale factor and
///    cannot restore hardware mute/volume behavior (confirmed against
///    Apple's own developer forums). A pure-`AudioContext` rewrite (used
///    briefly before this) fixed constraint 1 but reintroduced this:
///    replies played at a fixed volume regardless of the phone's mute
///    switch or volume buttons — and, because a suspended `AudioContext`'s
///    clock just freezes rather than rejecting playback, any reply whose
///    context got suspended by the OS (screen lock, backgrounding, a call)
///    mid-request would silently queue and later fire alongside other
///    stuck replies once the context resumed, instead of failing.
///
/// The reply/voice audio — the part that actually matters for not
/// startling someone in a quiet room, and that needs to survive slow
/// ("長考") replies — plays through ONE persistent, reused `<audio>`
/// element (never destroyed, only `src` reassigned): correct mute-switch
/// and volume-button behavior, immune to reply latency, and immune to the
/// "queues silently, all fire later" failure mode (`<audio>.play()`
/// rejects instead of hanging when blocked). The short decorative "pon"
/// cue is low-stakes UI feedback, not the user-facing voice content, and
/// still goes through a lightweight Web Audio buffer — the same trade-off
/// many apps make for brief UI sound effects.
class AudioPlaybackService {
  web.HTMLAudioElement? _replyElement;
  web.AudioContext? _cueContext;
  bool _unlocked = false;

  Completer<void>? _activeCompleter;
  StreamSubscription<web.Event>? _endedSubscription;
  StreamSubscription<web.Event>? _errorSubscription;

  static const _playStartTimeout = Duration(seconds: 5);
  // A safety net only, for a genuinely stuck/hung element — not meant to
  // bound how long a normal reply is allowed to run. 30s cut off replies
  // that were simply a bit long but entirely normal (a few hundred
  // characters of Japanese speech easily exceeds 30s); nothing about a
  // reply's own length is capped elsewhere (see CLAUDE_MAX_TOKENS in the
  // conversation Lambda), so this must comfortably outlast any realistic
  // one-turn reply while still catching an actually-stuck element.
  static const _completionTimeout = Duration(minutes: 5);

  web.HTMLAudioElement _ensureReplyElement() {
    final existing = _replyElement;
    if (existing != null) return existing;
    final element = web.HTMLAudioElement()..preload = 'auto';
    element.style.setProperty('display', 'none');
    web.document.body?.append(element);
    return _replyElement = element;
  }

  /// Must be invoked synchronously (before any other `await`) from inside a
  /// real user-gesture handler — a button tap — so the very first `play()`
  /// on the persistent reply element is attributed to that gesture. Safe to
  /// call on every tap: once actually unlocked, this is a cheap no-op for
  /// the rest of the page's lifetime (see class doc, point 1).
  Future<void> unlock() async {
    if (_unlocked) return;
    final element = _ensureReplyElement();
    try {
      element.src = _webAssetUrl('assets/sounds/unlock_silent.wav');
      await element.play().toDart.timeout(_playStartTimeout);
      _unlocked = true;
    } catch (e) {
      // Best-effort only; if this didn't actually unlock anything, the
      // next real play() attempt will surface that on its own.
      debugPrint('<audio> unlock failed: $e');
    }
  }

  /// Soft "pon" cue meaning "you may act now" — played both when the mic
  /// starts listening and when the reply has finished being read aloud.
  /// Best-effort and fire-and-forget: never awaited by callers, so a slow
  /// or blocked context can't delay the conversation flow over a cue sound.
  Future<void> playCue() async {
    try {
      final context = _cueContext ??= web.AudioContext();
      if (context.state == 'suspended') {
        await context.resume().toDart.timeout(_playStartTimeout);
      }
      if (context.state != 'running') return;
      final byteData = await rootBundle.load('assets/sounds/silence_cue.wav');
      final buffer = await context.decodeAudioData(byteData.buffer.toJS).toDart;
      final source = context.createBufferSource();
      source.buffer = buffer;
      final gain = context.createGain();
      gain.gain.value = 0.18;
      source.connect(gain);
      gain.connect(context.destination);
      source.start();
    } catch (e) {
      // Purely a nice-to-have UI cue — never let it affect the actual
      // conversation flow.
      debugPrint('Ready cue playback failed: $e');
    }
  }

  /// Plays [url] through the persistent reply `<audio>` element, waiting
  /// for it to finish (or for [stop] to be called). Throws on failure —
  /// callers decide whether that's worth surfacing (autoplay being blocked
  /// is expected/silent for an automatic reply, but not for a manual replay
  /// tap).
  Future<void> play(String url) async {
    if (!_unlocked) {
      // Nothing has successfully unlocked the element yet (e.g. the very
      // first gesture's unlock() attempt itself failed) — this call is
      // itself gesture-adjacent (a mic/send tap led here), so it's worth
      // one more direct attempt before giving up.
      await unlock();
    }
    final element = _ensureReplyElement();

    final completer = Completer<void>();
    _activeCompleter = completer;
    await _endedSubscription?.cancel();
    await _errorSubscription?.cancel();
    _endedSubscription = element.onEnded.listen((_) {
      if (!completer.isCompleted) completer.complete();
    });
    _errorSubscription = element.onError.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('<audio> element playback error'));
      }
    });

    try {
      // Never let a previous reply/cue keep playing underneath a new one.
      element.pause();
      element.src = url;
      element.currentTime = 0;
      await element.play().toDart.timeout(_playStartTimeout);
      // The 'ended' event is what normally completes this, but bound the
      // wait in case it never fires for some reason — this must never hang
      // the caller (and therefore the conversation flow) forever.
      await completer.future.timeout(_completionTimeout, onTimeout: () {
        element.pause();
      });
    } finally {
      await _endedSubscription?.cancel();
      await _errorSubscription?.cancel();
      _endedSubscription = null;
      _errorSubscription = null;
      if (identical(_activeCompleter, completer)) _activeCompleter = null;
    }
  }

  /// Stops whatever reply/manual-replay audio [play] is currently awaiting.
  Future<void> stop() async {
    _replyElement?.pause();
    _activeCompleter?.complete();
    _activeCompleter = null;
  }

  void dispose() {
    _replyElement?.pause();
    _replyElement?.remove();
    _replyElement = null;
    unawaited(_cueContext?.close().toDart ?? Future.value());
    _cueContext = null;
  }
}
