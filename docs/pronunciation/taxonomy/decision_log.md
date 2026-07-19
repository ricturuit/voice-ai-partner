# 決定ログ

用語の読み方や分類について、自明ではない判断をしたときの記録。
新しいレコードが `pronunciation_rules.md` の優先順位3(暫定採用)に
該当する場合や、分類に迷った場合は、ここに追記すること。
古い記録も削除せず、時系列で残す。

---

## 2026-07-19: 辞書管理システムの新設と初期データの移行元

`infra/lambda/conversation/index.js` にハードコードされていた
`TTS_PRONUNCIATION_OVERRIDES`(AWS/S3/EC2/API/URL/SDK/CDK/HTTPS/HTTP/JSON/CLI
の11件と、キャラクター名取の「せんせえ」の読み替え)を、本辞書管理
システムの初期データとして移行した。

移行時の判断:

- 上記11件の技術用語は、それぞれ最も近いカテゴリ
  (`aws` / `programming` / `web` / `networking` / `dev_tools`)へ振り分けた。
  1文字ずつ読む頭字語読みは元の実装をそのまま踏襲している。
- 「せんせえ → せんせい」は技術用語ではなく、キャラクター「名取」の
  台詞に固有の読み替えであるため、`custom` カテゴリに `app_specific`
  タグを付けて登録した。将来的に他のアプリ固有の言い回しが増えた場合も
  同様に `custom` + `app_specific` に集約する方針とする。
- `CDK` は文脈上ほぼ常に「AWS CDK」を指すため、`aws` カテゴリに分類した
  (`id: aws-cdk`)。

## 2026-07-19: 初版データはサンプルのみ

本ラウンドでは辞書管理の仕組み(taxonomy / dictionary / validate / build /
generated)の実装のみを行い、包括的な初版辞書の作成は別途 ChatGPT 側で
行う想定。上記の移行データ11件+1件は「動作確認用のサンプル」を兼ねた
実データであり、本番の `infra/lambda/conversation/index.js` への
再接続(`generated/` の読み込みへの切り替え)は本ラウンドでは実施していない。
