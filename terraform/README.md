# Terraform: FastAPI on ECS Fargate with Aurora PostgreSQL

Deploys the `k8s-event-api` FastAPI service to AWS:

```text
Internet ──► ALB (public subnets, 2 AZs)
                │  :8000
                ▼
          ECS Fargate tasks (private subnets, 2 AZs) ──► CloudWatch Logs
                │  :5432
                ▼
   Aurora PostgreSQL cluster
     writer  ── cluster endpoint, DB_HOST
     reader  ── reader endpoint, DB_READ_HOST; promoted on writer failure
     (one instance per AZ; which AZ holds the writer changes on failover)
   Credentials: Secrets Manager (generated and owned by RDS)
```

See [DESIGN.md](DESIGN.md) for the architecture diagram, design decisions and
the monthly cost (about $197 with the defaults; Aurora instances are $107 of it).

## Layout

| Path | Purpose |
|---|---|
| `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` | Root configuration that wires the modules together |
| `modules/vpc` | VPC, public/private subnets across AZs, IGW, NAT, route tables |
| `modules/ecr` | Image repository with scan-on-push and a retention policy |
| `modules/alb` | Public Application Load Balancer, target group, listeners |
| `modules/rds` | Aurora PostgreSQL cluster, writer + readers spread over AZs, security group |
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
| `db_instance_count` | `2` | 1 writer + 1 reader. The reader is also the failover target |
| `db_instance_class` | `db.t4g.medium` | Smallest provisioned Aurora PostgreSQL class |
| `db_engine_version` | `17.9` | Aurora PostgreSQL major.minor |
| `db_deletion_protection` | `false` | Set `true` in production (also keeps a final snapshot) |
| `alarm_emails` | `[]` | Emails for alarm notifications; each must click the AWS confirmation link. CI reads it from the `ALARM_EMAILS` repository variable |

For a cheap dev environment: `-var db_instance_count=1` (writer only, no
readable failover target).

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

# 3. Create everything else (the Aurora cluster and instances take roughly 10-20 minutes)
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
DB_CLUSTER=$(terraform output -raw db_cluster_identifier)
aws rds describe-db-clusters --db-cluster-identifier "$DB_CLUSTER" --query \
  'DBClusters[0].{status:Status,multiAz:MultiAZ,members:DBClusterMembers[].{id:DBInstanceIdentifier,writer:IsClusterWriter}}'
aws rds describe-db-instances --filters Name=db-cluster-id,Values="$DB_CLUSTER" --query \
  'DBInstances[].{id:DBInstanceIdentifier,az:AvailabilityZone,public:PubliclyAccessible}'
```

Expect `multiAz: true`, one member with `writer: true` and one with
`writer: false`, two different AZs, and `public: false` for both.

### Testing failover (optional, causes a brief outage)

```bash
aws rds failover-db-cluster --db-cluster-identifier "$DB_CLUSTER"
```

Aurora promotes the reader and the cluster endpoint (`DB_HOST`) follows it,
typically within a minute. Watch `/db-check` recover, then run the
`describe-db-clusters` command again: the writer flag has moved.

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

- **Password rotation breaks running tasks.** RDS rotates the managed password
  every 7 days by default, and ECS injects it only when a task starts. After a
  rotation, running tasks cannot open new DB connections (`/db-check` returns
  503) until they are redeployed:
  `aws ecs update-service --cluster <ecs_cluster_name> --service <ecs_service_name> --force-new-deployment`.
  The lasting fix is for the app to read the secret when it connects. Check the
  schedule with `aws secretsmanager describe-secret --secret-id <db_secret_arn>`.
  The `db-check-failing` alarm detects this case within about two minutes.
- The app sends every query to `DB_HOST` (the writer). `DB_READ_HOST` (reader
  endpoint) is injected but unused until the app routes `SELECT`s to it.
- Why Aurora and not an RDS instance plus read replica:
  [docs/read-replica-deferred.md](docs/read-replica-deferred.md).

## Cleanup

Costs accrue while the stack exists (NAT gateway, ALB, Aurora instances, Fargate tasks).

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
aws rds describe-db-clusters --query 'DBClusters[].DBClusterIdentifier'
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
```

With `db_deletion_protection=false` the Aurora cluster is deleted without a final
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
