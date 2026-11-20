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
hostssl all pgvigil 10.0.0.0/8 gss include_realm=0 krb_realm=EXAMPLE.COM                          # Kerberos (Active Directory)
```

The gss line is `hostssl`, with the instance's dsn at `sslmode=verify-full` (pgauth3 S3): pgvigil's PostgreSQL driver
has no GSS encryption (no `gssencmode`, so a `hostgssenc` line never matches it), and a gss sign-in proves the
collector to the server but not the server to the collector - TLS checked at verify-full is what proves the server.

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

## The instance's sign-in: Kerberos (pg_hba gss)

pg_hba's `gss` method signs the login in by a Kerberos ticket (Active Directory, or any KDC). pgvigil signs in with
**one Kerberos identity for the whole process** - a keytab and its principal, or a credential cache the host keeps
fresh - named once in `pgvigil.yaml`:

```yaml
kerberos:
  keytab: /etc/pgvigil/pgvigil.keytab   # the service account's own file, 0600
  principal: pgvigil@EXAMPLE.COM        # the keytab's principal: user@REALM
  krb5_conf: /etc/krb5.conf             # default: KRB5_CONFIG, else /etc/krb5.conf
# or, for a cache kept by 'kinit -k' outside pgvigil:  kerberos: { ccache: /var/lib/pgvigil/krb5cc }
```

The krb5.conf pgvigil reads (pgauth3 S4) needs the realm's `kdc =` lines or `dns_lookup_kdc = true`: pgvigil reads no
`include` or `includedir` line and no sssd locator, so a host joined to Active Directory whose own krb5.conf lists no
KDC (kinit works there through sssd) needs one of its own (`krb5_conf:`). A cache must be a FILE: pgvigil cannot read
a `KCM:`, `KEYRING:`, `DIR:` or `API:` cache (the default of such hosts, and of macOS) - the host keeps one with
`kinit -k -t <keytab> -c FILE:<path> <principal>` (a `FILE:` prefix in `ccache:` is accepted). One identity: a keytab
with its principal, or a cache, never both. The block is for the monitored servers' gss sign-ins; the commands that
open only the repository (report, tag, purge, export, user, demo, mcp, install, import) do not read it, so a
repository behind gss is not supported (pgauth3 N1).

Without the block, a credential cache named by `KRB5CCNAME` in the service's environment is the identity. Each
instance's dsn then names only the role the principal maps to (with `include_realm=0`, the principal's name before
the `@`) and, where the server's service principal is not `postgres/<host>`, `krbsrvname` or `krbspn`:

```yaml
instances:
  - name: ad1
    engine: postgres
    dsn: "host=ad1.example.com dbname=postgres user=pgvigil sslmode=verify-full sslrootcert=/etc/pgvigil/ca.pem"
