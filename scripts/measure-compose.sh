#!/usr/bin/env bash
# A box measurement, not a proof: for each metric family pgvigil.metric_points() serves (0085_alert_rules.sql:
# sessions, database at the instance level and per database, server, io, host, requests, cpu, scheduler, memory),
# how long ONE statement takes that reads the family at fleet scope over 7, 31 and 90 days, against serve's 15 s
# statement_timeout. The statement is the shape a dashboard panel compiles to: the 40 instances of the family's
# engine as a LATERAL list over metric_points, averaged per instance and bucket, then across the instances per
# bucket. Its numbers set the caps of the panel compiler.
#
# It makes a throwaway repository database, migrates it with this tree's pgvigil and inserts 40 PostgreSQL and 40 SQL
# Server instances (one PostgreSQL instance with 150 databases, the others 3 each). Then one STAGE per table, because
# the box's shared disk cannot hold every table's 91 days at once: a stage checks the free disk against its own
# estimate, fills 91 days of synthetic rows into its table at the collection's default cadence (counters only grow,
# gauges vary), runs VACUUM ANALYZE, measures the families that read the table, prints the table's rows and size,
# and empties it (TRUNCATE, its monthly partitions dropped) so the next stage has the disk back. The database is
# dropped on every exit path the shell can catch.
#
# Needs: go, psql, df (GNU), bash 4+, and
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a PostgreSQL 13+ cluster as a superuser
#   PGVIGIL_STAGES     the stages to run, by table name, space-separated (default every stage, in this order):
#                      activity_summary dbstats serverstats iostats host_sample mssql_requests_summary
#                      mssql_cpu_sample mssql_sched_sample mssql_memory_sample
#   PGVIGIL_IO_ROWS    pg_stat_io rows per read of one instance (default 30, the PostgreSQL 16/17 shape; 1 to 80)
# Disk: a stage runs only when / has its own estimate plus 5 GB free (the estimates are printed first; dbstats is
# the largest); else it prints SKIP and the next stage runs. / stands in for the cluster's data directory, which may
# not be reachable from here: on a box where they differ, check the data directory's disk by hand first.
# Time: a stage's fill and VACUUM take minutes (dbstats and iostats the longest); its measures at most 15 s each.
#
# Output: ESTIMATE lines first; then per stage STAGE, FILL, VACUUM ANALYZE, MEASURE, TABLE and EMPTY lines, or SKIP or
# FAIL; a STAGES line last. A MEASURE line's 'cold' run is the first run of the statement in a new session after its
# stage's fill (nothing restarts the server or drops the OS cache, so part of the data may still be cached from the
# fill); 'warm' is the same statement again right after it. Both run under serve's own session settings
# (internal/web/web.go uiPoolConfig), statement_timeout 15 s among them.
#
# EXPECTED (written before the first run):
#  warm runs at fleet scope (40 instances of the family's engine), under serve's session settings:
#  - sessions, host, requests, cpu, scheduler, memory (a direct read, 1-minute rows): 7 days under 2 s; 31 days 3-8 s;
#    90 days 10-20 s - near or past 15 s.
#  - server (serverstats_rate, 1-minute): 7 days 1-4 s; 31 days 5-12 s; 90 days past 15 s.
#  - io (iostats_rate, 5-minute, about 30 rows a read): 7 days 2-6 s; 31 days 8-20 s; 90 days past 15 s.
#  - database, instance level (dbstats_rate over every database): 7 days 2-8 s; 31 and 90 days past 15 s.
#  - database, per database (the 150-name LATERAL, no datname index): past 15 s already at 7 days.

set -uo pipefail
: "${PGVIGIL_ADMIN_DSN:?}"
cd "$(dirname "$0")/.."

