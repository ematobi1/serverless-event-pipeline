resource "aws_cloudwatch_log_group" "state_machine" {
  # The /aws/vendedlogs/ prefix avoids the CloudWatch resource-policy size limit.
  name              = "/aws/vendedlogs/states/${local.name}-order-workflow"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_sfn_state_machine" "order_workflow" {
  name     = "${local.name}-order-workflow"
  type     = "STANDARD"
  role_arn = aws_iam_role.step_functions.arn

  definition = templatefile("${path.module}/statemachine/order_workflow.asl.json", {
    table_name = aws_dynamodb_table.orders.name
  })

  logging_configuration {
    log_destination = "${aws_cloudwatch_log_group.state_machine.arn}:*"
    # Execution input holds only orderId + source, and the log group is CMK-encrypted.
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true
  }

  encryption_configuration {
    type                              = "CUSTOMER_MANAGED_KMS_KEY"
    kms_key_id                        = aws_kms_key.main.arn
    kms_data_key_reuse_period_seconds = 300
  }

  depends_on = [aws_iam_role_policy.step_functions]
}
