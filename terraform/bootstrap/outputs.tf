output "state_bucket" {
  description = "S3 bucket for Terraform state."
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  description = "DynamoDB table for state locking."
  value       = aws_dynamodb_table.locks.name
}

output "plan_role_arn" {
  description = "Role for pull-request plans (read-only)."
  value       = aws_iam_role.ci["plan"].arn
}

output "apply_role_arn" {
  description = "Role for deployments from the main branch."
  value       = aws_iam_role.ci["apply"].arn
}
