# -----------------------------------------------------------------------------
# CloudWatch: alarms + one dashboard covering both regions
# Route 53 health check metrics are only published in us-east-1, so the
# health-check alarm uses the aws.use1 provider (see providers.tf).
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  count    = var.alert_email == null ? 0 : 1
  provider = aws.use1
  name     = "${var.project_name}-dr-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == null ? 0 : 1
  provider  = aws.use1
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  alarm_actions = var.alert_email == null ? [] : [aws_sns_topic.alerts[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "primary_health_check" {
  provider            = aws.use1
  alarm_name          = "${local.name_primary}-route53-health-check-failed"
  alarm_description   = "Region 1 ALB health check is failing: Route 53 is failing over to the backup region."
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  dimensions          = { HealthCheckId = aws_route53_health_check.primary.id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "primary_healthy_hosts" {
  provider            = aws.primary
  alarm_name          = "${local.name_primary}-alb-no-healthy-hosts"
  alarm_description   = "No healthy web servers behind the Region 1 ALB."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = module.compute_primary.alb_arn_suffix, TargetGroup = module.compute_primary.target_group_arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
}

resource "aws_cloudwatch_metric_alarm" "secondary_healthy_hosts" {
  provider            = aws.secondary
  alarm_name          = "${local.name_secondary}-alb-no-healthy-hosts"
  alarm_description   = "No healthy web servers behind the backup-region ALB."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = module.compute_secondary.alb_arn_suffix, TargetGroup = module.compute_secondary.target_group_arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
}

resource "aws_cloudwatch_dashboard" "dr" {
  provider       = aws.primary
  dashboard_name = "${var.project_name}-multi-region-dr"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title   = "Route 53 health check - Region 1 (1 = healthy)"
          region  = "us-east-1"
          stat    = "Minimum"
          period  = 60
          metrics = [["AWS/Route53", "HealthCheckStatus", "HealthCheckId", aws_route53_health_check.primary.id]]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Healthy web hosts per region"
          stat   = "Minimum"
          period = 60
          region = var.primary_region
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", module.compute_primary.target_group_arn_suffix, "LoadBalancer", module.compute_primary.alb_arn_suffix, { region = var.primary_region, label = "Region 1 (${var.primary_region})" }],
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", module.compute_secondary.target_group_arn_suffix, "LoadBalancer", module.compute_secondary.alb_arn_suffix, { region = var.secondary_region, label = "Backup (${var.secondary_region})" }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "ALB requests per region"
          stat   = "Sum"
          period = 60
          region = var.primary_region
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", module.compute_primary.alb_arn_suffix, { region = var.primary_region, label = "Region 1" }],
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", module.compute_secondary.alb_arn_suffix, { region = var.secondary_region, label = "Backup" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "Cross-region replica lag (seconds)"
          stat   = "Maximum"
          period = 60
          region = var.secondary_region
          metrics = [
            ["AWS/RDS", "ReplicaLag", "DBInstanceIdentifier", module.db_secondary.identifier, { region = var.secondary_region }]
          ]
        }
      }
    ]
  })
}
