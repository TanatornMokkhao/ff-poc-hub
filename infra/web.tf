# The FE web app, per stage: a private bucket served over HTTPS by CloudFront. The hub deploy
# copies the stage's web build (made once per rc by ff-poc-fe) into the bucket.

resource "aws_s3_bucket" "web" {
  for_each      = var.stages
  bucket        = "ff-poc-web-${each.key}-${local.account}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "web" {
  for_each                = var.stages
  bucket                  = aws_s3_bucket.web[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "web" {
  for_each                          = var.stages
  name                              = "ff-poc-web-${each.key}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "web" {
  for_each            = var.stages
  enabled             = true
  comment             = "ff-poc web ${each.key}"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    origin_id                = "web"
    domain_name              = aws_s3_bucket.web[each.key].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.web[each.key].id
  }

  default_cache_behavior {
    target_origin_id       = "web"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    # AWS managed policy "CachingOptimized"; index.html and config.json are sent with no-store.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Only this stage's CloudFront distribution may read the bucket.
data "aws_iam_policy_document" "web_bucket" {
  for_each = var.stages

  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.web[each.key].arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.web[each.key].arn]
    }
  }
}

resource "aws_s3_bucket_policy" "web" {
  for_each = var.stages
  bucket   = aws_s3_bucket.web[each.key].id
  policy   = data.aws_iam_policy_document.web_bucket[each.key].json
}

# The deploy role writes its own stage's bucket and refreshes its own stage's distribution.
data "aws_iam_policy_document" "deploy_web" {
  for_each = var.stages

  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.web[each.key].arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.web[each.key].arn}/*"]
  }
  statement {
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = [aws_cloudfront_distribution.web[each.key].arn]
  }
}

resource "aws_iam_role_policy" "deploy_web" {
  for_each = var.stages
  name     = "web"
  role     = aws_iam_role.deploy[each.key].id
  policy   = data.aws_iam_policy_document.deploy_web[each.key].json
}

# Set by hand once after apply: WEB_BUCKET and CF_DISTRIBUTION_ID in each hub environment.
output "web" {
  value = {
    for k in keys(var.stages) : k => {
      bucket          = aws_s3_bucket.web[k].bucket
      distribution_id = aws_cloudfront_distribution.web[k].id
      url             = "https://${aws_cloudfront_distribution.web[k].domain_name}/"
    }
  }
}
