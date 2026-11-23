# Architecture, Design Decisions and Estimated AWS Costs

How the `k8s-event-api` FastAPI service is deployed on AWS with Terraform, why
it is built this way, and what it costs per month. Deployment, verification and
cleanup steps are in the [repository README](../README.md); Terraform variables
and operational detail are in [README.md](README.md).

## 1. Architecture

![Architecture diagram](docs/architecture.svg)

Request path: Client → Route 53 → ALB (public subnets, HTTPS) → ECS Fargate task
(private subnets, port 8000) → RDS PostgreSQL primary (port 5432). A read replica
in the second AZ is reachable as `DB_READ_HOST`.

| Layer | What | Terraform module |
|---|---|---|
| DNS and TLS | Route 53 alias records for `aethrclothes.shop` and `www`; existing ACM certificates on the ALB | `modules/dns`, `modules/alb` |
| Network | VPC `10.0.0.0/16` across 2 AZs: public subnets (ALB, NAT), private subnets (tasks, database), one NAT gateway | `modules/vpc` |
| Edge | Application Load Balancer: HTTPS on 443, HTTP 80 redirects to HTTPS | `modules/alb` |
| Compute | ECS Fargate service, 2 tasks (one per AZ), autoscaling 2 to 6 on CPU | `modules/ecs` |
| Image | ECR repository, scan on push, retention policy | `modules/ecr` |
| Database | RDS PostgreSQL 17: Multi-AZ primary (writes) + one read replica in the second AZ | `modules/rds` |
| Secrets | DB credentials in Secrets Manager, injected into tasks at start | `modules/rds`, `modules/ecs` |
| Monitoring | CloudWatch Logs, 10 alarms, Route 53 health check on `/db-check`, SNS email notifications | `modules/ecs`, `modules/monitoring` |
| Delivery | GitHub Actions with OIDC; Terraform state in S3 with DynamoDB locking | `.github/workflows/deploy.yml`, `bootstrap/` |

The icons are from the AWS Architecture Icons set as bundled in the open-source
`diagrams` Python package. Use is subject to AWS's icon terms.

## 2. How the requirements are met

| Requirement | How it is met |
|---|---|
| Containerised FastAPI on AWS | ECS Fargate service behind an ALB; image built by CI, tagged with the commit SHA |
| High availability across AZs | 2 AZs minimum (enforced by validation); one task per AZ; ALB in both public subnets |
| PostgreSQL in private subnets | RDS in private subnets only, `publicly_accessible = false`, encrypted storage |
| Multi-AZ with failover | Multi-AZ primary: synchronous standby in another AZ, automatic failover, same endpoint |
| 1 write + 1 read | Primary (`DB_HOST`) takes writes; read replica (`DB_READ_HOST`) serves reads |
| Secrets not in code | Password in a GitHub secret and Secrets Manager; ECS injects it at task start |
| Least privilege | Scoped IAM roles; security groups reference each other instead of CIDRs |
| Infrastructure as code | Reusable Terraform modules, remote state with locking, CI plan on PR and apply on `main` |
| Observability | Container logs in CloudWatch; alarms notify by email on ALARM and OK |
| HTTPS | TLS on the ALB with the existing ACM certificates for the domain |

## 3. Design decisions

### Network

| Decision | Why | Trade-off |
|---|---|---|
| At least 2 AZs, enforced by a variable validation | Losing one AZ must not take the service down | Two of everything that is per-AZ |
| Only the ALB and NAT are public; tasks and database are private | Nothing that runs code or stores data has a public IP | Outbound traffic from tasks needs NAT |
| One shared NAT gateway by default (`single_nat_gateway = true`) | NAT is the largest fixed cost; one saves about $36/month | If the NAT's AZ fails, private subnets lose egress. `false` gives one NAT per AZ |
| Stable subnet numbering (public from `/24` index 0, private from 100) | Adding an AZ later never renumbers existing subnets | None |

### Compute

| Decision | Why | Trade-off |
|---|---|---|
| ECS Fargate | No servers to patch or size for a small stateless API | Higher price per vCPU than EC2 at large scale |
| Tasks register by IP (`target_type = "ip"`) | Required by `awsvpc` networking | None |
| ALB health check on `/health`, not `/db-check` | A database blip would otherwise mark every task unhealthy at once and turn a short DB incident into a full outage | A DB outage is not seen by the ALB, so a separate Route 53 check covers `/db-check` |
| Deployment circuit breaker with rollback, 60 s grace period | A bad image or config rolls back automatically | None |
| Autoscaling on average CPU 60 %, 2 to 6 tasks; Terraform ignores `desired_count` after creation | Follows load; `apply` never fights the autoscaler | Memory is not a scaling signal (an alarm covers it) |
| Explicit `cpu_architecture` | The image must match the platform, otherwise tasks fail with `exec format error` | The build must pass `--platform` |

### Database

