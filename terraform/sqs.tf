resource "aws_sqs_queue" "orders_dlq" {
  name                              = "${local.name}-orders-dlq"
  message_retention_seconds         = 1209600 # 14 days, the SQS maximum
  kms_master_key_id                 = aws_kms_key.main.arn
  kms_data_key_reuse_period_seconds = 300
}

resource "aws_sqs_queue" "orders" {
  name                              = "${local.name}-orders"
  visibility_timeout_seconds        = var.lambda_timeout_seconds * 6
  message_retention_seconds         = 345600 # 4 days
  receive_wait_time_seconds         = 20     # long polling
  kms_master_key_id                 = aws_kms_key.main.arn
  kms_data_key_reuse_period_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.orders_dlq.arn
    maxReceiveCount     = var.sqs_max_receive_count
  })
}

# Only the main queue may redrive into the DLQ.
resource "aws_sqs_queue_redrive_allow_policy" "orders_dlq" {
  queue_url = aws_sqs_queue.orders_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.orders.arn]
  })
}

# Encryption in transit: reject any request not made over TLS.
data "aws_iam_policy_document" "sqs_tls_only" {
  for_each = {
    orders     = aws_sqs_queue.orders.arn
    orders_dlq = aws_sqs_queue.orders_dlq.arn
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [each.value]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "orders" {
  queue_url = aws_sqs_queue.orders.id
  policy    = data.aws_iam_policy_document.sqs_tls_only["orders"].json
}

resource "aws_sqs_queue_policy" "orders_dlq" {
  queue_url = aws_sqs_queue.orders_dlq.id
  policy    = data.aws_iam_policy_document.sqs_tls_only["orders_dlq"].json
}
