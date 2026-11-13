# Cloud discovery

Admin > Instances can read a cloud account for its database servers and list each one as a proposal. A click approves or ignores a proposal (task 205, built on the sync sources of task 204). Discovery never creates, changes or connects to anything in the cloud. Every call is a read: AWS `Describe*` and `sts:GetCallerIdentity`, Azure Resource Graph's query endpoint, and the GCP list calls.

A server gone from the account is marked gone; it is never removed by itself, and an approved server whose proposal is gone shows "gone from <source> since <time>" on its row. A server the read could not see (a region, a subscription or a project's API that did not answer or refused) is not gone: its proposal stays as it was.

| Source | What it finds | Host proposed |
|---|---|---|
| aws | every RDS and Aurora DB instance running PostgreSQL or SQL Server (not RDS Custom), **each by its own instance endpoint** | the instance's endpoint |
| azure | Azure SQL Database (each user database; a dedicated SQL pool is left out), Azure SQL Managed Instance, Azure Database for PostgreSQL flexible server | the server's fully qualified name |
| gcp | Cloud SQL for PostgreSQL and for SQL Server; AlloyDB instances | the private address first, the public one shown beside it; a Private Service Connect instance by its DNS name |

## One proposal per server, never a load-balanced endpoint

A collector reads one server's own counters. An endpoint that spreads connections over several servers would join their counters, and after a failover a cluster endpoint points at another server. So discovery proposes:

- every Aurora and Multi-AZ DB cluster member by its own instance endpoint, tagged `role:writer` or `role:reader` and `cluster:<id>`;
- an RDS read replica by its own endpoint, tagged `role:replica` and `source-instance:<id>` (`source-cluster:<id>` for a replica of a Multi-AZ DB cluster);
- never a cluster, reader, Multi-AZ reader, custom or RDS Proxy endpoint;
- never an AlloyDB read pool or a Cloud SQL read pool (one address balanced over its nodes): each is a note on the source.

An auto-scaled Aurora reader is proposed like any other instance and is marked gone when it is scaled in.

## Keys, tags and the resource id

A proposal's key names the server in its account: `aws:<account>:<region>:instance:<id>` (the account from `sts:GetCallerIdentity`, which needs no right), `azure:<subscription>:sql:<server>/<database>`, `azure:<subscription>:mi:<name>`, `azure:<subscription>:pg:<name>`, `gcp:<project>:sql:<name>`, `gcp:<project>:alloydb:<location>/<cluster>/<instance>`.

Each proposal also keeps the resource's immutable id: the RDS `DbiResourceId`, an Azure SQL database's `databaseId`, a Managed Instance's name with its DNS zone, the Cloud SQL self link with its creation time, the AlloyDB uid. A server deleted and created again under the same name is a new resource: its old proposal is marked gone and a fresh one is made. An Azure PostgreSQL flexible server has no such field in Resource Graph: its resource id (built from names) is kept, so one created again under the same name is not told apart, and one moved to another resource group looks new.

pgvigil's own tags on a proposal are `cloud`, `region`, `account`, `subscription`, `resource-group`, `project`, `cluster`, `role`, `source-instance`, `source-cluster` and `pool` (an Azure SQL database in an elastic pool: `pool:<the pool's name>`, the tag the elastic pool reads use, [sqlserver-cloud.md](sqlserver-cloud.md)). Alert rules are scoped by tags, so **a resource's own cloud tags come in only through the source's allow-list of keys**, none by default. The first read lists the keys it saw, and Edit on the source takes the keys to allow. A resource tag never adds a value under one of pgvigil's own keys.

## Regions, subscriptions and projects

**AWS.** Every read asks `ec2:DescribeRegions` (all regions, with the account's opt-in status) in the configuration's own region, an optional right, beside RDS's replication list and within 5 s (an EC2 host that does not answer costs each read 5 s, not a call's 20 s). With that list, a region the account has not enabled is noted '<region>: not enabled for this account', and a region the list does not hold '<region>: not a region of these credentials' partition (<partition>)': neither is read, and their servers are not seen (never marked gone); a sweep does not keep either, while a region named in the source stays named (an admin's list is not changed by a read) and is noted so at each read until an Edit removes it. A region the list says is enabled that still answers a token error is the token's fault (a session token of the global STS endpoint is valid only in the regions enabled by default): it is noted so and kept. Without the list (the right not granted, or no answer within 5 s) every read carries the note 'ec2:DescribeRegions not granted (<code>)' or 'not answered', with 'the account's enabled regions were not checked: a region outside RDS's replication list is not read'.

With no region named, the first read sweeps from the configuration's own region (the profile's, or `AWS_REGION`; with none, the source's first kept region that is not left out as silent): `rds:DescribeSourceRegions` there lists the regions RDS in that region names as its replication sources, and these, the enabled regions of `ec2:DescribeRegions` and the regions the source already keeps are read. `rds:DescribeSourceRegions` is RDS's own list, not a promise of every region RDS runs in; with `ec2:DescribeRegions` granted, the account's enabled regions close that gap, and without it a region outside RDS's list is read only when named in the source (Edit). With `rds:DescribeSourceRegions` refused and the region list answered, the enabled regions are swept alone. The regions that answered or did not answer in time are kept in the source, shown and editable; a region that refused is not. A kept region an Edit removes takes its note with it; a refused region's note stays until a read asks it again. The hourly read reads only the kept ones, less a region that gave no answer: such a region stays kept (its servers not seen, never marked gone) but is left out of every read until the next sweep, or until its note is a week old (a source never swept asks it again then), noted '<region>: not reachable (no answer within 20s) (since <time>)'; one the account's list says is no longer enabled is noted so instead and not asked. A source swept once is swept again by the hourly read when its regions are 7 days old (the changes row names 'the weekly sweep'); a sweep that fails is not tried again for 7 days either (the hourly read goes on meanwhile), so a region enabled since, or listed by RDS since, is read without a click. "Read the regions again" sweeps once more; without either list it reads the configuration's region and the kept ones and keeps the list as it was. A region a policy denies is noted with its code. Every read also asks `sts:GetCallerIdentity` (the account in the keys, the partition), so the configuration region's STS endpoint must be reachable (with no configured region, the first kept region not left out as silent), and so must its EC2 endpoint for the region list (one more host for a collector whose egress is restricted: `ec2.<region>.` and the partition's DNS suffix, as the SDK resolves it).

pgvigil writes no region, partition or endpoint into its code (its Go or its SQL): the SDK resolves each region's host, and the partition is the credentials' own, from `sts:GetCallerIdentity`'s ARN. A region is checked for its shape only (lower-case letters and digits in parts joined by hyphens, 40 characters at most), so a sovereign or isolated partition's region is taken as typed; with the region list answered, a region of another partition than the credentials' is noted 'not a region of these credentials' partition' and not read; without it, it is read, answers a token error, and is noted 'not enabled for these credentials, or not a region of their partition'. The region list is `ec2:DescribeRegions` because EC2 is in every AWS partition, while the account service (`account:ListRegions`) is in the aws and aws-cn partitions only (its GovCloud host does not resolve). GovCloud and the China regions are **not proven: no lab**. In GovCloud, RDS presents certificates of its own authority (`rds-ca-rsa4096-g1` and its peers), which an air-gapped collector host must trust. FIPS endpoints come from the profile's own `use_fips_endpoint` setting.

**Azure.** The source's cloud is Azure (public), Azure Government or Azure China. The cloud sets the Resource Manager host, the sign-in host, the token's audience and the managed identity's resource. Azure Government and Azure China are **not proven: no lab**, and whether Resource Graph answers there is not confirmed by Microsoft's pages.

Resource Graph leaves out a subscription the identity cannot read without saying so. With subscriptions named, a named one that is not readable is a note and its servers are kept as they were (the key carries the subscription); the read fails only when none of them is readable. With none named, every subscription the identity can read is read, and every page of the list is read. A subscription seen at an earlier read and missing now is not seen: its servers are kept as they were. To retire a subscription for good, remove the source and add it again. A read the tenant's subscription limit cut (`x-ms-tenant-subscription-limit-hit`) fails; name the subscriptions instead.

**GCP.** Projects are named. An API a project has not enabled (`SERVICE_DISABLED`) holds no server and counts as read, but only when the error names that project, by its id or by the number Cloud Resource Manager gives for it. An error naming another project (the caller's own) leaves the API not seen.

## Each read

What a read could not see is kept as the source's notes (Admin > Instances, 'not seen'), one per region where it names one, each with the time it was first seen. A read replaces the notes of the regions it asked (a region read clean loses its note) and its notes about the source as a whole; a region it did not ask keeps its note, so the hourly read still shows a sweep's refused or silent regions.

One read of a source runs at a time, whether the hourly loop's or a page request's. A request that finds a read running answers "a read of this source is running". A read's start is taken on the repository's clock, and a read that started before the last applied one is never applied over it.

A read done while the page waits ("Add the source", "Read now") has 50 seconds; the hourly read has 3 minutes. On a large estate the add's read may not finish in time; the hourly read follows by itself. A read cut by its limit fails and marks nothing gone.

Each read writes one row to Admin > Instances' changes: who asked (a login, or the hourly read), the servers read, new, gone and back, and the prefixes not seen.

## Read-only credentials

A lasting cloud credential (an Azure service principal's secret, a GCP key) is entered once in the source form. Serve writes it to the source's own file under `sources/` beside the config file (mode 0600 in a 0700 folder on Linux; a DPAPI blob in a folder whose access list is SYSTEM, Administrators and the serve account on Windows). The repository keeps only that file's name, and the page never shows the credential again.

Who can read it: the account serve runs as, and root or an Administrator. The reads run in serve, the process the network reaches. The host's own identity (an EC2 role, a managed identity, a GCE account) is reachable by any process on the host anyway. The defence is therefore a credential that can only list: grant the list-only roles below, never a broader one.

**AWS** has no credential field. It uses the serve host's default credential chain (the environment, the shared files, or an EC2 or ECS role), or a named profile set in the form. The settings file keeps only the profile's name. The list-only policy:

```json
{ "Version": "2012-10-17", "Statement": [ { "Effect": "Allow", "Action": [ "rds:DescribeDBClusters", "rds:DescribeDBInstances", "rds:DescribeSourceRegions", "ec2:DescribeRegions" ], "Resource": "*" } ] }
```

The tags come back inside the two Describe calls, so no `ListTagsForResource` is needed. `rds:DescribeSourceRegions` and `ec2:DescribeRegions` are optional: without the first, name the regions (or let the second's enabled regions be swept); without the second, regions the account has not enabled are tried and noted by their token error, and a region outside RDS's list is not swept (the standing note above). `ec2:DescribeRegions` reads only the region names and their opt-in status. The managed `AmazonRDSReadOnlyAccess` also works, but it adds every other RDS `Describe*` and `List*` action (logs, snapshots, parameters).

**Azure** offers three credentials:
- a service principal, given as a tenant, a client id and a secret;
- the managed identity of the VM serve runs on;
- an access token for a one-off read: `az account get-access-token --resource <the cloud's Resource Manager>`: `https://management.azure.com` (public), `https://management.usgovcloudapi.net` (Azure Government), `https://management.chinacloudapi.cn` (Azure China), each with the CLI signed in to that cloud (`az cloud set`); a Resource Manager refuses a token of another cloud. It is used for the add's read only and never written to a file, and the source is not read again ("Read now" says so). A token carries every right of whoever it belongs to: use one of an identity that holds the list-only role only.

The list-only custom role: `Microsoft.Sql/servers/read`, `Microsoft.Sql/servers/databases/read`, `Microsoft.Sql/managedInstances/read`, `Microsoft.DBforPostgreSQL/flexibleServers/read` and `Microsoft.Resources/subscriptions/read`, on each subscription read. Resource Graph returns what the identity may read. The built-in **Reader** also works, but it reads every resource of the subscription. The custom role is **not proven** (a role in the lab is the owner's hand).

**GCP** offers three credentials:
- a service account key, pasted as the key file's JSON;
- the Compute Engine or GKE account of the host serve runs on (its access scopes must include `cloud-platform`);
- an access token for a one-off read, used once and never written, as on Azure.

The list-only custom role: `cloudsql.instances.list`, `cloudsql.instances.get` (pgvigil calls only the list; Google's own roles pair the two, and it is kept for that), `alloydb.instances.list` and `resourcemanager.projects.get` (the last only for the `SERVICE_DISABLED` check above: the server must then reach `cloudresourcemanager.googleapis.com` too; when it does not answer, the API stays not seen), on each project named. The built-in `roles/cloudsql.viewer` also works but adds `cloudsql.backupRuns.export` and `cloudsql.users.list`; `roles/alloydb.viewer` adds `alloydb.instances.executeSqlReadOnly` and `alloydb.clusters.export`. Google calls service account keys a security risk, and organisations created on or after 2024-05-03 refuse new keys by default (`iam.disableServiceAccountKeyCreation`): prefer the host's own account. Workload identity federation is not supported yet. A project's Cloud SQL Admin API (`sqladmin.googleapis.com`) and AlloyDB API (`alloydb.googleapis.com`) must be enabled for its servers to be seen.

## Approving a cloud server

A proposal carries no login. The server's master user is shown as information only, because it holds every right on the server and the monitoring login stays least-privilege. The approve takes the source's login (the form's "The login an approved server is read with" fields), or a login typed in the approve row. A login equal to the master user needs a tick, and the approve's audit row says so. One source holds both engines: its login is a SQL login on SQL Server and a password login on PostgreSQL. A PostgreSQL server with no password reads it from `.pgpass`. The login is written to the instance's own credential file.

The approve row offers the instance's name (prefilled from the proposal's), a login and its kind, and Test (204's connection test, audited) before Approve. A kind picked with no login typed takes the source's own login when it is that kind (a source's one login counts as a SQL login on SQL Server and a password login on PostgreSQL), and otherwise the approve names what is missing; `.pgpass` picked takes the source's login alone, its password left out. A SQL login typed with the kind left at "as the source signs in", on a source that signs in as an Entra application, is refused until SQL login is picked: it would otherwise be sent as the application's id. The instance starts with the platform its cloud gave (`rds`, `aurora`, `azure`, `azuresqldb`, `azuresqlmi`, `cloudsql`, `alloydb`); a server of a list or CMS source starts as `auto` until its first read. A cloud server is approved with TLS on: `sslmode=require` on PostgreSQL unless the source's options set `sslmode`, and `encrypt=true` on SQL Server (pgvigil's default). Approve asks a tick, with its reason, when:

- **the server pauses when idle**: Aurora Serverless v2 at 0 ACU, or Azure SQL serverless with auto-pause. A collector reading it every minute keeps it from pausing and billing as idle;
- **the server is already an instance**: by its host (or the proposal's other address) and its port, the engine's default when blank, and for SQL Server the same database; or by the resource id of a proposal approved already (a server listed by two sources). The instances of `pgvigil.yaml` are not checked: the repository does not hold their hosts.

An Azure SQL server or Managed Instance with Microsoft Entra-only authentication, or a PostgreSQL flexible server with password authentication off, is proposed with a note. A SQL login is refused there: approve it with an Entra login - a service principal (`entra`: its application id and secret) or the managed identity of the host serve runs on (`entra-identity`: no secret; the login is a user-assigned identity's client id, or empty for the host's own system-assigned identity). A source whose authentication is `entra-identity` (any SQL Server source, a CMS, a DBA Dash repository or a list file included) needs no credential file: every server approved from it signs in as that identity, which an Entra admin has made a user of each database first ([sqlserver-cloud.md](sqlserver-cloud.md)). Such a PostgreSQL server cannot be monitored until its password authentication is on, because pgvigil signs in to PostgreSQL with a password. For the same reason a PostgreSQL server of a source that signs in to Azure as an Entra application (`entra`) or a managed identity (`entra-identity`) is approved only with a PostgreSQL login and password typed on the approve form: the source's own secret is never used as a PostgreSQL password, and with none typed the approve says so. A `pg_service` source follows the same rule. A server that signs in through IAM (Aurora with IAM authentication, Cloud SQL IAM users) is approved like any other; its login is set in Admin > Instances > Edit afterwards.

## Not proven

- GovCloud, the China regions, Azure Government and Azure China: no lab.
- A live mapping of Azure and GCP servers: the labs hold none (a new server is a billed resource). The unit tests prove the mapping on recorded answers.
- Aurora readers, Multi-AZ DB clusters, read replicas and read pools live: the AWS lab's cluster has one instance.
- `ec2:DescribeRegions` in GovCloud, the China regions and the isolated partitions (no lab); RDS's replication list read from an opt-in starting region (the lab account has none enabled).
- That `rds:DescribeSourceRegions` covers every region the account holds servers in, without `ec2:DescribeRegions`: outside the lab it is RDS's own list.
- The Azure and GCP list-only custom roles: creating a role in a lab is the owner's hand.
- The GCP `SERVICE_DISABLED` project check live: the lab's host account is refused by scope first.
