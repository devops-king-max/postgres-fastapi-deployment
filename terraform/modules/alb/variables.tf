variable "name" {
  description = "Name prefix (first 6 characters are used for ALB/target-group name prefixes)."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs (at least two AZs)."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An ALB needs subnets in at least two AZs."
  }
}

variable "target_port" {
  description = "Port the application container listens on."
  type        = number
  default     = 8000
}

variable "health_check_path" {
  description = "HTTP path the ALB probes. Use a liveness path that does not depend on the database."
  type        = string
  default     = "/health"
}

variable "enable_https" {
  description = "Create the HTTPS listener and redirect HTTP to HTTPS. Requires certificate_arn."
  type        = bool
  default     = false
}

variable "certificate_arn" {
  description = "ACM certificate ARN used by the HTTPS listener (may be unknown until apply)."
  type        = string
  default     = null
}

variable "additional_certificate_arns" {
  description = "Extra certificates on the HTTPS listener (e.g. a wildcard next to an apex certificate)."
  type        = list(string)
  default     = []
}

variable "ingress_cidr" {
  description = "CIDR allowed to reach the ALB."
  type        = string
  default     = "0.0.0.0/0"
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
