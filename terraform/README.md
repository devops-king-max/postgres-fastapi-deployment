# Terraform: FastAPI on ECS Fargate with RDS PostgreSQL

Deploys the `k8s-event-api` FastAPI service to AWS:

```text
Internet ──► ALB (public subnets, 2 AZs)
                │  :8000
                ▼
          ECS Fargate tasks (private subnets, 2 AZs) ──► CloudWatch Logs
                │  :5432
                ▼
   RDS PostgreSQL primary (Multi-AZ standby, auto failover)
   RDS read replica (reads)
   Credentials: Secrets Manager (generated and owned by RDS)
```

See [DESIGN.md](DESIGN.md) for the architecture diagram, design decisions and
the estimated monthly cost (about $128 with the defaults).

## Layout

| Path | Purpose |
|---|---|
| `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` | Root configuration that wires the modules together |
| `modules/vpc` | VPC, public/private subnets across AZs, IGW, NAT, route tables |
| `modules/ecr` | Image repository with scan-on-push and a retention policy |
| `modules/alb` | Public Application Load Balancer, target group, listeners |
| `modules/rds` | PostgreSQL primary (Multi-AZ) and one read replica |
| `modules/ecs` | Cluster, task definition, service, IAM roles, logs, autoscaling |

## Prerequisites

- Terraform `>= 1.4`
- AWS CLI v2 with credentials that can create VPC, ECS, ECR, RDS, ALB, IAM and Secrets Manager resources
- Docker

```bash
aws sts get-caller-identity   # confirm you are in the intended account
```

## Configuration

Defaults work out of the box. Override with `-var` or a `terraform.tfvars` file (git-ignored).

| Variable | Default | Notes |
|---|---|---|
| `aws_region` | `us-east-1` | |
| `az_count` | `2` | Minimum 2 |
| `single_nat_gateway` | `true` | `false` = one NAT per AZ (resilient, costs more) |
| `image_tag` | `latest` | Prefer a unique tag such as the git SHA |
| `cpu_architecture` | `X86_64` | Must match how the image is built |
| `desired_count` / `max_count` | `2` / `6` | Autoscaling on CPU 60% |
| `certificate_arn` | `null` | Set to enable HTTPS (HTTP then redirects) |
| `db_multi_az` | `true` | Synchronous standby with automatic failover |
| `db_create_read_replica` | `true` | One read replica |
| `db_deletion_protection` | `false` | Set `true` in production (also keeps a final snapshot) |

For a cheap dev environment: `-var db_multi_az=false -var db_create_read_replica=false`.

## Deploy

The service needs an image in ECR before it can start, so deploy in three steps.

```bash
cd terraform
terraform init

# 1. Create only the ECR repository
terraform apply -target=module.ecr

# 2. Build and push the image
REPO=$(terraform output -raw ecr_repository_url)
REGION=us-east-1   # same as aws_region
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${REPO%%/*}"

# --platform must match cpu_architecture (linux/amd64 for X86_64). Apple Silicon
# builds arm64 by default and the tasks would fail with "exec format error".
docker build --platform linux/amd64 -t "$REPO:latest" ../k8s-event-api
docker push "$REPO:latest"

# 3. Create everything else (RDS Multi-AZ takes roughly 10-20 minutes)
terraform apply
```

To roll out a new image: push it under a new tag, then
`terraform apply -var image_tag=<tag>`. With the same tag, run
`aws ecs update-service --cluster <ecs_cluster_name> --service <ecs_service_name> --force-new-deployment`.

## Verify

```bash
ALB=$(terraform output -raw alb_dns_name)
CLUSTER=$(terraform output -raw ecs_cluster_name)
SERVICE=$(terraform output -raw ecs_service_name)

# 1. Service reached a steady state with all tasks running
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].{desired:desiredCount,running:runningCount,events:events[:3].message}'

# 2. Liveness (does not touch the database)
curl -i "http://$ALB/health"            # 200 {"status":"ok",...}

# 3. Database connectivity (503 with a reason if the DB is unreachable)
curl -i "http://$ALB/db-check"          # 200 {"status":"ready","db_check":1,...}

# 4. Write and read through the API
curl -s -X POST "http://$ALB/events" -H 'Content-Type: application/json' \
  -d '{"source":"smoke-test","event_type":"deploy","payload":"{}"}'
curl -s "http://$ALB/events?limit=5"
curl -s "http://$ALB/stats"

# 5. Application logs in CloudWatch
aws logs tail "$(terraform output -raw log_group_name)" --since 15m --follow
```

Right after `apply`, the ALB may return 502/503 for a minute or two until the
tasks pass their health checks. If it persists, check the service events
(step 1) and the target health:

