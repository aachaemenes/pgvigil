# The remote collector: servers pgvigil cannot reach

Some networks let no outside server connect to their databases. For them pgvigil runs as a **remote collector**: the
same signed program, in a collector-only mode, on one Linux or Windows box inside that network (a **site**). It reads
the site's PostgreSQL and SQL Server instances with the same read-only logins as any pgvigil and, every interval,
writes what it read as a **bundle** of plain files. Your pgvigil (the **hub**) takes each bundle in once, checks it, and
shows those instances beside the rest of the fleet, as of the last bundle.

The bundle's format is [remote-bundle-format.md](remote-bundle-format.md).

## What the remote collector does, and does not do

- It runs `pgvigil run` with a `remote:` block and no `repository:` block: no repository, no web page, no alerts, no
  report mail, no DBA Dash door, no request queue. A file that also sets a `repository.dsn` (or a hub's
  `remote_sites:`, `export:`, `dbadash:` or `reports_dsn`) is refused.
- It reads its instances (from its own `pgvigil-remote.yaml` only) with their usual read-only logins: `pg_monitor` on
  PostgreSQL, the read-only grants of [sqlserver.md](sqlserver.md) on SQL Server.
- It writes only two folders: the **outbox** (the bundles) and the **state folder** (how far each source was read,
  the bundle sequence, a lock, and the signing key when it signs). A restart neither sends a log line or event twice
  nor skips one: the sequence is reserved before a bundle opens, the bundle is written as `.part` and renamed whole,
  and only then are the read positions kept; a crash in between is recovered from the newest finished bundle's
  manifest. A snapshot read (sessions, waits, counters) is simply not taken while the collector is down.
- No statement text leaves it. `query_text` is `hash` (the default on a remote collector: each text column holds the
  SHA-256 of its normalized form, so the same statement groups across intervals) or `none` (no text at all); `full`
  and `normalized` are refused at start ('no statement text leaves a remote collector'). Passwords in log lines and
  job steps are masked before anything is written, as on any collector.
- It connects to nothing outside the site except, when `push:` is set, HTTPS to one Azure Blob storage account (or
  its private endpoint) - under a managed identity also the VM's own link-local metadata endpoint for its token -,
  and, for an RDS or Aurora instance with an `aws:` block, that region's AWS APIs.

## Install on the site's box

The release carries `pgvigil-remote-<tag>-linux-amd64.tar.gz` and `pgvigil-remote-<tag>-windows-amd64.zip` beside the
offline bundles, listed in the signed `SHA256SUMS.offline` ([airgap.md](airgap.md) has the verification: put
`pgvigil-remote-<tag>-<os>-amd64.<ext>` where its recipe names `pgvigil-offline-*`). Each holds
the binaries (plain and FIPS), their SBOM, the installer, this page, [airgap.md](airgap.md) and a sample
`pgvigil-remote.yaml`.

```yaml
# pgvigil-remote.yaml on the site's box
remote:
  site: plant-east            # lower-case letters, digits, _ . - ; a letter or digit first; at most 63
  collector: c1               # this box's name within the site
  interval: 5m                # how long a bundle covers: 1m to 60m (5m by default)
  outbox: /var/lib/pgvigil-remote/outbox
  state_dir: /var/lib/pgvigil-remote/state
  keep_days: 7                # a bundle stays this long after it was pushed (or written, without push:)
  max_mb: 2048                # the outbox's cap: past it the oldest bundle goes first, logged ERROR
  sign: false                 # true: each manifest signed with this box's Ed25519 key (pgvigil-remote remote init)
  # push:                     # optional: the direct push to Azure Blob (below)
query_text: hash              # hash (default) or none
instances:
  - name: SQL01
    engine: sqlserver
    dsn: env:SQL01_DSN
  - name: pg-orders
    dsn: file:/etc/pgvigil-remote/pg-orders.dsn
```

The remote collector is its own binary, `pgvigil-remote`, and its own service, apart from any pgvigil on the box:

