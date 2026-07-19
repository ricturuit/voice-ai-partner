import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../services/conversation_api.dart';

const int minSilenceThresholdSeconds = 2;
const int maxSilenceThresholdSeconds = 10;

/// Holds all conversation state and STT/TTS logic shared between the chat
/// screen and the voice-call screen, so both can drive the same
/// session/history and stay in sync regardless of which one is on screen.
class ConversationController extends ChangeNotifier {
  // Generated once when the app starts and kept for the lifetime of this
  // browser tab/session — never persisted or regenerated mid-session.
  late final String sessionId;

  final ConversationApi _api = ConversationApi();
  final AudioPlayer audioPlayer = AudioPlayer();
  // Separate player for the short "ready to speak" cue so it never gets
  // tangled up with the reply-audio playback logic below.
  final AudioPlayer _cuePlayer = AudioPlayer();
  final SpeechToText _speech = SpeechToText();
  final TextEditingController inputTextController = TextEditingController();
  final List<ChatMessage> messages = [];

  final StreamController<String> _errorStreamController = StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorStreamController.stream;

  bool isSending = false;
  // True from the moment a reply's audio starts until it finishes (or is
  // force-stopped). Mic input and the send button are locked during this
  // window — see README.md for why — but the text field stays usable so the
  // user can type ahead.
  bool isPlayingReply = false;
  bool speechInitDone = false;
  bool speechAvailable = false;
  bool isListening = false;

  // Configurable silence threshold: how many seconds of no new recognized
  // speech before we auto-send. Also doubles as the visible countdown
  // duration.
  int silenceThresholdSeconds = minSilenceThresholdSeconds;
  Timer? _silenceTimer;
  int? silenceCountdown;

  // Brief grace period right after starting to listen during which we
  // ignore silence-countdown triggers, in case the recognizer delivers a
  // spurious very-early result right as it starts up.
  static const _postListenGracePeriod = Duration(seconds: 1);
  DateTime? _silenceGuardUntil;

  // Lets the force-stop button unblock an in-progress reply playback wait
  // immediately (AudioPlayer.stop() does not itself fire onPlayerComplete).
  Completer<void>? _replayCompleter;

  ConversationController() {
    sessionId = const Uuid().v4();
    _initSpeech();
  }

  @override
  void dispose() {
    _silenceTimer?.cancel();
    inputTextController.dispose();
    audioPlayer.dispose();
    _cuePlayer.dispose();
    _speech.stop();
    _errorStreamController.close();
    super.dispose();
  }

  void _emitError(String message) {
    if (_errorStreamController.isClosed) return;
    _errorStreamController.add(message);
  }

  Future<void> _initSpeech() async {
    // On web this checks for `SpeechRecognition`/`webkitSpeechRecognition`
    // support in the browser; it does not request microphone permission
    // yet (that happens on the first listen()).
    var available = false;
    try {
      available = await _speech.initialize(
        onError: _handleSpeechError,
        onStatus: _handleSpeechStatus,
      );
    } catch (e) {
      // Some browsers expose the SpeechRecognition constructor but still
      // fail to initialize it (missing OS-level speech service, etc.) —
      // treat that the same as "not available" instead of crashing.
      debugPrint('Speech recognition initialization failed: $e');
    }
    speechAvailable = available;
    speechInitDone = true;
    notifyListeners();
  }

  void _handleSpeechError(SpeechRecognitionError error) {
    _silenceTimer?.cancel();
    isListening = false;
    silenceCountdown = null;
    notifyListeners();
    _emitError('音声入力でエラーが発生しました(${error.errorMsg})。テキスト入力をご利用ください。');
  }

  void _handleSpeechStatus(String status) {
    if (status == 'notListening' || status == 'done') {
      isListening = false;
      notifyListeners();
    }
  }

  /// Chat-mode mic button behavior: tap while listening stops and sends
  /// whatever was recognized so far; tap while idle starts listening.
  Future<void> toggleListening() async {
    if (isListening) {
      await stopListeningAndSend();
      return;
    }
    await startListening();
  }

