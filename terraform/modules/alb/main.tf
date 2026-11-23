locals {
  https_enabled = var.certificate_arn != null
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-alb-"
  description = "Public ingress to the application load balancer"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = var.ingress_cidr
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "HTTP"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  count = local.https_enabled ? 1 : 0

  security_group_id = aws_security_group.this.id
  cidr_ipv4         = var.ingress_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS"
}

# No egress rule here on purpose: the ECS module adds the single rule that lets
# the ALB reach the tasks on the container port. Until then the ALB sends nothing.

resource "aws_lb" "this" {
  name_prefix        = substr(var.name, 0, 6)
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.this.id]
  subnets            = var.public_subnet_ids

  drop_invalid_header_fields = true

  tags = merge(var.tags, { Name = "${var.name}-alb" })
}

resource "aws_lb_target_group" "this" {
  # name_prefix + create_before_destroy: a target group cannot be renamed or
  # re-ported in place while a listener references it.
  name_prefix = substr(var.name, 0, 6)
  port        = var.target_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  # Fargate awsvpc tasks register by IP, not by instance.
  target_type = "ip"

  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# Without a certificate: plain HTTP forwards to the app (dev only).
# With a certificate: HTTP redirects to HTTPS and HTTPS forwards.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = local.https_enabled ? "redirect" : "forward"
    target_group_arn = local.https_enabled ? null : aws_lb_target_group.this.arn

    dynamic "redirect" {
      for_each = local.https_enabled ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}
