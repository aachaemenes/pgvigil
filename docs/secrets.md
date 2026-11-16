# A login's password from AWS Secrets Manager

An instance in pgvigil.yaml can take its read login's password from AWS Secrets Manager instead of the connection
string (task B24e; Prometheus sql_exporter has the same door). Both engines; configuration-file instances only.

```yaml
instances:
  - name: billing-rds
    dsn: host=billing.abc.us-east-2.rds.amazonaws.com user=pgvigil dbname=postgres sslmode=require
    password_secret:
      ref: aws-secretsmanager:pgvigil/billing-read      # a name or an ARN; #<key> takes the password from another JSON key
      region: us-east-2                                 # an ARN's own region wins
      profile: prod-read                                # the AWS profile; empty = the SDK's default chain
```

- **The secret**: RDS's JSON (`username`, `password`, as RDS writes a managed master password and Secrets Manager
  documents for RDS PostgreSQL and SQL Server secrets) or a plain string that is the password. With `#<key>` that
  key's value is the password alone and the login comes from the connection string.
- **The login**, one rule for every connect (the collector, the actions doors, EXPLAIN, the index advisor, the
  Connection Test): the connection string's user when it names one - it must then be the secret's `username` (SQL
  Server's names compare without case) -, else the secret's `username`; neither = refused, never pgvigil's own
  account. On SQL Server a SQL login only: a `DOMAIN\user` login, `integrated security` or `trusted_connection` is
  refused beside `password_secret`.
- **What pgvigil keeps**: the extracted password and username, in memory only, never written, logged, put in a page,
  a report zip or an error; the password is set on the driver's parsed configuration, never put into a connection
  string. An error names the secret and AWS's code and never the value. A read is logged (`password secret read`,
  the secret, its region and version), and at start the collector logs the endpoint each secret is read from.
- **How often it reads**: once a secret every 5 minutes, one read at a time. A departure from "read at each connect":
  a read per connect at a large site (1,819 databases, 5 connects a minute each) would be about USD 65 a day at USD
  0.05 per 10,000 calls, beside USD 0.40 a secret a month; this bound needs the back-off below.
- **A rotation**: when the server refuses the login (PostgreSQL 28P01, SQL Server 18456), pgvigil reads the secret
  once more and retries only when its version changed (with the new version's own login). Otherwise that version is
  held: for a minute no connect of the process signs in with it (each says *LoginRefused* without dialling), then one
  connect tries it again, once a minute, until it signs in or the secret's version changes. So during a single-user
  rotation's window (the database's password changed, the secret not yet) the connects already dialling when the first
  refusal came fail once each, and after that pgvigil adds one failed login a minute a secret and process. Whether
  that stays under a login's lockout threshold is the site's policy: a SQL login with CHECK_POLICY=ON under a Windows
  lockout policy of a few attempts can still lock in a long window - rotate in the order RDS uses (the secret first)
  or keep the window short. Only AWSCURRENT is read.
- **A revoke**: a refused read - AccessDeniedException, ResourceNotFoundException, InvalidRequestException (the
  secret scheduled for deletion), DecryptionFailure - drops the kept password, so pgvigil stops connecting with it
  within 5 minutes. Any other error (throttling, an expired or unrecognised AWS credential, an AWS 5xx, a proxy's
  answer, a timeout) keeps the last value one more 5 minutes and logs that it did. A failed read is answered from
  memory for a minute (no call to AWS meanwhile). A read gives up within 5 seconds and 2 attempts; a connect waiting
  on another's read of the same secret gives up within its own time.
- **The finding**: an instance whose newest runs cannot read the secret, or whose secret the connect refused (the
  login rule, a held version), has its own critical finding, *password secret unreadable*, naming the code and the
  secret and what to fix; it is never *server unreachable* nor a *collection failing* per collection.
- **The right**: `secretsmanager:GetSecretValue` on the secret's ARN, and `kms:Decrypt` on its key only when the secret
  uses a customer managed key (none for the default aws/secretsmanager key).
- **The hosts a locked-down site opens**: secretsmanager.&lt;region&gt;.amazonaws.com (.amazonaws.com.cn in the China
  regions), or secretsmanager-fips.&lt;region&gt;.amazonaws.com when AWS_USE_FIPS_ENDPOINT=true or the profile's
  use_fips_endpoint is set, or the endpoint AWS_ENDPOINT_URL_SECRETS_MANAGER (or the profile's services section)
  names - a VPC endpoint's own DNS name; the credential chain's own (sts.&lt;region&gt;.amazonaws.com for an
  assumed role, the instance metadata endpoint 169.254.169.254 for an instance role); the interface VPC endpoint
  com.amazonaws.&lt;region&gt;.secretsmanager. A door named in the configuration file runs under either site profile:
  the host's administrator turns it on in pgvigil.yaml on that host.
- **No new library**: the call is one signed request through the AWS SDK core pgvigil already links.
- **Not yet**: custom reports, the community tools and Query Store plans on such an instance (refused in words); a
  retry after a rotation on the page's one-off connects (Cancel / Terminate, EXPLAIN, the advisor, the Test: they sign
  in with the reader's current value and say the server's refusal);
  Azure Key Vault and Google Secret Manager; the other connection strings (actions_dsn, explain_dsn, pgbouncer, the
  DBA Dash sources, the repository's); the Add form of Admin > Instances (a page instance has no password_secret).
- Not proven until `scripts/proof-secrets.sh` runs on the AWS lab.
