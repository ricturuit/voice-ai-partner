/// The English proficiency ladder the learning mode progresses through.
///
/// These are CEFR levels, chosen over an ad-hoc scale because they are the
/// framework MEXT publishes an official 英検 mapping against, and because the
/// CEFR self-assessment grid's own wording already names this app's two
/// stated goals at specific levels: B2 is where "I can understand most TV
/// news and current affairs programmes" appears, and C1 is where the grid
/// describes using the language "for social and professional purposes".
///
/// A1 is the floor (英検3級 / 中学生程度) and C1 the ceiling, as specified.
/// C2 is deliberately excluded: it is beyond "business conversation", and
/// 英検 cannot certify it at all (even a perfect 1級 maps to C1).
enum LearningLevel {
  a1(
    code: 'A1',
    eiken: '英検3級',
    goal: 'ゆっくり言い直してもらえれば、簡単なやりとりができる',
  ),
  a2(
    code: 'A2',
    eiken: '英検準2級',
    goal: '身近な話題について、簡単な情報交換ができる',
  ),
  b1(
    code: 'B1',
    eiken: '英検2級',
    goal: '身近な話題なら、準備なしで会話に入れる',
  ),
  b2(
    code: 'B2',
    eiken: '英検準1級',
    goal: '流暢にやりとりでき、ニュースもほぼ理解できる',
  ),
  c1(
    code: 'C1',
    eiken: '英検1級',
    goal: '言葉を探さず流暢に、仕事の場面でも運用できる',
  );

  const LearningLevel({required this.code, required this.eiken, required this.goal});

  /// The CEFR code sent to the API (`A1`…`C1`).
  final String code;

  /// Roughly equivalent 英検 grade, per MEXT's published mapping. Shown in the
  /// UI because it is the scale a Japanese learner is likely to already have
  /// a feel for.
  final String eiken;

  /// What this level means in conversation terms, in plain Japanese.
  final String goal;

  bool get isHighest => this == LearningLevel.values.last;

  /// The next level up, or `null` at the ceiling.
  LearningLevel? get next =>
      isHighest ? null : LearningLevel.values[index + 1];

  static LearningLevel fromCode(String? code) => LearningLevel.values.firstWhere(
        (l) => l.code == code,
        orElse: () => LearningLevel.a1,
      );
}
