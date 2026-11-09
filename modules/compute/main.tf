# -----------------------------------------------------------------------------
# Compute module (one per region)
#   ALB (public)  ->  2x Web (Apache, public subnets, AZ-a/b)
#                     -> /api/* reverse-proxied to 2x App (Apache+PHP, private)
#                         -> RDS MySQL (local region: primary or replica)
#
# Security posture:
#   * ALB :80 only from var.allowed_cidrs + Route 53 health-checker ranges
#   * Web :80 only from the ALB SG; App :80 only from the Web SG
#   * DB :3306 only from the App SG
#   * No SSH anywhere: shell access is via SSM Session Manager
#   * IMDSv2 required, encrypted root volumes
# -----------------------------------------------------------------------------

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  region = data.aws_region.current.name

  # Secret has the same name in every region; scope IAM to this region's copy.
  secret_arn_pattern = "arn:${data.aws_partition.current.partition}:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:${var.db_secret_name}-*"

  role_text = var.is_primary ? "primary" : "secondary"
}

# =============================================================================
# Security groups
# =============================================================================

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "ALB: HTTP from allowed CIDRs and Route 53 health checkers only"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-alb-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_allowed" {
  for_each          = toset(var.allowed_cidrs)
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from presenter / audience network"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_r53" {
  for_each          = toset(var.healthcheck_cidrs)
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from Route 53 health checkers"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_web" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to web tier"
  referenced_security_group_id = aws_security_group.web.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "web" {
  name        = "${var.name}-web-sg"
  description = "Web tier: HTTP from the ALB only"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-web-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "web_from_alb" {
  security_group_id            = aws_security_group.web.id
  description                  = "HTTP from ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "web_all" {
  security_group_id = aws_security_group.web.id
  description       = "Outbound: packages, SSM, app tier"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "app" {
  name        = "${var.name}-app-sg"
  description = "App tier: HTTP from the web tier only"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-app-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_web" {
  security_group_id            = aws_security_group.app.id
  description                  = "HTTP from web tier"
  referenced_security_group_id = aws_security_group.web.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Outbound via NAT / S3 endpoint: packages, SSM, Secrets Manager, RDS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db-sg"
  description = "MySQL from the app tier only"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-db-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from app tier"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
}

# =============================================================================
# IAM: instance role (SSM + this region's DB secret + optional S3 backup)
# =============================================================================

resource "aws_iam_role" "ec2" {
  name = "${var.name}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "app" {
  name = "${var.name}-app-access"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid      = "ReadDbSecretInThisRegion"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = local.secret_arn_pattern
      }],
      var.backup_bucket_name == null ? [] : [{
        Sid      = "WriteBackupsViaS3GatewayEndpointOnly"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${var.backup_bucket_name}/mysql/*"
        Condition = {
          StringEquals = { "aws:SourceVpce" = var.s3_endpoint_id }
        }
      }]
    )
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# =============================================================================
# App tier (private subnets)
# =============================================================================

resource "aws_instance" "app" {
  count = 2

  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = var.private_subnet_ids[count.index]
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/app-userdata.sh.tftpl", {
    region         = local.region
    region_label   = var.region_label
    role           = local.role_text
    is_primary     = var.is_primary
    db_host        = var.db_host
    db_name        = var.db_name
    db_secret_name = var.db_secret_name
    backup_bucket  = var.backup_bucket_name == null ? "" : var.backup_bucket_name
    status_php_b64 = filebase64("${path.module}/files/status.php")
    backup_php_b64 = filebase64("${path.module}/files/backup.php")
  })

  tags = {
    Name       = "${var.name}-app-${substr(var.azs[count.index], -1, 1)}"
    Tier       = "app"
    RegionRole = local.role_text
  }
}

# =============================================================================
# Web tier (public subnets, reachable only via the ALB SG)
# =============================================================================

resource "aws_instance" "web" {
  count = 2

  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = var.public_subnet_ids[count.index]
  vpc_security_group_ids = [aws_security_group.web.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/web-userdata.sh.tftpl", {
    app_ips = aws_instance.app[*].private_ip
    index_html_b64 = base64encode(templatefile("${path.module}/templates/index.html.tftpl", {
      region       = local.region
      region_label = var.region_label
      is_primary   = var.is_primary
    }))
  })

  tags = {
    Name       = "${var.name}-web-${substr(var.azs[count.index], -1, 1)}"
    Tier       = "web"
    RegionRole = local.role_text
  }
}

# =============================================================================
# Application Load Balancer
# =============================================================================

resource "aws_lb" "this" {
  name                       = "${var.name}-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.public_subnet_ids
  drop_invalid_header_fields = true

  tags = { Name = "${var.name}-alb" }
}

resource "aws_lb_target_group" "web" {
  name                 = "${var.name}-web-tg"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  deregistration_delay = 10

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group_attachment" "web" {
  count            = 2
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web[count.index].id
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}
