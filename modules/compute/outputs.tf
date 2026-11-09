output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_zone_id" {
  value = aws_lb.this.zone_id
}

output "alb_arn_suffix" {
  value = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  value = aws_lb_target_group.web.arn_suffix
}

output "web_instance_ids" {
  value = aws_instance.web[*].id
}

output "app_instance_ids" {
  value = aws_instance.app[*].id
}

output "app_private_ips" {
  value = aws_instance.app[*].private_ip
}

output "db_security_group_id" {
  value = aws_security_group.db.id
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}
