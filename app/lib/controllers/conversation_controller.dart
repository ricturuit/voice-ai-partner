import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../models/learning_level.dart';
import '../services/audio_playback_service.dart';
import '../services/conversation_api.dart';
import '../services/learning_progress_store.dart';

/// Holds all conversation state and STT/TTS orchestration shared between the
/// chat screen and the voice-call screen, so both can drive the same
/// session/history and stay in sync regardless of which one is on screen.
///
/// Voice input is always explicit: tap the mic to start listening, tap again
/// to stop and send (or long-press to cancel instead). There is deliberately
/// no silence-based auto-send timer. It used to auto-stop listening and send
/// on its own, but that meant sendText() — and therefore the reply's
/// autoplay-unlock trigger (see [AudioPlaybackService.unlock]) — fired
/// without a fresh user gesture behind it, which is exactly the condition
/// browsers block audio autoplay under. That showed up as: the longer Claude
/// took to think, the more likely an auto-sent turn's reply would silently
/// fail to autoplay (text-only). A real tap on the mic/send button
/// guarantees that gesture every time, regardless of how long the reply
/// takes.
class ConversationController extends ChangeNotifier {
  // Generated once when the app starts and kept for the lifetime of this
  // browser tab/session — never persisted or regenerated mid-session.
  late final String sessionId;

  final ConversationApi _api = ConversationApi();
  final AudioPlaybackService _audio = AudioPlaybackService();
  final LearningProgressStore _progress = LearningProgressStore();
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

  // ---- English learning mode -------------------------------------------

  /// Whether the conversation is currently in English learning mode.
  bool learningMode = false;

  /// The learner's level, restored from local storage on startup.
  late LearningLevel level = _progress.load();

  /// Hints for the learner's *next* reply, produced alongside 名取's current
  /// reply (same API round trip — no extra call, no extra wait). Cleared as
  /// soon as a message is sent, since they describe the turn just answered.
  List<HintWord> hintWords = const [];

  /// Ready-made replies the learner can send as-is. Generated with the same
  /// reply but kept hidden until [showSuggestedReplies] is set, so seeing the
  /// answer is a deliberate choice rather than a spoiler.
  List<HintWord> suggestedReplies = const [];
  bool showSuggestedReplies = false;

  /// Level test state. [levelTestTurn] is 1-based and counts turns already
  /// sent; the server gives its verdict on the final turn.
  static const levelTestTotalTurns = 5;
  bool isLevelTest = false;
  int levelTestTurn = 0;

  /// The most recent verdict, held so the UI can present it (and any
  /// level-up) until the learner dismisses it.
  LevelTestResult? lastTestResult;
  LearningLevel? leveledUpTo;

  /// Reply playback speed. Persisted, and applied to the audio element
  /// immediately so a change lands on whatever is already playing.
  late PlaybackSpeed playbackSpeed = _progress.loadSpeed();

  void setPlaybackSpeed(PlaybackSpeed speed) {
    playbackSpeed = speed;
    _audio.playbackRate = speed.rate;
    _progress.saveSpeed(speed);
    notifyListeners();
  }

  ConversationController() {
    sessionId = const Uuid().v4();
    _audio.playbackRate = playbackSpeed.rate;
    _initSpeech();
  }

  void setLearningMode(bool enabled) {
    if (learningMode == enabled) return;
    learningMode = enabled;
    _clearTurnAssistance();
    // Abandon any test in progress: its remaining turns assume a mode the
    // learner just left.
    isLevelTest = false;
    levelTestTurn = 0;
    notifyListeners();
  }

  void startLevelTest() {
    if (!learningMode || isSending || isPlayingReply) return;
    isLevelTest = true;
    levelTestTurn = 0;
    lastTestResult = null;
    leveledUpTo = null;
    notifyListeners();
  }

  void cancelLevelTest() {
    if (!isLevelTest) return;
    isLevelTest = false;
    levelTestTurn = 0;
    notifyListeners();
  }

  void dismissTestResult() {
    lastTestResult = null;
    leveledUpTo = null;
    notifyListeners();
  }

  void toggleSuggestedReplies() {
    showSuggestedReplies = !showSuggestedReplies;
    notifyListeners();
  }

  /// Inserts a hint word into the input field. Stops listening first if the
  /// mic is open: every recognition result replaces the field's whole
  /// contents, so anything inserted mid-listen would be wiped by the next
  /// result. Ending input on tap is also the natural reading of the gesture —
  /// you reach for a hint word because you've stopped mid-sentence.
  Future<void> insertHintWord(String word) async {
    if (isListening) {
      await cancelListeningKeepingText();
    }
    final current = inputTextController.text.trimRight();
    final joined = current.isEmpty ? word : '$current $word';
    inputTextController.text = joined;
    inputTextController.selection = TextSelection.collapsed(offset: joined.length);
    notifyListeners();
  }