| Decision | Why | Trade-off |
|---|---|---|
| Managed RDS instead of a Postgres container | Fargate has no durable local storage; RDS handles backups, patching and failover | Cost of a managed service |
| Multi-AZ primary + one read replica | The Multi-AZ standby only takes over on failover and serves no queries, so the "read" node has to be a separate replica | Replication to the replica is asynchronous, so reads can lag behind writes |
| Failover through the same endpoint | If the primary or its AZ fails, RDS promotes the standby in one to two minutes and `DB_HOST` follows it; the replica keeps replicating from the new primary | Brief outage during failover |
| Terraform sets the master password (`manage_master_user_password = false`) | The first deploy used an RDS-managed password and failed on the replica: `InvalidParameterValue: Creating read replicas for source instance with engine postgres where ManageMasterUserPassword is enabled is not supported`. AWS documents this limitation for all engines except SQL Server and Db2 ([Password management with Amazon RDS and AWS Secrets Manager](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html), section *Limitations*) | The password is in Terraform state and is not rotated |
| `db.t4g.micro`, PostgreSQL 17 (major only) | Smallest Graviton class, enough for a small API; RDS applies minor upgrades | Low headroom (1 GiB RAM); resize with one variable |
| Aurora considered and replaced | An Aurora cluster (writer + reader) works with an RDS-managed password and was deployed and verified, but its smallest class is `db.t4g.medium` | It cost $110.58/month for the database against $41.94 now |
| Deletion protection off by default, final snapshot skipped | Easy teardown for a dev or demo environment | Production should set `db_deletion_protection = true` |

### Secrets, IAM and network security

| Decision | Why | Trade-off |
|---|---|---|
| DB password from the `DB_PASSWORD` GitHub secret, or generated by Terraform when unset | Never in the code or a committed file; validated at plan time against RDS rules | Stored in Terraform state, so the state bucket (private, encrypted, versioned) must be treated as secret |
| Terraform writes the credentials to its own Secrets Manager secret, in the RDS JSON shape | ECS keeps reading the `password` key; nothing in the app changes | Nothing rotates it. To change it, update `DB_PASSWORD` and push a commit so new tasks start with the new value |
| ECS `secrets` block injects `DB_PASSWORD` at task start | Not in the image or in plain-text environment variables | A password change needs new tasks |
| Scoped execution role: pull only from this ECR repo, write only to this log group, read only this secret | Least privilege instead of the broad AWS-managed policy | `ecr:GetAuthorizationToken` must stay `*` (AWS limitation) |
| Empty task role | The app calls no AWS APIs; permissions can be added later without redesign | None |
| Security groups reference each other, not CIDRs | Each tier accepts traffic only from the tier in front of it, even when IPs change | None |

| From | To | Port |
|---|---|---|
| Internet | ALB SG | 80 / 443 |
| ALB SG | Tasks SG | 8000 |
| Tasks SG | DB SG | 5432 |
| Tasks SG | Internet via NAT | 443 only |

The ALB has no other egress; the database has no egress at all.

### Monitoring and alerting

| Decision | Why | Trade-off |
|---|---|---|
| Container logs to CloudWatch (`awslogs`), 30-day retention | Central logs without extra agents | None |
| One SNS topic, email on ALARM and OK | The recipient also learns when an incident is over | Each address must confirm the subscription |
| Route 53 HTTPS health check on `/db-check` from 3 regions every 30 s | Detects a database or credentials failure that the ALB health check cannot see | About $1/month; Route 53 metrics exist only in `us-east-1`, which a precondition enforces |
| "No data" counts as failure for healthy hosts and the health check | Silence there means nothing is reporting | None |

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

Thresholds are starting values, to be tuned with real traffic.

### Delivery and code organisation

| Decision | Why | Trade-off |
|---|---|---|
| GitHub Actions with OIDC, no stored AWS keys | Short-lived credentials; roles trust only this repository (numeric owner and repo IDs) | One-time bootstrap stack run locally |
| Pull requests: read-only role, plan only. `main`: apply role in the `production` environment | Nothing changes in AWS before review | Applying needs a merge |
| Apply role limited to the services in this stack; IAM limited to roles named after the app | The pipeline cannot create an admin role | New services need a bootstrap change |
| Image tag = commit SHA; ECS wait and smoke test of `/health` and `/db-check` after apply | Every deploy is traceable and verified | None |
| Remote state in S3 (versioned, encrypted) with a DynamoDB lock | Shared, recoverable state; no concurrent applies | None |
| Reusable modules with typed, validated variables; the root module only wires them together | Cross-module dependencies go through outputs, never hard-coded IDs | None |

## 4. Estimated monthly cost

Assumptions:
- `us-east-1`, on-demand, Linux x86, 730 hours per month.
- Repo defaults: 2 tasks of 0.25 vCPU / 0.5 GB; `db.t4g.micro` Multi-AZ primary and Single-AZ replica, 20 GB gp3 each.
- 20 GB through NAT, about 1 ALB LCU, 1 GB of logs.
- Data transfer out within the 100 GB/month free allowance.

