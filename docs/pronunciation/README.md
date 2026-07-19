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
│   ├── aws.yaml
│   ├── programming.yaml
│   ├── web.yaml
│   ├── networking.yaml
│   ├── dev_tools.yaml
│   └── custom.yaml
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

## レコードのスキーマ

1レコードは次の6項目のみを持つ(それ以外のフィールドは `validate` が
エラーにする)。

```yaml
- id: aws              # 辞書全体でユニークな識別子(ケバブケース)
  term: AWS             # 見出し語(本文中でマッチさせたい表記)
  reading: エーダブリューエス   # 読み(平仮名・片仮名・長音記号のみ)
  category: aws          # taxonomy/categories.yaml に存在するカテゴリid
  tags: [acronym, brand_name]   # taxonomy/tags.yaml に存在するタグidの配列
  aliases: ["Amazon Web Services"]   # term と同じ読みをさせたい別表記
```

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

初版の網羅的な辞書はChatGPT側で別途作成される想定のため、今回は
`infra/lambda/conversation/index.js` に元々ハードコードされていた
発音矯正リスト(AWS/S3/EC2/CDK/API/SDK/URL/HTTP/HTTPS/JSON/CLI/せんせえ)
を本システムへ移行し、動作確認用のサンプルデータを兼ねている。
`index.js` 側を `generated/lookup.json` の読み込みに切り替える対応は、
今回のスコープ(辞書管理システムの実装)には含めていない。次のフェーズで
本格的な辞書データが揃った段階で改めて対応する。
