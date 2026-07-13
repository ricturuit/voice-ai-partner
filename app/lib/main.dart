import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() {
  runApp(const VoiceAiPartnerApp());
}

class VoiceAiPartnerApp extends StatelessWidget {
  const VoiceAiPartnerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '音声AIパートナー',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: const HomeScreen(),
    );
  }
}
