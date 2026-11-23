# Alarms that notify people. ECS target tracking already creates its own
# scaling alarms; these are separate and exist only to page someone.

data "aws_region" "current" {}

resource "aws_sns_topic" "alarms" {
  name = "${var.name}-alarms"
  tags = var.tags
}

# Email subscriptions stay "PendingConfirmation" until the recipient clicks the
# link AWS sends. Unconfirmed addresses receive nothing.
resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alarm_emails)

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}

locals {
  actions = [aws_sns_topic.alarms.arn]

  alb_dims = { LoadBalancer = var.alb_arn_suffix }
  tg_dims  = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  ecs_dims = { ClusterName = var.ecs_cluster_name, ServiceName = var.ecs_service_name }
  db_dims  = { DBInstanceIdentifier = var.db_instance_identifier }

  # One definition per alarm. treat_missing_data: counts that are simply absent
  # when nothing goes wrong are notBreaching; "no data" for a liveness signal
  # (healthy hosts) is itself a failure, so it is breaching.
  alarms = {
    alb-5xx = {
      description = "ALB itself returned 5xx (no healthy target, timeouts)."
      namespace   = "AWS/ApplicationELB", metric = "HTTPCode_ELB_5XX_Count", dims = local.alb_dims
      statistic   = "Sum", period = 300, evaluation_periods = 1
      operator    = "GreaterThanOrEqualToThreshold", threshold = 10, missing = "notBreaching"
    }
    target-5xx = {
      description = "The application returned 5xx (for example /db-check 503 when the database is unreachable)."
      namespace   = "AWS/ApplicationELB", metric = "HTTPCode_Target_5XX_Count", dims = local.alb_dims
      statistic   = "Sum", period = 300, evaluation_periods = 1
      operator    = "GreaterThanOrEqualToThreshold", threshold = 10, missing = "notBreaching"
    }
    unhealthy-targets = {
      description = "At least one task fails the ALB health check (/health) for 3 minutes."
      namespace   = "AWS/ApplicationELB", metric = "UnHealthyHostCount", dims = local.tg_dims
      statistic   = "Maximum", period = 60, evaluation_periods = 3
      operator    = "GreaterThanOrEqualToThreshold", threshold = 1, missing = "notBreaching"
    }
    no-healthy-targets = {
      description = "No healthy task behind the ALB: the API is down."
      namespace   = "AWS/ApplicationELB", metric = "HealthyHostCount", dims = local.tg_dims
      statistic   = "Minimum", period = 60, evaluation_periods = 2
      operator    = "LessThanThreshold", threshold = 1, missing = "breaching"
    }
    ecs-cpu-high = {
      description = "Service CPU above 85% for 15 minutes even with autoscaling (at max_count, or scaling too slowly)."
      namespace   = "AWS/ECS", metric = "CPUUtilization", dims = local.ecs_dims
      statistic   = "Average", period = 300, evaluation_periods = 3
      operator    = "GreaterThanThreshold", threshold = 85, missing = "notBreaching"
    }
    ecs-memory-high = {
      description = "Service memory above 85% for 15 minutes; tasks risk being OOM-killed (autoscaling tracks CPU only)."
      namespace   = "AWS/ECS", metric = "MemoryUtilization", dims = local.ecs_dims
      statistic   = "Average", period = 300, evaluation_periods = 3
      operator    = "GreaterThanThreshold", threshold = 85, missing = "notBreaching"
    }
    db-cpu-high = {
      description = "Primary DB CPU above 80% for 15 minutes."
      namespace   = "AWS/RDS", metric = "CPUUtilization", dims = local.db_dims
      statistic   = "Average", period = 300, evaluation_periods = 3
      operator    = "GreaterThanThreshold", threshold = 80, missing = "notBreaching"
    }
    db-memory-low = {
      description = "Primary DB freeable memory below 128 MiB for 15 minutes (db.t4g.micro has 1 GiB)."
      namespace   = "AWS/RDS", metric = "FreeableMemory", dims = local.db_dims
      statistic   = "Minimum", period = 300, evaluation_periods = 3
      operator    = "LessThanThreshold", threshold = 134217728, missing = "notBreaching"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  dimensions          = each.value.dims
  statistic           = each.value.statistic
  period              = each.value.period
  evaluation_periods  = each.value.evaluation_periods
  comparison_operator = each.value.operator
  threshold           = each.value.threshold
  treat_missing_data  = each.value.missing

  alarm_actions = local.actions
  ok_actions    = local.actions

  tags = var.tags
}

# p95 needs extended_statistic, so it does not fit the map above.
resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name          = "${var.name}-latency-p95"
  alarm_description   = "95th percentile target response time above ${var.latency_p95_threshold_seconds}s for 15 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = local.alb_dims
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.latency_p95_threshold_seconds
  treat_missing_data  = "notBreaching"

  alarm_actions = local.actions
  ok_actions    = local.actions

  tags = var.tags
}

# ---- Synthetic check of /db-check ----
# The ALB health check uses /health, which never touches the database, so a DB
# outage (or a rotated password the running tasks do not have) does not make any
# target unhealthy. Route 53 calls /db-check from outside and alarms when it fails.
resource "aws_route53_health_check" "db_check" {
  count = var.health_check_fqdn != null ? 1 : 0

  fqdn              = var.health_check_fqdn
  type              = "HTTPS"
  port              = 443
  resource_path     = var.health_check_path
  request_interval  = 30
  failure_threshold = 3
  # Three checker regions (the minimum) keep the load on /db-check low:
  # about 6 requests per minute in total.
  regions = ["us-east-1", "us-west-2", "eu-west-1"]

  tags = merge(var.tags, { Name = "${var.name}-db-check" })
}

resource "aws_cloudwatch_metric_alarm" "db_check" {
  count = var.health_check_fqdn != null ? 1 : 0

  alarm_name          = "${var.name}-db-check-failing"
  alarm_description   = "https://${var.health_check_fqdn}${var.health_check_path} is failing: the API cannot reach the database. After a secret rotation, redeploy the ECS service."
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  dimensions          = { HealthCheckId = aws_route53_health_check.db_check[0].id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_actions = local.actions
  ok_actions    = local.actions

  tags = var.tags

  lifecycle {
    precondition {
      # Route 53 publishes health check metrics only in us-east-1.
      condition     = data.aws_region.current.name == "us-east-1"
      error_message = "The /db-check alarm must live in us-east-1, where Route 53 health check metrics are published."
    }
  }
}
