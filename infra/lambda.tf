data "archive_file" "s3_to_sqs" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/s3_to_sqs"
  output_path = "${path.module}/build/s3_to_sqs.zip"
  excludes    = ["requirements.txt"]
}

resource "aws_cloudwatch_log_group" "s3_to_sqs" {
  name              = "/aws/lambda/${var.project_name}-s3-to-sqs"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "s3_to_sqs" {
  function_name    = "${var.project_name}-s3-to-sqs"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.s3_to_sqs.output_path
  source_code_hash = data.archive_file.s3_to_sqs.output_base64sha256

  environment {
    variables = {
      JOB_QUEUE_URL = aws_sqs_queue.job_queue.id
    }
  }

  depends_on = [aws_cloudwatch_log_group.s3_to_sqs]
}
