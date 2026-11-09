# HTTP API (v2): cheaper and lower latency than REST for a single proxy route.
# The route uses AWS_IAM authorization, so callers must sign requests with SigV4
# and hold execute-api:Invoke on this API. No anonymous access.
resource "aws_apigatewayv2_api" "orders" {
  name          = "${local.name}-api"
  protocol_type = "HTTP"
  description   = "Order ingestion API"
}

resource "aws_apigatewayv2_integration" "order_handler" {
  api_id                 = aws_apigatewayv2_api.orders.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.order_handler.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

resource "aws_apigatewayv2_route" "post_orders" {
  api_id             = aws_apigatewayv2_api.orders.id
  route_key          = "POST /orders"
  target             = "integrations/${aws_apigatewayv2_integration.order_handler.id}"
  authorization_type = "AWS_IAM"
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.name}-api"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.orders.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.api_throttle_rate_limit
    throttling_burst_limit = var.api_throttle_burst_limit
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId          = "$context.requestId"
      requestTime        = "$context.requestTime"
      httpMethod         = "$context.httpMethod"
      routeKey           = "$context.routeKey"
      status             = "$context.status"
      responseLength     = "$context.responseLength"
      integrationLatency = "$context.integrationLatency"
      userArn            = "$context.identity.userArn"
      sourceIp           = "$context.identity.sourceIp"
      errorMessage       = "$context.error.message"
    })
  }
}