DAYS=91
PG_N=40; MS_N=40; BIG_DBS=150; SMALL_DBS=3
IO_ROWS=${PGVIGIL_IO_ROWS:-30}
ALL_STAGES="activity_summary dbstats serverstats iostats host_sample mssql_requests_summary mssql_cpu_sample mssql_sched_sample mssql_memory_sample"
STAGES=${PGVIGIL_STAGES:-$ALL_STAGES}
# the families each stage's table serves; database-perdb is the 'database' family read per database
declare -A FAMILIES=([activity_summary]=sessions [dbstats]="database database-perdb" [serverstats]=server [iostats]=io
  [host_sample]=host [mssql_requests_summary]=requests [mssql_cpu_sample]=cpu [mssql_sched_sample]=scheduler
  [mssql_memory_sample]=memory)
REPO=pgvigil_measure_$RANDOM
WORK=$(mktemp -d); CREATED=""

fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  if [[ -n "$CREATED" ]]; then
    psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO with (force)" >/dev/null 2>&1 \
      || echo "CLEANUP: $REPO not dropped" >&2
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
# a signal ends the script through exit, so the EXIT trap drops the database
trap 'exit 130' INT TERM HUP

for t in go psql df; do command -v $t >/dev/null || fail "$t is not on this machine"; done
[[ $IO_ROWS =~ ^[0-9]+$ ]] && (( IO_ROWS >= 1 && IO_ROWS <= 80 )) || fail "PGVIGIL_IO_ROWS must be 1 to 80"
for t in $STAGES; do [[ -n ${FAMILIES[$t]+x} ]] || fail "PGVIGIL_STAGES: no stage $t (the stages: $ALL_STAGES)"; done

# ---- the estimates -----------------------------------------------------------------------------------------------
M=$((DAYS * 1440)); M5=$((DAYS * 288))
DBS=$((BIG_DBS + (PG_N - 1) * SMALL_DBS))
declare -A NEED
# bytes a row: rough, the heap row and its (instance_id, snapshot_at) index entry from the column widths, not measured
estimate() {   # estimate <table> <rows> <bytes a row> <how>
  local gib=1073741824 b=$(( $2 * $3 ))
  NEED[$1]=$(( (b + gib - 1) / gib + 5 ))
  printf 'ESTIMATE %s: %d rows (%s), about %d.%d GB; the stage needs %d GB free\n' \
    "$1" "$2" "$4" $((b / gib)) $((b % gib * 10 / gib)) "${NEED[$1]}"
}
estimate activity_summary       $((PG_N * M))            120 "1 min x $PG_N instances"
estimate dbstats                $((DBS * M))             300 "1 min x $DBS databases"
estimate serverstats            $((PG_N * M))            230 "1 min x $PG_N instances"
estimate iostats                $((PG_N * IO_ROWS * M5)) 240 "5 min x $PG_N instances x $IO_ROWS pg_stat_io rows"
estimate host_sample            $((PG_N * M))            160 "1 min x $PG_N instances"
estimate mssql_requests_summary $((MS_N * M))            120 "1 min x $MS_N instances"
estimate mssql_cpu_sample       $((MS_N * M))             90 "1 min x $MS_N instances"
estimate mssql_sched_sample     $((MS_N * M))            150 "1 min x $MS_N instances"
estimate mssql_memory_sample    $((MS_N * M))            230 "1 min x $MS_N instances"
echo "stages to run: $STAGES"
free_gb() { df -BG --output=avail / | tail -1 | tr -dc '0-9'; }

# ---- the repository and the instances ----------------------------------------------------------------------------
BIN=$WORK/pgvigil
go build -o "$BIN" ./cmd/pgvigil || fail "go build"
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO" >/dev/null || fail "create database $REPO"
CREATED=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO"
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$WORK/cfg.yaml"
"$BIN" migrate -config "$WORK/cfg.yaml" > "$WORK/migrate.out" 2>&1 || { tail -5 "$WORK/migrate.out" >&2; fail "migrate"; }

q() { psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
[[ $(q "select to_regprocedure('pgvigil.metric_points(int, text, timestamptz, timestamptz, interval, text)') is not null") == t ]] \
  || fail "no pgvigil.metric_points(int, text, timestamptz, timestamptz, interval, text) in this tree"
echo "repository $REPO: $(q "select 'PostgreSQL ' || current_setting('server_version') || ', shared_buffers ' || current_setting('shared_buffers')
  || ', work_mem ' || current_setting('work_mem') || ', effective_cache_size ' || current_setting('effective_cache_size')
  || ', max_parallel_workers_per_gather ' || current_setting('max_parallel_workers_per_gather')")"

q "insert into pgvigil.instances (name, platform, engine)
   select format('measure-pg-%s', lpad(g::text, 2, '0')), 'onprem', 'postgres' from generate_series(1, $PG_N) g
   union all
   select format('measure-ms-%s', lpad(g::text, 2, '0')), 'sqlserver', 'sqlserver' from generate_series(1, $MS_N) g" >/dev/null \
  || fail "insert the instances"
PG_IDS=$(q "select array_agg(instance_id order by instance_id) from pgvigil.instances where engine = 'postgres'")
MS_IDS=$(q "select array_agg(instance_id order by instance_id) from pgvigil.instances where engine = 'sqlserver'")
BIG=$(q "select min(instance_id) from pgvigil.instances where engine = 'postgres'")

# The fill's own lookup tables, outside the pgvigil schema: per instance a scale s (so the instances differ), a phase
# (so their waves do not move together) and a few seconds of offset (collectors of one fleet do not read on the same
# second); per database its id, name and scale; the pg_stat_io keys of one read.
q "create table public.measure_inst as
   select instance_id, engine, 1 + (instance_id * 37) % 97 as s, ((instance_id % 13) * 0.5)::float8 as phase,
          make_interval(secs => (instance_id * 7) % 60) as off
     from pgvigil.instances" >/dev/null || fail "measure_inst"
q "create table public.measure_db as
   select i.instance_id, i.phase, i.off, 16383 + n as dbid, format('db%s', lpad(n::text, 3, '0')) as datname,
          1 + (i.instance_id * 37 + n * 11) % 97 as s
     from public.measure_inst i
    cross join lateral generate_series(1, case when i.instance_id = $BIG then $BIG_DBS else $SMALL_DBS end) as n
    where i.engine = 'postgres'" >/dev/null || fail "measure_db"
q "create table public.measure_io as
   select (array['client backend', 'autovacuum worker', 'background worker', 'background writer', 'checkpointer',
                 'standalone backend', 'startup', 'walsender', 'autovacuum launcher', 'walsummarizer'])[1 + (j - 1) % 10] as backend_type,
          case when j <= 40 then 'relation' else 'temp relation' end as object,
          (array['normal', 'bulkread', 'bulkwrite', 'vacuum'])[1 + ((j - 1) / 10) % 4] as context,
          1.0::float8 / j as f
     from generate_series(1, $IO_ROWS) j" >/dev/null || fail "measure_io"
DB_NAMES=$(q "select array_agg(datname order by datname) from public.measure_db where instance_id = $BIG")
echo "instances: $PG_N PostgreSQL $PG_IDS (instance $BIG has $BIG_DBS databases, the others $SMALL_DBS), $MS_N SQL Server $MS_IDS"

# ---- the fills, one function per stage -----------------------------------------------------------------------------
# START is set by each stage just before its fill, so every stage's 91 days end at its own fill and its 7-day window
# is full when it is measured.
START=0; END=0

months() {   # months <table>: its monthly partitions over the fill's days, made as an import makes them
  psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 >/dev/null <<SQL || { echo "FAIL $1: the month partitions"; return 1; }
DO \$\$
DECLARE
  d timestamptz;
BEGIN
  FOR d IN SELECT generate_series(to_timestamp($START) - interval '1 day', to_timestamp($END) + interval '1 day', interval '1 day') LOOP
    PERFORM pgvigil.ensure_month_partition('$1', d);
  END LOOP;
END \$\$;
SQL
}

# fill <table>, the INSERT on stdin. Every INSERT walks time in the outer loop and the instances inside it (the
# LATERAL subquery with OFFSET 0 holds that join order), so the rows land in the heap in the order the collectors
# write them: a minute of every instance, then the next minute. An instance-major fill would cluster each instance's
# rows and measure reads faster than a real repository gives them.
# In each: k the read's index (minutes, or 5-minute steps for iostats), at its time, w a slow wave and z a fast one
# (-1..1) for gauges, u a counter clock that only grows (each step adds 0.5 to 1.5 minutes' worth), s the scale.
fill() {
  local t=$1 sql t0 out
  sql=$(cat)
  t0=$(date +%s%N)
  out=$(psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$sql" 2>&1) || { echo "FAIL $t: the fill: $out"; return 1; }
  echo "FILL $t: ${out##* } rows in $(( ($(date +%s%N) - t0) / 1000000 )) ms"
}
minute_base() {   # minute_base <engine>: the FROM of a one-minute table, one row per read of every instance of the engine
  printf '%s' "generate_series(0, $M - 1) AS k
  CROSS JOIN LATERAL (
    SELECT i.instance_id, i.s, k, to_timestamp($START) + k * interval '1 minute' + i.off AS at,
           sin(k::float8 / 90 + i.phase) AS w, sin(k::float8 / 7 + 2 * i.phase) AS z,
           k + 20 * sin(k::float8 / 40 + i.phase) AS u
      FROM public.measure_inst i
     WHERE i.engine = '$1'
    OFFSET 0) r"
}

fill_activity_summary() {
  fill activity_summary <<SQL
INSERT INTO pgvigil.activity_summary (instance_id, snapshot_at, total, active, idle, idle_in_txn, idle_in_txn_aborted, waiting_lock,
    active_client_wait, longest_active_secs, longest_idle_txn_secs, oldest_xmin_age, max_connections)
SELECT r.instance_id, r.at, g.active + g.idle + g.iit, g.active, g.idle, g.iit, 0, g.wl, g.active / 4,
       (1 + 30 * (1 + r.z))::int, CASE WHEN g.iit > 0 THEN 5 + r.k % 300 ELSE 0 END, (1000 + 50000 * (1 + r.w))::int, 500
  FROM $(minute_base postgres)
  CROSS JOIN LATERAL (SELECT (3 + r.s / 10 + 6 * (1 + r.w))::int AS active, (40 + r.s + 20 * (1 + r.z))::int AS idle,
                             ((r.k + r.instance_id) % 5 = 0)::int + ((r.k / 30 + r.instance_id) % 7 = 0)::int AS iit,
                             ((r.k + r.instance_id) % 23 = 0)::int AS wl) g
SQL
}

fill_dbstats() {
  fill dbstats <<SQL
INSERT INTO pgvigil.dbstats (instance_id, snapshot_at, dbid, datname, stats_reset, numbackends, xact_commit, xact_rollback,
    blks_read, blks_hit, tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted, conflicts, temp_files, temp_bytes,
    deadlocks, checksum_failures, blk_read_time, blk_write_time, session_time, active_time, idle_in_transaction_time,
    sessions, sessions_abandoned, sessions_fatal, sessions_killed, epoch)
SELECT r.instance_id, r.at, r.dbid, r.datname, to_timestamp($START) - interval '30 days', (1 + r.s / 10 + 5 * (1 + r.w))::int,
       (r.u * r.s * 20)::bigint, (r.u * r.s * 0.2)::bigint, (r.u * r.s * 10)::bigint, (r.u * r.s * 1000)::bigint,
       (r.u * r.s * 3000)::bigint, (r.u * r.s * 800)::bigint, (r.u * r.s * 15)::bigint, (r.u * r.s * 10)::bigint,
       (r.u * r.s * 2)::bigint, 0, (r.u * r.s / 500)::bigint, (r.u * r.s * 4000)::bigint, (r.u * r.s / 20000)::bigint, 0,
       r.u * r.s * 0.4, r.u * r.s * 0.1, r.u * 60000 * (1 + r.s / 10), r.u * r.s * 300, r.u * r.s * 20,
       (r.u * r.s / 5)::bigint, 0, 0, 0, 0
  FROM generate_series(0, $M - 1) AS k
  CROSS JOIN LATERAL (
    SELECT d.instance_id, d.dbid, d.datname, d.s, to_timestamp($START) + k * interval '1 minute' + d.off AS at,
           sin(k::float8 / 90 + d.phase + d.s) AS w, k + 20 * sin(k::float8 / 40 + d.phase) AS u
      FROM public.measure_db d
    OFFSET 0) r
SQL
}

fill_serverstats() {
  fill serverstats <<SQL
INSERT INTO pgvigil.serverstats (instance_id, snapshot_at, bgwriter_stats_reset, checkpointer_stats_reset, checkpoints_timed,
    checkpoints_req, checkpoint_write_time, checkpoint_sync_time, buffers_checkpoint, buffers_clean, maxwritten_clean,
    buffers_backend, buffers_backend_fsync, buffers_alloc, wal_records, wal_fpi, wal_bytes, wal_buffers_full, wal_write,
    wal_sync, wal_write_time, wal_sync_time)
SELECT r.instance_id, r.at, to_timestamp($START) - interval '30 days', to_timestamp($START) - interval '30 days', r.k / 5,
       (r.u / 240)::bigint, r.u * 900, r.u * 30, (r.u * r.s * 30)::bigint, (r.u * r.s * 5)::bigint, (r.u / 1000)::bigint,
       (r.u * r.s * 2)::bigint, 0, (r.u * r.s * 25)::bigint, (r.u * r.s * 400)::bigint, (r.u * r.s * 20)::bigint,
       round((r.u * r.s * 60000)::numeric), 0, (r.u * r.s * 3)::bigint, (r.u * r.s * 3)::bigint, r.u * 5, r.u * 40
  FROM $(minute_base postgres)
SQL
}

# the PostgreSQL 16/17 shape: bytes as operations times op_bytes (iostats_rate's coalesce), the *_bytes columns NULL
fill_iostats() {
  fill iostats <<SQL
INSERT INTO pgvigil.iostats (instance_id, snapshot_at, backend_type, object, context, stats_reset, reads, read_time, writes,
    write_time, writebacks, writeback_time, extends, extend_time, op_bytes, hits, evictions, reuses, fsyncs, fsync_time)
SELECT r.instance_id, r.at, r.backend_type, r.object, r.context, to_timestamp($START) - interval '30 days',
       (r.u * r.s * r.f * 40)::bigint, r.u * r.s * r.f * 3, (r.u * r.s * r.f * 15)::bigint, r.u * r.s * r.f * 0.5,
       (r.u * r.s * r.f * 5)::bigint, r.u * r.s * r.f * 0.2, (r.u * r.s * r.f * 2)::bigint, r.u * r.s * r.f * 0.1, 8192,
       (r.u * r.s * r.f * 4000)::bigint, (r.u * r.s * r.f * 10)::bigint, (r.u * r.s * r.f * 3)::bigint,
       (r.u * r.f)::bigint, r.u * r.f * 2
  FROM generate_series(0, $M5 - 1) AS k
  CROSS JOIN LATERAL (
    SELECT i.instance_id, i.s, j.backend_type, j.object, j.context, j.f,
           to_timestamp($START) + k * interval '5 minutes' + i.off AS at,
           5 * k + 20 * sin(5 * k::float8 / 40 + i.phase) AS u
      FROM public.measure_inst i CROSS JOIN public.measure_io j
     WHERE i.engine = 'postgres'
    OFFSET 0) r
SQL
}

fill_host_sample() {
  fill host_sample <<SQL
INSERT INTO pgvigil.host_sample (instance_id, snapshot_at, source, cpu_pct, cpu_user_pct, cpu_system_pct, cpu_iowait_pct,
    mem_total, mem_used, mem_free, mem_cache, swap_total, swap_used, load1, load5, load15)
SELECT r.instance_id, r.at, 'system_stats', g.cpu, g.cpu * 0.7, g.cpu * 0.2, 1 + 2 * (1 + r.z),
       68719476736, (68719476736 * (0.55 + 0.15 * r.w))::bigint, (68719476736 * (0.10 + 0.04 * (1 + r.z)))::bigint,
       17179869184, 4294967296, (16777216 * (1 + r.w))::bigint, g.cpu / 12.5, g.cpu / 13, g.cpu / 14
  FROM $(minute_base postgres)
  CROSS JOIN LATERAL (SELECT 25 + 15 * r.w + 5 * r.z AS cpu) g
SQL
}

fill_mssql_requests_summary() {
  fill mssql_requests_summary <<SQL
INSERT INTO pgvigil.mssql_requests_summary (instance_id, snapshot_at, server_utc, source, sessions, requests, blocked, heads,
    longest_wait_ms, memory_grants_pending, read_ms)
SELECT r.instance_id, r.at, r.at, 'dmv', (60 + r.s + 25 * (1 + r.w))::int, (3 + 3 * (1 + r.z))::int, g.blocked,
       least(g.blocked, 1), CASE WHEN g.blocked > 0 THEN 1000 * (1 + r.k % 120) ELSE r.k % 900 END, 0, 15 + r.k % 40
  FROM $(minute_base sqlserver)
  CROSS JOIN LATERAL (SELECT CASE WHEN (r.k + r.instance_id) % 45 < 3 THEN 1 + r.k % 4 ELSE 0 END AS blocked) g
SQL
}

# one scheduler monitor record a minute, numbered as the server numbers them
fill_mssql_cpu_sample() {
  fill mssql_cpu_sample <<SQL
INSERT INTO pgvigil.mssql_cpu_sample (instance_id, snapshot_at, record_id, sql_pct, other_pct, idle_pct)
SELECT r.instance_id, r.at, 1000 + r.k, g.sql_pct, g.other_pct, 100 - g.sql_pct - g.other_pct
  FROM $(minute_base sqlserver)
  CROSS JOIN LATERAL (SELECT (35 + 25 * r.w + 8 * r.z)::int AS sql_pct, (3 + 2 * r.z)::int AS other_pct) g
SQL
}

fill_mssql_sched_sample() {
  fill mssql_sched_sample <<SQL
INSERT INTO pgvigil.mssql_sched_sample (instance_id, snapshot_at, schedulers, cpu_count, runnable_tasks, work_queue, pending_io,
    current_workers, active_workers, max_workers, batch_s, compiles_s, recompiles_s, transactions_s, interval_secs,
    offline_cpus, nodes_total, nodes_online)
SELECT r.instance_id, r.at, 16, 16, (2 * (1 + r.z))::int, ((r.k + r.instance_id) % 97 = 0)::int, (1 + r.w)::int,
       120 + r.s, (25 + 15 * (1 + r.w))::int, 704, g.batch, g.batch * 0.08, g.batch * 0.005, g.batch * 1.4, 60, 0, 1, 1
  FROM $(minute_base sqlserver)
  CROSS JOIN LATERAL (SELECT (400 + 10 * r.s) * (1 + 0.5 * r.w) AS batch) g
SQL
}

fill_mssql_memory_sample() {
  fill mssql_memory_sample <<SQL
INSERT INTO pgvigil.mssql_memory_sample (instance_id, snapshot_at, physical_kb, available_kb, system_state, process_kb, process_low,
    committed_kb, committed_target_kb, target_kb, total_kb, stolen_kb, buffer_pool_kb, plan_cache_kb, clerks_kb, ple,
    grants_pending, grants_outstanding, memory_model, xtp_kb, tokenperm_kb, max_workspace_kb, granted_workspace_kb)
SELECT r.instance_id, r.at, 134217728, (8388608 * (1.5 + r.w))::bigint, 'Available physical memory is high', g.total_kb + 524288,
       false, g.total_kb, 117440512, 117440512, g.total_kb, g.stolen_kb, g.total_kb - g.stolen_kb - g.plan_kb, g.plan_kb,
       g.total_kb - 1048576, (3000 + 2500 * r.w + 10 * r.s)::bigint, ((r.k + r.instance_id) % 120 = 0)::int,
       (2 * (1 + r.z))::int, 'CONVENTIONAL', 0, 102400, 88080384, (1048576 * (1 + r.z))::bigint
  FROM $(minute_base sqlserver)
  CROSS JOIN LATERAL (SELECT (117440512 * (0.96 + 0.03 * r.w))::bigint AS total_kb, (8388608 * (1 + 0.2 * r.z))::bigint AS stolen_kb,
                             (2097152 * (1 + 0.1 * r.w))::bigint AS plan_kb) g
SQL
}

# ---- the measures ------------------------------------------------------------------------------------------------
SERVE_SET="SET statement_timeout = '15s'; SET plan_cache_mode = force_custom_plan; SET jit = off; SET lock_timeout = '2s';
  SET search_path = pgvigil, pg_catalog; SET default_transaction_read_only = on"
# measure <label> <days> <statement>: the statement twice, each in a session of its own under serve's settings
measure() {
  local label=$1 days=$2 sql=$3 run out ms rows
  for run in cold warm; do
    out=$(psql "$PGVIGIL_REPO_DSN" -XAtq -c "$SERVE_SET" -c '\timing on' -c "$sql" 2>&1)
    if [[ $out == *"canceling statement due to statement timeout"* ]]; then
      echo "MEASURE $label ${days}d: TIMEOUT (15 s) [$run]"
    elif [[ $out == *ERROR:* ]]; then
      echo "MEASURE $label ${days}d: ERROR $(grep -m1 'ERROR:' <<<"$out") [$run]"
    else
      ms=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' <<<"$out" | tail -1)
      rows=$(grep -cv '^Time: ' <<<"$out")
      echo "MEASURE $label ${days}d: ${ms:-?} ms, $rows rows [$run]"
    fi
  done
}
# a bucket per range as a panel would draw it; to_timestamp(floor(...)) stands in for date_bin (PostgreSQL 14+ only)
RANGES=${PGVIGIL_RANGES:-"7:3600 31:21600 90:86400"}   # days:bucket seconds; a fraction of a day is taken (0.25 = 6 hours)
measure_family() {   # measure_family <family>: its three ranges at fleet scope; database-perdb is one instance's databases
  local fam=$1 engine metric ids r days secs
  if [[ $fam == database-perdb ]]; then
    metric=$(q "select metric from pgvigil.metric_catalog where family = 'database' and per_database order by sort limit 1")
    [[ -n $metric ]] || { echo "FAIL $fam: metric_catalog has no per-database metric of the database family"; return 1; }
    echo "family database-perdb: metric $metric, instance $BIG, its $BIG_DBS databases"
    for r in $RANGES; do
      days=${r%%:*}; secs=${r##*:}
      measure database-perdb "$days" "SELECT x.bucket, avg(x.v)
  FROM (SELECT d.datname, to_timestamp(floor(extract(epoch FROM p.at) / $secs) * $secs) AS bucket, p.metric, avg(p.value) AS v
          FROM unnest('$DB_NAMES'::text[]) AS d(datname)
          CROSS JOIN LATERAL pgvigil.metric_points($BIG, 'database', now() - interval '$days days', now(), interval '15 minutes', d.datname) p
         WHERE p.metric = '$metric'
         GROUP BY 1, 2, 3) x
 GROUP BY 1 ORDER BY 1"
    done
    return 0
  fi
  engine=$(q "select engine from pgvigil.metric_catalog where family = '$fam' limit 1")
  metric=$(q "select metric from pgvigil.metric_catalog where family = '$fam' order by sort limit 1")
  [[ -n $metric ]] || { echo "FAIL $fam: metric_catalog has no family $fam"; return 1; }
  # host is engine 'any' in the catalog, but only the PostgreSQL host collection (import_host) writes host_sample
  if [[ $engine == sqlserver ]]; then ids=$MS_IDS; else ids=$PG_IDS; fi
  echo "family $fam: metric $metric, instances $ids"
  for r in $RANGES; do
    days=${r%%:*}; secs=${r##*:}
    measure "$fam" "$days" "SELECT x.bucket, avg(x.v)
  FROM (SELECT i.instance_id, to_timestamp(floor(extract(epoch FROM p.at) / $secs) * $secs) AS bucket, p.metric, avg(p.value) AS v
          FROM unnest('$ids'::int[]) AS i(instance_id)
          CROSS JOIN LATERAL pgvigil.metric_points(i.instance_id, '$fam', now() - interval '$days days', now()) p
         WHERE p.metric = '$metric'
         GROUP BY 1, 2, 3) x
 GROUP BY 1 ORDER BY 1"
  done
}

# ---- the stages --------------------------------------------------------------------------------------------------
stage() {   # stage <table>: fill, VACUUM ANALYZE, measure, report; non-zero when a step failed (the caller empties it)
  local t=$1 fam t0
  START=$(q "select extract(epoch from date_trunc('minute', now()) - interval '$DAYS days')::bigint") || return 1
  END=$((START + DAYS * 86400))
  if [[ $(q "select relkind = 'p' from pg_class where oid = 'pgvigil.$t'::regclass") == t ]]; then
    months "$t" || return 1
  fi
  "fill_$t" || return 1
  echo "database after the fill: $(q "select pg_size_pretty(pg_database_size(current_database())) || ' (' || pg_database_size(current_database()) || ' bytes)'")"
  # VACUUM as well as ANALYZE: a repository's settled rows have their hint bits and visibility map set by autovacuum;
  # without it the first measure would set them itself and pay for writes no panel read pays, and autovacuum could
  # start on the new partitions in the middle of the measures.
  t0=$(date +%s%N)
  q "vacuum (analyze) pgvigil.$t" >/dev/null || { echo "FAIL $t: vacuum analyze"; return 1; }
  echo "VACUUM ANALYZE $t: $(( ($(date +%s%N) - t0) / 1000000 )) ms"
  for fam in ${FAMILIES[$t]}; do measure_family "$fam" || return 1; done
  echo "TABLE $t: $(q "select (select count(*) from pgvigil.$t) || ' rows, '
    || (select pg_size_pretty(sum(pg_total_relation_size(relid))) from pg_partition_tree('pgvigil.$t'))")"
}
empty() {   # empty <table>: TRUNCATE it and drop its monthly partitions, so the disk comes back before the next stage
  local t=$1 parts
  q "truncate pgvigil.$t" >/dev/null || echo "WARN $t: not truncated"
  parts=$(q "select string_agg(relid::regclass::text, ', ') from pg_partition_tree('pgvigil.$t') where parentrelid is not null")
  if [[ -n $parts ]]; then q "drop table $parts" >/dev/null || echo "WARN $t: its partitions not dropped"; fi
  echo "EMPTY $t: $(free_gb) GB free on / after it"
}

DONE=""; SKIPPED=""; FAILED=""
for t in $STAGES; do
  free=$(free_gb)
  [[ $free =~ ^[0-9]+$ ]] || free=0   # an unreadable df skips the stage rather than filling blind
  if (( free < NEED[$t] )); then
    echo "SKIP $t: $free GB free, the stage needs ${NEED[$t]} GB"
    SKIPPED+=" $t"; continue
  fi
  echo "STAGE $t: $free GB free, the stage needs ${NEED[$t]} GB"
  if stage "$t"; then DONE+=" $t"; else FAILED+=" $t"; fi
  empty "$t"
done
echo "STAGES: done${DONE:- none}; skipped${SKIPPED:- none}; failed${FAILED:- none}; $REPO is dropped on exit"
[[ -z $FAILED ]] || exit 1
