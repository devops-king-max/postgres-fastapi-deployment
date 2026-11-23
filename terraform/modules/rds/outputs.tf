output "address" {
  description = "Primary hostname (no port). Writes go here; it follows a Multi-AZ failover."
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

output "secret_arn" {
  description = "Secrets Manager secret (JSON with username/password/host/port/dbname) written by Terraform."
  # The version's arn is the secret ARN; referencing the version makes
  # consumers (the ECS task definition) wait until the value is written.
  value = aws_secretsmanager_secret_version.db.arn
}

output "security_group_id" {
  description = "Database security group ID."
  value       = aws_security_group.this.id
}

output "instance_identifier" {
  description = "Primary DB instance identifier (CloudWatch DBInstanceIdentifier dimension)."
  value       = aws_db_instance.this.identifier
}

output "replica_identifier" {
  description = "Read replica identifier, or null when no replica exists."
  value       = one(aws_db_instance.replica[*].identifier)
}
