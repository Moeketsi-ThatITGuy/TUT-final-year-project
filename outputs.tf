# --- Endpoints ------------------------------------------------------------------

output "failover_fqdn" {
  description = "The DNS name that fails over between regions."
  value       = local.app_fqdn
}

output "route53_name_servers" {
  description = "Authoritative name servers. Query these directly if you don't own the domain."
  value       = data.aws_route53_zone.selected.name_servers
}

output "primary_alb_url" {
  value = "http://${module.compute_primary.alb_dns_name}"
}

output "secondary_alb_url" {
  value = "http://${module.compute_secondary.alb_dns_name}"
}

output "primary_alb_dns_name" {
  value = module.compute_primary.alb_dns_name
}

output "secondary_alb_dns_name" {
  value = module.compute_secondary.alb_dns_name
}

output "health_check_id" {
  value = aws_route53_health_check.primary.id
}

output "allowed_cidrs" {
  description = "Networks allowed to open the website."
  value       = local.allowed_cidrs
}

# --- Regions / instances (used by scripts/) ------------------------------------

output "project_name" {
  value = var.project_name
}

output "primary_region" {
  value = var.primary_region
}

output "secondary_region" {
  value = var.secondary_region
}

output "primary_web_instance_ids" {
  value = module.compute_primary.web_instance_ids
}

output "primary_app_instance_ids" {
  value = module.compute_primary.app_instance_ids
}

output "secondary_web_instance_ids" {
  value = module.compute_secondary.web_instance_ids
}

output "secondary_app_instance_ids" {
  value = module.compute_secondary.app_instance_ids
}

# --- Databases ------------------------------------------------------------------

output "primary_db_endpoint" {
  value = module.db_primary.address
}

output "secondary_db_endpoint" {
  value = module.db_secondary.address
}

output "secondary_db_identifier" {
  value = module.db_secondary.identifier
}

output "backup_bucket" {
  value = aws_s3_bucket.backup.id
}

# --- Hybrid VPN -------------------------------------------------------------------

output "vpn_connections" {
  description = "Tunnel endpoints/inside IPs for the Packet Tracer edge router write-up."
  value       = var.enable_vpn ? module.vpn[0].connections : {}
}

output "vpn_preshared_keys" {
  description = "Tunnel PSKs. terraform output -json vpn_preshared_keys"
  value       = var.enable_vpn ? module.vpn[0].preshared_keys : {}
  sensitive   = true
}

output "cloudwatch_dashboard_url" {
  value = "https://${var.primary_region}.console.aws.amazon.com/cloudwatch/home?region=${var.primary_region}#dashboards:name=${aws_cloudwatch_dashboard.dr.dashboard_name}"
}
