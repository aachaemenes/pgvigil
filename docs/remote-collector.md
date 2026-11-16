# The remote collector: servers pgvigil cannot reach

Some networks let no outside server connect to their databases. For them pgvigil runs as a **remote collector**: the
same signed program, in a collector-only mode, on one Linux or Windows box inside that network (a **site**). It reads
the site's PostgreSQL and SQL Server instances with the same read-only logins as any pgvigil and, every interval,
writes what it read as a **bundle** of plain files. Your pgvigil (the **hub**) takes each bundle in once, checks it, and
shows those instances beside the rest of the fleet, as of the last bundle.

The bundle's format is [remote-bundle-format.md](remote-bundle-format.md).

## What the remote collector does, and does not do

- It runs `pgvigil run` with a `remote:` block and no `repository:` block: no repository, no web page, no alerts, no
  report mail, no DBA Dash door, no request queue. A file with both blocks is refused.
- It reads its instances (from its own `pgvigil.yaml` only) with their usual read-only logins: `pg_monitor` on
  PostgreSQL, the read-only grants of [sqlserver.md](sqlserver.md) on SQL Server.
- It writes only two folders: the **outbox** (the bundles) and the **state folder** (how far each source was read,
  the bundle sequence, a lock). A restart neither sends a row twice nor skips one: the sequence is reserved before a
  bundle opens, the bundle is written as `.part` and renamed whole, and only then are the read positions kept; a
  crash in between is recovered from the newest finished bundle's manifest.
- No statement text leaves it. `query_text` is `hash` (the default on a remote collector: each text column holds the
  SHA-256 of its normalized form, so the same statement groups across intervals) or `none` (no text at all); `full`
  and `normalized` are refused at start ('no statement text leaves a remote collector'). Passwords in log lines and
  job steps are masked before anything is written, as on any collector.
- It connects to nothing outside the site except, when `push:` is set, HTTPS to one Azure Blob storage account (or
  its private endpoint), and, for an RDS or Aurora instance with an `aws:` block, that region's AWS APIs.

## Install on the site's box

The release carries `pgvigil-remote-<tag>-linux-amd64.tar.gz` and `pgvigil-remote-<tag>-windows-amd64.zip` beside the
offline bundles, listed in the signed `SHA256SUMS.offline` ([airgap.md](airgap.md) has the verification). Each holds
the binaries (plain and FIPS), the installer, this page and a sample `pgvigil-remote.yaml`.

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
  sign: false                 # true: each manifest signed with this box's Ed25519 key (pgvigil remote init)
  # push:                     # optional: the direct push to Azure Blob (below)
query_text: hash              # hash (default) or none
instances:
  - name: SQL01
    engine: sqlserver
    dsn: env:SQL01_DSN
  - name: pg-orders
    dsn: file:/etc/pgvigil-remote/pg-orders.dsn
```

- Linux: `sudo ./install.sh --remote` installs the service with write access to the outbox and the state folder only
  (the unit keeps `ProtectSystem=strict` and `ProtectHome=yes`: a folder under `/home` is refused).
- Windows: `.\install.ps1 -Remote` installs the Windows service and makes the two folders with an ACL for the service
  account only.

`pgvigil bundle inspect <bundle folder>` prints a bundle's manifest and every line as plain JSON, with the result of
its sums and, when it is signed, of its signature: what a security team reads before a bundle leaves.

## Getting the bundles out

Two ways, whichever the site allows.

**(a) The direct push to Azure Blob (recommended where the box may reach one storage account).**

```yaml
remote:
  push:
    type: azure_blob
    account_url: https://plantexport.blob.core.windows.net
    container: pgvigil-bundles
    sas_url: file:/etc/pgvigil-remote/push.sas   # a SAS on that container with Create and Write only
```

- The credential may only write: a SAS with **Create + Write** on that container (no Read, List or Delete), or, on an
  Azure VM, its managed identity with a custom role holding only the blob write data actions on that container (leave
  `sas_url` out: the default credential is used). A retry overwrites the same bytes.
- Each finished bundle is uploaded view files and `SHA256SUMS` first, `manifest.json` last: a blob is visible only
  once it is committed, so a hub that finds the manifest finds every file whole.
- A failed upload is retried each interval; the outbox is the queue. The hub polls the container with a read-only
  credential (Read + List).

**(b) The outbox folder, moved by the site's own tool** (a box that may not reach cloud storage): an Azure Blob
container, an S3 or GCS bucket the hub reads with a read-only key; an SMB / NFS share or an SFTP drop the hub reads; a
one-way copy or USB for a closed network. Whatever moves it must leave out `*.part` folders and should upload under a
temporary name where it can; a bundle copied half-way is retried by the hub, never loaded half-way (below).
Filebeat may carry the files where a log pipeline is the only way out, only if it delivers them unchanged (the sums
prove it): there is no second format.

An Event Grid notification instead of polling is a later option, not in v0.4.0.

## On the hub: remote_sites

```yaml
# the hub's pgvigil.yaml
remote_sites:
  - name: plant-east
    drop:                                   # folder | s3 (GCS: s3 with its endpoint and HMAC keys) | azure_blob
      type: azure_blob
      account_url: https://plantexport.blob.core.windows.net
      container: pgvigil-bundles
      sas_url: env:PLANT_EAST_READ_SAS       # Read + List only
    tags: [site:plant-east]
    expected_every: 5m      # how often a bundle arrives: the interval for a direct push, the copy's cadence otherwise
    gap_wait: 15m           # a missing bundle is waited for this long (3 x expected_every by default)
    collectors:
      - name: c1
        keys: []            # 'ed25519:<public key>' as pgvigil remote init prints it, when the collector signs
