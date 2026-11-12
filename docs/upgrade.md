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

## The upgrade from the offline bundle (no network needed)

On a host without Internet access, or wherever the release came as a bundle ([airgap.md](airgap.md), "The offline
bundle"), the installer does steps 2 to 5 below in one run, with every refusal before any change:

```sh
# the owner's connection string in a file of root's alone (a variable does not survive sudo's env_reset)
sudo install -m 0600 /dev/null /root/pgvigil-owner.dsn && sudo sh -c 'cat > /root/pgvigil-owner.dsn'   # paste, then Ctrl-D
sudo sh <bundle>/install.sh --from <bundle> --owner-dsn-file /root/pgvigil-owner.dsn
```

```powershell
& <bundle>\install.ps1 -From <bundle> -OwnerDsnFile C:\secure\pgvigil-owner.dsn
```

It finds the installed collector (the unit's `ExecStart=` and `User=`, the service's command line) and keeps its
binary path, config and account; a `-bin`, `-config` or `-user` that names another is refused. Then, before anything
changes, it refuses when: it does not run as root (elevated); the repository already holds a migration newer than this
build (a downgrade: the way back below, not this command); the owner's connection string is missing or does not own the repository; `pg_dump` is older
(major version) than the repository's server, or missing (`--pg-dump <path>` names one, `--no-dump` takes none); the
dump's folder has less room than the repository's size; another process runs the installed binary (a `pgvigil serve`,
the Windows app: the swap would leave it on the old binary over the new schema). Then:

1. keeps the binary it replaces as `pgvigil.previous` (`pgvigil.previous.exe`) beside it, while the service still runs (a
   copy that cannot be made ends the run before anything else changes); a run after a half-finished upgrade, where the
   installed binary is already this one, leaves `pgvigil.previous` as it is;
2. stops the service;
3. dumps the repository as its owner (`pg_dump --format=custom`), by default to
   `/var/backups/pgvigil/pgvigil-before-<version>-<UTC time>.dump` (Windows: `%ProgramData%\pgvigil-backups\`), a
   folder of root's (SYSTEM's and Administrators') alone and a file of mode 0600 (the dump holds the UI users'
   password hashes and statement text); `--dump <file>` names another, and a folder the operator names keeps its own
   permissions (only the file is made root's alone); the password reaches `pg_dump` through a temporary password file,
   never a command line or its environment. A failed dump starts the old service again and changes nothing else;
4. migrates the repository as its owner (the role that owns the `pgvigil` schema);
5. swaps the binary, writes the unit or the service again with the same paths and account, starts it;
6. prints the way back: the previous binary, the dump and the restore line below.

The Windows app's update check: an upgrade leaves a policy value as it finds it, so a machine whose app an earlier pgvigil installed (v0.3.0 wrote `UpdateCheck` = 1 by default) keeps the check ON: the app asks the release feed once a day, and `pgvigil-app install -no-update-check` (which writes `UpdateCheck` = 0) turns it off; a machine install with neither switch reads the value first and says which it found ([app.md](app.md), [airgap.md](airgap.md)).

A failed migrate swaps nothing and starts nothing: the service stays stopped on the previous binary, the way back is
printed (a migration file is its own transaction, so the files before the failed one are applied: the dump is the way
back to before them).

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

On a network without Internet access the offline bundle above does steps 2 to 5; by hand, step 1 reads a mirror folder instead
(`PGVIGIL_BASE_URL=https://mirror.example.internal/pgvigil`, [docs/airgap.md](airgap.md)), or the verified binary is
carried across by hand and renamed `pgvigil`; the other steps are the same.

The collector is down from step 2 to step 5. On the proof's store (three days of the demo's twelve instances, 429,444
to 429,545 rows in the three runs below) the 39 files from v0.3.0 to the build measured below ran in 2,237 to 3,079 ms
(PostgreSQL 18, 16, 13: 2,237, 2,997 and 3,079 ms); a release with more files is measured again before its figure is
given here, and a migration that rewrites a large table would say so in its release notes.

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
PostgreSQL as the repository and as the monitored server. Run on 2026-11-11 (PST) against PostgreSQL 13, 16 and 18 on
the build of rel-join-w1 at 42cbbe2 (99 migration files, the newest 0110_join_release.sql; the proof's own tree differed
from it in proof scripts and docs only), green on each, as the lab box jobs s175-upg13 (13) and s175-loop1 (16, then
18). The numbers are PostgreSQL 16's; 13's and 18's are in brackets where they differ:

- **The release.** v0.3.0's binary and SBOM match `SHA256SUMS`. The SBOM names exactly the 35 modules the binary
  itself reports (`go version -m`: name, version and hash of each) and the same build settings. The signature of
  `SHA256SUMS` verifies for the release workflow at that tag, and another tag's identity is refused: online, and
  from the bundle on the host with no route out.
- **The install without Internet access.** The host reached neither github.com nor a public address. It installed
  v0.3.0 from the mirror folder with the checksum verified; a mirror copy changed by one byte was refused and nothing
  was installed.
- **The old store.** v0.3.0's own `migrate` (60 files) as an owner with CREATEROLE, the logins `pgvigil roles`
  prints, three days of v0.3.0's demo (12 instances; 429,510 rows in 107 tables [13: 429,444; 18: 429,545]), and its
  collector running
  under the collector's login against a live server through a `pg_monitor` login.
- **The upgrade, in the order above.** This build refused to run on the old schema (exit 1, naming the file and
  `pgvigil migrate`). `migrate` applied 39 files in 2,997 ms [13: 3,079; 18: 2,237], and a second run none. Every
  one of the 107 tables held the row count it held before; in the 101 that hold rows, a hash of those rows over the
  columns v0.3.0 had was the same before and after. The 144 tables this build adds held what a migrate of an empty
  repository leaves: no rows but the two seeded lists (pg_threshold_keys 8, pgaudit_rules 6). `./pgvigil install`
  ended `installed and running`, the config and the env file byte for byte as before, the unit running as `pgvigil`
  and still without a restart 209 s after the upgrade [13: 213 s; 18: 210 s].
- **The collector.** Under the collector's login, all 20 collections that ended ok under v0.3.0 (20 ok, 0 partial,
  7 skipped) ended ok under this build (30 ok, 0 partial, 8 skipped), and none ended in an error or newly partial
  [13: 18 of 18; v0.3.0 18 ok, 1 partial, 8 skipped, this build 28 ok, 1 partial, 9 skipped].
