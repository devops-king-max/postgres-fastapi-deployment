variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "fastapi-postgres"
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to use (minimum 2)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "az_count must be at least 2."
  }
}

variable "single_nat_gateway" {
  description = "Share one NAT gateway (cheap, dev) or create one per AZ (resilient, prod)."
  type        = bool
  default     = true
}

variable "environment" {
  description = "Environment label passed to the app as APP_ENV."
  type        = string
  default     = "dev"
}

variable "container_port" {
  description = "Port the FastAPI container listens on."
  type        = number
  default     = 8000
}

variable "image_tag" {
  description = "Image tag to deploy from the ECR repository. Prefer a unique tag (e.g. git SHA) over latest."
  type        = string
  default     = "latest"
}

variable "cpu_architecture" {
  description = "X86_64 or ARM64. Build the image with --platform linux/amd64 (or linux/arm64) to match."
  type        = string
  default     = "X86_64"
}

variable "task_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Initial and minimum number of tasks. Push an image to ECR before the full apply (see README step order)."
  type        = number
  default     = 2
}

variable "max_count" {
  description = "Autoscaling maximum number of tasks."
  type        = number
  default     = 6
}

variable "certificate_arn" {
  description = "ACM certificate ARN. Set to enable HTTPS (HTTP then redirects)."
  type        = string
  default     = null
}

variable "domain_name" {
  description = "Public domain for the API (e.g. aethrclothes.shop). Enables an ACM certificate, HTTPS and Route 53 alias records. Null keeps plain HTTP."
  type        = string
  default     = null
}

variable "domain_alternative_names" {
  description = "Extra names on the certificate and alias records."
  type        = list(string)
  default     = []
}

variable "dns_zone_name" {
  description = "Route 53 hosted zone name. Defaults to domain_name."
  type        = string
  default     = null
}

variable "db_multi_az" {
  description = "Run the primary with a synchronous standby in a second AZ (automatic failover)."
  type        = bool
  default     = true
}

variable "db_create_read_replica" {
  description = "Create one read replica for read traffic. Deferred: see docs/read-replica-deferred.md."
  type        = bool
  default     = false

  # Fail at plan time instead of after the primary has been built (~15 min).
  validation {
    condition     = !var.db_create_read_replica
    error_message = "RDS does not allow a read replica of a source whose master password is managed by Secrets Manager (manage_master_user_password = true in modules/rds). See terraform/docs/read-replica-deferred.md for the options."
  }
}

variable "db_deletion_protection" {
  description = "Protect the database from deletion and take a final snapshot on destroy. Enable for production."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    Project   = "postgres-fastapi-deployment"
    ManagedBy = "terraform"
  }
}
