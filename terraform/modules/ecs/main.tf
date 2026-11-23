data "aws_region" "current" {}

locals {
  secret_arns = distinct([for s in values(var.secrets) : s.secret_arn])
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# ---- IAM ----
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: used by the ECS agent (pull image, write logs, fetch secrets).
resource "aws_iam_role" "execution" {
  name_prefix        = "${var.name}-exec-"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = var.tags
}

# Scoped replacement for the AWS-managed AmazonECSTaskExecutionRolePolicy, which
# grants ecr:* reads and logs:* writes on every resource. Here each action is
# limited to this service's repository, log group and secrets.
data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "EcrAuthToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource-level scoping
  }

  statement {
    sid = "EcrPullImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = var.ecr_repository_arns
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  dynamic "statement" {
    for_each = length(var.secrets) > 0 ? [1] : []

    content {
      sid       = "ReadSecrets"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = local.secret_arns
    }
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# Task role: what the application code itself may do in AWS. The app calls no
# AWS APIs, so it gets an empty role (least privilege) that is ready to extend.
resource "aws_iam_role" "task" {
  name_prefix        = "${var.name}-task-"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = var.tags
}

# ---- Networking ----
resource "aws_security_group" "tasks" {
  name_prefix = "${var.name}-tasks-"
  description = "ECS tasks: ingress from the ALB only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-tasks" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_alb" {
  security_group_id            = aws_security_group.tasks.id
  referenced_security_group_id = var.alb_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  description                  = "App port from ALB"
}

# Egress is limited to what the task really does: HTTPS to AWS APIs (ECR,
# Secrets Manager, CloudWatch Logs, reached through the NAT) and PostgreSQL to
# the database security group.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.tasks.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS to AWS APIs via NAT"
}

resource "aws_vpc_security_group_egress_rule" "database" {
  security_group_id            = aws_security_group.tasks.id
  referenced_security_group_id = var.database_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL"
}

# The ALB side of the pair lives here (not in the alb module) so that both rules
# are owned by the module that knows the tasks, without a module cycle.
resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = var.alb_security_group_id
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  description                  = "ALB to tasks"
}

# ---- Task definition & service ----
resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([{
    name      = var.name
    image     = var.container_image
    essential = true

    portMappings = [{
      containerPort = var.container_port
      protocol      = "tcp"
    }]

    environment = [for k, v in var.environment : { name = k, value = v }]

    secrets = [for k, s in var.secrets : {
      name      = k
      valueFrom = s.json_key == null ? s.secret_arn : "${s.secret_arn}:${s.json_key}::"
    }]

    # No container-level health check: the python:slim image ships no curl, and
    # the ALB already probes /health and replaces unhealthy tasks.
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.this.name
        awslogs-region        = data.aws_region.current.name
        awslogs-stream-prefix = "app"
      }
    }
  }])

  tags = var.tags
}

resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Gives the app time to start (and run init_db) before the ALB can fail it.
  health_check_grace_period_seconds = 60

  # A bad image/config rolls back automatically instead of looping forever.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = var.name
    container_port   = var.container_port
  }

  # Autoscaling owns the task count after creation; without this every apply
  # would reset it to desired_count.
  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = var.tags
}

# ---- Autoscaling ----
resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
  min_capacity       = var.min_capacity
  max_capacity       = var.max_capacity
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  resource_id        = aws_appautoscaling_target.this.resource_id

  target_tracking_scaling_policy_configuration {
    target_value = var.cpu_target_percent

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
