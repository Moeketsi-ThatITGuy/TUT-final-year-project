variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "route_table_ids" {
  description = "Route tables that should learn on-prem routes over BGP."
  type        = list(string)
}

variable "customer_gateways" {
  description = "Map of CGW name => public IP of the on-prem edge router (one per ISP)."
  type        = map(string)
}

variable "customer_bgp_asn" {
  description = "On-prem BGP ASN (private range)."
  type        = number
  default     = 65000
}

variable "amazon_side_asn" {
  description = "AWS-side BGP ASN on the VGW."
  type        = number
  default     = 64512
}
