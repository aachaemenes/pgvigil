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
#   overview     exactly the 60 demo rows of EXPECTED_OVERVIEW_FIXED below (check@instance), one per finding the
#                demo's scenarios raise across every overview check the waves added (io, pi, host, disk, storage,
#                backups, corruption, custom, roles, indexes, jobs report, vacuum, beside the first ones); 'job
#                failed'@aurora-crm01 once per failed run: refresh-sales-mv twice and sync-contacts four times at the
#                anchor, once more for each 20-minute mark the catch-up ticks pass (jobsreport_demo.go); 'job run over twice
#                its average'@rds-billing01 only while no export-ledger run after the anchor is stored (the
#                demo's next normal run ends it); plus 'vacuum waiting
#                on a lock'@rds-orders01 only when the newest vacuum read is in minutes 30-35 (vacuum_demo.go), and
#                'CPU over 90 % for 10 minutes'@onprem-erp01 only while its host samples cover the rule's last 10
#                minutes (5 readings over 8 minutes: 1 to 2 minutes after the last catch-up tick; host_demo.go);
#                deadlocks (24 h)@rds-orders01 with '3 deadlock(s)'; no stale collection, no 'check could not run'
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
#                column (the dbadash_* tables aside: theirs is DBA Dash's InstanceID, not a pgvigil instance); the same counts; a non-demo instance named like a demo one (prefix trap-) makes
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
grid_n() {
  SEED_ANCHOR=$(sed -n 's/.*; anchor \([0-9TZ:-]*\)$/\1/p' <<<"$OUT"); [[ -n "$SEED_ANCHOR" ]] || fail "the seed printed no anchor"
  TICKS=$(P -c "select count(distinct snapshot_at) from pgvigil.activity_summary where snapshot_at > '$SEED_ANCHOR'")
  N=$(P -c "select case when extract(minute from '$SEED_ANCHOR'::timestamptz at time zone 'UTC')::int % 5 = 0 then 2065 else 2066 end + $TICKS")
  (( TICKS <= 30 )) || fail "$TICKS catch-up ticks: the seed stops ticking thirty minutes after its anchor"
}
grid_n
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
      (select count(*) from pgvigil.activity_summary a where a.instance_id = i.instance_id and extract(minute from a.snapshot_at at time zone 'UTC')::int % 5 = 0) m
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
EXPECTED_OVERVIEW_FIXED="BurstBalance@demo-rds-orders01
DMS CDC latency@demo-aurora-dms01
DMS changes on disk@demo-aurora-dms01
DMS tables in error@demo-aurora-dms01
DMS validation failures@demo-aurora-dms01
DMS validation suspended@demo-aurora-dms01
DiskQueueDepth@demo-rds-orders01
ReadLatency@demo-rds-orders01
archiver failing@demo-onprem-hr01
cache starved by the ACU floor@demo-aurora-reporting01
collection failing@demo-cloudsql-analytics02
corruption: amcheck bt_index_check@demo-onprem-hr01
corruption: corruption in the log@demo-onprem-hr01
corruption: ignore_checksum_failure@demo-cloudsql-analytics02
custom@demo-aurora-crm01
custom@demo-onprem-erp01
deadlocks (24 h)@demo-rds-orders01
disk free under 10 %@demo-onprem-erp02
disk free under 10 %@demo-onprem-hr01
disk free under 10 %@demo-rds-orders01
duplicate index@demo-aurora-crm01
duplicate index@demo-azure-portal02
duplicate index@demo-onprem-erp02
inactive slot retaining WAL@demo-rds-billing01
invalid index@demo-aurora-dms01
invalid index@demo-azure-portal02
invalid index@demo-onprem-erp01
invalid index@demo-rds-orders01
job failing repeatedly@demo-aurora-crm01
job schedule missed@demo-rds-billing01
last archive older than 60 min@demo-onprem-hr01
no snapshot in 24 h@demo-aurora-reporting01
replay lag@demo-onprem-erp01
replay lag@demo-onprem-erp02
retention under 7 days@demo-aurora-dms01
retention under 7 days@demo-rds-orders01
role: BYPASSRLS@demo-aurora-reporting01
role: BYPASSRLS@demo-cloudsql-analytics02
role: BYPASSRLS@demo-rds-orders01
role: CREATEROLE@demo-aurora-crm01
role: CREATEROLE@demo-azure-portal02
role: CREATEROLE@demo-onprem-erp02
role: pg_monitor@demo-azure-portal02
role: pg_monitor@demo-rds-billing01
role: superuser@demo-azure-portal01
role: superuser@demo-onprem-erp01
role: superuser@demo-rds-billing01
swap used@demo-onprem-hr01
swap used@demo-rds-orders01
table autovacuum off@demo-onprem-hr01
table bloat@demo-onprem-erp01
table dead rows@demo-rds-orders01
table never vacuumed@demo-aurora-dms01
table over vacuum threshold@demo-rds-orders01
volume full within 30 days@demo-onprem-erp02
volume full within 30 days@demo-rds-orders01
volume under 10 % free@demo-onprem-erp02
volume under 10 % free@demo-onprem-hr01
volume under 10 % free@demo-rds-orders01
wraparound@demo-onprem-hr01"
# vacuum_demo.go: rds-orders01's manual VACUUM waits on a lock in minutes 30 to 35 of every hour, and vacuum_running
# keeps a read for 10 minutes: the row is expected only when the newest vacuum read is in that window
expected_overview() {
  local v; v=$(P -c "select count(*) from pgvigil.vacuum_state s join pgvigil.instances i using (instance_id)
                      where i.name = 'demo-rds-orders01' and s.snapshot_at > now() - interval '10 minutes'
                        and extract(minute from s.snapshot_at at time zone 'UTC')::int between 30 and 35") || fail "the vacuum window query"; [[ "$v" =~ ^[0-9]+$ ]] || fail "the vacuum window query answered '$v'"
  # 'job failed'@aurora-crm01, one row per failed run of the last day: refresh-sales-mv's two (gen.go jobRows: its hourly
  # :05 runs in [anchor - 7 h, anchor - 5 h)) and every sync-contacts run ('*/20', 1 s when it fails) that starts at or
  # after anchor - 80 min and has ended by the seed's last tick (jobsreport_demo.go): four at the anchor, five when the
  # catch-up ticks pass the next 20-minute mark
  local f; f=$(P -c "select 2 + count(*) from (select max(snapshot_at) last from pgvigil.activity_summary) l,
                      generate_series((date_trunc('hour', '$SEED_ANCHOR'::timestamptz at time zone 'UTC') at time zone 'UTC') - interval '2 hours', l.last, interval '20 minutes') g
                     where g >= '$SEED_ANCHOR'::timestamptz - interval '80 minutes' and g + interval '1 second' <= l.last") || fail "the crm01 job failures query"; [[ "$f" =~ ^[0-9]+$ ]] || fail "the crm01 job failures query answered '$f'"
  # jobsreport_demo.go: export-ledger ('15 * * * *', 30 s) ran 6x as long in its last run up to the anchor; the first
  # normal run after the anchor ends the row, so it is expected only while no run started after the anchor is stored
  local x; x=$(P -c "select count(*) from pgvigil.job_runs r join pgvigil.jobs j using (instance_id, scheduler, job_id)
                      join pgvigil.instances i using (instance_id)
                     where i.name = 'demo-rds-billing01' and j.job_name = 'export-ledger' and r.start_time > '$SEED_ANCHOR'") || fail "the export-ledger runs after the anchor query"; [[ "$x" =~ ^[0-9]+$ ]] || fail "the export-ledger runs after the anchor query answered '$x'"
  # host_demo.go: erp01's CPU sits at 99 %; the rule needs 5 readings spanning 8 minutes inside the last 10, so after the
  # seed returns (plain serve does not tick) the row holds only while erp01's newest host sample is about 2 minutes old
  local c; c=$(P -c "select count(*) >= 5 and max(h.snapshot_at) - min(h.snapshot_at) >= interval '8 minutes'
                      from pgvigil.host_sample h join pgvigil.instances i using (instance_id)
                     where i.name = 'demo-onprem-erp01' and h.snapshot_at > now() - interval '10 minutes' and h.cpu_pct is not null") || fail "erp01's CPU window query"; [[ "$c" =~ ^[tf]$ ]] || fail "erp01's CPU window query answered '$c'"
  { echo "$EXPECTED_OVERVIEW_FIXED"; if [[ "$v" == 1 ]]; then echo "vacuum waiting on a lock@demo-rds-orders01"; fi
    if [[ "$c" == t ]]; then echo "CPU over 90 % for 10 minutes@demo-onprem-erp01"; fi
    for _ in $(seq "$f"); do echo "job failed@demo-aurora-crm01"; done
    if [[ "$x" == 0 ]]; then echo "job run over twice its average@demo-rds-billing01"; fi; } | LC_ALL=C python3 -c 'import sys; print("\n".join(sorted(sys.stdin.read().split("\n")[:-1])))'
}
check_api() {
  local got id
  got=$(api instances | python3 -c 'import json,sys; d=json.load(sys.stdin); n=d["columns"].index("tags"); print(sum(1 for r in d["rows"] if "demo" in (r[n] or [])))')
  [[ "$got" == 15 ]] || fail "api instances: $got"; ok "api instances: 15 demo"
  local want want2; want=$(expected_overview)
  got=$(api overview | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d["columns"]; print("\n".join(sorted(r[c.index("check_name")]+"@"+r[c.index("instance")] for r in d["rows"] if r[c.index("instance")].startswith("demo-") or r[c.index("check_name")]=="check could not run")))')
  want2=$(expected_overview)
  # a clock-bound row whose window closed during the read (erp01's CPU, about 1-2 minutes after the last tick): the API
  # answered at one edge or the other, each an exact list
  [[ "$got" == "$want" || "$got" == "$want2" ]] || { diff <(echo "$want2") <(echo "$got") >&2; fail "overview rows differ"; }; ok "api overview: the $(wc -l <<<"$want") expected demo rows"
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

# a real DBA Dash door whose InstanceID equals a demo pgvigil id (1) and whose repository is configured: a re-seed keeps
# its rows (expected 1/1/1/1) and keeps it configured (expected t); the demo's own repository comes back with 3 instances
P -c "insert into pgvigil.dbadash_repositories (repository, status, read_at) values ('real-door', 'ok', now());
      insert into pgvigil.dbadash_instances (repository, instance_id, instance, display_name, first_seen, snapshot_at) values ('real-door', 1, 'PRODSQL', 'PRODSQL', now(), now());
      insert into pgvigil.dbadash_summary values ('real-door', 1, now(), now(), '{}', '{}');
      insert into pgvigil.dbadash_summary_history values ('real-door', 1, now(), now(), '{}', '{}')" >/dev/null
door() { P -c "select (select count(*) from pgvigil.dbadash_repositories where repository = 'real-door') || '/' || (select count(*) from pgvigil.dbadash_instances where repository = 'real-door')
  || '/' || (select count(*) from pgvigil.dbadash_summary where repository = 'real-door') || '/' || (select count(*) from pgvigil.dbadash_summary_history where repository = 'real-door')
  || ' ' || coalesce((select is_configured::text from pgvigil.dbadash_repositories where repository = 'real-door'), 'none')
  || ' ' || (select count(*) from pgvigil.dbadash_instances where repository = 'dbadash-demo')
  || ' ' || (select count(*) from pgvigil.dbadash_summary_history where repository = 'dbadash-demo')"; }
# a real instance with an open alert older than every demo alert, and a real user named demo who silenced it from the UI:
# a re-seed's acknowledgements stay on the demo fleet (expected '1/1/0 true/true 7': the real silence open with its log row,
# no acknowledgement or note on the real alert, both seeded rules scoped to tag demo, the seed's own 7 rows)
KEEPNAME=$(P -c "select name from pgvigil.instances where instance_id = $KEEP")
P -c "insert into pgvigil.alert_state (channel, finding_key, instance_id, instance_name, severity, first_sent_at, last_sent_at)
      values ('ops', 'realkey1', $KEEP, '$KEEPNAME', 'critical', now() - interval '30 days', now())" >/dev/null
P -c "select pgvigil.import_ack(now(), jsonb_build_object('op','add','ui_user','demo','client','10.0.0.5','kind','silence','instance_name','$KEEPNAME','note','real'))" >/dev/null
acks_real() { P -c "select (select count(*) from pgvigil.acks where instance_name = '$KEEPNAME' and kind = 'silence' and ended_at is null and client = '10.0.0.5')
  || '/' || (select count(*) from pgvigil.ack_log where instance_name = '$KEEPNAME' and client = '10.0.0.5')
  || '/' || (select count(*) from pgvigil.acks where finding_key = 'realkey1')
  || ' ' || (select bool_and(tag = 'demo')::text from pgvigil.acks where client = 'demo seed' and kind = 'mute')
  || '/' || (select bool_and(tag = 'demo')::text from pgvigil.acks where client = 'demo seed' and kind = 'noise')
  || ' ' || (select count(*) from pgvigil.acks where client = 'demo seed')"; }
# a re-run replaces the demo instances and only them
OUT=$("$BIN" demo -config "$CFG" 2>"$WORK/seed2.log") || { cat "$WORK/seed2.log" >&2; fail "seed 2"; }
got=$(door); [[ "${got% *}" == "1/1/1/1 true 3" ]] || fail "a real DBA Dash door after a re-seed (rows, configured, demo instances): ${got% *}"
ok "a real DBA Dash door sharing a demo id: its rows kept and it stays configured over a re-seed"
acks=$(acks_real); [[ "$acks" == "1/1/0 true/true 7" ]] || fail "a real instance's alert and a real user demo's silence after a re-seed (silence/log/acks on the alert, rule tags, seed rows): $acks, wanted 1/1/0 true/true 7"
ok "a re-seed's acknowledgements stay on the demo fleet: the real user demo's silence and log kept, the real alert untouched, the rules tagged demo"
DEMO_HIST=${got##* }
echo "$OUT"
grep -q "(15 replaced)" <<<"$OUT" || fail "rerun did not replace 15"
LEFT=0; NT=0
# the dbadash_* tables' instance_id is DBA Dash's own InstanceID, not a pgvigil instance (0052_dbadash.sql): the demo's
# DBA Dash repository carries ids 1 to 3 on every run, so they are not part of this sweep
for t in $(P -c "select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace join pg_attribute a on a.attrelid = c.oid and a.attname = 'instance_id'
                 where n.nspname = 'pgvigil' and c.relkind in ('r', 'p') and not c.relispartition and c.relname not like 'dbadash\_%'"); do
  LEFT=$((LEFT + $(P -c "select count(*) from pgvigil.$t where instance_id in ($FIRST_IDS)"))); NT=$((NT + 1))
done
[[ "$LEFT" == 0 ]] || fail "rows of the first run left: $LEFT"; ok "rerun: no row of the first run left in $NT tables"
# a real instance that carries a demo name is never taken over: the seed refuses before any write
TRAP=$(P -c "select pgvigil.ensure_instance('trap-onprem-erp01', 'onprem', '16.1', 160001, false, '{prod}')")
if "$BIN" demo -config "$CFG" -prefix trap- -instances 1 -days 1 >/dev/null 2>"$WORK/trap.log"; then fail "seed over a non-demo instance did not refuse"; fi
grep -q "exist without the demo tag" "$WORK/trap.log" || { cat "$WORK/trap.log" >&2; fail "refusal message"; }
got=$(P -c "select tags::text || '/' || (select count(*) from pgvigil.instances where name like 'trap-%') from pgvigil.instances where instance_id = $TRAP")
[[ "$got" == "{prod}/1" ]] || fail "trap instance changed: $got"; ok "a non-demo instance with a demo name: refused, untouched"
got=$(door); [[ "$got" == "1/1/1/1 true 3 $DEMO_HIST" ]] || fail "after a refused seed (door rows, configured, demo instances, demo history): $got, wanted 1/1/1/1 true 3 $DEMO_HIST"
ok "a refused seed leaves the demo's DBA Dash repository and the real door as they were"
# the second seed's grid from its own printed anchor and ticks, as the first
grid_n
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
