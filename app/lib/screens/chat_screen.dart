import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../services/conversation_api.dart';
import '../widgets/chat_bubble.dart';

const int _minSilenceThresholdSeconds = 2;
const int _maxSilenceThresholdSeconds = 10;

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  // Generated once when the app starts and kept for the lifetime of this
  // browser tab/session — never persisted or regenerated mid-session.
  late final String _sessionId;

  final ConversationApi _api = ConversationApi();
  final AudioPlayer _audioPlayer = AudioPlayer();
  // Separate player for the short silence-detected cue so it never gets
  // tangled up with the (longer, sometimes-blocked, sometimes-timing-out)
  // reply-audio playback logic in _playAudio.
  final AudioPlayer _cuePlayer = AudioPlayer();
  final SpeechToText _speech = SpeechToText();
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];

  bool _isSending = false;
  bool _speechInitDone = false;
  bool _speechAvailable = false;
  bool _isListening = false;

  // True while the mic is toggled "on" for a hands-free voice conversation:
  // the app keeps re-starting the recognizer after every auto-sent turn
  // until the user taps the mic again to turn it off.
  bool _conversationModeActive = false;

  // Configurable silence threshold: how many seconds of no new recognized
  // speech before we auto-send. Also doubles as the visible countdown
  // duration.
  int _silenceThresholdSeconds = _minSilenceThresholdSeconds;
  Timer? _silenceTimer;
  int? _silenceCountdown;

  // Brief grace period right after (re)starting the recognizer during which
  // we ignore silence-countdown triggers — mainly so a stray/late result
  // from the just-finished turn (or the reply's own TTS audio, in case any
  // of it leaks into the mic) can't immediately fire another countdown.
  static const _postListenGracePeriod = Duration(seconds: 1);
  DateTime? _silenceGuardUntil;

  @override
  void initState() {
    super.initState();
    _sessionId = const Uuid().v4();
    _initSpeech();
  }

  @override
  void dispose() {
    _silenceTimer?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    _cuePlayer.dispose();
    _speech.stop();
    super.dispose();
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
    if (!mounted) return;
    setState(() {
      _speechAvailable = available;
      _speechInitDone = true;
    });
  }

  void _handleSpeechError(SpeechRecognitionError error) {
    if (!mounted) return;
    _silenceTimer?.cancel();
    setState(() {
      _isListening = false;
      _conversationModeActive = false;
      _silenceCountdown = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('音声入力でエラーが発生しました(${error.errorMsg})。テキスト入力をご利用ください。')),
    );
  }

  void _handleSpeechStatus(String status) {
    if (!mounted) return;
    if (status == 'notListening' || status == 'done') {
      setState(() => _isListening = false);
    }
  }

  Future<void> _toggleListening() async {
    if (_conversationModeActive) {
      // Manual turn-off: stop listening and, if something was already
      // recognized, send it now rather than discarding it.
      _conversationModeActive = false;
      _silenceTimer?.cancel();
      final pendingText = _textController.text.trim();
      await _speech.stop();
      if (mounted) {
        setState(() {
          _isListening = false;
          _silenceCountdown = null;
        });
      }
      if (pendingText.isNotEmpty) {
        await _handleSend();
      }
      return;
    }

    if (!_speechInitDone) {
      // Still checking browser support; ignore taps until that resolves.
      return;
    }
    if (!_speechAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('お使いのブラウザ/端末は音声入力に対応していません。テキスト入力をご利用ください。')),
      );
      return;
    }

    _conversationModeActive = true;
    await _startListening();
  }

  // [isAutoRestart] is true when this is the app re-arming the mic between
  // conversation turns (not a direct user tap). Browsers can briefly refuse
  // to start a new SpeechRecognition session immediately after the previous
  // one stopped, so on that path we wait a moment and retry quietly instead
  // of alarming the user with an error for something they didn't do.
  Future<void> _startListening({bool isAutoRestart = false}) async {
    if (isAutoRestart) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted || !_conversationModeActive) return;
    }

    setState(() => _isListening = true);
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
    } catch (e) {
      debugPrint('Speech recognition failed to start (autoRestart=$isAutoRestart): $e');
      if (!mounted) return;
      if (isAutoRestart) {
        // One quiet retry after a slightly longer pause before giving up.
        await Future.delayed(const Duration(milliseconds: 800));
        if (!mounted || !_conversationModeActive) return;
        try {
          _silenceGuardUntil = DateTime.now().add(_postListenGracePeriod);
          await _speech.listen(
            onResult: _handleSpeechResult,
            listenOptions: SpeechListenOptions(
              localeId: 'ja_JP',
              partialResults: true,
              cancelOnError: true,
            ),
          );
          return;
        } catch (e2) {
          debugPrint('Speech recognition retry failed: $e2');
        }
      }
      if (!mounted) return;
      setState(() {
        _isListening = false;
        _conversationModeActive = false;
      });
      if (!isAutoRestart) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('音声入力を開始できませんでした: $e')),
        );
      }
    }
  }

  void _handleSpeechResult(SpeechRecognitionResult result) {
    setState(() {
      _textController.text = result.recognizedWords;
      _textController.selection = TextSelection.collapsed(offset: _textController.text.length);
    });
    // The recognizer runs in continuous mode (it never decides on its own
    // that an utterance is "done"), so silence is detected here instead:
    // every new result (partial or final) restarts the countdown, and
    // reaching zero without any further speech triggers the send.
    _restartSilenceCountdown();
  }

  void _restartSilenceCountdown() {
    _silenceTimer?.cancel();
    if (!_conversationModeActive) return;

    final guardUntil = _silenceGuardUntil;
    if (guardUntil != null && DateTime.now().isBefore(guardUntil)) {
      // Within the brief post-(re)start grace period — don't start counting
      // down yet, just show the plain "listening" state.
      setState(() => _silenceCountdown = null);
      return;
    }

    setState(() => _silenceCountdown = _silenceThresholdSeconds);
    var cuePlayed = false;
    _silenceTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!cuePlayed) {
        cuePlayed = true;
        _playSilenceCue();
      }
      final remaining = (_silenceCountdown ?? 1) - 1;
      if (remaining <= 0) {
        timer.cancel();
        setState(() => _silenceCountdown = null);
        _handleSilenceTimeout();
      } else {
        setState(() => _silenceCountdown = remaining);
      }
    });
  }

  Future<void> _playSilenceCue() async {
    try {
      await _cuePlayer.play(AssetSource('sounds/silence_cue.wav'), volume: 0.18);
    } catch (e) {
      // Purely a nice-to-have UI cue — never let it affect the actual
      // conversation flow.
      debugPrint('Silence cue playback failed: $e');
    }
  }

  Future<void> _handleSilenceTimeout() async {
    final text = _textController.text.trim();
    await _speech.stop();
    if (text.isNotEmpty) {
      await _handleSend();
    }
    // Keep the conversation going hands-free: start listening again for the
    // next turn, unless the user turned conversation mode off in the
    // meantime (e.g. while the previous turn was still sending).
    if (_conversationModeActive && mounted) {
      await _startListening(isAutoRestart: true);
    }
  }

  Future<void> _handleSend() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _isSending) return;

    _silenceTimer?.cancel();
    setState(() => _silenceCountdown = null);
    if (_isListening) {
      await _speech.stop();
    }

    setState(() {
      _messages.add(ChatMessage(role: ChatRole.user, text: text));
      _isSending = true;
      _isListening = false;
    });
    _textController.clear();
    _scrollToBottom();

    String? audioUrlToPlay;
    try {
      final result = await _api.sendMessage(sessionId: _sessionId, text: text);
      setState(() {
        _messages.add(
          ChatMessage(role: ChatRole.assistant, text: result.text, audioUrl: result.audioUrl),
        );
      });
      audioUrlToPlay = result.audioUrl;
    } on ConversationApiException catch (e) {
      setState(() {
        _messages.add(ChatMessage(role: ChatRole.error, text: e.message));
      });
    } finally {
      // Done sending regardless of what happens with audio playback below —
      // playback (which can hang if the browser blocks autoplay; see
      // _playAudio) must never keep the input/send controls disabled.
      if (mounted) {
        setState(() => _isSending = false);
      }
      _scrollToBottom();
    }

    if (audioUrlToPlay != null) {
      await _playAudio(audioUrlToPlay, isManualReplay: false);
    }
  }

  Future<void> _playAudio(String url, {required bool isManualReplay}) async {
    try {
      // Some browsers leave the play() promise pending indefinitely instead
      // of rejecting it when autoplay is blocked (rather than throwing
      // immediately), so bound it — otherwise this hangs forever.
      await _audioPlayer.play(UrlSource(url)).timeout(const Duration(seconds: 10));
    } catch (e) {
      // Always log so playback failures (blocked autoplay, CORS, expired
      // signed URL, ...) are visible in the browser console even when we
      // don't show the user an error.
      debugPrint('Audio playback failed for $url: $e');
      // Autoplay can be blocked by the browser until the user interacts
      // with the page — that's expected and the "音声を再生" button lets
      // them retry, so stay silent there. A manual tap failing is not
      // expected, so surface it.
      if (isManualReplay && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('音声を再生できませんでした: $e')),
        );
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('音声AIパートナー'),
        actions: [_buildSilenceThresholdMenu()],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? const Center(
                      child: Text('メッセージを送信して会話を始めましょう', style: TextStyle(color: Colors.grey)),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final message = _messages[index];
                        return ChatBubble(
                          message: message,
                          onReplayAudio: message.audioUrl != null
                              ? () => _playAudio(message.audioUrl!, isManualReplay: true)
                              : null,
                        );
                      },
                    ),
            ),
            if (_isSending) const LinearProgressIndicator(minHeight: 2),
            if (_isListening) _buildListeningIndicator(),
            _buildInputBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildSilenceThresholdMenu() {
    return PopupMenuButton<int>(
      tooltip: '無音判定時間(発話が止まってから自動送信までの秒数)',
      initialValue: _silenceThresholdSeconds,
      onSelected: (value) => setState(() => _silenceThresholdSeconds = value),
      itemBuilder: (context) => [
        for (var s = _minSilenceThresholdSeconds; s <= _maxSilenceThresholdSeconds; s++)
          PopupMenuItem(value: s, child: Text('無音判定: $s秒')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.timer_outlined, size: 20),
            const SizedBox(width: 4),
            Text('$_silenceThresholdSeconds秒'),
          ],
        ),
      ),
    );
  }

  Widget _buildListeningIndicator() {
    final countdown = _silenceCountdown;
    final label = countdown != null ? '送信まで: $countdown' : '音声を認識しています…';
    return Container(
      width: double.infinity,
      color: Colors.red.shade50,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, color: Colors.red.shade400, size: 12),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: Colors.red.shade700)),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          IconButton(
            onPressed: _isSending ? null : _toggleListening,
            tooltip: _speechAvailable ? '音声入力' : '音声入力は利用できません',
            icon: Icon(
              _isListening ? Icons.mic : (_speechAvailable ? Icons.mic_none : Icons.mic_off),
              color: _isListening
                  ? Colors.red
                  : (_speechAvailable ? null : Theme.of(context).disabledColor),
            ),
          ),
          Expanded(
            child: TextField(
              controller: _textController,
              enabled: !_isSending,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _handleSend(),
              decoration: InputDecoration(
                hintText: _isListening ? '話しかけてください…' : 'メッセージを入力',
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(24)),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: _isSending ? null : _handleSend,
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}
