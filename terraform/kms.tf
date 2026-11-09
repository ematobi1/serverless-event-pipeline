# One customer-managed key encrypts SQS (both queues), DynamoDB, Lambda
# environment variables and every CloudWatch log group in this stack.
resource "aws_kms_key" "main" {
  description             = "CMK for ${local.name} (SQS, DynamoDB, Lambda env, CloudWatch Logs)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms_key.json
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.main.key_id
}

data "aws_iam_policy_document" "kms_key" {
  # checkov:skip=CKV_AWS_109:Key policy; Resource "*" refers only to this key.
  # checkov:skip=CKV_AWS_111:Key policy; Resource "*" refers only to this key.
  # checkov:skip=CKV_AWS_356:Key policy; Resource "*" refers only to this key.
  # Standard root statement: delegates key access to IAM policies in this
  # account. In a key policy "Resource = *" means "this key" only.
  statement {
    sid       = "EnableIamPolicies"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # CloudWatch Logs encrypts log groups itself, so it must be granted in the
  # key policy. Scoped by encryption context to log groups in this account.
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
    }
  }
}
