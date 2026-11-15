# Cloud doors for replicas

pgvigil reads some high-availability facts from a cloud's own API, beside what the database itself answers: Azure
Resource Manager for an Azure SQL Database's failover groups (task 390a), and - with task 390b - Amazon CloudWatch and
the RDS API for an RDS read replica's lag, and Google Cloud Monitoring and the Cloud SQL Admin API for a Cloud SQL
replica's. Each read is a door of its own: named in the instance's configuration, off when it is not named, and every
call is a read (nothing is written in any cloud).

## A locked-down site

A door named in the configuration file runs under either site profile: under 'locked-down' the host's administrator
turns it on in pgvigil.yaml on that host; the Settings page cannot. Without the block nothing calls the cloud, and the
collection says which block is missing.

## Azure Resource Manager (failover groups)

| | |
|---|---|
| Config | the instance's `azure:` block: `subscription`, `resource_group`, `server` (the logical server's name), `cloud` (public, usgov, china) |
| Credential (none stored by pgvigil) | the instance's own Entra identity when its connection string signs in with one (a service principal written `<application id>@<tenant>`, or a managed identity); else azidentity's default chain: the environment (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET or AZURE_FEDERATED_TOKEN_FILE), a workload identity, a managed identity, the Azure CLI's sign-in |
| Narrowest right | `Microsoft.Sql/servers/failoverGroups/read` on the server (Reader, or a custom role with it); `Microsoft.Insights/eventtypes/values/read` for the Activity Log's failover operations |
| Outbound hosts | management.azure.com (usgov: management.usgovcloudapi.net; china: management.chinacloudapi.cn); the sign-in: login.microsoftonline.com (usgov: login.microsoftonline.us) for a service principal, the instance metadata endpoint 169.254.169.254 for a managed identity |
| A private path | Azure Resource Manager's Private Link for resource management, which Microsoft applies at the root management group (Owner or Contributor there) |

A custom role with the two actions, read only:

```json
{
  "Name": "pgvigil failover group reader",
  "Actions": ["Microsoft.Sql/servers/failoverGroups/read", "Microsoft.Insights/eventtypes/values/read"],
  "AssignableScopes": ["/subscriptions/<subscription>/resourceGroups/<group>"]
}
```

Not proven: the usgov and china clouds (no lab).

## Provider replicas: Amazon RDS and Google Cloud SQL (task 390b)

