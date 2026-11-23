output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs, ordered like the azs input."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, ordered like the azs input."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "Availability Zones the subnets were created in."
  value       = var.azs
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs (empty when NAT is disabled)."
  value       = aws_nat_gateway.this[*].id
}

output "nat_public_ips" {
  description = "Elastic IPs of the NAT gateways, useful for allow-listing egress."
  value       = aws_eip.nat[*].public_ip
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway."
  value       = aws_internet_gateway.this.id
}

output "public_route_table_id" {
  description = "ID of the public route table."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "Private route table IDs, one per AZ."
  value       = aws_route_table.private[*].id
}
