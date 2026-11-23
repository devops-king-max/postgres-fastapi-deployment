variable "name" {
  description = "Name prefix for the cluster, its instances and its security group."
  type        = string
}

variable "vpc_id" {
  description = "VPC the database lives in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs (at least two AZs) for the DB subnet group."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "The DB subnet group needs subnets in at least two AZs."
  }
}

variable "availability_zones" {
  description = "AZs of subnet_ids. Instance N is placed in availability_zones[N % length]."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "Spread instances over at least two AZs."
  }
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to connect on 5432."
  type        = list(string)
}

variable "engine_version" {
  description = "Aurora PostgreSQL version (major.minor). List with: aws rds describe-db-engine-versions --engine aurora-postgresql."
  type        = string
  default     = "17.9"
}

variable "instance_class" {
  description = "Instance class for every cluster instance. db.t4g.medium is the smallest provisioned class for Aurora PostgreSQL."
  type        = string
  default     = "db.t4g.medium"
}

variable "instance_count" {
  description = "Cluster instances: 1 writer + (count - 1) readers. Use 2 or more for a readable failover target."
  type        = number
  default     = 2

  validation {
    condition     = var.instance_count >= 1 && var.instance_count <= 16
    error_message = "An Aurora cluster holds 1 to 16 instances."
  }
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "events_db"
}

variable "username" {
  description = "Master username."
  type        = string
  default     = "events_user"
}

variable "backup_retention_days" {
  description = "Automated backup retention in days (Aurora minimum is 1)."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Block accidental deletion. Enable for production."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Set false for production."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
