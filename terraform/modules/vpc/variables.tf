variable "name" {
  description = "Name prefix applied to every resource created by this module."
  type        = string
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block of the VPC."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "azs" {
  description = "Availability Zones to spread subnets across. At least two for high availability."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "Provide at least two Availability Zones."
  }
}

variable "public_subnet_cidrs" {
  description = "One CIDR per AZ for the public subnets (same order as azs)."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "One CIDR per AZ for the private subnets (same order as azs)."
  type        = list(string)
}

variable "enable_nat_gateway" {
  description = "Create NAT gateway(s) so private subnets get outbound internet access."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway (cheaper, but an AZ outage cuts egress for all private subnets). Set false for one NAT per AZ."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
