import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chat_message.dart';

class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback? onReplayAudio;

  const ChatBubble({super.key, required this.message, this.onReplayAudio});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    final isError = message.role == ChatRole.error;

    final Color bubbleColor;
    final Color textColor;
    if (isError) {
      bubbleColor = Colors.red.shade50;
      textColor = Colors.red.shade900;
    } else if (isUser) {
      bubbleColor = Colors.blue.shade500;
      textColor = Colors.white;
    } else {
      bubbleColor = Colors.grey.shade200;
      textColor = Colors.black87;
    }

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message.text, style: TextStyle(color: textColor)),
            if (!isError)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: () => _copyToClipboard(context, message.text),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.copy, size: 14, color: textColor.withValues(alpha: 0.8)),
                          const SizedBox(width: 4),
                          Text(
                            'コピー',
                            style: TextStyle(color: textColor.withValues(alpha: 0.8), fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    if (message.audioUrl != null && onReplayAudio != null) ...[
                      const SizedBox(width: 12),
                      InkWell(
                        onTap: onReplayAudio,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.volume_up,
                              size: 16,
                              color: textColor.withValues(alpha: 0.8),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '音声を再生',
                              style: TextStyle(
                                color: textColor.withValues(alpha: 0.8),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _copyToClipboard(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('コピーしました'), duration: Duration(seconds: 1)),
    );
  }
}
