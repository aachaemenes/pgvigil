#!/usr/bin/env bash
# Proof of the tables collection and the other 0016 additions (findings, DMS drain, statement windows).
#
#   ADMIN_DSN   a superuser connection to the sandbox server (default: PGVIGIL_REPO_DSN). The proof makes its own
#               repository database, two target databases and a pg_monitor-only login, all with a random suffix,
#               and drops them at the end; nothing that exists before the run is touched.
#
# Expected (written before the first run):
#  A. collect -once tables as the superuser, the target DSN on database tgt1 (tgt2 is a second database):
#     - tgt1 and tgt2 each get a table_databases row; tables rows come from both (two dbids)
#     - t_loaded (about 2,000 pages, autovacuum off, never vacuumed or analyzed): last_vacuum and last_analyze NULL,
#       stats_columns 0, bloat_pct NULL, autovacuum_off true; table_checks names it 'table autovacuum off',
#       'table never analyzed' and 'table never vacuumed'
#     - t_clean (VACUUM ANALYZE after the load): all-visible 100 %, stats_columns 3, bloat_pct under 20, no check
#     - t_bloated (analyzed, then 70 % of its rows deleted, autovacuum off): n_dead_tup >= 70,000, bloat_pct over 20;
#       checks 'table autovacuum off' and 'table dead rows' (its waste is under the 100 MB bloat floor)
#       [run 1 graded: also 'table never vacuumed' and 'table statistics stale' - both right (analyzed only, 70,000
#        rows changed against 30,000 live); the expectation had missed them, the four are expected from run 2 on]
#     - t_locked (ACCESS EXCLUSIVE held by another session through the run): absent; the collect still ends
#       inside 15 s (it never queues behind the lock) with no collection error
#       [review 1 fold, expected before the rerun: the collect runs twice, the first time with no lock; then an
#        ACCESS EXCLUSIVE on t_locked and a REINDEX INDEX holding the lock on t_idxlocked's INDEX only; the second
#        collect ends inside 15 s with no collection error, and t_locked and t_idxlocked keep their first-run rows
#        (is_present true, snapshot_at of run 1) while t_clean moves to run 2's snapshot. Fold run 1 graded: the
#        lock checks matched; it stopped at "table_sizes rows", which compared all history with the current rows -
#        right for one collect, not two; the check now compares run 2's history rows with run 2's reads]
#     - t_ff (fillfactor 50, VACUUM ANALYZE): bloat_pct under 20 (the estimate counts the fillfactor)
#     - t_newcol (analyzed, then a column added): stats_columns 2, bloat_pct NULL (no estimate on a partial width)
#     - t_other in tgt2 is read on the second connection, with its own dbid
#     - xid_age > 0 on every row; table_sizes holds one history row per tables row
#  B. collect again as a pg_monitor-only login: rows still come (sizes, dead rows), stats_readable false on
#     t_clean and its bloat_pct NULL (pg_stats is filtered by SELECT privilege)
#  C. import_tables seeded on a scratch instance: table_checks gives exactly
#       table bloat|warning|db.s.bloated, table never analyzed|warning|db.s.loaded, table never vacuumed|warning|db.s.loaded,
#       table statistics stale|warning|db.s.stale, table xid age|critical|db.s.oldest, table xid age|warning|db.s.old
#     (the small never-vacuumed table and the healthy big table raise nothing); a second import of db's 'db' row
#     without db.s.stale marks it is_present false and its check goes; a collector_error for db2 keeps db2's table
#  D. findings on seeded instance_state rows:
#       onprem 16, autovacuum off, work_mem 200000, seq_page_cost 2 and every other rule satisfied ->
#         autovacuum|critical, seq_page_cost|warning, work_mem|warning (exactly these three)
#       aurora 16 with no non-default setting -> default_toast_compression, idle_in_transaction_session_timeout, jit,
#         log_lock_waits, random_page_cost, track_io_timing (exactly these six, all info)
#       onprem 16 replica with max_standby_streaming_delay -1, max_standby_archive_delay 1000, synchronous_standby_names
#         '*' -> max_standby_archive_delay|warning, max_standby_streaming_delay|info, synchronous_standby_names|warning
#       onprem 16 with pg-collector's settings tripped (track_counts off, enable_indexscan off, synchronous_commit off,
#         log_statement mod, log_min_duration_statement 0, log_min_messages debug1, log_planner_stats on,
#         debug_print_plan on, autovacuum_freeze_max_age 400000000) and one database at xid age 350,000,000 ->
#         exactly those nine settings (track_counts critical, freeze info, the rest warning) plus
#         'database xid age|warning', all with source pg-collector
#       [review 1 fold: a second database at 1,200,000,000 adds 'database xid age|critical' (one row per database);
#        the replica also sets autovacuum_vacuum_cost_delay -1 and synchronous_commit remote_apply ->
#        autovacuum_vacuum_cost_delay|warning joins its three, synchronous_standby_names|warning still fires]
#  E. dms_drain on two seeded imports 15 minutes apart: target latency 1200 s -> 600 s gives speed_x 1.667 and
#     eta_secs 900; 10,000 rows behind at 150 out / 50 in per second gives eta_rows_secs 100; spilling true;
#     dms_checks adds 'DMS changes on disk' and 'DMS validation suspended' and the latency detail says
#     "caught up in about 15 min"
#  F. top_statements_by over seeded deltas: first row A by time, B by calls, C by io;
#     slow_in_window over seeded samples: one execution of at least 120 s (pid 101), the 2 s one (pid 102) dropped
#  G. purge(30) runs and returns a count.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
ADMIN_DSN=${ADMIN_DSN:-$PGVIGIL_REPO_DSN}
SUF=$RANDOM
REPO_DB=pgvigil_tblproof_$SUF; T1=pgvigil_tbl1_$SUF; T2=pgvigil_tbl2_$SUF; MON=pgvigil_tblmon_$SUF; MONPW=p$RANDOM$RANDOM
dsn_for() { echo "$ADMIN_DSN dbname=$1"; }   # a later keyword wins, in libpq and in pgx
CFG=$(mktemp); HOLD_PID=
cleanup() {
  # shellcheck disable=SC2086
  [[ -n "$HOLD_PID" ]] && kill $HOLD_PID 2>/dev/null || true
  rm -f "$CFG"
  for d in "$REPO_DB" "$T1" "$T2"; do psql "$ADMIN_DSN" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1 || true; done
  psql "$ADMIN_DSN" -XAtq -c "drop role if exists $MON" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for d in "$REPO_DB" "$T1" "$T2"; do psql "$ADMIN_DSN" -XAtq -c "create database $d" >/dev/null; done
psql "$ADMIN_DSN" -XAtq -c "create role $MON login password '$MONPW' in role pg_monitor" >/dev/null
export PGVIGIL_REPO_DSN; PGVIGIL_REPO_DSN=$(dsn_for "$REPO_DB")
export TGT_DSN; TGT_DSN=$(dsn_for "$T1")
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
t1() { psql "$TGT_DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }

echo "--- A. targets"
t1 "create table t_loaded (id bigint, pad text, n int) with (autovacuum_enabled = false, toast.autovacuum_enabled = false);
    insert into t_loaded select g, repeat('x', 100), g % 7 from generate_series(1, 120000) g;"
t1 "create table t_clean (id bigint, pad text, n int);
    insert into t_clean select g, repeat('y', 100), g % 7 from generate_series(1, 120000) g;"
t1 "vacuum analyze t_clean"
t1 "create table t_bloated (id bigint, pad text, n int) with (autovacuum_enabled = false, toast.autovacuum_enabled = false);
    insert into t_bloated select g, repeat('z', 100), g % 7 from generate_series(1, 100000) g;"
t1 "analyze t_bloated"
t1 "delete from t_bloated where id % 10 < 7"
t1 "create table t_locked (id bigint, pad text); insert into t_locked select g, repeat('l', 100) from generate_series(1, 300000) g;"
t1 "create table t_idxlocked (id bigint, pad text, n int); insert into t_idxlocked select g, repeat('i', 100), g % 7 from generate_series(1, 200000) g;
    create index t_idxlocked_n on t_idxlocked (n);"
t1 "create table t_ff (id bigint, pad text) with (fillfactor = 50); insert into t_ff select g, repeat('f', 100) from generate_series(1, 100000) g;"
t1 "vacuum analyze t_ff"
t1 "create table t_newcol (id bigint, pad text); insert into t_newcol select g, repeat('c', 100) from generate_series(1, 100000) g;"
t1 "analyze t_newcol"
t1 "alter table t_newcol add column extra int"
psql "$(dsn_for "$T2")" -XAtq -c "create table t_other (id int); insert into t_other select generate_series(1, 50000); analyze t_other"
sleep 1   # the cumulative statistics reach pg_stat_user_tables at the next flush

cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-tables-$SUF
    dsn: env:TGT_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
"$BIN" collect -config "$CFG" -once tables || fail "collect tables (run 1, no lock)"
iid=$(q "select instance_id from pgvigil.instances where name='proof-tables-$SUF'")
S1=$(q "select snapshot_at from pgvigil.tables where instance_id=$iid and table_name='t_locked'")
[[ -n "$S1" ]] || fail "run 1 did not read t_locked"
sleep 1.1

# the lock holders: ACCESS EXCLUSIVE on t_locked; REINDEX INDEX = ACCESS EXCLUSIVE on t_idxlocked's index only
psql "$TGT_DSN" -XAtq -c "begin; lock table t_locked in access exclusive mode; select pg_sleep(60);" >/dev/null 2>&1 &
HOLD_PID=$!
psql "$TGT_DSN" -XAtq -c "begin; reindex index t_idxlocked_n; select pg_sleep(60);" >/dev/null 2>&1 &
HOLD_PID="$HOLD_PID $!"
for _ in $(seq 1 50); do
  [[ $(t1 "select count(*) from pg_locks where relation in ('t_locked'::regclass, 't_idxlocked_n'::regclass) and mode = 'AccessExclusiveLock' and granted") == 2 ]] && break; sleep 0.1
done
start=$(date +%s)
"$BIN" collect -config "$CFG" -once tables || fail "collect tables (run 2, under the locks)"
took=$(( $(date +%s) - start ))
# shellcheck disable=SC2086
kill $HOLD_PID 2>/dev/null || true; HOLD_PID=
row() { q "select $1 from pgvigil.tables where instance_id=$iid and table_name='$2' and is_present"; }
[[ $took -le 15 ]] || fail "collect took ${took}s: it waited behind the lock"
# other databases on a shared sandbox may come and go during the run (a partial read of one of them is
# fine); the two proof databases must have been read (checked below)
[[ $(q "select status from pgvigil.collection_dates where instance_id=$iid and collection='tables'") != error ]] || fail "collection failed: $(q "select note from pgvigil.collection_dates where instance_id=$iid and collection='tables'")"
[[ $(q "select count(*) from pgvigil.table_databases where instance_id=$iid and datname in ('$T1','$T2')") == 2 ]] || fail "table_databases rows for tgt1 and tgt2"
[[ $(q "select count(distinct dbid) from pgvigil.tables where instance_id=$iid and table_name in ('t_loaded','t_other')") == 2 ]] || fail "rows from two databases"
for t in t_locked t_idxlocked; do
  [[ $(row "snapshot_at = '$S1'" $t) == t ]] || fail "$t was read under its lock or lost its row: $(q "select is_present, snapshot_at from pgvigil.tables where instance_id=$iid and table_name='$t'") (run 1 $S1)"
done
[[ $(row "snapshot_at > '$S1'" t_clean) == t ]] || fail "run 2 did not move t_clean"
[[ $(row "bloat_pct < 20" t_ff) == t ]] || fail "t_ff (fillfactor 50): $(row "bloat_pct, est_pages, heap_bytes" t_ff)"
[[ $(row "stats_columns = 2 and bloat_pct is null" t_newcol) == t ]] || fail "t_newcol: $(row "stats_columns, bloat_pct" t_newcol)"
[[ $(row "last_vacuum is null and last_analyze is null and stats_columns = 0 and bloat_pct is null" t_loaded) == t ]] || fail "t_loaded: $(row "last_vacuum, last_analyze, stats_columns, bloat_pct, heap_bytes" t_loaded)"
[[ $(row "round(100.0 * relallvisible / nullif(relpages, 0)) = 100 and stats_columns = 3 and bloat_pct < 20" t_clean) == t ]] || fail "t_clean: $(row "relpages, relallvisible, stats_columns, bloat_pct" t_clean)"
[[ $(row "n_dead_tup >= 70000 and bloat_pct > 20" t_bloated) == t ]] || fail "t_bloated: $(row "n_dead_tup, n_live_tup, bloat_pct, est_pages, heap_bytes" t_bloated)"
[[ $(q "select bool_and(xid_age > 0) from pgvigil.tables where instance_id=$iid") == t ]] || fail "xid_age"
# one history row per table read in a run (two runs now: compare run 2's)
S2=$(q "select max(snapshot_at) from pgvigil.tables where instance_id=$iid")
[[ $(q "select count(*) from pgvigil.table_sizes where instance_id=$iid and snapshot_at = '$S2'") == $(q "select count(*) from pgvigil.tables where instance_id=$iid and snapshot_at = '$S2'") ]] || fail "table_sizes rows"
CHK=$(q "select check_name from pgvigil.table_checks where instance_id=$iid and object='$T1.public.t_loaded' order by 1" | paste -sd,)
[[ "$CHK" == "table autovacuum off,table never analyzed,table never vacuumed" ]] || fail "t_loaded checks: $CHK"
CHK=$(q "select check_name from pgvigil.table_checks where instance_id=$iid and object='$T1.public.t_bloated' order by 1" | paste -sd,)
[[ "$CHK" == "table autovacuum off,table dead rows,table never vacuumed,table statistics stale" ]] || fail "t_bloated checks: $CHK"
[[ $(q "select count(*) from pgvigil.table_checks where instance_id=$iid and object='$T1.public.t_clean'") == 0 ]] || fail "t_clean raised a check"
echo "A: OK ($(q "select count(*) from pgvigil.tables where instance_id=$iid") tables over $(q "select count(*) from pgvigil.table_databases where instance_id=$iid") databases in ${took}s; t_bloated $(row bloat_pct t_bloated) % bloat; t_locked and t_idxlocked skipped and kept)"

echo "--- B. pg_monitor-only login"
export MON_DSN; MON_DSN="$ADMIN_DSN dbname=$T1 user=$MON password=$MONPW"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-tables-mon-$SUF
    dsn: env:MON_DSN
EOF
"$BIN" collect -config "$CFG" -once tables || fail "collect tables as pg_monitor"
mid=$(q "select instance_id from pgvigil.instances where name='proof-tables-mon-$SUF'")
[[ $(q "select stats_readable = false and bloat_pct is null and total_bytes > 0 from pgvigil.tables where instance_id=$mid and table_name='t_clean'") == t ]] \
  || fail "pg_monitor t_clean: $(q "select stats_readable, bloat_pct, total_bytes from pgvigil.tables where instance_id=$mid and table_name='t_clean'")"
[[ $(q "select n_dead_tup >= 70000 from pgvigil.tables where instance_id=$mid and table_name='t_bloated'") == t ]] || fail "pg_monitor t_bloated dead rows"
echo "B: OK (sizes and dead rows without SELECT; no bloat estimate)"

echo "--- C. table_checks on seeded rows"
SID=$(q "select pgvigil.ensure_instance('tables-checks-$SUF', 'onprem', 'proof', 160004, false, '{proof}')")
tb() { # name relid relpages last_vacuum last_analyze n_live n_mod bloat_pct bloat_bytes xid_age [dbid]
  local db=${11:-1} dn=db
  [[ $db == 1 ]] || dn=db2
  printf '{"kind":"table","dbid":%s,"relid":%s,"datname":"%s","schema_name":"s","table_name":"%s","relpages":%s,"heap_bytes":%s,"total_bytes":%s,"relallvisible":0,"last_vacuum":%s,"last_analyze":%s,"n_live_tup":%s,"n_dead_tup":0,"n_mod_since_analyze":%s,"bloat_pct":%s,"bloat_bytes":%s,"xid_age":%s,"mxid_age":5}' \
    "$db" "$2" "$dn" "$1" "$3" "$(( $3 * 8192 ))" "$(( $3 * 8192 ))" "$4" "$5" "$6" "$7" "$8" "$9" "${10}"; }
NOW='"2026-11-09T12:00:00Z"'
DB1='{"kind":"db","dbid":1,"datname":"db","stats_reset":null,"user_tables":7}'
DB2='{"kind":"db","dbid":2,"datname":"db2","user_tables":1}'
LOADED=$(tb loaded 101 2000 null null 100000 0 null null 1000)
SMALL=$(tb small 102 10 null null 100 0 null null 1000)
HEALTHY=$(tb healthy 103 5000 "$NOW" "$NOW" 1000000 1000 5 1000000 1000)
STALE=$(tb stale 104 5000 "$NOW" "$NOW" 1000000 500000 5 1000000 1000)
BLOATED=$(tb bloated 105 50000 "$NOW" "$NOW" 1000000 0 45 209715200 1000)
OLD=$(tb old 106 5000 "$NOW" "$NOW" 1000000 0 5 1000000 1100000000)
OLDEST=$(tb oldest 107 5000 "$NOW" "$NOW" 1000000 0 5 1000000 1600000000)
OTHER=$(tb other 201 5000 "$NOW" "$NOW" 1000000 0 5 1000000 1000 2)
P="[$DB1,$DB2,$LOADED,$SMALL,$HEALTHY,$STALE,$BLOATED,$OLD,$OLDEST,$OTHER]"
q "select pgvigil.import_tables($SID, now(), \$j\$$P\$j\$::jsonb)" >/dev/null
GOT=$(q "select check_name || '|' || severity || '|' || object from pgvigil.table_checks where instance_id=$SID" | sort)
WANT=$(printf '%s\n' 'table bloat|warning|db.s.bloated' 'table never analyzed|warning|db.s.loaded' 'table never vacuumed|warning|db.s.loaded' \
  'table statistics stale|warning|db.s.stale' 'table xid age|critical|db.s.oldest' 'table xid age|warning|db.s.old' | sort)
[[ "$GOT" == "$WANT" ]] || { echo "got:"; echo "$GOT"; echo "want:"; echo "$WANT"; fail "table_checks rows differ"; }
# second run: db read again without 'stale'; db2 failed this run (its table must stay present)
P2="[$DB1,$LOADED,$SMALL,$HEALTHY,$BLOATED,$OLD,$OLDEST,{\"kind\":\"collector_error\",\"source\":\"tables:db2\",\"message\":\"connect: refused\"}]"
q "select pgvigil.import_tables($SID, now(), \$j\$$P2\$j\$::jsonb)" >/dev/null
[[ $(q "select is_present from pgvigil.tables where instance_id=$SID and table_name='stale'") == f ]] || fail "stale table still present"
[[ $(q "select count(*) from pgvigil.table_checks where instance_id=$SID and check_name='table statistics stale'") == 0 ]] || fail "stale check survived"
[[ $(q "select is_present from pgvigil.tables where instance_id=$SID and table_name='other'") == t ]] || fail "db2's table lost on a failed read"
[[ $(q "select is_present from pgvigil.table_databases where instance_id=$SID and dbid=2") == t ]] || fail "db2 marked gone on a failed read"
echo "C: OK (6 findings; absence judged only inside a database read this run)"

echo "--- D. findings"
inst() { # name platform replica settings-json
  local id; id=$(q "select pgvigil.ensure_instance('$1-$SUF', '$2', 'proof', 160004, $3, '{proof}')")
  q "select pgvigil.import_instance($id, now(), \$j\$[{\"platform\":\"$2\",\"server_version_num\":160004,\"is_replica\":$3,\"max_connections\":100,\"non_default_settings\":$4}]\$j\$::jsonb)" >/dev/null
  echo "$id"; }
s() { printf '{"name":"%s","value":"%s"}' "$1" "$2"; }
GOOD="$(s checkpoint_timeout 1800),$(s max_wal_size 16384),$(s min_wal_size 4096),$(s huge_pages on),$(s track_io_timing on),$(s log_lock_waits on),$(s idle_in_transaction_session_timeout 300000),$(s default_toast_compression lz4),$(s wal_compression lz4),$(s jit off)"
F1=$(inst find-onprem onprem false "[$(s autovacuum off),$(s work_mem 200000),$(s seq_page_cost 2),$GOOD]")
F2=$(inst find-aurora aurora false "[]")
F3=$(inst find-replica onprem true "[$(s max_standby_streaming_delay -1),$(s max_standby_archive_delay 1000),$(s synchronous_standby_names '*'),$(s synchronous_commit remote_apply),$(s autovacuum_vacuum_cost_delay -1),$GOOD]")
fs() { q "select setting || '|' || severity from pgvigil.findings where instance_id=$1 order by 1" | paste -sd' '; }
[[ $(fs "$F1") == "autovacuum|critical seq_page_cost|warning work_mem|warning" ]] || fail "onprem findings: $(fs "$F1")"
[[ $(fs "$F2") == "default_toast_compression|info idle_in_transaction_session_timeout|info jit|info log_lock_waits|info random_page_cost|info track_io_timing|info" ]] || fail "aurora findings: $(fs "$F2")"
[[ $(fs "$F3") == "autovacuum_vacuum_cost_delay|warning max_standby_archive_delay|warning max_standby_streaming_delay|info synchronous_standby_names|warning" ]] || fail "replica findings: $(fs "$F3")"
F4=$(inst find-collector onprem false "[$(s track_counts off),$(s enable_indexscan off),$(s synchronous_commit off),$(s log_statement mod),$(s log_min_duration_statement 0),$(s log_min_messages debug1),$(s log_planner_stats on),$(s debug_print_plan on),$(s autovacuum_freeze_max_age 400000000),$GOOD]")
q "select pgvigil.import_databases($F4, now(), \$j\$[{\"dbid\":5,\"datname\":\"app\",\"is_template\":false,\"xid_age\":350000000},{\"dbid\":6,\"datname\":\"young\",\"is_template\":false,\"xid_age\":1000},{\"dbid\":7,\"datname\":\"old\",\"is_template\":false,\"xid_age\":1200000000}]\$j\$::jsonb)" >/dev/null
WANT4="amcheck never run|info autovacuum_freeze_max_age|info database xid age|critical database xid age|warning debug_print_plan|warning enable_indexscan|warning log_min_duration_statement|warning log_min_messages|warning log_planner_stats|warning log_statement|warning synchronous_commit|warning track_counts|critical"
[[ $(fs "$F4") == "$WANT4" ]] || fail "pg-collector findings: $(fs "$F4")"
[[ $(q "select count(*) from pgvigil.findings where instance_id=$F4 and source <> 'pg-collector' and not (source = 'pg-backups' and setting = 'amcheck never run')") == 0 ]] || fail "pg-collector findings carry another source"
echo "D: OK (3 / 6 / 4 pg_gather findings, 11 pg-collector findings and pg-backups' amcheck never run)"

echo "--- E. DMS drain"
DID=$(q "select pgvigil.ensure_instance('dms-drain-$SUF', 'aurora', 'proof', 160004, false, '{proof}')")
ARN=arn:aws:dms:us-east-2:123456789012:task:DRAIN
task() { printf '[{"kind":"task","task_arn":"%s","task_id":"t-drain","migration_type":"cdc","status":"running","latency_source_s":%s,"latency_target_s":%s,"latency_at":"%s","latency_warn_secs":300,"incoming_changes":10000,"rows_in_s":50,"rows_out_s":150,"disk_source":0,"disk_target":500},{"kind":"table","task_arn":"%s","schema_name":"s","table_name":"x","validation_state":"Suspended records"},{"kind":"table","task_arn":"%s","schema_name":"s","table_name":"y","validation_state":"Validated"}]' "$ARN" "$1" "$1" "$2" "$ARN" "$ARN"; }
TB=$(date -u +%Y-%m-%dT%H:%M:00Z); TA=$(date -u -d "$TB - 15 min" +%Y-%m-%dT%H:%M:00Z)
q "select pgvigil.import_dms($DID, '$TA', \$j\$$(task 1200 "$TA")\$j\$::jsonb)" >/dev/null
q "select pgvigil.import_dms($DID, '$TB', \$j\$$(task 600 "$TB")\$j\$::jsonb)" >/dev/null
D=$(q "select speed_x || '|' || eta_secs || '|' || eta_rows_secs || '|' || spilling || '|' || suspended || '|' || validated from pgvigil.dms_drain where instance_id=$DID")
[[ "$D" == "1.667|900|100|true|1|1" ]] || fail "dms_drain: $D (want 1.667|900|100|true|1|1)"
CK=$(q "select check_name from pgvigil.dms_checks where instance_id=$DID order by 1" | paste -sd,)
[[ "$CK" == "DMS CDC latency,DMS changes on disk,DMS validation suspended" ]] || fail "dms checks: $CK"
q "select detail from pgvigil.dms_checks where instance_id=$DID and check_name='DMS CDC latency'" | grep -q "caught up in about 15 min" || fail "latency detail: $(q "select detail from pgvigil.dms_checks where instance_id=$DID and check_name='DMS CDC latency'")"
echo "E: OK (speed 1.667x, caught up in 900 s by latency, 100 s by rows; spill and suspended-validation checks)"

echo "--- F. statement windows"
SQ=$(q "select pgvigil.ensure_instance('stmts-$SUF', 'onprem', 'proof', 160004, false, '{proof}')")
q "select pgvigil.ensure_month_partition('statements_delta', now()); select pgvigil.ensure_month_partition('activity_sample', now());" >/dev/null
q "insert into pgvigil.statements_delta (instance_id, snapshot_at, interval_secs, dbid, userid, queryid, toplevel, calls, total_exec_ms, rows, shared_blks_read, shared_blks_hit, temp_blks_read, temp_blks_written, wal_bytes)
   values ($SQ, now() - interval '30 min', 60, 1, 1, 11, true, 10, 90000, 10, 100, 1000, 0, 0, 0),
          ($SQ, now() - interval '30 min', 60, 1, 1, 22, true, 100000, 5000, 100000, 0, 500000, 0, 0, 0),
          ($SQ, now() - interval '30 min', 60, 1, 1, 33, true, 50, 20000, 50, 400000, 10, 1000, 2000, 0)" >/dev/null
first() { q "select queryid from pgvigil.top_statements_by($SQ, now() - interval '1 hour', now(), '$1', 1)"; }
[[ "$(first time) $(first calls) $(first io)" == "11 22 33" ]] || fail "top_statements_by: time $(first time), calls $(first calls), io $(first io)"
q "insert into pgvigil.activity_sample (instance_id, snapshot_at, pid, backend_start, state, query_start, xact_start, blocking_pids, backend_type)
   select $SQ, b + o, 101, b - interval '1 hour', 'active', b - interval '10 min', b - interval '10 min', '{}'::int[], 'client backend'
     from (select date_trunc('minute', now()) - interval '40 min' b) x, (values (interval '-9 min'), (interval '-8 min')) v(o)
   union all
   select $SQ, date_trunc('minute', now()) - interval '40 min', 102, now() - interval '2 hours', 'active',
          date_trunc('minute', now()) - interval '40 min' - interval '2 s', null::timestamptz, '{}'::int[], 'client backend'" >/dev/null
SW=$(q "select pid || '|' || at_least_secs || '|' || samples from pgvigil.slow_in_window($SQ, now() - interval '1 hour', now(), 5)" | paste -sd' ')
[[ "$SW" == "101|120|2" ]] || fail "slow_in_window: $SW (want 101|120|2)"
echo "F: OK (time / calls / io orders; one execution of at least 120 s)"

echo "--- G. purge"
q "select pgvigil.purge(30)" >/dev/null || fail "purge"
echo "G: OK"
echo "proof-tables: OK"
