import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
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
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];

  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _sessionId = const Uuid().v4();
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _handleSend() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() {
      _messages.add(ChatMessage(role: ChatRole.user, text: text));
      _isSending = true;
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
            _buildInputBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              enabled: !_isSending,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _handleSend(),
              decoration: const InputDecoration(
                hintText: 'メッセージを入力',
                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