  Future<void> stopListeningAndSend() async {
    _silenceTimer?.cancel();
    // speech_to_text's stop() triggers one more *final* recognition result
    // that lands asynchronously via onResult — reading the text before
    // calling stop() (the previous bug here) or immediately after it can
    // both race ahead of that final result, silently dropping whatever the
    // user said in the last moment before tapping "finish". Stop first,
    // then give the trailing result a brief window to land before reading
    // the text for real.
    await _speech.stop();
    await Future.delayed(const Duration(milliseconds: 400));
    final pendingText = inputTextController.text.trim();
    isListening = false;
    silenceCountdown = null;
    notifyListeners();
    if (pendingText.isNotEmpty) {
      await sendText(pendingText);
    }
  }

  /// Voice-call-mode behavior for tapping while listening: stop and discard
  /// whatever was recognized, going straight back to idle without sending.
  Future<void> cancelListening() async {
    _silenceTimer?.cancel();
    await _speech.stop();
    isListening = false;
    silenceCountdown = null;
    inputTextController.clear();
    notifyListeners();
  }

  Future<void> startListening() async {
    if (isListening) return;
    if (isSending || isPlayingReply) return;
    if (!speechInitDone) {
      // Still checking browser support; ignore taps until that resolves.
      return;
    }
    if (!speechAvailable) {
      _emitError('お使いのブラウザ/端末は音声入力に対応していません。テキスト入力をご利用ください。');
      return;
    }

    isListening = true;
    notifyListeners();

    // Invoked before any other await, so the underlying play() call still
    // rides on the same user-gesture callstack as the tap — see
    // _ensureSilentLoopPlaying()'s doc comment for why this starts a
    // continuous loop rather than a one-shot ping. Deliberately NOT awaited
    // here — awaiting it delayed _speech.listen() below by however long the
    // call took to resolve, which showed up as a perceptible lag between
    // tapping the mic and speech actually being captured (early words
    // lost). sendText() performs its own awaited call before the API
    // request, which is what actually matters for the reply's playback.
    _ensureSilentLoopPlaying();
    _silenceGuardUntil = DateTime.now().add(_postListenGracePeriod);
    try {
      await _speech.listen(
        onResult: _handleSpeechResult,
        listenOptions: SpeechListenOptions(
          localeId: 'ja_JP',
          partialResults: true,
          cancelOnError: true,
        ),
      );
      // Cue that it's the user's turn to speak, right when the mic is
      // actually ready to receive input.
      _playReadyCue();
    } catch (e) {
      debugPrint('Speech recognition failed to start: $e');
      isListening = false;
      notifyListeners();
      _emitError('音声入力を開始できませんでした: $e');
    }
  }

  // Several rounds of a periodic "ping" keep-alive (re-playing a short
  // silent clip every few seconds) all failed to reliably keep automatic
  // reply playback working for slow-to-generate replies — real-device
  // testing showed no autoplay *and* no browser audio-activity indicator at
  // all once a reply took long enough, meaning the ping itself was being
  // silently blocked, not just occasionally missed. This points at a
  // stricter policy than "was audio recently playing": browsers appear to
  // evaluate each individual play() call against how long it's been since
  // an actual user gesture, and re-triggering a new discrete play() call
  // from a Timer doesn't count as one — so no ping frequency can fix it.
  //
  // The fix is a different mechanism entirely: start ONE continuously
  // looping (silent) playback the moment a real user gesture is available,
  // and never issue another *new* play() call for the purpose of staying
  // "unlocked" — a loop, once started, keeps playing indefinitely without
  // needing fresh permission, since the browser sees it as the same
  // ongoing playback session rather than a new autoplay attempt. When a
  // real reply is ready, we swap this same AudioPlayer's source to the
  // reply audio (interrupting the loop) via _runOnAudioPlayer, then resume
  // the loop once that reply finishes, so the next (possibly slow) reply
  // stays covered too. This is the standard trick web apps (chat/notifier
  // UIs) use for exactly this kind of "must be able to make sound without
  // a fresh click every time" requirement.
  bool _silentLoopActive = false;
  Future<void>? _silentLoopStarting;

