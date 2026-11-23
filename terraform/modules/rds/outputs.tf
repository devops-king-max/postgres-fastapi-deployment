output "address" {
  description = "DB hostname (no port)."
  value       = aws_db_instance.this.address
}

output "read_address" {
  description = "Read replica hostname, or null when no replica exists."
  value       = one(aws_db_instance.replica[*].address)
}

output "port" {
  description = "DB port."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Database name."
  value       = aws_db_instance.this.db_name
}

output "username" {
  description = "Master username."
  value       = aws_db_instance.this.username
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret (JSON with username/password) managed by RDS."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  description = "Database security group ID."
  value       = aws_security_group.this.id
}
