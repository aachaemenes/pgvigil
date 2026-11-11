#!/usr/bin/env bash
# Proof of task 132 (migration 0086, internal/collect/instance.go, internal/web/q_diff.go, q_tablesize.go,
# q_pgconfig.go, q_connections.go, q_jobs_history.go): the instance diff, connections over time, the per-job chart
# with its step cut, the fleet table sizes and the PostgreSQL settings' detail.
#
# Needs: psql, curl, python3, go at the repository root, and PGVIGIL_ADMIN_DSN, a superuser connection to the
# PostgreSQL sandbox in KEYWORD form WITHOUT a password (the password from ~/.pgpass: the DSN is on psql's command
# line). For part G a PostgreSQL 13: PGVIGIL_PG13_DSN (keyword form, no password in it) or docker (the proof then
# starts postgres:13 on a loopback port with a throwaway password and removes it); PGVIGIL_PROOF_SKIP_PG13=1 skips
# G and the last line says so.
#
# What it makes, and drops on every exit path (a flag per object; nothing it did not make is touched): its own
# repository database and two target databases (names with the slice's 'diffgrids' and a random suffix), a few
# psql sessions with its own application names, and for part F ONE server setting through ALTER SYSTEM:
# event_source (the Windows event log's source name, no effect on Linux), set and reloaded so that it waits for a
# restart, then undone in two steps: set to the running value and reloaded (PostgreSQL drops the pending mark only
# when a reload finds the file's value equal to the running one), then RESET and reloaded. The part is skipped, and
# said so, when a configuration file already sets event_source, it already reads pending restart, or
# PGVIGIL_PROOF_NO_ALTER_SYSTEM=1. No SQL Server is needed: the SQL Server side is seeded rows in the
# collector's shape (mssql_config, job_versions, mssql_job_runs).
#
# The routes GET /api/diff, /api/tablesize and /api/pgconfig are the lead's lines in web.go: where the tree lacks
# them the proof builds a scratch copy with exactly those three lines and says so. One binary, built into the
# proof's temporary folder, is used throughout.
#
# Expected (written before the first run):
#  S. The seeded rows (seed.sql below, the same text on PostgreSQL 13 in part G) print exactly EXPECT_SEED:
#     S1  conn_sources_series, 60 s buckets, top 2 of X (3+3, then 2), Z (5) and Y (1, 1): bucket 0 holds two reads
#         (X 6 over 2 reads, peak 3, average 3.00; the folded Y 1, 0.50), bucket 60 a read with no client (every
#         series 0), bucket 120 X 2, Z 5, other 1. S1g: per application sum(conns) / sum(reads) and max(peak) equal
#         conn_sources_window's avg_total and peak_total (X 2.0 / 3, Y 0.5 / 1, Z 1.3 / 5). S1u: by user u1 14, u2 1.
#     S2  table_size_fleet over reads at -72 h, -30 h, -10 h and -1 h. A 24-hour window: t1 9000 bytes against its
#         base 2000 (the read 30 h back, at most two days before the window), growth 7000 and 70 rows over 1.21 days
#         = 5793 bytes and 58 rows a day; t2 (first read inside the window) 20200 against 20000, in_window; t3 (one
#         read) no growth; heap only where pgvigil.tables holds the same read. By size t2, t1, t3; by growth t1, t2,
#         t3. A 5-day window: the base is the first read inside it (t1 from 1000: +8000 over 2.96 days = 2704 a
#         day). A 30-minute window with no read: no row. A 2-hour window: t1 from 5000, t2 from 20000, not in_window.
#     S3  SQL Server: two instances differ in 'max degree of parallelism' (8 / 4), one setting is only on b, a
#         setting no longer listed is absent; as of 3 hours ago the first instance's value was 2 (the previous
#         value, changed 2 hours ago), as of 1 hour ago nothing differs. Jobs: 'backup' differs in step 01's command
#         only (the schedule keys 'nightly #12' and 'nightly #40' compare as one: 5 fields differ unstripped, 1
#         stripped), 'only-a' is only on a, 'purge' (dropped on a) only on b; one instance against itself 3 hours
#         ago: backup's command changed, only-a the same, purge only then.
#     S4  schema, two instances: a column only on b under a table both have stays a row; a function differs in
#         definition and owner; a view in its ACL; a table only on a folds its column and index (children 2); a
#         database only one side has is one row with its object count. Two databases of one instance: 5 rows only
#         in a. One instance at two times: a table added (its later index folded: children 1) is only in b; a table
#         dropped (its column dropped earlier folded) only in a; added then dropped: no row; a view changed and
#         changed back: no row; a definition changed past the stored text: different; dropped and re-created with
#         another definition: different; with the same: no row; an ACL set: different; a change before the first or
#         after the second time: no row. With identical rows asked for: 7 'same' (5 untouched objects, the view and
#         the re-created table). An unknown database: no row.
#     S5  pg_config_settings: without the detail list two rows, detail_read false; with it the setting waiting for
#         a restart first (source 'default', not in the non-default list), then by name. S5c / S5d, the PostgreSQL
#         settings rolled back through their history (work_mem 4096 -> 6144 five hours ago and -> 8192 two hours ago,
#         fsync set three hours ago, max_wal_size taken out four hours ago): as of six hours ago work_mem was 4096
#         (the FIRST change after that time, not the last), fsync was not set (only b), max_wal_size was 2048 (only
#         a); as of 150 minutes ago work_mem was 6144, fsync the same on both sides, max_wal_size on neither.
#     S6  diff_sides: a SQL Server side has no settings history start; a PostgreSQL side counts its two databases.
#  A. Two instances as last read (the API, db_a = the first target database, db_b = the second): exactly three
#     differences. settings: maintenance_work_mem (ALTER DATABASE on b only: 'only b', or 'different' where the
#     sandbox's own configuration sets it); jobs: 'nightly' different, the one field 'schedule' 15 3 * * * against
#     30 3 * * * (the job ids 1 and 4 do not matter); schema: table public.t_only_a 'only a' with its columns, index
#     and constraints folded (children = the repository's count of its children, 4 or more). all=1 adds the
#     identical rows: the job 'weekly' (ids 7 and 9), the setting work_mem (6144 on both), and every object of b's
#     database. The engines differ (PostgreSQL against the seeded SQL Server): 400; at_a with two instances: 400;
#     one instance and nothing else: 400; an unknown instance: 404. The seeded SQL Server pair: 2 setting rows,
#     3 job rows, no schema part, coverage says schema is not compared.
#  B. One instance at two times (the API, db_a = the first target database): between AT_A and AT_B a table t_new was
#     created, work_mem set by ALTER DATABASE and the job's schedule changed; a table t_temp was created and dropped
#     between two reads inside the window; a table t_after was created after AT_B. Exactly three rows: settings
#     work_mem ('only b' 6144, or 'different' where the sandbox sets it), jobs 'nightly' schedule 0 3 * * * against
#     15 3 * * *, schema table public.t_new 'only b'. Without at_b (the newest read): two schema rows, t_after too.
#  C. Connections, live: three reads with 3 idle sessions of one application name, the third after they closed. At
#     1-second buckets (the function; the API's buckets are a minute or more) the application's connections per
#     read are the hand counts of pg_stat_activity taken right after each read (3, 3, 0). For every application of
#     the window sum(conns) / sum(reads) = the grid's avg_total and max(peak) = its peak_total. The API with
#     chart=application: step_secs 60, at most 8 named series, each named series' average and peak equal its grid
#     row, and the series' connections sum to conn_sources' own total; chart=nonsense: 400.
#  D. Fleet table sizes, live: a table read at 2,000 rows and again at 22,000 (VACUUM ANALYZE before each read, so
#     its maps exist): total_bytes = the hand pg_total_relation_size after read 2, growth_bytes = that less the hand
#     size after read 1, growth_rows 20000, in_window true from a window that starts before read 1 and false from
#     one that starts between the reads. The API lists the same tables in the same order as the function for
#     order=growth and order=size; meta counts the PostgreSQL and the SQL Server instances as a hand count does;
#     top=7 and order=x: 400.
#  E. The job chart (the API). SQL Server, seeded: three runs of two steps, each 0 s, step 2 failing in runs 1 and
#     3. counts: 3 runs, 2 failed, 1 succeeded; the series' runs sum to 3 and its failed to 2; the three buckets with
#     a run carry avg_s 0 (a point, not a hole) and every other bucket no duration; stats: the outcome row 2 / 1,
#     step 1 0 / 3, step 2 2 / 1. step=2: three runs, all of step 2, newest first failed, succeeded, failed; step=1:
#     three succeeded. PostgreSQL: four 0-second runs of 'nightly': the series' runs sum to 4 = counts; one stats
#     row. engine=pg with step: 400; step=0: 400; step without a job: 400.
#  F. pg_config, live: after an instance read every row of pg_config_settings (name, value, unit, default, source,
#     context, pending restart, category) equals a hand read of pg_settings from the same database (the names the
#     collector masks compared without their value). event_source set by ALTER SYSTEM and reloaded: its row reads
#     pending restart true, source 'default', value 'PostgreSQL', context postmaster, listed first, and is NOT in
#     the non-default list (no change-history row); after RESET and reload a hand read shows it no longer pending.
#     /api/pgconfig returns the same rows.
#     [run 2 graded: S and A-E green at the values above; F green up to the undo, whose last expectation was wrong
#      about PostgreSQL: after ALTER SYSTEM RESET and a reload the setting still read pending restart. The server
#      drops the mark only when a reload finds the file's value EQUAL to the running one, or at a restart; taking the
#      line out leaves it. Expected from run 3: the undo sets event_source to its running value and reloads (pending
#      false), then RESETs and reloads (still false, in no file). The Configuration page's sentence and docs/diff.md
#      now say how long the mark stays]
#  G. PostgreSQL 13: every migration through 0086 applies to a fresh database and seed.sql prints EXPECT_SEED there.
#  [run 1 graded: S green at the first run (68 lines); the setup then stopped at 'VACUUM cannot run inside a
#   transaction block': the setup's psql -c held several statements, which run as one transaction. The VACUUMs are
#   now their own calls; no expectation changed]
#
# Not proven here: the pages in a browser (the looks and proof-a11y are the slice's report); a real pg_cron, pgAgent
# or SQL Server (their collectors are proven by proof-jobs-history.sh and the SQL Server proofs: this proof seeds
# their stored shapes); a fleet large enough to time table_size_fleet.
set -euo pipefail
export PATH=$HOME/.local/share/mise/shims:$PATH
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?a superuser keyword DSN of the PostgreSQL sandbox}"
ADMIN_DSN=$PGVIGIL_ADMIN_DSN
SUF=$RANDOM$RANDOM
REPO_DB=pgvigil_diffgrids_$SUF; D1=pgvigil_diffgrids_a_$SUF; D2=pgvigil_diffgrids_b_$SUF; DB13=pgvigil_diffgrids13_$SUF
NA=proof-diffgrids-a-$SUF; NB=proof-diffgrids-b-$SUF
EVT=pgvigil_proof_$SUF
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; OUT=$WORK/out; LOG=$WORK/serve.log; SCRATCH=$WORK/scratch; mkdir -p "$SCRATCH"
fail() { echo "FAIL: $*" >&2; exit 1; }
MADE_DBS=(); MADE_EVT=; MADE_13=; CT13=; PW13=; SRVPID=; BG=
# undo_evt: take part F's one server setting back. Removing the line alone leaves the pending mark until a restart:
# the file is first set to the value the server runs with and reloaded (that drops the mark), then the line goes.
evt_pending() { psql "$ADMIN_DSN" -XAt -c "select pending_restart from pg_settings where name = 'event_source'" 2>/dev/null; }
undo_evt() {
  local running; running=$(psql "$ADMIN_DSN" -XAt -c "show event_source" 2>/dev/null)
  psql "$ADMIN_DSN" -XAtq -c "alter system set event_source = '${running:-PostgreSQL}'" -c "select pg_reload_conf()" >/dev/null 2>&1
  for _ in $(seq 1 50); do [ "$(evt_pending)" = f ] && break; sleep 0.1; done
  psql "$ADMIN_DSN" -XAtq -c "alter system reset event_source" -c "select pg_reload_conf()" >/dev/null 2>&1
  sleep 0.5
}
# with13 <command>: run it with the throwaway PostgreSQL 13 password in its environment (part G's own container)
with13() { if [ -n "$PW13" ]; then PGPASSWORD=$PW13 "$@"; else "$@"; fi; }
adm() { psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
cleanup() {
  local rc=$?
  set +e   # every step of the cleanup runs, whatever failed before it
  # shellcheck disable=SC2086
  [ -n "$BG" ] && kill $BG 2>/dev/null
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null
  if [ -n "$MADE_EVT" ]; then
    undo_evt
    [ "$(psql "$ADMIN_DSN" -XAt -c "select count(*) from pg_file_settings where name = 'event_source'" 2>/dev/null)" = 0 ] && [ "$(evt_pending)" = f ] \
      || echo "CLEANUP: event_source is not back (in a configuration file, or still pending restart): run ALTER SYSTEM SET event_source = '<its running value>'; SELECT pg_reload_conf(); ALTER SYSTEM RESET event_source; SELECT pg_reload_conf();" >&2
  fi
  for d in "${MADE_DBS[@]}"; do
    psql "$ADMIN_DSN" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $d not dropped" >&2
  done
  if [ -n "$CT13" ]; then
    docker rm -f "$CT13" >/dev/null 2>&1 || echo "CLEANUP: container $CT13 not removed" >&2
  elif [ -n "$MADE_13" ]; then
    psql "$PGVIGIL_PG13_DSN" -XAtq -c "drop database if exists $DB13 with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $DB13 on the PostgreSQL 13 not dropped" >&2
  fi
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
for t in psql curl python3 go; do command -v $t >/dev/null 2>&1 || fail "$t is not on this machine"; done
[ -f go.mod ] || fail "run from the repository (go.mod not found)"
[[ "$ADMIN_DSN" != *password=* ]] || fail "PGVIGIL_ADMIN_DSN carries a password: keep it in ~/.pgpass (the DSN is on a command line)"
[[ "${PGVIGIL_PG13_DSN:-}" != *password=* ]] || fail "PGVIGIL_PG13_DSN carries a password: keep it in ~/.pgpass"

# ---- the one binary: this tree where it is wired, else a scratch copy with the lead's three route lines
if grep -q '"GET /api/diff"' internal/web/web.go; then
  CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil || fail "the build"
  WIRED="wired in this tree"
else
  tar --exclude=./web/node_modules --exclude=./bin --exclude=./.git -cf - . | tar -C "$SCRATCH" -xf -
  python3 - "$SCRATCH" <<'PY' || fail "the wiring's anchor line is gone from web.go"
import sys, io
p = sys.argv[1] + "/internal/web/web.go"
s = io.open(p, encoding="utf-8").read()
old = '\tapi.HandleFunc("GET /api/connections", s.Connections)\n'
if s.count(old) != 1:
    sys.exit("web.go: anchor found %d times" % s.count(old))
new = old + '\tapi.HandleFunc("GET /api/diff", s.Diff)\n\tapi.HandleFunc("GET /api/tablesize", s.TableSize)\n\tapi.HandleFunc("GET /api/pgconfig", s.PGConfig)\n'
io.open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
  (cd "$SCRATCH" && CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil) || fail "the scratch build with the wiring"
  WIRED="wired in a scratch build (the join applies the same three lines)"
fi
BIN=$WORK/pgvigil
echo "binary: $WIRED"

for d in "$REPO_DB" "$D1" "$D2"; do adm -c "create database $d" || fail "create database $d"; MADE_DBS+=("$d"); done
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
export DG_A_DSN="$ADMIN_DSN dbname=$D1" DG_B_DSN="$ADMIN_DSN dbname=$D2"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
d1() { psql "$DG_A_DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
d2() { psql "$DG_B_DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $NA
    dsn: env:DG_A_DSN
  - name: $NB
    dsn: env:DG_B_DSN
EOF
"$BIN" migrate -config "$CFG" >"$OUT" 2>&1 || { tail -20 "$OUT"; fail "migrate"; }
[ "$(q "select count(*) from pgvigil.schema_version where version like '0086%'")" = 1 ] || fail "migration 0086 is not recorded"
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$2" >"$OUT" 2>&1 || { cat "$OUT"; fail "collect $1 on $2"; }; }
# the repository server's clock as an RFC 3339 time, and the same URL-encoded
stamp() { q "select to_char(clock_timestamp() at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')"; }
enc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }

# ---------------------------------------------------------------------------------------------------------------
# the seeded rows and what they print: the same text on the sandbox's PostgreSQL (S) and on PostgreSQL 13 (G)
cat > "$WORK/seed.sql" <<'SQL'
\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\pset format unaligned
select now() as t0, date_trunc('minute', now()) - interval '10 minutes' as m0, date_trunc('hour', now()) as h0 \gset
select pgvigil.ensure_instance('seed-conn-' || :'suf', 'onprem', '16.0', 160000, false, '{}') as sc \gset
select pgvigil.ensure_instance('seed-tab-' || :'suf', 'onprem', '16.0', 160000, false, '{}') as st \gset
select pgvigil.ensure_instance('seed-ms1-' || :'suf', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver') as s1 \gset
select pgvigil.ensure_instance('seed-ms2-' || :'suf', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver') as s2 \gset
select pgvigil.ensure_instance('seed-pg1-' || :'suf', 'onprem', '16.0', 160000, false, '{}') as p1 \gset
select pgvigil.ensure_instance('seed-pg2-' || :'suf', 'onprem', '16.0', 160000, false, '{}') as p2 \gset
select pgvigil.ensure_instance('seed-cfg-' || :'suf', 'onprem', '16.0', 160000, false, '{}') as sf \gset
\o /dev/null
select pgvigil.ensure_month_partition('conn_sources', :'m0'::timestamptz), pgvigil.ensure_month_partition('conn_sources', :'m0'::timestamptz + interval '3 minutes');
select pgvigil.ensure_month_partition('table_sizes', :'h0'::timestamptz - x * interval '1 hour') from (values (72), (30), (10), (1)) v(x);
select pgvigil.ensure_month_partition('schema_changes', :'t0'::timestamptz - x * interval '1 hour') from (values (8), (5), (4), (3), (2), (1)) v(x);
select pgvigil.ensure_month_partition('mssql_job_runs', :'t0'::timestamptz - x * interval '1 hour') from (values (5), (3), (1)) v(x);
\o

-- S1: connection sources
insert into pgvigil.conn_sources (instance_id, snapshot_at, application_name, usename, datname, client, total, active, idle, idle_in_txn, waiting_lock, other) values
  (:sc, :'m0'::timestamptz + interval '10 seconds', 'X', 'u1', 'd', 'c', 2, 0, 2, 0, 0, 0),
  (:sc, :'m0'::timestamptz + interval '10 seconds', 'X', 'u2', 'd', 'c', 1, 0, 1, 0, 0, 0),
  (:sc, :'m0'::timestamptz + interval '10 seconds', 'Y', 'u1', 'd', 'c', 1, 0, 1, 0, 0, 0),
  (:sc, :'m0'::timestamptz + interval '40 seconds', 'X', 'u1', 'd', 'c', 3, 0, 3, 0, 0, 0),
  (:sc, :'m0'::timestamptz + interval '70 seconds', '', '', '', '', 0, 0, 0, 0, 0, 0),
  (:sc, :'m0'::timestamptz + interval '130 seconds', 'X', 'u1', 'd', 'c', 2, 0, 2, 0, 0, 0),
  (:sc, :'m0'::timestamptz + interval '130 seconds', 'Y', 'u1', 'd', 'c', 1, 0, 1, 0, 0, 0),
  (:sc, :'m0'::timestamptz + interval '130 seconds', 'Z', 'u1', 'd', 'c', 5, 0, 5, 0, 0, 0);
select 'S1|' || extract(epoch from bucket - :'m0'::timestamptz)::int || '|' || coalesce(source, '(other)') || '|' || folded || '|' || conns || '|' || reads || '|' || peak || '|' || avg_conns || '|' || sources || '|' || rank
  from pgvigil.conn_sources_series(:sc, :'m0'::timestamptz - interval '1 minute', :'m0'::timestamptz + interval '5 minutes', 'application', 60, 2)
 order by bucket, rank;
select 'S1g|' || w.application_name || '|' || w.avg_total || '|' || w.peak_total || '|' || (w.avg_total = s.avg1 and w.peak_total = s.peak)
  from pgvigil.conn_sources_window(:sc, :'m0'::timestamptz - interval '1 minute', :'m0'::timestamptz + interval '5 minutes', '{application}') w
  join (select source, round(sum(conns)::numeric / sum(reads), 1) as avg1, max(peak) as peak
          from pgvigil.conn_sources_series(:sc, :'m0'::timestamptz - interval '1 minute', :'m0'::timestamptz + interval '5 minutes', 'application', 60, 1000)
         group by source) s on s.source = w.application_name
 order by 1;
select 'S1u|' || source || '|' || sum(conns)
  from pgvigil.conn_sources_series(:sc, :'m0'::timestamptz - interval '1 minute', :'m0'::timestamptz + interval '5 minutes', 'user', 60, 1000)
 group by source order by 1;

-- S2: table sizes
insert into pgvigil.tables (instance_id, dbid, relid, datname, schema_name, table_name, snapshot_at, total_bytes, heap_bytes, toast_bytes, index_bytes, n_live_tup, first_seen) values
  (:st, 5, 101, 'db', 'public', 't1', :'h0'::timestamptz - interval '1 hour', 9000, 6000, 1000, 2000, 90, :'h0'::timestamptz - interval '72 hours'),
  (:st, 5, 102, 'db', 'public', 't2', :'h0'::timestamptz - interval '1 hour', 20200, 200, 0, 20000, 3, :'h0'::timestamptz - interval '10 hours'),
  (:st, 5, 103, 'db', 'public', 't3', :'h0'::timestamptz, 50, 40, 0, 10, 5, :'h0'::timestamptz - interval '1 hour');
insert into pgvigil.table_sizes (instance_id, snapshot_at, dbid, relid, total_bytes, n_live_tup) values
  (:st, :'h0'::timestamptz - interval '72 hours', 5, 101, 1000, 10),
  (:st, :'h0'::timestamptz - interval '30 hours', 5, 101, 2000, 20),
  (:st, :'h0'::timestamptz - interval '10 hours', 5, 101, 5000, 50),
  (:st, :'h0'::timestamptz - interval '10 hours', 5, 102, 20000, 1),
  (:st, :'h0'::timestamptz - interval '1 hour', 5, 101, 9000, 90),
  (:st, :'h0'::timestamptz - interval '1 hour', 5, 102, 20200, 3),
  (:st, :'h0'::timestamptz - interval '1 hour', 5, 103, 50, 5);
select 'S2a|' || table_name || '|' || total_bytes || '|' || coalesce(heap_bytes::text, '-') || '|' || coalesce(base_bytes::text, '-') || '|' || coalesce(growth_bytes::text, '-')
       || '|' || coalesce(growth_rows::text, '-') || '|' || coalesce(in_window::text, '-') || '|' || coalesce(days::text, '-') || '|' || coalesce(bytes_per_day::text, '-') || '|' || coalesce(rows_per_day::text, '-')
  from pgvigil.table_size_fleet(:'h0'::timestamptz - interval '24 hours', :'h0'::timestamptz, 1000000, 'size') where instance_id = :st order by table_name;
select 'S2s|' || string_agg(table_name, ',' order by ordinality) from pgvigil.table_size_fleet(:'h0'::timestamptz - interval '24 hours', :'h0'::timestamptz, 1000000, 'size') with ordinality where instance_id = :st;
select 'S2g|' || string_agg(table_name, ',' order by ordinality) from pgvigil.table_size_fleet(:'h0'::timestamptz - interval '24 hours', :'h0'::timestamptz, 1000000, 'growth') with ordinality where instance_id = :st;
select 'S2b|' || table_name || '|' || coalesce(base_bytes::text, '-') || '|' || coalesce(growth_bytes::text, '-') || '|' || coalesce(in_window::text, '-') || '|' || coalesce(days::text, '-') || '|' || coalesce(bytes_per_day::text, '-')
  from pgvigil.table_size_fleet(:'h0'::timestamptz - interval '5 days', :'h0'::timestamptz, 1000000, 'size') where instance_id = :st order by table_name;
select 'S2c|' || count(*) from pgvigil.table_size_fleet(:'h0'::timestamptz - interval '30 minutes', :'h0'::timestamptz, 1000000, 'size') where instance_id = :st;
select 'S2d|' || table_name || '|' || coalesce(base_bytes::text, '-') || '|' || coalesce(growth_bytes::text, '-') || '|' || coalesce(in_window::text, '-')
  from pgvigil.table_size_fleet(:'h0'::timestamptz - interval '2 hours', :'h0'::timestamptz, 1000000, 'size') where instance_id = :st order by table_name;

-- S3: SQL Server settings and jobs
insert into pgvigil.mssql_config (instance_id, name, value, value_in_use, snapshot_at, previous_in_use, changed_at, is_present) values
  (:s1, 'max degree of parallelism', 8, 8, :'t0', 2, :'t0'::timestamptz - interval '2 hours', true),
  (:s1, 'cost threshold for parallelism', 50, 50, :'t0', NULL, NULL, true),
  (:s1, 'gone option', 1, 1, :'t0'::timestamptz - interval '1 day', NULL, NULL, false),
  (:s2, 'max degree of parallelism', 4, 4, :'t0', NULL, NULL, true),
  (:s2, 'cost threshold for parallelism', 50, 50, :'t0', NULL, NULL, true),
  (:s2, 'optimize for ad hoc workloads', 1, 1, :'t0', NULL, NULL, true);
select 'S3a|' || name || '|' || coalesce(a_value, '-') || '|' || coalesce(b_value, '-') || '|' || status from pgvigil.diff_settings(:s1, NULL, :s2, NULL);
select 'S3b|' || name || '|' || coalesce(a_value, '-') || '|' || coalesce(b_value, '-') || '|' || status from pgvigil.diff_settings(:s1, :'t0'::timestamptz - interval '3 hours', :s1, NULL);
select 'S3c|' || count(*) filter (where status <> 'same') || '|' || count(*) from pgvigil.diff_settings(:s1, :'t0'::timestamptz - interval '1 hour', :s1, NULL);
insert into pgvigil.job_versions (instance_id, scheduler, job_id, valid_from, version_no, job_name, def_hash, definition, dropped, changes) values
  (:s1, 'sqlagent', 'AAA', :'t0'::timestamptz - interval '5 hours', 1, 'backup', 'h1',
   '{"name": "backup", "enabled": true, "schedules": {"nightly #12": {"enabled": true, "runs": "every day at 01:00"}}, "steps": {"step 01": {"name": "full", "command": "BACKUP DATABASE a"}}}', false, NULL),
  (:s1, 'sqlagent', 'AAA', :'t0'::timestamptz - interval '2 hours', 2, 'backup', 'h2',
   '{"name": "backup", "enabled": true, "schedules": {"nightly #12": {"enabled": true, "runs": "every day at 01:00"}}, "steps": {"step 01": {"name": "full", "command": "BACKUP DATABASE a WITH COMPRESSION"}}}', false, '[]'),
  (:s1, 'sqlagent', 'CCC', :'t0'::timestamptz - interval '5 hours', 1, 'purge', 'h3', '{"name": "purge", "enabled": true}', false, NULL),
  (:s1, 'sqlagent', 'CCC', :'t0'::timestamptz - interval '1 hour', 2, 'purge', 'h3', '{"name": "purge", "enabled": true}', true, '[]'),
  (:s1, 'sqlagent', 'DDD', :'t0'::timestamptz - interval '5 hours', 1, 'only-a', 'h4', '{"name": "only-a", "enabled": true}', false, NULL),
  (:s2, 'sqlagent', 'BBB', :'t0'::timestamptz - interval '4 hours', 1, 'backup', 'h5',
   '{"name": "backup", "enabled": true, "schedules": {"nightly #40": {"enabled": true, "runs": "every day at 01:00"}}, "steps": {"step 01": {"name": "full", "command": "BACKUP DATABASE a"}}}', false, NULL),
  (:s2, 'sqlagent', 'EEE', :'t0'::timestamptz - interval '4 hours', 1, 'purge', 'h6', '{"name": "purge", "enabled": true}', false, NULL);
select 'S3j|' || job_name || '|' || status || '|' || coalesce((select string_agg((f->>'field') || '=' || coalesce(f->>'a', '-') || '>' || coalesce(f->>'b', '-'), ';') from jsonb_array_elements(fields) f), '-')
  from pgvigil.diff_jobs(:s1, NULL, :s2, NULL);
select 'S3k|' || job_name || '|' || status || '|' || coalesce((select string_agg((f->>'field') || '=' || coalesce(f->>'a', '-') || '>' || coalesce(f->>'b', '-'), ';') from jsonb_array_elements(fields) f), '-')
  from pgvigil.diff_jobs(:s1, :'t0'::timestamptz - interval '3 hours', :s1, NULL);
select 'S3s|' || jsonb_array_length(pgvigil.diff_job_fields(a.definition, b.definition, false)) || '|' || jsonb_array_length(pgvigil.diff_job_fields(a.definition, b.definition, true))
  from pgvigil.diff_jobs_at(:s1, NULL) a, pgvigil.diff_jobs_at(:s2, NULL) b where a.job_name = 'backup' and b.job_name = 'backup';
-- the job chart's rows (part E reads them through the API): three runs, two steps each, every one 0 s
insert into pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, step_name, run_status, duration_s, retries, message,
                                    failed_step_id, failed_step_name, failed_message, step_retries)
select :s1, :'t0'::timestamptz - (7 - 2 * k) * interval '1 hour', 10 * k + s.step_no, 'JOB1', 'chart job', s.step_id, s.step_name,
       case when s.step_id = 1 or k = 2 then 1 else 0 end, 0, 0, 'run ' || k || ' ' || s.step_name,
       case when s.step_id = 0 and k <> 2 then 2 end, case when s.step_id = 0 and k <> 2 then 'two' end,
       case when s.step_id = 0 and k <> 2 then 'run ' || k || ' two' end, case when s.step_id = 0 then 0 end
  from generate_series(1, 3) k, (values (1, 1, 'one'), (2, 2, 'two'), (3, 0, '(Job outcome)')) s(step_no, step_id, step_name);

-- S4: schema objects and their changes
insert into pgvigil.schema_databases (instance_id, dbid, datname, snapshot_at, first_read, objects, is_present) values
  (:p1, 1, 'app', :'t0', :'t0'::timestamptz - interval '10 days', 6, true), (:p1, 2, 'onlya', :'t0', :'t0'::timestamptz - interval '10 days', 3, true),
  (:p2, 7, 'app', :'t0', :'t0'::timestamptz - interval '10 days', 5, true), (:p2, 8, 'onlyb', :'t0', :'t0'::timestamptz - interval '10 days', 4, true);
insert into pgvigil.schema_objects (instance_id, dbid, kind, identity, datname, schema_name, object_name, parent, definition, owner, acl, hash, def_hash, first_seen, snapshot_at, is_present) values
  (:p1, 1, 'schema', 'public', 'app', 'public', 'public', NULL, 'schema', 'o', NULL, 'h-s', 'd-s', :'t0'::timestamptz - interval '10 days', :'t0', true),
  (:p1, 1, 'table', 'public.t1', 'app', 'public', 't1', NULL, 'table', 'o', NULL, 'h-t1', 'd-t1', :'t0'::timestamptz - interval '10 days', :'t0', true),
  (:p1, 1, 'table', 'public.t_a', 'app', 'public', 't_a', NULL, 'table', 'o', NULL, 'h-ta', 'd-ta', :'t0'::timestamptz - interval '10 days', :'t0', true),
  (:p1, 1, 'column', 'public.t_a.id', 'app', 'public', 'id', 'public.t_a', 'integer', 'o', NULL, 'h-tac', 'd-tac', :'t0'::timestamptz - interval '10 days', :'t0', true),
  (:p1, 1, 'index', 'public.t_a_pkey', 'app', 'public', 't_a_pkey', 'public.t_a', 'index', 'o', NULL, 'h-tai', 'd-tai', :'t0'::timestamptz - interval '10 days', :'t0', true),
  (:p1, 1, 'function', 'public.f(integer)', 'app', 'public', 'f', NULL, 'f v1', 'alice', NULL, 'h-f1', 'd-f1', :'t0'::timestamptz - interval '10 days', :'t0', true),
  (:p1, 1, 'view', 'public.v', 'app', 'public', 'v', NULL, 'select 1', 'o', NULL, 'h-v1', 'd-v', :'t0'::timestamptz - interval '10 days', :'t0', true),
  (:p1, 1, 'table', 'public.gone', 'app', 'public', 'gone', NULL, 'table', 'o', NULL, 'h-g', 'd-g', :'t0'::timestamptz - interval '10 days', :'t0'::timestamptz - interval '7 hours', false),
  (:p2, 7, 'schema', 'public', 'app', 'public', 'public', NULL, 'schema', 'o', NULL, 'h-s', 'd-s', :'t0'::timestamptz - interval '10 days', :'t0', true),
  (:p2, 7, 'table', 'public.t1', 'app', 'public', 't1', NULL, 'table', 'o', NULL, 'h-t1', 'd-t1', :'t0'::timestamptz - interval '10 days', :'t0', true),
  (:p2, 7, 'column', 'public.t1.extra', 'app', 'public', 'extra', 'public.t1', 'text', 'o', NULL, 'h-t1x', 'd-t1x', :'t0'::timestamptz - interval '10 days', :'t0', true),
  (:p2, 7, 'function', 'public.f(integer)', 'app', 'public', 'f', NULL, 'f v2', 'bob', NULL, 'h-f2', 'd-f2', :'t0'::timestamptz - interval '10 days', :'t0', true),
  (:p2, 7, 'view', 'public.v', 'app', 'public', 'v', NULL, 'select 1', 'o', '{x=r/o}', 'h-v2', 'd-v', :'t0'::timestamptz - interval '10 days', :'t0', true);
select 'S4a|' || coalesce(datname_a, '-') || '|' || coalesce(datname_b, '-') || '|' || kind || '|' || identity || '|' || status || '|' || coalesce(differs, '-') || '|' || coalesce(children::text, '-')
  from pgvigil.diff_schema(:p1, :p2) order by coalesce(datname_a, datname_b), kind, identity;
select 'S4b|' || count(*) || '|' || coalesce(string_agg(distinct status, ','), '-') || '|' || coalesce(max(children), -1) from pgvigil.diff_schema(:p1, :p1, 'app', 'onlya');
insert into pgvigil.schema_changes (instance_id, snapshot_at, dbid, datname, kind, identity, schema_name, object_name, parent, change, attribute, before, after)
select :p1, :'t0'::timestamptz - c.h * interval '1 hour', 1, 'app', c.kind, c.identity, 'public', c.identity, c.parent, c.change, c.attribute, c.before, c.after
  from (values
    (5, 'table', 'public.n1', NULL, 'added', NULL, NULL, 'def n1'),
    (4, 'index', 'public.n1_idx', 'public.n1', 'added', NULL, NULL, 'index n1'),
    (5, 'table', 'public.tmp', NULL, 'added', NULL, NULL, 'def tmp'),
    (3, 'table', 'public.tmp', NULL, 'dropped', NULL, 'def tmp', NULL),
    (5, 'view', 'public.v', NULL, 'changed', 'definition', 'select 1', 'select 2'),
    (3, 'view', 'public.v', NULL, 'changed', 'definition', 'select 2', 'select 1'),
    (4, 'function', 'public.f(integer)', NULL, 'changed', 'definition', 'f v0', 'f v1'),
    (2, 'function', 'public.f(integer)', NULL, 'changed', 'owner', 'carol', 'alice'),
    (4, 'table', 'public.big', NULL, 'changed', 'definition', 'cut', 'cut'),
    (2, 'table', 'public.old', NULL, 'dropped', NULL, 'def old', NULL),
    (4, 'column', 'public.old.c', 'public.old', 'dropped', NULL, 'integer', NULL),
    (5, 'table', 'public.re', NULL, 'dropped', NULL, 'def re', NULL),
    (3, 'table', 'public.re', NULL, 'added', NULL, NULL, 'def re'),
    (5, 'table', 'public.re2', NULL, 'dropped', NULL, 'def A', NULL),
    (3, 'table', 'public.re2', NULL, 'added', NULL, NULL, 'def B'),
    (1, 'table', 'public.late', NULL, 'added', NULL, NULL, 'def late'),
    (8, 'table', 'public.early', NULL, 'added', NULL, NULL, 'def early'),
    (3, 'sequence', 'public.s', NULL, 'changed', 'acl', NULL, '{r=U/o}')
  ) c(h, kind, identity, parent, change, attribute, before, after);
select 'S4c|' || kind || '|' || identity || '|' || status || '|' || coalesce(differs, '-') || '|' || coalesce(children::text, '-') || '|' || coalesce(a_definition, '-') || '|' || coalesce(b_definition, '-')
       || '|' || coalesce(a_owner, '-') || '>' || coalesce(b_owner, '-')
  from pgvigil.diff_schema_snapshots(:p1, :'t0'::timestamptz - interval '6 hours', :'t0'::timestamptz - interval '90 minutes') order by kind, identity;
select 'S4d|' || status || '|' || count(*) from pgvigil.diff_schema_snapshots(:p1, :'t0'::timestamptz - interval '6 hours', :'t0'::timestamptz - interval '90 minutes', 'app', true) group by status order by status;
select 'S4e|' || count(*) from pgvigil.diff_schema_snapshots(:p1, :'t0'::timestamptz - interval '6 hours', :'t0'::timestamptz - interval '90 minutes', 'nope', true);

-- S5: the settings' detail
insert into pgvigil.instance_state (instance_id, snapshot_at, non_default_settings)
values (:sf, :'t0', '[{"name": "work_mem", "value": "8192"}, {"name": "fsync", "value": "off"}]');
select 'S5a|' || name || '|' || value || '|' || coalesce(unit, '-') || '|' || detail_read || '|' || non_default from pgvigil.pg_config_settings(:sf);
update pgvigil.instance_state set settings_detail = '[
  {"name": "work_mem", "value": "8192", "unit": "kB", "boot_val": "4096", "source": "configuration file", "context": "user", "pending_restart": false, "category": "Resource Usage / Memory"},
  {"name": "fsync", "value": "off", "unit": null, "boot_val": "on", "source": "configuration file", "context": "sighup", "pending_restart": false, "category": "Write-Ahead Log / Settings"},
  {"name": "max_connections", "value": "100", "unit": null, "boot_val": "100", "source": "default", "context": "postmaster", "pending_restart": true, "category": "Connections and Authentication / Connection Settings"}]'
 where instance_id = :sf;
select 'S5b|' || name || '|' || value || '|' || coalesce(unit, '-') || '|' || default_value || '|' || source || '|' || context || '|' || restart_needed || '|' || pending_restart || '|' || non_default || '|' || category
  from pgvigil.pg_config_settings(:sf);

-- S5c, S5d: the settings of that instance as they were (its current list: work_mem 8192, fsync off)
insert into pgvigil.instance_setting_history (instance_id, changed_at, name, old_value, new_value) values
  (:sf, :'t0'::timestamptz - interval '5 hours', 'work_mem', '4096', '6144'),
  (:sf, :'t0'::timestamptz - interval '2 hours', 'work_mem', '6144', '8192'),
  (:sf, :'t0'::timestamptz - interval '3 hours', 'fsync', NULL, 'off'),
  (:sf, :'t0'::timestamptz - interval '4 hours', 'max_wal_size', '2048', NULL);
select 'S5c|' || name || '|' || coalesce(a_value, '-') || '|' || coalesce(b_value, '-') || '|' || status from pgvigil.diff_settings(:sf, :'t0'::timestamptz - interval '6 hours', :sf, NULL);
select 'S5d|' || name || '|' || coalesce(a_value, '-') || '|' || coalesce(b_value, '-') || '|' || status from pgvigil.diff_settings(:sf, :'t0'::timestamptz - interval '150 minutes', :sf, NULL);

-- S6: the two sides
select 'S6|' || side || '|' || engine || '|' || (at is null) || '|' || (settings_read is not null) || '|' || (settings_from is null) || '|' || (jobs_from is not null) || '|' || (schema_read is null)
  from pgvigil.diff_sides(:s1, :'t0'::timestamptz - interval '3 hours', :s2, NULL);
select 'S6p|' || side || '|' || engine || '|' || schema_databases || '|' || (schema_from is not null) || '|' || (schema_changes_from is not null) || '|' || (settings_from is not null)
  from pgvigil.diff_sides(:p1, NULL, :p2, NULL);
SQL
cat > "$WORK/seed.expect" <<'EOF'
S1|0|X|false|6|2|3|3.00|1|1
S1|0|Z|false|0|2|0|0.00|1|2
S1|0|(other)|true|1|2|1|0.50|1|3
S1|60|X|false|0|1|0|0.00|1|1
S1|60|Z|false|0|1|0|0.00|1|2
S1|60|(other)|true|0|1|0|0.00|1|3
S1|120|X|false|2|1|2|2.00|1|1
S1|120|Z|false|5|1|5|5.00|1|2
S1|120|(other)|true|1|1|1|1.00|1|3
S1g|X|2.0|3|true
S1g|Y|0.5|1|true
S1g|Z|1.3|5|true
S1u|u1|14
S1u|u2|1
S2a|t1|9000|6000|2000|7000|70|false|1.21|5793|58
S2a|t2|20200|200|20000|200|2|true|0.38|533|5
S2a|t3|50|-|-|-|-|-|-|-|-
S2s|t2,t1,t3
S2g|t1,t2,t3
S2b|t1|1000|8000|true|2.96|2704
S2b|t2|20000|200|true|0.38|533
S2b|t3|-|-|-|-|-
S2c|0
S2d|t1|5000|4000|false
S2d|t2|20000|200|false
S2d|t3|-|-|-
S3a|cost threshold for parallelism|50|50|same
S3a|max degree of parallelism|8|4|different
S3a|optimize for ad hoc workloads|-|1|only b
S3b|cost threshold for parallelism|50|50|same
S3b|max degree of parallelism|2|8|different
S3c|0|2
S3j|backup|different|steps / step 01 / command=BACKUP DATABASE a WITH COMPRESSION>BACKUP DATABASE a
S3j|only-a|only a|-
S3j|purge|only b|-
S3k|backup|different|steps / step 01 / command=BACKUP DATABASE a>BACKUP DATABASE a WITH COMPRESSION
S3k|only-a|same|-
S3k|purge|only a|-
S3s|5|1
S4a|app|app|column|public.t1.extra|only b|-|-
S4a|app|app|function|public.f(integer)|different|definition, owner|-
S4a|app|app|schema|public|same|-|-
S4a|app|app|table|public.t1|same|-|-
S4a|app|app|table|public.t_a|only a|-|2
S4a|app|app|view|public.v|different|acl|-
S4a|onlya|-|database|onlya|only a|-|3
S4a|-|onlyb|database|onlyb|only b|-|4
S4b|5|only a|2
S4c|function|public.f(integer)|different|definition, owner|-|f v0|f v1|carol>alice
S4c|sequence|public.s|different|acl|-|-|-|->-
S4c|table|public.big|different|definition|-|cut|cut|->-
S4c|table|public.n1|only b|-|1|-|def n1|->-
S4c|table|public.old|only a|-|1|def old|-|->-
S4c|table|public.re2|different|definition|-|def A|def B|->-
S4d|different|4
S4d|only a|1
S4d|only b|1
S4d|same|7
S4e|0
S5a|fsync|off|-|false|true
S5a|work_mem|8192|-|false|true
S5b|max_connections|100|-|100|default|postmaster|true|true|false|Connections and Authentication / Connection Settings
S5b|fsync|off|-|on|configuration file|sighup|false|false|true|Write-Ahead Log / Settings
S5b|work_mem|8192|kB|4096|configuration file|user|false|false|true|Resource Usage / Memory
S5c|fsync|-|off|only b
S5c|max_wal_size|2048|-|only a
S5c|work_mem|4096|8192|different
S5d|fsync|off|off|same
S5d|work_mem|6144|8192|different
S6|a|sqlserver|false|true|true|true|true
S6|b|sqlserver|true|true|true|true|true
S6p|a|postgres|2|true|true|true
S6p|b|postgres|2|true|false|true
EOF
# seed <psql connection>: run seed.sql there and grade its output against the expected text
seed() {
  psql "$1" -X -v suf="$SUF" -f "$WORK/seed.sql" > "$WORK/seed.out" 2> "$WORK/seed.err" || { cat "$WORK/seed.err"; fail "$2: seed.sql"; }
  diff -u "$WORK/seed.expect" "$WORK/seed.out" || fail "$2: the seeded rows differ from the expected text (above: - expected, + got)"
}

echo "--- S. the seeded rows"
seed "$PGVIGIL_REPO_DSN" S
SID1=$(q "select instance_id from pgvigil.instances where name = 'seed-ms1-$SUF'"); SID2=$(q "select instance_id from pgvigil.instances where name = 'seed-ms2-$SUF'")
echo "S: OK ($(wc -l < "$WORK/seed.expect") lines)"

# ---------------------------------------------------------------------------------------------------------------
echo "--- the two instances and their reads"
SRC_WM=$(d1 "select source from pg_settings where name = 'work_mem'"); SRC_MWM=$(d1 "select source from pg_settings where name = 'maintenance_work_mem'")
server_level() { case "$1" in 'configuration file'|'command line'|'environment variable'|global|database) return 0;; *) return 1;; esac; }
d1 "create table t_same (id int, v text); create table t_only_a (id int primary key, v text); create table t_grow (id int, pad text);
    insert into t_grow select g, repeat('x', 100) from generate_series(1, 2000) g;"
d1 "vacuum analyze t_grow"   # its own call: several statements in one -c are one transaction, and VACUUM takes none
d2 "create table t_same (id int, v text); create table t_new (id int primary key); create table t_after (id int); create table t_grow (id int, pad text);"
adm -c "alter database $D2 set work_mem = '6MB'" -c "alter database $D2 set maintenance_work_mem = '70MB'"
for i in "$NA" "$NB"; do collect instance "$i"; collect schema "$i"; done
IA=$(q "select instance_id from pgvigil.instances where name = '$NA'"); IB=$(q "select instance_id from pgvigil.instances where name = '$NB'")
cron() { echo "{\"kind\":\"job\",\"scheduler\":\"pg_cron\",\"job_id\":$1,\"job_name\":\"$2\",\"schedule\":\"$3\",\"command\":\"SELECT 1\",\"datname\":\"app\",\"run_as\":\"postgres\",\"active\":true}"; }
imp() { q "select pgvigil.import_jobs($1, clock_timestamp(), \$j\$[$2]\$j\$::jsonb)" >/dev/null; }
imp "$IA" "$(cron 1 nightly '0 3 * * *'),$(cron 7 weekly '0 4 * * 0')"
imp "$IB" "$(cron 4 nightly '30 3 * * *'),$(cron 9 weekly '0 4 * * 0')"
sleep 1.1; AT_A=$(stamp); sleep 1.1
d1 "create table t_new (id int primary key); create table t_temp (id int);"
adm -c "alter database $D1 set work_mem = '6MB'"
collect schema "$NA"
d1 "drop table t_temp"
sleep 1.1; collect schema "$NA"
collect instance "$NA"
NOW=$(date -u +%s); ts() { date -u -d "@$1" +%FT%TZ; }
RUNS=""; for i in 1 2 3 4; do st=$((NOW - 3600 + i * 600)); RUNS+=",{\"kind\":\"run\",\"scheduler\":\"pg_cron\",\"job_id\":1,\"run_id\":$i,\"status\":\"succeeded\",\"return_message\":\"SELECT 1\",\"start_time\":\"$(ts $st)\",\"end_time\":\"$(ts $st)\",\"duration_secs\":0}"; done
imp "$IA" "$(cron 1 nightly '15 3 * * *'),$(cron 7 weekly '0 4 * * 0')$RUNS"
sleep 1.1; AT_B=$(stamp); sleep 1.1
d1 "create table t_after (id int)"
collect schema "$NA"
echo "  instances $IA ($NA, database $D1) and $IB ($NB, database $D2); AT_A $AT_A, AT_B $AT_B; work_mem source before: $SRC_WM, maintenance_work_mem: $SRC_MWM"

# ---- the API
PORT=$((20000 + RANDOM % 20000)); while ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q .; do PORT=$((20000 + RANDOM % 20000)); done
U="http://127.0.0.1:$PORT"
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$WORK/serve.yaml"
"$BIN" serve -config "$WORK/serve.yaml" -listen "127.0.0.1:$PORT" -no-login >"$LOG" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "$U/api/health" >/dev/null 2>&1 && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || fail "serve exited: $(cat "$LOG")"
api() { local code; code=$(curl -s -o "$LOG.body" -w '%{http_code}' "$U/api/$1"); [ "$code" = "${2:-200}" ] || fail "/api/$1 answered $code, expected ${2:-200}: $(head -c 600 "$LOG.body")"; cat "$LOG.body"; }
# py <python lines>: the reply on stdin as d; rows(k) = its part k as a list of dicts
py() { python3 -c "import json, sys
d = json.load(sys.stdin)
def rows(k):
    t = d.get(k) or {'columns': [], 'rows': []}
    return [dict(zip(t['columns'], r)) for r in t['rows']]
$1"; }
EA=$(enc "$AT_A"); EB=$(enc "$AT_B")

echo "--- A. two instances as last read"
if server_level "$SRC_MWM"; then ST_MWM=different; else ST_MWM="only b"; fi
KIDS=$(q "select count(*) from pgvigil.schema_objects where instance_id = $IA and datname = '$D1' and parent = 'public.t_only_a' and is_present")
[ "$KIDS" -ge 4 ] || fail "A: t_only_a has $KIDS children in the repository, expected 4 or more (2 columns, its key's index and constraint)"
R=$(api "diff?a=$IA&b=$IB&db_a=$D1&db_b=$D2" | py "
s, j, o = rows('settings'), rows('jobs'), rows('schema')
m = rows('meta')[0]
print('%s|%d:%s' % (m['mode'], len(s), ','.join('%s=%s/%s/%s' % (r['name'], r['a_value'], r['b_value'], r['status']) for r in s)))
print('%d:%s' % (len(j), ','.join('%s/%s/%s/%s' % (r['job_name'], r['status'], r['a_job_id'], r['b_job_id']) + ''.join('/%s=%s>%s' % (f['field'], f['a'], f['b']) for f in r['fields']) for r in j)))
print('%d:%s' % (len(o), ','.join('%s/%s/%s/%s/%s/%s' % (r['kind'], r['identity'], r['status'], r['children'], r['datname_a'], r['datname_b']) for r in o)))")
echo "$R" | sed 's/^/  /'
[ "$R" = "instances|1:maintenance_work_mem=$(if [ "$ST_MWM" = different ]; then d1 "select setting from pg_settings where name = 'maintenance_work_mem'"; else echo None; fi)/71680/$ST_MWM
1:nightly/different/1/4/schedule=15 3 * * *>30 3 * * *
1:table/public.t_only_a/only a/$KIDS/$D1/$D2" ] || fail "A: the three differences"
SAME_OBJ=$(q "select count(*) from pgvigil.schema_objects where instance_id = $IB and datname = '$D2' and is_present")
R=$(api "diff?a=$IA&b=$IB&db_a=$D1&db_b=$D2&all=1" | py "
s, j, o = rows('settings'), rows('jobs'), rows('schema')
wm = [r for r in s if r['name'] == 'work_mem']
print('%s|%s|%d|%d|%d' % ('/'.join('%s=%s' % (r['job_name'], r['status']) for r in j), '%s/%s/%s' % (wm[0]['a_value'], wm[0]['b_value'], wm[0]['status']) if wm else '-',
      sum(1 for r in s if r['status'] != 'same'), sum(1 for r in o if r['status'] == 'same'), sum(1 for r in o if r['status'] != 'same')))")
echo "  all=1: $R"
[ "$R" = "nightly=different/weekly=same|6144/6144/same|1|$SAME_OBJ|1" ] || fail "A: all=1 (the identical job, work_mem the same, $SAME_OBJ identical objects)"
api "diff?a=$IA&b=$SID1" 400 >/dev/null
api "diff?a=$IA&b=$IB&at_a=$EA" 400 >/dev/null
api "diff?a=$IA&b=$IA" 400 >/dev/null
api "diff?a=$IA&b=999999999" 404 >/dev/null
R=$(api "diff?a=$SID1&b=$SID2" | py "
c = {r['section']: r['compared'] for r in rows('coverage')}
print('%s|%d|%d|%s|%s|%s' % (rows('meta')[0]['engine'], len(rows('settings')), len(rows('jobs')), 'schema' in d, c['schema'], c['settings'] and c['jobs']))")
echo "  SQL Server pair: $R"
[ "$R" = "sqlserver|2|3|False|False|True" ] || fail "A: the seeded SQL Server pair"
R=$(api "diff?a=$IA&b=$IB&part=databases" | py "print(','.join(sorted(set(r['datname'] for r in rows('databases')) & {'$D1', '$D2'})) + '|' + str(len(d)))")
[ "$R" = "$D1,$D2|1" ] || fail "A: part=databases ($R)"
echo "A: OK"

echo "--- B. one instance at two times"
if server_level "$SRC_WM"; then ST_WM=different; WM_A=$(q "select old_value from pgvigil.instance_setting_history where instance_id = $IA and name = 'work_mem' order by changed_at limit 1"); else ST_WM="only b"; WM_A=None; fi
R=$(api "diff?a=$IA&b=$IA&at_a=$EA&at_b=$EB&db_a=$D1" | py "
s, j, o = rows('settings'), rows('jobs'), rows('schema')
print('%s|%d:%s' % (rows('meta')[0]['mode'], len(s), ','.join('%s=%s/%s/%s' % (r['name'], r['a_value'], r['b_value'], r['status']) for r in s)))
print('%d:%s' % (len(j), ','.join('%s/%s' % (r['job_name'], r['status']) + ''.join('/%s=%s>%s' % (f['field'], f['a'], f['b']) for f in r['fields']) for r in j)))
print('%d:%s' % (len(o), ','.join('%s/%s/%s' % (r['kind'], r['identity'], r['status']) for r in o)))")
echo "$R" | sed 's/^/  /'
[ "$R" = "snapshots|1:work_mem=$WM_A/6144/$ST_WM
1:nightly/different/schedule=0 3 * * *>15 3 * * *
1:table/public.t_new/only b" ] || fail "B: the three changes between AT_A and AT_B"
R=$(api "diff?a=$IA&b=$IA&at_a=$EA&db_a=$D1" | py "print(','.join(sorted('%s/%s' % (r['identity'], r['status']) for r in rows('schema'))))")
echo "  to the newest read: $R"
[ "$R" = "public.t_after/only b,public.t_new/only b" ] || fail "B: without at_b the table created after AT_B shows too"
api "diff?a=$IA&b=$IA&at_a=$EB&at_b=$EA" 400 >/dev/null
echo "B: OK"

echo "--- C. connections over time"
for i in 1 2 3; do (echo "select 1;"; sleep 90) | PGAPPNAME=pvdg_idle_$SUF psql "$DG_A_DSN" -XAtq >/dev/null 2>&1 & BG="$BG $!"; done
IDLE_PIDS=$BG
appcount() { psql "$ADMIN_DSN" -XAt -c "select count(*) from pg_stat_activity where application_name = 'pvdg_idle_$SUF'"; }
for _ in $(seq 1 50); do [ "$(appcount)" = 3 ] && break; sleep 0.1; done
[ "$(appcount)" = 3 ] || fail "C setup: $(appcount) idle sessions"
C0=$(stamp)
collect connections "$NA"; H1=$(appcount); sleep 1.2
collect connections "$NA"; H2=$(appcount); sleep 1.2
# shellcheck disable=SC2086
kill $IDLE_PIDS 2>/dev/null || true
for _ in $(seq 1 50); do [ "$(appcount)" = 0 ] && break; sleep 0.1; done
collect connections "$NA"; H3=$(appcount)
R=$(q "select string_agg(conns::text, ',' order by bucket) || '|' || count(*) from pgvigil.conn_sources_series($IA, '-infinity', 'infinity', 'application', 1, 1000000) where source = 'pvdg_idle_$SUF'")
echo "  the application per read: $R (hand counts $H1,$H2,$H3)"
[ "$R" = "$H1,$H2,$H3|3" ] && [ "$H1,$H2,$H3" = "3,3,0" ] || fail "C: the per-read connections against the hand counts"
R=$(q "select bool_and(w.avg_total = s.avg1 and w.peak_total = s.peak) || '|' || (count(*) >= 1)
         from pgvigil.conn_sources_window($IA, '-infinity', 'infinity', '{application}') w
         join (select source, round(sum(conns)::numeric / sum(reads), 1) as avg1, max(peak) as peak
                 from pgvigil.conn_sources_series($IA, '-infinity', 'infinity', 'application', 60, 1000000) group by source) s on s.source = w.application_name")
[ "$R" = "true|true" ] || fail "C: the series' totals against the grid's ($R)"
EC0=$(enc "$C0"); ENOW=$(enc "$(stamp)")
TOTAL=$(q "select sum(total) from pgvigil.conn_sources where instance_id = $IA and snapshot_at > '$C0'")
R=$(api "connections?instance=$IA&from=$EC0&to=$ENOW&by=application&chart=application" | py "
from decimal import Decimal, ROUND_HALF_UP
g = {r['application_name']: r for r in rows('sources')}
m = rows('series_meta')[0]
ser = {}
for r in rows('series'):
    k = (r['source'], r['folded'])
    a = ser.setdefault(k, [0, 0, 0]); a[0] += r['conns']; a[1] += r['reads']; a[2] = max(a[2], r['peak'])
named = [k for k in ser if not k[1]]
ok = all((Decimal(ser[k][0]) / Decimal(ser[k][1])).quantize(Decimal('0.1'), rounding=ROUND_HALF_UP) == Decimal(str(g[k[0]]['avg_total'])) and ser[k][2] == g[k[0]]['peak_total'] for k in named)
print('%s|%s|%s|%s|%d' % (m['step_secs'], m['dim'], 1 <= len(named) <= 8, ok, sum(a[0] for a in ser.values())))")
echo "  the API's chart: $R (conn_sources' total $TOTAL)"
[ "$R" = "60|application|True|True|$TOTAL" ] || fail "C: the API's series against the grid and the stored total"
api "connections?instance=$IA&chart=nonsense" 400 >/dev/null
echo "C: OK"

echo "--- D. the fleet's table sizes"
sleep 1.2; D0=$(stamp); sleep 1.1
collect tables "$NA"; H1=$(d1 "select pg_total_relation_size('t_grow')")
sleep 1.1; DM=$(stamp); sleep 1.1
d1 "insert into t_grow select g, repeat('x', 100) from generate_series(2001, 22000) g"
d1 "vacuum analyze t_grow"
sleep 1.3   # the cumulative statistics reach the shared view
collect tables "$NA"; H2=$(d1 "select pg_total_relation_size('t_grow')")
[ "$H2" -gt "$H1" ] || fail "D setup: the table did not grow ($H1 -> $H2)"
R=$(q "select total_bytes || '|' || growth_bytes || '|' || growth_rows || '|' || in_window || '|' || (heap_bytes is not null) from pgvigil.table_size_fleet('$D0', now(), 1000000, 'size') where instance_id = $IA and datname = '$D1' and table_name = 't_grow'")
echo "  from before read 1: $R (hand $H1 -> $H2)"
[ "$R" = "$H2|$((H2 - H1))|20000|true|true" ] || fail "D: the size and growth against the hand reads (a window from before the first read)"
R=$(q "select total_bytes || '|' || base_bytes || '|' || growth_bytes || '|' || in_window from pgvigil.table_size_fleet('$DM', now(), 1000000, 'growth') where instance_id = $IA and datname = '$D1' and table_name = 't_grow'")
[ "$R" = "$H2|$H1|$((H2 - H1))|false" ] || fail "D: a window from between the two reads ($R)"
ED0=$(enc "$D0"); T=$(stamp); ENOW=$(enc "$T")
for ord in growth size; do
  EXP=$(q "select coalesce(string_agg(instance_id || '.' || dbid || '.' || relid, ',' order by ordinality), '') from pgvigil.table_size_fleet('$D0', '$T', 20, '$ord') with ordinality")
  GOT=$(api "tablesize?from=$ED0&to=$ENOW&top=20&order=$ord" | py "print(','.join('%s.%s.%s' % (r['instance_id'], r['dbid'], r['relid']) for r in rows('tables')))")
  [ -n "$EXP" ] && [ "$GOT" = "$EXP" ] || fail "D: /api/tablesize order=$ord against the function"
done
EXPM=$(q "select count(*) filter (where engine = 'postgres') || '|' || count(*) filter (where engine = 'sqlserver') from pgvigil.instances where is_active")
R=$(api "tablesize?from=$ED0&to=$ENOW" | py "m = rows('meta')[0]; print('%s|%s' % (m['pg_instances'], m['mssql_instances'])); assert m['instances_read'] == 1 and m['top'] == 100 and m['order'] == 'size', m")
[ "$R" = "$EXPM" ] || fail "D: meta $R against the hand count $EXPM"
api "tablesize?top=7" 400 >/dev/null
api "tablesize?order=x" 400 >/dev/null
echo "D: OK"

echo "--- E. the job chart and the step cut"
FROM=$(date -u -d '-6 hours' +%Y-%m-%dT%H:%M:%SZ); TO=$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)
JQ="jobs/history?engine=mssql&instance=$SID1&from=$FROM&to=$TO&scheduler=sqlagent&job=JOB1"
R=$(api "$JQ" | py "
c, s, st = rows('counts')[0], rows('series'), rows('stats')
hit = [r for r in s if r['runs'] > 0]
print('%s/%s/%s|%d/%d|%d|%s|%s|%s' % (c['runs'], c['failed'], c['succeeded'], sum(r['runs'] for r in s), sum(r['failed'] for r in s), len(hit),
      all(float(r['avg_s']) == 0 and float(r['max_s']) == 0 for r in hit), all(r['avg_s'] is None for r in s if r['runs'] == 0) and len(s) > len(hit),
      ';'.join('%s:%s/%s/%s' % (r['step_id'], r['step_name'], r['failed'], r['succeeded']) for r in st)))")
echo "  the job: $R"
[ "$R" = "3/2/1|3/2|3|True|True|0:(job outcome)/2/1;1:one/0/3;2:two/2/1" ] || fail "E: the SQL Server job's counts, series and steps"
R=$(api "$JQ&step=2" | py "
r, c = rows('runs'), rows('counts')[0]
print('%d|%s|%s|%s/%s|%d|%s' % (len(r), ','.join(x['outcome'] for x in r), all(x['failed_step'] == '2 two' for x in r), c['failed'], c['succeeded'], sum(x['runs'] for x in rows('series')), rows('series_meta')[0]['step']))")
echo "  step 2: $R"
[ "$R" = "3|failed,succeeded,failed|True|2/1|3|2" ] || fail "E: the step cut"
R=$(api "$JQ&step=1" | py "print('%s|%s' % (','.join(x['outcome'] for x in rows('runs')), rows('counts')[0]['failed']))")
[ "$R" = "succeeded,succeeded,succeeded|0" ] || fail "E: step 1 ($R)"
PQ="jobs/history?engine=pg&instance=$IA&from=$FROM&to=$TO&scheduler=pg_cron&job=1"
R=$(api "$PQ" | py "
c, s, st = rows('counts')[0], rows('series'), rows('stats')
print('%s|%d|%d|%s|%s' % (c['runs'], sum(r['runs'] for r in s), len(st), '%s:%s/%s' % (st[0]['step_id'], st[0]['succeeded'], st[0]['failed']), all(float(r['avg_s']) == 0 for r in s if r['runs'] > 0)))")
echo "  the PostgreSQL job: $R"
[ "$R" = "4|4|1|0:4/0|True" ] || fail "E: the PostgreSQL job's chart"
api "$PQ&step=2" 400 >/dev/null
api "$JQ&step=0" 400 >/dev/null
api "jobs/history?engine=mssql&instance=$SID1&from=$FROM&to=$TO&step=2" 400 >/dev/null
echo "E: OK"

echo "--- F. the settings' detail"
HANDQ="select name || '|' || case when name in ('primary_conninfo','archive_command','restore_command','archive_cleanup_command','recovery_end_command','ssl_passphrase_command','ssl_key_file') then '<masked>' else setting end
              || '|' || coalesce(unit, '-') || '|' || coalesce(boot_val, '-') || '|' || source || '|' || context || '|' || pending_restart || '|' || category
         from pg_settings where source in ('configuration file','command line','environment variable','global','database') or pending_restart order by name"
GOTQ="select name || '|' || case when value = '<masked>' then '<masked>' else value end || '|' || coalesce(unit, '-') || '|' || coalesce(default_value, '-') || '|' || source || '|' || context || '|' || pending_restart || '|' || category
        from pgvigil.pg_config_settings($IA) order by name"
if [ "${PGVIGIL_PROOF_NO_ALTER_SYSTEM:-}" = 1 ] || [ "$(adm -c "select count(*) from pg_file_settings where name = 'event_source'")" != 0 ] || [ "$(evt_pending)" != f ]; then
  PEND="not proven: event_source is already set in a configuration file here or already reads pending restart, or PGVIGIL_PROOF_NO_ALTER_SYSTEM=1"
else
  echo "  the one server setting, before: event_source = $(adm -c "show event_source"), in no configuration file, not pending. Its undo: ALTER SYSTEM SET event_source = '<that value>'; SELECT pg_reload_conf(); ALTER SYSTEM RESET event_source; SELECT pg_reload_conf();"
  MADE_EVT=1
  adm -c "alter system set event_source = '$EVT'" -c "select pg_reload_conf()" >/dev/null
  for _ in $(seq 1 50); do [ "$(d1 "select pending_restart from pg_settings where name = 'event_source'")" = t ] && break; sleep 0.1; done
  [ "$(d1 "select pending_restart || '|' || source || '|' || setting from pg_settings where name = 'event_source'")" = "true|default|PostgreSQL" ] \
    || fail "F setup: event_source does not read pending restart after the reload: $(d1 "select pending_restart, source, setting from pg_settings where name = 'event_source'")"
  PEND=set
fi
collect instance "$NA"
HAND=$(d1 "$HANDQ"); GOT=$(q "$GOTQ")
[ -n "$GOT" ] && [ "$GOT" = "$HAND" ] || { diff <(echo "$HAND") <(echo "$GOT") | head -20; fail "F: pg_config_settings against the hand read of pg_settings (above: < hand, > stored)"; }
echo "  $(grep -c . <<<"$GOT") settings equal the hand read of pg_settings"
if [ "$PEND" = set ]; then
  R=$(q "select name || '|' || value || '|' || source || '|' || context || '|' || restart_needed || '|' || pending_restart || '|' || non_default from pgvigil.pg_config_settings($IA) where name = 'event_source'")
  echo "  the pending setting: $R"
  [ "$R" = "event_source|PostgreSQL|default|postmaster|true|true|false" ] || fail "F: the setting waiting for a restart"
  [ "$(q "select pending_restart from pgvigil.pg_config_settings($IA) limit 1")" = t ] || fail "F: the settings waiting for a restart are not listed first"
  [ "$(q "select count(*) from pgvigil.instance_setting_history where instance_id = $IA and name = 'event_source'")" = 0 ] || fail "F: a pending setting made a change-history row"
  R=$(api "pgconfig?instance=$IA" | py "r = rows('settings'); e = [x for x in r if x['name'] == 'event_source'][0]; print('%s|%s|%s|%s|%d' % (r[0]['pending_restart'], e['pending_restart'], e['source'], e['detail_read'], len(r)))")
  [ "$R" = "True|True|default|True|$(grep -c . <<<"$GOT")" ] || fail "F: /api/pgconfig ($R)"
  undo_evt
  [ "$(d1 "select pending_restart || '|' || source || '|' || setting from pg_settings where name = 'event_source'")" = "false|default|PostgreSQL" ] \
    || fail "F: event_source is not back after the undo: $(d1 "select pending_restart, source, setting from pg_settings where name = 'event_source'")"
  [ "$(adm -c "select count(*) from pg_file_settings where name = 'event_source'")" = 0 ] || fail "F: event_source is still in a configuration file after the undo"
  MADE_EVT=
  echo "F: OK (the pending restart set, read and undone)"
else
  R=$(api "pgconfig?instance=$IA" | py "r = rows('settings'); print('%s|%d' % (r[0]['detail_read'], len(r)))")
  [ "$R" = "True|$(grep -c . <<<"$GOT")" ] || fail "F: /api/pgconfig ($R)"
  echo "F: OK for the columns; the live pending restart $PEND (the seeded S5 row covers the function)"
fi

echo "--- G. PostgreSQL 13"
G_NOTE=
if [ "${PGVIGIL_PROOF_SKIP_PG13:-}" = 1 ]; then
  G_NOTE=" (G NOT PROVEN: PGVIGIL_PROOF_SKIP_PG13=1)"; echo "G: not proven: skipped on PGVIGIL_PROOF_SKIP_PG13=1"
else
  if [ -n "${PGVIGIL_PG13_DSN:-}" ]; then
    DSN13=$PGVIGIL_PG13_DSN
  else
    command -v docker >/dev/null 2>&1 || fail "G: no PGVIGIL_PG13_DSN and no docker: a PostgreSQL 13 is needed (or PGVIGIL_PROOF_SKIP_PG13=1, said in the last line)"
    # a throwaway password, handed to the container and to libpq through the environment of those calls alone
    # (never on a command line, and never left in this script's own environment: the sandbox's comes from ~/.pgpass)
    PW13=Pv$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    CT13=pgvigil-diffgrids13-$SUF
    POSTGRES_PASSWORD=$PW13 docker run -d --name "$CT13" -e POSTGRES_PASSWORD -p 127.0.0.1::5432 postgres:13 >/dev/null || fail "G: docker run postgres:13"
    P13=$(docker port "$CT13" 5432/tcp | head -1 | sed 's/.*://')
    DSN13="host=127.0.0.1 port=$P13 user=postgres"
    for _ in $(seq 1 120); do with13 psql "$DSN13 dbname=postgres" -XAtc "select 1" >/dev/null 2>&1 && break; sleep 0.5; done
    sleep 1   # the image starts once to initialise and again to serve
    for _ in $(seq 1 120); do with13 psql "$DSN13 dbname=postgres" -XAtc "select 1" >/dev/null 2>&1 && break; sleep 0.5; done
  fi
  V13=$(with13 psql "$DSN13 dbname=postgres" -XAtc "show server_version_num") || fail "G: the PostgreSQL 13 does not answer"
  [ "${V13:0:2}" = 13 ] || fail "G: that server is version $V13, not 13"
  with13 psql "$DSN13 dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $DB13" || fail "G: create database"
  MADE_13=1
  printf 'repository:\n  dsn: env:PG13_REPO_DSN\ninstances: []\n' > "$WORK/pg13.yaml"
  PG13_REPO_DSN="$DSN13 dbname=$DB13" with13 "$BIN" migrate -config "$WORK/pg13.yaml" >"$OUT" 2>&1 || { tail -20 "$OUT"; fail "G: the migrations on PostgreSQL 13"; }
  [ "$(with13 psql "$DSN13 dbname=$DB13" -XAtc "select count(*) from pgvigil.schema_version where version like '0086%'")" = 1 ] || fail "G: 0086 is not recorded on PostgreSQL 13"
  with13 seed "$DSN13 dbname=$DB13" G
  echo "G: OK (server_version_num $V13: every migration through 0086 applied; seed.sql prints the expected text)"
fi
echo "PROOF OK$G_NOTE"
