output "api_endpoint" {
  description = "Base URL of the HTTP API. POST /orders with a SigV4-signed request."
  value       = aws_apigatewayv2_api.orders.api_endpoint
}

output "orders_queue_url" {
  description = "URL of the main orders queue."
  value       = aws_sqs_queue.orders.url
}

output "orders_dlq_url" {
  description = "URL of the dead-letter queue."
  value       = aws_sqs_queue.orders_dlq.url
}

output "orders_table_name" {
  description = "DynamoDB table holding orders."
  value       = aws_dynamodb_table.orders.name
}

output "state_machine_arn" {
  description = "ARN of the order workflow state machine."
  value       = aws_sfn_state_machine.order_workflow.arn
}

output "lambda_function_name" {
  description = "Name of the order handler Lambda function."
  value       = aws_lambda_function.order_handler.function_name
}

output "eventbridge_rule_name" {
  description = "EventBridge rule that starts the workflow for reprocess requests."
  value       = aws_cloudwatch_event_rule.order_reprocess.name
}

output "eventbridge_event_source" {
  description = "Source value producers must use when emitting reprocess events."
  value       = local.event_source
}

output "kms_key_arn" {
  description = "ARN of the customer-managed KMS key."
  value       = aws_kms_key.main.arn
}
