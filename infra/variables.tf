variable "aws_region" {
  description = "既存の音声会話AIとは無関係の、本プロジェクト専用リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "全リソース共通の命名プレフィックス"
  type        = string
  default     = "voice-dataset"
}

variable "bucket_suffix" {
  description = "S3バケット名をグローバルに一意にするためのサフィックス（例: AWSアカウントID）"
  type        = string
}

variable "archive_transition_days" {
  description = "archive/ 配下のオブジェクトをGlacier Instant Retrievalへ移行するまでの日数"
  type        = number
  default     = 90
}

variable "error_expiration_days" {
  description = "error/ 配下のオブジェクトを自動削除するまでの日数"
  type        = number
  default     = 30
}

variable "sqs_visibility_timeout_seconds" {
  description = "SQS可視性タイムアウト。Whisper文字起こし+Claude API+ffmpegの合計処理時間より長く設定する"
  type        = number
  default     = 1800
}

variable "sqs_max_receive_count" {
  description = "DLQへ移動するまでの最大受信回数"
  type        = number
  default     = 3
}

variable "log_retention_days" {
  description = "Lambda用CloudWatch Logsの保持日数"
  type        = number
  default     = 14
}
