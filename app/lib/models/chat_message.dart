enum ChatRole { user, assistant, error }

class ChatMessage {
  final ChatRole role;
  final String text;
  final String? audioUrl;

  const ChatMessage({required this.role, required this.text, this.audioUrl});
}
