# One-time bootstrap, run locally with an admin profile (local state):
#   cd bootstrap && terraform init && terraform apply -var="gitlab_project_path=group/project"
# Creates: Terraform state bucket, GitLab OIDC provider, CI deploy role.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "serverless-event-pipeline"
}

variable "gitlab_url" {
  type    = string
  default = "https://gitlab.com"
}

variable "gitlab_project_path" {
  description = "GitLab project path allowed to assume the deploy role, e.g. my-group/serverless-event-pipeline."
  type        = string
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "shared"
      Project     = var.project_name
      ManagedBy   = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  partition    = data.aws_partition.current.partition
  gitlab_host  = trimprefix(var.gitlab_url, "https://")
  name_pattern = "${var.project_name}-*"
}

# ------------------------------------------------------------ state bucket --

resource "aws_s3_bucket" "state" {
  bucket = "${var.project_name}-tfstate-${local.account_id}"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

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

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json
}

# ------------------------------------------------------------ GitLab OIDC --

resource "aws_iam_openid_connect_provider" "gitlab" {
  url            = var.gitlab_url
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "deploy_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gitlab.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.gitlab_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Any branch / MR of this one project. Tighten to ref:main for apply-only roles.
    condition {
      test     = "StringLike"
      variable = "${local.gitlab_host}:sub"
      values   = ["project_path:${var.gitlab_project_path}:ref_type:branch:ref:*"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.project_name}-gitlab-deploy"
  assume_role_policy   = data.aws_iam_policy_document.deploy_assume.json
  max_session_duration = 3600
}

# Deploy permissions are limited to the services this stack uses. Resource
# names are constrained to the project prefix wherever the service supports it.
data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "TerraformState"
    actions   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid     = "ProjectIamRoles"
    actions = ["iam:*Role", "iam:*RolePolicy", "iam:*RolePolicies", "iam:TagRole", "iam:UntagRole", "iam:ListInstanceProfilesForRole", "iam:ListAttachedRolePolicies", "iam:PassRole"]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role/${local.name_pattern}",
    ]
  }

  statement {
    sid = "ProjectResources"
    actions = [
      "sqs:*",
      "dynamodb:*",
      "lambda:*",
      "states:*",
      "events:*",
    ]
    resources = [
      "arn:${local.partition}:sqs:*:${local.account_id}:${local.name_pattern}",
      "arn:${local.partition}:dynamodb:*:${local.account_id}:table/${local.name_pattern}",
      "arn:${local.partition}:lambda:*:${local.account_id}:function:${local.name_pattern}",
      "arn:${local.partition}:lambda:*:${local.account_id}:event-source-mapping:*",
      "arn:${local.partition}:states:*:${local.account_id}:stateMachine:${local.name_pattern}",
      "arn:${local.partition}:events:*:${local.account_id}:rule/${local.name_pattern}",
    ]
  }

  # These APIs either have no resource-level permissions or create resources
  # whose ARN is unknown until creation (KMS keys, HTTP APIs, log groups).
  statement {
    sid = "ServicesWithoutNamePrefix"
    actions = [
      "kms:*",
      "apigateway:*",
      "logs:*",
      "lambda:CreateEventSourceMapping",
      "lambda:GetEventSourceMapping",
      "lambda:ListEventSourceMappings",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "${var.project_name}-gitlab-deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "deploy_role_arn" {
  value = aws_iam_role.deploy.arn
}
