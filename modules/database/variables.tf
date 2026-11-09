variable "name" {
  description = "Name prefix (e.g. univen-primary)."
  type        = string
}

variable "mode" {
  description = "\"primary\" for the writable source DB, \"replica\" for a cross-region read replica."
  type        = string

  validation {
    condition     = contains(["primary", "replica"], var.mode)
    error_message = "mode must be \"primary\" or \"replica\"."
  }
}

variable "subnet_ids" {
  description = "Private subnet IDs for the DB subnet group (two AZs)."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group to attach to the DB (allows 3306 from the app tier only)."
  type        = string
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "engine_version" {
  description = "MySQL major version (primary only; the replica inherits it)."
  type        = string
  default     = "8.4"
}

variable "multi_az" {
  description = "Run a synchronous standby in a second AZ (primary only)."
  type        = bool
  default     = true
}

variable "db_name" {
  description = "Initial database name (primary only)."
  type        = string
  default     = "univen"
}

variable "username" {
  description = "Master username (primary only)."
  type        = string
  default     = null
}

variable "password" {
  description = "Master password (primary only). Pass from random_password, never a literal."
  type        = string
  default     = null
  sensitive   = true
}

variable "source_db_arn" {
  description = "ARN of the primary DB to replicate from (replica only)."
  type        = string
  default     = null
}
