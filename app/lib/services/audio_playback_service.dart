import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Owns all TTS/cue playback and the browser-autoplay "unlock" workaround.
///
/// Browsers only allow audio to autoplay without a fresh user gesture when it
/// is the continuation of an already-playing session tied to a real click/
/// tap — a brand-new play() call issued later (e.g. once a slow reply
/// finally arrives) gets silently blocked, with no error and no visible
/// audio-activity indicator. The workaround: start one continuously-looping
/// silent clip the instant a real user gesture is available (see [unlock]),
/// and never issue a fresh play() call for the sole purpose of staying
/// "unlocked" — once a reply is ready, swap this same player's source to it
/// (interrupting the loop), then resume the loop afterwards so the *next*
/// reply — however long the wait — stays covered too.
class AudioPlaybackService {
  final AudioPlayer _player = AudioPlayer();
  // Separate player for the short "ready to speak"/"your turn" cue so it
  // never gets tangled up with the reply-audio playback logic below.
  final AudioPlayer _cuePlayer = AudioPlayer();

  bool _silentLoopActive = false;
  Future<void>? _silentLoopStarting;

  // Several call sites (unlock's loop-start and play()'s real playback) can
  // race on this same AudioPlayer — audioplayers_web's WrappedPlayer mutates
  // shared, non-atomic state across await points inside play(), so any two
  // overlapping calls can corrupt that state and leave playback broken for
  // the rest of the session. Funnel every call through this queue so at
  // most one is ever in flight at a time.
  Future<void> _opQueue = Future.value();

  // audioPlayer.play()'s returned Future can sometimes never resolve or
  // reject at all when the browser silently blocks a non-gesture-linked
  // play() call. Every op run through [_runQueued] is bounded by this
  // timeout specifically so a single hung call (most likely the silent
  // loop's start) can't wedge every operation queued after it.
  static const _opTimeout = Duration(seconds: 10);
  static const _completionTimeout = Duration(seconds: 30);

  Completer<void>? _activeCompleter;

  /// Primes the browser to allow autoplay later in this session. Must be
  /// invoked synchronously (before any `await`) from inside a real
  /// user-gesture handler — a button tap — so the resulting play() call is
  /// attributed to that gesture. Callers still mid-gesture (e.g. right
  /// before starting speech recognition) should NOT await this, since doing
  /// so delays whatever else the gesture needs to do; callers past the
  /// gesture (e.g. right before an API call) should await it.
  Future<void> unlock() {
    if (_silentLoopActive) return Future.value();
    final existing = _silentLoopStarting;
    if (existing != null) return existing;
    final future = _startSilentLoop();
    _silentLoopStarting = future;
    future.whenComplete(() {
      if (identical(_silentLoopStarting, future)) _silentLoopStarting = null;
    });
    return future;
  }

  Future<void> _startSilentLoop() async {
    try {
      await _runQueued(() async {
        await _player.setReleaseMode(ReleaseMode.loop);
        // volume: 0.0 is safe here since every real playback call below
        // passes its own explicit volume, so nothing depends on inheriting
        // whatever this loop last set. Zeroing the gain — on top of the
        // asset already being silent — is also a defensive measure against
        // the browser's echo-cancellation/AGC pipeline treating this
        // continuously-active output as "audio is playing" and suppressing
        // quiet mic input while it runs.
        await _player.play(AssetSource('sounds/unlock_silent.wav'), volume: 0.0);
      });
      _silentLoopActive = true;
    } catch (e) {
      // Purely a best-effort unlock; never let it affect the actual flow.
      // Leave _silentLoopActive false so the next caller retries instead of
      // assuming coverage that was never actually achieved.
      debugPrint('Silent audio-unlock loop failed to start: $e');
    }
  }

  /// Soft "pon" cue meaning "you may act now".
  Future<void> playCue() async {
    try {
      await _cuePlayer.play(AssetSource('sounds/silence_cue.wav'), volume: 0.18);
    } catch (e) {
      // Purely a nice-to-have UI cue — never let it affect the actual
      // conversation flow.
      debugPrint('Ready cue playback failed: $e');
    }
  }

  /// Plays [url] and waits for it to finish (or for [stop] to be called).
  /// Resumes the silent unlock loop afterwards. Throws on failure —
  /// callers decide whether that's worth surfacing to the user (autoplay
  /// being blocked is expected/silent for an automatic reply, but not for a
  /// manual replay tap).
  Future<void> play(String url) async {
    // About to interrupt the silent loop (if any) by swapping this
    // player's source to the real reply — mark it inactive so a concurrent
    // unlock() caller doesn't wrongly think coverage still exists, and so
    // it gets resumed (see finally below) rather than skipped as a no-op.
    _silentLoopActive = false;
    final completer = Completer<void>();
    _activeCompleter = completer;
    final subscription = _player.onPlayerComplete.listen((_) {
      if (!completer.isCompleted) completer.complete();
    });
    try {
      // play() resolves once playback *starts*, not once it finishes, and
      // some browsers leave it pending forever if autoplay is blocked —
      // _runQueued already bounds it with _opTimeout, so no separate
      // timeout is needed here. Once it resolves (or times out),
      // separately wait for the real completion event.
      await _runQueued(() async {
        await _player.setReleaseMode(ReleaseMode.release);
        await _player.play(UrlSource(url), volume: 1.0);
      });
      await completer.future.timeout(_completionTimeout, onTimeout: () {});
    } catch (e) {
      // Always log so playback failures (blocked autoplay, CORS, expired
      // signed URL, ...) are visible in the browser console.
      debugPrint('Audio playback failed for $url: $e');
      rethrow;
    } finally {
      await subscription.cancel();
      _activeCompleter = null;
      // Not awaited — best-effort background upkeep, not something the
      // caller needs to wait on.
      unawaited(unlock());
    }
  }

  /// Stops whatever is currently playing. [play]'s completer doesn't fire
  /// from AudioPlayer.stop() alone (it doesn't emit onPlayerComplete), so
  /// this completes it directly to unblock a pending [play] call.
  Future<void> stop() async {
    await _player.stop();
    _activeCompleter?.complete();
  }

  Future<T> _runQueued<T>(Future<T> Function() action) {
    final scheduled = _opQueue.then((_) => action().timeout(_opTimeout));
    // Chain the *next* op off this one regardless of whether it succeeds —
    // a failed play() must not wedge every subsequent queued call behind a
    // permanently-unresolved future. Errors still propagate to whoever
    // awaits `scheduled` directly.
    _opQueue = scheduled.then((_) {}, onError: (_) {});
    return scheduled;
  }

  void dispose() {
    _player.dispose();
    _cuePlayer.dispose();
  }
}
