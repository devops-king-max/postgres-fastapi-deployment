# One-time stack (run locally with admin-capable credentials) that creates what
# CI needs before it can run: remote state, state locking, and GitHub OIDC roles.
# Its own state stays local on purpose: it is tiny and must exist before the
# remote backend does.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = { Project = "postgres-fastapi-deployment", ManagedBy = "terraform-bootstrap" }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  bucket_name = "tfstate-${local.account_id}-${var.aws_region}"
  # GitHub's OIDC `sub` claim carries immutable numeric IDs for the owner and the
  # repository (owner@ID/repo@ID). Matching them also means a renamed or transferred
  # repository can no longer assume these roles. Observed in CloudTrail on the
  # first failed run; find the IDs with: gh api repos/<owner>/<repo> -q '.owner.id, .id'
  repo        = "${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}"
  name_prefix = var.app_name
}

# ---- Remote state ----
resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name
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
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "locks" {
  name         = "terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# ---- GitHub OIDC: no long-lived AWS keys in GitHub ----
# An account can hold one provider per URL; reuse it if it already exists.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  oidc_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    # Pull requests may only plan. A job that declares `environment:` gets an
    # environment-shaped subject (not ref-shaped), so the apply role trusts the
    # GitHub environment; restrict that environment to the main branch in the
    # repository settings (deployment branches) to keep "only main may apply".
    plan  = "repo:${local.repo}:pull_request"
    apply = "repo:${local.repo}:environment:${var.deploy_environment}"
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value]
    }
  }
}

resource "aws_iam_role" "ci" {
  for_each = data.aws_iam_policy_document.trust

  name                 = "${local.name_prefix}-ci-${each.key}"
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

# State access shared by both roles (plan also takes the lock).
data "aws_iam_policy_document" "state" {
  statement {
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.locks.arn]
  }
}

resource "aws_iam_role_policy" "state" {
  for_each = aws_iam_role.ci

  name   = "terraform-state"
  role   = each.value.id
  policy = data.aws_iam_policy_document.state.json
}

# Plan role: read everything, change nothing.
resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.ci["plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Apply role: service-level access to exactly the services this stack uses.
# IAM is limited to roles/policies named after the app, so the pipeline cannot
# mint an admin role.
data "aws_iam_policy_document" "apply" {
  statement {
    sid = "StackServices"
    actions = [
      "ec2:*", "ecs:*", "ecr:*", "elasticloadbalancing:*", "rds:*",
      "logs:*", "secretsmanager:*", "acm:*", "route53:*",
      "application-autoscaling:*", "kms:DescribeKey", "kms:CreateGrant",
    ]
    resources = ["*"]
  }

  # Notifying alarms and their topic, limited to names starting with the app name.
  statement {
    sid = "AppAlarms"
    actions = [
      "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:TagResource",
      "cloudwatch:UntagResource", "cloudwatch:ListTagsForResource",
    ]
    resources = ["arn:aws:cloudwatch:${var.aws_region}:${local.account_id}:alarm:${var.app_name}-*"]
  }

  statement {
    sid       = "DescribeAlarms"
    actions   = ["cloudwatch:DescribeAlarms"]
    resources = ["*"]
  }

  statement {
    sid       = "AppTopics"
    actions   = ["sns:*"]
    resources = ["arn:aws:sns:${var.aws_region}:${local.account_id}:${var.app_name}-*"]
  }

  statement {
    sid = "AppIamOnly"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:TagRole", "iam:UntagRole",
      "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole", "iam:PassRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.app_name}-*"]
  }

  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "ecs.amazonaws.com", "elasticloadbalancing.amazonaws.com", "rds.amazonaws.com",
        "ecs.application-autoscaling.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "stack-deploy"
  role   = aws_iam_role.ci["apply"].id
  policy = data.aws_iam_policy_document.apply.json
}
