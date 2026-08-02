enum ChatRole { user, assistant, error }

/// A word the learner might want for their next reply, offered as a tappable
/// hint under the input bar (English learning mode only).
class HintWord {
  final String en;
  final String ja;

  const HintWord({required this.en, required this.ja});
}

/// The outcome of a level test, present only on the turn the verdict is given.
class LevelTestResult {
  final bool passed;
  final String comment;

  const LevelTestResult({required this.passed, required this.comment});
}

class ChatMessage {
  final ChatRole role;
  final String text;
  final String? audioUrl;

  /// Japanese rendering of [text], shown small beneath it. Only set for
  /// 名取's English replies in learning mode — null for Japanese replies
  /// (including grammar explanations, which are already Japanese) and for
  /// every message outside learning mode.
  final String? translation;

  const ChatMessage({
    required this.role,
    required this.text,
    this.audioUrl,
    this.translation,
  });
}
