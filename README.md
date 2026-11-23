# FastAPI + PostgreSQL on AWS (ECS Fargate, RDS, Terraform)

This repository deploys the `k8s-event-api` FastAPI service to AWS with Terraform:

- ECS Fargate tasks in two Availability Zones, behind an HTTPS Application Load Balancer.
- An RDS PostgreSQL Multi-AZ primary for writes and one read replica for reads, both in private subnets.
- CloudWatch alarms that send email notifications.
- A GitHub Actions pipeline that authenticates to AWS with OIDC (no stored AWS keys).

```text
Clients ── Route 53 (aethrclothes.shop) ──► ALB :443 (public subnets, 2 AZs)
                                              │ :8000
                                              ▼
                              ECS Fargate tasks (private subnets, 2 AZs)
                                              │ :5432
                                              ▼
              RDS PostgreSQL primary (DB_HOST, Multi-AZ standby) ──async──► read replica (DB_READ_HOST)
```

| Document | Content |
|---|---|
| This README | Deployment, verification and cleanup |
| [terraform/DESIGN.md](terraform/DESIGN.md) | Architecture, design decisions and estimated AWS costs (about $130/month) |
| [terraform/README.md](terraform/README.md) | Terraform variables, modules and operational detail |
| [docs/local-docker-and-kubernetes.md](docs/local-docker-and-kubernetes.md) | Running the app locally with Docker Compose or Kubernetes |

## Repository layout

| Path | Purpose |
|---|---|
| `k8s-event-api/` | The FastAPI application and its Dockerfile (the image that is deployed) |
| `terraform/` | Root Terraform stack: `vpc`, `alb`, `ecs`, `ecr`, `rds`, `dns`, `monitoring` modules |
| `terraform/bootstrap/` | One-time stack: S3 state bucket, DynamoDB lock table, GitHub OIDC provider, CI roles |
| `.github/workflows/deploy.yml` | Plan on pull requests, build and apply on `main` |
| `compose-demo/` | Local Docker Compose demo (not deployed to AWS) |

## Prerequisites

- An AWS account and credentials with administrator access, for the one-time bootstrap.
- AWS CLI v2, Terraform `>= 1.4`, Docker, and the GitHub CLI (`gh`).
- For HTTPS: a Route 53 hosted zone for the domain and ISSUED ACM certificates in
  `us-east-1` for the apex and the wildcard (`aethrclothes.shop`,
  `*.aethrclothes.shop`). Terraform looks them up; it does not request them.
  Without a domain, leave `domain_name` unset: the API is then served over plain
  HTTP on the ALB DNS name.

```bash
export AWS_PROFILE=<your-profile> AWS_REGION=us-east-1
aws sts get-caller-identity        # confirm the intended account before creating anything
```

## Deployment

### Step 1: One-time setup

The bootstrap stack creates what the pipeline needs before it can run: the
remote state bucket, the lock table, the GitHub OIDC provider and two IAM roles.
A pull request uses the read-only plan role; `main` uses the apply role.

```bash
cd terraform/bootstrap
terraform init
terraform apply                    # add -var create_github_oidc_provider=false if the account already has one
terraform output                   # note state_bucket, plan_role_arn, apply_role_arn
```

Configure the GitHub repository:

```bash
# Repository variables (identifiers, not credentials)
gh variable set TF_STATE_BUCKET    --body "<state_bucket>"
gh variable set AWS_PLAN_ROLE_ARN  --body "<plan_role_arn>"
gh variable set AWS_APPLY_ROLE_ARN --body "<apply_role_arn>"
gh variable set ALARM_EMAILS       --body '["ops@example.com"]'   # optional: alarm recipients

# Repository secret: the database master password.
# If it is not set, Terraform generates a random password.
gh secret set DB_PASSWORD          # prompts for the value, so it stays out of shell history
```

In **Settings > Environments**, create the `production` environment and set its
deployment branches to `main` only. The apply role trusts only jobs that run in
that environment.

### Step 2a: Deploy with GitHub Actions (recommended)

Merge a change to `main` that touches `terraform/`, `k8s-event-api/` or the
workflow, or start the workflow by hand:

```bash
gh workflow run deploy --ref main
gh run watch                       # follow the run
```

The `deploy` job runs these steps in order:

1. Create the ECR repository.
2. Build the image, tagged with the commit SHA (`linux/amd64`), and push it.
3. Run `terraform apply`.
4. Wait until the ECS service is stable.
5. Smoke-test `/health` and `/db-check`.

