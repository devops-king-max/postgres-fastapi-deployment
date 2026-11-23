# Design and Cost

Design rationale, architecture and estimated monthly cost of the FastAPI on
ECS Fargate stack. For deploy, verify and cleanup steps see [README.md](README.md).
A one-page summary is in [docs/design-decisions-and-costs.md](docs/design-decisions-and-costs.md).

## Architecture

![Architecture diagram](docs/architecture.svg)

Request path: Client → Internet Gateway → ALB (public subnets) → ECS Fargate
task (private subnets, port 8000) → RDS PostgreSQL primary (port 5432). A read
replica in the second AZ is reachable as `DB_READ_HOST`.

| Layer | Resource | Module |
|---|---|---|
| Network | VPC, 2+ public and 2+ private subnets, IGW, NAT, route tables | `modules/vpc` |
| Edge | Application Load Balancer, target group, HTTP (and optional HTTPS) listeners | `modules/alb` |
| Compute | ECS cluster, Fargate service, task definition, CPU autoscaling | `modules/ecs` |
| Image | ECR repository with scan-on-push and retention | `modules/ecr` |
| Data | RDS PostgreSQL: Multi-AZ primary (write) + 1 read replica in the second AZ | `modules/rds` |
| Secrets | Master credentials set by Terraform, stored in a Secrets Manager secret | `modules/rds` |
| Observability | CloudWatch log group (`/ecs/<name>`) | `modules/ecs` |
| Alerting | SNS topic (email), 10 CloudWatch alarms, Route 53 health check on `/db-check` | `modules/monitoring` |

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
- **Managed database instead of a Postgres container.** Fargate has no durable
  local volume.
- **RDS PostgreSQL: Multi-AZ primary + one read replica.** The primary takes
  every write; its Multi-AZ standby in another AZ is for failover only and serves
  no queries. The read replica (asynchronous, second AZ) is the "1 read" node and
  is injected as `DB_READ_HOST`.
- **Terraform sets the master password** (`manage_master_user_password = false`).
  RDS rejects an instance read replica when it manages the password in Secrets
  Manager itself, which is what failed on the first deploy. An Aurora cluster
  (writer + reader) avoided that, but at about $69/month more; this design goes
  back to the cheaper RDS instances. History, AWS references and the
  alternatives: [docs/read-replica-deferred.md](docs/read-replica-deferred.md).
- **Failover.** If the primary or its AZ fails, RDS promotes the standby,
  typically in one to two minutes, and the primary endpoint (`DB_HOST`) follows
  it, so the app needs no configuration change. The replica keeps replicating from
  the new primary.
- **`db.t4g.micro` and version 17.** The smallest Graviton class, enough for a
  small API. A major-only version lets RDS pick the current minor and apply minor
  upgrades automatically.
- **Private, encrypted, no public access.** `publicly_accessible = false`,
  `storage_encrypted = true`, subnet group on private subnets only.
- **Safe-by-default knobs for dev, strict for prod.** `deletion_protection`
  defaults to `false` and skips the final snapshot for easy teardown; production
  should set `db_deletion_protection = true`.

### Secrets
- **The password comes from the `DB_PASSWORD` GitHub secret** (`db_password`),
  or Terraform generates a 32-character one when it is unset. It is never in the
  code or a committed `tfvars` file, but it **is stored in Terraform state**, so
  the state bucket (private, encrypted, versioned) must be treated as secret.
