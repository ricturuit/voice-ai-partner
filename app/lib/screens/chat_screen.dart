import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/conversation_controller.dart';
import '../services/learning_progress_store.dart' show PlaybackSpeed;
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
        title: Text(_controller.learningMode ? '英語学習モード' : '音声AIパートナー'),
        actions: [
          _buildSpeedMenu(),
          IconButton(
            tooltip: _controller.learningMode ? '英語学習モードを終了' : '英語学習モード',
            onPressed: () => _controller.setLearningMode(!_controller.learningMode),
            icon: Icon(
              Icons.school_outlined,
              color: _controller.learningMode ? Colors.teal : null,
            ),
          ),
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
            if (_controller.learningMode) _buildLearningHeader(),
            Expanded(
              child: _controller.messages.isEmpty
                  ? Center(
                      child: Text(
                        _controller.learningMode
                            ? 'Say hello to start! 英語で話しかけてみましょう'
                            : 'メッセージを送信して会話を始めましょう',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      itemCount: _controller.messages.length,
                      itemBuilder: (context, index) {
                        final message = _controller.messages[index];
                        return ChatBubble(
                          message: message,
                          // Withheld while a reply is being read: both share
                          // the one <audio> element, so starting a replay
                          // now would cut the current reply off mid-sentence.
                          onReplayAudio:
                              message.audioUrl != null && !_controller.isPlayingReply
                                  ? () => _controller.playAudio(
                                        message.audioUrl!,
                                        isManualReplay: true,
                                      )
                                  : null,
                        );
                      },
                    ),
            ),
            if (_controller.isSending) const LinearProgressIndicator(minHeight: 2),
            if (_controller.lastTestResult != null) _buildTestResultBanner(),
            if (_controller.isPlayingReply) _buildPlayingReplyIndicator(),
            if (_controller.autoplayBlockedUrl != null) _buildAutoplayBlockedBanner(),
            if (_controller.isListening) _buildListeningIndicator(),
            if (_controller.learningMode) _buildInputAssistance(),
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
          Text('音声を認識しています…(✕でやり直せます)', style: TextStyle(color: Colors.red.shade700)),
        ],
      ),
    );
  }

  /// Reply playback speed. Changing it takes effect immediately, including
  /// on a reply that is already being read aloud, so it can be slowed down
  /// mid-sentence rather than only for the next one.
  Widget _buildSpeedMenu() {
    return PopupMenuButton<PlaybackSpeed>(
      tooltip: '読み上げの速さ',
      initialValue: _controller.playbackSpeed,
      onSelected: _controller.setPlaybackSpeed,
      itemBuilder: (context) => [
        for (final speed in PlaybackSpeed.values)
          PopupMenuItem(
            value: speed,
            child: Row(
              children: [
                SizedBox(
                  width: 46,
                  child: Text(
                    speed.display,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Text(speed.label),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.speed, size: 20),
            const SizedBox(width: 3),
            Text(_controller.playbackSpeed.display, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  /// Current level, its plain-Japanese meaning, and the level-test control.
  Widget _buildLearningHeader() {
    final level = _controller.level;
    final testing = _controller.isLevelTest;
    return Container(
      width: double.infinity,
      color: Colors.teal.shade50,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.teal.shade600,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        level.code,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      level.eiken,
                      style: TextStyle(color: Colors.teal.shade900, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  testing
                      ? 'レベルテスト中… ${_controller.levelTestTurn}/${ConversationController.levelTestTotalTurns}'
                      : level.goal,
                  style: TextStyle(color: Colors.teal.shade900, fontSize: 11),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: testing ? _controller.cancelLevelTest : _controller.startLevelTest,
            icon: Icon(testing ? Icons.close : Icons.workspace_premium_outlined, size: 18),
            label: Text(testing ? '中止' : 'テスト'),
            style: TextButton.styleFrom(foregroundColor: Colors.teal.shade800),
          ),
        ],
      ),
    );
  }

  /// Hint words for the learner's next reply, plus the on-demand suggested
  /// replies. Both arrive with 名取's reply, so tapping is instant; the
  /// suggestions stay hidden until asked for so they don't spoil the attempt.
  Widget _buildInputAssistance() {
    final hints = _controller.hintWords;
    final suggestions = _controller.suggestedReplies;
    if (hints.isEmpty && suggestions.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_controller.showSuggestedReplies && suggestions.isNotEmpty)
            ...suggestions.map(
              (s) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: InkWell(
                  onTap: () => _controller.useSuggestedReply(s.en),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.teal.shade50,
                      border: Border.all(color: Colors.teal.shade200),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(s.en, style: const TextStyle(fontSize: 14)),
                        Text(
                          s.ja,
                          style: TextStyle(fontSize: 11, color: Colors.teal.shade900),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Row(
            children: [
              if (suggestions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(
                    avatar: Icon(
                      _controller.showSuggestedReplies
                          ? Icons.visibility_off_outlined
                          : Icons.lightbulb_outline,
                      size: 16,
                    ),
                    label: Text(_controller.showSuggestedReplies ? '隠す' : '回答例'),
                    onPressed: _controller.toggleSuggestedReplies,
                    backgroundColor: Colors.amber.shade50,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final h in hints)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ActionChip(
                            label: Text('${h.en}（${h.ja}）', style: const TextStyle(fontSize: 12)),
                            onPressed: () => _controller.insertHintWord(h.en),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The verdict from a finished level test, including a level-up when the
  /// learner passed.
  Widget _buildTestResultBanner() {
    final result = _controller.lastTestResult!;
    final leveledUp = _controller.leveledUpTo;
    final color = result.passed ? Colors.green : Colors.orange;
    return Container(
      width: double.infinity,
      color: color.shade50,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            result.passed ? Icons.emoji_events : Icons.replay_circle_filled_outlined,
            color: color.shade700,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  result.passed
                      ? (leveledUp != null
                          ? '合格！ ${leveledUp.code}（${leveledUp.eiken}）にレベルアップ'
                          : '合格！ 最高レベルに到達しています')
                      : 'もう一歩。同じレベルでもう一度挑戦しましょう',
                  style: TextStyle(fontWeight: FontWeight.bold, color: color.shade900),
                ),
                if (result.comment.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    result.comment,
                    style: TextStyle(fontSize: 12, color: color.shade900, height: 1.5),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: '閉じる',
            onPressed: _controller.dismissTestResult,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }

  /// Shown when a reply's audio couldn't start on its own. Tapping carries
  /// a fresh user gesture, which is what blocked playback actually needs —
  /// and it makes the failure visible rather than silently degrading to
  /// text-only (see ConversationController.autoplayBlockedUrl).
  Widget _buildAutoplayBlockedBanner() {
    return Material(
      color: Colors.amber.shade50,
      child: InkWell(
        onTap: _controller.retryBlockedAutoplay,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.play_circle_outline, color: Colors.amber.shade900, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '音声を自動再生できませんでした。タップして再生',
                      style: TextStyle(color: Colors.amber.shade900),
                    ),
                    if (_controller.autoplayFailureReason != null)
                      Text(
                        _controller.autoplayFailureReason!,
                        style: TextStyle(
                          color: Colors.amber.shade900.withValues(alpha: 0.7),
                          fontSize: 10,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
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
          if (_controller.isListening)
            IconButton(
              onPressed: _controller.cancelListening,
              tooltip: 'やり直す(認識内容を破棄)',
              icon: const Icon(Icons.close, color: Colors.red),
            ),
          IconButton(
            onPressed: _controller.isPlayingReply ? _controller.forceStopReading : null,
            tooltip: '読み上げを停止',
            icon: const Icon(Icons.stop_circle_outlined),
          ),
          Expanded(
            child: TextField(
              controller: _controller.inputTextController,
              // Deliberately never disabled (not even while isSending) —
              // matches the "type ahead" behavior already used for
              // isPlayingReply (see the comment on that field), and sending
              // is already blocked at the send button (controlsLocked
              // below) and inside sendText() itself, so nothing depends on
              // this field's enabled state for correctness. Flutter's web
              // text-input plugin has a known issue where toggling
              // TextField.enabled false→true doesn't always fully restore
              // the underlying input's focusability, which read as "can't
              // type from the 2nd message onward" — every send flipped
              // enabled false then true again. Leaving it always enabled
              // sidesteps that toggle entirely.
              minLines: 1,
              maxLines: 4,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: _controller.isListening
                    ? (_controller.learningMode ? 'Speak in English…' : '話しかけてください…')
                    : (_controller.learningMode ? 'Type in English…' : 'メッセージを入力'),
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
