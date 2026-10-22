# Put each deploy role ARN in the matching GitHub Environment as the AWS_ROLE_ARN variable.
output "deploy_role_arns" {
  value = { for k, r in aws_iam_role.deploy : k => r.arn }
}

output "runtime_role_arns" {
  value = { for k, r in aws_iam_role.runtime : k => r.arn }
}

output "secret_names" {
  value = local.secret_list
}
