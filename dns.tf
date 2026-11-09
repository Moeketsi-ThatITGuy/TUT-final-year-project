# -----------------------------------------------------------------------------
# Route 53 DNS failover
#   app.<domain>  PRIMARY   -> Region 1 ALB   (health-checked)
#                 SECONDARY -> Backup ALB     (used when PRIMARY is unhealthy)
# -----------------------------------------------------------------------------

resource "aws_route53_zone" "this" {
  count         = var.existing_hosted_zone_id == null ? 1 : 0
  provider      = aws.primary
  name          = var.domain_name
  comment       = "UNIVEN multi-region DR demo"
  force_destroy = true
}

locals {
  zone_id = var.existing_hosted_zone_id != null ? var.existing_hosted_zone_id : aws_route53_zone.this[0].zone_id
}

data "aws_route53_zone" "selected" {
  provider = aws.primary
  zone_id  = local.zone_id
}

resource "aws_route53_health_check" "primary" {
  provider          = aws.primary
  fqdn              = module.compute_primary.alb_dns_name
  type              = "HTTP"
  port              = 80
  resource_path     = "/health"
  request_interval  = 10 # fast checks so the demo fails over in ~30-60s
  failure_threshold = 2
  regions           = var.health_check_regions
  measure_latency   = false

  tags = { Name = "${local.name_primary}-alb-health" }
}

resource "aws_route53_record" "app_primary" {
  provider        = aws.primary
  zone_id         = local.zone_id
  name            = local.app_fqdn
  type            = "A"
  set_identifier  = "primary-${var.primary_region}"
  health_check_id = aws_route53_health_check.primary.id

  failover_routing_policy {
    type = "PRIMARY"
  }

  alias {
    name                   = module.compute_primary.alb_dns_name
    zone_id                = module.compute_primary.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "app_secondary" {
  provider       = aws.primary
  zone_id        = local.zone_id
  name           = local.app_fqdn
  type           = "A"
  set_identifier = "secondary-${var.secondary_region}"

  failover_routing_policy {
    type = "SECONDARY"
  }

  alias {
    name                   = module.compute_secondary.alb_dns_name
    zone_id                = module.compute_secondary.alb_zone_id
    evaluate_target_health = true
  }
}