- **The pages.** This build's `serve`, under the UI's login, rendered 503 pages over the upgraded store with no error
  box, no API answer of 400 or over, no failed request and no script exception (the same 503 on 13, 16 and 18): the 29
  root pages, every tab of all 13 instances (469: 36 each, 37 where a pooler is read) and the 5 drill pages they link
  to (a database, a table, an index, a job, the statement comparison). With the UI login's read role taken away the same walk fails at its first page,
  so a broken page would not pass unseen. The store of v0.3.0 holds PostgreSQL instances only, so the SQL Server
  pages are not in this walk (`scripts/proof-a11y.sh` walks them on a fresh store).
- **After the restart.** The rows outside the live instance were still the counts from before the upgrade (107 tables,
  426,345 rows [13: 426,347; 18: 426,332]).
- **The way back.** The owner's dump, restored by the owner into a second database, held every table's row count and
  row hash from before the upgrade, and v0.3.0, reinstalled from the mirror, collected on it.
- **The installer first.** On that restored store the installer for this build replaced the binary and ended with
  `the service did not come up` (exit 1), naming the migration file and `pgvigil migrate` in that same line, as the
  journal did; the unit restarted once in 12 s. After the owner's `migrate` the unit came up by itself at its next
  restart, and the rows outside the live instance were the counts from before.

Not proven here: Windows; a start from a version older than v0.3.0 (the one release that carries the installer); a
store larger than the demo's three days; a repository behind a pooler.
