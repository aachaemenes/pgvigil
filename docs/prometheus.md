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
- A token file is read again when it changes; the old token is still accepted for 60 seconds, so a rotation costs no
  failed scrape. Write the new file, then change Prometheus' `credentials_file`.
- The compare runs on SHA-256 digests in constant time. A token in the URL is refused (400). Five refused tokens from
  one address in a minute refuse that address for the rest of the minute (429). A request without credentials logs one
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

- Gauges only, no explicit timestamps: the newest collected value of each metric, in base units. A value older than
  its freshness (10 minutes; IO 30 minutes; host 15 minutes) is left out, so an alert on a missing series fires;
  `pgvigil_sample_timestamp_seconds{server, family}` gives the newest sample's Unix time of each family within the last
  day, fresh or stale (alert on `time() - pgvigil_sample_timestamp_seconds > 900`).
- Labels: `server` (pgvigil's instance name) and `engine` on every series; `database` on the per-database series.
- The names: 62, one per metric of the Metrics page (internal/web/metrics_prom.go `promNames`, frozen by a test):
  a percent becomes a `_ratio` (/ 100), milliseconds `_seconds`, MB `_bytes` (x 1048576), a count per collection
  interval (deadlocks, checkpoints, requested checkpoints) `_per_second`. For example `pgvigil_sessions`,
  `pgvigil_sessions_connections_used_ratio`, `pgvigil_requests_blocked`, `pgvigil_cpu_sql_ratio`,
  `pgvigil_memory_total_bytes`, `pgvigil_host_load1`.
- The database family: each PostgreSQL instance's totals always, as `pgvigil_instance_*` (the databases summed per
  read, as the Metrics page's default view shows them); with `metrics.databases: on`, each database's own series as
  `pgvigil_database_*{database}` - chosen by size, largest first, or the `include_databases` list, never by backends
  (the set does not churn), cut at `max_databases` with `pgvigil_metrics_databases_cut{server}` the count left out.
  Never sum the per-database series and the instance totals together.
- `pgvigil_instance_info{server, engine, platform, version}` = 1 for every active instance (`tags` with
  `metrics.tags: on`, sorted and comma-wrapped: `,env:prod,team:a,`, so `=~".*,env:prod,.*"` matches one tag).
- `pgvigil_findings{server, severity}`: the instance's findings - the setting rules' and the alert rules' - for each of
  info, warning and critical (0 included). Acknowledged and muted findings are counted (the Findings page's list
  before its own filters); pgvigil's own repository-wide findings (no instance) are not.
- The endpoint's own: `pgvigil_metrics_series`, `pgvigil_metrics_render_seconds`,
  `pgvigil_metrics_last_render_timestamp_seconds`, `pgvigil_metrics_refused_total` (as of the body's render).

## Cost and freshness

The body is rendered in the background, one render at a time, from one set-based read of the stored samples
(`pgvigil.metrics_newest`, migration 0196); a scrape gets the body of the last `cache_seconds` (60) at once, the
previous one while a render runs, and never a body older than twice `cache_seconds`: with nothing that fresh, a scrape
waits for the render up to its `X-Prometheus-Scrape-Timeout-Seconds` and gets 503 when it fails or does not end
(Prometheus then records `up` = 0). The reply is gzip when Prometheus asks for it (it does by default). At 1,000
instances expect about 42,400 series by default and about 82,400 with `databases: on` and the default cut.

## Not proven

See `scripts/proof-prometheus.sh` for the rows proven on a box run and the ones left NOT PROVEN.
