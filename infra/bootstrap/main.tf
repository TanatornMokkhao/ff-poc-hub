# One-time setup, applied by a person with admin rights. It creates what CI needs before it can
# reach AWS on its own: the GitHub OIDC provider, the role Terraform runs as in CI, the boundary
# that caps every role Terraform creates, and the bucket for Terraform state.
# Everything else in infra/ is applied by CI through ff-poc-terraform.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

# GitHub's immutable OIDC subject: owner and repo names with their numeric ids, so a repo created
# later under the same name never matches. Read it with:
#   gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix
variable "hub_sub_prefix" {
  type    = string
  default = "repo:TanatornMokkhao@111348335/ff-poc-hub@1429529487"
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "me" {}

locals {
  account  = data.aws_caller_identity.me.account_id
  prefix   = "ff-poc"
  bucket   = "${local.prefix}-tfstate-${local.account}"
  role_arn = "arn:aws:iam::${local.account}:role/${local.prefix}-*"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# The most any role made by Terraform can do: read the ff-poc parameters, push and pull the
# ff-poc images, write the ff-poc web buckets and refresh their CDN. Nothing else in the account,
# whatever policy the role is given.
data "aws_iam_policy_document" "boundary" {
  statement {
    sid       = "ListParameterNames"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }
  statement {
    sid       = "Parameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:${var.region}:${local.account}:parameter/${local.prefix}/*"]
  }
  statement {
    sid       = "DecryptThroughSsm"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "Images"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage",
      "ecr:DescribeImages",
    ]
    resources = ["arn:aws:ecr:${var.region}:${local.account}:repository/${local.prefix}-*"]
  }
  statement {
    sid       = "WebBuckets"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.prefix}-web-*"]
  }
  statement {
    sid       = "WebObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.prefix}-web-*/*"]
  }
  statement {
    sid       = "CdnRefresh"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = ["arn:aws:cloudfront::${local.account}:distribution/*"]
  }
}

resource "aws_iam_policy" "boundary" {
  name   = "${local.prefix}-boundary"
  policy = data.aws_iam_policy_document.boundary.json
}

# Terraform in CI: only from a job in the hub's "infra" environment, which needs an approval.
data "aws_iam_policy_document" "terraform_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.hub_sub_prefix}:environment:infra"]
    }
  }
}

data "aws_iam_policy_document" "terraform" {
  statement {
    sid       = "ReadIam"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }
  # A role can only be created or given a policy while it carries the boundary.
  statement {
    sid       = "RolesUnderBoundary"
    actions   = ["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:PutRolePermissionsBoundary"]
    resources = [local.role_arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.boundary.arn]
    }
  }
  statement {
    sid = "ManageOwnRoles"
    actions = [
      "iam:DeleteRole", "iam:DeleteRolePolicy", "iam:DetachRolePolicy", "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy", "iam:TagRole", "iam:UntagRole",
    ]
    resources = [local.role_arn]
  }
  # It can never change itself, the boundary, or take the boundary off a role.
  statement {
    sid    = "ProtectBootstrap"
    effect = "Deny"
    actions = [
      "iam:Create*", "iam:Delete*", "iam:Put*", "iam:Update*", "iam:Attach*", "iam:Detach*",
      "iam:Tag*", "iam:Untag*", "iam:SetDefaultPolicyVersion",
    ]
    resources = ["arn:aws:iam::${local.account}:role/${local.prefix}-terraform", aws_iam_policy.boundary.arn]
  }
  statement {
    sid       = "KeepBoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }
  statement {
    sid       = "Repositories"
    actions   = ["ecr:*"]
    resources = ["arn:aws:ecr:${var.region}:${local.account}:repository/${local.prefix}-*"]
  }
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken", "ecr:DescribeRepositories"]
    resources = ["*"]
  }
  statement {
    sid       = "WebBuckets"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::${local.prefix}-web-*", "arn:aws:s3:::${local.prefix}-web-*/*"]
  }
  # CloudFront has few resource-level permissions; the account has no other distribution.
  statement {
    sid       = "Cdn"
    actions   = ["cloudfront:*"]
    resources = ["*"]
  }
  statement {
    sid       = "StateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_role" "terraform" {
  name                 = "${local.prefix}-terraform"
  assume_role_policy   = data.aws_iam_policy_document.terraform_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "terraform" {
  name   = "terraform"
  role   = aws_iam_role.terraform.id
  policy = data.aws_iam_policy_document.terraform.json
}

# Terraform plan on pull requests: reads what plan refreshes and the state, writes nothing. Plans
# run with -lock=false, so it needs no write even on the lock file.
data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.hub_sub_prefix}:pull_request"]
    }
  }
}

data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "ReadIam"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }
  statement {
    sid       = "ReadEcr"
    actions   = ["ecr:DescribeRepositories", "ecr:ListTagsForResource", "ecr:GetLifecyclePolicy", "ecr:GetRepositoryPolicy"]
    resources = ["*"]
  }
  statement {
    sid       = "ReadBuckets"
    actions   = ["s3:GetBucket*", "s3:GetAccelerateConfiguration", "s3:GetLifecycleConfiguration", "s3:GetReplicationConfiguration", "s3:GetEncryptionConfiguration", "s3:GetObjectLockConfiguration", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.prefix}-*"]
  }
  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
  statement {
    sid       = "ReadCdn"
    actions   = ["cloudfront:Get*", "cloudfront:List*"]
    resources = ["*"]
  }
  # Written out so that no later Allow can turn this role into a writer.
  statement {
    sid    = "NeverWrite"
    effect = "Deny"
    actions = [
      "iam:Create*", "iam:Delete*", "iam:Put*", "iam:Update*", "iam:Attach*", "iam:Detach*", "iam:Tag*",
      "iam:Untag*", "iam:PassRole", "iam:SetDefaultPolicyVersion", "s3:Put*", "s3:Delete*", "s3:Replicate*",
      "ecr:Put*", "ecr:Delete*", "ecr:BatchDelete*", "ecr:Create*", "ecr:Set*", "ecr:Tag*", "ecr:Untag*",
      "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer", "cloudfront:Create*", "cloudfront:Update*", "cloudfront:Delete*",
      "cloudfront:Tag*", "cloudfront:Untag*", "ssm:*", "kms:*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "plan" {
  name                 = "${local.prefix}-terraform-plan"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "plan" {
  name   = "plan"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket
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

output "terraform_role_arn" {
  value = aws_iam_role.terraform.arn
}

output "terraform_plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "boundary_arn" {
  value = aws_iam_policy.boundary.arn
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "region" {
  value = var.region
}
