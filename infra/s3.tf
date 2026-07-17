resource "aws_s3_bucket" "dataset" {
  bucket = "${var.project_name}-${var.bucket_suffix}"
}

resource "aws_s3_bucket_public_access_block" "dataset" {
  bucket = aws_s3_bucket.dataset.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "dataset" {
  bucket = aws_s3_bucket.dataset.id

  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "dataset" {
  bucket = aws_s3_bucket.dataset.id

  rule {
    id     = "archive-to-glacier"
    status = "Enabled"

    filter {
      prefix = "archive/"
    }

    transition {
      days          = var.archive_transition_days
      storage_class = "GLACIER_IR"
    }
  }

  rule {
    id     = "expire-error"
    status = "Enabled"

    filter {
      prefix = "error/"
    }

    expiration {
      days = var.error_expiration_days
    }
  }
}

# upload/ output/ archive/ error/ を可視化するための空プレフィックスオブジェクト
resource "aws_s3_object" "prefixes" {
  for_each = toset(["upload/", "output/", "archive/", "error/"])

  bucket  = aws_s3_bucket.dataset.id
  key     = each.value
  content = ""
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_to_sqs.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.dataset.arn
}

resource "aws_s3_bucket_notification" "dataset" {
  bucket = aws_s3_bucket.dataset.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.s3_to_sqs.arn
    events               = ["s3:ObjectCreated:*"]
    filter_prefix        = "upload/"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}
