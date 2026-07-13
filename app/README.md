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

- テキスト入力欄 + マイクボタン + 送信ボタン(下部)、AppBar右上に無音判定
  時間の設定(2〜10秒、デフォルト2秒)
- マイクボタンをタップすると「会話モード」が始まり、音声入力(STT)を開始。
  認識結果はテキスト入力欄にリアルタイムで反映される。**無音が設定秒数
  続くと自動的に送信され、そのまま次の発話を待って聞き取りを継続する**
  (マイクをオンにしたまま連続で会話できる)。無音区間検知中は入力欄上に
  「送信まで: 3」のようなカウントダウンを表示し、話し出すとカウントは
  リセットされる
- マイクボタンをもう一度タップすると会話モードを終了。その時点で認識中の
  テキストがあればそれを送信してから停止する
- 送信ボタンは常に表示されたまま。テキストを直接入力して送信ボタンを押す
  従来の経路も引き続き利用可能(音声・テキストどちらからでも会話できる)
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

### 無音検知による自動送信(会話モード)

`speech_to_text`のWeb実装は`continuous: true`でSpeechRecognitionを開始する
(`partialResults`と連動)ため、**ブラウザ側は途中でどれだけ間が空いても
「発話終了」を自動検知してくれない**(`result.finalResult`が自然にtrueに
なることはなく、`.stop()`を呼んだ時に初めて最後の結果がfinalとして届く)。
そのため、無音検知はアプリ側で独自に実装している(`_restartSilenceCountdown`
/ `_handleSilenceTimeout`、`chat_screen.dart`):

- `onResult`が呼ばれるたび(部分結果・確定結果を問わず)に、`Timer`を
  設定した秒数(デフォルト2秒、AppBarのメニューで2〜10秒に変更可能)に
  リセットする
- 1秒ごとにカウントダウンし、画面に「送信まで: N」として表示。新しい
  認識結果が来ればその時点でリセットされる
- 0になったら`_speech.stop()`→(テキストがあれば)送信→会話モードが
  まだ有効なら`_speech.listen()`を再開、という流れでハンズフリーの
  連続会話を実現している。音声再生(TTS)が終わるまで待ってから聞き取りを
  再開するようにしており、AIの音声出力自体をマイクが拾ってしまう
  フィードバックループを避けている
- マイクボタンでの手動オフは、その時点の認識中テキストがあれば送信して
  から会話モードを終了する(次のターンの聞き取りは再開しない)

### 実機フィードバックを受けた追加調整(2026-07-13)

1. **返答待ち中に会話モードが解除され「音声入力を開始できませんでした」と
   出る件**: ターン間で聞き取りを再開する際(`_startListening(isAutoRestart:
   true)`)、ブラウザが直前の`.stop()`直後の`.start()`を一瞬拒否することが
   ある。再開時は400ms待ってから開始し、失敗したらさらに800ms待って
   もう一度だけ静かにリトライするようにした。自動再開の失敗はユーザー操作の
   結果ではないため、リトライも尽きた場合のみ会話モードを終了し、
   エラーのSnackBarは出さない(手動でマイクボタンを押して失敗した場合は
   従来通り表示する)。
2. **読み上げ完了後1秒は無音カウントを開始しない**: 聞き取りを再開した
   直後に、直前ターンの遅延した認識結果やAI自身の読み上げ音声が誤って
   マイクに拾われても即座にカウントダウンが始まらないよう、
   `_startListening`の呼び出しごとに1秒間のグレース期間
   (`_silenceGuardUntil`)を設け、`_restartSilenceCountdown`はその間は
   カウントダウンを開始しない(「音声を認識しています…」表示のみ)。
3. **合図音**: 控えめな「ポン」音を再生する(`assets/sounds/silence_cue.wav`、
   音量0.18、専用の`AudioPlayer`インスタンスで再生)。既存の著作権付き
   効果音(iOS標準の通知音など)は使わず、短い正弦波トーン(約220ms、880Hz、
   指数減衰エンベロープ)をこちらで新規に合成したものを同梱している。
   → 鳴らすタイミングは下記4で「無音検知時」から「マイクが話しかけ待ち
   状態になった瞬間」に変更している。

### 実機フィードバックを受けた追加調整・その2(2026-07-13)

4. **合図音のタイミングと意味を変更**: 当初は「無音を検知したタイミング」
   で鳴らしていたが、実機で試したところ「AIの回答文が確定したタイミング」
   で鳴ってしまい、読み上げ中に無音カウントが0になって未入力判定になる
   (詳細は次項5)のと、初回のマイク起動時には鳴らないという2つの問題が
   見つかった。使い手にとって「ポンが鳴ったら話してよい」という一貫した
   合図にしたいとのフィードバックを受け、**合図音は`_startListening`が
   実際に聞き取りを開始できた瞬間に鳴らす**方式に変更した。これにより
   初回のマイクタップ時にも、各ターン間の聞き取り再開時にも、同じ意味
   (「今話しかけてください」)で鳴るようになった。
