import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/conversation_controller.dart';
import '../widgets/chat_bubble.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.controller, required this.onSwitchToVoiceCall});

  final ConversationController controller;
  final VoidCallback onSwitchToVoiceCall;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<String>? _errorSubscription;

  ConversationController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    _errorSubscription = _controller.errorStream.listen(_showError);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _errorSubscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    _scrollToBottom();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
        actions: [
          _buildSilenceThresholdMenu(),
          IconButton(
            tooltip: '音声会話モードに切り替え',
            onPressed: widget.onSwitchToVoiceCall,
            icon: const Icon(Icons.graphic_eq),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _controller.messages.isEmpty
                  ? const Center(
                      child: Text('メッセージを送信して会話を始めましょう', style: TextStyle(color: Colors.grey)),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      itemCount: _controller.messages.length,
                      itemBuilder: (context, index) {
                        final message = _controller.messages[index];
                        return ChatBubble(
                          message: message,
                          onReplayAudio: message.audioUrl != null
                              ? () => _controller.playAudio(message.audioUrl!, isManualReplay: true)
                              : null,
                        );
                      },
                    ),
            ),
            if (_controller.isSending) const LinearProgressIndicator(minHeight: 2),
            if (_controller.isPlayingReply) _buildPlayingReplyIndicator(),
            if (_controller.isListening) _buildListeningIndicator(),
            _buildInputBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildSilenceThresholdMenu() {
    return PopupMenuButton<int>(
      tooltip: '無音判定時間(発話が止まってから自動送信までの秒数)',
      initialValue: _controller.silenceThresholdSeconds,
      onSelected: (value) => _controller.setSilenceThresholdSeconds(value),
      itemBuilder: (context) => [
        for (var s = minSilenceThresholdSeconds; s <= maxSilenceThresholdSeconds; s++)
          PopupMenuItem(value: s, child: Text('無音判定: $s秒')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.timer_outlined, size: 20),
            const SizedBox(width: 4),
            Text('${_controller.silenceThresholdSeconds}秒'),
          ],
        ),
      ),
    );
  }

  Widget _buildListeningIndicator() {
    final countdown = _controller.silenceCountdown;
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

  Widget _buildPlayingReplyIndicator() {
    return Container(
      width: double.infinity,
      color: Colors.blue.shade50,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.volume_up, color: Colors.blue.shade400, size: 16),
          const SizedBox(width: 8),
          Text('読み上げ中…(完了までマイク入力・送信はできません)',
              style: TextStyle(color: Colors.blue.shade700)),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    final controlsLocked = _controller.isSending || _controller.isPlayingReply;
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          IconButton(
            onPressed: controlsLocked ? null : _controller.toggleListening,
            tooltip: _controller.speechAvailable ? '音声入力' : '音声入力は利用できません',
            icon: Icon(
              _controller.isListening
                  ? Icons.mic
                  : (_controller.speechAvailable ? Icons.mic_none : Icons.mic_off),
              color: _controller.isListening
                  ? Colors.red
                  : (_controller.speechAvailable ? null : Theme.of(context).disabledColor),
            ),
          ),
          IconButton(
            onPressed: _controller.isPlayingReply ? _controller.forceStopReading : null,
            tooltip: '読み上げを停止',
            icon: const Icon(Icons.stop_circle_outlined),
          ),
          Expanded(
            child: TextField(
              controller: _controller.inputTextController,
              enabled: !_controller.isSending,
              minLines: 1,
              maxLines: 4,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: _controller.isListening ? '話しかけてください…' : 'メッセージを入力',
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(24)),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed:
                controlsLocked ? null : () => _controller.sendText(_controller.inputTextController.text),
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}
