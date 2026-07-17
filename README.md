# voice-dataset-builder

音声クローン学習データセット生成システム。既存の音声会話AI（AWS上）とはIAM・Lambda・S3・CloudWatch・Secrets Manager・Parameter Store・CDK/CloudFormation・Docker・環境変数を一切共有しない、完全独立のシステムです。

- 詳細設計: [docs/architecture.md](docs/architecture.md)
- インフラ（Terraform）: [infra/](infra/)
- S3イベント→SQS投入Lambda: [lambda/s3_to_sqs/](lambda/s3_to_sqs/)
- ローカル常駐Worker（Whisper / Claude API / ffmpeg）: [worker/](worker/)

## セットアップ

```sh
cd infra
cp terraform.tfvars.example terraform.tfvars   # bucket_suffix にAWSアカウントID等を設定
terraform init
terraform plan
terraform apply
```

```sh
cd worker
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # terraform outputの値とANTHROPIC_API_KEYを設定
python main.py
```

音源を S3 の `upload/` プレフィックスへアップロードすると、自動で文字起こし→話題区間分割→wav切り出しが行われ、`output/{job_id}/` へ `001.wav, 002.wav, ..., clips.csv, report.md` が保存されます。