variable "name" {
  description = "Name prefix (e.g. univen-primary). Keep it short: ALB/TG names max 32 chars."
  type        = string

  validation {
    condition     = length(var.name) <= 25
    error_message = "name must be 25 characters or fewer (ALB name limit)."
  }
}

variable "is_primary" {
  description = "True for the primary region (DB writable, runs backups)."
  type        = bool
}

variable "region_label" {
  description = "Human label shown on the web page, e.g. \"REGION 1 - PRIMARY\"."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "azs" {
  description = "The two AZ names the subnets are in (used for tags)."
  type        = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the ALB on port 80."
  type        = list(string)

  validation {
    condition     = !contains(var.allowed_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not allowed; list the specific networks that need access."
  }
}

variable "healthcheck_cidrs" {
  description = "Route 53 health-checker CIDRs allowed to reach the ALB on port 80."
  type        = list(string)
  default     = []
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "db_host" {
  description = "Hostname of the DB in THIS region (primary endpoint or replica endpoint)."
  type        = string
}

variable "db_name" {
  type    = string
  default = "univen"
}

variable "db_secret_name" {
  description = "Name of the Secrets Manager secret (same name exists in each region)."
  type        = string
}

variable "backup_bucket_name" {
  description = "S3 bucket for MySQL backups (primary region only; null disables)."
  type        = string
  default     = null
}

variable "s3_endpoint_id" {
  description = "S3 Gateway endpoint ID; backups are only allowed through it."
  type        = string
  default     = null
}
