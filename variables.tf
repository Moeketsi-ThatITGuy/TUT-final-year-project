# =============================================================================
# General
# =============================================================================

variable "project_name" {
  description = "Short prefix for all resource names (lowercase, max 8 chars)."
  type        = string
  default     = "univen"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.project_name))
    error_message = "project_name must be 2-8 lowercase letters/digits, starting with a letter."
  }
}

variable "aws_profile" {
  description = "Optional AWS CLI profile. Leave null to use AWS_PROFILE / env credentials."
  type        = string
  default     = null
}

variable "extra_tags" {
  description = "Additional tags for every resource."
  type        = map(string)
  default     = {}
}

# =============================================================================
# Regions and networks
# =============================================================================

variable "primary_region" {
  description = "Region 1 (serves traffic normally, writable DB)."
  type        = string
  default     = "us-east-1"
}

variable "secondary_region" {
  description = "Backup region (takes over via Route 53 failover, DB read replica)."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = var.secondary_region != var.primary_region
    error_message = "secondary_region must be different from primary_region."
  }
}

variable "primary_vpc_cidr" {
  description = "Primary VPC CIDR (matches the diagram)."
  type        = string
  default     = "10.0.0.0/16"
}

variable "secondary_vpc_cidr" {
  description = "Secondary VPC CIDR. Must not overlap the primary or on-prem ranges."
  type        = string
  default     = "10.1.0.0/16"

  validation {
    condition     = var.secondary_vpc_cidr != var.primary_vpc_cidr
    error_message = "secondary_vpc_cidr must not equal primary_vpc_cidr."
  }
}

# =============================================================================
# Access
# =============================================================================

variable "allowed_cidrs" {
  description = <<-EOT
    CIDRs that may open the website (ALB port 80). Leave empty to auto-detect
    the public IP of the machine running Terraform (via checkip.amazonaws.com).
    Add your audience's network here if others need to open the page.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "Every allowed_cidrs entry must be a valid CIDR, e.g. 203.0.113.10/32."
  }

  validation {
    condition     = !contains(var.allowed_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not allowed. List the specific networks that need access."
  }
}

# =============================================================================
# Compute and database
# =============================================================================

variable "instance_type" {
  description = "EC2 type for web and app servers."
  type        = string
  default     = "t3.micro"
}

variable "db_instance_class" {
  description = "RDS instance class for primary and replica."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_multi_az" {
  description = "Multi-AZ standby for the primary DB (the diagram's 'MySQL Standby')."
  type        = bool
  default     = true
}

variable "db_engine_version" {
  description = "MySQL major version."
  type        = string
  default     = "8.4"
}

variable "db_username" {
  description = "Master username for MySQL."
  type        = string
  default     = "univenadmin"
}

# =============================================================================
# DNS failover
# =============================================================================

variable "domain_name" {
  description = <<-EOT
    Hosted zone domain. If you don't own it, the zone still works for the demo:
    query Route 53's name servers directly (scripts/check-dns.sh does this).
  EOT
  type        = string
  default     = "univen-dr-demo.com"
}

variable "existing_hosted_zone_id" {
  description = "Use an existing public hosted zone (e.g. a domain you own) instead of creating one."
  type        = string
  default     = null
}

variable "app_subdomain" {
  description = "Record name for the failover endpoint: <app_subdomain>.<domain_name>."
  type        = string
  default     = "app"
}

variable "health_check_regions" {
  description = "Route 53 health-checker regions (minimum 3). The ALB only allows these checkers' IPs."
  type        = list(string)
  default     = ["us-east-1", "us-west-1", "us-west-2"]

  validation {
    condition     = length(var.health_check_regions) >= 3
    error_message = "Route 53 needs at least 3 health checker regions."
  }
}

# =============================================================================
# Hybrid VPN
# =============================================================================

variable "enable_vpn" {
  description = "Create the VGW + 2 site-to-site VPN connections (about $0.10/hour). Set false to save cost."
  type        = bool
  default     = true
}

variable "customer_gateway_ips" {
  description = <<-EOT
    Public IPs of the on-prem edge routers (one per ISP, as in the diagram).
    Defaults are RFC 5737 documentation addresses: tunnels will stay DOWN,
    which is expected when on-prem is simulated in Packet Tracer.
  EOT
  type        = map(string)
  default = {
    isp-a = "203.0.113.10"
    isp-b = "198.51.100.10"
  }
}

variable "onprem_bgp_asn" {
  description = "BGP ASN of the on-prem edge routers."
  type        = number
  default     = 65000
}

# =============================================================================
# Monitoring
# =============================================================================

variable "alert_email" {
  description = "Optional email for CloudWatch alarm notifications (confirm the SNS email)."
  type        = string
  default     = null
}
