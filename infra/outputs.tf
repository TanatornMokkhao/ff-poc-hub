# Set by hand once after the first apply (see README): deploy and runtime ARNs as variables of each
# hub environment, the push ARN and the registry as variables of ff-poc-be.
output "deploy_role_arns" {
  value = { for k, r in aws_iam_role.deploy : k => r.arn }
}

output "runtime_role_arns" {
  value = { for k, r in aws_iam_role.runtime : k => r.arn }
}

output "be_push_role_arn" {
  value = aws_iam_role.be_push.arn
}

output "be_repository_url" {
  value = aws_ecr_repository.be.repository_url
}