- Linux: `sudo ./install.sh --remote` installs `/usr/local/bin/pgvigil-remote`, the unit `pgvigil-remote.service` under
  the account `pgvigil-remote`, the configuration `/etc/pgvigil-remote/pgvigil-remote.yaml` (its secrets in
  `/etc/pgvigil-remote/pgvigil-remote.env`) and the two folders `/var/lib/pgvigil-remote/outbox` and
  `/var/lib/pgvigil-remote/state`, read from the file's `remote:` block (no second flag). The unit writes those two
  folders only (`ReadWritePaths=`, `ProtectSystem=strict`, `ProtectHome=yes`): a folder under `/home` is refused at
  install, in words.
- Windows: `.\install.ps1 -Remote` installs `%ProgramFiles%\pgvigil-remote\pgvigil-remote.exe` (put on the machine's PATH), the
  service `pgvigil-remote` under `NT SERVICE\pgvigil-remote`, and `C:\ProgramData\pgvigil-remote\pgvigil-remote.yaml`
  with its `outbox` and `state` folders, their ACL SYSTEM, Administrators and the service account only.

Its commands read as that binary's, on Linux and Windows alike: `pgvigil-remote remote init`,
`pgvigil-remote bundle inspect ...` (a pgvigil on the same PATH keeps its own name).

`pgvigil-remote bundle inspect [-key ed25519:<public key>]... [-max-mb N] <bundle folder>` prints a bundle's manifest, the
result of its sums and row counts, and its signature's: checked only against a key given with `-key` (without one a
signed bundle reads 'signed, not checked (no -key given)'). Only a bundle that passes its checks has every line
printed, as plain JSON; `-max-mb` (512 by default) caps what a view file may uncompress to. It is what a security
team reads before a bundle leaves.

## Getting the bundles out

Two ways, whichever the site allows.

**(a) The direct push to Azure Blob (recommended where the box may reach one storage account).**

```yaml
remote:
  push:
    type: azure_blob
    container: pgvigil-bundles
    prefix: bundles                              # the folder in the container; the hub's drop names the same one
    sas_url: file:/etc/pgvigil-remote/push.sas   # a SAS on that container with Create and Write only
```

- `sas_url` names the file (or `env:` variable) that holds the storage account's address with the SAS token after
  `?`: `https://<account>.blob.core.windows.net/?sv=...`. The container is `container:`. Not the Azure Portal's
  container 'Blob SAS URL', which already ends in the container's name.
- The credential may only write: a SAS with **Create + Write** on that container (no Read, List or Delete), or, on an
  Azure VM, its managed identity with a custom role holding only the blob write data actions on that container (then
  `account_url: https://<account>.blob.core.windows.net` in place of `sas_url`: a destination takes exactly one way
  in - `sas_url`, `account_url` or `connection_string`). A retry overwrites the same bytes.
- Each finished bundle is uploaded view files and `SHA256SUMS` first, `manifest.json` last: a blob is visible only
  once it is committed, so a hub that finds the manifest finds every file whole.
- A failed upload is tried three times, then again at the next interval; the outbox is the queue. The hub polls the
  container with a read-only credential (Read + List).

