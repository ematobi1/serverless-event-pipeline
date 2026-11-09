variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name, used as a prefix for every resource name and as the Project tag."
  type        = string
  default     = "serverless-event-pipeline"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,40}$", var.project_name))
    error_message = "project_name must be 3-40 characters of lowercase letters, digits and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for Lambda, API Gateway and Step Functions log groups."
  type        = number
  default     = 365
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout. The SQS visibility timeout is derived from it (6x, per AWS guidance)."
  type        = number
  default     = 30
}

variable "lambda_reserved_concurrency" {
  description = "Reserved concurrency for the Lambda function. Caps cost and protects downstream services."
  type        = number
  default     = 10
}

variable "sqs_max_receive_count" {
  description = "Number of receives before a message is moved to the DLQ."
  type        = number
  default     = 3
}

variable "sqs_batch_size" {
  description = "Maximum number of SQS messages per Lambda invocation."
  type        = number
  default     = 10
}

variable "api_throttle_rate_limit" {
  description = "Steady-state requests per second allowed by the HTTP API default route settings."
  type        = number
  default     = 50
}

variable "api_throttle_burst_limit" {
  description = "Burst requests allowed by the HTTP API default route settings."
  type        = number
  default     = 100
}
