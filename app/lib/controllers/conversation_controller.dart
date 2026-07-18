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

  // Keeps audioPlayer's AudioContext from being auto-suspended by the
  // browser during two windows where several seconds can pass with no
  // touch interaction at all: the listening phase (the user is talking,
  // not tapping) and, separately, the isSending wait for the Claude+
  // ElevenLabs round trip (see sendText() and _sendingKeepAliveInterval
  // below) — both end with a non-gesture-linked automatic play() call that
  // can no longer resume an already-suspended context on its own.
  //
  // Kept deliberately infrequent: each ping plays real (if silent) audio
  // through the same AudioContext the browser's echo-cancellation/AGC
  // pipeline watches, and pinging too often measurably hurt speech
  // recognition accuracy for quiet speech ("ボソッと喋ると間違って入力
  // される"). The silence threshold this is protecting against tops out
  // at maxSilenceThresholdSeconds (10s), so a ping every 10s still covers
  // that window without keeping audio activity continuously live.
  static const _audioKeepAliveInterval = Duration(seconds: 10);
  // Separate, much tighter interval used only while sendText() is waiting
  // on the Claude+ElevenLabs round trip (isSending == true). The mic is
  // already closed by then (STT has stopped), so there's no accuracy
  // tradeoff to justify spacing pings out — and the round trip itself
  // (~5s in testing) is shorter than _audioKeepAliveInterval, meaning a
  // timer freshly started at 10s could complete the entire wait without a
  // single ping ever firing.
  static const _sendingKeepAliveInterval = Duration(seconds: 3);
  Timer? _audioKeepAliveTimer;

  ConversationController() {
    sessionId = const Uuid().v4();
    _initSpeech();
  }

  @override
  void dispose() {
    _silenceTimer?.cancel();
    _audioKeepAliveTimer?.cancel();
    inputTextController.dispose();
    audioPlayer.dispose();
    _cuePlayer.dispose();
    _speech.stop();
    _errorStreamController.close();
    super.dispose();
  }

  void _startAudioKeepAlive([Duration interval = _audioKeepAliveInterval]) {
    _audioKeepAliveTimer?.cancel();
    _audioKeepAliveTimer = Timer.periodic(interval, (_) {
      _unlockAudioPlayback();
    });
  }

  void _stopAudioKeepAlive() {
    _audioKeepAliveTimer?.cancel();
    _audioKeepAliveTimer = null;
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
    _stopAudioKeepAlive();
    isListening = false;
    silenceCountdown = null;
    notifyListeners();
    _emitError('音声入力でエラーが発生しました(${error.errorMsg})。テキスト入力をご利用ください。');
  }

  void _handleSpeechStatus(String status) {
    if (status == 'notListening' || status == 'done') {
      _stopAudioKeepAlive();
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
    _stopAudioKeepAlive();
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
    _stopAudioKeepAlive();
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
    // rides on the same user-gesture callstack as the tap, unlocking
    // `audioPlayer`'s AudioContext for later programmatic (non-gesture)
    // playback of the reply audio. Deliberately NOT awaited here — awaiting
    // it delayed _speech.listen() below by however long the silent clip's
    // play() took to resolve, which showed up as a perceptible lag between
    // tapping the mic and speech actually being captured (early words lost).
    // The race this used to guard against (this call's play() overlapping
    // the real reply's later play() on the same AudioPlayer) isn't a risk
    // here: sendText() performs its own awaited unlock call immediately
    // before the API request, which is what actually runs close in time to
    // the real reply's playback — see the comment there.
    _unlockAudioPlayback();
    // Keeps re-pinging audioPlayer's AudioContext for as long as listening
    // continues, so a long pause before speech is detected (or before the
    // silence timeout fires) doesn't let it idle-suspend with no gesture
    // available later to resume it.
    _startAudioKeepAlive();
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
      _stopAudioKeepAlive();
      isListening = false;
      notifyListeners();
      _emitError('音声入力を開始できませんでした: $e');
    }
  }

  // Deliberately re-run on every gesture-linked call, not just once per
  // session — mobile Safari (and other mobile browsers) can re-suspend an
  // AudioContext after a period without touch interaction (e.g. the several
  // seconds spent listening for speech while waiting for the silence
  // timeout), and once suspended it stays that way for every later
  // automatic playback until a fresh gesture resumes it again. This is why
  // auto-play worked for the first turn or two after opening the app and
  // then silently stopped — the one-time-only version of this unlock left
  // the context unresumed for later turns. Manual replay always worked
  // throughout because tapping "音声を再生" is itself a fresh gesture.
  // There are several independent call sites that invoke audioPlayer.play()
  // (the mic-tap in startListening(), the periodic keep-alive pings during
  // both listening and isSending, sendText()'s own awaited unlock call, and
  // the real reply/manual-replay playback in _playAndAwaitCompletion) —
  // audioplayers_web's WrappedPlayer mutates shared, non-atomic state
  // across await points inside play() (setUrl, recreateNode, ...), so any
  // two of these overlapping on the same AudioPlayer can corrupt that
  // state, even when one side is just replaying the silent unlock clip.
  // Once corrupted, playback stays broken for the rest of the session
  // (including manual replay, since it shares the same AudioPlayer) — this
  // was the actual cause of a "stops auto-playing and manual replay also
  // stops working" regression: only the unlock calls were serialized
  // against each other, leaving them free to overlap with the real
  // playback call, which isn't itself an unlock call. All calls to
  // audioPlayer.play() now funnel through _runOnAudioPlayer() below so at
  // most one is ever in flight at a time, whichever call it came from.
  Future<void> _audioOpQueue = Future.value();

  Future<T> _runOnAudioPlayer<T>(Future<T> Function() action) {
    final scheduled = _audioOpQueue.then((_) => action());
    // Chain the *next* op off this one regardless of whether it succeeds —
    // a failed play() (blocked autoplay, network error, ...) must not wedge
    // every subsequent queued call behind a permanently-unresolved future.
    // Errors still propagate to whoever awaits `scheduled` directly.
    _audioOpQueue = scheduled.then((_) {}, onError: (_) {});
    return scheduled;
  }

  Future<void>? _unlockInFlight;

  Future<void> _unlockAudioPlayback() {
    final existing = _unlockInFlight;
    if (existing != null) return existing;
    final future = _doUnlockAudioPlayback();
    _unlockInFlight = future;
    future.whenComplete(() {
      if (identical(_unlockInFlight, future)) _unlockInFlight = null;
    });
    return future;
  }

  Future<void> _doUnlockAudioPlayback() async {
    try {
      // No volume: parameter here — AudioPlayer.setVolume() persists on the
      // instance until explicitly changed again, so passing volume: 0.0
      // would silence every later play() call on this same shared
      // audioPlayer (including real replies and manual replays) that
      // doesn't also pass its own volume. The asset itself is already pure
      // silence, so there's nothing to gain from also zeroing the gain.
      await _runOnAudioPlayer(() => audioPlayer.play(AssetSource('sounds/unlock_silent.wav')));
    } catch (e) {
      // Purely a best-effort unlock; never let it affect the actual flow.
      debugPrint('Audio unlock playback failed: $e');
    }
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
    _stopAudioKeepAlive();
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

    // Invoked before any other await — same reasoning as in startListening()
    // (must be awaited to full completion, not fire-and-forget, to avoid
    // racing with the reply's later play() call on the same AudioPlayer).
    // Without this at all, a text-only send (never touching the mic button)
    // never unlocks the shared AudioPlayer's AudioContext with a genuine
    // user gesture, so the reply's automatic playback gets silently blocked
    // by the browser's autoplay policy once the API round-trip (which can
    // take several seconds) outlasts the click/Enter-key gesture.
    await _unlockAudioPlayback();

    _silenceTimer?.cancel();
    silenceCountdown = null;
    if (isListening) {
      await _speech.stop();
    }

    messages.add(ChatMessage(role: ChatRole.user, text: text));
    isSending = true;
    isListening = false;
    inputTextController.clear();
    notifyListeners();

    // Covers the Claude+ElevenLabs round trip itself, not just the moment
    // right before it — without this, nothing re-pings the AudioContext
    // between the single unlock call above and the reply's actual play()
    // call several seconds later, which was enough for the browser to
    // re-suspend it in between and silently block the automatic playback.
    // Uses the tighter _sendingKeepAliveInterval since the mic is already
    // closed at this point (see its doc comment for why that's safe here).
    _startAudioKeepAlive(_sendingKeepAliveInterval);

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
      _stopAudioKeepAlive();
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
    final completer = Completer<void>();
    _replayCompleter = completer;
    final subscription = audioPlayer.onPlayerComplete.listen((_) {
      if (!completer.isCompleted) completer.complete();
    });
    try {
      // play() resolves once playback *starts*, not once it finishes, and
      // some browsers leave it pending forever if autoplay is blocked — so
      // bound it, then separately wait for the real completion event.
      //
      // volume is passed explicitly on every real playback call — it's a
      // setting that persists on the AudioPlayer instance until changed
      // again (not reset per-source), so relying on "whatever it happened
      // to be left at" is fragile (this is exactly how a past unlock-sound
      // tweak silently zeroed all future playback on this player).
      // Routed through _runOnAudioPlayer so this can never overlap an
      // in-flight unlock ping on the same AudioPlayer — see the comment on
      // _runOnAudioPlayer for why that overlap was corrupting playback.
      await _runOnAudioPlayer(
        () => audioPlayer.play(UrlSource(url), volume: 1.0),
      ).timeout(const Duration(seconds: 10));
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
    }
  }

  void setSilenceThresholdSeconds(int value) {
    silenceThresholdSeconds = value;
    notifyListeners();
  }
}
