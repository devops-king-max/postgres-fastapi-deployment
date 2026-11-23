# Finding: RDS read replica rejected, resolved with Aurora PostgreSQL

| | |
|---|---|
| Date | 2026-11-23 |
| Status | Resolved: the database moved from an RDS instance (+ read replica) to an Aurora PostgreSQL cluster (writer + reader) |
| Requirement | "PostgreSQL in private subnets, Multi-AZ, 1 write + 1 read, failover" |
| Met by | Aurora writer + reader in different AZs, automatic failover to the reader, master password managed in Secrets Manager |

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
| A. Terraform-managed secret | `random_password` + an `aws_secretsmanager_secret` created by Terraform, `manage_master_user_password = false`, keep the RDS replica | Smallest change, same cost. The password is stored in Terraform state, and rotation is no longer automatic |
| **B. Aurora PostgreSQL (chosen)** | Replace `modules/rds` with an Aurora cluster: one writer + one reader, cluster and reader endpoints | Keeps the RDS-managed password. The reader serves reads and is the failover target. Smallest instance class is `db.t4g.medium`, so it costs more |
| C. Multi-AZ DB cluster (RDS) | `aws_rds_cluster` with two readable standbys | Readable standbys and fast failover, but needs larger instance classes and costs considerably more |
| D. Defer the reader | Deploy only the Multi-AZ primary | "1 read" not met. Briefly in place before the switch to Aurora |

## Decision and change

The database is an Aurora PostgreSQL cluster (`modules/rds`):

- `aws_rds_cluster` `fastapi-postgres-aurora`, engine `aurora-postgresql` 17.9,
  `manage_master_user_password = true`, encrypted storage, private subnet group.
- Two `aws_rds_cluster_instance` (`db.t4g.medium`): `-aurora-1` in `us-east-1a`
  and `-aurora-2` in `us-east-1b`. Aurora picks the writer: after the first
  deploy it was `-aurora-2`, the reverse of the `promotion_tier` order, so the
  docs do not name a fixed writer AZ.
- `DB_HOST` = cluster endpoint (follows the writer after failover);
  `DB_READ_HOST` = reader endpoint. The app currently uses only `DB_HOST`.
- Root variables `db_multi_az` and `db_create_read_replica` were replaced by
  `db_instance_count` (default 2), `db_instance_class` and `db_engine_version`.

Facts checked in the account before the change: `aurora-postgresql` 17.9 is the
default version in `us-east-1`; `db.t4g.medium` is orderable in `us-east-1a` and
`us-east-1b`, where the private subnets are.

Migration impact: the existing RDS instance `fastapi-postgres-db` is destroyed
(no final snapshot). It held no data: the ECS service had never been created, so
no application had connected to it. Plan against the live state: 7 to add
(cluster, 2 instances, ECS service, task definition, 2 autoscaling resources),
1 to change (execution role policy, new secret ARN), 1 to destroy (the RDS
instance).

## Cost impact

About $197/month with the defaults, up from about $114 for the RDS design. The
two Aurora instances are $106.58 of that (Price List API: $0.073/h for
`db.t4g.medium` in `us-east-1`). Breakdown: [DESIGN.md](../DESIGN.md#estimated-monthly-cost).

## Remaining risk

RDS rotates the managed password every seven days by default, and ECS injects
it only at task start. After a rotation, running tasks cannot open new
connections until they are redeployed. The lasting fix is for the app to fetch
the secret at connect time (see README, Known limitations).

## Verification

```bash
DB_CLUSTER=$(terraform output -raw db_cluster_identifier)
aws rds describe-db-clusters --db-cluster-identifier "$DB_CLUSTER" --query \
  'DBClusters[0].{multiAz:MultiAZ,members:DBClusterMembers[].{id:DBInstanceIdentifier,writer:IsClusterWriter}}'
curl -fsS https://aethrclothes.shop/db-check
aws rds failover-db-cluster --db-cluster-identifier "$DB_CLUSTER"   # optional, brief outage
```
