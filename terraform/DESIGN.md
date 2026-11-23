# Design and Cost

Design rationale, architecture and estimated monthly cost of the FastAPI on
ECS Fargate stack. For deploy, verify and cleanup steps see [README.md](README.md).

## Architecture

![Architecture diagram](docs/architecture.svg)

Request path: Client → Internet Gateway → ALB (public subnets) → ECS Fargate
task (private subnets, port 8000) → RDS PostgreSQL primary (port 5432).

| Layer | Resource | Module |
|---|---|---|
| Network | VPC, 2+ public and 2+ private subnets, IGW, NAT, route tables | `modules/vpc` |
| Edge | Application Load Balancer, target group, HTTP (and optional HTTPS) listeners | `modules/alb` |
| Compute | ECS cluster, Fargate service, task definition, CPU autoscaling | `modules/ecs` |
| Image | ECR repository with scan-on-push and retention | `modules/ecr` |
| Data | RDS PostgreSQL primary (Multi-AZ); read replica deferred | `modules/rds` |
| Secrets | RDS-managed master secret in Secrets Manager | `modules/rds` |
| Observability | CloudWatch log group (`/ecs/<name>`) | `modules/ecs` |

The icons are from the AWS Architecture Icons set as bundled in the open-source
`diagrams` Python package. Use is subject to AWS's icon terms.

## Design decisions

### Network
- **Two AZs minimum, enforced.** `az_count` has a validation (`>= 2`), and the
  VPC module rejects any CIDR list whose length differs from the AZ count.
  One AZ loss must not take the service down.
- **Public subnets hold only the ALB and NAT. Tasks and databases are private.**
  Nothing that runs code or stores data has a public IP.
- **Stable subnet addressing.** Public subnets use `/24` index `0..n-1`, private
  ones start at index `100`, so adding an AZ later never renumbers existing subnets.
- **One shared NAT by default** (`single_nat_gateway = true`). It is the largest
  fixed cost after compute; the trade-off is that an AZ failure of the NAT cuts
  egress for every private subnet. Set `false` for one NAT per AZ.

### Compute
- **Fargate** removes node patching and capacity planning for a small stateless API.
- **Tasks register by IP** (`target_type = "ip"`), which `awsvpc` networking requires.
- **ALB health check uses `/health`, not `/db-check`.** `/health` does not touch
  the database. If the database blips, a DB-dependent check would mark every task
  unhealthy at once and turn a short DB incident into a full outage. `/db-check`
  stays available for humans and monitoring.
- **Safe deployments.** The deployment circuit breaker rolls back a bad image or
  config automatically, and a 60 s health-check grace period lets the app start.
- **Autoscaling** tracks average CPU at 60 % between `desired_count` and `max_count`.
  Terraform ignores `desired_count` after creation so an `apply` never fights the
  autoscaler.
- **CPU architecture is explicit** (`cpu_architecture`). The image must be built
  for the same platform, otherwise tasks fail with `exec format error`.

### Database
- **RDS instead of a Postgres container.** Fargate has no durable local volume.
- **Multi-AZ primary plus one read replica.** The Multi-AZ standby is synchronous
  and gives automatic failover, but it cannot serve queries. The replica is
  asynchronous and gives the "1 write, 1 read" shape. They solve different problems.
  **The replica is deferred:** RDS refuses to create a read replica from a source
  whose master password is managed by Secrets Manager (see Secrets below). The
  diagram marks it as deferred. Report with AWS references and options:
  [docs/read-replica-deferred.md](docs/read-replica-deferred.md).
- **Private, encrypted, no public access.** `publicly_accessible = false`,
  `storage_encrypted = true`, subnet group on private subnets only.
- **Safe-by-default knobs for dev, strict for prod.** `deletion_protection`
  defaults to `false` and skips the final snapshot for easy teardown; production
  should set `db_deletion_protection = true`.

### Secrets
- **RDS generates and stores the password** (`manage_master_user_password`). It
  never appears in Terraform code, `tfvars` or state.
- **ECS injects the password at task start** through the task definition `secrets`
  block, so it is not in the image or in plain-text environment variables.

