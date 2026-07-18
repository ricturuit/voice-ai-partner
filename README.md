# voice-ai-partner

音声AIパートナー(名取)のPhase 1バックエンド・Flutter Webクライアント。

- `infra/` — AWS CDK(TypeScript)。DynamoDB・S3・Lambda(Claude + ElevenLabs TTS)・CloudFront。詳細は `infra/README.md`
- `app/` — Flutter Webクライアント(チャットモード・音声会話モード)。詳細は `app/README.md`
- `.claude/skills/natori-japanese/` — キャラクター「名取」の返答が仕様通りの自然な日本語音声会話になっているかを採点するClaude Codeスキル。詳細はそのディレクトリの `SKILL.md`