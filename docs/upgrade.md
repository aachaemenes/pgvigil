# Upgrading pgvigil

An upgrade is two things: a new binary, and the repository schema that binary expects. The configuration, the logins
and the stored history stay as they are. This page gives the order that ends clean, what each step does, the way back,
what happens in the other order, and what the project's own proof showed (`scripts/proof-upgrade.sh`).

## What an upgrade changes

- **The binary.** One file; `pgvigil version` prints its tag.
- **The repository schema.** `pgvigil migrate` applies the numbered files the new binary carries and the repository
  does not hold yet: in order, each in one transaction, each recorded in `pgvigil.schema_version`. A file already
  recorded is never run again, and a released file is never edited (the rule of `internal/repo/sql/README.md`), so a
  store that was upgraded and a store that was installed fresh have run the same files. A second `migrate` applies
  nothing. The run takes an advisory lock, so two at once do not collide (not proven: no proof runs two at once).
- **The grants.** Every file re-applies the access contract (`pgvigil.apply_roles()`) inside its own transaction: the
  collector's login and the UI's login get their rights on the new tables and functions with it. `pgvigil roles` is
  not run again for an upgrade, unless the release notes name a new login.
- **Nothing else.** The config file and the env file are kept byte for byte. From v0.3.0 to this version no migration
  changes a stored row: the proof compares, table by table, the row count and a hash of the rows before and after.

Two rules follow from how the binary checks the schema:

- A binary does not run on a schema older than its own: `pgvigil run` ends with
  `repository schema is behind this binary (needs <file>): run 'pgvigil migrate' as the repository owner`. The
  schema goes first.
- An older collector should not keep writing while the schema moves under it: a migration may replace an import
  function it calls. Stop the collector before `migrate`.

There is no downgrade migration. The way back is the dump taken before the upgrade and the previous binary (below).

## Before

1. Read the release notes of every version between yours and the new one.
2. Fetch the release and verify it: `SHA256SUMS`, its signature, the SBOM
   ([the README](https://github.com/aachaemenes/pgvigil#releases-and-how-to-verify-one); on a network without
   Internet access, [docs/airgap.md](airgap.md)).
3. Have the repository owner's connection string at hand (the login that ran the first `pgvigil migrate`). The
   service's own env file holds the collector's login, which cannot migrate.

## The steps (Linux, the systemd service)

As root on the host that runs the collector. `OWNER_DSN` is the owner's connection string.

```sh
# 1. fetch and verify only: ./pgvigil of the new version lands in the current folder, nothing is installed
curl -fsSL https://pgvigil.com/install.sh | PGVIGIL_VERSION=vX.Y.Z PGVIGIL_NO_SERVICE=1 sh
./pgvigil version

# 2. stop the collector (and any 'pgvigil serve' of the old version)
systemctl stop pgvigil

# 3. the way back: a dump of the repository as it is now, as its owner
pg_dump -Fc -d "$OWNER_DSN" -f pgvigil-before-vX.Y.Z.dump

# 4. the schema, as the owner (the config names the repository as env:PGVIGIL_REPO_DSN)
PGVIGIL_REPO_DSN="$OWNER_DSN" ./pgvigil migrate -config /etc/pgvigil/pgvigil.yaml

# 5. the binary and the unit: the config and the env file are kept, the service starts
./pgvigil install

# 6. look
pgvigil version
systemctl status pgvigil
journalctl -u pgvigil -n 20
```

Then start `pgvigil serve` again with the new binary (it is not part of the unit). Step 4 prints
`repository schema is current applied=<n>`: the number of files it ran. Step 5 ends with
`pgvigil is installed and running`.

On a network without Internet access step 1 reads a mirror folder instead
(`PGVIGIL_BASE_URL=https://mirror.example.internal/pgvigil`, [docs/airgap.md](airgap.md)), or the verified binary is
carried across by hand and renamed `pgvigil`; the other steps are the same.

The collector is down from step 2 to step 5. On the proof's store (three days of the demo's twelve instances, about
430,000 rows) the 26 files from v0.3.0 to the first build named below ran in under four seconds (this tree carries 38); a migration that rewrites a large table would say
so in its release notes.

## The way back

Stop the collector, restore the dump into a new, empty database that the owner owns, make that database the
repository, put the previous binary back:

```sh
systemctl stop pgvigil
pg_restore --exit-on-error -d "<the owner's connection to the new, empty database>" pgvigil-before-vX.Y.Z.dump
# the repository is now that database: its name in PGVIGIL_REPO_DSN (/etc/pgvigil/pgvigil.env) and in the UI's
# connection string, or the two databases renamed
curl -fsSL https://pgvigil.com/install.sh | PGVIGIL_VERSION=<the previous tag> sh
```

