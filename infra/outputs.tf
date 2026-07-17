output "bucket_name" {
  description = "voice-dataset用S3バケット名"
  value       = aws_s3_bucket.dataset.bucket
}

output "job_queue_url" {
  description = "Workerが受信するSQSキューURL"
  value       = aws_sqs_queue.job_queue.id
}

output "job_dlq_url" {
  description = "DLQのURL"
  value       = aws_sqs_queue.job_dlq.id
}

output "worker_access_key_id" {
  description = "worker/.env の AWS_ACCESS_KEY_ID に設定する値"
  value       = aws_iam_access_key.worker.id
}

output "worker_secret_access_key" {
  description = "worker/.env の AWS_SECRET_ACCESS_KEY に設定する値"
  value       = aws_iam_access_key.worker.secret
  sensitive   = true
}
