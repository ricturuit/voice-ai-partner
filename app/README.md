# voice_ai_partner_client

音声AIパートナーのクライアントアプリ(Flutter)。Phase 1はFlutter Web向けの実装で、
実機iOS/Androidビルドは後回し。標準の `flutter create` 構成のままなので、
`ios/` `android/` フォルダは既にあり、将来モバイルアプリとして流用できる。

## 公開URL

**https://d2nglo9qqrftj1.cloudfront.net/** ← こちらを使う(HTTPS、マイク入力に必須)

http://voice-ai-partner-web-568529252964-ap-northeast-1.s3-website-ap-northeast-1.amazonaws.com/
(S3直接、HTTPのみ。マイク入力は動作しない。CloudFrontの原点として内部的に使用)

S3静的website hosting + その手前のCloudFrontディストリビューション(HTTPS化のみが目的、
独自ドメイン/ACM証明書なしで`*.cloudfront.net`のデフォルト証明書を利用)。
`infra/lib/infra-web-stack.ts` でCDK管理。検証フェーズ用の暫定構成のため、
価格クラスは最小(`PRICE_CLASS_100`)、WAF等は付けていない。将来ネイティブ
モバイルアプリに移行してこのWeb版が不要になったら、`InfraWebStack`ごと
`cdk destroy` すればよい。GitHub Pagesではなくこちらを選んだ理由は
`infra/README.md` 参照。

## 画面構成

- テキスト入力欄 + マイクボタン + 送信ボタン(下部)
- マイクボタンをタップすると音声入力(STT)を開始。認識結果はテキスト入力欄に
  リアルタイムで反映される(自動送信はしない。認識結果を確認・修正してから
  送信ボタンを押す想定)。認識中は入力欄上に赤いインジケーター
  (「音声を認識しています…」)を表示
- 会話履歴を吹き出し表示(ユーザー発言は右・青、AI返答は左・グレー、エラーは赤)
- AI返答の音声は自動再生。ブラウザの自動再生ポリシーでブロックされた場合に備え、
  吹き出し内に「音声を再生」ボタンで手動再生も可能

## 音声入力(STT)の実装

