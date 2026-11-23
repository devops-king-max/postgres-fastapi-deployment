data "aws_route53_zone" "this" {
  name         = var.zone_name
  private_zone = false
}

locals {
  names = concat([var.domain_name], var.alternative_names)
}

# Existing certificates are looked up, never requested. An ALB can only use
# certificates from its own region, so these must live in the deployment region.
# statuses = ISSUED makes the plan fail early on an expired or pending cert.
data "aws_acm_certificate" "this" {
  for_each = toset(var.certificate_domains)

  domain      = each.value
  statuses    = ["ISSUED"]
  most_recent = true
}

resource "aws_route53_record" "alias" {
  for_each = toset(local.names)

  zone_id = data.aws_route53_zone.this.zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}