The first deploy takes about 25 to 35 minutes, mostly for the RDS primary and
then the replica. Each alarm recipient gets an "AWS Notification - Subscription
Confirmation" email and must click the link to receive alarms.

### Step 2b: Deploy from your machine

Use this when you work without the pipeline. The same remote state is used, so
never run it while a pipeline run is in progress.

```bash
cd terraform
cp backend.hcl.example backend.hcl            # fill in the bucket from the bootstrap output
terraform init -backend-config=backend.hcl

# The same inputs the pipeline sets. Without the domain variables, the plan
# removes HTTPS and the DNS records.
export TF_VAR_domain_name=aethrclothes.shop
export TF_VAR_domain_alternative_names='["www.aethrclothes.shop"]'
export TF_VAR_alarm_emails='["ops@example.com"]'
export TF_VAR_db_password='<password>'        # 8-128 printable characters, no / " @ or spaces

# 1. The ECR repository must exist before an image can be pushed
terraform apply -target=module.ecr

# 2. Build and push the image. --platform must match cpu_architecture (X86_64).
REPO=$(terraform output -raw ecr_repository_url)
TAG=$(git rev-parse --short HEAD)
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO%%/*}"
docker build --platform linux/amd64 -t "$REPO:$TAG" ../k8s-event-api
docker push "$REPO:$TAG"

# 3. Everything else
terraform apply -var image_tag="$TAG"
```

## Verification

Run these commands from `terraform/` after the deploy. They need the backend
initialised as in step 2b; `terraform output` then works without the other
variables.

```bash
URL=$(terraform output -raw app_url)                  # https://aethrclothes.shop
CLUSTER=$(terraform output -raw ecs_cluster_name)
SERVICE=$(terraform output -raw ecs_service_name)
DB_ID=$(terraform output -raw db_instance_identifier)
```

**1. The ECS service is stable, with 2 running tasks in different AZs**

```bash
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].{desired:desiredCount,running:runningCount,rollout:deployments[0].rolloutState}'
aws ecs describe-tasks --cluster "$CLUSTER" \
  --tasks $(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --query 'taskArns' --output text) \
  --query 'tasks[].[availabilityZone,lastStatus,healthStatus]' --output table
```

Expected: `running` equals `desired` (2), `rollout` is `COMPLETED`, and the
tasks are in two different AZs.

**2. The API answers over HTTPS**

```bash
curl -s "$URL/health"          # {"status":"ok",...}                 liveness, no database access
curl -s "$URL/db-check"        # {"status":"ready","db_check":1,...}  the app reaches PostgreSQL
curl -s "$URL/info"            # app name, environment, version (commit SHA), DB host

curl -s -X POST "$URL/events" -H 'Content-Type: application/json' \
  -d '{"source":"readme","event_type":"verify","payload":"{}"}'      # write path
curl -s "$URL/events?limit=5"                                        # read path
curl -s "$URL/stats"
```

**3. HTTPS is enforced**

```bash
curl -sI "http://aethrclothes.shop/health" | head -3    # 301, Location: https://...
curl -svo /dev/null "$URL/health" 2>&1 | grep -E 'SSL connection|subject:|expire'
```

**4. The database is private, Multi-AZ, and has a read replica**

```bash
aws rds describe-db-instances --query \
  "DBInstances[?starts_with(DBInstanceIdentifier, '$DB_ID')].{id:DBInstanceIdentifier,az:AvailabilityZone,standbyAz:SecondaryAvailabilityZone,multiAz:MultiAZ,source:ReadReplicaSourceDBInstanceIdentifier,public:PubliclyAccessible,encrypted:StorageEncrypted}" \
  --output table
```

Expected:
- The primary shows `multiAz: True` and a `standbyAz`.
- The replica (`<name>-db-replica`) shows `source` = the primary, in a different AZ.
- Both instances show `public: False` and `encrypted: True`.

**5. Alarms are in place and notifications are confirmed**

```bash
aws cloudwatch describe-alarms --alarm-name-prefix fastapi-postgres- \
  --query 'MetricAlarms[].[AlarmName,StateValue]' --output table
aws sns list-subscriptions-by-topic --topic-arn "$(terraform output -raw alarm_topic_arn)" \
  --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table
```

Expected:
- 10 alarms, all `OK` after a few minutes (new alarms start as `INSUFFICIENT_DATA`).
- A subscription ARN for each email address, not `PendingConfirmation`.

