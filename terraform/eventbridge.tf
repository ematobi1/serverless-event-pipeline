# Custom-event rule on the default bus. Any producer in the account can ask for
# an existing order to be (re)processed without going through API Gateway/SQS:
#
#   aws events put-events --entries '[{
#     "Source": "serverless-event-pipeline.orders",
#     "DetailType": "OrderReprocessRequested",
#     "Detail": "{\"orderId\":\"order-001\"}"
#   }]'
#
# A custom event was chosen over a schedule because the workflow acts on one
# order; a cron trigger would have no order to act on.
resource "aws_cloudwatch_event_rule" "order_reprocess" {
  name        = "${local.name}-order-reprocess"
  description = "Starts the order workflow for ${local.event_detail_type} events"

  event_pattern = jsonencode({
    source        = [local.event_source]
    "detail-type" = [local.event_detail_type]
    detail = {
      orderId = [{ exists = true }]
    }
  })
}

resource "aws_cloudwatch_event_target" "order_workflow" {
  rule     = aws_cloudwatch_event_rule.order_reprocess.name
  arn      = aws_sfn_state_machine.order_workflow.arn
  role_arn = aws_iam_role.eventbridge.arn

  # Reshape the EventBridge envelope into the state machine's input contract.
  input_transformer {
    input_paths = {
      orderId = "$.detail.orderId"
    }
    input_template = <<-EOT
      {"orderId": <orderId>, "source": "eventbridge"}
    EOT
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 5
  }
}
