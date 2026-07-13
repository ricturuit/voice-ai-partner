import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../services/conversation_api.dart';
import '../widgets/chat_bubble.dart';

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
  final SpeechToText _speech = SpeechToText();
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];

  bool _isSending = false;
  bool _speechInitDone = false;
  bool _speechAvailable = false;
  bool _isListening = false;

  @override
  void initState() {
    super.initState();
    _sessionId = const Uuid().v4();
    _initSpeech();
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
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
    setState(() => _isListening = false);
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
    if (_isListening) {
      await _speech.stop();
      if (mounted) setState(() => _isListening = false);
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

    setState(() => _isListening = true);
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
      debugPrint('Speech recognition failed to start: $e');
      if (mounted) {
        setState(() => _isListening = false);
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
  }

  Future<void> _handleSend() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _isSending) return;

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

    try {
      final result = await _api.sendMessage(sessionId: _sessionId, text: text);
      setState(() {
        _messages.add(
          ChatMessage(role: ChatRole.assistant, text: result.text, audioUrl: result.audioUrl),
        );
      });
      if (result.audioUrl != null) {
        await _playAudio(result.audioUrl!, isManualReplay: false);
      }
    } on ConversationApiException catch (e) {
      setState(() {
        _messages.add(ChatMessage(role: ChatRole.error, text: e.message));
      });
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
      _scrollToBottom();
    }
  }

  Future<void> _playAudio(String url, {required bool isManualReplay}) async {
    try {
      await _audioPlayer.play(UrlSource(url));
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
      appBar: AppBar(title: const Text('音声AIパートナー')),
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

  Widget _buildListeningIndicator() {
    return Container(
      width: double.infinity,
      color: Colors.red.shade50,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, color: Colors.red.shade400, size: 12),
          const SizedBox(width: 8),
          Text('音声を認識しています…', style: TextStyle(color: Colors.red.shade700)),
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
