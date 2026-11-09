output "arn" {
  value = local.db.arn
}

output "identifier" {
  value = local.db.identifier
}

output "address" {
  description = "DNS name of the DB endpoint (contains the region, e.g. ...us-west-2.rds.amazonaws.com)."
  value       = local.db.address
}

output "port" {
  value = local.db.port
}
