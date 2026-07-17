# --- Lambda実行ロール（S3イベントをSQSへ中継するだけの権限のみ） ---

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.project_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_permissions" {
  statement {
    sid       = "ReadUploadObjects"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.dataset.arn}/upload/*"]
  }

  statement {
    sid       = "SendJobMessage"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.job_queue.arn]
  }

  statement {
    sid = "WriteOwnLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.s3_to_sqs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${var.project_name}-lambda-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

# --- ローカルWorker用IAMユーザー（ジョブ取得・成果物アップロード・原本移動のみ） ---

resource "aws_iam_user" "worker" {
  name = "${var.project_name}-worker-user"
}

data "aws_iam_policy_document" "worker_permissions" {
  statement {
    sid = "ReceiveJobs"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.job_queue.arn]
  }

  statement {
    sid       = "ReadUpload"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.dataset.arn}/upload/*"]
  }

  statement {
    sid     = "WriteOutputArchiveError"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.dataset.arn}/output/*",
      "${aws_s3_bucket.dataset.arn}/archive/*",
      "${aws_s3_bucket.dataset.arn}/error/*",
    ]
  }

  statement {
    sid       = "DeleteAfterMove"
    actions   = ["s3:DeleteObject"]
    resources = ["${aws_s3_bucket.dataset.arn}/upload/*"]
  }
}

resource "aws_iam_user_policy" "worker" {
  name   = "${var.project_name}-worker-policy"
  user   = aws_iam_user.worker.name
  policy = data.aws_iam_policy_document.worker_permissions.json
}

resource "aws_iam_access_key" "worker" {
  user = aws_iam_user.worker.name
}
