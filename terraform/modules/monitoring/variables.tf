variable "name" {
  description = "Name prefix for the topic, alarms and health check."
  type        = string
}

variable "alarm_emails" {
  description = "Email addresses subscribed to the alarm topic. Each must confirm the subscription email from AWS."
  type        = list(string)
  default     = []
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix (CloudWatch LoadBalancer dimension)."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Target group ARN suffix (CloudWatch TargetGroup dimension)."
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name."
  type        = string
}

variable "ecs_service_name" {
  description = "ECS service name."
  type        = string
}

variable "db_cluster_identifier" {
  description = "Aurora cluster identifier."
  type        = string
}

variable "health_check_fqdn" {
  description = "Public hostname for the Route 53 /db-check health check. Null disables the check and its alarm."
  type        = string
  default     = null
}

variable "health_check_path" {
  description = "Path the Route 53 health check requests."
  type        = string
  default     = "/db-check"
}

variable "latency_p95_threshold_seconds" {
  description = "Alarm when p95 target response time exceeds this many seconds."
  type        = number
  default     = 1
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