```bash
aws elbv2 describe-target-health --target-group-arn \
  "$(aws elbv2 describe-target-groups --query "TargetGroups[?starts_with(TargetGroupName, 'fastap')].TargetGroupArn | [0]" --output text)"
```

### Checking the database setup

```bash
aws rds describe-db-instances --query \
  'DBInstances[].{id:DBInstanceIdentifier,multiAz:MultiAZ,az:AvailabilityZone,replicaOf:ReadReplicaSourceDBInstanceIdentifier,public:PubliclyAccessible}'
```

Expect the primary with `multiAz: true`, the replica with a `replicaOf` value,
and `public: false` for both.

### Testing failover (optional, causes a brief outage)

```bash
aws rds reboot-db-instance --db-instance-identifier <name>-db --force-failover
```

The primary endpoint stays the same and flips to the standby within about a
minute or two. Watch `/db-check` recover.

## Known limitations

- The app reads only `DB_HOST`, so all queries hit the primary. `DB_READ_HOST`
  (the replica) is injected into the container but unused until the app routes
  `SELECT`s to it.
- The database password is injected when a task starts. RDS-managed secrets are
  rotated periodically; verify rotation with
  `aws secretsmanager describe-secret --secret-id <db_secret_arn>`. After a
  rotation, running tasks may need a redeploy to pick up the new password.
- The default listener is HTTP only. Set `certificate_arn` for HTTPS.
- Terraform state is local. Use an S3 backend with locking for team use.

## Cleanup

Costs accrue while the stack exists (NAT gateway, ALB, RDS instances, Fargate tasks).

```bash
cd terraform

# If you set db_deletion_protection=true, disable it first, otherwise destroy fails
terraform apply -var db_deletion_protection=false

# The ECR repository refuses to be deleted while it holds images. Empty it first.
REPO_NAME=$(terraform output -raw ecr_repository_url | cut -d/ -f2)
IDS=$(aws ecr list-images --repository-name "$REPO_NAME" --query 'imageIds[*]' --output json)
[ "$IDS" != "[]" ] && aws ecr batch-delete-image --repository-name "$REPO_NAME" --image-ids "$IDS"

terraform destroy
```

Afterwards, confirm nothing is left:

```bash
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
```

With `db_deletion_protection=false` the primary is deleted without a final
snapshot, and all data is lost. Take a manual snapshot first if you need it.

## CI/CD (GitHub Actions)

Workflow: [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml).

| Event | Job | AWS role | Effect |
|---|---|---|---|
| Pull request | `plan` | read-only | fmt, validate, plan. Changes nothing |
| Push to `main` | `deploy` | apply | build image (tag = commit SHA), push to ECR, `terraform apply`, wait for ECS, smoke test `/health` and `/db-check` |

Authentication uses GitHub OIDC, so no AWS keys are stored in GitHub. The apply
role can only be assumed by jobs of the `production` GitHub environment, and that
environment is restricted to the `main` branch (Settings > Environments >
production > Deployment branches). A job that declares `environment:` gets an
environment-shaped OIDC subject, so a trust policy on `ref:refs/heads/main` would
never match it. The subjects also contain the numeric owner and repository IDs
(`repo:<owner>@<id>/<repo>@<id>:...`).

### One-time setup

```bash
export AWS_PROFILE=aws-study
cd terraform/bootstrap
terraform init && terraform apply     # S3 state bucket, lock table, OIDC provider, 2 roles
terraform output                      # note state_bucket, plan_role_arn, apply_role_arn

# Repository variables (not secrets: they are identifiers, not credentials)
gh variable set TF_STATE_BUCKET   --body "<state_bucket>"
gh variable set AWS_PLAN_ROLE_ARN  --body "<plan_role_arn>"
gh variable set AWS_APPLY_ROLE_ARN --body "<apply_role_arn>"
```

If the account already has a GitHub OIDC provider, run bootstrap with
`-var create_github_oidc_provider=false`. For a manual approval gate, add
required reviewers to the `production` environment in the repository settings.

### Domain and HTTPS

The workflow sets `domain_name = aethrclothes.shop` (plus `www`). Terraform does
**not** request certificates: it looks up the existing ISSUED ACM certificates
`aethrclothes.shop` (default) and `*.aethrclothes.shop` (added via SNI), enables
the HTTPS listener (HTTP redirects to HTTPS) and creates alias records to the ALB
in the existing Route 53 hosted zone.

An ALB can only use certificates from its own region, and these certificates live
in `us-east-1`, so the stack deploys to `us-east-1`. Public ACM certificates cannot
be copied to another region.

Local runs now need the remote backend: copy `backend.hcl.example` to
`backend.hcl`, fill it from the bootstrap outputs and run
`terraform init -backend-config=backend.hcl`.
