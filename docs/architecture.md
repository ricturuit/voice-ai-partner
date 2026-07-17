# voice-dataset-builder アーキテクチャ

音声クローン学習データセット生成システム。既存の音声会話AIとはAWSリソース・IAM・命名規則を一切共有しない、完全独立のシステムとして構築する。

## 前提・確認済み事項

- 既存システムと**同一AWSアカウント内**で、命名・IAM・タグにより論理的に完全分離する
- リージョン: `ap-northeast-1`
- S3は単一バケット＋用途別プレフィックス（`upload/` `output/` `archive/` `error/`）方式
- 命名プレフィックスは `voice-dataset-` に統一。`voice-chat` / `cotomo` / `assistant` 等の語は使用しない
- Whisper（faster-whisper, smallモデル, CPU）・ffmpeg・Claude APIはローカルPC常駐Workerで実行し、AWS上では実行しない
- Secrets Manager / Parameter Store は使用しない。AWS認証情報・Claude APIキーはローカル `.env` で管理する

## データフロー

```
音源ファイル
  → S3 upload/                        (手動/スクリプトでアップロード)
  → S3 ObjectCreated イベント
  → Lambda (voice-dataset-s3-to-sqs)  ジョブJSONをSQSへ送るだけ。Whisper等は実行しない
  → SQS (voice-dataset-job-queue)
  → ローカルWorker (常時起動)
      1. SQSをロングポーリング
      2. S3 upload/ から音源をダウンロード
      3. ffprobeでソース音質チェック（ビットレート/サンプルレートが閾値未満ならerror/へ）
      4. faster-whisper (small, CPU) で文字起こし（no_speech_probも取得）
      5. 文字起こしテキスト（無音/笑い声の注記付き）のみをClaude APIへ送信し、話題境界(30秒〜3分、文の途中で切らない)をJSONで取得
      6. no_speech_prob・笑い声比率が閾値を超える候補区間は採用せず除外
      7. ffmpegでJSON区間ごとにloudnorm（音量正規化）しつつwav切り出し (001.wav, 002.wav, ...)
      8. clips.csv / report.md（採用区間・除外区間と理由）を生成
  → 成果物をS3 output/{job_id}/ へアップロード
  → 成功: 原本を upload/ → archive/ へ移動、SQSメッセージ削除
  → 失敗: 原本を upload/ → error/ へ移動、SQSメッセージ削除（無限リトライ防止。DLQは別途上限到達時のみ）
```

## 命名規則

| 種別 | 命名パターン |
|---|---|
| S3バケット | `voice-dataset-<AWSアカウントID>` |
| S3プレフィックス | `upload/` `output/` `archive/` `error/` |
| SQSキュー | `voice-dataset-job-queue` |
| SQS DLQ | `voice-dataset-job-dlq` |
| Lambda関数 | `voice-dataset-s3-to-sqs` |
| IAMロール | `voice-dataset-lambda-role` |
| IAMユーザー | `voice-dataset-worker-user` |
| CloudWatchロググループ | `/aws/lambda/voice-dataset-s3-to-sqs` |
| 共通タグ | `Project=voice-dataset` / `ManagedBy=terraform` |

## IAM設計（2主体のみ、最小権限）

- **`voice-dataset-lambda-role`**: `upload/*` の `s3:GetObject`、ジョブキューへの `sqs:SendMessage`、自身のロググループへの書き込みのみ。
- **`voice-dataset-worker-user`**: ジョブキューの受信・削除、`upload/*` の読み取り、`output/* archive/* error/*` への書き込み、`upload/*` の削除（move実装のため）のみ。

いずれも既存システムのIAMロール・ポリシーとは無関係の新規リソース。

## 音質ゲート（ベストエフォート）

話者は1名確定という前提のもと、以下をWorkerに実装している。いずれも「明らかに使えない音源・区間を機械的に弾く」ためのものであり、非可逆圧縮による音質劣化そのものを復元・保証するものではない。

- **ソース音質チェック** (`worker/quality.py: check_source_quality`): ffprobeでビットレート・サンプルレートを確認し、`MIN_BITRATE_KBPS`（既定96kbps）/ `MIN_SAMPLE_RATE_HZ`（既定32000Hz）を下回る音源は文字起こし前に`error/`へ振り分ける。
- **ラウドネス正規化** (`worker/cutter.py`): クリップ切り出し時にffmpegの`loudnorm`（I=-16 LUFS, TP=-1.5dBTP, LRA=11）を適用し、クリップ間の音量ばらつきを揃える。
- **無音/雑音・笑い声区間の除外** (`worker/quality.py: evaluate_clip`): faster-whisperの`no_speech_prob`が閾値（既定0.5）を超える区間、および文字起こしテキストが笑い声パターン（正規表現、日英の代表的な表現のみ）に閾値以上（既定30%）一致する区間は採用せず、`report.md`の「除外区間と理由」に記録する。Claudeへ渡す文字起こしにも`[NOISE]`/`[LAUGH]`の注記を付け、区間選定時点でも避けるよう指示している。
- 笑い声検知は正規表現ベースのため、明示的にテキスト化されない笑い声（Whisperが無視・誤変換した場合）は検知できないことがある。取りこぼしがあり得るベストエフォートの仕組みである。

## SQSメッセージスキーマ

```json
{
  "job_id": "b3f1...-uuid",
  "bucket": "voice-dataset-123456789012",
  "key": "upload/rec-20260717-001.wav",
  "uploaded_at": "2026-07-17T09:12:00Z"
}
```

音声本体・文字起こしテキストはSQSに載せない（S3参照のみ）。

## コスト目安

Whisper/ffmpeg/Claude APIをローカルへ逃がしているため、AWS側はS3・SQS・Lambda・CloudWatch Logsのみで、月200円程度の想定（要件: 月1,000円未満）。

## ディレクトリ構成

```
voice-dataset-builder/
├── infra/          Terraform一式 (S3/SQS/Lambda/IAM)
├── lambda/         S3イベント→SQS投入Lambda
├── worker/         ローカル常駐Worker (Python)
└── docs/           本ドキュメント
```

## デプロイ手順（お客様側の環境で実行）

このリポジトリのセッションにはAWS認証情報がないため、`terraform apply` はAWS認証情報を持つご自身のPC/CIで実行してください。

```sh
cd infra
cp terraform.tfvars.example terraform.tfvars   # bucket_suffixを設定
terraform init
terraform plan   # 内容を確認
terraform apply
terraform output worker_access_key_id
terraform output -raw worker_secret_access_key
```

```sh
cd worker
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # terraform outputの値・ANTHROPIC_API_KEYを設定
python main.py
```

## 実装スケジュール（MVP）

1. 設計承認（完了）
2. Terraform基盤（本コミットで完了）
3. Lambda実装（本コミットで完了）
4. Workerスケルトン（本コミットで完了。SQS/S3配線＋Whisper/Claude/ffmpeg統合まで一括実装済み）
5. 実音源での通し確認（お客様環境での `terraform apply` ＋ Worker起動後に実施）
