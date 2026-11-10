#!/usr/bin/env bash
# Proof of 'pgvigil demo': the synthetic fleet reaches the repository through the import functions,
# every page's endpoint answers with rows, a re-run replaces the demo instances and nothing else, and
# -pgbin runs the whole thing on a throwaway PostgreSQL started from a bin folder.
#   PGVIGIL_ADMIN_DSN  a superuser connection without dbname (creates and drops a scratch database)
#   PGVIGIL_PGBIN      a PostgreSQL bin folder with initdb and pg_ctl for the -pgbin part (default: the
#                      folder of the initdb on the PATH; none = that part is skipped and says so)
# N = the seed's grid: 7 days at 5 minutes up to the last hour, then every minute (2,065 points when
# the anchor is on a 5-minute mark, 2,066 when it is not), plus the seed's catch-up ticks (one a minute from the
# anchor, which the seed prints, to the minute the seed returns).
# Expected:
#   instances    15 tagged demo: twelve PostgreSQL (onprem 3, rds 2, aurora 3, azure 2, cloudsql 2) and three SQL
#                Server (sqlserver 2, azuresqlmi 1); the non-demo
#                instance seeded before the run is untouched after two runs
#   activity     N summaries per PostgreSQL instance, none on a SQL Server one; at the latest snapshot blocking_chains() gives
#                onprem-erp01 3 waiters (depth up to 2, active head), rds-orders01 6 (depth up to 2,
#                head running the report), onprem-hr01 2 (head 'idle in transaction'), every other 0
#   dbstats      N rows per database (onprem-erp01/02: 3 databases, the others 2) = 26 N
#   statements   statements_info at every 5-minute snapshot on 11 instances (none on
#                cloudsql-analytics02); reset rows on rds-orders01 only
#   overview     exactly these demo rows (check@instance):
#                  collection failing@cloudsql-analytics02 (statements), replay lag@onprem-erp01,
#                  replay lag@onprem-erp02, inactive slot retaining WAL@rds-billing01,
#                  job failed@aurora-crm01 x2, DMS CDC latency@aurora-dms01, DMS changes on disk@aurora-dms01,
#                  DMS tables in error@aurora-dms01, DMS validation failures@aurora-dms01, DMS validation
#                  suspended@aurora-dms01 (the attachments table in 'Error'), deadlocks (24 h)@rds-orders01
#                  with '3 deadlock(s)', table autovacuum off@onprem-hr01, table bloat@onprem-erp01, table dead
#                  rows@rds-orders01, table never vacuumed@aurora-dms01; no stale collection, no 'check could not run'
#   jobs         aurora-crm01 4 jobs (three and the job report's sync-contacts), rds-billing01 4 (two and the job
#                report's export-ledger and rollup-invoices: internal/demo/jobsreport_demo.go)
#   logs         slow, lock_wait, deadlock, auth_fail, corruption (the corruption demo) and temp_file (the memory
#                demo) events; 3 deadlocks in 24 h on rds-orders01
#   dms          2 tasks, 15 tables, 2 in 'Table error'; the CDC task's drain readout has a rows ETA and a latency
#                ETA (latency falling, speed over 1x) and is spilling
#   tables       14 databases, 70 tables present (5 per application database; cloudsql-analytics01's skipped
#                table keeps its last read: older than its database's read on an odd UTC hour, the same on an
#                even one); table_checks = exactly the four table rows of the overview
#   settings     one change each on onprem-erp01 (work_mem) and rds-orders01 (log_min_duration_statement)
#   rerun        "15 replaced"; no instance_id of the first run is left in any table with an instance_id
#                column; the same counts; a non-demo instance named like a demo one (prefix trap-) makes
#                the seed refuse with "exist without the demo tag" and stays as it was
#   api          without a login: instances 15, overview the rows above, activity chains 3,
#                statements >= 10 rows over 7 days, counters db/server/io/sessions rows > 0, dms 2 tasks
#   pgbin        initdb + start on a free port, seed, serve on -listen 127.0.0.1:0 (the logged URL answers);
#                within 150 s a live snapshot newer than
#                the seed's anchor; SIGINT exits 0 and leaves no postmaster.pid
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_ADMIN_DSN:?}"
DB="pgvigil_it_demo_$RANDOM"; CFG=$(mktemp); WORK=$(mktemp -d); CREATED=""; SPID=""; GPID=""
cleanup() {
  [[ -n "$SPID" ]] && kill "$SPID" 2>/dev/null || true
  [[ -n "$GPID" ]] && kill -INT "$GPID" 2>/dev/null && wait "$GPID" 2>/dev/null || true
  [[ -f "$WORK/data/postmaster.pid" && -n "${PGBIN:-}" ]] && "$PGBIN/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$CFG" "$WORK"
  [[ -n "$CREATED" ]] && psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB"; CREATED=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\n' > "$CFG"
P() { psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
"$BIN" migrate -config "$CFG" >/dev/null 2>&1 || fail "migrate"
KEEP=$(P -c "select pgvigil.ensure_instance('keep-$RANDOM', 'onprem', '16.1', 160001, false, '{prod}')")
P -c "select pgvigil.log_collection($KEEP, 'instance', now(), 10, 'ok', null)" >/dev/null

OUT=$("$BIN" demo -config "$CFG" 2>"$WORK/seed1.log") || { cat "$WORK/seed1.log" >&2; fail "seed 1"; }
echo "$OUT"
FIRST_IDS=$(P -c "select string_agg(instance_id::text, ',') from pgvigil.instances where 'demo' = any(tags)")
ANCHOR=$(P -c "select max(snapshot_at) from pgvigil.activity_summary")
# the seed prints its anchor and ticks on from it to the current minute before it returns: N is the grid (2,065
# points when the anchor is on a 5-minute mark, 2,066 when it is not) plus the snapshot times after the anchor
SEED_ANCHOR=$(sed -n 's/.*; anchor \([0-9TZ:-]*\)$/\1/p' <<<"$OUT"); [[ -n "$SEED_ANCHOR" ]] || fail "the seed printed no anchor"
TICKS=$(P -c "select count(distinct snapshot_at) from pgvigil.activity_summary where snapshot_at > '$SEED_ANCHOR'")
N=$(P -c "select case when extract(minute from '$SEED_ANCHOR'::timestamptz)::int % 5 = 0 then 2065 else 2066 end + $TICKS")
(( TICKS <= 30 )) || fail "$TICKS catch-up ticks: the seed stops ticking thirty minutes after its anchor"
got=$(P -c "select count(distinct snapshot_at) from pgvigil.activity_summary a join pgvigil.instances i using (instance_id) where 'demo' = any(i.tags)")
[[ "$got" == "$N" ]] || fail "the fleet holds $got snapshot times, want $N (the grid of anchor $SEED_ANCHOR plus $TICKS tick(s))"

check_repo() {
  local got
  got=$(P -c "select string_agg(platform || ' ' || n, ', ' order by platform) from (select platform, count(*) n from pgvigil.instances where 'demo' = any(tags) group by 1) x")
  [[ "$got" == "aurora 3, azure 2, azuresqlmi 1, cloudsql 2, onprem 3, rds 2, sqlserver 2" ]] || fail "platforms: $got"; ok "instances: $got"
  got=$(P -c "select count(*) from pgvigil.instances where instance_id = $KEEP and not 'demo' = any(tags)")
  [[ "$got" == 1 ]] || fail "the non-demo instance is gone"; ok "non-demo instance kept"
  got=$(P -c "select count(*) filter (where n <> $N) from (select i.name, count(a.*) n from pgvigil.instances i left join pgvigil.activity_summary a using (instance_id) where 'demo' = any(i.tags) and i.engine = 'postgres' group by 1) x")
  [[ "$got" == 0 ]] || fail "activity summaries per PostgreSQL instance not $N"; ok "activity: $N summaries per PostgreSQL instance"
  got=$(P -c "select count(*) from pgvigil.activity_summary a join pgvigil.instances i using (instance_id) where i.engine <> 'postgres'")
  [[ "$got" == 0 ]] || fail "$got PostgreSQL activity summaries on a SQL Server instance"; ok "activity: none on the SQL Server instances"
  got=$(P -c "select string_agg(name || '=' || n || '/' || d || '/' || coalesce(h, '-'), ' ' order by name) from (
      select i.name, count(c.*) n, coalesce(max(c.depth), 0) d, max(c.head_state) h
        from pgvigil.instances i
        left join lateral pgvigil.blocking_chains(i.instance_id, (select max(snapshot_at) from pgvigil.activity_summary s where s.instance_id = i.instance_id)) c on true
       where 'demo' = any(i.tags) group by 1) x where n > 0")
  [[ "$got" == "demo-onprem-erp01=3/2/active demo-onprem-hr01=2/1/idle in transaction demo-rds-orders01=6/2/active" ]] || fail "chains: $got"; ok "chains: $got"
  got=$(P -c "select count(*) from pgvigil.dbstats d join pgvigil.instances i using (instance_id) where 'demo' = any(i.tags)")
  [[ "$got" == $((26 * N)) ]] || fail "dbstats rows $got, want $((26 * N))"; ok "dbstats: $got rows"
  got=$(P -c "select count(*) from (select i.name, (select count(*) from pgvigil.statements_info s where s.instance_id = i.instance_id) n,
      (select count(*) from pgvigil.activity_summary a where a.instance_id = i.instance_id and extract(minute from a.snapshot_at)::int % 5 = 0) m
      from pgvigil.instances i where 'demo' = any(i.tags)) x where n = m and n > 0")
  [[ "$got" == 11 ]] || fail "statements_info on $got instance(s), want 11"; ok "statements: 11 instances at every 5-minute snapshot"
  got=$(P -c "select string_agg(distinct i.name, ',') from pgvigil.statements_delta d join pgvigil.instances i using (instance_id) where d.reset and 'demo' = any(i.tags)")
  [[ "$got" == "demo-rds-orders01" ]] || fail "reset rows on: $got"; ok "statements reset on $got"
  got=$(P -c "select string_agg(i.name || '=' || n, ' ' order by i.name) from (select instance_id, count(*) n from pgvigil.jobs group by 1) j join pgvigil.instances i using (instance_id) where 'demo' = any(i.tags)")
  [[ "$got" == "demo-aurora-crm01=4 demo-rds-billing01=4" ]] || fail "jobs: $got"; ok "jobs: $got"
  got=$(P -c "select string_agg(distinct kind, ',' order by kind) from pgvigil.log_events e join pgvigil.instances i using (instance_id) where 'demo' = any(i.tags)")
  [[ "$got" == "auth_fail,corruption,deadlock,lock_wait,slow,temp_file" ]] || fail "log kinds: $got"; ok "log kinds: $got"
  got=$(P -c "select count(*) from pgvigil.log_events e join pgvigil.instances i using (instance_id) where i.name = 'demo-rds-orders01' and kind = 'deadlock' and snapshot_at > now() - interval '24 hours'")
  [[ "$got" == 3 ]] || fail "deadlock events in 24 h: $got"; ok "deadlock events in 24 h: 3"
  got=$(P -c "select count(*) || '/' || (select count(*) from pgvigil.dms_table_stats) || '/' || (select count(*) from pgvigil.dms_table_stats where table_state = 'Table error') from pgvigil.dms_tasks where is_present")
  [[ "$got" == "2/15/2" ]] || fail "dms tasks/tables/errors: $got"; ok "dms tasks/tables/errors: $got"
  got=$(P -c "select count(*) filter (where eta_rows_secs > 0 and eta_secs > 0 and speed_x > 1 and spilling) || '/' || count(*) from pgvigil.dms_drain d join pgvigil.instances i using (instance_id) where 'demo' = any(i.tags) and d.task_id = 'erp-to-aurora-cdc'")
  [[ "$got" == "1/1" ]] || fail "dms drain eta and spill: $got"; ok "dms drain: the CDC task drains (rows and latency ETA, speed over 1x) and is spilling"
  got=$(P -c "select (select count(*) from pgvigil.table_databases d join pgvigil.instances i using (instance_id) where 'demo' = any(i.tags) and d.is_present) || '/' || count(*) from pgvigil.tables t join pgvigil.instances i using (instance_id) where 'demo' = any(i.tags) and t.is_present")
  [[ "$got" == "14/70" ]] || fail "tables databases/tables: $got"; ok "tables: 14 databases, 70 tables"
  # the skip scenario: on an odd UTC hour the latest read skipped event_props, so its row is older than its
  # database's read; on an even hour it was read with it
  got=$(P -c "select case when extract(hour from d.snapshot_at at time zone 'UTC')::int % 2 = 1 then t.snapshot_at < d.snapshot_at else t.snapshot_at = d.snapshot_at end
                from pgvigil.tables t join pgvigil.table_databases d using (instance_id, dbid) join pgvigil.instances i using (instance_id)
               where i.name = 'demo-cloudsql-analytics01' and t.table_name = 'event_props' and t.is_present")
  [[ "$got" == t ]] || fail "skipped table row kept: $got"; ok "tables: the skipped table keeps its last read"
  got=$(P -c "select string_agg(c.check_name || '@' || i.name || ':' || c.object, ' ' order by c.check_name) from pgvigil.table_checks c join pgvigil.instances i using (instance_id) where 'demo' = any(i.tags)")
  [[ "$got" == "table autovacuum off@demo-onprem-hr01:hr.public.timesheets table bloat@demo-onprem-erp01:erp.public.order_lines table dead rows@demo-rds-orders01:orders.public.order_items table never vacuumed@demo-aurora-dms01:erp_mirror.erp.order_lines" ]] || fail "table checks: $got"; ok "table checks: the four scenario tables"
  got=$(P -c "select string_agg(i.name || ':' || h.name, ' ' order by i.name) from pgvigil.instance_setting_history h join pgvigil.instances i using (instance_id) where 'demo' = any(i.tags)")
  [[ "$got" == "demo-onprem-erp01:work_mem demo-rds-orders01:log_min_duration_statement" ]] || fail "setting history: $got"; ok "setting history: $got"
}
check_repo

# the overview and the pages, served without a login
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
"$BIN" serve -config "$CFG" -no-login -listen "127.0.0.1:$PORT" 2>"$WORK/serve.log" & SPID=$!
for _ in $(seq 50); do curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
api() { curl -fsS "http://127.0.0.1:$PORT/api/$1"; }
EXPECTED_OVERVIEW="DMS CDC latency@demo-aurora-dms01
DMS changes on disk@demo-aurora-dms01
DMS tables in error@demo-aurora-dms01
DMS validation failures@demo-aurora-dms01
DMS validation suspended@demo-aurora-dms01
collection failing@demo-cloudsql-analytics02
deadlocks (24 h)@demo-rds-orders01
inactive slot retaining WAL@demo-rds-billing01
job failed@demo-aurora-crm01
job failed@demo-aurora-crm01
replay lag@demo-onprem-erp01
replay lag@demo-onprem-erp02
table autovacuum off@demo-onprem-hr01
table bloat@demo-onprem-erp01
table dead rows@demo-rds-orders01
table never vacuumed@demo-aurora-dms01"
check_api() {
  local got id
  got=$(api instances | python3 -c 'import json,sys; d=json.load(sys.stdin); n=d["columns"].index("tags"); print(sum(1 for r in d["rows"] if "demo" in (r[n] or [])))')
  [[ "$got" == 15 ]] || fail "api instances: $got"; ok "api instances: 15 demo"
  got=$(api overview | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d["columns"]; print("\n".join(sorted(r[c.index("check_name")]+"@"+r[c.index("instance")] for r in d["rows"] if r[c.index("instance")].startswith("demo-") or r[c.index("check_name")]=="check could not run")))')
  [[ "$got" == "$EXPECTED_OVERVIEW" ]] || { echo "$got" >&2; fail "overview rows differ"; }; ok "api overview: the 16 expected demo rows"
  api overview | grep -q '3 deadlock(s)' || fail "overview deadlock detail"; ok "api overview: 3 deadlock(s)"
  id=$(P -c "select instance_id from pgvigil.instances where name = 'demo-onprem-erp01'")
  got=$(api "activity?instance=$id" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["chains"]["rows"]))')
  [[ "$got" == 3 ]] || fail "api activity chains: $got"; ok "api activity: 3 chain rows"
  local from; from=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
  got=$(api "statements?instance=$(P -c "select instance_id from pgvigil.instances where name = 'demo-rds-orders01'")&from=$from" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["rows"]))')
  (( got >= 10 )) || fail "api statements: $got"; ok "api statements: $got rows"
  for k in db server io sessions; do
    got=$(api "counters?kind=$k&instance=$id" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["rows"]))')
    (( got > 0 )) || fail "api counters $k: $got"; ok "api counters $k: $got rows"
  done
  got=$(api dms | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tasks"]["rows"]))')
  [[ "$got" == 2 ]] || fail "api dms tasks: $got"; ok "api dms: 2 tasks"
}
check_api

# a re-run replaces the demo instances and only them
OUT=$("$BIN" demo -config "$CFG" 2>"$WORK/seed2.log") || { cat "$WORK/seed2.log" >&2; fail "seed 2"; }
echo "$OUT"
grep -q "(15 replaced)" <<<"$OUT" || fail "rerun did not replace 15"
LEFT=0; NT=0
for t in $(P -c "select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace join pg_attribute a on a.attrelid = c.oid and a.attname = 'instance_id'
                 where n.nspname = 'pgvigil' and c.relkind in ('r', 'p') and not c.relispartition"); do
  LEFT=$((LEFT + $(P -c "select count(*) from pgvigil.$t where instance_id in ($FIRST_IDS)"))); NT=$((NT + 1))
done
[[ "$LEFT" == 0 ]] || fail "rows of the first run left: $LEFT"; ok "rerun: no row of the first run left in $NT tables"
# a real instance that carries a demo name is never taken over: the seed refuses before any write
TRAP=$(P -c "select pgvigil.ensure_instance('trap-onprem-erp01', 'onprem', '16.1', 160001, false, '{prod}')")
if "$BIN" demo -config "$CFG" -prefix trap- -instances 1 -days 1 >/dev/null 2>"$WORK/trap.log"; then fail "seed over a non-demo instance did not refuse"; fi
grep -q "exist without the demo tag" "$WORK/trap.log" || { cat "$WORK/trap.log" >&2; fail "refusal message"; }
got=$(P -c "select tags::text || '/' || (select count(*) from pgvigil.instances where name like 'trap-%') from pgvigil.instances where instance_id = $TRAP")
[[ "$got" == "{prod}/1" ]] || fail "trap instance changed: $got"; ok "a non-demo instance with a demo name: refused, untouched"
ANCHOR=$(P -c "select max(snapshot_at) from pgvigil.activity_summary")
N=$(P -c "select case when extract(minute from '$ANCHOR'::timestamptz)::int % 5 = 0 then 2065 else 2066 end")
check_repo
check_api
kill "$SPID"; wait "$SPID" 2>/dev/null || true; SPID=""

# -pgbin: a throwaway cluster from a bin folder, seeded and served, live, stopped on SIGINT
PGBIN=${PGVIGIL_PGBIN:-$(dirname "$(command -v initdb 2>/dev/null || echo /nonexistent/initdb)")}
if [[ ! -x "$PGBIN/initdb" ]]; then
  echo "SKIP pgbin: no initdb found (set PGVIGIL_PGBIN)"
else
  # port 0: the server picks one; the logged URL must answer (the Host check follows the bound port)
  "$BIN" demo -serve -pgbin "$PGBIN" -pgdata "$WORK/data" -listen "127.0.0.1:0" >"$WORK/pgbin.out" 2>"$WORK/pgbin.log" & GPID=$!
  PORT=""
  for _ in $(seq 300); do PORT=$(grep -o 'url=http://127.0.0.1:[0-9]*' "$WORK/pgbin.log" | grep -o '[0-9]*$' || true); [[ -n "$PORT" ]] && break; sleep 0.5; done
  [[ -n "$PORT" ]] || { cat "$WORK/pgbin.log" >&2; fail "pgbin: no serving URL logged"; }
  curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null || fail "pgbin: the logged URL $PORT does not answer"; ok "pgbin: -listen 127.0.0.1:0 serves on the logged port $PORT"
  got=$(api instances | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["rows"]))') || { cat "$WORK/pgbin.log" >&2; fail "pgbin serve"; }
  [[ "$got" == 15 ]] || fail "pgbin instances: $got"; ok "pgbin: 15 instances served"
  id=$(api instances | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d["columns"]; print([r[c.index("instance_id")] for r in d["rows"] if r[c.index("name")]=="demo-onprem-erp01"][0])')
  first=$(api "activity?instance=$id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["snapshot_at"])')
  live=""
  for _ in $(seq 150); do
    now=$(api "activity?instance=$id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["snapshot_at"])')
    [[ "$now" != "$first" ]] && { live=$now; break; }
    sleep 1
  done
  [[ -n "$live" ]] || fail "pgbin: no live snapshot after $first"; ok "pgbin: live snapshot $first -> $live"
  kill -INT "$GPID"; rc=0; wait "$GPID" || rc=$?; GPID=""
  [[ "$rc" == 0 ]] || { cat "$WORK/pgbin.log" >&2; fail "pgbin exit $rc"; }
  [[ ! -f "$WORK/data/postmaster.pid" ]] || fail "pgbin: postmaster.pid left"; ok "pgbin: SIGINT exit 0, cluster stopped"
fi
echo "PASS proof-demo"
