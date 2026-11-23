# Terraform: FastAPI on ECS Fargate with RDS PostgreSQL

Deploys the `k8s-event-api` FastAPI service to AWS:

```text
Internet ──► ALB (public subnets, 2 AZs)
                │  :8000
                ▼
          ECS Fargate tasks (private subnets, 2 AZs) ──► CloudWatch Logs
                │  :5432
                ▼
   RDS PostgreSQL
     primary  ── DB_HOST (writes); Multi-AZ standby in another AZ, failover only
     replica  ── DB_READ_HOST (reads), second AZ, asynchronous
   Credentials: Secrets Manager secret written by Terraform
                (password from the DB_PASSWORD GitHub secret, or generated)
```

See [DESIGN.md](DESIGN.md) for the architecture diagram, design decisions and
the monthly cost (about $130 with the defaults; the two RDS instances are $42 of it).

## Layout

| Path | Purpose |
|---|---|
| `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` | Root configuration that wires the modules together |
| `modules/vpc` | VPC, public/private subnets across AZs, IGW, NAT, route tables |
| `modules/ecr` | Image repository with scan-on-push and a retention policy |
| `modules/alb` | Public Application Load Balancer, target group, listeners |
| `modules/rds` | RDS PostgreSQL primary (Multi-AZ) + read replica, credentials secret, security group |
| `modules/ecs` | Cluster, task definition, service, IAM roles, logs, autoscaling |
| `modules/monitoring` | SNS alarm topic (email), CloudWatch alarms, Route 53 health check on `/db-check` |

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
| `db_multi_az` | `true` | Standby for the primary in another AZ (failover only, serves no reads) |
| `db_create_read_replica` | `true` | One read replica in the second AZ (`DB_READ_HOST`) |
| `db_instance_class` | `db.t4g.micro` | Used by the primary and the replica |
| `db_engine_version` | `17` | Major only; RDS picks and upgrades the minor |
| `db_password` | `null` | Master password, sensitive. Unset or empty: Terraform generates one. CI reads it from the `DB_PASSWORD` repository secret. Stored in Terraform state |
| `db_deletion_protection` | `false` | Set `true` in production (also keeps a final snapshot) |
| `alarm_emails` | `[]` | Emails for alarm notifications; each must click the AWS confirmation link. CI reads it from the `ALARM_EMAILS` repository variable |

For a cheap dev environment: `-var db_multi_az=false -var db_create_read_replica=false`
(one instance, no failover, no read node).

Locally, pass the password through the environment so it stays out of shell
history and files: `export TF_VAR_db_password=...` (it must be 8-128 printable
ASCII characters without `/`, `"`, `@` or spaces).

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

# 3. Create everything else (the primary and then the replica take roughly 20-30 minutes)
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
DB_ID=$(terraform output -raw db_instance_identifier)
aws rds describe-db-instances --query \
  "DBInstances[?starts_with(DBInstanceIdentifier, '$DB_ID')].{id:DBInstanceIdentifier,az:AvailabilityZone,standbyAz:SecondaryAvailabilityZone,multiAz:MultiAZ,source:ReadReplicaSourceDBInstanceIdentifier,managedSecret:MasterUserSecret,public:PubliclyAccessible}"
```

Expect the primary with `multiAz: true` and a `standbyAz`, the replica
(`<name>-db-replica`) with `source` = the primary and an AZ different from the
primary, `managedSecret: null` for both (Terraform owns the password), and
`public: false`.

### Testing failover (optional, causes a brief outage)

```bash
aws rds reboot-db-instance --db-instance-identifier "$DB_ID" --force-failover
```

RDS promotes the standby and the primary endpoint (`DB_HOST`) follows it,
typically within one to two minutes. Watch `/db-check` recover, then run the
`describe-db-instances` command again: `az` and `standbyAz` have swapped.

### Alarms and notifications

```bash
# State of every notifying alarm (OK, ALARM or INSUFFICIENT_DATA)
aws cloudwatch describe-alarms --alarm-name-prefix fastapi-postgres- \
  --query 'MetricAlarms[].[AlarmName,StateValue]' --output table

# Email subscriptions: "PendingConfirmation" until the link in the AWS email is clicked
aws sns list-subscriptions-by-topic --topic-arn "$(terraform output -raw alarm_topic_arn)" \
  --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table

# End-to-end test of the notification path (sends ALARM, then the real state returns)
aws cloudwatch set-alarm-state --alarm-name fastapi-postgres-target-5xx \
  --state-value ALARM --state-reason "manual notification test"
```

New alarms start in `INSUFFICIENT_DATA` until their metric has data points; the
`/db-check` health check needs a couple of minutes after creation.

## Known limitations

- **The DB password is in Terraform state** (and in the Secrets Manager secret).
  Anyone who can read the state bucket can read it. Nothing rotates it.
- **Changing the password needs new tasks.** ECS injects the secret only when a
  task starts. After changing `DB_PASSWORD`, push a commit (new image tag, so the
  service rolls out). A re-run of an old workflow run keeps the old tag; then run
  `aws ecs update-service --cluster <ecs_cluster_name> --service <ecs_service_name> --force-new-deployment`.
  Until then `/db-check` returns 503, and the `db-check-failing` alarm fires within
  about two minutes.
- The app sends every query to `DB_HOST` (the primary). `DB_READ_HOST` (replica)
  is injected but unused until the app routes `SELECT`s to it. Replication is
  asynchronous, so reads from the replica can lag behind writes.
- Why the password is not managed by RDS:
  [docs/read-replica-deferred.md](docs/read-replica-deferred.md).

## Cleanup

Costs accrue while the stack exists (NAT gateway, ALB, RDS instances, Fargate tasks).

```bash
cd terraform

# If you set db_deletion_protection=true, disable it first, otherwise destroy fails
terraform apply -var db_deletion_protection=false

# The ECR repository refuses to be deleted while it holds images. Empty it first.
REPO_NAME=$(terraform output -raw ecr_repository_url | cut -d/ -f2)
# Repeat until empty: an image index blocks its child manifests on the first pass.
while IDS=$(aws ecr list-images --repository-name "$REPO_NAME" --query 'imageIds[*]' --output json) \
      && [ "$IDS" != "[]" ]; do
  aws ecr batch-delete-image --repository-name "$REPO_NAME" --image-ids "$IDS" >/dev/null
done

terraform destroy
```

Afterwards, confirm nothing is left:

```bash
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
```

With `db_deletion_protection=false` the database is deleted without a final
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

# Optional: alarm recipients as a JSON list (unset = alarms without notifications)
gh variable set ALARM_EMAILS --body '["ops@example.com"]'

# DB master password (a secret, not a variable). Unset = Terraform generates one.
gh secret set DB_PASSWORD     # prompts for the value, keeps it out of shell history
```

The apply role may create CloudWatch alarms and SNS topics only with names that
start with the app name. After changing `bootstrap/main.tf`, re-run
`terraform apply` there locally: CI cannot change its own role.

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
