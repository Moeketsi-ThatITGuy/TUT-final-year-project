output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "region" {
  value = data.aws_region.current.name
}

output "azs" {
  value = local.azs
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "public_subnet_cidrs" {
  value = aws_subnet.public[*].cidr_block
}

output "private_subnet_cidrs" {
  value = aws_subnet.private[*].cidr_block
}

output "private_route_table_ids" {
  value = [aws_route_table.private.id]
}

output "s3_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}

output "nat_public_ip" {
  value = aws_eip.nat.public_ip
}
