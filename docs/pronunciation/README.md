# 発音辞書管理システム

音声会話AI「名取」で使う技術用語・固有名詞の発音(読み方)を一元管理する
仕組み。特定のTTSサービスに依存せず、将来的に複数の音声合成サービスへの
出力に対応できることを前提としている。

## 目的

- 専門用語の読み間違いを防ぐ
- 用語を一元管理する
- AI(Claude Code等)が自動更新できる運用にする

## ディレクトリ構成

```
docs/pronunciation/
├── README.md              このファイル
├── package.json           validate/build スクリプトの依存関係(js-yaml)
├── taxonomy/               分類・ルールの定義(手動編集)
│   ├── categories.yaml     カテゴリ一覧
│   ├── tags.yaml           タグ一覧
│   ├── registration_rules.md   登録ルール(id命名・必須項目・更新フロー)
│   ├── pronunciation_rules.md  発音表記ルール(かな表記の書き方)
│   └── decision_log.md     読み方・分類で迷った判断の記録
├── dictionary/             辞書本体(唯一のマスターデータ、手動編集)
│   └── <category_id>.yaml   カテゴリごとに1ファイル(taxonomy/categories.yaml と1対1対応)
│   (該当データがまだ無いカテゴリのファイルは未作成。
│    最初の用語を追加する時点でファイルごと新規作成する)
├── generated/               build による自動生成専用(手動編集禁止・git管理外)
│   ├── dictionary.json      全レコードを統合した構造化データ
│   └── lookup.json          term/alias → reading のフラットなマップ
└── scripts/
    ├── lib/dictionary.js    taxonomy/dictionary の読み込み・検証ロジック(共通)
    ├── validate.js          スキーマ・整合性チェック
    └── build.js              validate → generated/ の再生成
```

## セットアップ

```sh
cd docs/pronunciation
npm install
```

## 使い方

```sh
npm run validate   # taxonomy/dictionary の整合性チェックのみ
npm run build       # validate を内部で実行したうえで generated/ を再生成
```

`generated/` はビルド成果物なので git 管理していない(`.gitignore` 参照)。
このディレクトリを利用する側(将来のTTS連携コード)は、デプロイ・ビルドの
前段で `npm run build` を実行して最新の `generated/*.json` を用意すること。

## 更新フロー

```
taxonomy → dictionary → validate → build → generated
```

1. 必要なら `taxonomy/categories.yaml` / `taxonomy/tags.yaml` を更新
2. `dictionary/<category>.yaml` に用語を追加・編集
3. `npm run validate` で整合性を確認
4. `npm run build` で `generated/` を再生成
5. `generated/*.json` を見て意図した読みになっているか確認

詳細な登録ルールは `taxonomy/registration_rules.md`、
かな表記の書き方は `taxonomy/pronunciation_rules.md` を参照。

## レコードのスキーマ(現段階)

1レコードは次の6項目のみを持つ(それ以外のフィールドは `validate` が
エラーにする)。これは「用語の正規化(正しい読みへの変換)」のみを
スコープとする現段階の設計であり、将来的な拡張については
「将来の発音レイヤー拡張方針」を参照。

```yaml
- id: aws              # 辞書全体でユニークな識別子(ケバブケース)
  term: AWS             # 見出し語(本文中でマッチさせたい表記)
  reading: エーダブリューエス   # 読み(平仮名・片仮名・長音記号のみ)
  category: aws          # taxonomy/categories.yaml に存在するカテゴリid
  tags: [acronym, brand_name]   # taxonomy/tags.yaml に存在するタグidの配列
  aliases: ["Amazon Web Services"]   # term と同じ読みをさせたい別表記
```

### `reading` の役割(スコープの限定)

`reading` は次の役割のみに限定する。アクセント位置・高低・韻律等の
情報は含めない(`taxonomy/pronunciation_rules.md` の文字種制限
(平仮名・片仮名・長音記号のみ)がこれを構造的に担保している)。

- 正しい読みへ正規化する
- 英字を自然な日本語読みへ変換する
- 略語を適切に読む
- 音声エンジンへ入力できるカタカナ表記を提供する

`reading` は常に不透明な文字列として扱われ(`toTtsText()` 等の消費側は
単純な文字列置換のみを行う)、パース(解析)されることを前提にしない。
アクセント・韻律情報を持たせたくなった場合は、`reading` を拡張するの
ではなく、以下の「将来の発音レイヤー拡張方針」に従って別フィールドを
追加する。

## 将来の発音レイヤー拡張方針

現在のマスタは「技術用語の正規化(正しい読みへの変換)」のみを
スコープとしている。将来的には音声合成品質を高めるため、アクセント・
韻律・ポーズ・TTSエンジン固有設定を管理できるよう拡張する想定であり、
今回の実装(taxonomy / dictionary / validate / build / generated)は
その拡張を妨げない設計にしている。