5. **`AudioPlayer.play()`が再生完了ではなく再生開始で完了扱いになっていた
   件**: 合図音のタイミングがずれていた根本原因はこちら。
   `audioplayers`の`play()`が返す`Future`は**再生が始まった時点で完了して
   おり、読み上げが終わるまでは待ってくれない**。そのため
   `_handleSend()`内で返答音声の`_playAudio(...)`を`await`しても、実際には
   読み上げの数秒前(≒返答テキストが確定した直後)で処理が先に進んでしまい、
   聞き取りの再開(と、当時の実装での合図音)が読み上げの途中で始まって
   いた。`AudioPlayer.onPlayerComplete`ストリームを`play()`呼び出し前に
   購読し、実際の再生完了イベントを待つように修正(`onPlayerComplete`が
   何らかの理由で発火しない場合に備え30秒のタイムアウトも保険として設定)。
   これにより、聞き取りの再開(と合図音)は読み上げが本当に終わった後まで
   正しく遅延されるようになった。

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

## 修正済み: MissingPluginException(音声入力が`initialize`で失敗)(2026-07-13)

**症状**: 音声入力(マイクボタン)を使おうとすると
`MissingPluginException(No implementation found for method initialize on
channel plugin.csdcorp.com/speech_to_text)` が発生していた。

**原因**: `.dart_tool/flutter_build/` 配下のインクリメンタルビルドキャッシュが
不整合を起こしていた。`web_plugin_registrant.dart`(Web版プラグイン登録用の
自動生成ファイル)のソース自体は`SpeechToTextPlugin.registerWith(registrar)`
を正しく含んでいたが、実際にビルドされた`main.dart.js`には
`webkitSpeechRecognition`関連のコードが含まれておらず、代わりにデフォルトの
MethodChannel実装(ネイティブアプリ向けの、存在しないチャンネルにメッセージを
送ろうとする実装)だけが残っていた。`speech_to_text`パッケージを追加した後、
一度も`flutter clean`せずに複数回ビルドを重ねたことで、古いビルド成果物が
一部再利用されてしまったことが原因と考えられる。

**対応**: `flutter clean` → `flutter pub get` → クリーンな状態で
`flutter build web --release --no-web-resources-cdn --dart-define=...` を
再実行。ビルド後の`main.dart.js`に`webkitSpeechRecognition`
(2箇所)・`SpeechRecognitionError`・`SpeechRecognitionResult` が含まれる
ことを確認してからデプロイ・CloudFrontキャッシュ無効化を実施。

`web/index.html`(`flutter_bootstrap.js`の読み込み等)は元々標準のまま
正しく、修正不要だった。

## 修正済み: 送信後ロード表示が終わらず入力欄が固まる不具合(2026-07-13)

**症状**(実機報告): テキストを送信すると返答テキストは表示されるが、
音声が再生されないまま送信中のロード表示が終わらず、以降テキスト入力欄が
無効化されたまま操作できなくなる。

**原因**: `_handleSend()`内で、返答音声の自動再生(`_playAudio(...)`の
`await`)が`_isSending`を`false`に戻す`finally`ブロックより**前**、かつ
同じ`try`ブロック内にあった。一部のブラウザでは自動再生がブロックされた際、
`audioplayers`が使う`<audio>`要素の`play()`(内部的にWeb Audio APIの
`AudioContext.resume()`を経由)が**例外を投げずに永遠に保留されたまま
(pending)になる**ケースがあり、この場合`await`が完了しないため
`finally`にも到達できず、`_isSending`が`true`のまま固定される。
`TextField`・送信ボタンとも`enabled: !_isSending`相当の条件で無効化して
いたため、結果的に入力できなくなっていた。

**対応**:
1. 音声の自動再生を`_isSending`の管理対象から完全に分離。API応答を受け
   取った時点(`finally`)で`_isSending`を`false`に戻し、**その後で**
   音声再生を試みるように順序を変更(送信・入力の可否が音声再生の成否に
   左右されなくなった)
2. `_playAudio()`に`.timeout(Duration(seconds: 10))`を追加。ブラウザ側の
   挙動に関わらず、再生試行が10秒以内に必ず完了(失敗含む)するように
   した(手動の「音声を再生」ボタンでも同様に保護される)

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
