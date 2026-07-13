# voice_ai_partner_client

音声AIパートナーのクライアントアプリ(Flutter)。Phase 1はFlutter Web向けの実装で、
実機iOS/Androidビルドは後回し。標準の `flutter create` 構成のままなので、
`ios/` `android/` フォルダは既にあり、将来モバイルアプリとして流用できる。

## 公開URL

http://voice-ai-partner-web-568529252964-ap-northeast-1.s3-website-ap-northeast-1.amazonaws.com/

S3の静的website hosting(バケット: `voice-ai-partner-web-568529252964-ap-northeast-1`、
`infra/lib/infra-web-stack.ts` でCDK管理)。GitHub Pagesではなくこちらを選んだ理由は
`infra/README.md` 参照。

## 画面構成

- テキスト入力欄 + 送信ボタン(下部)
- 会話履歴を吹き出し表示(ユーザー発言は右・青、AI返答は左・グレー、エラーは赤)
- AI返答の音声は自動再生。ブラウザの自動再生ポリシーでブロックされた場合に備え、
  吹き出し内に「音声を再生」ボタンで手動再生も可能

## 会話APIとの連携

- エンドポイント: `https://se2cfbj2p7jinxigw2nmlpz35e0kcjco.lambda-url.ap-northeast-1.on.aws/`
  (`lib/config.dart` にハードコード。シークレットではないので問題なし)
- `sessionId` はアプリ起動時(1タブのライフサイクル中)に1回だけ`uuid` で生成し、
  そのセッション中は使い回す(`lib/screens/chat_screen.dart`)
- リクエスト: `POST { sessionId, text }`、ヘッダー `x-api-secret`
- レスポンス: `{ text, audioUrl }` — `text` を吹き出しに、`audioUrl` を自動再生

## ⚠️ 重要: `x-api-secret` の扱いについて(暫定実装)

**共有シークレットの値はビルド時に `--dart-define=API_SHARED_SECRET=<値>` で
コンパイル済みJSバンドルに埋め込んでいる。** ソースコード・Gitリポジトリには
一切含まれないが、ビルド後の `main.dart.js` を開けば誰でも値を読み取れる
(ブラウザの開発者ツールで丸見えになる)。

これはPhase 1の暫定対応であり、**本番公開前に必ず見直しが必要**:

- 現状: 静的サイト + 埋め込みシークレットで、実質「誰でもAPIキーを取り出して
  直接叩ける」状態。乱用されると会話API(Claude/ElevenLabs呼び出し)の
  コストがそのままかかる
- 見直し案の例:
  - バックエンドに軽量な認証プロキシ/トークン発行エンドポイントを用意し、
    クライアントは短命トークンだけを受け取る
  - Cognito等でユーザー単位の認証に切り替え、共有シークレットを廃止
  - API Gateway + WAF + レート制限を前段に置く

## ローカル開発

```bash
flutter pub get
flutter run -d chrome --dart-define=API_SHARED_SECRET=<voice-ai-partner-api-shared-secretの値>
```

シークレット値の取得:
```bash
aws secretsmanager get-secret-value \
  --secret-id voice-ai-partner-api-shared-secret \
  --region ap-northeast-1 --query SecretString --output text
```

## ビルド & デプロイ

```bash
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id voice-ai-partner-api-shared-secret \
  --region ap-northeast-1 --query SecretString --output text)

flutter build web --release --no-web-resources-cdn \
  --dart-define=API_SHARED_SECRET="$SECRET"

aws s3 sync build/web s3://voice-ai-partner-web-568529252964-ap-northeast-1/ \
  --region ap-northeast-1 --delete
```

`--no-web-resources-cdn` は必須。付けないとCanvasKit/フォントをGoogleのCDN
(gstatic.com)から読み込む設定になり、CDNへのアクセスが制限されたネットワーク
環境で真っ白な画面になる。このフラグでビルド成果物にCanvasKit一式を同梱し、
外部CDNに一切依存しない自己完結型のサイトにしている。

## 動作確認したこと

- ヘッドレスブラウザ(モバイル相当のビューポート・UA)で実サイトを読み込み、
  画面が正しく描画されることをスクリーンショットで確認
- メッセージ送信時に、正しい `sessionId`・`text`・`x-api-secret` ヘッダーを
  含むPOSTリクエストが会話APIに向けて送信されることをネットワークログで確認
- 会話APIへのCORSプリフライト(OPTIONS)がこのサイトのオリジンに対して
  正しく `Access-Control-Allow-Origin` / `-Headers` / `-Methods` を返すことを確認
- 会話API自体は別途curlで何度もE2E動作確認済み(`infra/README.md`参照)

## 今後(モバイル版への展開時)

- `flutter create` の標準構成のため `flutter build ios` / `flutter build apk` は
  そのまま試せるはず(未検証)
- モバイルではシークレットのビルド埋め込みはさらにリスクが高い
  (アプリのバイナリを解析されると同様に漏れる)ため、上記の見直しは
  モバイル版に進む前に必須
