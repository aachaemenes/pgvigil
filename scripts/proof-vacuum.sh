#!/usr/bin/env bash
# Proof of the vacuum and vacuum_tables collections and the 0024 views (task 35).
#
#   ADMIN_DSN   a superuser connection to the sandbox server (default: PGVIGIL_REPO_DSN). The proof makes its own
#               repository database, a target database and a pg_monitor-only login, all with a random suffix, and
#               drops them at the end; nothing that exists before the run is touched.
#
# Expected (written before the first run):
#  A. the target: t_over (autovacuum on, 10,000 rows analyzed, then 5,000 deleted: threshold 50 + 0.2 x 10,000 =
#     2,050), a session H holding SHARE on t_over inside a REPEATABLE READ transaction that has read it (so it holds
#     an xmin, and autovacuum cannot take the table), and a manual VACUUM t_over waiting behind H; t_own
#     (autovacuum_enabled = false, autovacuum_vacuum_scale_factor 0.01, autovacuum_vacuum_threshold 10, 10,000 rows
#     analyzed, 500 deleted). Collected as the pg_monitor login: activity, vacuum twice (1 s apart), vacuum_tables.
#     - vacuum_running: one 'vacuum' row for the VACUUM's pid: table public.t_over, is_auto false, phase NULL,
#       wait_event_type Lock, blocking_pids holding H's pid
#     - vacuum_checks: 'vacuum waiting on a lock' | warning | <db>.public.t_over, its detail naming H's pid
#     - vacuum_tables t_over: n_dead_tup 5,000, vac_threshold 2,050, over_vacuum true, autovacuum_enabled true,
#       over_since = the read's snapshot; t_own: vac_threshold 110 (its own reloptions), autovacuum_enabled false,
#       over_vacuum false (autovacuum off is never "over"), has_own_settings true
#     - vacuum_databases: the target's row read (tables_at set) with over_vacuum >= 1 and autovacuum_off >= 1;
#       a wraparound row for every database of pg_database, template0 included (xid_age > 0)
#     - vacuum_state: autovacuum 'on', max_workers > 0, freeze_max_age > 0, settings_at set
#     - vacuum_xmin_holders: a 'session' row with H's pid
#     - collection_dates: vacuum ok, vacuum_tables ok
#  B. H released: the VACUUM finishes; a third vacuum read has no running row for it; vacuum_runs holds one run of
#     t_over by that pid with samples 2 and waited_lock true; vacuum_history over the last hour returns it
#  C. seeded imports on a scratch instance:
#     - summary autovacuum 'off' -> 'autovacuum off' | critical
#     - a running vacuum with elapsed 4,000 s (not waiting) -> 'vacuum running over an hour' | warning, and no
#       'vacuum waiting on a lock'; an anti-wraparound analyze waiting on a Lock -> 'vacuum waiting on a lock' | critical
#     - vacuum_tables at T-7h, T-1h and T with db.s.hot over its threshold each time -> hours_over 7.0 and
#       'table over vacuum threshold' | warning; a fourth read at T+18h still over -> critical (25 h); a fifth read
#       not over -> over_since NULL and the check gone; db.s.cold over only at T -> no check (under 6 h)
#     - wraparound rows with freeze_max_age 200,000,000: xid ages 50 M (nothing), 150 M (warning), 1.2 B (critical)
#     - vacuum_findings has as many rows as vacuum_checks for the scratch instance, setting = check_name
#  D. log_events takes kind 'autovacuum' (seeded as the owner) and vacuum_history returns it with source 'log'
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
ADMIN_DSN=${ADMIN_DSN:-$PGVIGIL_REPO_DSN}
SUF=$RANDOM
REPO_DB=pgvigil_vacproof_$SUF; T1=pgvigil_vac1_$SUF; MON=pgvigil_vacmon_$SUF; MONPW=p$RANDOM$RANDOM
dsn_for() { echo "$ADMIN_DSN dbname=$1"; }   # a later keyword wins, in libpq and in pgx
CFG=$(mktemp); HOLD_PID=; VAC_PID=
cleanup() {
  [[ -n "$HOLD_PID" ]] && kill "$HOLD_PID" 2>/dev/null || true
  [[ -n "${H:-}" ]] && psql "$ADMIN_DSN" -XAtq -c "select pg_terminate_backend($H)" >/dev/null 2>&1 || true
  [[ -n "$VAC_PID" ]] && kill "$VAC_PID" 2>/dev/null || true
  rm -f "$CFG"
  for d in "$REPO_DB" "$T1"; do psql "$ADMIN_DSN" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1 || true; done
  psql "$ADMIN_DSN" -XAtq -c "drop role if exists $MON" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for d in "$REPO_DB" "$T1"; do psql "$ADMIN_DSN" -XAtq -c "create database $d" >/dev/null; done
psql "$ADMIN_DSN" -XAtq -c "create role $MON login password '$MONPW' in role pg_monitor" >/dev/null
export PGVIGIL_REPO_DSN; PGVIGIL_REPO_DSN=$(dsn_for "$REPO_DB")
TGT_ADMIN=$(dsn_for "$T1")
export MON_DSN; MON_DSN="$ADMIN_DSN dbname=$T1 user=$MON password=$MONPW"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
t1() { psql "$TGT_ADMIN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }

echo "--- A. a table over its threshold, a VACUUM waiting on a lock"
t1 "create table t_own (id int, pad text) with (autovacuum_enabled = false, autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 10);
    insert into t_own select g, 'x' from generate_series(1, 10000) g;"
t1 "analyze t_own"
t1 "delete from t_own where id <= 500"
# t_over is loaded with autovacuum off (no autovacuum between the delete and the lock), switched on, then H locks it
t1 "create table t_over (id int, pad text) with (autovacuum_enabled = false);
    insert into t_over select g, 'y' from generate_series(1, 10000) g;"
t1 "analyze t_over"
t1 "delete from t_over where id <= 5000"
t1 "alter table t_over set (autovacuum_enabled = true)"
psql "$TGT_ADMIN" -XAtq -c "begin isolation level repeatable read; select count(*) from t_over; lock table t_over in share mode; select pg_sleep(120);" >/dev/null 2>&1 &
HOLD_PID=$!
for _ in $(seq 1 50); do
  [[ $(t1 "select count(*) from pg_locks where relation = 't_over'::regclass and mode = 'ShareLock' and granted") == 1 ]] && break; sleep 0.1
done
H=$(t1 "select pid from pg_locks where relation = 't_over'::regclass and mode = 'ShareLock' and granted")
[[ -n "$H" ]] || fail "the holder did not take its lock"
psql "$TGT_ADMIN" -XAtq -c "vacuum t_over" >/dev/null 2>&1 &
VAC_PID=$!
for _ in $(seq 1 50); do
  [[ $(t1 "select count(*) from pg_stat_activity where query = 'vacuum t_over' and wait_event_type = 'Lock'") == 1 ]] && break; sleep 0.1
done
V=$(t1 "select pid from pg_stat_activity where query = 'vacuum t_over' and wait_event_type = 'Lock'")
[[ -n "$V" ]] || fail "the VACUUM is not waiting on its lock"
sleep 1   # the cumulative statistics reach pg_stat_user_tables at the next flush

cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-vacuum-$SUF
    dsn: env:MON_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
"$BIN" collect -config "$CFG" -once activity >/dev/null || fail "collect activity"
"$BIN" collect -config "$CFG" -once vacuum >/dev/null || fail "collect vacuum (1)"
sleep 1.1
"$BIN" collect -config "$CFG" -once vacuum >/dev/null || fail "collect vacuum (2)"
"$BIN" collect -config "$CFG" -once vacuum_tables >/dev/null || fail "collect vacuum_tables"
iid=$(q "select instance_id from pgvigil.instances where name='proof-vacuum-$SUF'")
for c in vacuum vacuum_tables; do
  [[ $(q "select status from pgvigil.collection_dates where instance_id=$iid and collection='$c'") == ok ]] \
    || fail "$c: $(q "select status || ' ' || coalesce(note, '') from pgvigil.collection_dates where instance_id=$iid and collection='$c'")"
done
[[ $(q "select kind || '|' || table_name || '|' || is_auto || '|' || coalesce(phase, 'null') || '|' || wait_event_type || '|' || ($H = any(blocking_pids))
         from pgvigil.vacuum_running where instance_id=$iid and pid=$V") == "vacuum|public.t_over|false|null|Lock|true" ]] \
  || fail "running row: $(q "select row(r.*) from pgvigil.vacuum_running r where instance_id=$iid")"
[[ $(q "select severity from pgvigil.vacuum_checks where instance_id=$iid and check_name='vacuum waiting on a lock' and object='$T1.public.t_over' and detail ~ 'blocked by pid $H'") == warning ]] \
  || fail "lock check: $(q "select row(c.*) from pgvigil.vacuum_checks c where instance_id=$iid")"
vt() { q "select $1 from pgvigil.vacuum_table_state where instance_id=$iid and datname='$T1' and table_name='$2'"; }
[[ $(vt "n_dead_tup || '|' || vac_threshold || '|' || over_vacuum || '|' || autovacuum_enabled || '|' || (over_since = snapshot_at)" t_over) == "5000|2050|true|true|true" ]] \
  || fail "t_over: $(vt "n_dead_tup, vac_threshold, over_vacuum, autovacuum_enabled, over_since, snapshot_at" t_over)"
[[ $(vt "vac_threshold || '|' || autovacuum_enabled || '|' || over_vacuum || '|' || has_own_settings" t_own) == "110|false|false|true" ]] \
  || fail "t_own: $(vt "vac_threshold, autovacuum_enabled, over_vacuum, has_own_settings, n_dead_tup" t_own)"
[[ $(q "select tables_at is not null and over_vacuum >= 1 and autovacuum_off >= 1 from pgvigil.vacuum_wraparound where instance_id=$iid and datname='$T1'") == t ]] \
  || fail "database row: $(q "select row(w.*) from pgvigil.vacuum_wraparound w where instance_id=$iid and datname='$T1'")"
[[ $(q "select count(*) from pgvigil.vacuum_wraparound where instance_id=$iid and xid_age > 0") == $(psql "$ADMIN_DSN" -XAt -c "select count(*) from pg_database") ]] \
  || fail "wraparound rows: $(q "select count(*) from pgvigil.vacuum_wraparound where instance_id=$iid")"
[[ $(q "select 1 from pgvigil.vacuum_wraparound where instance_id=$iid and datname='template0'") == 1 ]] || fail "template0 has no wraparound row"
[[ $(q "select autovacuum = 'on' and max_workers > 0 and freeze_max_age > 0 and settings_at is not null from pgvigil.vacuum_state where instance_id=$iid") == t ]] \
  || fail "state: $(q "select row(s.*) from pgvigil.vacuum_state s where instance_id=$iid")"
[[ $(q "select count(*) from pgvigil.vacuum_xmin_holders where instance_id=$iid and holder='session' and name='$H'") == 1 ]] \
  || fail "holder: $(q "select row(h.*) from pgvigil.vacuum_xmin_holders h where instance_id=$iid")"
echo "A: OK (VACUUM pid $V waits on holder $H; t_over 5000 dead over 2050; t_own threshold 110 from its reloptions; $(q "select count(*) from pgvigil.vacuum_wraparound where instance_id=$iid") wraparound rows)"

echo "--- B. the run, after the release"
# the backend of a killed psql sleeps on until it next writes to the client: end it on the server
t1 "select pg_terminate_backend($H)" >/dev/null
kill "$HOLD_PID" 2>/dev/null || true; HOLD_PID=
wait "$VAC_PID" 2>/dev/null || true; VAC_PID=
"$BIN" collect -config "$CFG" -once vacuum >/dev/null || fail "collect vacuum (3)"
[[ $(q "select count(*) from pgvigil.vacuum_running where instance_id=$iid and pid=$V") == 0 ]] || fail "the finished VACUUM still shows as running"
[[ $(q "select kind || '|' || table_name || '|' || samples || '|' || waited_lock from pgvigil.vacuum_runs where instance_id=$iid and pid=$V") == "vacuum|public.t_over|2|true" ]] \
  || fail "run: $(q "select row(r.*) from pgvigil.vacuum_runs r where instance_id=$iid")"
[[ $(q "select count(*) from pgvigil.vacuum_history($iid, now() - interval '1 hour', now()) where source = 'sample' and table_name = 'public.t_over'") == 1 ]] \
  || fail "history: $(q "select row(h.*) from pgvigil.vacuum_history($iid, now() - interval '1 hour', now()) h")"
echo "B: OK (one run, two samples, waited on a lock)"

echo "--- C. checks on seeded imports"
SID=$(q "select pgvigil.ensure_instance('vacuum-checks-$SUF', 'onprem', 'proof', 160004, false, '{proof}')")
imp() { q "select pgvigil.import_$1($SID, '$2'::timestamptz, \$j\$$3\$j\$::jsonb)" >/dev/null; }
T=$(q "select date_trunc('minute', now())")
SUM='{"kind":"summary","autovacuum":"off","track_counts":"on","max_workers":3,"workers_running":2}'
RUN1='{"kind":"vacuum","pid":101,"dbid":1,"datname":"db","relid":11,"table_name":"s.big","is_auto":true,"is_wraparound":false,"phase":"scanning heap","heap_blks_total":1000,"heap_blks_scanned":400,"query_start":"2026-11-09T10:00:00Z","elapsed_secs":4000}'
RUN2='{"kind":"analyze","pid":102,"dbid":1,"datname":"db","relid":12,"table_name":"s.wrapped","is_auto":true,"is_wraparound":true,"query_start":"2026-11-09T11:00:00Z","elapsed_secs":120,"wait_event_type":"Lock","wait_event":"relation","blocking_pids":[555]}'
imp vacuum "$T" "[$SUM,$RUN1,$RUN2]"
SET='{"kind":"settings","autovacuum":"off","track_counts":"on","max_workers":3,"freeze_max_age":200000000,"mxid_freeze_max_age":400000000,"failsafe_age":1600000000}'
WRAP='{"kind":"wrap","dbid":1,"datname":"db","allow_conn":true,"xid_age":50000000,"mxid_age":10},{"kind":"wrap","dbid":2,"datname":"warm","allow_conn":true,"xid_age":150000000,"mxid_age":10},{"kind":"wrap","dbid":3,"datname":"hot","allow_conn":true,"xid_age":1200000000,"mxid_age":10}'
DBR='{"kind":"db","dbid":1,"datname":"db","user_tables":2,"over_vacuum":1}'
tbl() { printf '{"kind":"table","dbid":1,"relid":%s,"datname":"db","schema_name":"s","table_name":"%s","n_live_tup":1000,"n_dead_tup":%s,"vac_threshold":250,"anl_threshold":150,"n_mod_since_analyze":0,"autovacuum_enabled":true,"over_vacuum":%s,"over_insert":false,"over_analyze":false,"xid_age":1000,"freeze_max_age":200000000}' "$1" "$2" "$3" "$4"; }
HOT=$(tbl 21 hot 900 true); COLD=$(tbl 22 cold 900 true); COLDOK=$(tbl 22 cold 10 false); HOTOK=$(tbl 21 hot 10 false)
at() { q "select ('$T'::timestamptz + interval '$1')"; }
imp vacuum_tables "$(at '-7 hours')" "[$SET,$WRAP,$DBR,$HOT,$COLDOK]"
imp vacuum_tables "$(at '-1 hour')" "[$SET,$WRAP,$DBR,$HOT,$COLDOK]"
imp vacuum_tables "$T" "[$SET,$WRAP,$DBR,$HOT,$COLD]"
GOT=$(q "select check_name || '|' || severity || '|' || object from pgvigil.vacuum_checks where instance_id=$SID" | sort)
WANT=$(printf '%s\n' 'autovacuum off|critical|autovacuum' 'vacuum running over an hour|warning|db.s.big' 'vacuum waiting on a lock|critical|db.s.wrapped' \
  'table over vacuum threshold|warning|db.s.hot' 'wraparound|warning|warm' 'wraparound|critical|hot' | sort)
[[ "$GOT" == "$WANT" ]] || { echo "got:"; echo "$GOT"; echo "want:"; echo "$WANT"; fail "vacuum_checks rows differ"; }
[[ $(q "select hours_over from pgvigil.vacuum_table_state where instance_id=$SID and table_name='hot'") == 7.0 ]] || fail "hours_over: $(q "select hours_over from pgvigil.vacuum_table_state where instance_id=$SID and table_name='hot'")"
imp vacuum_tables "$(at '18 hours')" "[$SET,$WRAP,$DBR,$HOT,$COLD]"
[[ $(q "select severity from pgvigil.vacuum_checks where instance_id=$SID and check_name='table over vacuum threshold' and object='db.s.hot'") == critical ]] || fail "25 h over is not critical"
imp vacuum_tables "$(at '19 hours')" "[$SET,$WRAP,$DBR,$HOTOK,$COLD]"
[[ $(q "select over_since is null from pgvigil.vacuum_tables where instance_id=$SID and table_name='hot'") == t ]] || fail "over_since kept after a read under the threshold"
[[ $(q "select count(*) from pgvigil.vacuum_checks where instance_id=$SID and check_name='table over vacuum threshold' and object='db.s.hot'") == 0 ]] || fail "the check stayed"
[[ $(q "select count(*) from pgvigil.vacuum_findings where instance_id=$SID") == $(q "select count(*) from pgvigil.vacuum_checks where instance_id=$SID") ]] || fail "findings count"
[[ $(q "select count(*) from pgvigil.vacuum_findings f where instance_id=$SID and setting not in (select check_name from pgvigil.vacuum_checks where instance_id=$SID)") == 0 ]] || fail "findings setting"
echo "C: OK ($(q "select count(*) from pgvigil.vacuum_checks where instance_id=$SID") checks on the scratch instance after the release read)"

echo "--- D. the log's autovacuum entries"
q "select pgvigil.ensure_month_partition('log_events', now())" >/dev/null
q "insert into pgvigil.log_events (instance_id, snapshot_at, kind, datname, duration_ms, statement, detail, source, event_key)
   values ($SID, now() - interval '5 minutes', 'autovacuum', 'db', 3500, 'db.s.hot', 'automatic vacuum of table \"db.s.hot\": index scans: 1', 'proof', 'k1')" >/dev/null
[[ $(q "select source || '|' || table_name || '|' || elapsed_secs from pgvigil.vacuum_history($SID, now() - interval '1 hour', now()) where source = 'log'") == "log|db.s.hot|4" ]] \
  || fail "log history: $(q "select row(h.*) from pgvigil.vacuum_history($SID, now() - interval '1 hour', now()) h")"
echo "D: OK"
echo "proof-vacuum: OK"
