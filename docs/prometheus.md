# Prometheus: /metrics on pgvigil serve

`pgvigil serve` can give every active instance's newest collected figures in the Prometheus text format, so a site
that already runs Prometheus and Alertmanager reads pgvigil's collections without a second login on every server.
It is read only and **off unless `pgvigil.yaml` turns it on**.

```yaml
doors:
  prometheus_metrics: on
metrics:
  token: file:/etc/pgvigil/metrics.token   # or env:NAME; 32 bytes at least
  cache_seconds: 60                         # a body's life before the next render
  databases: off                            # each database's own series (the instance totals are always there)
  max_databases: 50                         # per instance, the largest first
  include_databases: [app, billing]         # in place of the largest
  tags: off                                 # the instance's tags on pgvigil_instance_info
```

## What it opens

Server names, engines, platforms, versions and every figure below (tags and database names when `metrics.tags` /
`metrics.databases` are on) - to everyone who reads that Prometheus, its remote_write targets included. While the
switch is on, serve says so in one WARN at start. Off, `/metrics` answers 404 with the words 'off on this install:
doors.prometheus_metrics in pgvigil.yaml turns on the Prometheus endpoint /metrics; ...'. The switch is in the file
only, never on a page.

## Reading it

A request needs a signed-in session (the UI login's cookie) or `Authorization: Bearer <token>`:

- `metrics.token` is `file:/path` or `env:NAME`, never the token itself; surrounding whitespace is trimmed. serve
  refuses to start when the token resolves to nothing or to under 32 bytes, and when the door is on under `-no-login`
  without a token. With the UI login on and no token, only a signed-in browser can read `/metrics` (serve says so at
  start).
- A token file is read again when its content changes (checked at most once a second); the old token is still
  accepted for 60 seconds after the change. Write the new file, then change Prometheus' `credentials_file` within 60
  seconds: no scrape is refused.
- The compare runs on SHA-256 digests in constant time. A token in the URL is refused (400). Five refused tokens from
  one address in a minute refuse that address's wrong tokens for the rest of the minute (429); the right token still
  passes, so another sender on a shared address (NAT, a proxy) cannot keep Prometheus out. A request without credentials logs one
  WARN per address per minute. Every refusal counts in `pgvigil_metrics_refused_total`.
- A non-loopback listen is TLS only (`pgvigil serve -tls-cert -tls-key`, as for the page).

```yaml
scrape_configs:
  - job_name: pgvigil
    scheme: https
    scrape_interval: 60s
    scrape_timeout: 30s          # SQLMonitor's sql_exporter uses 120 s on a large fleet
    metrics_path: /metrics
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/pgvigil.token
    tls_config:
      ca_file: /etc/prometheus/pgvigil-ca.pem
    static_configs:
      - targets: ['pgvigil.example.internal:8443']
```

## The body

- Gauges, plus one counter (`pgvigil_metrics_refused_total`), no explicit timestamps: the newest collected value of each metric, in base units. A value older than
  its freshness (10 minutes; IO 30 minutes; host 15 minutes) is left out, so an alert on a missing series fires;
  `pgvigil_sample_timestamp_seconds{server, family}` gives the newest sample's Unix time of each family, fresh or stale,
  however old (alert on `time() - pgvigil_sample_timestamp_seconds{family!="collection"} > 900`: an instance silent for
  days keeps firing; the collection family's sample is the end of its newest ENDED hour, so up to two hours old by
  design - alert on it past 7200 s).
- Labels: `server` (pgvigil's instance name) on every instance series; `engine` on the figures and on
  `pgvigil_instance_info`; `family`, `severity`, `database` and `collection` on their own series; the endpoint's own
  four series have none.
- The names: 113, one per metric of the Metrics page (internal/web/metrics_prom.go `promNames`, frozen by a test):
  a percent becomes a `_ratio` (/ 100), milliseconds `_seconds`, MB `_bytes` (x 1048576), a count per collection
  interval (deadlocks, checkpoints, requested checkpoints) `_per_second`.
  - 62 of the sessions, database, server, IO, requests, CPU, scheduler, memory and host families: for example
    `pgvigil_sessions`, `pgvigil_sessions_connections_used_ratio`, `pgvigil_requests_blocked`, `pgvigil_cpu_sql_ratio`,
    `pgvigil_memory_total_bytes`, `pgvigil_host_load1`.
  - 43 of SQL Server's performance counters, `pgvigil_counters_<metric>`: a rate `_per_second`
    (`pgvigil_counters_batch_requests_per_second`), a percent `_ratio` (`pgvigil_counters_buffer_cache_hit_ratio`), an
    average in milliseconds `_seconds` (`pgvigil_counters_avg_lock_wait_seconds`; the log flush wait time per second
    `pgvigil_counters_log_flush_wait_seconds_per_second`), a count kept as it is (`pgvigil_counters_user_connections`).
    Five names say what the value is rather than the grid's label: `pgvigil_counters_errors_per_second` (all
    errors), `pgvigil_counters_compilations_per_batch_ratio` and `pgvigil_counters_recompilations_per_compilation_ratio`
    (the grid's per 100, / 100), `pgvigil_counters_page_splits_per_batch` (the grid's per 100 batches, / 100) and
    `pgvigil_counters_page_life_expectancy_per_4gb_seconds`.
  - 2 of the Extended Events capture: `pgvigil_xe_client_timeouts_per_second` and
    `pgvigil_xe_client_timeouts_left_out_per_second` (the grid's per minute, / 60).
  - 1 of the waits: `pgvigil_waits_wait_per_core_ratio`, wait seconds per core per second (the grid's wait seconds per
    core per minute, / 60), benign waits and SQLMonitor's per-core list left out as on the page.
  - 5 of the Collection family, one series per collection under the label `collection` (never `database`):
    `pgvigil_collection_duration_seconds`, `_cpu_seconds`, `_logical_reads`, `_failed_ratio`, `_import_seconds`
    `{server, engine, collection}`, each the hour that ended last. The instance's worst collection - the Metrics page's
    instance row - is not a series of its own: `max by (server) (pgvigil_collection_duration_seconds)` gives it (a
    label naming the worst collection would change hour by hour). `metrics.databases` and `max_databases` do not touch
    these series: a collection is not a database.
- Not exported: `counters.percent_log_used` (`promNotExported`, the same file) - SQL Server's Percent Log Used for
  `_Total` is the whole server's log space, so one database's log near full among empty ones reads low, and an alert
  on it would miss the case it is for; it comes with per-database series.
- Freshness of the four SQL Server families: a counter 10 minutes, an Agent jobs figure 15 minutes, a per-database
  counter 30 minutes (its read every 5 minutes); the Extended Events and the waits 10 minutes; a collection 2 hours.
- The database family: each PostgreSQL instance's totals always, as `pgvigil_instance_*` (the databases summed per
  read, as the Metrics page's default view shows them); with `metrics.databases: on`, each database's own series as
  `pgvigil_database_*{database}` - chosen by size, largest first, or the `include_databases` list, never by backends
  (the set does not churn), cut at `max_databases` with `pgvigil_metrics_databases_cut{server}` the count left out.
  Never sum the per-database series and the instance totals together.
- Known limits of the SQL Server counters:
  - A counter is the newest read's value: a metric with no point at that read (a rate just after a restart, a ratio
    under its floor - the compilations per batch under 5 batch requests a second) has no sample, never an older
    read's value; so too the waits of an instance with no scheduler count (every Azure SQL Database instance).
  - The per-database counters (write transactions, log flush waits, the log flush wait time, active transactions,
    log growths) are the server's total (`_Total`), never one database's.
  - The Agent jobs started, failed and succeeded and the log growths are counts per read (every 5 minutes) held until
    the next read: never `sum_over_time` them over 15-second scrapes (it counts each read about 20 times); `max_over_time`
    or the newest value.
- `pgvigil_instance_info{server, engine, platform, version}` = 1 for every active instance (`tags` with
  `metrics.tags: on`, sorted and comma-wrapped: `,env:prod,team:a,`, so `=~".*,env:prod,.*"` matches one tag).
- `pgvigil_findings{server, severity}`: the instance's findings - the setting rules' and the alert rules' - for each of
  info, warning and critical (0 included). Acknowledged and muted findings are counted (the Findings page's list
  before its own filters); pgvigil's own repository-wide findings (no instance) are not.
- The endpoint's own: `pgvigil_metrics_series`, `pgvigil_metrics_render_seconds`,
  `pgvigil_metrics_last_render_timestamp_seconds`, `pgvigil_metrics_refused_total` (as of the body's render).

## Cost and freshness

The body is rendered in the background, one render at a time, from one set-based read of the stored samples
(`pgvigil.metrics_newest`, migration 0196; 0323 reads the four SQL Server families through set functions called once
for every instance, never once per instance); a scrape gets the body of the last `cache_seconds` (60) at once, the
previous one while a render runs, and never a body older than twice `cache_seconds`: with nothing that fresh, a scrape
waits for the render up to its `X-Prometheus-Scrape-Timeout-Seconds` and gets 503 when it fails or does not end
(Prometheus then records `up` = 0). The reply is gzip when Prometheus asks for it (it does by default). At 1,000
PostgreSQL instances expect about 42,400 series by default; a SQL Server instance adds 46 (counters, Extended Events,
waits) and 5 per collection it runs (about 30: about 196); `databases: on` adds 10 series per exported database, up to
`max_databases` per PostgreSQL instance (about 82,400 at 1,000 instances with five databases each; the upper bound is
10 x `max_databases` per PostgreSQL instance, 500 at the default cut). A rate's lookback is each instance's own (3 x its
longest dbstats, serverstats or iostats interval, 15 minutes at least), as on the Metrics page.

## Not proven

See `scripts/proof-prometheus.sh` for the rows proven on a box run and the ones left NOT PROVEN.