- **Terraform writes the credentials to its own Secrets Manager secret**, in the
  same JSON shape RDS uses (`username`, `password`, `host`, `port`, `dbname`), and
  nothing rotates them. To change the password, update the GitHub secret and push
  a commit: Terraform modifies the primary in place, and the new image tag rolls
  out tasks that read the new value. Re-running a workflow keeps the old tag, so
  the running tasks keep the old password; force a new ECS deployment then.
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
- **Alarms notify through one SNS topic** (`<name>-alarms`) by email, on both
  ALARM and OK, so the recipient also learns when an incident is over.

  | Alarm | Signal | Fires when |
  |---|---|---|
  | `alb-5xx` | ALB `HTTPCode_ELB_5XX_Count` | ≥ 10 in 5 min (no healthy target, timeouts) |
  | `target-5xx` | ALB `HTTPCode_Target_5XX_Count` | ≥ 10 in 5 min (application errors, `/db-check` 503) |
  | `unhealthy-targets` | `UnHealthyHostCount` | ≥ 1 for 3 min |
  | `no-healthy-targets` | `HealthyHostCount` | < 1 for 2 min, or no data: the API is down |
  | `latency-p95` | `TargetResponseTime` p95 | > 1 s for 15 min |
  | `ecs-cpu-high` | ECS service `CPUUtilization` | > 85 % for 15 min (autoscaling is not keeping up) |
  | `ecs-memory-high` | ECS service `MemoryUtilization` | > 85 % for 15 min (autoscaling tracks CPU only) |
  | `db-cpu-high` | Primary `CPUUtilization` | > 80 % for 15 min |
  | `db-memory-low` | Primary `FreeableMemory` | < 128 MiB for 15 min (`db.t4g.micro` has 1 GiB) |
  | `db-check-failing` | Route 53 `HealthCheckStatus` | `https://<domain>/db-check` fails for 2 min |

- **Why a Route 53 check on `/db-check`.** The ALB health check uses `/health`,
  which never touches the database (see Compute). A database outage, or a changed
  password that running tasks do not have, therefore leaves every target healthy
  and no request-based alarm fires unless users happen to hit DB routes. Route 53
  calls `/db-check` from three regions every 30 s (about 6 requests per minute)
  and alarms within about two minutes. Route 53 publishes these metrics only in
  `us-east-1`, which a precondition enforces.
- Missing data is not a failure for counters (no 5xx is normal), but it is for
  `HealthyHostCount` and the health check: silence there means nothing is
  reporting.

### Code organisation
- Reusable modules with typed, validated variables and explicit outputs. The root
  module only wires modules together. Cross-module dependencies go through
  outputs, never through hard-coded IDs.

## Estimated monthly cost

Assumptions: `us-east-1`, on-demand, Linux x86, 730 hours/month, defaults of this
repo (2 AZs, 2 tasks of 0.25 vCPU / 0.5 GB, RDS `db.t4g.micro` Multi-AZ primary +
Single-AZ replica, 20 GB gp3 each), 20 GB NAT traffic, about 1 LCU, 1 GB of logs,
the monitoring module (10 alarms, one Route 53 HTTPS health check, SNS email).
Data transfer out stays inside the 100 GB/month free allowance.

All figures come from the AWS Pricing Calculator (estimate date 2026-11-23).
Each estimate was re-priced with "Update estimate" and the saved and recalculated
totals match. The RDS rows also match the AWS Price List API
(`aws pricing get-products`, `us-east-1`, PostgreSQL): `db.t4g.micro` $0.016/h
Single-AZ and $0.032/h Multi-AZ, gp3 storage $0.115/GB-month Single-AZ and
$0.23/GB-month Multi-AZ.