```

Inside `pgvigil run` (and `pgvigil ingest -once`; `pgvigil ingest -retry <bundle>` loads a set-aside bundle's missing
part later) the hub, one loop per site:

- lists `<site>/<collector>/<instance-key>/<day>/` from the day of its newest loaded bundle to today, and never writes,
  moves or deletes anything in a drop;
- checks each bundle in order: the signature first when the collector lists keys; the manifest's site, collector,
  instance and sequence against the configuration and the folder; the format version (a newer one is set aside and
  read after the hub's upgrade); every view against pgvigil's own list (an unknown view is refused); each file's
  size, sum and row count. A file missing or short while the bundle is younger than the settle time is a copy still
  running: retried. Every other failure sets the bundle aside with its reason, kept in the repository until a person
  clears it;
- loads the batches in their order, **each batch in its own transaction with its ledger row**, so a bundle that stops
  part-way resumes at its first batch not loaded, and a bundle seen twice is loaded once;
- keeps each instance's bundles in sequence: a missing one is waited for `gap_wait`, then the gap is recorded and the
  instance goes on; a stalled bundle holds its instance's later ones for `gap_wait`, then is set aside.

The site's instances are named `<site>/<name>` (`plant-east/SQL01`), so two sites' `SQL01` never meet, and carry the
site's tags. A name another site or the hub's own file holds is refused ('name owned elsewhere'). An instance an admin
disabled stays disabled. One repository holds every site; a viewer of it reads every instance (a tag is no access
boundary): a repository per client is the way to keep clients apart.

## What a remote instance shows

- **As of the last bundle.** Every page of a remote instance says `as of <time> (remote collector <c> of site <s>, a
  bundle every <interval>)`. Its collections are judged fresh or stale against that time, with the intervals its
  collector reported, never against the hub's clock: a site that copies once an hour is not 'offline' between
  copies. Its header turns Offline when the site sends nothing for twice `expected_every` ('site <s> has gone quiet:
  last bundle <age>'), or when its collector collected nothing healthy in the 30 minutes before its newest bundle.
- **No live door.** Actions (cancel, terminate, kill, a job's start, stop, enable or disable, a backup's verify, a plan
  evict), EXPLAIN and EXPLAIN ANALYZE, the planner check, the index advisor, Community tools, a custom report that runs
  on the instance, a histogram, a fragmentation read and a plan read by its handle are off on it, each with the same
  sentence: `instance <n> is read from remote collector <c> of site <s>: no live connection reaches it`. A custom
  report that reads only the repository runs as for any instance.
- **Statement text** is its fingerprint (`hash`) or nothing (`none`): numbers, waits, states and groupings work as for
  any instance; a statement's text, a plan's text, a deadlock's input buffer, a job step's command and a module's body
  do not.
- **The Collector page** lists each remote collector: its site's silence (sending; a warning past twice
  `expected_every`; critical past six times), its newest bundle, its heartbeat, and the bundles ingest found missing,
  set aside (with the newest reason), late or in conflict.

## Alerts and findings

- A site that sends nothing raises its silence finding: per site, a warning after twice `expected_every` and critical
  after six times (`site <s> has gone quiet: last bundle <time>`), and the same per instance.
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
also sign (`remote.sign: true`): `pgvigil remote init` makes an Ed25519 key on the collector's box (mode 0600, never
printed) and prints the public key for the hub's `keys:`; the hub checks the signature before it reads any other file.
pgvigil does not encrypt the files: in transit the transport's encryption protects them (HTTPS, SFTP), at rest the
store's own.

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
- Admin's per-instance edits on the hub never reach a remote collector: its settings are its own `pgvigil.yaml`.
- The SQL Server error log's search strings an admin sets per instance on the hub (`errorlog:search`) never reach a
  remote site either: a remote instance's error log is read with no search strings.
- `/metrics` ([prometheus.md](prometheus.md)) exports a remote instance's newest loaded values with no timestamp of
  their own: its series lag by the bundle interval plus the transfer.
- An Event Grid notification instead of polling is a later option.

## Not proven

- Google Cloud Storage itself (its S3 path is proven against an S3-compatible emulator only), unless the release's
  live row for it is named in its notes; S3 and Azure Blob live only as far as the release's live rows go.
- A managed identity's push (no Azure VM in the proof).
- Event Grid (not built).
- The site's own transfer tools and Filebeat.
- RDS, Aurora or Azure instances behind a remote collector (their cloud API reads need the site's network and keys).
- A collector of over 100 instances (a bundle's size per interval).
- Any Windows leg the proof's Windows box cannot reach.
