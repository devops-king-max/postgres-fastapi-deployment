variable "name" {
  description = "Name prefix for the cluster, service, roles and log group."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets the tasks run in (at least two AZs)."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Run tasks in at least two AZs."
  }
}

variable "container_image" {
  description = "Full image URI including tag, e.g. <acct>.dkr.ecr.<region>.amazonaws.com/app:1.0.0."
  type        = string
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
  default     = 8000
}

variable "cpu" {
  description = "Task CPU units (256 = 0.25 vCPU). Must be a valid Fargate pair with memory."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Task memory in MiB."
  type        = number
  default     = 512
}

variable "cpu_architecture" {
  description = "X86_64 or ARM64. Must match the architecture the image was built for."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "desired_count" {
  description = "Initial number of tasks. Autoscaling manages it afterwards."
  type        = number
  default     = 2
}

variable "min_capacity" {
  description = "Autoscaling minimum task count."
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Autoscaling maximum task count."
  type        = number
  default     = 6
}

variable "cpu_target_percent" {
  description = "Target average CPU utilization for autoscaling."
  type        = number
  default     = 60
}

variable "environment" {
  description = "Plain environment variables for the container."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Container env vars sourced from Secrets Manager. json_key selects a key of a JSON secret."
  type = map(object({
    secret_arn = string
    json_key   = optional(string)
  }))
  default = {}
}

variable "target_group_arn" {
  description = "ALB target group the service registers with."
  type        = string
}

variable "alb_security_group_id" {
  description = "ALB security group; the only source allowed to reach the tasks."
  type        = string
}

variable "ecr_repository_arns" {
  description = "ECR repositories the execution role may pull from."
  type        = list(string)

  validation {
    condition     = length(var.ecr_repository_arns) > 0
    error_message = "Provide at least one ECR repository ARN, otherwise tasks cannot pull their image."
  }
}

variable "database_security_group_id" {
  description = "Security group of the database; the only egress destination on 5432."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
  default     = 30
}

variable "enable_container_insights" {
  description = "Enable CloudWatch Container Insights (extra cost)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
