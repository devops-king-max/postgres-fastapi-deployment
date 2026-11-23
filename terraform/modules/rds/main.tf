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

# Aurora PostgreSQL: one cluster volume replicated across three AZs, one writer
# and (instance_count - 1) readers. On writer failure Aurora promotes a reader,
# and the cluster (writer) endpoint follows it. Unlike an RDS instance read
# replica, Aurora readers work with an RDS-managed master password
# (docs/read-replica-deferred.md).
resource "aws_rds_cluster" "this" {
  cluster_identifier = "${var.name}-aurora"

  engine         = "aurora-postgresql"
  engine_version = var.engine_version

  database_name   = var.db_name
  master_username = var.username
  # RDS generates the password and keeps it in Secrets Manager, so it never
  # lands in Terraform state or in a tfvars file.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  storage_encrypted      = true

  backup_retention_period = var.backup_retention_days
  copy_tags_to_snapshot   = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-aurora-final"

  tags = var.tags

  lifecycle {
    # Instances apply minor upgrades automatically; without this, the next plan
    # would try to "downgrade" to the pinned minor and fail.
    ignore_changes = [engine_version]
  }
}

# Each instance goes to a different AZ, so losing one AZ leaves an instance to
# promote. Terraform creates the instances in parallel and Aurora picks the first
# writer (on the first deploy it was instance 2); promotion_tier only orders
# failover candidates. The writer can also move on every failover.
resource "aws_rds_cluster_instance" "this" {
  count = var.instance_count

  identifier         = "${var.name}-aurora-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.this.id
  engine             = aws_rds_cluster.this.engine
  engine_version     = aws_rds_cluster.this.engine_version
  instance_class     = var.instance_class

  availability_zone    = element(var.availability_zones, count.index)
  db_subnet_group_name = aws_db_subnet_group.this.name
  publicly_accessible  = false
  promotion_tier       = count.index

  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  tags = merge(var.tags, { Role = count.index == 0 ? "writer" : "reader" })

  lifecycle {
    ignore_changes = [engine_version]
  }
}