### IAM and security groups (least privilege)
- **Execution role** (used by the ECS agent) has a scoped inline policy instead
  of the broad AWS-managed one: image pull only from this ECR repository, log
  writes only to this log group, secret read only for the DB secret.
  `ecr:GetAuthorizationToken` is the one `*` resource because AWS does not support
  scoping it.
- **Task role** (used by the application code) is empty because the app calls no
  AWS APIs. It exists so permissions can be added later without redesign.
- **Security groups reference each other, not CIDRs.**

  | From | To | Port |
  |---|---|---|
  | Internet | ALB SG | 80 / 443 |
  | ALB SG | Tasks SG | 8000 |
  | Tasks SG | DB SG | 5432 |
  | Tasks SG | Internet via NAT | 443 only |

  The ALB has no other egress; the DB has no egress at all.

### Observability
- Container logs go to CloudWatch with the `awslogs` driver, 30-day retention.
- CPU-based autoscaling is the only automation today. There are no alarms yet
  (see below).

### Code organisation
- Reusable modules with typed, validated variables and explicit outputs. The root
  module only wires modules together. Cross-module dependencies go through
  outputs, never through hard-coded IDs.

## Estimated monthly cost

Assumptions: `us-east-1`, on-demand, Linux x86, 730 hours/month, defaults of this
repo (2 AZs, 2 tasks of 0.25 vCPU / 0.5 GB, `db.t4g.micro`, 20 GB gp3), 20 GB NAT
traffic, about 1 LCU, 1 GB of logs. Data transfer out stays inside the 100 GB/month
free allowance.

| Item | Basis | USD / month |
|---|---|---:|
| NAT Gateway (1) | $0.045/h | 32.85 |
| NAT data processing | 20 GB × $0.045 | 0.90 |
| Public IPv4 (NAT EIP + 2 ALB IPs) | 3 × $0.005/h | 10.95 |
| Application Load Balancer | $0.0225/h | 16.43 |
| ALB capacity (LCU) | ~1 LCU × $0.008/h | 5.84 |
| ECS Fargate, 2 tasks | $0.04048/vCPU-h, $0.004445/GB-h | 18.02 |
| RDS primary, Multi-AZ `db.t4g.micro` | $0.032/h | 23.36 |
| RDS primary storage, 20 GB gp3, Multi-AZ | $0.23/GB | 4.60 |
| Secrets Manager | 1 secret | 0.40 |
| CloudWatch Logs | 1 GB ingest + storage | 0.53 |
| ECR | ~0.5 GB | 0.05 |
| VPC, IGW, security groups, IAM, autoscaling | free | 0.00 |
| **Total (default)** | | **≈ 114** |

| Scenario | How | USD / month |
|---|---|---:|
| Default (this repo) | as above | ≈ 114 |
| Dev-lite | `-var db_multi_az=false` | ≈ 100 |
| Higher availability | `-var single_nat_gateway=false` (one NAT + EIP per AZ) | ≈ 150 |
| With read replica (once re-enabled) | `db.t4g.micro` replica + 20 GB gp3 | ≈ 128 |

Each extra Fargate task added by autoscaling costs about $9/month while it runs.
The fixed network cost (NAT, ALB, public IPv4) is about $66 and dominates a small
workload, so cost is mostly independent of traffic at this scale.

> **These figures are estimates from unit prices recalled from AWS's public price
> list, not from a live price query.** Prices differ by region (for example
> `ap-southeast-1` is typically higher) and change over time. Check the final
> number in the [AWS Pricing Calculator](https://calculator.aws/) before relying on it.

## Not implemented yet

| Item | Status |
|---|---|
| HTTPS | Implemented for `aethrclothes.shop`: existing ACM certificates are looked up (not requested) in `us-east-1`, so the stack deploys there |
| CloudWatch alarms and notifications | Not implemented |
| Remote Terraform state (S3) | Implemented: S3 bucket and DynamoDB lock from `terraform/bootstrap` |
| CI/CD pipeline | Implemented: GitHub Actions with OIDC (`.github/workflows/deploy.yml`); not yet run end to end |
| Read replica ("1 read") | Deferred: not supported with an RDS-managed master password, see [docs/read-replica-deferred.md](docs/read-replica-deferred.md) |
| Secret rotation handling | Open risk: tasks read the password only at start, see README |