**(b) The outbox folder, moved by the site's own tool** (a box that may not reach cloud storage): an Azure Blob
container, an S3 or GCS bucket the hub reads with a read-only key; an SMB / NFS share or an SFTP drop the hub reads; a
one-way copy or USB for a closed network. Whatever moves it must leave out `*.part` folders and should upload under a
temporary name where it can; a bundle copied half-way is waited for by the hub, never loaded half-way (below). An
operating system's litter in a bundle's folder (`._*`, `.DS_Store`, `Thumbs.db`, `desktop.ini`) is ignored and never
read; any other file the manifest does not list (a copy tool's temp file left behind) sets the bundle aside ('extra')
once the settle time is past.
Filebeat may carry the files where a log pipeline is the only way out, only if it delivers them unchanged (the sums
prove it): there is no second format.

An Event Grid notification instead of polling is a later option, not in v0.4.0.

## On the hub: remote_sites

```yaml
# the hub's pgvigil.yaml
remote_sites:
  - name: plant-east
    drop:                                   # folder | s3 (GCS through its S3 endpoint) | azure_blob
      type: azure_blob
      container: pgvigil-bundles
      prefix: bundles                       # the push's prefix: the folder the site's bundles land in
      sas_url: env:PLANT_EAST_READ_SAS      # Read + List only: the account's address with the token, as above
    tags: [site:plant-east]
    expected_every: 5m      # how often a bundle arrives: the interval for a direct push, the copy's cadence otherwise
    gap_wait: 15m           # a missing bundle is waited for this long (3 x expected_every by default)
    collectors:
      - name: c1
        keys: []            # 'ed25519:<public key>' as pgvigil-remote remote init prints it, when the collector signs
  - name: plant-west
    drop:                                   # a GCS bucket through its S3 endpoint (or any S3 bucket)
      type: s3
      bucket: pgvigil-bundles-west
      prefix: bundles
      endpoint: https://storage.googleapis.com
      region: auto
      profile: plant-west-read              # this site's own HMAC read key: a profile in the hub's AWS credentials file
    collectors:
      - name: c1
```

A bucket or container drop needs its `prefix:` (refused at start without one: at the bucket's root the bundles would
mix with anything else kept there); a folder drop is read where it is. Each site has its own drop and its own read key:
two sites on one drop are refused at start, and on S3 or GCS each site reads with its own `profile:`, never one
environment key shared by two sites.

**Ingest's own login.** The hub reads its sites on a login of its own, a member of the role `pgvigil_ingest` (0329
makes the role) and of nothing else - never the collector's login (a collector login could otherwise load a batch and
hide a site's data), never the repository's owner, never a superuser. Make it as the repository's owner and name it
beside `remote_sites:`:

```sql
CREATE ROLE pgvigil_ingest_hub LOGIN PASSWORD '<a password>' IN ROLE pgvigil_ingest;
```

```yaml
ingest_dsn: env:PGVIGIL_INGEST_DSN   # host=... dbname=<the repository> user=pgvigil_ingest_hub (env: / file:)
```

`pgvigil run` and `pgvigil ingest` check that login at start and refuse, in words, the owner, a superuser, a member of
`pgvigil_collector` or a login outside `pgvigil_ingest`; with no `ingest_dsn:` the sites are not read (said in the log).

Inside `pgvigil run` (and `pgvigil ingest -once`) the hub runs one loop per site - each site on its own, one at a time
across every hub process on the repository, so a site catching up never delays another:

- lists the site's folder once a round: its instance keys, and any collector folder the site does not list (marked
  by name, its bundles not read); then each key's `<day>/` folders from the day of its newest loaded bundle (and the
  days of its retried bundles) to today; a folder marker key (`<folder>/`) is skipped; it never writes, moves or
  deletes anything in a drop;
