import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/conversation_controller.dart';

enum _ButtonVisualState { idle, listening, sending, playingReply }

/// Cotomo-style dedicated voice-conversation mode: a single large circular
/// button whose appearance and label reflect the current turn state. No
/// chat history or text is ever shown here — the same [ConversationController]
/// (and therefore the same sessionId/history) is shared with the chat mode
/// screen, so switching modes never loses conversation context.
class VoiceCallScreen extends StatefulWidget {
  const VoiceCallScreen({super.key, required this.controller, required this.onSwitchToChat});

  final ConversationController controller;
  final VoidCallback onSwitchToChat;

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  StreamSubscription<String>? _errorSubscription;

  ConversationController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _controller.addListener(_onControllerChanged);
    _errorSubscription = _controller.errorStream.listen(_showError);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _errorSubscription?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    _syncPulseAnimation();
  }

  void _syncPulseAnimation() {
    if (_visualState == _ButtonVisualState.listening) {
      if (!_pulseController.isAnimating) _pulseController.repeat(reverse: true);
    } else {
      if (_pulseController.isAnimating) _pulseController.stop();
      _pulseController.value = 0;
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  _ButtonVisualState get _visualState {
    if (_controller.isSending) return _ButtonVisualState.sending;
    if (_controller.isPlayingReply) return _ButtonVisualState.playingReply;
    if (_controller.isListening) return _ButtonVisualState.listening;
    return _ButtonVisualState.idle;
  }

  // Single tap while listening ends input (sends whatever was recognized so
  // far) instead of canceling — ambient noise can keep the recognizer from
  // ever going quiet on its own, so relying solely on the silence timer left
  // the button stuck in "listening" with no way out. Canceling is now a
  // long-press instead, so it stays available but isn't the default action.
  Future<void> _handleTap() async {
    switch (_visualState) {
      case _ButtonVisualState.sending:
        // Disabled — no-op.
        return;
      case _ButtonVisualState.playingReply:
        await _controller.forceStopReading();
        return;
      case _ButtonVisualState.listening:
        await _controller.stopListeningAndSend();
        return;
      case _ButtonVisualState.idle:
        await _controller.startListening();
        return;
    }
  }

  Future<void> _handleLongPress() async {
    if (_visualState != _ButtonVisualState.listening) return;
    await _controller.cancelListening();
  }

  @override
  Widget build(BuildContext context) {
    final state = _visualState;
    final theme = Theme.of(context);

    final Color color;
    final IconData icon;
    final String label;
    String? subLabel;
    final bool enabled;
    final bool pulse;

    switch (state) {
      case _ButtonVisualState.idle:
        color = theme.colorScheme.primary;
        icon = Icons.mic_none;
        label = 'タップして話す';
        enabled = true;
        pulse = false;
        break;
      case _ButtonVisualState.listening:
        color = Colors.red;
        icon = Icons.mic;
        label = 'タップで入力終了';
        subLabel = '長押しでキャンセル';
        enabled = true;
        pulse = true;
        break;
      case _ButtonVisualState.sending:
        color = Colors.grey;
        icon = Icons.hourglass_top;
        label = '考え中…';
        enabled = false;
        pulse = false;
        break;
      case _ButtonVisualState.playingReply:
        color = Colors.blue;
        icon = Icons.volume_up;
        label = 'タップで停止';
        enabled = true;
        pulse = false;
        break;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('音声AIパートナー'),
        actions: [
          IconButton(
            tooltip: 'チャットモードに切り替え',
            onPressed: widget.onSwitchToChat,
            icon: const Icon(Icons.chat_bubble_outline),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: enabled ? _handleTap : null,
                onLongPress: state == _ButtonVisualState.listening ? _handleLongPress : null,
                child: AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    final scale = pulse ? 1.0 + (_pulseController.value * 0.12) : 1.0;
                    return Transform.scale(
                      scale: scale,
                      child: Container(
                        width: 180,
                        height: 180,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: enabled ? color : color.withValues(alpha: 0.4),
                          boxShadow: pulse
                              ? [
                                  BoxShadow(
                                    color: color.withValues(alpha: 0.4),
                                    blurRadius: 24,
                                    spreadRadius: 8,
                                  ),
                                ]
                              : null,
                        ),
                        child: Icon(icon, color: Colors.white, size: 72),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 24),
              Text(
                label,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: enabled ? null : theme.disabledColor,
                ),
              ),
              if (subLabel != null) ...[
                const SizedBox(height: 4),
                Text(
                  subLabel,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.disabledColor),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
