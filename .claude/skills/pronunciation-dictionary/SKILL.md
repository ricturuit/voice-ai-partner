---
name: pronunciation-dictionary
description: voice-ai-partnerの発音辞書(docs/pronunciation/)へ技術用語・キャラクター固有語の発音(reading)を安全に追加・修正・削除するスキル。taxonomy/registration_rules.md・taxonomy/pronunciation_rules.mdのルールに従って dictionary/<category>.yaml を編集し、npm run validate → npm run build まで一気通貫で行い、infra/lambda/conversation/pronunciation-lookup.json(本番Lambdaが実際に読み込むデータ)への反映を確認する。「発音辞書に◯◯を追加して」「◯◯の読みがおかしいので直して」「新しいAWSサービスを辞書に登録して」「この単語の発音を直して」といった依頼で使う。git commit/push や cdk deploy(実際のAWSへの反映)は本スキルの範囲外で、必ずユーザーに確認してから別途行う。
license: MIT
argument-hint: "[add|fix|remove] <対象語> [読み/カテゴリ等の詳細]"
---

# pronunciation-dictionary

音声会話AI「名取」の発音辞書(`docs/pronunciation/`)を更新するスキル。
辞書システム自体の設計・スキーマ・本番Lambdaとの接続方式は
`docs/pronunciation/README.md` に一元化されている。このスキルは
「ルールを毎回セッションの会話から思い出す」のではなく、それらの
ドキュメントを直接読みに行かせることで、どのセッションから呼んでも
同じ手順・同じ品質で辞書を更新できるようにするためのもの。

## 前提として必ず読むファイル

作業を始める前に、以下を(未読、または前回読んでから内容が変わって
いそうなら必ず)読むこと。ルールの実体をこのSKILL.mdに複製しない —
複製すると本体とスキルの内容がズレる(natori-japanaseスキルの
`references/character-natori.md` が抱える「手動同期が必要」という
弱点と同じ問題になるため、辞書ルールについては複製せず直接参照する)。

- `docs/pronunciation/README.md` — システム全体の構成・更新フロー・
  本番Lambdaとの接続方式
- `docs/pronunciation/taxonomy/registration_rules.md` — 登録ルール
  (id命名・必須6項目・重複チェックの仕組み)
- `docs/pronunciation/taxonomy/pronunciation_rules.md` — 発音表記ルール
  (readingの書き方、カテゴリ別の参考例テーブル)
- `docs/pronunciation/taxonomy/categories.yaml` / `tags.yaml` — 使用可能な
  カテゴリ・タグの一覧(存在しないものは`validate`がエラーにする)
- `docs/pronunciation/taxonomy/decision_log.md` — 過去に読みや分類で
  迷った判断の記録。対象語が既に登場していないか、まずここも確認する

## 手順

1. 上記のファイルを読み、ルールを把握する
2. 依頼内容に応じて対象カテゴリの `docs/pronunciation/dictionary/<category>.yaml`
   を編集する
   - **追加**: レコード形式は `id` / `term` / `reading` / `category` /
     `tags` / `aliases` の6項目のみ。他の項目は追加しない。カテゴリが
     どれにも当てはまらない場合は新規カテゴリを作らず `custom` を使うか、
     ユーザーに確認する
   - **修正**: 既存の `id` は変更しない(`generated/` を参照する側が
     `id` をキーにしている可能性があるため)
   - **削除**: 依頼が明確に「削除」の場合のみ行う。読みが違うだけなら
     `reading`/`aliases` の書き換えで足りることが多い
   - `reading` は平仮名・片仮名・長音記号のみ。スペース・記号・英数字・
     漢字は含めない(複数単語の読みでもスペースなしで1文字列にする)
   - 読みが複数ありうる語は `ambiguous_reading` タグを付け、
     `taxonomy/decision_log.md` に採用理由を追記する
   - ベンダー名を伴う正式名称(例: `Amazon Elastic Compute Cloud`)は、
     実際の会話では略称のみ発音される前提で、略称と同じreadingで
     `aliases` に含めてよい(例: `term: EC2` → `aliases: ["Amazon Elastic
     Compute Cloud"]`)。ただし略称自体の読みが展開形と異なる場合
     (例: `JS` と `JavaScript`)は別レコードとして登録する
   - 大文字小文字違い・ハイフン有無などの表記ゆれは同一レコード内で
     `aliases` に追加してよい(`validate` は自己衝突として誤検知しない)
   - 一般的な英単語と衝突しやすい語は、より安全な複合表記のみ登録する
     (`Spring` ではなく `Spring Boot`、`Rails` ではなく `Ruby on Rails`)
3. `cd docs/pronunciation && npm run validate` で整合性を確認する。
   エラーが出たら原因(id重複・term重複・reading文字種違反・ファイル名と
   categoryの不一致・未定義フィールド等)を直して再実行する
4. `npm run build` を実行する。これにより同時に更新される:
   - `docs/pronunciation/generated/dictionary.json` / `lookup.json`
     (git管理外、内容確認用)
   - `infra/lambda/conversation/pronunciation-lookup.json`(git管理下、
     本番Lambdaの `toTtsText()` が実際に読み込む実体)
5. `git diff infra/lambda/conversation/pronunciation-lookup.json` を見て、
   意図した語・読みだけが変わっていることを確認する
6. 変更内容(追加/修正/削除した語とその件数、迷って
   `decision_log.md` に書いた判断があればその要約)をユーザーに報告する

## やらないこと

- **`git commit` / `git push` / `cdk deploy` は自動では行わない。**
  辞書ファイルの編集とビルド(ローカルの作業ツリー変更)まではこの
  スキルの範囲だが、コミット・デプロイは呼び出し元セッションの通常の
  確認フローに従う。特に `cdk deploy` は稼働中のLambdaを実際に
  更新する操作なので、必ずユーザーに確認してから別途実行すること
  (`npm run build` しただけではデプロイ済みのLambdaには反映されない)
- `taxonomy/categories.yaml` / `tags.yaml` へのカテゴリ・タグの新規追加は、
  既存のもので対応できない場合のみ検討し、必ずユーザーに確認する
- `generated/` 配下や `infra/lambda/conversation/pronunciation-lookup.json`
  を手で直接編集しない(次の `npm run build` で上書きされるだけになる)

## 完了後の後片付け

作業用に一時ファイルを作った場合は完了後に削除する。