```

**One identity, by pgx's rule:** pgvigil's PostgreSQL driver takes ONE Kerberos provider for the whole process; it
gives that provider the server's host and service (or the SPN whole) at each sign-in, but never the instance or the
login (pgauth3 N4), so one connection cannot carry another principal than the next. A site that needs a second principal runs a second
collector (the same binary, as a remote collector) with its own `kerberos:` block. This is DBA Dash's shape too: its
service signs in as one account (a gMSA).

The host's Kerberos name of the server must be the one its service principal is for (`postgres/ad1.example.com`): give
the host name, not its address, and the REGISTERED name, never a DNS alias (pgauth3 S2: pgvigil lower-cases the host
as libpq does, but does not follow an alias the way MIT's library does - a dsn that works in psql is no proof). A dsn
of several hosts (`host=pg1,pg2`) signs in to each with the FIRST host's ticket: give one instance per host, or a
`krbspn` every host's keytab holds. On Admin > Instances the kind is `kerberos` (the login is the role, no password); it
is this server's own identity, so Community tools and custom reports run on such an instance only from `pgvigil.yaml`.
A gss server with no identity set fails in words naming the `kerberos:` block.

## What pgvigil checks

On PostgreSQL 16 and later the server says how it signed the session in (`SYSTEM_USER`: "the authentication method and
the identity (if any) that the user presented during the authentication cycle", PostgreSQL's documentation). pgvigil
reads the method word, never the identity (under LDAP it is the bind DN):

- **The connection test** (the page's Test and Check all, a proposal's test, and `pgvigil check` per instance) adds a
  WARN when the method is `ldap`, `radius`, `pam`, `bsd` or `password` and the dsn does not open at `verify-full`: the
  password then reaches a server whose certificate (or, at `verify-ca`, whose name) nobody checked. The sslmode is
  read as the connect itself reads it - the keyword, the URL's `ssl=true`, a service file, `PGSSLMODE`, and
  `sslrootcert=system`, which pgx always opens at `verify-full`. `pgvigil check` exits 3 on it, as on any WARN. Without TLS at all the warning says
  so first. Nothing is refused: a configuration that signs in today keeps signing in.
- **The `pg_signin` collection** (hourly, PostgreSQL 16 and later) reads the same: the method, whether the session runs
  inside TLS, and the dsn's sslmode, which only the collector knows. It is a warning on the instance, *a password sent
  in clear, the server not fully checked* (`pgvigil.pg_signin_findings`, one row an instance in `pgvigil.pg_signin`;
  the Findings page and the alert channels carry it once the release's join places it): shown while a collector that
  beats reads the instance, whatever the collection's schedule, or for three hours after a read with no such collector;
  the next read after the dsn is fixed clears it.
- **Behind a pooler** (PgBouncer with `auth_type` pam or ldap, say) the guard reads the SERVER's side of the sign-in:
  the pooler's own sign-in to the server (scram, say) - so pgvigil's password crossing to the pooler in clear gives no
  WARN. Give such a pooler's dsn `sslmode=verify-full` by hand.

Under PostgreSQL 16 the method is not readable from the client: `pg_signin` is skipped with that reason and the
connection test says nothing about the method.

## Not on this page yet

- Not in this release: Windows SSPI (the service's own domain account; a keytab on a Windows collector, as on
  Linux, is not proven there), the cloud tokens (Amazon RDS IAM, Microsoft
  Entra on Azure Database for PostgreSQL, Cloud SQL IAM), and an LDAP sign-in for pgvigil's own web pages.

Not built from the design (named): a locked account's row, and a key file the service cannot read (the proof's X3
reads a key file that does not exist).

## What is proven

LDAP, RADIUS, PAM and a client certificate, against an OpenLDAP, a FreeRADIUS, PAM and the proof's own CA in
containers beside PostgreSQL 18 (`scripts/proof-pg-signin.sh`): each method signs the collector in and `SYSTEM_USER`
reads `ldap:` with the bind DN, `radius:` and `pam:` with the user, `cert:` with the certificate's DN; `pgvigil check`
gives OK at `sslmode=verify-full`, the warning at `sslmode=require`, and says first when the session runs without TLS;
a wrong password, another CA, another certificate name and a missing key fail with the server's own words; every
PostgreSQL collection runs under each method, and `pg_signin` stores the method word (never the identity) and gives
its warning finding at `sslmode=require`, none at `verify-full`.

Kerberos, against an MIT KDC in a container and PostgreSQL 18's GSSAPI (`scripts/proof-pg-kerberos.sh`): a keytab, a
credential cache and `krbsrvname` sign in; a collector running past its tickets' life keeps signing in from a cache
that `kinit -k` writes anew as a new file renamed over it (K8) - kinit writing the cache path itself is K8b, not run
yet (pgauth3 S1); no identity, a principal mapped to another role and a key rotated at the KDC (before a fresh
collector start) fail in words; every PostgreSQL collection runs by the keytab.

Not proven (pgauth3 N7 among them): a key rotated at the KDC under a collector that keeps running; `krbspn`; one bad
host beside a good one on one identity (the good one kept, no KDC sign-in a minute: pgauth3 B2's unit rows only);
Active Directory itself, for LDAP (a domain controller as the directory) and Active Directory as the KDC;
a page instance's private-CA verify-full (a private CA's file is `pgvigil.yaml`'s); a public-CA client certificate
(the proof's comes from its own CA); a real host name for the SPN (the proof's is `localhost`); a Windows keytab (a
keytab on a Windows collector; SSPI is not in this release); the guard under PostgreSQL 16 (the method cannot be read
there); Kerberos on macOS until its GitHub run (`.github/workflows/pgauth-macos.yml`; the same rows ran on Linux with
no Docker: `scripts/proof-pg-kerberos-native.sh`).