- パッケージ: [`speech_to_text`](https://pub.dev/packages/speech_to_text)
  (Web版は`webkitSpeechRecognition`/`SpeechRecognition`(Web Speech API)を
  利用する実装が組み込み済み。追加パッケージ不要)
- アプリ起動時に`SpeechToText.initialize()`でブラウザの対応状況を確認し、
  対応していなければマイクボタンをグレーアウト(`Icons.mic_off`)表示
- マイクボタンタップ時にも改めて利用可否をチェックし、非対応・エラー時は
  SnackBarで理由を表示してテキスト入力にフォールバックできるようにしている
  (`_handleSpeechError` / `_toggleListening`、`chat_screen.dart`)
- `initialize()`・`listen()`双方をtry/catchで保護し、ブラウザ側の予期しない
  例外でアプリ全体がクラッシュしないようにしている

### 解決済み: マイク入力にはHTTPSが必須だった件

**Web Speech API(および`getUserMedia`によるマイクアクセス全般)は、ブラウザの
「セキュアコンテキスト」(HTTPSまたは`localhost`)でのみ動作する。** S3の
静的website hosting単体はプレーンHTTPしか提供できないため、そのままでは
マイク入力が動作しなかった。

実際に検証して切り分けた内容:
- `https://`または`http://localhost`(secure context)では、
  `SpeechRecognition`が正常に初期化され、マイクボタンが有効になる
- プレーンHTTP(非localhost)では `window.isSecureContext` が`false`になり、
  `navigator.mediaDevices` 自体が存在しなくなる。`SpeechRecognition`コンス
  トラクタ自体は存在するためマイクボタンは一見有効に見えるが、タップして
  実際に音声認識を開始しようとすると失敗する

**対応**: S3バケットの手前にCloudFrontディストリビューションを追加し(`infra/lib/infra-web-stack.ts`)、
デフォルト証明書(`*.cloudfront.net`、独自ドメイン・ACM証明書は不要)でHTTPS配信するようにした。
`cloudfront:*`権限が不足していたため、`claude-code-dev`ユーザーにインラインポリシーで追加。
IAM管理ポリシーの上限(10個)に達していたため、追加の管理ポリシーではなくインラインポリシー
(`CloudFrontAccess`)で対応した。

検証フェーズ限定の暫定構成という位置づけのため、価格クラスは最小(`PRICE_CLASS_100`)、
WAF等の追加設定はしていない。ネイティブモバイルアプリへの移行後にこのWeb版が不要になれば、
`InfraWebStack`ごと`cdk destroy`すれば消せる。

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

# CloudFront caches responses, so bust the cache after every deploy or the
# HTTPS URL keeps serving the old build for a while.
aws cloudfront create-invalidation --distribution-id EWNS21M4N3R3L --paths "/*"
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
- 音声再生に必要なS3バケットのCORS設定を確認・修正済み(次項)
- 音声入力(STT)を`http://localhost`(secure context)でローカルサーブし、
  ヘッドレスブラウザ + フェイクマイクデバイス(`--use-fake-device-for-media-stream`)
  で検証:
  - マイクボタンタップ → 音声認識開始 → (フェイクデバイス起因の)
    `audio-capture`エラー発生 → SnackBarで
    「音声入力でエラーが発生しました(audio-capture)。テキスト入力をご利用
    ください。」と表示 → 数秒後に自動的にUIが通常状態に復帰、の一連の
    流れをFlutterのsemanticsツリー(アクセシビリティ用DOM)経由でテキスト
    として確認
  - `window.SpeechRecognition`/`webkitSpeechRecognition`を意図的に無効化
    (未対応ブラウザを模擬)した場合、マイクボタンが「音声入力は利用
    できません」表示になり、タップすると
    「音声入力でエラーが発生しました(speech_not_supported)。テキスト入力
    をご利用ください。」とSnackBarが出ることを確認
  - 上記いずれのケースもアプリがクラッシュしたり無反応になったりせず、
    エラーメッセージ表示 → 通常状態への復帰まで正しく動作することを確認
  - **本番URL(S3 HTTP)では`isSecureContext`が`false`になり
    `navigator.mediaDevices`が存在しなくなることも別途確認済み**
    (次項「⚠️重要」参照。実機での有効な音声入力確認にはHTTPS化が必要)

## 修正済み: 音声が再生されない不具合(2026-07-13)

**症状**: テキスト返答は表示されるが、自動再生・手動再生ボタンのどちらでも
音声が再生されなかった。

**原因**: 音声保存用S3バケット(`voice-ai-partner-artifacts-...`)にCORS設定が
存在しなかった。`audioplayers` のWeb実装(`audioplayers_web`)は、音量・
パン(左右バランス)調整のためWeb Audio APIの`MediaElementAudioSourceNode`に
`<audio>`要素を接続する構造になっており、そのために`<audio>`要素へ
`crossOrigin = "anonymous"` を明示的に設定している
(`wrapped_player.dart`)。この設定がある`<audio>`要素はブラウザが
CORSチェック付きリクエストとして音声を取得しようとするため、S3側に
`Access-Control-Allow-Origin` 等が無いと読み込みに失敗し、再生されない
(かつ`chat_screen.dart`側で例外を握りつぶしていたためエラーも見えなかった)。

**対応**:
1. `infra/lib/infra-core-stack.ts` の `ArtifactsBucket` にCORS設定を追加
   (`GET`/`HEAD`許可、`AllowedOrigins: ["*"]`)。バケット自体は署名付きURL
   経由でしか読めない非公開設定のままなので、CORSを緩めても認可の範囲は
   広がらない(ブラウザJSが結果を読めるかどうかだけの話)
2. `chat_screen.dart`: 再生失敗時に必ず `debugPrint` でログを残すよう変更。
   自動再生の失敗(ブラウザの自動再生ポリシーでブロックされるケース)は
   従来通り無言だが、「音声を再生」ボタンでの手動再生が失敗した場合は
   SnackBarでエラーを表示するようにした(今後同種の問題が起きた際に
   気づけるように)

**検証**: 修正後、S3にCORS設定が反映されたことを`get-bucket-cors`で確認。
実際に新しい音声ファイルを生成し、ブラウザの`<audio crossorigin="anonymous">`
が送るのと同じ形のリクエスト(`Origin`ヘッダー付き、`Range`リクエスト込み)を
curlで再現したところ、`Access-Control-Allow-Origin: *` 等が正しく返り、
`206 Partial Content` でオーディオデータを取得できることを確認した。
ヘッドレスブラウザでの実再生確認は、このセッションのサンドボックス環境が
S3ドメインへの直接アクセスを許可していない制約により完走できなかった
(同じ制約は以前の動作確認時にも発生している。実機のブラウザは通常の
インターネット接続を使うため、この制約の影響を受けない)。

## 既知の制限: 日本語フォントがGoogle Fonts CDNに依存している

`--no-web-resources-cdn` はCanvasKit/Roboto本体には効くが、Flutter Webは
日本語などCJK文字のグリフを表示する際、Noto Sans SCなどのフォールバック
フォントを実行時に `fonts.gstatic.com` から動的取得する仕組みが別途動いている
(この会話アプリの主目的が日本語表示なので影響が大きい)。通常のインター
ネット環境なら問題なく取得できるが、Google Fonts CDNをブロックする
ネットワーク(一部の企業網、中国本土など)ではテキストが表示されない。

恒久対応するなら、日本語フォント(Noto Sans JPなど)をアプリのassetとして
同梱し `ThemeData(fontFamily: ...)` で明示指定して動的取得自体を発生させない
のが良い。Phase 1では未対応(現状のフォールバック取得で通常は動く)。

## 今後(モバイル版への展開時)

- `flutter create` の標準構成のため `flutter build ios` / `flutter build apk` は
  そのまま試せるはず(未検証)
- モバイルではシークレットのビルド埋め込みはさらにリスクが高い
  (アプリのバイナリを解析されると同様に漏れる)ため、上記の見直しは
  モバイル版に進む前に必須
- 「送信しただけでは自動再生されず、手動の『音声を再生』ボタンが必要」な
  現象(ブラウザの自動再生ポリシー)は**Web固有の制約**。ネイティブアプリ
  (iOS/Android)にはこの制約が無いため、モバイル版では送信だけで自動再生
  される想定(コード変更は不要、`audioplayers`はモバイルでも同じAPI)
