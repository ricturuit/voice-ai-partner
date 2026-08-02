import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/chat_message.dart';
import '../models/learning_level.dart';

class ConversationApiException implements Exception {
  final String message;
  ConversationApiException(this.message);

  @override
  String toString() => message;
}

class ConversationResult {
  final String text;
  final String? audioUrl;

  /// The fields below are only ever populated in English learning mode; the
  /// server omits them entirely otherwise.
  final String? translation;
  final List<HintWord> hintWords;
  final List<HintWord> suggestedReplies;
  final LevelTestResult? testResult;

  const ConversationResult({
    required this.text,
    this.audioUrl,
    this.translation,
    this.hintWords = const [],
    this.suggestedReplies = const [],
    this.testResult,
  });
}

class ConversationApi {
  /// Sends one turn. [level] and the level-test fields are only meaningful
  /// when [englishLearningMode] is true, and are omitted from the request
  /// otherwise so a normal-mode request stays exactly what it always was.
  Future<ConversationResult> sendMessage({
    required String sessionId,
    required String text,
    bool englishLearningMode = false,
    LearningLevel? level,
    bool levelTest = false,
    int levelTestTurn = 0,
  }) async {
    final http.Response response;
    try {
      response = await http.post(
        Uri.parse(AppConfig.conversationApiUrl),
        headers: {
          'Content-Type': 'application/json',
          'x-api-secret': AppConfig.apiSharedSecret,
        },
        body: jsonEncode({
          'sessionId': sessionId,
          'text': text,
          if (englishLearningMode) ...{
            'mode': 'english_learning',
            'level': (level ?? LearningLevel.a1).code,
            if (levelTest) ...{
              'levelTest': true,
              'levelTestTurn': levelTestTurn,
            },
          },
        }),
      );
    } catch (_) {
      throw ConversationApiException('サーバーに接続できませんでした。通信環境を確認してください。');
    }

    if (response.statusCode == 401) {
      throw ConversationApiException('認証に失敗しました(共有シークレットが正しくありません)。');
    }
    if (response.statusCode != 200) {
      throw ConversationApiException('サーバーエラーが発生しました (status: ${response.statusCode})');
    }

    final Map<String, dynamic> data;
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw ConversationApiException('サーバーからの応答を解析できませんでした。');
    }

    final replyText = data['text'] as String?;
    if (replyText == null) {
      throw ConversationApiException('サーバーからの応答が不正です。');
    }

    return ConversationResult(
      text: replyText,
      audioUrl: data['audioUrl'] as String?,
      translation: data['translation'] as String?,
      hintWords: _parsePairs(data['hintWords']),
      suggestedReplies: _parsePairs(data['suggestedReplies']),
      testResult: _parseTestResult(data['testResult']),
    );
  }

  /// Tolerant on purpose: a malformed hint costs the learner a suggestion
  /// chip, which must never be able to fail the whole turn.
  List<HintWord> _parsePairs(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .where((m) => m['en'] is String && m['ja'] is String)
        .map((m) => HintWord(en: m['en'] as String, ja: m['ja'] as String))
        .toList(growable: false);
  }

  LevelTestResult? _parseTestResult(dynamic raw) {
    if (raw is! Map || raw['passed'] is! bool) return null;
    return LevelTestResult(
      passed: raw['passed'] as bool,
      comment: raw['comment'] is String ? raw['comment'] as String : '',
    );
  }
}