To test the notification path end to end, force an alarm. The ALARM email
arrives at once, and the OK email follows when CloudWatch next evaluates the real
state.

```bash
aws cloudwatch set-alarm-state --alarm-name fastapi-postgres-target-5xx \
  --state-value ALARM --state-reason "manual notification test"
```

**6. Application logs reach CloudWatch**

```bash
aws logs tail "$(terraform output -raw log_group_name)" --since 15m
```

**7. Optional: database failover (causes a brief outage)**

```bash
aws rds reboot-db-instance --db-instance-identifier "$DB_ID" --force-failover
```

RDS promotes the standby within one to two minutes. `/db-check` recovers without
any change to the app, and `az` and `standbyAz` in check 4 swap.

### Troubleshooting

| Symptom | Where to look |
|---|---|
| 502/503 right after deploy | Normal for a minute or two while tasks pass health checks. Then check the target health: `aws elbv2 describe-target-health --target-group-arn <arn>` |
| Tasks keep stopping | `aws ecs describe-services ... --query 'services[0].events[:10]'` and the stopped-task reason, which the pipeline prints when its wait fails |
| `exec format error` in the logs | The image was built for the wrong platform; rebuild with `--platform linux/amd64` |
| `/health` is 200 but `/db-check` is 503 | The database is unreachable, or the password changed after the tasks started. Force a new deployment: `aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --force-new-deployment` |
| Pipeline fails at "Configure AWS credentials" | The job must run in the `production` environment on `main`, and the role ARNs in the repository variables must match the bootstrap outputs |

## Cleanup

The stack costs money while it exists, mostly for the NAT gateway, the ALB, the
RDS instances and the Fargate tasks. Cleanup removes the main stack. The
bootstrap stack can stay: it costs almost nothing, and the pipeline needs it to
redeploy.

> A push to `main` that touches the watched paths, or a manual workflow run,
> recreates the whole stack. Disable the workflow first if it must stay down:
> `gh workflow disable deploy`.

```bash
cd terraform
# Same inputs as the deploy, so the plan matches what exists (step 2b exports)

# 1. Only if db_deletion_protection was set to true: turn it off first.
#    Pass the running image tag, otherwise the apply rolls the service to :latest.
TAG=$(aws ecs describe-task-definition --task-definition "$(aws ecs describe-services \
  --cluster "$(terraform output -raw ecs_cluster_name)" --services "$(terraform output -raw ecs_service_name)" \
  --query 'services[0].taskDefinition' --output text)" \
  --query 'taskDefinition.containerDefinitions[0].image' --output text | cut -d: -f2)
terraform apply -var db_deletion_protection=false -var image_tag="$TAG"

# 2. Empty the ECR repository (Terraform refuses to delete one that holds images).
#    Repeat until empty: an image index blocks its child manifests on the first pass.
REPO_NAME=$(terraform output -raw ecr_repository_url | cut -d/ -f2)
while IDS=$(aws ecr list-images --repository-name "$REPO_NAME" --query 'imageIds[*]' --output json) \
      && [ "$IDS" != "[]" ]; do
  aws ecr batch-delete-image --repository-name "$REPO_NAME" --image-ids "$IDS" >/dev/null
done

# 3. Destroy the stack. The RDS instances take 10 to 15 minutes.
terraform destroy
```

With the default `db_deletion_protection = false`, the database is deleted
without a final snapshot and its data is lost. Take a manual snapshot first if
the data matters: `aws rds create-db-snapshot`.

Confirm that nothing is left. Every command should return an empty list:

```bash
terraform state list
aws rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier, 'fastapi-postgres')].DBInstanceIdentifier"
aws ec2 describe-nat-gateways --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId'
aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, 'fastap')].LoadBalancerName"
aws ecs list-clusters --query 'clusterArns'
aws cloudwatch describe-alarms --alarm-name-prefix fastapi-postgres- --query 'MetricAlarms[].AlarmName'
aws route53 list-health-checks --query 'HealthChecks[].Id'
```

The Route 53 hosted zone and the ACM certificates were not created by this stack,
so they remain.

**Optional: remove the bootstrap stack as well.** Do this only when the project
is finished; the pipeline cannot run afterwards.

1. Empty the state bucket, including all object versions (S3 console > bucket > Empty).
2. Run `terraform destroy` in `terraform/bootstrap`.
3. Delete the repository variables and the `DB_PASSWORD` secret in GitHub.
