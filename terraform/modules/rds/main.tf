resource "aws_security_group" "this" {
  name_prefix = "${var.name}-db-"
  description = "PostgreSQL access from allowed security groups only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-db" })

  lifecycle {
    create_before_destroy = true
  }
}

# Source-SG rules (not CIDRs): only the ECS tasks can reach the DB, even if
# their IPs change.
resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = { for idx, sg in var.allowed_security_group_ids : idx => sg }

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from application"
}

resource "aws_db_subnet_group" "this" {
  name_prefix = "${var.name}-"
  subnet_ids  = var.subnet_ids

  tags = merge(var.tags, { Name = "${var.name}-db" })
}

resource "aws_db_instance" "this" {
  identifier = "${var.name}-db"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.username
  # RDS generates the password and keeps it in Secrets Manager, so it never
  # lands in Terraform state or in a tfvars file.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  backup_retention_period    = var.backup_retention_days
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-db-final"

  tags = var.tags
}

# Read replica: the "1 read" node. The Multi-AZ standby of the primary is for
# failover only and cannot serve queries, so reads need a separate instance.
# It inherits engine, credentials, encryption and DB name from the primary.
resource "aws_db_instance" "replica" {
  count = var.create_read_replica ? 1 : 0

  identifier          = "${var.name}-db-replica"
  replicate_source_db = aws_db_instance.this.identifier

  instance_class    = var.instance_class
  storage_type      = "gp3"
  availability_zone = var.replica_availability_zone

  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = false

  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  # The primary owns backups and the final snapshot; a replica can be rebuilt.
  skip_final_snapshot = true
  deletion_protection = var.deletion_protection

  tags = merge(var.tags, { Role = "read-replica" })
}
