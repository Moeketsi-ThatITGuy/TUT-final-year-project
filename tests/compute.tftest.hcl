# Plan-time security tests for modules/compute (no AWS credentials needed).

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
}

variables {
  name               = "test-primary"
  is_primary         = true
  region_label       = "REGION 1 - PRIMARY"
  vpc_id             = "vpc-123"
  azs                = ["us-east-1a", "us-east-1b"]
  public_subnet_ids  = ["subnet-pa", "subnet-pb"]
  private_subnet_ids = ["subnet-xa", "subnet-xb"]
  allowed_cidrs      = ["203.0.113.5/32"]
  healthcheck_cidrs  = ["54.243.31.192/26", "54.183.255.128/26"]
  db_host            = "test-primary-mysql.abc.us-east-1.rds.amazonaws.com"
  db_secret_name     = "univen-db-credentials"
  backup_bucket_name = "univen-db-backup-111122223333-us-east-1"
  s3_endpoint_id     = "vpce-123"
}

run "alb_ingress_is_restricted" {
  command = plan
  module {
    source = "./modules/compute"
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb_from_allowed) == 1 && length(aws_vpc_security_group_ingress_rule.alb_from_r53) == 2
    error_message = "ALB should only allow the presenter CIDR plus Route 53 health checkers."
  }
  assert {
    condition = alltrue(concat(
      [for r in aws_vpc_security_group_ingress_rule.alb_from_allowed : r.cidr_ipv4 != "0.0.0.0/0" && r.from_port == 80],
      [for r in aws_vpc_security_group_ingress_rule.alb_from_r53 : r.cidr_ipv4 != "0.0.0.0/0" && r.from_port == 80],
    ))
    error_message = "No ALB ingress rule may be 0.0.0.0/0, and only port 80 is opened."
  }
}

run "tiers_only_trust_the_tier_in_front" {
  command = plan
  module {
    source = "./modules/compute"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.web_from_alb.cidr_ipv4 == null
    error_message = "Web tier must accept traffic from the ALB security group, not a CIDR."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.app_from_web.cidr_ipv4 == null
    error_message = "App tier must accept traffic from the web security group, not a CIDR."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.db_from_app.cidr_ipv4 == null && aws_vpc_security_group_ingress_rule.db_from_app.from_port == 3306
    error_message = "DB must accept 3306 from the app security group only."
  }
}

run "instances_are_hardened" {
  command = plan
  module {
    source = "./modules/compute"
  }

  assert {
    condition     = alltrue([for i in concat(aws_instance.web, aws_instance.app) : i.metadata_options[0].http_tokens == "required"])
    error_message = "IMDSv2 must be required on every instance."
  }
  assert {
    condition     = alltrue([for i in concat(aws_instance.web, aws_instance.app) : i.root_block_device[0].encrypted])
    error_message = "Root volumes must be encrypted."
  }
  assert {
    condition     = aws_instance.app[0].subnet_id == "subnet-xa" && aws_instance.app[1].subnet_id == "subnet-xb"
    error_message = "App servers must be in the private subnets, one per AZ."
  }
  assert {
    condition     = aws_instance.web[0].subnet_id == "subnet-pa" && aws_instance.web[1].subnet_id == "subnet-pb"
    error_message = "Web servers must be in the public subnets, one per AZ."
  }
}

run "iam_is_least_privilege" {
  command = plan
  module {
    source = "./modules/compute"
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.app.policy).Statement[0].Resource == "arn:aws:secretsmanager:us-east-1:111122223333:secret:univen-db-credentials-*"
    error_message = "Secret access must be scoped to this region's DB secret only."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.app.policy).Statement[1].Condition.StringEquals["aws:SourceVpce"] == "vpce-123"
    error_message = "S3 backup writes must be restricted to the S3 Gateway endpoint."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.app.policy).Statement[1].Action == ["s3:PutObject"]
    error_message = "Backups need PutObject only."
  }
}

run "secondary_has_no_backup_permission" {
  command = plan
  module {
    source = "./modules/compute"
  }
  variables {
    name               = "test-secondary"
    is_primary         = false
    region_label       = "BACKUP REGION"
    backup_bucket_name = null
    s3_endpoint_id     = null
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.app.policy).Statement) == 1
    error_message = "Backup region should only be able to read its DB secret."
  }
}

run "rejects_world_open_alb" {
  command = plan
  module {
    source = "./modules/compute"
  }
  variables {
    allowed_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.allowed_cidrs]
}
