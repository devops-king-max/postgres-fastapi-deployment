variable "domain_name" {
  description = "Primary domain served by the ALB, e.g. example.com."
  type        = string
}

variable "alternative_names" {
  description = "Extra names that get an alias record, e.g. [\"www.example.com\"]."
  type        = list(string)
  default     = []
}

variable "certificate_domains" {
  description = "Domains of EXISTING ACM certificates to look up. The first becomes the listener's default certificate, the rest are added to it (SNI)."
  type        = list(string)

  validation {
    condition     = length(var.certificate_domains) > 0
    error_message = "Provide at least one certificate domain."
  }
}

variable "zone_name" {
  description = "Public Route 53 hosted zone that contains the names."
  type        = string
}

variable "alb_dns_name" {
  description = "ALB DNS name the alias records point to."
  type        = string
}

variable "alb_zone_id" {
  description = "ALB canonical hosted zone ID."
  type        = string
}