  /// Fills the input with a ready-made reply so the learner can review or
  /// edit it before sending, rather than it being sent out from under them.
  Future<void> useSuggestedReply(String reply) async {
    if (isListening) {
      await cancelListeningKeepingText();
    }
    inputTextController.text = reply;
    inputTextController.selection = TextSelection.collapsed(offset: reply.length);
    showSuggestedReplies = false;
    notifyListeners();
  }

  void _clearTurnAssistance() {
    hintWords = const [];
    suggestedReplies = const [];
    showSuggestedReplies = false;
  }

  @override
  void dispose() {
    inputTextController.dispose();
    _audio.dispose();
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
    isListening = false;
    notifyListeners();
    _emitError('音声入力でエラーが発生しました(${error.errorMsg})。テキスト入力をご利用ください。');
  }

  void _handleSpeechStatus(String status) {
    if (status == 'notListening' || status == 'done') {
      isListening = false;
      notifyListeners();
    }
  }

  /// Tap while listening stops and sends whatever was recognized so far;
  /// tap while idle starts listening.
  Future<void> toggleListening() async {
    if (isListening) {
      await stopListeningAndSend();
      return;
    }
    await startListening();
  }

  Future<void> stopListeningAndSend() async {
    // speech_to_text's stop() triggers one more *final* recognition result
    // that lands asynchronously via onResult — reading the text before
    // calling stop() (a previous bug here) or immediately after it can both
    // race ahead of that final result, silently dropping whatever the user
    // said in the last moment before tapping "finish". Stop first, then
    // give the trailing result a brief window to land before reading the
    // text for real.
    await _speech.stop();
    await Future.delayed(const Duration(milliseconds: 400));
    final pendingText = inputTextController.text.trim();
    isListening = false;
    notifyListeners();
    if (pendingText.isNotEmpty) {
      await sendText(pendingText);
    }
  }

  /// Stop and discard whatever was recognized, going straight back to idle
  /// without sending.
  Future<void> cancelListening() async {
    await _speech.stop();
    isListening = false;
    inputTextController.clear();
    notifyListeners();
  }

  /// Stops listening but keeps whatever has been recognized so far, so the
  /// learner can edit it (or add a hint word to it) instead of losing it.
  Future<void> cancelListeningKeepingText() async {
    await _speech.stop();
    isListening = false;
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
    // AudioPlaybackService.unlock()'s doc comment for why this starts a
    // continuous loop rather than a one-shot ping. Deliberately NOT awaited
    // here — awaiting it delayed _speech.listen() below by however long the
    // call took to resolve, which showed up as a perceptible lag between
    // tapping the mic and speech actually being captured (early words
    // lost). sendText() performs its own awaited call before the API
    // request, which is what actually matters for the reply's playback.
    unawaited(_audio.unlock());
    try {
      await _speech.listen(
        onResult: _handleSpeechResult,
        listenOptions: SpeechListenOptions(
          // Recognition has to be told which language to expect — a
          // Japanese recognizer fed English produces phonetic nonsense.
          // This also makes the transcript itself useful feedback in
          // learning mode: the bubble shows what was actually heard, so a
          // pronunciation that isn't landing becomes visible.
          localeId: learningMode ? 'en_US' : 'ja_JP',
          partialResults: true,
          cancelOnError: true,
        ),
      );
      // Cue that it's the user's turn to speak, right when the mic is
      // actually ready to receive input.
      await _audio.playCue();
    } catch (e) {
      debugPrint('Speech recognition failed to start: $e');
      isListening = false;
      notifyListeners();
      _emitError('音声入力を開始できませんでした: $e');
    }
  }

