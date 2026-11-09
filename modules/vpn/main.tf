# -----------------------------------------------------------------------------
# Site-to-site VPN (primary region): the "hybrid" link from the diagram
#   Virtual Private Gateway  <-- IPsec + BGP -->  Customer Gateway 1 (ISP A)
#                            <-- IPsec + BGP -->  Customer Gateway 2 (ISP B)
#
# Packet Tracer cannot terminate a real IPsec tunnel to AWS, so the tunnels
# will show DOWN. That is expected. Use the tunnel outputs / downloaded config
# to document the matching config on the Packet Tracer edge routers.
# -----------------------------------------------------------------------------

resource "aws_vpn_gateway" "this" {
  vpc_id          = var.vpc_id
  amazon_side_asn = var.amazon_side_asn
  tags            = { Name = "${var.name}-vgw" }
}

resource "aws_vpn_gateway_route_propagation" "private" {
  count          = length(var.route_table_ids)
  vpn_gateway_id = aws_vpn_gateway.this.id
  route_table_id = var.route_table_ids[count.index]
}

resource "aws_customer_gateway" "this" {
  for_each   = var.customer_gateways
  bgp_asn    = var.customer_bgp_asn
  ip_address = each.value
  type       = "ipsec.1"
  tags       = { Name = "${var.name}-cgw-${each.key}" }
}

resource "aws_vpn_connection" "this" {
  for_each            = var.customer_gateways
  vpn_gateway_id      = aws_vpn_gateway.this.id
  customer_gateway_id = aws_customer_gateway.this[each.key].id
  type                = "ipsec.1"
  static_routes_only  = false # dynamic routing with BGP

  tags = { Name = "${var.name}-vpn-${each.key}" }
}
