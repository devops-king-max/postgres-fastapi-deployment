output "address" {
  description = "Cluster (writer) endpoint hostname. Follows the writer after a failover."
  value       = aws_rds_cluster.this.endpoint
}

output "read_address" {
  description = "Reader endpoint hostname, load-balanced across readers (the writer when there are none)."
  value       = aws_rds_cluster.this.reader_endpoint
}

output "port" {
  description = "DB port."
  value       = aws_rds_cluster.this.port
}

output "db_name" {
  description = "Database name."
  value       = aws_rds_cluster.this.database_name
}

output "username" {
  description = "Master username."
  value       = aws_rds_cluster.this.master_username
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret (JSON with username/password) managed by RDS."
  value       = aws_rds_cluster.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  description = "Database security group ID."
  value       = aws_security_group.this.id
}

output "cluster_identifier" {
  description = "Aurora cluster identifier."
  value       = aws_rds_cluster.this.cluster_identifier
}
