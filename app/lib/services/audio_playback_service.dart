import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:web/web.dart' as web;

/// Owns all TTS/cue playback, built directly on the Web Audio API.
///
/// Browsers only allow audio to play without a fresh user gesture through an
/// `AudioContext` that a user gesture has already resumed — once resumed,
/// that SAME context can schedule and play any number of buffers at any
/// later time (however long the wait) with no further gesture required. See
/// [unlock].
///
/// This deliberately does not use the `audioplayers` package's
/// `<audio>`-element-based playback. That package recreates the underlying
/// `HTMLAudioElement` (and reconnects it to the audio graph) every time the
/// source URL changes — a previous version of this service relied on
/// swapping a single `AudioPlayer`'s source from a silent "unlock" loop to
/// the real reply audio, on the theory that this counted as one continuous,
/// already-gesture-authorized playback session. In practice each swap is a
/// brand-new element under the hood, and some browsers (notably iOS Safari)
/// require a fresh user gesture for that new element regardless of how
/// "unlocked" the page seemed a moment earlier. That mismatch was the actual
/// cause of "reply audio doesn't autoplay, only text shows up" for slow
/// replies: the swap silently failed once the API round-trip outlasted the
/// original tap. Playing everything through one persistent `AudioContext`
/// instead sidesteps this entirely, since nothing about scheduling a new
/// buffer on an already-running context is gated by recency of a gesture.
class AudioPlaybackService {
  web.AudioContext? _context;
  web.AudioBufferSourceNode? _activeSource;
  Completer<void>? _activeCompleter;

  web.AudioContext _ensureContext() => _context ??= web.AudioContext();

  /// Primes the browser to allow playback later in this session. Must be
  /// invoked synchronously (before any other `await`) from inside a real
  /// user-gesture handler — a button tap — so the underlying `resume()`
  /// call is attributed to that gesture. Safe to call on every tap: once
  /// the context is actually resumed, this and all future calls are cheap
  /// no-ops for the rest of the page's lifetime.
  static const _resumeTimeout = Duration(seconds: 5);
  static const _completionTimeout = Duration(seconds: 30);

  Future<void> unlock() async {
    final context = _ensureContext();
    if (context.state == 'suspended') {
      try {
        // Without a genuine user gesture behind this call (e.g. this ever
        // runs in an automated/headless context), resume() can sit pending
        // forever rather than resolving or rejecting — bound it so a single
        // bad call can't hang every future await of this method.
        await context.resume().toDart.timeout(_resumeTimeout);
      } catch (e) {
        // Best-effort only; if this didn't actually unlock anything, the
        // next real play() attempt will surface that on its own.
        debugPrint('AudioContext resume failed: $e');
      }
    }
  }

  Future<web.AudioBuffer> _fetchAndDecode(String url) async {
    final response = await web.window.fetch(url.toJS).toDart;
    final data = await response.arrayBuffer().toDart;
    return _ensureContext().decodeAudioData(data).toDart;
  }

  Future<web.AudioBuffer> _loadAssetAndDecode(String assetKey) async {
    final byteData = await rootBundle.load(assetKey);
    return _ensureContext().decodeAudioData(byteData.buffer.toJS).toDart;
  }

  void _playBuffer(web.AudioBuffer buffer, {required double volume}) {
    final context = _ensureContext();
    final source = context.createBufferSource();
    source.buffer = buffer;
    final gain = context.createGain();
    gain.gain.value = volume;
    source.connect(gain);
    gain.connect(context.destination);
    source.start();
  }

  /// Soft "pon" cue meaning "you may act now" — played both when the mic
  /// starts listening and when the reply has finished being read aloud.
  Future<void> playCue() async {
    try {
      final buffer = await _loadAssetAndDecode('assets/sounds/silence_cue.wav');
      _playBuffer(buffer, volume: 0.18);
    } catch (e) {
      // Purely a nice-to-have UI cue — never let it affect the actual
      // conversation flow.
      debugPrint('Ready cue playback failed: $e');
    }
  }

  /// Fetches, decodes, and plays [url], waiting for it to finish (or for
  /// [stop] to be called). Throws on failure — callers decide whether
  /// that's worth surfacing (autoplay being blocked is expected/silent for
  /// an automatic reply, but not for a manual replay tap).
  Future<void> play(String url) async {
    final web.AudioBuffer buffer;
    try {
      buffer = await _fetchAndDecode(url);
    } catch (e) {
      debugPrint('Audio fetch/decode failed for $url: $e');
      rethrow;
    }

    final context = _ensureContext();
    final source = context.createBufferSource();
    source.buffer = buffer;
    final gain = context.createGain();
    gain.gain.value = 1.0;
    source.connect(gain);
    gain.connect(context.destination);

    final completer = Completer<void>();
    _activeCompleter = completer;
    _activeSource = source;
    final subscription = source.onEnded.listen((_) {
      if (!completer.isCompleted) completer.complete();
    });
    try {
      source.start();
      // The 'ended' event is what normally completes this, but it can never
      // fire if the context somehow never renders (e.g. stuck suspended) —
      // bound the wait so that can't hang the caller forever.
      await completer.future.timeout(_completionTimeout, onTimeout: () {});
    } finally {
      await subscription.cancel();
      if (identical(_activeSource, source)) _activeSource = null;
      _activeCompleter = null;
    }
  }

  /// Stops whatever reply/manual-replay audio [play] is currently awaiting.
  Future<void> stop() async {
    try {
      _activeSource?.stop();
    } catch (e) {
      // stop() throws if the source already finished naturally right
      // before this call landed — harmless, the completer below still
      // needs firing either way.
      debugPrint('AudioBufferSourceNode.stop() failed: $e');
    }
    _activeSource = null;
    _activeCompleter?.complete();
    _activeCompleter = null;
  }

  void dispose() {
    unawaited(stop());
    unawaited(_context?.close().toDart ?? Future.value());
    _context = null;
  }
}