### 想定する処理レイヤー

```
term
  ↓
reading       (正規化された日本語読み。現段階の管理対象)
  ↓
pronunciation (アクセント・韻律・ポーズ等。将来追加予定・未実装)
  ↓
TTS Engine    (ElevenLabs / OpenAI / Azure / Amazon Polly 等)
```

### 現段階で管理する項目

`id` / `term` / `reading` / `category` / `tags` / `aliases` の6項目のみ。
これ以外のフィールドは追加しない(`validate` がエラーにする)。

### 将来追加を想定する項目(今回は未実装)

以下はあくまで設計上の想定であり、今回のタスクでは実装しない。

```yaml
pronunciation:
  accent:
  prosody:
  pause:
  stress:
  tts:
```

のようなフラットな追加、あるいは

```yaml
speech:
  accent:
  prosody:
  pause:
```

のようなネスト構造も採用候補として残す。実装時にどちらが
`dictionary.js` の読み込み・検証ロジックと相性が良いかを検討する。

### 拡張時に壊さないための設計上の配慮

- `reading` にはアクセント情報を埋め込まない(文字種を平仮名・片仮名・
  長音記号のみに制限しているのはこのため。`taxonomy/pronunciation_rules.md`
  参照)。
- `reading` を解析(パース)前提の値として扱わない。消費側
  (`toTtsText()` 等)は常に不透明な文字列として単純置換するのみ。
- `RECORD_FIELDS`(`scripts/lib/dictionary.js`)は単純な配列で
  フィールド許可リストを管理している。将来 `pronunciation` 等を
  追加する際は、この配列にフィールド名を足すだけで対応でき、
  既存レコード(6項目のみ)は `pronunciation` 等を省略した状態
  (未設定 = 現行のreadingベースの読み上げにフォールバック)のまま
  互換性を保てる。
- バリデーションは「定義済みフィールド以外を許可しない」方式
  (許可リスト方式)を採用しているため、将来新しい項目を追加する際は
  `RECORD_FIELDS` とそれぞれのフィールド用のチェックを追加するだけで
  済み、既存のチェックロジックを壊さない。

## 設計上の判断

### なぜ Node.js で実装したか

`docs/` はドキュメント色の強い置き場だが、本システムの実利用先は
`infra/lambda/conversation/index.js`(Node.js製Lambda)であり、
リポジトリの実行時スタックはNode.js(infra) + Dart/Flutter(app)で
Pythonは `.claude/skills/` 内のツール用スクリプトに限られる。将来この
`generated/` を実際にLambdaへ組み込む際の言語的な段差をなくすため、
YAMLパーサに `js-yaml` を使ったNode.jsスクリプトとして実装した。
`docs/pronunciation/` 配下に専用の `package.json` を置き、`infra/` の
依存関係とは独立させている(デプロイパイプラインに巻き込まないため)。

### なぜ `generated/` を2ファイルに分けたか

- `dictionary.json`: `id`/`category`/`tags` を含む完全な構造化データ。
  将来、TTSサービスごとに異なる変換(IPA化、SSML化等)が必要になった
  場合の入力として使う。
- `lookup.json`: `term`/`alias` → `reading` のフラットな辞書引きマップ。
  現在 `infra/lambda/conversation/index.js` にある `toTtsText()`(単純な
  文字列置換によるTTS向けテキスト変換)がそのまま消費できる形。

どちらもTTSサービス固有の形式(例: ElevenLabsの発音記法)には依存させて
いない。プロバイダごとの変換が必要になった時点で、これらを入力とする
アダプタ層を別途追加する想定。

### なぜ「せんせえ」を含めたか

`term`/`reading` の読み替えという性質は技術用語もキャラクター固有の
言い回しも同じであり、読み替えの仕組みを2箇所に分散させると
「一元管理する」という目的に反する。指定されたカテゴリ一覧には
キャラクター設定向けの分類が無かったため、`custom` カテゴリに
`app_specific` タグを付けて集約する方針にした(`taxonomy/decision_log.md`
参照)。

### 初版データについて

初版はサンプルデータとして、`infra/lambda/conversation/index.js` に元々
ハードコードされていた発音矯正リスト(AWS/S3/EC2/CDK/API/SDK/URL/
HTTP/HTTPS/JSON/CLI/せんせえ)を本システムへ移行したのみだった。

その後の「技術用語マスタ作成タスク」で、`custom` を除く全カテゴリの
ダミーデータを実用データへ置き換えた(詳細は
`taxonomy/decision_log.md` の該当エントリを参照)。

`index.js` 側を `generated/lookup.json` の読み込みに切り替える対応は
まだ実施していない。切り替え時は、`toTtsText()` が非英数字termを
正規表現として無加工で使う実装になっている点に注意すること
(`taxonomy/decision_log.md` 参照)。
