# Plan-time tests for modules/database (no AWS credentials needed).

mock_provider "aws" {}

variables {
  name              = "test"
  subnet_ids        = ["subnet-a", "subnet-b"]
  security_group_id = "sg-db"
}

run "primary_is_private_encrypted_multi_az" {
  command = plan
  module {
    source = "./modules/database"
  }
  variables {
    mode     = "primary"
    username = "admin"
    password = "not-a-real-password-123"
  }

  assert {
    condition     = length(aws_db_instance.primary) == 1 && length(aws_db_instance.replica) == 0
    error_message = "primary mode must create exactly the primary instance."
  }
  assert {
    condition     = aws_db_instance.primary[0].publicly_accessible == false
    error_message = "DB must never be publicly accessible."
  }
  assert {
    condition     = aws_db_instance.primary[0].storage_encrypted == true
    error_message = "DB storage must be encrypted."
  }
  assert {
    condition     = aws_db_instance.primary[0].multi_az == true
    error_message = "Primary should be Multi-AZ by default (diagram: MySQL standby)."
  }
  assert {
    condition     = aws_db_instance.primary[0].backup_retention_period >= 1
    error_message = "Backups must be on: cross-region replicas require them."
  }
  assert {
    condition     = aws_db_instance.primary[0].vpc_security_group_ids == toset(["sg-db"])
    error_message = "DB must only use the dedicated DB security group."
  }
}

run "replica_is_private_encrypted_with_own_key" {
  command = plan
  module {
    source = "./modules/database"
  }
  variables {
    mode          = "replica"
    source_db_arn = "arn:aws:rds:us-east-1:111122223333:db:test-mysql"
  }

  assert {
    condition     = length(aws_db_instance.replica) == 1 && length(aws_db_instance.primary) == 0
    error_message = "replica mode must create exactly the replica instance."
  }
  assert {
    condition     = aws_db_instance.replica[0].replicate_source_db == "arn:aws:rds:us-east-1:111122223333:db:test-mysql"
    error_message = "Replica must replicate from the primary's ARN."
  }
  assert {
    condition     = aws_db_instance.replica[0].publicly_accessible == false && aws_db_instance.replica[0].storage_encrypted
    error_message = "Replica must be private and encrypted."
  }
  assert {
    condition     = length(aws_kms_key.replica) == 1
    error_message = "Encrypted cross-region replica needs a KMS key in its own region."
  }
}

run "rejects_unknown_mode" {
  command = plan
  module {
    source = "./modules/database"
  }
  variables {
    mode = "standby"
  }
  expect_failures = [var.mode]
}