  Future<void> _ensureSilentLoopPlaying() {
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
      await _runOnAudioPlayer(() async {
        await audioPlayer.setReleaseMode(ReleaseMode.loop);
        // No volume: parameter here — AudioPlayer.setVolume() persists on
        // the instance until explicitly changed again, so passing
        // volume: 0.0 would silence every later play() call on this same
        // shared audioPlayer (including real replies and manual replays)
        // that doesn't also pass its own volume. The asset itself is
        // already pure silence, so there's nothing to gain from also
        // zeroing the gain.
        await audioPlayer.play(AssetSource('sounds/unlock_silent.wav'));
      });
      _silentLoopActive = true;
    } catch (e) {
      // Purely a best-effort unlock; never let it affect the actual flow.
      // Leave _silentLoopActive false so the next caller retries instead of
      // assuming coverage that was never actually achieved.
      debugPrint('Silent audio-unlock loop failed to start: $e');
    }
  }

  // Several independent call sites invoke audioPlayer.play()/setReleaseMode
  // (the mic-tap in startListening(), sendText()'s own awaited call, and
  // the real reply/manual-replay playback in _playAndAwaitCompletion) —
  // audioplayers_web's WrappedPlayer mutates shared, non-atomic state
  // across await points inside play() (setUrl, recreateNode, ...), so any
  // two of these overlapping on the same AudioPlayer can corrupt that
  // state, even when one side is just the silent loop. Once corrupted,
  // playback stays broken for the rest of the session (including manual
  // replay, since it shares the same AudioPlayer) — this was the actual
  // cause of a past "stops auto-playing and manual replay also stops
  // working" regression. All calls now funnel through _runOnAudioPlayer()
  // below so at most one is ever in flight at a time, whichever call it
  // came from.
  Future<void> _audioOpQueue = Future.value();

  // audioPlayer.play()'s returned Future is documented elsewhere in this
  // file (see _playAndAwaitCompletion) to sometimes never resolve *or*
  // reject at all when the browser silently blocks a non-gesture-linked
  // play() call — this is a real, previously-observed behavior, not a
  // hypothetical. Every op run through _runOnAudioPlayer is bounded by this
  // timeout specifically so that case can't wedge the queue: without it, a
  // single hung silent-loop start (far more likely to hit a blocked-
  // autoplay wall than a real user-gesture-adjacent call) would
  // permanently block every operation queued after it — including the next
  // real reply's playback, AND (via _ensureSilentLoopPlaying awaiting this
  // same queue) _silentLoopStarting itself, which sendText() awaits as its
  // very first async step, meaning a single hung start could eventually
  // freeze sending new messages entirely, not just audio playback.
  static const _audioOpTimeout = Duration(seconds: 10);

  Future<T> _runOnAudioPlayer<T>(Future<T> Function() action) {
    final scheduled = _audioOpQueue.then((_) => action().timeout(_audioOpTimeout));
    // Chain the *next* op off this one regardless of whether it succeeds —
    // a failed play() (blocked autoplay, network error, ...) must not wedge
    // every subsequent queued call behind a permanently-unresolved future.
    // Errors still propagate to whoever awaits `scheduled` directly.
    _audioOpQueue = scheduled.then((_) {}, onError: (_) {});
    return scheduled;
  }

  void _handleSpeechResult(SpeechRecognitionResult result) {
    inputTextController.text = result.recognizedWords;
    inputTextController.selection =
        TextSelection.collapsed(offset: inputTextController.text.length);
    notifyListeners();
    // The recognizer runs in continuous mode (it never decides on its own
    // that an utterance is "done"), so silence is detected here instead:
    // every new result (partial or final) restarts the countdown, and
    // reaching zero without any further speech triggers the send.
    _restartSilenceCountdown();
  }

  void _restartSilenceCountdown() {
    _silenceTimer?.cancel();

    final guardUntil = _silenceGuardUntil;
    if (guardUntil != null && DateTime.now().isBefore(guardUntil)) {
      // Within the brief post-start grace period — don't start counting
      // down yet, just show the plain "listening" state.
      silenceCountdown = null;
      notifyListeners();
      return;
    }

    silenceCountdown = silenceThresholdSeconds;
    notifyListeners();
    _silenceTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remaining = (silenceCountdown ?? 1) - 1;
      if (remaining <= 0) {
        timer.cancel();
        silenceCountdown = null;
        notifyListeners();
        _handleSilenceTimeout();
      } else {
        silenceCountdown = remaining;
        notifyListeners();
      }
    });
  }

  // Soft "pon" cue meaning "you may act now" — played both when the mic
  // starts listening and when the reply has finished being read aloud.
  Future<void> _playReadyCue() async {
    try {
      await _cuePlayer.play(AssetSource('sounds/silence_cue.wav'), volume: 0.18);
    } catch (e) {
      // Purely a nice-to-have UI cue — never let it affect the actual
      // conversation flow.
      debugPrint('Ready cue playback failed: $e');
    }
  }

  Future<void> _handleSilenceTimeout() async {
    // Same ordering fix as stopListeningAndSend(): read the text after
    // stop() (and its trailing final result) rather than before.
    await _speech.stop();
    await Future.delayed(const Duration(milliseconds: 400));
    final text = inputTextController.text.trim();
    isListening = false;
    notifyListeners();
    if (text.isNotEmpty) {
      await sendText(text);
    }
    // No automatic restart: the recognizer has proven unreliable to
    // re-arm on its own across browsers, and the user now gets a clear
    // "your turn" signal (the ready cue) each time they tap the mic
    // again for the next utterance instead.
  }

  Future<void> sendText(String text) async {
    text = text.trim();
    if (text.isEmpty || isSending || isPlayingReply) return;

    // isSending is set synchronously here, before any `await` — Dart runs
    // an async function's body synchronously up to its first `await`, so
    // this closes a race where a rapid double-tap on the send button (or
    // hitting Enter twice) could both pass the isSending check above and
    // send the same text twice. Previously isSending wasn't set until
    // after the unlock call's `await` had already yielded control back to
    // the event loop, leaving a real window for a second tap to slip
    // through. Clearing the input and disabling the controls happen in the
    // same synchronous block for the same reason.
    final wasListening = isListening;
    isSending = true;
    isListening = false;
    _silenceTimer?.cancel();
    silenceCountdown = null;
    messages.add(ChatMessage(role: ChatRole.user, text: text));
    inputTextController.clear();
    notifyListeners();

    if (wasListening) {
      await _speech.stop();
    }

    // Without this, a text-only send (never touching the mic button) never
    // starts the shared AudioPlayer's silent unlock loop with a genuine
    // user gesture, so the reply's automatic playback gets silently
    // blocked by the browser's autoplay policy once the API round-trip
    // (which can take several seconds) outlasts the click/Enter-key
    // gesture. See _ensureSilentLoopPlaying()'s doc comment for why this is
    // a continuous loop rather than a one-shot ping.
    await _ensureSilentLoopPlaying();

    String? audioUrlToPlay;
    try {
      final result = await _api.sendMessage(sessionId: sessionId, text: text);
      messages.add(
        ChatMessage(role: ChatRole.assistant, text: result.text, audioUrl: result.audioUrl),
      );
      audioUrlToPlay = result.audioUrl;
    } on ConversationApiException catch (e) {
      messages.add(ChatMessage(role: ChatRole.error, text: e.message));
    } finally {
      // Done sending regardless of what happens with audio playback below —
      // playback must never keep the input controls disabled indefinitely.
      isSending = false;
      notifyListeners();
    }

    if (audioUrlToPlay != null) {
      await playReplyAudio(audioUrlToPlay);
    }
  }

  /// Plays the just-received reply's audio. Locks mic input and the send
  /// button until playback genuinely finishes (or is force-stopped via
  /// [forceStopReading]), then plays the "ready" cue.
  Future<void> playReplyAudio(String url) async {
    isPlayingReply = true;
    notifyListeners();
    await _playAndAwaitCompletion(url, isManualReplay: false);
    isPlayingReply = false;
    notifyListeners();
    _playReadyCue();
  }

  Future<void> forceStopReading() async {
    if (!isPlayingReply) return;
    await audioPlayer.stop();
    // AudioPlayer.stop() does not fire onPlayerComplete, so unblock the
    // pending wait in _playAndAwaitCompletion directly.
    _replayCompleter?.complete();
  }

  /// Manual replay from the "音声を再生" button on a past message bubble.
  /// Does not touch isPlayingReply — replaying an old message shouldn't
  /// lock the input for a new one.
  Future<void> playAudio(String url, {required bool isManualReplay}) async {
    await _playAndAwaitCompletion(url, isManualReplay: isManualReplay);
  }

  Future<void> _playAndAwaitCompletion(String url, {required bool isManualReplay}) async {
    // About to interrupt the silent loop (if any) by swapping this
    // AudioPlayer's source to the real reply — mark it inactive so a
    // concurrent _ensureSilentLoopPlaying() caller doesn't wrongly think
    // coverage still exists, and so it gets resumed (see finally below)
    // rather than skipped as a no-op the next time it's needed.
    _silentLoopActive = false;
    final completer = Completer<void>();
    _replayCompleter = completer;
    final subscription = audioPlayer.onPlayerComplete.listen((_) {
      if (!completer.isCompleted) completer.complete();
    });
    try {
      // play() resolves once playback *starts*, not once it finishes, and
      // some browsers leave it pending forever if autoplay is blocked —
      // _runOnAudioPlayer already bounds it with _audioOpTimeout, so no
      // separate timeout is needed here. Once it resolves (or times out),
      // separately wait for the real completion event.
      //
      // volume is passed explicitly on every real playback call — it's a
      // setting that persists on the AudioPlayer instance until changed
      // again (not reset per-source), so relying on "whatever it happened
      // to be left at" is fragile (this is exactly how a past unlock-sound
      // tweak silently zeroed all future playback on this player).
      // Routed through _runOnAudioPlayer so this can never overlap an
      // in-flight silent-loop operation on the same AudioPlayer — see the
      // comment on _runOnAudioPlayer for why that overlap was corrupting
      // playback. ReleaseMode.release (the package default, set explicitly
      // here since the silent loop leaves it on ReleaseMode.loop) so this
      // plays once and stops rather than looping the reply audio.
      await _runOnAudioPlayer(() async {
        await audioPlayer.setReleaseMode(ReleaseMode.release);
        await audioPlayer.play(UrlSource(url), volume: 1.0);
      });
      await completer.future.timeout(const Duration(seconds: 30), onTimeout: () {});
    } catch (e) {
      // Always log so playback failures (blocked autoplay, CORS, expired
      // signed URL, ...) are visible in the browser console even when we
      // don't show the user an error.
      debugPrint('Audio playback failed for $url: $e');
      // Autoplay can be blocked by the browser until the user interacts
      // with the page — that's expected and the "音声を再生" button lets
      // them retry, so stay silent there. A manual tap failing is not
      // expected, so surface it.
      if (isManualReplay) {
        _emitError('音声を再生できませんでした: $e');
      }
    } finally {
      await subscription.cancel();
      _replayCompleter = null;
      // Resume the silent loop so a long wait before the *next* reply
      // stays covered without needing a fresh user gesture. Not awaited —
      // this is best-effort background upkeep, not something the caller
      // needs to wait on.
      unawaited(_ensureSilentLoopPlaying());
    }
  }

  void setSilenceThresholdSeconds(int value) {
    silenceThresholdSeconds = value;
    notifyListeners();
  }
}
