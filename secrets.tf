# -----------------------------------------------------------------------------
# DB credentials
#   * Password is generated, never written in code.
#   * One secret per region with the same name and value, so the backup region
#     can read credentials even when Region 1 (and its Secrets Manager) is down.
#   * Note: the generated password is stored in Terraform state, so keep the
#     state file private (it is git-ignored).
# -----------------------------------------------------------------------------

resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!#%^*-_=+" # RDS forbids / @ " and spaces
}

locals {
  db_secret_value = jsonencode({
    username = var.db_username
    password = random_password.db.result
  })
}

resource "aws_secretsmanager_secret" "db_primary" {
  provider                = aws.primary
  name                    = local.db_secret_name
  description             = "UNIVEN demo MySQL credentials (primary region copy)"
  recovery_window_in_days = 0 # demo: allow immediate re-create after destroy
}

resource "aws_secretsmanager_secret_version" "db_primary" {
  provider      = aws.primary
  secret_id     = aws_secretsmanager_secret.db_primary.id
  secret_string = local.db_secret_value
}

resource "aws_secretsmanager_secret" "db_secondary" {
  provider                = aws.secondary
  name                    = local.db_secret_name
  description             = "UNIVEN demo MySQL credentials (backup region copy)"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_secondary" {
  provider      = aws.secondary
  secret_id     = aws_secretsmanager_secret.db_secondary.id
  secret_string = local.db_secret_value
}
