variable "name" {
  description = "Name prefix for the database and its security group."
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
    error_message = "RDS needs subnets in at least two AZs."
  }
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to connect on 5432."
  type        = list(string)
}

variable "engine_version" {
  description = "PostgreSQL engine version. A major-only value (e.g. 16) lets RDS pick the current minor."
  type        = string
  default     = "16"
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial storage in GiB."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling in GiB (0 disables autoscaling)."
  type        = number
  default     = 100
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

variable "multi_az" {
  description = "Synchronous standby in a second AZ with automatic failover (roughly doubles primary cost)."
  type        = bool
  default     = true
}

variable "create_read_replica" {
  description = "Create one read replica for read traffic."
  type        = bool
  default     = true
}

variable "replica_availability_zone" {
  description = "AZ for the read replica. Null lets AWS choose; set it to spread away from the primary."
  type        = string
  default     = null
}

variable "backup_retention_days" {
  description = "Automated backup retention. 0 disables backups."
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
