resource "aws_sqs_queue" "job_dlq" {
  name                      = "${var.project_name}-job-dlq"
  message_retention_seconds = 1209600 # 14日
}

resource "aws_sqs_queue" "job_queue" {
  name                       = "${var.project_name}-job-queue"
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  message_retention_seconds  = 345600 # 4日

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.job_dlq.arn
    maxReceiveCount     = var.sqs_max_receive_count
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "job_dlq" {
  queue_url = aws_sqs_queue.job_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.job_queue.arn]
  })
}
