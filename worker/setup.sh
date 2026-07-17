#!/usr/bin/env bash
# Worker実行環境（Python仮想環境・依存パッケージ）を準備するスクリプト。
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "エラー: ffmpeg が見つかりません。先にインストールしてください。"
  echo "  sudo apt update && sudo apt install -y ffmpeg"
  exit 1
fi

python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

echo ""
if [ ! -f .env ]; then
  echo "注意: worker/.env がまだありません。"
  echo "先に infra/deploy.sh を実行して自動生成するか、.env.example をコピーして手動設定してください。"
else
  echo "セットアップ完了。"
fi
echo "Workerの起動:"
echo "  source .venv/bin/activate"
echo "  python main.py"
