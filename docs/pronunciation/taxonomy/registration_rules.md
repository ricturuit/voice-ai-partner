# 登録ルール

`dictionary/` に用語を追加・更新する際の運用ルール。

## 1. どこに書くか

- カテゴリごとに `dictionary/<category_id>.yaml` へ追加する。
  `category_id` は `taxonomy/categories.yaml` に定義されたものと1対1で対応する
  ファイル名(拡張子を除く)と一致させること。
- 1ファイル内のレコードは必ず同じ `category` を持つ。ファイルをまたいで
  カテゴリを混在させない(`validate` がファイル名とレコードの `category` の
  不一致をエラーにする)。
- 分類に迷う場合、あるいはどのカテゴリにも当てはまらない一時的な語は
  `dictionary/custom.yaml`(`category: custom`)に置く。

## 2. id の付け方

- 半角英小文字・数字・ハイフンのみ。スネークケースではなくケバブケースを使う
  (例: `aws-cdk`、`ec2`)。
- 辞書全体でユニークであること(カテゴリをまたいでも重複不可)。
- 用語そのものが変わらない限り、一度付けた `id` は変更しない
  (`generated/` を参照する側が `id` をキーにしている可能性があるため)。

## 3. 必須フィールドと最小構成

1レコードは以下の6項目のみを持つ。これ以外のフィールドは追加しない。

| フィールド | 必須 | 説明 |
|---|---|---|
| `id` | ✅ | 辞書全体でユニークな識別子 |
| `term` | ✅ | 見出し語(本文中でマッチさせたい表記) |
| `reading` | ✅ | 読み(`pronunciation_rules.md` の表記ルールに従う) |
| `category` | ✅ | `taxonomy/categories.yaml` に存在するカテゴリid |
| `tags` | — | `taxonomy/tags.yaml` に存在するタグidの配列。省略時は空配列 |
| `aliases` | — | `term` と同じ読みをさせたい別表記の配列。省略時は空配列 |

補足やメモを残したい場合は、レコードにフィールドを増やすのではなく
`decision_log.md` に追記する(データと経緯を分離する)。

## 4. 重複・衝突のチェック

`validate` は以下を検出してエラーにする。

- `id` の重複
- `term` の重複(大文字小文字を区別しない)
- 他レコードの `term`/`aliases` と衝突する `alias`
- 存在しない `category`/`tags` の参照
- ファイル名と `category` の不一致
- 定義済み6フィールド以外のキーが存在するレコード

同じ表記が複数の読み方を持ちうる場合(`ambiguous_reading` タグの対象)は、
どちらか一方に統一するか、あるいはより限定的な `term`(例: 前後の文脈込みの
表記)に分けて登録する。どちらを選んだかは `decision_log.md` に理由を残す。

## 5. 更新フロー

新規追加・変更は必ず次の順序で行う。

1. 必要なら `taxonomy/categories.yaml` / `taxonomy/tags.yaml` を更新
2. `dictionary/<category>.yaml` にレコードを追加・編集
3. `npm run validate` でスキーマ・整合性チェック
4. `npm run build` で `generated/` を再生成
5. 生成された `generated/*.json` を確認(意図した読みになっているか)

`generated/` を直接編集しない。次回の `build` で上書きされる。
