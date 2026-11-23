output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.this.name
}

output "tasks_security_group_id" {
  description = "Security group attached to the tasks (grant it access to backing services)."
  value       = aws_security_group.tasks.id
}

output "log_group_name" {
  description = "CloudWatch log group of the application."
  value       = aws_cloudwatch_log_group.this.name
}

output "task_role_arn" {
  description = "Task role ARN; attach policies here if the app needs AWS APIs."
  value       = aws_iam_role.task.arn
}
