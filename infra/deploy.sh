#!/usr/bin/env bash
# AWSインフラをTerraformで構築し、出力値を自動で worker/.env に書き込むスクリプト。
# 実行前に terraform.tfvars（bucket_suffix）を設定しておくこと。
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f terraform.tfvars ]; then
  echo "エラー: infra/terraform.tfvars がありません。"
  echo "  cp terraform.tfvars.example terraform.tfvars"
  echo "を実行し、bucket_suffix にAWSアカウントIDを設定してから再実行してください。"
  exit 1
fi

terraform init
terraform plan

echo ""
read -r -p "上記の内容でAWSにリソースを作成します。よろしいですか？ (yes と入力): " confirm
if [ "$confirm" != "yes" ]; then
  echo "中止しました。何も作成していません。"
  exit 1
fi

terraform apply -auto-approve

REGION=$(terraform output -raw aws_region)
BUCKET=$(terraform output -raw bucket_name)
QUEUE_URL=$(terraform output -raw job_queue_url)
ACCESS_KEY=$(terraform output -raw worker_access_key_id)
SECRET_KEY=$(terraform output -raw worker_secret_access_key)

ENV_FILE="../worker/.env"
cp ../worker/.env.example "$ENV_FILE"

sed -i \
  -e "s|^AWS_REGION=.*|AWS_REGION=${REGION}|" \
  -e "s|^AWS_ACCESS_KEY_ID=.*|AWS_ACCESS_KEY_ID=${ACCESS_KEY}|" \
  -e "s|^AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=${SECRET_KEY}|" \
  -e "s|^SQS_QUEUE_URL=.*|SQS_QUEUE_URL=${QUEUE_URL}|" \
  -e "s|^S3_BUCKET=.*|S3_BUCKET=${BUCKET}|" \
  "$ENV_FILE"

echo ""
echo "=================================================="
echo "AWSリソースの作成が完了し、worker/.env を自動生成しました。"
echo "残りの手動作業は1つだけです:"
echo "  worker/.env を開いて ANTHROPIC_API_KEY= の行に、あなたのClaude APIキーを入力してください。"
echo "=================================================="
