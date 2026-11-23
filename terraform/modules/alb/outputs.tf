output "dns_name" {
  description = "Public DNS name of the load balancer."
  value       = aws_lb.this.dns_name
}

output "zone_id" {
  description = "Canonical hosted zone ID of the load balancer (for Route 53 alias records)."
  value       = aws_lb.this.zone_id
}

output "security_group_id" {
  description = "ALB security group ID."
  value       = aws_security_group.this.id
}

output "target_group_arn" {
  description = "Target group ARN for the ECS service."
  value       = aws_lb_target_group.this.arn
}
