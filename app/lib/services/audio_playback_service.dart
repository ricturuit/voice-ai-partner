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
  // Guards re-priming (see [unlock]) against interrupting a reply that is
  // genuinely playing right now. This is NOT an "already unlocked" latch —
  // see unlock()'s doc comment for why such a latch must never exist here.
  bool _isPlayingReply = false;

  Completer<void>? _activeCompleter;
  // Bumped for every play(); a call whose generation is stale must not touch
  // shared state in its `finally`, since a newer call already owns it.
  int _playGeneration = 0;

  double _playbackRate = 1.0;

  /// Playback speed applied to reply audio, as a multiplier. Takes effect
  /// immediately, including on audio that is already playing, so a learner
  /// can slow a reply down while it's being read rather than after.
  set playbackRate(double rate) {
    _playbackRate = rate;
    final element = _replyElement;
    if (element == null) return;
    element.preservesPitch = true;
    element.playbackRate = rate;
  }

  /// Why the last playback attempt failed, if it did. Surfaced in the UI so a
  /// recurrence is reportable with the actual browser error rather than just
  /// "sometimes there's no sound" — the ambiguity that has repeatedly cost
  /// this project days of guessing.
  String? lastFailureReason;

  /// How many times [unlock] has actually attempted to prime the element.
  /// Exists so a test can assert that priming happens on *every* gesture —
  /// the invariant whose violation caused this bug twice. See [unlock].
  @visibleForTesting
  int primeAttempts = 0;

  // Priming plays a small, bundled, already-cached asset, so if it hasn't
  // started in a few seconds it isn't going to.
  static const _primeStartTimeout = Duration(seconds: 5);
  // A reply, by contrast, is an MP3 fetched over the network: play() only
  // resolves once enough has buffered to begin, which on a phone connection
  // can legitimately take a while for a long reply. The old 5s bound here
  // aborted those — turning "slow to load" into "no audio at all". A policy
  // block (NotAllowedError) rejects essentially instantly, so waiting longer
  // costs nothing for the case this timeout actually exists to catch.
  static const _replyStartTimeout = Duration(seconds: 30);
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

  /// Re-primes the reply element for gesture-free playback later in the
  /// turn. Must be invoked synchronously (before any other `await`) from
  /// inside a real user-gesture handler — a button tap — so the `play()`
  /// below is attributed to that gesture.
  ///
  /// **This deliberately re-primes on EVERY call and must never be latched
  /// behind an "already unlocked" boolean.** An earlier version of this
  /// service did exactly that (`if (_unlocked) return;`), which silently
  /// reintroduced a regression this project had already diagnosed and
  /// fixed once before, in the AudioContext era: see `README.md` §"修正:
  /// スマホで数ターン後に自動再生が止まる不具合(2026-07-17)", where a
  /// one-shot `_audioContextUnlocked` flag produced precisely this
  /// symptom (first turn or two play, then autoplay stops for the rest of
  /// the session while manual replay keeps working), and deleting the flag
  /// so every tap re-primes was the fix.
  ///
  /// The reason a latch cannot work: iOS Safari's "this element may play
  /// without a gesture" state is not permanent. Backgrounding the tab,
  /// locking the screen, or an audio-session interruption can revoke it,
  /// and nothing notifies the page when that happens. A latch turns that
  /// silent revocation into a permanent failure, because the one code path
  /// that could restore the permission — touching the element inside a
  /// real gesture — is exactly the path the latch skips. Re-priming costs
  /// one ~100ms silent asset play (cached after the first) per tap, which
  /// is a trivial price for not losing audio for the rest of the session.
  Future<void> unlock() async {
    // Never yank the source out from under a reply that is actually
    // playing — this is the one case where re-priming would do harm.
    if (_isPlayingReply) return;
    primeAttempts++;
    final element = _ensureReplyElement();
    try {
      element.src = _webAssetUrl('assets/sounds/unlock_silent.wav');
      await element.play().toDart.timeout(_primeStartTimeout);
      // The asset is ~100ms of silence and would end on its own, but stop
      // it explicitly so the element is idle before the real reply swaps
      // the source in.
      //
      // Re-check the guard rather than trusting the one at the top of this
      // method: everything above is asynchronous, so a reply can have
      // started playing on this same element in the meantime, and pausing
      // unconditionally here would silence it — an intermittent "no audio"
      // whose trigger is purely how long the prime's play() took to settle.
      if (!_isPlayingReply) element.pause();
    } catch (e) {
      // Best-effort only; if this didn't actually prime anything, the next
      // real play() attempt surfaces that to the caller (which now shows
      // the user a tap-to-play affordance rather than failing silently).
      debugPrint('<audio> unlock/prime failed: $e');
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
        await context.resume().toDart.timeout(_primeStartTimeout);
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
    // Deliberately does NOT try to unlock() here as a fallback: by this
    // point the originating tap is long over (the API round-trip happened
    // in between), so a prime issued now carries no gesture and cannot
    // grant permission the element doesn't already have. Priming only ever
    // works at gesture time — see unlock(). If playback is blocked anyway,
    // this method throws and the caller offers the user a tap-to-play
    // affordance, which does carry a fresh gesture.
    final element = _ensureReplyElement();

    // There is one element, so a second play() necessarily takes the first
    // one's playback away. Release the earlier caller explicitly instead of
    // orphaning it: it is sitting on `completer.future`, and without this it
    // would wait out the full completion timeout — with the conversation's
    // input controls locked the whole time — for audio that stopped long
    // ago. Reachable today by tapping a bubble's replay button while a reply
    // is still being read aloud.
    _releaseActivePlayback();

    final generation = ++_playGeneration;
    final completer = Completer<void>();
    _activeCompleter = completer;
    final endedSubscription = element.onEnded.listen((_) {
      if (!completer.isCompleted) completer.complete();
    });
    final errorSubscription = element.onError.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('<audio> element playback error'));
      }
    });

    try {
      _isPlayingReply = true;
      // Never let a previous reply/prime keep playing underneath a new one.
      element.pause();
      // Assigning src resets playback to the start on its own; no
      // currentTime seek is needed (and seeking before the new source has
      // loaded is a no-op that only muddies the state).
      element.src = url;
      element.preservesPitch = true;
      element.playbackRate = _playbackRate;
      await element.play().toDart.timeout(_replyStartTimeout);
      lastFailureReason = null;
      // The 'ended' event is what normally completes this, but bound the
      // wait in case it never fires for some reason — this must never hang
      // the caller (and therefore the conversation flow) forever.
      await completer.future.timeout(_completionTimeout, onTimeout: () {
        element.pause();
      });
    } catch (e) {
      lastFailureReason = e.toString();
      rethrow;
    } finally {
      await endedSubscription.cancel();
      await errorSubscription.cancel();
      // A newer play() has already taken ownership of the shared state;
      // leave it alone rather than clobbering the live playback's flags.
      if (_playGeneration == generation) {
        _isPlayingReply = false;
        if (identical(_activeCompleter, completer)) _activeCompleter = null;
      }
    }
  }

  /// Completes whatever [play] call is currently waiting, so it can unwind
  /// instead of waiting for audio that is about to be replaced or stopped.
  void _releaseActivePlayback() {
    final active = _activeCompleter;
    _activeCompleter = null;
    if (active != null && !active.isCompleted) active.complete();
  }

  /// Stops whatever reply/manual-replay audio [play] is currently awaiting.
  Future<void> stop() async {
    _replyElement?.pause();
    _releaseActivePlayback();
  }

  void dispose() {
    _releaseActivePlayback();
    _replyElement?.pause();
    _replyElement?.remove();
    _replyElement = null;
    unawaited(_cueContext?.close().toDart ?? Future.value());
    _cueContext = null;
  }
}
