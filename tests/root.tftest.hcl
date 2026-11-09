# Plan-time tests for the full two-region stack (no AWS credentials needed).

mock_provider "aws" {
  alias = "primary"
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b"] }
  }
  mock_data "aws_ip_ranges" {
    defaults = { cidr_blocks = ["54.243.31.192/26", "54.183.255.128/26"] }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_region" {
    defaults = { name = "us-east-1" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_route53_zone" {
    defaults = { name_servers = ["ns-1.awsdns-01.org"] }
  }
}

mock_provider "aws" {
  alias = "secondary"
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-west-2a", "us-west-2b"] }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0fedcba9876543210" }
  }
  mock_data "aws_region" {
    defaults = { name = "us-west-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
}

mock_provider "aws" {
  alias = "use1"
}

mock_provider "random" {}

mock_provider "http" {
  mock_data "http" {
    defaults = { response_body = "198.51.100.7\n" }
  }
}

run "auto_detects_presenter_ip" {
  command = plan
  variables {
    allowed_cidrs = [] # override any local terraform.tfvars
  }

  assert {
    condition     = length(output.allowed_cidrs) == 1 && output.allowed_cidrs[0] == "198.51.100.7/32"
    error_message = "With no allowed_cidrs, the caller's public IP /32 should be allowed."
  }
}

run "failover_routing_is_wired" {
  command = plan

  assert {
    condition     = aws_route53_record.app_primary.failover_routing_policy[0].type == "PRIMARY"
    error_message = "app record for Region 1 must be the PRIMARY failover record."
  }
  assert {
    condition     = aws_route53_record.app_secondary.failover_routing_policy[0].type == "SECONDARY"
    error_message = "app record for the backup region must be the SECONDARY failover record."
  }
  assert {
    condition     = aws_route53_record.app_primary.name == "app.univen-dr-demo.com" && aws_route53_record.app_secondary.name == "app.univen-dr-demo.com"
    error_message = "Both failover records must share the same name."
  }
  assert {
    condition     = aws_route53_record.app_primary.alias[0].evaluate_target_health && aws_route53_record.app_secondary.alias[0].evaluate_target_health
    error_message = "Alias records should evaluate ALB target health."
  }
  assert {
    condition     = aws_route53_health_check.primary.resource_path == "/health" && aws_route53_health_check.primary.type == "HTTP"
    error_message = "Health check must probe /health over HTTP."
  }
  assert {
    condition     = aws_route53_health_check.primary.request_interval == 10 && aws_route53_health_check.primary.failure_threshold == 2
    error_message = "Health check should be fast (10s x 2) for a quick demo failover."
  }
}

run "backup_bucket_is_private" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.backup.block_public_acls,
      aws_s3_bucket_public_access_block.backup.block_public_policy,
      aws_s3_bucket_public_access_block.backup.ignore_public_acls,
      aws_s3_bucket_public_access_block.backup.restrict_public_buckets,
    ])
    error_message = "All four S3 Block Public Access settings must be on."
  }
  assert {
    condition     = aws_s3_bucket_ownership_controls.backup.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs must be disabled on the backup bucket."
  }
}

run "secrets_exist_in_both_regions" {
  command = plan

  assert {
    condition     = aws_secretsmanager_secret.db_primary.name == aws_secretsmanager_secret.db_secondary.name
    error_message = "Each region needs its own copy of the DB secret under the same name."
  }
}

run "vpn_on_by_default" {
  command = plan

  assert {
    condition     = length(module.vpn) == 1
    error_message = "VPN should be created by default."
  }
}

run "vpn_can_be_disabled" {
  command = plan
  variables {
    enable_vpn = false
  }

  assert {
    condition     = length(module.vpn) == 0 && output.vpn_connections == {}
    error_message = "enable_vpn = false must not create any VPN resources."
  }
}

run "rejects_world_open_access" {
  command = plan
  variables {
    allowed_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.allowed_cidrs]
}

run "rejects_same_region_twice" {
  command = plan
  variables {
    primary_region   = "us-east-1"
    secondary_region = "us-east-1"
  }
  expect_failures = [var.secondary_region]
}
