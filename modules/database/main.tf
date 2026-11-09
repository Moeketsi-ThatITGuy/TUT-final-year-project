# -----------------------------------------------------------------------------
# Database module
#   mode = "primary" -> RDS MySQL (Multi-AZ optional) that accepts writes
#   mode = "replica" -> cross-region read replica of the primary
#
# Both live in private subnets only, are encrypted, and accept 3306 only from
# the security group passed in (the app tier SG).
#
# DEMO SETTINGS: skip_final_snapshot = true and deletion_protection = false so
# `terraform destroy` cleans everything up. Do NOT copy these into production.
# -----------------------------------------------------------------------------

locals {
  is_primary = var.mode == "primary"
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db-subnets"
  subnet_ids = var.subnet_ids
  tags       = { Name = "${var.name}-db-subnets" }
}

# A cross-region encrypted replica must name a KMS key in ITS OWN region.
# A small customer-managed key avoids relying on alias/aws/rds already existing.
resource "aws_kms_key" "replica" {
  count                   = local.is_primary ? 0 : 1
  description             = "${var.name} RDS cross-region replica encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = { Name = "${var.name}-rds-kms" }
}

resource "aws_db_instance" "primary" {
  count = local.is_primary ? 1 : 0

  identifier     = "${var.name}-mysql"
  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.username
  password = var.password

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false

  # Read replicas need automated backups on the source.
  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  apply_immediately          = true

  # Demo-only teardown settings (see header comment).
  skip_final_snapshot = true
  deletion_protection = false

  tags = { Name = "${var.name}-mysql", Role = "primary" }
}

resource "aws_db_instance" "replica" {
  count = local.is_primary ? 0 : 1

  identifier          = "${var.name}-mysql-replica"
  replicate_source_db = var.source_db_arn
  instance_class      = var.instance_class

  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = aws_kms_key.replica[0].arn

  multi_az               = false
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false

  backup_retention_period    = 0
  auto_minor_version_upgrade = true
  apply_immediately          = true

  skip_final_snapshot = true
  deletion_protection = false

  tags = { Name = "${var.name}-mysql-replica", Role = "replica" }
}

locals {
  db = local.is_primary ? aws_db_instance.primary[0] : aws_db_instance.replica[0]
}
