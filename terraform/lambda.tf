# Only handler.py is packaged: boto3 is provided by the Lambda runtime.
# The zip lands in terraform/build/ and is passed from the plan job to the
# apply job as a CI artifact so the saved plan's hash matches.
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../src/handler.py"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}-order-handler"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_lambda_function" "order_handler" {
  function_name                  = "${local.name}-order-handler"
  description                    = "Accepts orders from API Gateway and processes them from SQS"
  role                           = aws_iam_role.lambda.arn
  runtime                        = "python3.12"
  handler                        = "handler.lambda_handler"
  filename                       = data.archive_file.lambda.output_path
  source_code_hash               = data.archive_file.lambda.output_base64sha256
  timeout                        = var.lambda_timeout_seconds
  memory_size                    = 256
  architectures                  = ["arm64"]
  reserved_concurrent_executions = var.lambda_reserved_concurrency
  kms_key_arn                    = aws_kms_key.main.arn

  environment {
    variables = {
      TABLE_NAME        = aws_dynamodb_table.orders.name
      QUEUE_URL         = aws_sqs_queue.orders.url
      STATE_MACHINE_ARN = aws_sfn_state_machine.order_workflow.arn
      LOG_LEVEL         = "INFO"
    }
  }

  tracing_config {
    mode = "Active"
  }

  # Failed asynchronous invocations go to the same DLQ as failed SQS messages.
  dead_letter_config {
    target_arn = aws_sqs_queue.orders_dlq.arn
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda.name
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
  ]
}

resource "aws_lambda_event_source_mapping" "orders_queue" {
  event_source_arn                   = aws_sqs_queue.orders.arn
  function_name                      = aws_lambda_function.order_handler.arn
  batch_size                         = var.sqs_batch_size
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = min(var.lambda_reserved_concurrency, 1000)
  }
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowHttpApiInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.order_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.orders.execution_arn}/*/POST/orders"
}