The installer replaces the binary with the previous one and starts the service. What the collector stored between the
upgrade and the way back is not in the dump.

## The other order: the installer first

`install.sh` and `install.ps1` say "re-run to upgrade", and for a release without a new migration file that is the
whole upgrade. When the release carries one, the installer-first order still arrives, with a detour:

1. The installer replaces the binary and restarts the service.
2. The new binary finds the schema behind and ends (the message above); systemd starts it again every 10 seconds.
3. The installer calls the service running only after it stayed up for four seconds. The first start has failed
   well before that, so it ends with an error in one line: `the service did not come up: the repository schema is
   behind this binary (needs <file>)`, followed by what is already done (the binary and the service are installed)
   and the one command left (`pgvigil migrate` as the repository owner). `journalctl -u pgvigil` names the same file.
4. Once the owner has run `pgvigil migrate`, the next start finds the schema current and the service runs. Nothing
   was written in between, and nothing is lost.

So an automated run of the installer can report a failure on such a release although one command is all that is left.
The order above avoids it.

## Windows

The same order with `install.ps1` (`$env:PGVIGIL_NO_SERVICE = '1'`), `Stop-Service pgvigil`,
`pgvigil.exe migrate` with the owner's DSN and `pgvigil.exe install` from an elevated PowerShell. Not proven by the
upgrade proof, which runs on Linux; `scripts/proof-install-windows.sh` covers the installer on Windows, not an
upgrade over stored history.

## What the proof showed

`scripts/proof-upgrade.sh` starts from the released v0.3.0 itself and ends on the build of this tree, on throwaway
containers: a Debian 12 host under systemd for pgvigil, on a network with no route out, a mirror folder there, and
PostgreSQL as the repository and as the monitored server. Run on 2026-11-11 against PostgreSQL 13, 16 and 18 on two earlier builds (86 migration files for the figures below, 89 for the installer-first line; this tree holds 98), green
on each (the numbers are PostgreSQL 16's):

- **The release.** v0.3.0's binary and SBOM match `SHA256SUMS`. The SBOM names exactly the 35 modules the binary
  itself reports (`go version -m`: name, version and hash of each) and the same build settings. The signature of
  `SHA256SUMS` verifies for the release workflow at that tag, and another tag's identity is refused: online, and
  from the bundle on the host with no route out.
- **The install without Internet access.** The host reached neither github.com nor a public address. It installed
  v0.3.0 from the mirror folder with the checksum verified; a mirror copy changed by one byte was refused and nothing
  was installed.
- **The old store.** v0.3.0's own `migrate` (60 files) as an owner with CREATEROLE, the logins `pgvigil roles`
  prints, three days of v0.3.0's demo (12 instances; about 430,000 rows in 107 tables), and its collector running
  under the collector's login against a live server through a `pg_monitor` login.
- **The upgrade, in the order above.** This build refused to run on the old schema (exit 1, naming the file and
  `pgvigil migrate`). `migrate` applied 26 files in under four seconds, and a second run none. Every one of the 107
  tables held the row count it held before; in the 101 that hold rows, a hash of those rows over the columns v0.3.0
  had was the same before and after. The 76 tables that build adds were empty. `./pgvigil install` ended
  `installed and running`, the config and the env file byte for byte as before, the unit running as `pgvigil` and
  still without a restart minutes later.
- **The collector.** Under the collector's login, all 20 collections that ended ok under v0.3.0 ended ok under this
  build (18 of 18 on PostgreSQL 13), and none ended in an error.
- **The pages.** This build's `serve`, under the UI's login, rendered 488 pages over the upgraded store with no error
  box, no API answer of 400 or over, no failed request and no script exception: the 27 root pages, every tab of all
  13 instances (35 each, 36 where a pooler is read) and the drill pages they link to (a database, a table, an index,
  a job, the statement comparison). With the UI login's read role taken away the same walk fails at its first page,
  so a broken page would not pass unseen. The store of v0.3.0 holds PostgreSQL instances only, so the SQL Server
  pages are not in this walk (`scripts/proof-a11y.sh` walks them on a fresh store).
- **After the restart.** The rows outside the live instance were still the counts from before the upgrade.
- **The way back.** The owner's dump, restored by the owner into a second database, held every table's row count and
  row hash from before the upgrade, and v0.3.0, reinstalled from the mirror, collected on it.
- **The installer first.** On that restored store the installer for this build replaced the binary and ended with
  `the service did not come up` (exit 1), naming the migration file and `pgvigil migrate` in that same line, as the
  journal did. After the owner's `migrate` the unit came up by itself at its next restart, and the rows outside
  the live instance were the counts from before.

Not proven here: Windows; a start from a version older than v0.3.0 (the one release that carries the installer); a
store larger than the demo's three days; a repository behind a pooler.
