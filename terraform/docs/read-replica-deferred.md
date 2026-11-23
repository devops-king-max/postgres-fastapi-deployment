# Finding: RDS read replica rejected, resolved with a Terraform-managed password

| | |
|---|---|
| Date | 2026-11-23 |
| Status | Resolved with option A: RDS primary + read replica, master password set by Terraform. An Aurora cluster (option B) was used in between and replaced the same day for cost |
| Requirement | "PostgreSQL in private subnets, Multi-AZ, 1 write + 1 read, failover" |
| Met by | RDS Multi-AZ primary (write, automatic failover to its standby) + one read replica in the second AZ; credentials in a Terraform-managed Secrets Manager secret |

## What happened

The first full `terraform apply` from the `deploy` workflow on `main` created the
RDS primary instance `fastapi-postgres-db` (Multi-AZ, 14m22s), then failed on the
read replica:

```text
Error: creating RDS DB Instance (read replica) (fastapi-postgres-db-replica):
operation error RDS: CreateDBInstanceReadReplica, https response error StatusCode: 400,
api error InvalidParameterValue: Creating read replicas for source instance with
engine postgres where ManageMasterUserPassword is enabled is not supported.

  with module.rds.aws_db_instance.replica[0],
  on modules/rds/main.tf line 70
```

## Root cause

The primary was created with `manage_master_user_password = true`: RDS generates
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
- [Password management with Amazon Aurora and AWS Secrets Manager](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/rds-secrets-manager.html),
  section *Limitations*: for Aurora, managed master passwords are unsupported
  only for Blue/Green Deployments, clusters in an Aurora global database,
  cross-Region read replicas, and binary log external replication. Reader
  instances inside the same cluster are not on the list: they are cluster
  members sharing the cluster volume, not replicas created from a source
  instance. The same page states that the managed password is rotated every
  seven days by default.

The API error above (HTTP 400, `InvalidParameterValue`) is the direct evidence
from this account. The documentation confirms it is a documented limitation,
not a transient or permission problem.

## Options considered

| Option | Change | Trade-off |
|---|---|---|
| **A. Terraform-managed secret (chosen)** | `manage_master_user_password = false`, password from the `DB_PASSWORD` GitHub secret (or `random_password`), written to an `aws_secretsmanager_secret` created by Terraform; keep the RDS replica | Smallest change, cheapest. The password is stored in Terraform state, and nothing rotates it |
| B. Aurora PostgreSQL (used first, then replaced) | Replace `modules/rds` with an Aurora cluster: one writer + one reader, cluster and reader endpoints | Keeps the RDS-managed password. The reader serves reads and is the failover target. Smallest instance class is `db.t4g.medium`, so the database costs $110.58/month instead of $41.94 |
| C. Multi-AZ DB cluster (RDS) | `aws_rds_cluster` with two readable standbys | Readable standbys and fast failover, but needs larger instance classes and costs considerably more |
| D. Defer the reader | Deploy only the Multi-AZ primary | "1 read" not met. Briefly in place before the switch to Aurora |

## Decision and change

The database is back to RDS instances (`modules/rds`), with the password owned
by Terraform instead of RDS:

- `aws_db_instance` `fastapi-postgres-db`: PostgreSQL 17, `db.t4g.micro`,
  Multi-AZ, gp3, encrypted, private, `manage_master_user_password = false`,
  `password` = `var.db_password` or a generated 32-character alphanumeric value
  (`coalesce` treats an empty GitHub secret as unset).
- `aws_db_instance` `fastapi-postgres-db-replica`: `replicate_source_db` = the
  primary, placed in the second AZ. It inherits the credentials.
- `aws_secretsmanager_secret` `fastapi-postgres-db-*` with the RDS-style JSON
  (`username`, `password`, `host`, `port`, `dbname`). ECS still injects the
  `password` key as `DB_PASSWORD`.
- CI passes `TF_VAR_db_password` from the `DB_PASSWORD` repository secret.
- A variable validation rejects passwords RDS would refuse (outside 8-128
  printable ASCII characters, or containing `/`, `"`, `@` or a space) at plan
  time instead of halfway through an apply.
- Root variables `db_instance_count` (Aurora) were replaced by `db_multi_az`,
  `db_create_read_replica` and `db_password`; `db_instance_class` defaults to
  `db.t4g.micro` and `db_engine_version` to `17`.

Why not keep Aurora: it worked (deployed and verified end to end), but its
smallest class is `db.t4g.medium`. Option A meets the same requirement for about
$69/month less. The stack had been destroyed before the change, so there was no
data to migrate.

The Aurora phase, for the record: cluster `fastapi-postgres-aurora` (17.9) with
two `db.t4g.medium` instances in `us-east-1a` and `us-east-1b`; Aurora picked
the second instance as the writer, so writer placement is not fixed by
`promotion_tier`.

## Cost impact

About $130/month with the defaults: the two RDS instances with storage are
$41.94 (primary Multi-AZ $27.96, replica $13.98; Price List API, `us-east-1`).
The Aurora design was $198.53. Breakdown: [DESIGN.md](../DESIGN.md#estimated-monthly-cost).

## Remaining risk

- The password is in Terraform state (S3 bucket, private, encrypted, versioned)
  and in the secret. Access to the state bucket equals access to the database
  password.
- Nothing rotates it. A password change needs a new ECS rollout, because tasks
  read the secret only at start (see README, Known limitations).

## Verification

```bash
DB_ID=$(terraform output -raw db_instance_identifier)
aws rds describe-db-instances --query \
  "DBInstances[?starts_with(DBInstanceIdentifier, '$DB_ID')].{id:DBInstanceIdentifier,az:AvailabilityZone,multiAz:MultiAZ,source:ReadReplicaSourceDBInstanceIdentifier,managedSecret:MasterUserSecret}"
curl -fsS https://aethrclothes.shop/db-check
aws rds reboot-db-instance --db-instance-identifier "$DB_ID" --force-failover   # optional, brief outage
```
