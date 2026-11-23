# Finding: RDS read replica deferred

| | |
|---|---|
| Date | 2026-11-23 |
| Status | Read replica not deployed (decision: defer) |
| Affected requirement | "RDS PostgreSQL Multi-AZ, 1 write + 1 read, failover" |
| Still met | 1 writer, Multi-AZ synchronous standby, automatic failover, credentials in Secrets Manager |
| Not met | The separate readable node ("1 read") |

## What happened

The first full `terraform apply` from the `deploy` workflow on `main` created the
primary instance `fastapi-postgres-db` (Multi-AZ, 14m22s), then failed on the
replica:

```text
Error: creating RDS DB Instance (read replica) (fastapi-postgres-db-replica):
operation error RDS: CreateDBInstanceReadReplica, https response error StatusCode: 400,
api error InvalidParameterValue: Creating read replicas for source instance with
engine postgres where ManageMasterUserPassword is enabled is not supported.

  with module.rds.aws_db_instance.replica[0],
  on modules/rds/main.tf line 70
```

## Root cause

The primary is created with `manage_master_user_password = true`: RDS generates
the master password and stores it in AWS Secrets Manager, so it never appears in
Terraform code or state. RDS does not support creating a read replica from a
source that manages its master password this way. The design combined the two
features without checking that limitation.

## AWS documentation

- [Password management with Amazon RDS and AWS Secrets Manager](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html),
  section *Limitations*: managing master user passwords with Secrets Manager is
  not supported for creating a read replica when the source DB instance or DB
  cluster manages credentials with Secrets Manager. The restriction applies to
  all engines except RDS for SQL Server and RDS for Db2, so it covers RDS for
  PostgreSQL.
- [Working with read replicas for Amazon RDS for PostgreSQL](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PostgreSQL.Replication.ReadReplicas.html):
  the PostgreSQL replica page does not repeat this restriction in its own
  limitations list, which is how it was missed at design time.

The API error above (HTTP 400, `InvalidParameterValue`) is the direct evidence
from this account; the documentation confirms it is a documented limitation,
not a transient or permission problem.

## Decision

Deploy without the read replica for now.

- `db_create_read_replica` now defaults to `false`, and a variable validation
  rejects `true` at plan time, so nobody waits for a 15-minute primary build
  before hitting the same error.
- The replica resource stays in `modules/rds` for the follow-up below.
- `DB_READ_HOST` is no longer injected (it is only set when the replica exists).
  The application never used it: all queries already went to `DB_HOST`.
- Cost drops by about $14/month (replica instance and storage).

The Multi-AZ standby still gives automatic failover. It cannot serve reads,
which is why the "1 read" part of the requirement is open.

## Options to restore "1 read"

| Option | Change | Trade-off |
|---|---|---|
| A. Terraform-managed secret | `random_password` + an `aws_secretsmanager_secret` created by Terraform, `manage_master_user_password = false` on the primary (in-place modify, no rebuild), re-enable the replica | Smallest change, same cost. The password is stored in Terraform state (the S3 bucket is encrypted and readable only by the CI roles and admins). Rotation is no longer automatic. Not yet tested in this account |
| B. Aurora PostgreSQL | Replace `modules/rds` with an Aurora cluster: one writer + one reader, reader endpoint, failover to the reader | Supports managed passwords with readers. Larger rewrite, the current instance is replaced, higher cost |
| C. Multi-AZ DB cluster (RDS) | `aws_rds_cluster` with two readable standbys | Readable standbys and fast failover, but needs larger instance classes and costs considerably more |

Option A is the recommended follow-up when the read node is required.

## Verification

```bash
# Primary exists, Multi-AZ, no replica
aws rds describe-db-instances --query \
  'DBInstances[].{id:DBInstanceIdentifier,multiAz:MultiAZ,replicaOf:ReadReplicaSourceDBInstanceIdentifier}'

# Plan with the replica enabled is rejected before any API call
terraform plan -var db_create_read_replica=true   # fails in variable validation
```