  void _handleSpeechResult(SpeechRecognitionResult result) {
    inputTextController.text = result.recognizedWords;
    inputTextController.selection =
        TextSelection.collapsed(offset: inputTextController.text.length);
    notifyListeners();
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
    messages.add(ChatMessage(role: ChatRole.user, text: text));
    inputTextController.clear();
    // The hints described the turn being answered right now; they'd be
    // misleading once this message is on its way.
    _clearTurnAssistance();
    if (isLevelTest) levelTestTurn++;
    notifyListeners();

    if (wasListening) {
      await _speech.stop();
    }

    // Without this, a text-only send (never touching the mic button) never
    // starts the shared unlock loop with a genuine user gesture, so the
    // reply's automatic playback gets silently blocked by the browser's
    // autoplay policy once the API round-trip (which can take several
    // seconds) outlasts the click/Enter-key gesture. See
    // AudioPlaybackService.unlock()'s doc comment for why this is a
    // continuous loop rather than a one-shot ping.
    await _audio.unlock();

    String? audioUrlToPlay;
    try {
      final result = await _api.sendMessage(
        sessionId: sessionId,
        text: text,
        englishLearningMode: learningMode,
        level: level,
        levelTest: isLevelTest,
        levelTestTurn: levelTestTurn,
      );
      messages.add(
        ChatMessage(
          role: ChatRole.assistant,
          text: result.text,
          audioUrl: result.audioUrl,
          translation: result.translation,
        ),
      );
      hintWords = result.hintWords;
      suggestedReplies = result.suggestedReplies;
      showSuggestedReplies = false;
      if (result.testResult != null) {
        _applyTestResult(result.testResult!);
      }
      audioUrlToPlay = result.audioUrl;
    } on ConversationApiException catch (e) {
      messages.add(ChatMessage(role: ChatRole.error, text: e.message));
      // A failed turn shouldn't burn a test turn the learner never got to
      // use — give it back so the test still runs its full length.
      if (isLevelTest && levelTestTurn > 0) levelTestTurn--;
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

  /// Records a verdict and, on a pass, moves the learner up a level. The
  /// test always ends here either way — a verdict is the end of the test.
  void _applyTestResult(LevelTestResult result) {
    lastTestResult = result;
    isLevelTest = false;
    levelTestTurn = 0;
    leveledUpTo = null;
    if (result.passed) {
      final next = level.next;
      if (next != null) {
        level = next;
        leveledUpTo = next;
        _progress.save(next);
      }
      // Passing at the ceiling is still a pass; there is simply nowhere
      // further to go, which the UI says rather than silently doing nothing.
    }
  }

  /// Set when a reply's audio failed to start on its own. The UI surfaces
  /// this as a tap-to-play prompt: a tap carries a fresh user gesture,
  /// which is exactly what blocked playback needs, and it also means a
  /// failure is visible and reportable instead of silently degrading to
  /// text-only — the condition that let earlier autoplay regressions go
  /// undiagnosed for several rounds (see README.md's autoplay history).
  String? autoplayBlockedUrl;

  /// The browser's own error text for that failure, shown alongside the
  /// prompt. Deliberately not translated or prettified: when this recurs,
  /// the exact error is what makes the next diagnosis take minutes instead
  /// of rounds of guessing.
  String? get autoplayFailureReason => _audio.lastFailureReason;

  /// Plays the just-received reply's audio. Locks mic input and the send
  /// button until playback genuinely finishes (or is force-stopped via
  /// [forceStopReading]), then plays the "ready" cue.
  Future<void> playReplyAudio(String url) async {
    isPlayingReply = true;
    autoplayBlockedUrl = null;
    notifyListeners();
    try {
      await _audio.play(url);
    } catch (e) {
      debugPrint('Reply autoplay failed, offering manual playback: $e');
      autoplayBlockedUrl = url;
    }
    isPlayingReply = false;
    notifyListeners();
    await _audio.playCue();
  }

  /// Retries a reply whose autoplay was blocked. Called straight from a
  /// tap, so it both carries a fresh gesture and re-primes the element.
  Future<void> retryBlockedAutoplay() async {
    final url = autoplayBlockedUrl;
    if (url == null) return;
    unawaited(_audio.unlock());
    autoplayBlockedUrl = null;
    notifyListeners();
    await playReplyAudio(url);
  }

  Future<void> forceStopReading() async {
    if (!isPlayingReply) return;
    await _audio.stop();
  }

  /// Manual replay from the "音声を再生" button on a past message bubble.
  /// Does not touch isPlayingReply — replaying an old message shouldn't
  /// lock the input for a new one.
  Future<void> playAudio(String url, {required bool isManualReplay}) async {
    try {
      await _audio.play(url);
    } catch (e) {
      // A manual tap failing is not expected (unlike an automatic reply
      // being blocked by autoplay policy), so surface it.
      if (isManualReplay) {
        _emitError('音声を再生できませんでした: $e');
      }
    }
  }

  /// Live caption text for the voice-call screen: the live partial
  /// recognition result while listening, otherwise whatever was most
  /// recently said — the user's own just-finished utterance right after
  /// sending, then the assistant's reply text once it arrives (spoken aloud
  /// at the same time via [playReplyAudio]). Error messages aren't spoken,
  /// so they're never shown as a caption.
  String get captionText {
    if (isListening) return inputTextController.text;
    if (messages.isEmpty) return '';
    final last = messages.last;
    if (last.role == ChatRole.error) return '';
    return last.text;
  }
}