| Item | Input | USD / month |
|---|---|---:|
| NAT Gateway (VPC) | 1 gateway, 20 GB processed | 33.75 |
| Public IPv4 (VPC) | 3 in-use addresses (NAT EIP + 2 ALB IPs) | 10.95 |
| Application Load Balancer | 1 ALB, 1 GB/h processed, 1 new conn/s, 1 req/s (≈ 1 LCU) | 22.27 |
| AWS Fargate | 2 tasks × 730 h, 0.25 vCPU / 0.5 GB, Linux x86, 20 GB ephemeral | 18.02 |
| RDS primary | `db.t4g.micro` Multi-AZ (23.36), 20 GB gp3 Multi-AZ (4.60) | 27.96 |
| RDS read replica | `db.t4g.micro` Single-AZ (11.68), 20 GB gp3 (2.30) | 13.98 |
| Secrets Manager | 1 secret, 1,000 API calls | 0.41 |
| CloudWatch | 1 GB logs ingested and stored 1 month (0.50), 10 standard-resolution alarms (1.00) | 1.50 |
| ECR | 0.5 GB stored | 0.05 |
| Route 53 health check | 1 basic check of an AWS endpoint (free, first 50) + HTTPS option | 1.00 |
| SNS | 1,000 publishes, 1,000 email notifications (inside the free allowance) | 0.00 |
| VPC, IGW, security groups, IAM, autoscaling | not billed | 0.00 |
| **Total (default)** | [calculator estimate](https://calculator.aws/#/estimate?id=dfe5fe4bc0dca632d50460a815d67e4753fa13eb) | **129.89** |

| Scenario | How | USD / month | Calculator estimate |
|---|---|---:|---|
| Default (this repo) | as above | 129.89 | [link](https://calculator.aws/#/estimate?id=dfe5fe4bc0dca632d50460a815d67e4753fa13eb) |
| Dev-lite | `-var db_multi_az=false -var db_create_read_replica=false` (one Single-AZ instance, 13.98) | 101.93 | [link](https://calculator.aws/#/estimate?id=3ab6ff9a9f37bfa139b69a03a98bbc3ea247268e) |
| Higher availability | `-var single_nat_gateway=false` (2 NAT × 10 GB: 66.60; 4 public IPv4: 14.60) | 166.39 | [link](https://calculator.aws/#/estimate?id=e62ab5adeb71f73b6c0787baaebf12456a2e66f6) |
| Previous Aurora design, for comparison | 2 × `db.t4g.medium` writer + reader (110.58) | 198.53 | [link](https://calculator.aws/#/estimate?id=7737ad5fa34e1c6c227c35cecaeffc348635c159) |

The database costs 41.94 of 129.89, against 110.58 for Aurora, because RDS
offers `db.t4g.micro` while Aurora's smallest class is `db.t4g.medium`. The read
replica adds 13.98. The fixed network cost (NAT, public IPv4, ALB) is 66.97, the
largest share. Each extra Fargate task added by autoscaling costs about $9/month
while it runs (half of the 18.02 above).

Monitoring (alarms, health check, SNS) adds 2.00 to the bill. The health check
targets the domain name, which resolves to the ALB, and is priced as an AWS
endpoint; if Route 53 bills it as a non-AWS endpoint it costs 2.75 instead of
1.00 ($0.75 basic + $2.00 HTTPS). The hosted zone already exists and is not
created by this stack, so its $0.50/month is not counted here.

> Figures are on-demand list prices for `us-east-1` and exclude tax, free tier,
> data transfer out (assumed inside the 100 GB/month free allowance), backup
> storage beyond the free allocation (equal to provisioned storage), and Fargate
> public IPs (tasks run in private subnets). Prices differ by region and change
> over time.

## Not implemented yet

| Item | Status |
|---|---|
| HTTPS | Implemented for `aethrclothes.shop`: existing ACM certificates are looked up (not requested) in `us-east-1`, so the stack deploys there |
| Remote Terraform state (S3) | Implemented: S3 bucket and DynamoDB lock from `terraform/bootstrap` |
| CI/CD pipeline | Implemented: GitHub Actions with OIDC (`.github/workflows/deploy.yml`). The first full run on `main` applied everything, but its ECS wait timed out: the service started tasks before the execution policy for the new DB secret existed, and the circuit breaker failed the deployment. Fixed with `depends_on` in `modules/ecs`; the next run on `main` passed every step, including the ECS wait and the smoke test |
| CloudWatch alarms with notifications | Implemented: `modules/monitoring` (see Observability). Email recipients come from the `ALARM_EMAILS` repository variable and must confirm the subscription |
| "1 write, 1 read" | Implemented with an RDS Multi-AZ primary + read replica (Terraform-managed password). The app still sends all queries to `DB_HOST`; `DB_READ_HOST` (replica) is injected but unused |
| Secret rotation | Not applicable: nothing rotates the Terraform-managed password. It changes only when the `DB_PASSWORD` secret changes and CI redeploys. The password is in Terraform state |