Sources:
- Non-database rows: AWS Pricing Calculator, estimate dated 2026-11-23. It was made for the earlier Aurora design, whose other services are unchanged.
- RDS rows: AWS Price List API (`aws pricing get-products`, `us-east-1`, PostgreSQL). `db.t4g.micro` costs $0.016/h Single-AZ and $0.032/h Multi-AZ. gp3 storage costs $0.115/GB-month Single-AZ and $0.23 Multi-AZ.

| Item | Input | USD / month |
|---|---|---:|
| NAT Gateway | 1 gateway, 20 GB processed | 33.75 |
| Public IPv4 | 3 addresses (NAT EIP + 2 ALB) | 10.95 |
| Application Load Balancer | 1 ALB, 1 GB/h processed, 1 new conn/s, 1 req/s (about 1 LCU) | 22.27 |
| ECS Fargate | 2 tasks × 730 h, 0.25 vCPU / 0.5 GB, 20 GB ephemeral | 18.02 |
| RDS primary | `db.t4g.micro` Multi-AZ (23.36) + 20 GB gp3 Multi-AZ (4.60) | 27.96 |
| RDS read replica | `db.t4g.micro` Single-AZ (11.68) + 20 GB gp3 (2.30) | 13.98 |
| Secrets Manager | 1 secret, 1,000 API calls | 0.41 |
| CloudWatch | 1 GB logs (0.50) + 10 standard-resolution alarms (1.00) | 1.50 |
| ECR | 0.5 GB stored | 0.05 |
| Route 53 health check | Basic check of an AWS endpoint (free, first 50) + HTTPS option | 1.00 |
| SNS | 1,000 publishes and email notifications, within the free allowance | 0.00 |
| VPC, IGW, security groups, IAM, autoscaling | Not billed | 0.00 |
| **Total** | | **129.89** |

That is about **$4.30 per day** or **$0.18 per hour** while the stack exists.

### Where the money goes

| Group | USD / month | Share |
|---|---:|---:|
| Fixed network: NAT, public IPv4, ALB | 66.97 | 52 % |
| Database: primary + replica | 41.94 | 32 % |
| Compute: Fargate | 18.02 | 14 % |
| Everything else | 2.96 | 2 % |

### Scenarios

| Scenario | How | USD / month |
|---|---|---:|
| Default (this repo) | as above | 129.89 |
| Dev-lite | `-var db_multi_az=false -var db_create_read_replica=false` (one Single-AZ instance, 13.98) | 101.93 |
| Higher availability | `-var single_nat_gateway=false` (2 NAT × 10 GB: 66.60; 4 public IPv4: 14.60) | 166.39 |
| Previous Aurora design | 2 × `db.t4g.medium` writer + reader (110.58), [calculator estimate](https://calculator.aws/#/estimate?id=7737ad5fa34e1c6c227c35cecaeffc348635c159) | 198.53 |

- Each extra task added by autoscaling costs about $9/month while it runs.
- The read replica alone adds 13.98.
- The health check is priced as an AWS endpoint, because the domain resolves to the ALB. If Route 53 bills it as a non-AWS endpoint, it costs 2.75 instead of 1.00 ($0.75 basic + $2.00 HTTPS).

### Ways to reduce cost

- Destroy the stack when it is not needed. Costs stop at once, apart from the
  bootstrap stack, which costs almost nothing.
- Use dev-lite for non-production environments: one DB instance, no replica.
- Add VPC endpoints for ECR, Logs and Secrets Manager. This lowers NAT data
  charges at higher traffic, but each interface endpoint has its own hourly fee.
- Use Reserved Instances (RDS) or Savings Plans (Fargate) for a long-lived
  production environment.

### Not included

- Tax and the free tier.
- Data transfer out above the free allowance.
- Backup storage beyond the free allocation (equal to provisioned storage).
- The existing Route 53 hosted zone ($0.50/month).

These are list prices, which differ by region and change over time.

## 5. Implementation status and known limitations

| Item | Status |
|---|---|
| HTTPS | Implemented. The existing ACM certificates are looked up, not requested, in `us-east-1`, so the stack deploys there |
| Remote Terraform state | Implemented: S3 bucket and DynamoDB lock from `terraform/bootstrap` |
| CI/CD pipeline | Implemented: GitHub Actions with OIDC; plan on pull requests, build, apply, ECS wait and smoke test on `main` |
| CloudWatch alarms with notifications | Implemented. Recipients come from the `ALARM_EMAILS` repository variable and must confirm the subscription |
| "1 write, 1 read" | Implemented. The app still sends every query to `DB_HOST`; `DB_READ_HOST` is injected but unused until the app sends `SELECT`s to the replica |
| Password rotation | Not rotated (accepted trade-off for the read replica). The password changes only when `DB_PASSWORD` changes and a new commit is deployed |
| ACM certificate renewal | The certificates were created outside the stack. Their DNS validation CNAME is missing from the hosted zone, so they will not renew automatically before they expire in December 2026 |
| Single NAT gateway | Egress depends on one AZ; switch with `single_nat_gateway = false` |
