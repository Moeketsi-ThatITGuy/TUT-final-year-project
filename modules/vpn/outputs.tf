output "vpn_gateway_id" {
  value = aws_vpn_gateway.this.id
}

output "connections" {
  description = "Non-secret tunnel details per ISP, for the Packet Tracer edge router config."
  value = {
    for k, c in aws_vpn_connection.this : k => {
      vpn_connection_id   = c.id
      customer_gateway_ip = aws_customer_gateway.this[k].ip_address
      tunnel1_outside_ip  = c.tunnel1_address
      tunnel1_inside_cidr = c.tunnel1_inside_cidr
      tunnel1_aws_bgp_ip  = c.tunnel1_vgw_inside_address
      tunnel1_cgw_bgp_ip  = c.tunnel1_cgw_inside_address
      tunnel2_outside_ip  = c.tunnel2_address
      tunnel2_inside_cidr = c.tunnel2_inside_cidr
      tunnel2_aws_bgp_ip  = c.tunnel2_vgw_inside_address
      tunnel2_cgw_bgp_ip  = c.tunnel2_cgw_inside_address
    }
  }
}

output "preshared_keys" {
  description = "Tunnel PSKs (sensitive). Read with: terraform output -json vpn_preshared_keys"
  sensitive   = true
  value = {
    for k, c in aws_vpn_connection.this : k => {
      tunnel1 = c.tunnel1_preshared_key
      tunnel2 = c.tunnel2_preshared_key
    }
  }
}
