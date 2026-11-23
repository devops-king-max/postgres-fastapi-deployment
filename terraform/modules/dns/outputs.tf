output "certificate_arn" {
  description = "ARN of the default (first) certificate."
  value       = data.aws_acm_certificate.this[var.certificate_domains[0]].arn
}

output "additional_certificate_arns" {
  description = "ARNs of the remaining certificates, attached to the same listener."
  value       = [for d in slice(var.certificate_domains, 1, length(var.certificate_domains)) : data.aws_acm_certificate.this[d].arn]
}

output "fqdns" {
  description = "Names that resolve to the ALB."
  value       = [for r in aws_route53_record.alias : r.fqdn]
}
