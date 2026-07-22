@TestOn('chrome')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:voice_ai_partner_client/main.dart';

void main() {
  testWidgets('Chat screen shows input field and send button', (WidgetTester tester) async {
    await tester.pumpWidget(const VoiceAiPartnerApp());

    expect(find.text('音声AIパートナー'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('Mode switch button toggles between chat and voice-call screens',
      (WidgetTester tester) async {
    await tester.pumpWidget(const VoiceAiPartnerApp());

    // Starts in chat mode.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('タップして話す'), findsNothing);

    // Switch to voice-call mode.
    await tester.tap(find.byIcon(Icons.graphic_eq));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('タップして話す'), findsOneWidget);
    // No chat history/text should ever be shown in this mode.
    expect(find.text('メッセージを送信して会話を始めましょう'), findsNothing);

    // Switch back to chat mode.
    await tester.tap(find.byIcon(Icons.chat_bubble_outline));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('タップして話す'), findsNothing);
  });
}
