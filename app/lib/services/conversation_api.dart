import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

class ConversationApiException implements Exception {
  final String message;
  ConversationApiException(this.message);

  @override
  String toString() => message;
}

class ConversationResult {
  final String text;
  final String? audioUrl;

  const ConversationResult({required this.text, this.audioUrl});
}

class ConversationApi {
  Future<ConversationResult> sendMessage({
    required String sessionId,
    required String text,
  }) async {
    final http.Response response;
    try {
      response = await http.post(
        Uri.parse(AppConfig.conversationApiUrl),
        headers: {
          'Content-Type': 'application/json',
          'x-api-secret': AppConfig.apiSharedSecret,
        },
        body: jsonEncode({'sessionId': sessionId, 'text': text}),
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

    return ConversationResult(text: replyText, audioUrl: data['audioUrl'] as String?);
  }
}
