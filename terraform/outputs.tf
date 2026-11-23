output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (one per AZ)."
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs (one per AZ)."
  value       = module.vpc.private_subnet_ids
}

output "availability_zones" {
  description = "AZs in use."
  value       = module.vpc.availability_zones
}

output "nat_public_ips" {
  description = "NAT egress IPs."
  value       = module.vpc.nat_public_ips
}

output "alb_dns_name" {
  description = "Public URL host of the application load balancer."
  value       = module.alb.dns_name
}

output "ecr_repository_url" {
  description = "Push the application image here."
  value       = module.ecr.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = module.ecs.cluster_name
}

output "ecs_service_name" {
  description = "ECS service name."
  value       = module.ecs.service_name
}

output "log_group_name" {
  description = "CloudWatch log group of the application."
  value       = module.ecs.log_group_name
}

output "db_endpoint" {
  description = "Aurora cluster (writer) endpoint, private, reachable only from the ECS tasks."
  value       = module.rds.address
}

output "db_secret_arn" {
  description = "Secrets Manager secret holding the generated DB credentials."
  value       = module.rds.master_user_secret_arn
}

output "db_read_endpoint" {
  description = "Aurora reader endpoint (load-balanced across reader instances)."
  value       = module.rds.read_address
}

output "db_cluster_identifier" {
  description = "Aurora cluster identifier (for failover tests and describe calls)."
  value       = module.rds.cluster_identifier
}

output "app_url" {
  description = "Public URL of the API."
  value       = var.domain_name != null ? "https://${var.domain_name}" : "http://${module.alb.dns_name}"
}
