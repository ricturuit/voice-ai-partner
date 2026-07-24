import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/conversation_controller.dart';

enum _ButtonVisualState { idle, listening, sending, playingReply }

/// Cotomo-style dedicated voice-conversation mode: a single large circular
/// button whose appearance and label reflect the current turn state, with a
/// live caption above it showing whatever is currently being heard or
/// spoken (see [_FlowingCaption]) — never the full chat history, just the
/// most recent line. The same [ConversationController] (and therefore the
/// same sessionId/history) is shared with the chat mode screen, so
/// switching modes never loses conversation context.
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

  // Single tap while listening ends input and sends whatever was recognized
  // so far — voice input is always explicit (tap to start, tap to stop and
  // send), never an automatic silence-timeout. Canceling without sending is
  // a long-press instead, so it stays available but isn't the default
  // action.
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
              _FlowingCaption(text: _controller.captionText),
              const SizedBox(height: 32),
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

/// A fixed-height caption window that always keeps its latest content
/// anchored at the bottom (fully visible) and fades/scrolls anything older
/// up and out through a gradient mask — a "flowing captions" look, so only
/// the most recent line ever needs full attention. Bound to
/// [ConversationController.captionText], which is either the live partial
/// speech-recognition result while listening, or whatever was most recently
/// said (the user's own utterance, then the assistant's reply once it
/// arrives and is read aloud).
class _FlowingCaption extends StatefulWidget {
  const _FlowingCaption({required this.text});

  final String text;

  @override
  State<_FlowingCaption> createState() => _FlowingCaptionState();
}

class _FlowingCaptionState extends State<_FlowingCaption> {
  final ScrollController _scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant _FlowingCaption oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _scrollToLatest();
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 96,
      width: double.infinity,
      child: widget.text.isEmpty
          ? const SizedBox.shrink()
          : ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black, Colors.black],
                stops: [0.0, 0.4, 1.0],
              ).createShader(rect),
              child: SingleChildScrollView(
                controller: _scrollController,
                // The text updates programmatically (new speech recognized,
                // a new reply arriving) — scrolling itself is never
                // user-driven, only the auto-scroll-to-latest above.
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      widget.text,
                      key: ValueKey(widget.text),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.82),
                        height: 1.6,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
