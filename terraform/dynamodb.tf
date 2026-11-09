resource "aws_dynamodb_table" "orders" {
  name                        = "${local.name}-orders"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "orderId"
  deletion_protection_enabled = var.environment == "prod"

  attribute {
    name = "orderId"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  point_in_time_recovery {
    enabled = true
  }
}
