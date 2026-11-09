# =============================================================================
# UNIVEN multi-region DR: wiring for both regions
#
#   Region 1 (primary)    : network -> compute -> RDS MySQL (Multi-AZ, writable)
#                           + site-to-site VPN to on-prem + S3 backups
#   Backup region         : network -> compute -> RDS cross-region read replica
#   Global                : Route 53 failover record + health check (dns.tf)
# =============================================================================

# --- Who may open the website ------------------------------------------------

data "http" "my_ip" {
  count = length(var.allowed_cidrs) == 0 ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

# Route 53 health checkers must reach the primary ALB; allow only their ranges.
data "aws_ip_ranges" "route53_healthchecks" {
  provider = aws.primary
  services = ["route53_healthchecks"]
  regions  = concat(var.health_check_regions, ["global"])
}

locals {
  name_primary   = "${var.project_name}-primary"
  name_secondary = "${var.project_name}-secondary"

  allowed_cidrs = length(var.allowed_cidrs) > 0 ? var.allowed_cidrs : [
    "${trimspace(data.http.my_ip[0].response_body)}/32"
  ]

  healthcheck_cidrs = data.aws_ip_ranges.route53_healthchecks.cidr_blocks

  db_secret_name = "${var.project_name}-db-credentials"
  app_fqdn       = "${var.app_subdomain}.${var.domain_name}"
}

# =============================================================================
# Networks
# =============================================================================

module "network_primary" {
  source    = "./modules/network"
  providers = { aws = aws.primary }

  name     = local.name_primary
  vpc_cidr = var.primary_vpc_cidr
}

module "network_secondary" {
  source    = "./modules/network"
  providers = { aws = aws.secondary }

  name     = local.name_secondary
  vpc_cidr = var.secondary_vpc_cidr
}

# =============================================================================
# Databases
# =============================================================================

module "db_primary" {
  source    = "./modules/database"
  providers = { aws = aws.primary }

  name              = local.name_primary
  mode              = "primary"
  subnet_ids        = module.network_primary.private_subnet_ids
  security_group_id = module.compute_primary.db_security_group_id
  instance_class    = var.db_instance_class
  engine_version    = var.db_engine_version
  multi_az          = var.db_multi_az
  username          = var.db_username
  password          = random_password.db.result
}

module "db_secondary" {
  source    = "./modules/database"
  providers = { aws = aws.secondary }

  name              = local.name_secondary
  mode              = "replica"
  subnet_ids        = module.network_secondary.private_subnet_ids
  security_group_id = module.compute_secondary.db_security_group_id
  instance_class    = var.db_instance_class
  source_db_arn     = module.db_primary.arn
}

# =============================================================================
# Compute (ALB + web + app)
# =============================================================================

module "compute_primary" {
  source    = "./modules/compute"
  providers = { aws = aws.primary }

  name               = local.name_primary
  is_primary         = true
  region_label       = "REGION 1 - PRIMARY"
  vpc_id             = module.network_primary.vpc_id
  azs                = module.network_primary.azs
  public_subnet_ids  = module.network_primary.public_subnet_ids
  private_subnet_ids = module.network_primary.private_subnet_ids
  allowed_cidrs      = local.allowed_cidrs
  healthcheck_cidrs  = local.healthcheck_cidrs
  instance_type      = var.instance_type

  db_host        = module.db_primary.address
  db_secret_name = aws_secretsmanager_secret.db_primary.name

  backup_bucket_name = aws_s3_bucket.backup.id
  s3_endpoint_id     = module.network_primary.s3_endpoint_id
}

module "compute_secondary" {
  source    = "./modules/compute"
  providers = { aws = aws.secondary }

  name               = local.name_secondary
  is_primary         = false
  region_label       = "BACKUP REGION"
  vpc_id             = module.network_secondary.vpc_id
  azs                = module.network_secondary.azs
  public_subnet_ids  = module.network_secondary.public_subnet_ids
  private_subnet_ids = module.network_secondary.private_subnet_ids
  allowed_cidrs      = local.allowed_cidrs
  healthcheck_cidrs  = local.healthcheck_cidrs
  instance_type      = var.instance_type

  # The backup region talks to ITS OWN replica, using ITS OWN copy of the secret.
  db_host        = module.db_secondary.address
  db_secret_name = aws_secretsmanager_secret.db_secondary.name
}

# =============================================================================
# Hybrid: site-to-site VPN to the on-prem campus (primary region)
# =============================================================================

module "vpn" {
  count     = var.enable_vpn ? 1 : 0
  source    = "./modules/vpn"
  providers = { aws = aws.primary }

  name              = local.name_primary
  vpc_id            = module.network_primary.vpc_id
  route_table_ids   = module.network_primary.private_route_table_ids
  customer_gateways = var.customer_gateway_ips
  customer_bgp_asn  = var.onprem_bgp_asn
}
