data "aws_caller_identity" "me" {}

locals {
  account   = data.aws_caller_identity.me.account_id
  param_arn = "arn:aws:ssm:${var.region}:${local.account}:parameter/ff-poc"
  oidc      = "token.actions.githubusercontent.com"
}

# Made once by bootstrap/: GitHub Actions gets short-lived AWS credentials through this provider,
# and every role here must carry the boundary, which caps what it can ever do.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://${local.oidc}"
}

data "aws_iam_policy" "boundary" {
  name = "ff-poc-boundary"
}

# The BE image. Releases tag the same image again for each rc and for prod, so 10 images cover
# many releases; rollback to an older one needs a rebuild.
resource "aws_ecr_repository" "be" {
  name                 = "ff-poc-be"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "be" {
  repository = aws_ecr_repository.be.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 10 newest images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

# Pushes the BE image: only from a tag build in ff-poc-be (the hub makes those tags).
data "aws_iam_policy_document" "be_push_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "${local.oidc}:sub"
      values   = ["${var.be_sub_prefix}:ref:refs/tags/*"]
    }
  }
}

data "aws_iam_policy_document" "be_push" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage",
      "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.be.arn]
  }
}

resource "aws_iam_role" "be_push" {
  name                 = "ff-poc-be-push"
  assume_role_policy   = data.aws_iam_policy_document.be_push_trust.json
  permissions_boundary = data.aws_iam_policy.boundary.arn
}

resource "aws_iam_role_policy" "be_push" {
  role   = aws_iam_role.be_push.id
  policy = data.aws_iam_policy_document.be_push.json
}

# Deploy role, one per stage. Only a job running in that stage's GitHub Environment can assume it,
# and production's environment needs an approval first.
data "aws_iam_policy_document" "deploy_trust" {
  for_each = var.stages

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc}:sub"
      values   = ["${var.hub_sub_prefix}:environment:${each.value}"]
    }
  }
}

# Pulls the image and lists parameter names, so the deploy can check every key the release needs
# is set. It can never read a value: reading and decrypting are denied outright.
data "aws_iam_policy_document" "deploy" {
  statement {
    actions   = ["ssm:DescribeParameters", "ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [aws_ecr_repository.be.arn]
  }
  statement {
    effect    = "Deny"
    actions   = ["kms:Decrypt", "ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "deploy" {
  for_each             = var.stages
  name                 = "ff-poc-deploy-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust[each.key].json
  permissions_boundary = data.aws_iam_policy.boundary.arn
}

resource "aws_iam_role_policy" "deploy" {
  for_each = var.stages
  role     = aws_iam_role.deploy[each.key].id
  policy   = data.aws_iam_policy_document.deploy.json
}

# Runtime role, one per stage: what the BE server runs as. It reads and decrypts its own stage's
# parameters only; staging can never read prod.
# In real use only ECS tasks assume it. This POC has no ECS, so the deploy job may assume it too
# and hand the short-lived credentials to the container it runs on the GitHub runner.
data "aws_iam_policy_document" "runtime_trust" {
  for_each = var.stages

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc}:sub"
      values   = ["${var.hub_sub_prefix}:environment:${each.value}"]
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
  for_each             = var.stages
  name                 = "ff-poc-be-runtime-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.runtime_trust[each.key].json
  permissions_boundary = data.aws_iam_policy.boundary.arn
}

resource "aws_iam_role_policy" "runtime" {
  for_each = var.stages
  role     = aws_iam_role.runtime[each.key].id
  policy   = data.aws_iam_policy_document.runtime[each.key].json
}

# The parameters themselves are not created here on purpose: Terraform would copy every value
# into its state file. An admin creates each one (see README), and the deploy fails while any key
# in the BE's .env.example has no parameter.
