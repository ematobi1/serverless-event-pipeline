# One role per service principal, each scoped to the exact resources it touches.
#
# Wildcard resources appear in two places only, both forced by AWS:
#   * X-Ray PutTraceSegments/PutTelemetryRecords do not support resource-level
#     permissions.
#   * Step Functions log delivery (logs:*LogDelivery*, Describe*Policies) is an
#     account-level API without resource-level permissions.

data "aws_iam_policy_document" "xray" {
  statement {
    sid       = "XRayTracing"
    effect    = "Allow"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

# ---------------------------------------------------------------- Lambda ----

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda" {
  source_policy_documents = [data.aws_iam_policy_document.xray.json]

  statement {
    sid       = "WriteOwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  # API path enqueues orders; dead_letter_config sends failed async events to the DLQ.
  statement {
    sid       = "SendToQueues"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.orders.arn, aws_sqs_queue.orders_dlq.arn]
  }

  # Required by the SQS event source mapping.
  statement {
    sid    = "ConsumeOrdersQueue"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [aws_sqs_queue.orders.arn]
  }

  statement {
    sid       = "InsertOrders"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.orders.arn]
  }

  statement {
    sid       = "StartOrderWorkflow"
    effect    = "Allow"
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.order_workflow.arn]
  }

  # SQS, DynamoDB and Lambda env vars are all encrypted with the CMK.
  statement {
    sid       = "UseCmk"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${local.name}-lambda"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

# -------------------------------------------------------- Step Functions ----

data "aws_iam_policy_document" "step_functions_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:states:${local.region}:${local.account_id}:stateMachine:${local.name}-*"]
    }
  }
}

resource "aws_iam_role" "step_functions" {
  name               = "${local.name}-sfn"
  assume_role_policy = data.aws_iam_policy_document.step_functions_assume.json
}

data "aws_iam_policy_document" "step_functions" {
  source_policy_documents = [data.aws_iam_policy_document.xray.json]

  statement {
    sid       = "UpdateOrders"
    effect    = "Allow"
    actions   = ["dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.orders.arn]
  }

  # DynamoDB table and the state machine's own execution data use the CMK.
  statement {
    sid       = "UseCmk"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.main.arn]
  }

  statement {
    sid    = "LogDelivery"
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "step_functions" {
  name   = "${local.name}-sfn"
  role   = aws_iam_role.step_functions.id
  policy = data.aws_iam_policy_document.step_functions.json
}

# ----------------------------------------------------------- EventBridge ----

data "aws_iam_policy_document" "eventbridge_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "eventbridge" {
  name               = "${local.name}-events"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume.json
}

data "aws_iam_policy_document" "eventbridge" {
  statement {
    sid       = "StartOrderWorkflow"
    effect    = "Allow"
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.order_workflow.arn]
  }

  # StartExecution on a CMK-encrypted state machine needs the key.
  statement {
    sid       = "UseCmk"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "eventbridge" {
  name   = "${local.name}-events"
  role   = aws_iam_role.eventbridge.id
  policy = data.aws_iam_policy_document.eventbridge.json
}
