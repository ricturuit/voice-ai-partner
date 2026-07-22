import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../services/audio_playback_service.dart';
import '../services/conversation_api.dart';

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

  ConversationController() {
    sessionId = const Uuid().v4();
    _initSpeech();
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
          localeId: 'ja_JP',
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
    try {
      await _audio.play(url);
    } catch (e) {
      // Autoplay can still be blocked by the browser in rare cases — the
      // "音声を再生" button lets the user retry, so stay silent here.
    }
    isPlayingReply = false;
    notifyListeners();
    await _audio.playCue();
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
}
