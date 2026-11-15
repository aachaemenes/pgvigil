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
