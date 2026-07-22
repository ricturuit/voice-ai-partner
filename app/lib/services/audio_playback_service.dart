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
///
/// Two follow-up problems showed up in real iOS Safari use after switching
/// to a raw `AudioContext`, both addressed below:
///
/// 1. **Playback ignored the hardware mute switch and volume buttons.** iOS
///    Safari puts a page's audio session in the "playback" category (which
///    ignores the silent-mode switch and can behave oddly with the volume
///    buttons) unless at least one plain `<audio>`/`<video>` element is also
///    actively playing on the page — a raw `AudioContext` with no
///    `HTMLMediaElement` involved at all defaults to that category. See
///    [_ensureAmbientCategoryLoop]: a single silent `<audio>` element, whose
///    `src` is set once and never changed again (so it can't hit the
///    swap-requires-a-new-gesture problem above), is kept looping for the
///    whole session purely to keep the page in the mute-switch-respecting
///    "ambient" category.
/// 2. **Audio queued up and all played at once after backgrounding/reopening
///    the tab.** iOS can suspend (or "interrupt") an `AudioContext` on its
///    own — screen lock, backgrounding, a phone call — independently of the
///    page's own code. A `BufferSourceNode.start()` call schedules playback
///    against the context's clock; if that clock is frozen because the
///    context is suspended, the node just sits there having "started" but
///    never actually rendering, and every such node fires together the
///    moment the context resumes. [play] now insists on a working (resumed)
///    context immediately before scheduling — if resuming fails, it fails
///    loudly instead of silently queuing a node for some arbitrary future
///    moment — and always stops/disconnects the previous node before a new
///    one starts, so at most one is ever alive.
class AudioPlaybackService {
  web.AudioContext? _context;
  web.HTMLAudioElement? _ambientLoopElement;
  web.AudioBufferSourceNode? _activeSource;
  Completer<void>? _activeCompleter;

  static const _resumeTimeout = Duration(seconds: 5);
  static const _completionTimeout = Duration(seconds: 30);

  web.AudioContext _ensureContext() => _context ??= web.AudioContext();

  /// Primes the browser to allow playback later in this session. Must be
  /// invoked synchronously (before any other `await`) from inside a real
  /// user-gesture handler — a button tap — so the underlying `resume()`
  /// call (and the ambient-category loop's `play()`) is attributed to that
  /// gesture. Safe to call on every tap: once both are actually running,
  /// this and all future calls are cheap no-ops for the rest of the page's
  /// lifetime.
  Future<void> unlock() async {
    await Future.wait([
      _resumeContext(),
      _ensureAmbientCategoryLoop(),
    ]);
  }

  Future<void> _resumeContext() async {
    final context = _ensureContext();
    if (context.state != 'suspended') return;
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

  /// Keeps a plain (non-Web-Audio) `<audio>` element silently looping for
  /// the whole session — see the class doc for why. Its `src` is a
  /// same-origin blob URL built once from the bundled silent WAV asset and
  /// is never reassigned, so this element is never subject to the "new
  /// source needs a new gesture" restriction.
  Future<void> _ensureAmbientCategoryLoop() async {
    if (_ambientLoopElement != null) return;
    try {
      final byteData = await rootBundle.load('assets/sounds/unlock_silent.wav');
      final blob = web.Blob(
        [byteData.buffer.toJS].toJS,
        web.BlobPropertyBag(type: 'audio/wav'),
      );
      final element = web.HTMLAudioElement()
        ..src = web.URL.createObjectURL(blob)
        ..loop = true
        ..volume = 1.0; // the asset itself is all-zero samples — inaudible.
      await element.play().toDart.timeout(_resumeTimeout);
      _ambientLoopElement = element;
    } catch (e) {
      debugPrint('Ambient-category silent loop failed to start: $e');
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

  /// Stops and disconnects whatever source node is currently tracked as
  /// active, if any, so it can never fire later. Always call this before
  /// starting a new node and whenever giving up on the current one.
  void _killActiveSource() {
    final source = _activeSource;
    _activeSource = null;
    if (source == null) return;
    try {
      source.stop();
    } catch (_) {
      // Already stopped/finished — fine, we're disconnecting it either way.
    }
    try {
      source.disconnect();
    } catch (_) {}
  }

  /// Soft "pon" cue meaning "you may act now" — played both when the mic
  /// starts listening and when the reply has finished being read aloud.
  /// Best-effort and fire-and-forget: never awaited by callers, so a slow
  /// or blocked context can't delay the conversation flow over a cue sound.
  Future<void> playCue() async {
    try {
      await _resumeContext();
      if (_ensureContext().state != 'running') return;
      final buffer = await _loadAssetAndDecode('assets/sounds/silence_cue.wav');
      final context = _ensureContext();
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

    // The context can have been suspended by the OS (screen lock, a call,
    // backgrounding, ...) independently of anything this app did, any time
    // between the last unlock() and now — the round trip to fetch/decode
    // the reply above is itself a real window for that. Insist on a
    // working context right before scheduling: if it won't resume, fail
    // loudly now rather than silently scheduling a node that would only
    // fire whenever the context happens to recover, possibly stacked
        // together with other stale attempts (see class doc, point 2).
    await _resumeContext();
    final context = _ensureContext();
    if (context.state != 'running') {
      throw StateError('AudioContext is not running (state: ${context.state})');
    }

    // Never let two source nodes be alive at once — an overlapping manual
    // replay, or a previous attempt this method gave up waiting on, must
    // not be left running/pending underneath a new one.
    _killActiveSource();

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
      // fire if the context somehow stops rendering mid-playback (e.g. an
      // OS interruption) — bound the wait, and give up on this node for
      // good rather than leaving it to potentially fire later.
      await completer.future.timeout(_completionTimeout, onTimeout: _killActiveSource);
    } finally {
      await subscription.cancel();
      if (identical(_activeSource, source)) _activeSource = null;
      _activeCompleter = null;
    }
  }

  /// Stops whatever reply/manual-replay audio [play] is currently awaiting.
  Future<void> stop() async {
    _killActiveSource();
    _activeCompleter?.complete();
    _activeCompleter = null;
  }

  void dispose() {
    _killActiveSource();
    _ambientLoopElement?.pause();
    _ambientLoopElement = null;
    unawaited(_context?.close().toDart ?? Future.value());
    _context = null;
  }
}