The collection `cloud_replicas` (PostgreSQL on RDS or Cloud SQL) and `mssql_cloud_replicas` (RDS for SQL Server) read,
every 5 minutes and with no SQL statement, the instance's own resource, its direct source and its direct replicas, each
one's status and replication status, and each replica's lag, so a replica pgvigil does not connect to still has its
lag. Each lag is to the replica's DIRECT upstream: a replica of a replica (cascaded, marked on its row) lags its own
source, not the first. A resource is one row whoever reads it: a source and its replica both monitored read the same
chain and store it once; both pages show it. An RDS resource is keyed by its ARN (DBInstanceArn, lower case: unique
across regions, accounts and partitions, where an identifier such as 'database-1' is not; a replica RDS names by its
bare identifier takes its source's partition and account), the page showing its identifier; when the listing is
refused, the instance's own key comes from the credential's identity (sts:GetCallerIdentity, which needs no right); a
Cloud SQL resource is project:instance. The page is the Replicas (provider) block under a PostgreSQL instance's
Replication tab and an RDS for SQL Server instance's Availability tab: source and replicas, the lag and byte lag charts
over the range bar's window (hours past a day; a window past 31 days shows its newest 31, and the page says so), the
changes, the findings.

The instance's own failover is read too, through the same door: RDS's event list (category failover: 'Multi-AZ instance
failover started' and '... completed') and Cloud SQL's FAILOVER operations. An RDS Multi-AZ DB instance's or a Cloud SQL
HA instance's failover reads 'restart' in the instance's own events (its standby runs no engine until it takes over);
the provider's word wins: that restart becomes a failover with the provider's words, and a failover no read saw is
written at its completion.

### Amazon RDS (P1)

| | |
|---|---|
| Config | the instance's `aws:` block: `region`, `profile` (optional), `db_instance`, and `replicas: true` - the switch, off by default (on SQL Server the block takes these four keys; `cluster`, `log_group` and `dms` are PostgreSQL's). Aurora's replicas are not this door. |
| Credential (none stored by pgvigil) | the AWS SDK's chain, as the io and logs reads: the environment, the profile, `aws login`, an assumed role, the instance role |
| Calls | `rds:DescribeDBInstances` (one paged listing a region and run, shared by every instance of the run), `cloudwatch:GetMetricData` (ReplicaLag, Maximum over 60 s, the last 20 minutes, a row a datapoint), `rds:DescribeEvents` (the DB instance's failover events, the last 2 hours) |
| Narrowest right | the policy below: DescribeDBInstances on the account's DB instances in every region (`rds:*` in the ARN: a replica in another region is listed in its own region; its hosts too); DescribeEvents and GetMetricData take no resource type, so only Resource "*" grants them |
| Outbound hosts | rds.<region>.amazonaws.com and monitoring.<region>.amazonaws.com for each region a replica is in; sts.<region>.amazonaws.com for an assumed role; the instance metadata endpoint 169.254.169.254 for an instance role |

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "rds:DescribeDBInstances", "Resource": "arn:<partition>:rds:*:<account>:db:*" },
    { "Effect": "Allow", "Action": ["rds:DescribeEvents", "cloudwatch:GetMetricData"], "Resource": "*" }
  ]
}
```

`<partition>` is the site's: `aws`, or `aws-us-gov` in GovCloud. A listing refused (AccessDenied) still reads the
instance's own lag and says which right is missing; a throttle rests the door until its next interval.

### Google Cloud SQL for PostgreSQL (P2)

| | |
|---|---|
| Config | the instance's `gcp:` block: `project`, `instance` (the instance's name, not its connection name), `credentials_file` (optional). PostgreSQL only: Google lists no replica lag for Cloud SQL for SQL Server. |
| Credential (none stored by pgvigil) | Application Default Credentials: GOOGLE_APPLICATION_CREDENTIALS, gcloud's application-default sign-in, the attached service account through the metadata server; or `credentials_file`: a workload identity federation file (no secret) or a service account key (a stored secret: keep it as one) - no other file type is taken |
| Calls | Cloud SQL Admin `instances.get` (the instance, its source `masterInstanceName`, its replicas `replicaNames`), `operations.list` (its FAILOVER operations); Cloud Monitoring `timeSeries.list`: `database/replication/replica_lag` and `database/replication/state` on each replica, `database/postgresql/replication/replica_byte_lag` (replay) on the source, the last 15 minutes (Google: a point is 'not visible for up to 165 seconds') |
| Narrowest right | roles/cloudsql.viewer and roles/monitoring.viewer, or a custom role with `cloudsql.instances.get`, `cloudsql.instances.list` (Google's IAM table names both for operations.list) and `monitoring.timeSeries.list` |
| Outbound hosts | sqladmin.googleapis.com, monitoring.googleapis.com, oauth2.googleapis.com; sts.googleapis.com and iamcredentials.googleapis.com for a federation file; the metadata server for an attached service account |

### What is judged

| Finding | Rule | Default | Source |
|---|---|---|---|
| provider replica lag | the replica's lag over the tier in every datapoint of the 10 minutes to its newest one | warning 10 minutes, critical 30 (`provider_replica_lag`, root, tag or instance) | pgvigil's own, above AWS's 'up to five minutes' an idle source's replica reports |
| provider replica stopped | an available replica whose reported replication status is not replicating (RDS) or Running (Cloud SQL), in two reads | critical | RDS StatusInfos; Cloud Monitoring's replication state. A blank status is 'not reported yet', never stopped |
| provider lag missing | an available replica seen for 15 minutes with no lag datapoint in 15 minutes | warning | pgvigil's own |
| replica promoted or detached | a replica's source gone, or a source no longer listing it | warning for 24 hours | pgvigil's own |
| cloud door failing | 3 reads in a row with a refused or failed call, the sentence carried | warning | pgvigil's own; a read refused whole is the collector's 'collection failing' |

An RDS instance's own Multi-AZ standby is not a replica here and is not read: no row and no finding; its failover is the
provider's failover event (DescribeEvents, above).

Not proven: an RDS for SQL Server read replica (Enterprise edition only: no lab), a cascaded or a cross-region replica
(no lab makes one), an RDS Multi-AZ or Cloud SQL HA failover event (a billed lab not approved), the Cloud SQL rows until
their lab runs, the GovCloud partition.
