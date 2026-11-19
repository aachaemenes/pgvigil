# PostgreSQL sign-in without a password role of its own

Some sites allow no PostgreSQL password for any account: the server checks every login against a directory (LDAP,
Active Directory, RADIUS, PAM). pgvigil's read login still needs a **role** on the server, because PostgreSQL
authenticates against the directory and then maps the login to a role that must exist. This page says how to set that
up for each method, what the instance's sign-in looks like, and what pgvigil checks.

## The role

The role has LOGIN and no password (the directory checks the password), and the grants pgvigil documents for any read
login ([the login's grants](configuration.md)):

```sql
CREATE ROLE pgvigil LOGIN;          -- no PASSWORD: the directory checks it
GRANT pg_monitor TO pgvigil;        -- as for a password login
```

The role is named for the directory account, or mapped to it through `pg_ident.conf`.

## The server's pg_hba.conf

One line per method, the role's line above any broader one. Examples:

```
hostssl all pgvigil 10.0.0.0/8 ldap ldapurl="ldaps://dc1.example.com/dc=example,dc=com?uid?sub"   # LDAP, search and bind
hostssl all pgvigil 10.0.0.0/8 radius radiusservers=r1 radiussecrets=...                          # RADIUS
hostssl all pgvigil 10.0.0.0/8 pam                                                                # PAM
hostssl all pgvigil 10.0.0.0/8 cert                                                               # a client certificate
```

## The instance's sign-in: LDAP, RADIUS, PAM and BSD

These methods have the server ask the client for the password **in clear**, inside the session's TLS when there is
TLS. pgvigil's driver answers them as it answers a password request; nothing else is needed on pgvigil's side but the
directory account's password and a session that checks the server's certificate:

- **Admin > Instances:** auth `password`, the login and the directory account's password, and in the driver options
  `sslmode=verify-full sslrootcert=system`. The page opens `sslrootcert` only as `system` (the server's certificate
  from a public CA): a server whose certificate comes from a private CA needs its CA file, which is `pgvigil.yaml`'s.
- **pgvigil.yaml:** the dsn with `sslmode=verify-full` and `sslrootcert=/path/to/ca.pem` (or `system`), the password
  from a passfile, `env:NAME`, `file:/path` or `password_secret` - never inline in the dsn (an inline password warns at
  load). pgvigil's driver (pgx) knows no `hostaddr`: it would reach the server as a setting the server refuses, so
  the address goes in `host`.

```yaml
instances:
  - name: dir1
    engine: postgres
    dsn: "host=dir1.example.com dbname=postgres user=pgvigil sslmode=verify-full sslrootcert=/etc/pgvigil/ca.pem passfile=/etc/pgvigil/dir1.pgpass"
```

pg_hba's `password` method (the server's own password, sent in clear) is the same case.

## The instance's sign-in: a client certificate

pg_hba's `cert` method signs the login in by its TLS client certificate: the certificate's CN is the role (or is mapped
to it through `pg_ident.conf` with `map=`), and the server's `ssl_ca_file` names the CA that signed it. No password
crosses at all.

- **pgvigil.yaml only:** the dsn names the certificate and its key, files on the collector's host readable by the
  service account alone (the key file 0600):

```yaml
instances:
  - name: cert1
    engine: postgres
    dsn: "host=cert1.example.com dbname=postgres user=pgvigil sslmode=verify-full sslrootcert=/etc/pgvigil/ca.pem sslcert=/etc/pgvigil/client.crt sslkey=/etc/pgvigil/client.key"
```

- **Admin > Instances refuses it:** the page's door never opens `sslcert` or `sslkey` (a key file on serve's host is
  serve's own identity, not a credential typed into the form), so an instance that signs in by a certificate is one
  of `pgvigil.yaml`.

A certificate of another CN than the role is refused by the server ("certificate authentication failed for user"); a
key file that is not there or not readable fails the connection in words naming the file.

## What pgvigil checks

On PostgreSQL 16 and later the server says how it signed the session in (`SYSTEM_USER`: "the authentication method and
the identity (if any) that the user presented during the authentication cycle", PostgreSQL's documentation). pgvigil
reads the method word, never the identity (under LDAP it is the bind DN):

- **The connection test** (the page's Test, and `pgvigil check` per instance) adds a WARN when the method is `ldap`,
  `radius`, `pam`, `bsd` or `password` and the dsn's sslmode is not `verify-full`: the password then reaches a server
  whose certificate nobody checked. `pgvigil check` exits 3 on it, as on any WARN. Without TLS at all the warning says
  so first. Nothing is refused: a configuration that signs in today keeps signing in.
- **The `pg_signin` collection** (hourly, PostgreSQL 16 and later) reads the same: the method, whether the session runs
  inside TLS, and the dsn's sslmode, which only the collector knows.

Under PostgreSQL 16 the method is not readable from the client: `pg_signin` is skipped with that reason and the
connection test says nothing about the method.

## Not on this page yet

- Kerberos with a keytab on a Linux or macOS collector (pg_hba `gss`; next: M3).
- Not in this release: Windows SSPI (the service's own domain account), the cloud tokens (Amazon RDS IAM, Microsoft
  Entra on Azure Database for PostgreSQL, Cloud SQL IAM), and an LDAP sign-in for pgvigil's own web pages.

## What is proven

Not proven yet against a real directory: the lab rows (an OpenLDAP, a FreeRADIUS and a PAM server in containers beside
a PostgreSQL 18, and a client certificate from the proof's own CA: `scripts/proof-pg-signin.sh`) come with this
release's proof.
