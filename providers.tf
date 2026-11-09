# Two aliased providers: one per region. Credentials come from the normal AWS
# credential chain (AWS_PROFILE, env vars, SSO, ...) or var.aws_profile.

locals {
  common_tags = merge({
    Project   = var.project_name
    ManagedBy = "terraform"
    Demo      = "true"
  }, var.extra_tags)
}

provider "aws" {
  alias   = "primary"
  region  = var.primary_region
  profile = var.aws_profile

  default_tags {
    tags = merge(local.common_tags, { RegionRole = "primary" })
  }
}

provider "aws" {
  alias   = "secondary"
  region  = var.secondary_region
  profile = var.aws_profile

  default_tags {
    tags = merge(local.common_tags, { RegionRole = "secondary" })
  }
}

# Route 53 health-check metrics only exist in us-east-1, regardless of which
# regions you pick above. Used by monitoring.tf.
provider "aws" {
  alias   = "use1"
  region  = "us-east-1"
  profile = var.aws_profile

  default_tags {
    tags = local.common_tags
  }
}