- checks each bundle in order: the signature first when the collector lists keys; the manifest's site, collector,
  instance and sequence against the configuration and the folder; the format version (a newer one is set aside and
  read after the hub's upgrade); every view against pgvigil's own list (an unknown view is refused); each file's
  size, sum and row count; a bundle whose views uncompress past 2 GiB in all is set aside ('too_big'). Every file is
  read under a cap - `manifest.json` and `SHA256SUMS` 1 MiB, `manifest.sig` 4 KiB, a view file the bytes its manifest
  names (a bucket or container is asked for one byte more, never the whole object): a file past its cap is set aside
  ('too_big', the file named) at once, as nothing a copy still running writes is longer, and read no further. The **settle
  time** (`gap_wait`) runs from when the hub FIRST SAW the bundle's folder, never from the bundle's window end, so a
  backlog copied late is not past it on arrival: inside it, any problem - a file missing or short, a signature not there
  yet, a copy tool's temp file - is a copy still running and is waited for (the bundles after it wait too); past it
  the bundle is set aside with its reason. A bundle set aside as missing, short, a newer format, a signature the hub
  could not check, an unknown view or a name owned elsewhere is read again by itself once the hub (or the copy) is put
  right. Any other is kept until `pgvigil ingest -retry <site>/<collector>/<instance-key>/<day>/<seq>-<end>` (the
  bundle's folder, relative to the drop), run once the copy is put right, clears its mark and reads the site again -
  even a bundle older than its stream's newest, which then loads after a gap; the batches already in stay in. A drop
  error or a load the repository refuses holds that instance alone, never the round, and past the settle time is
  marked ('drop error', 'load') with its text;
- loads the batches in their order, **each batch in its own transaction with its ledger row**, so a bundle that stops
  part-way resumes at its first batch not loaded, and a bundle seen twice is loaded once;
- keeps each instance's bundles in sequence: a missing one is waited for `gap_wait`, then the gap is recorded and the
  instance goes on; a stalled bundle holds its instance's later ones for `gap_wait`, then is set aside. A bundle older
  than one already loaded is marked late and loads only through `-retry`.

The site's instances are named `<site>/<name>` (`plant-east/SQL01`), so two sites' `SQL01` never meet, and carry the
site's tags. A name another site or the hub's own file holds is refused and its bundle set aside ('instance
<site>/<name> is owned elsewhere'). An instance an admin
disabled stays disabled. One repository holds every site; a viewer of it reads every instance (a tag is no access
boundary): a repository per client is the way to keep clients apart.

## What a remote instance shows

- **As of the last bundle.** Every page of a remote instance says `as of <time> (remote collector <c> of site <s>, a
  bundle every <interval>)`. Its collections are judged fresh or stale against that time, with the intervals its
  collector reported, never against the hub's clock: a site that copies once an hour is not 'offline' between
  copies. An 'as of' that is not today names its day. Its header turns Offline when the hub has LOADED nothing of
  the site for twice the longer of `expected_every` and the bundle interval (the hub's clock, never the site's: a site
  clock that runs slow or fast changes nothing) - 'site <s> has gone quiet: last bundle <time>', said on the instance's
  Summary too - or when its collector collected nothing healthy in the 30 minutes before its newest bundle.
- **A failed read shows as failed.** A read that failed on the site (a login refused, a secret not found, a query that
  failed) shows as failed with its reason, from the bundle's manifest, as for an instance the hub reads itself: never
  as healthy, never as a gap.
- **No live door.** Actions (cancel, terminate, kill, a job's start, stop, enable or disable, a backup's verify, a plan
  evict), EXPLAIN and EXPLAIN ANALYZE, the planner check, the index advisor, Community tools, a custom report that runs
  on the instance, a histogram, a fragmentation read and a plan read by its handle are off on it, each with the same
  sentence: `instance <n> is read from remote collector <c> of site <s>: no live connection reaches it`. A custom
  report that reads only the repository runs as for any instance.
- **Statement text** is its fingerprint (`hash`) or nothing (`none`), as its bundles say: numbers, waits, states and
  groupings work as for any instance, and a statement shows as `fingerprint <hex>` (the SHA-256 of its normalized
  text); a statement's text, a plan's text, a deadlock's graph, a job step's command and a module's body do not, and the
  page says why ('this instance's query_text policy is "hash" (a remote collector's) ...'); the text search skips it.
- **The Collector page** lists each remote collector, a configured one that never sent included: its silence by the
  hub's newest load of it (sending; a warning past twice the longer of `expected_every` and the bundle interval;
  critical past six times; 'not in remote_sites:' once the configuration no longer lists it), its newest bundle, its
  heartbeat, and the bundles ingest found missing, set aside (with the newest reason), late or in conflict.

## Alerts and findings

- A site the hub has loaded nothing of raises its silence finding - by the hub's newest load (its own clock), a
  warning after twice the longer of `expected_every` and the bundle interval, critical after six times: per site
  (`site <s> has gone quiet: last bundle <time>`, sent as an alert like any repository-wide finding; a site that never
  sent is judged from its first sync), per configured collector of a site that still sends (`collector <c> of site <s>
  has gone quiet`), and per instance (`instance <site>/<name> of site <s> has gone quiet: last bundle <time>`). A site
  taken out of `remote_sites:` raises none.
- Every other finding of a remote instance is computed from its bundles as they arrive, so it fires as late as the
  bundle interval plus the transfer. A finding judged over a recent window cannot fire at all once the delay is longer
  than its window. [remote-windows.md](remote-windows.md) lists which findings fire late, which cannot fire past a
  given delay, and which read an age that the delay makes look older.
- A finding of a remote instance clears no sooner than its bundle interval plus its site's `expected_every` (at least
  the channel's `clear_after`), so it neither clears between two bundles nor fires again with each one.
- A remote collector's heartbeat lands only in the hub's remote collectors list: a transfer's delay never reads as a
  collector down, and never holds the instances' alerts as 'collector or network'.

## What sums do and do not give

The sums and the row counts catch a file damaged, cut or changed on the way. They do not say who wrote a bundle: anyone
who can write the drop can change a file and its sum together. Who may write a drop is its access rights: each site its
own drop and its own read key, the site's identity the only writer, the hub's credential read-only. A collector may
also sign (`remote.sign: true`): `pgvigil-remote remote init` makes an Ed25519 key on the collector's box (mode 0600, never
printed) and prints the public key for the hub's `keys:`; the hub checks the signature before it reads any other file.
pgvigil does not encrypt the files: in transit the transport's encryption protects them (HTTPS, SFTP), at rest the
store's own.

## Removing the remote collector

- `pgvigil-remote uninstall -remote` removes the service (the Linux unit, the Windows service) only - never a hub's or
  another pgvigil's on the box.
- `-purge` also removes the outbox's bundles, the state folder's own files, the configuration folder's own files and the
  binary, each folder once it is empty; anything else in them is kept and named.
- `-purge` refuses while the outbox holds a bundle not yet pushed - it says how many and the newest one's window end:
  'a bundle not yet carried to the hub is lost' - unless `-force` is given (a bundle with its `.pushed` marker counts as
  carried).
- On Linux the account `pgvigil-remote` stays, named in the output; `userdel pgvigil-remote` removes it.

## Retention

- On the site: a bundle stays `keep_days` (7) after it was pushed, or after it was written when the outbox is moved by
  the site's tool; `max_mb` (2048) caps the outbox, the oldest bundle first (logged ERROR; the hub sees the gap).
- In the drop: the hub never deletes. Give the container or bucket a lifecycle rule (Azure lifecycle management, S3 or
  GCS lifecycle), or let the site's own clean-up remove old bundles.
- On the hub: the ledgers are kept 90 days, each stream's newest sequence for good, a set-aside or late bundle's reason
  until a person clears it; the data by the repository's own retention (`pgvigil purge`).

## Known limits

- Alerts are as fresh as the interval plus the transfer; a recent-window finding cannot fire past its window
  ([remote-windows.md](remote-windows.md)).
- Admin's per-instance edits on the hub never reach a remote collector: its settings are its own `pgvigil-remote.yaml`.
- The SQL Server error log's search strings an admin sets per instance on the hub (`errorlog:search`) never reach a
  remote site either: a remote instance's error log is read with no search strings.
- `/metrics` ([prometheus.md](prometheus.md)) exports a remote instance's newest loaded values and leaves out a value
  older than its freshness (10 minutes; IO 30 minutes; host 15 minutes): once a site's delay passes that, its series
  are absent rather than late, and an alert on a missing series fires between bundles.
  `pgvigil_sample_timestamp_seconds{server, family}` gives its newest sample's time.
- An Event Grid notification instead of polling is a later option.
- The hub lists a site's whole drop prefix each round - the site's lifecycle rule (`keep_days`) bounds it; a one-level
  listing is a later row.
- A remote collector in a Kubernetes pod is not in v0.4.0, and nothing in it precludes one: a read-only root with the
  two folders set where the pod may write, and credentials by `env:` / `file:`.

## Not proven

- Google Cloud Storage itself (its S3 path is proven against an S3-compatible emulator only), unless the release's
  live row for it is named in its notes; S3 and Azure Blob live only as far as the release's live rows go.
- A managed identity's push (no Azure VM in the proof).
- Event Grid (not built).
- The site's own transfer tools and Filebeat.
- RDS, Aurora or Azure instances behind a remote collector (their cloud API reads need the site's network and keys).
- A collector of over 100 instances (a bundle's size per interval).
- Any Windows leg the proof's Windows box cannot reach.
