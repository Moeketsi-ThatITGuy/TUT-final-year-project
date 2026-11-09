# Plan-time tests for modules/network (no AWS credentials needed).

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  }
  mock_data "aws_region" {
    defaults = { name = "us-east-1" }
  }
}

run "subnets_match_the_diagram" {
  command = plan
  module {
    source = "./modules/network"
  }
  variables {
    name     = "test-primary"
    vpc_cidr = "10.0.0.0/16"
  }

  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.0.1.0/24" && aws_subnet.public[1].cidr_block == "10.0.3.0/24"
    error_message = "Public subnets must be 10.0.1.0/24 (AZ-a) and 10.0.3.0/24 (AZ-b)."
  }
  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.0.2.0/24" && aws_subnet.private[1].cidr_block == "10.0.4.0/24"
    error_message = "Private subnets must be 10.0.2.0/24 (AZ-a) and 10.0.4.0/24 (AZ-b)."
  }
  assert {
    condition     = aws_subnet.public[0].availability_zone != aws_subnet.public[1].availability_zone
    error_message = "Subnets must span two different AZs."
  }
  assert {
    condition     = alltrue([for s in aws_subnet.private : s.map_public_ip_on_launch != true])
    error_message = "Private subnets must not auto-assign public IPs."
  }
  assert {
    condition     = aws_route.private_nat.destination_cidr_block == "0.0.0.0/0"
    error_message = "Private route table needs a default route via NAT."
  }
  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" && aws_vpc_endpoint.s3.service_name == "com.amazonaws.us-east-1.s3"
    error_message = "S3 must use a (free) Gateway endpoint in the VPC's region."
  }
}

run "secondary_cidr_layout" {
  command = plan
  module {
    source = "./modules/network"
  }
  variables {
    name     = "test-secondary"
    vpc_cidr = "10.1.0.0/16"
  }

  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.1.1.0/24" && aws_subnet.private[1].cidr_block == "10.1.4.0/24"
    error_message = "Secondary VPC should mirror the layout in 10.1.0.0/16."
  }
}

run "rejects_non_16_cidr" {
  command = plan
  module {
    source = "./modules/network"
  }
  variables {
    name     = "bad"
    vpc_cidr = "10.0.0.0/24"
  }
  expect_failures = [var.vpc_cidr]
}
