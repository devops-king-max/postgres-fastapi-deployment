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

# Generated only when no password is supplied (var.password null or empty).
# Alphanumeric, so it never hits the characters RDS rejects (/ " @ and space).
resource "random_password" "master" {
  length  = 32
  special = false
}

locals {
  # coalesce skips null and "", so an unset GitHub secret (empty TF_VAR) falls
  # back to the generated password instead of failing.
  master_password = coalesce(var.password, random_password.master.result)
}

# Terraform sets the password itself (manage_master_user_password = false):
# an RDS instance read replica cannot be created when RDS manages the master
# password (docs/read-replica-deferred.md). The cost of this choice: the
# password is stored in Terraform state, and nothing rotates it.
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
  password = local.master_password

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  # Read replicas need automated backups on the source.
  backup_retention_period    = var.backup_retention_days
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-db-final"

  tags = merge(var.tags, { Role = "primary" })

  lifecycle {
    precondition {
      condition     = !var.create_read_replica || var.backup_retention_days > 0
      error_message = "A read replica needs automated backups on the primary (backup_retention_days > 0)."
    }
  }
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

# Credentials for the application, in the same JSON shape RDS uses for its own
# managed secret, so ECS keeps reading the "password" key.
resource "aws_secretsmanager_secret" "db" {
  name_prefix = "${var.name}-db-"
  description = "Master credentials of ${aws_db_instance.this.identifier} (set by Terraform)."
  # Delete at once on destroy, so a redeploy never waits on a pending deletion.
  recovery_window_in_days = 0

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    engine   = "postgres"
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    dbname   = var.db_name
    username = var.username
    password = local.master_password
  })
}
