data "aws_caller_identity" "me" {}

locals {
  account   = data.aws_caller_identity.me.account_id
  param_arn = "arn:aws:ssm:${var.region}:${local.account}:parameter/ff-poc"
}

# GitHub Actions gets short-lived AWS credentials from this provider; no AWS keys are stored in GitHub.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# Deploy role, one per stage. Only a job running in that stage's GitHub Environment can assume it,
# and production's environment needs an approval first.
data "aws_iam_policy_document" "deploy_trust" {
  for_each = var.stages

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
      values   = ["repo:${var.github_owner}/${var.hub_repo}:environment:${each.value}"]
    }
  }
}

# Lists parameter names, so the deploy can check every key the release needs is set.
# It can never read a value: reading and decrypting are denied outright.
data "aws_iam_policy_document" "deploy" {
  statement {
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }
  statement {
    effect    = "Deny"
    actions   = ["kms:Decrypt", "ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "deploy" {
  for_each           = var.stages
  name               = "ff-poc-deploy-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.deploy_trust[each.key].json
}

resource "aws_iam_role_policy" "deploy" {
  for_each = var.stages
  role     = aws_iam_role.deploy[each.key].id
  policy   = data.aws_iam_policy_document.deploy.json
}

# Runtime role, one per stage: what the BE server runs as (an ECS task role here).
# It reads and decrypts its own stage's parameters only; staging can never read prod.
data "aws_iam_policy_document" "runtime_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "runtime" {
  for_each = var.stages

  statement {
    actions   = ["ssm:GetParametersByPath", "ssm:GetParameters"]
    resources = ["${local.param_arn}/${each.key}/be", "${local.param_arn}/${each.key}/be/*"]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runtime" {
  for_each           = var.stages
  name               = "ff-poc-be-runtime-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.runtime_trust.json
}

resource "aws_iam_role_policy" "runtime" {
  for_each = var.stages
  role     = aws_iam_role.runtime[each.key].id
  policy   = data.aws_iam_policy_document.runtime[each.key].json
}

# The secret parameters themselves are not created here on purpose: Terraform would copy every
# value into its state file. An admin creates each one once (see README), and the deploy fails
# while any key marked "# secret" in the BE's .env.example has no value.
