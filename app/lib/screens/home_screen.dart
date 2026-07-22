import 'package:flutter/material.dart';

import '../controllers/conversation_controller.dart';
import 'chat_screen.dart';
import 'voice_call_screen.dart';

/// Owns the single [ConversationController] shared by both modes and
/// switches between them. Only the active mode's screen is built/mounted at
/// a time, so its listeners/subscriptions are torn down when not in use.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final ConversationController _controller;
  bool _isChatMode = true;

  @override
  void initState() {
    super.initState();
    _controller = ConversationController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isChatMode) {
      return ChatScreen(
        controller: _controller,
        onSwitchToVoiceCall: () => setState(() => _isChatMode = false),
      );
    }
    return VoiceCallScreen(
      controller: _controller,
      onSwitchToChat: () => setState(() => _isChatMode = true),
    );
  }
}
