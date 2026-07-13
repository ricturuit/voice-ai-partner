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
}
