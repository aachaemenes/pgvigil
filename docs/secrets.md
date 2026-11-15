# A login's password from AWS Secrets Manager

An instance in pgvigil.yaml can take its read login's password from AWS Secrets Manager instead of the connection
string (task B24e; Prometheus sql_exporter has the same door). Both engines; configuration-file instances only.

```yaml
instances:
  - name: billing-rds
    dsn: host=billing.abc.us-east-2.rds.amazonaws.com user=pgvigil dbname=postgres sslmode=require
    password_secret:
      ref: aws-secretsmanager:pgvigil/billing-read      # a name or an ARN; #<key> picks another JSON key
      region: us-east-2                                 # an ARN's own region wins
      profile: prod-read                                # the AWS profile; empty = the SDK's default chain
```

- **The secret**: RDS's JSON (`username`, `password`, as RDS writes a managed master password and Secrets Manager
  documents for RDS PostgreSQL and SQL Server secrets) or a plain string that is the password. The login is the
  connection string's user when it names one (it must then be the secret's `username`), else the secret's.
- **What pgvigil keeps**: the extracted password and username, in memory only, never written, logged, put in a page,
  a report zip or an error. An error names the secret and AWS's code (AccessDeniedException, ResourceNotFoundException,
  InvalidRequestException, DecryptionFailure) and never the value.
- **How often it reads**: once a secret every 5 minutes, one read at a time. A departure from "read at each connect":
  a read per connect at a large site (1,819 databases, 5 connects a minute each) would be about USD 65 a day at USD
  0.05 per 10,000 calls, beside USD 0.40 a secret a month; this bound needs the back-off below.
- **A rotation**: when the server refuses the login (PostgreSQL 28P01, SQL Server 18456), pgvigil reads the secret
  once more and retries only when its version changed; otherwise it waits a minute before the next read. So during a
  single-user rotation's window (the database's password changed, the secret not yet) pgvigil adds at most one failed
  login a secret a minute and never drives an account lockout. Only AWSCURRENT is read.
- **A revoke**: a refused read (the secret deleted or scheduled for deletion, the right removed, its key disabled)
  drops the kept password, so pgvigil stops connecting with it within 5 minutes; a transient error (throttling, an
  AWS 5xx, a timeout) keeps the last value one more bound. A read gives up within 5 seconds and 2 attempts.
- **The finding**: an instance whose newest runs cannot read the secret has its own critical finding, *password
  secret unreadable*, naming the refusal; it is never *server unreachable* (the server was not asked).
- **The right**: `secretsmanager:GetSecretValue` on the secret's ARN, and `kms:Decrypt` on its key only when the secret
  uses a customer managed key (none for the default aws/secretsmanager key).
- **The hosts a locked-down site opens**: secretsmanager.&lt;region&gt;.amazonaws.com, or secretsmanager-fips.&lt;region&gt;
  .amazonaws.com when AWS_USE_FIPS_ENDPOINT=true; the credential chain's own (sts.&lt;region&gt;.amazonaws.com for an
  assumed role, the instance metadata endpoint 169.254.169.254 for an instance role); the interface VPC endpoint
  com.amazonaws.&lt;region&gt;.secretsmanager. A door named in the configuration file runs under either site profile:
  the host's administrator turns it on in pgvigil.yaml on that host.
- **No new library**: the call is one signed request through the AWS SDK core pgvigil already links.
- **Not yet**: custom reports, the community tools and Query Store plans on such an instance (refused in words);
  Azure Key Vault and Google Secret Manager; the other connection strings (actions_dsn, explain_dsn, pgbouncer, the
  DBA Dash sources, the repository's); the Add form of Admin > Instances (a page instance has no password_secret).
- Not proven until `scripts/proof-secrets.sh` runs on the AWS lab.
