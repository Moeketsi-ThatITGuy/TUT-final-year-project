variable "name" {
  description = "Name prefix for every resource in this VPC (e.g. univen-primary)."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR. Must be a /16 so the /24 subnet layout from the diagram fits."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be a valid /16 CIDR, e.g. 10.0.0.0/16."
  }
}
