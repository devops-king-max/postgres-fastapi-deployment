data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Carve /24s out of the VPC CIDR: public use indexes 0..n-1, private use a
  # separate range starting at 100 so adding AZs never shifts existing subnets.
  public_subnet_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 100)]
}

module "vpc" {
  source = "./modules/vpc"

  name                 = var.name
  vpc_cidr             = var.vpc_cidr
  azs                  = local.azs
  public_subnet_cidrs  = local.public_subnet_cidrs
  private_subnet_cidrs = local.private_subnet_cidrs
  single_nat_gateway   = var.single_nat_gateway
  tags                 = var.tags
}

module "ecr" {
  source = "./modules/ecr"

  name = var.name
  tags = var.tags
}

module "alb" {
  source = "./modules/alb"

  name              = var.name
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  target_port       = var.container_port
  certificate_arn   = var.certificate_arn
  tags              = var.tags
}

module "rds" {
  source = "./modules/rds"

  name                       = var.name
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_subnet_ids
  allowed_security_group_ids = [module.ecs.tasks_security_group_id]
  multi_az                   = var.db_multi_az
  create_read_replica        = var.db_create_read_replica
  deletion_protection        = var.db_deletion_protection
  skip_final_snapshot        = !var.db_deletion_protection
  tags                       = var.tags
}

module "ecs" {
  source = "./modules/ecs"

  name               = var.name
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  container_image  = "${module.ecr.repository_url}:${var.image_tag}"
  container_port   = var.container_port
  cpu              = var.task_cpu
  memory           = var.task_memory
  cpu_architecture = var.cpu_architecture
  desired_count    = var.desired_count
  min_capacity     = var.desired_count
  max_capacity     = var.max_count

  ecr_repository_arns        = [module.ecr.repository_arn]
  database_security_group_id = module.rds.security_group_id

  environment = merge(
    {
      APP_NAME    = var.name
      APP_ENV     = var.environment
      APP_VERSION = var.image_tag
      DB_HOST     = module.rds.address
      DB_PORT     = tostring(module.rds.port)
      DB_NAME     = module.rds.db_name
      DB_USER     = module.rds.username
    },
    # The current app only reads DB_HOST; DB_READ_HOST is provided for read
    # traffic once the app routes SELECTs to it.
    var.db_create_read_replica ? { DB_READ_HOST = module.rds.read_address } : {}
  )

  # The password stays in Secrets Manager; ECS injects it at task start.
  secrets = {
    DB_PASSWORD = {
      secret_arn = module.rds.master_user_secret_arn
      json_key   = "password"
    }
  }

  target_group_arn      = module.alb.target_group_arn
  alb_security_group_id = module.alb.security_group_id
  tags                  = var.tags

  # The target group must be attached to a listener before the service
  # registers with it, otherwise ECS rejects the service.
  depends_on = [module.alb]
}
