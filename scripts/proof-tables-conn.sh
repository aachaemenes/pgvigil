#!/usr/bin/env bash
# Proof of task 127 (0080): the busiest tables over a window, the connection sources, the tile wall, and the new and
# dropped databases on both engines.
#
#   ADMIN_DSN   a superuser connection to the sandbox server (default: PGVIGIL_REPO_DSN). The proof makes its own
#               repository database and two target databases with a random suffix and drops them at the end; its own
#               psql sessions carry application names with the suffix, so the sandbox's other sessions never count.
#   Needs: psql, curl, python3, ss; a pgvigil binary whose serve wires /api/tables/top, /api/connections, /api/tiles and
#   /api/dbchanges (the lead's join applies the wiring; part E fails on a tree without it).
#
# Expected (written before the first run):
#  A. table_activity: read 1, then in tgt1 a_scan seq-scanned 7 times, b_ins +500 rows, c_upd 300 rows updated,
#     d_del 200 rows deleted, e_quiet untouched, and in tgt2 t2_ins +50 rows; read 2; then c_upd's counters reset
#     (pg_stat_reset_single_table_counters) and 40 more rows updated; read 3.
#     table_activity_top(read 1 .. read 3, n 5): every one of the five moved tables' seq_scan, n_tup_ins, n_tup_upd and
#     n_tup_del equals the hand delta of pg_stat_user_tables (read by psql right before read 1, after read 2, and after
#     read 3, the reset step adding its new value); c_upd shows n_tup_upd 340 and resets 1; rank_seq 1 = a_scan,
#     rank_ins 1 = b_ins, rank_upd 1 = c_upd, rank_del 1 = d_del; t2_ins comes from tgt2's own dbid; e_quiet absent.
#     [run 1 graded: the ranks are instance-wide and the sandbox's other databases are busier, so the top 5 held none
#      of the proof's tables; the expectation had assumed a quiet server. From run 2: the function with an unbounded
#      n, the proof's two databases only, the deltas as above, and each measure's leader among the proof's tables
#      carries the smallest rank]
#  B. connections, read twice with: 3 idle sessions (app pv_idle_<suf>), 1 idle in transaction holding a row lock
#     (pv_hold_<suf>), 1 waiting on that lock (pv_wait_<suf>), 1 running pg_sleep (pv_act_<suf>); then the idle three
#     closed and a third read. conn_sources_window(by all four) over the three reads: pv_idle avg_total 2.0, peak 3,
#     avg_idle 2.0, reads_seen 2 of 3; pv_hold peak_idle_in_txn 1; pv_wait peak_waiting_lock 1 and avg_active 1.0;
#     pv_act avg_active 1.0; each source's count at read 2 equals the hand count of pg_stat_activity taken right after
#     read 2. By application alone the pv_ rows carry NULL user, database and client and the same averages.
#  C. databases: read 1; database x_<suf> created with a 2 MB table; read 2; hand pg_database_size(x); dropped; read 3.
#     database_changes(1, the instance) lists x 'new' with created_after = read 1, first_seen = read 2, and 'dropped'
#     with last_seen = read 2, dropped_by = read 3 and size_bytes = the hand size; tgt1 and tgt2 (there before read 1)
#     are not 'new'. SQL Server, seeded on a sqlserver instance: ms_new (created 2 days ago) 'new' with its 150 MB;
#     ms_gone (absent since 1 day ago, last storage read 100 + 20 MB) 'dropped' with 125,829,120 bytes and dropped_by
#     = the next storage read that does not list it; ms_old (created 400 days ago) absent; database_changes(30) lists
#     both instances' rows, newest first.
#  D. the tile wall: (1) live: the activity collect during B; instance_tiles' idle_in_txn, waiting_lock, total and
#     max_connections equal a hand read of pg_stat_activity / max_connections taken right after it (either side of
#     the collect, the sandbox has other sessions) [run 3 graded: total was the hand count + 1, the collect's own
#     repository connection on the same server, open during the read; expected from run 4: total - 1]; fsync, full_page_writes, synchronous_commit, data_checksums and
#     wal_level equal current_setting() of each. (2) seeded on a scratch instance: activity_summary total 80 of 100,
#     idle_in_txn 2 + 1 aborted, waiting_lock 4, longest_active_secs 700, oldest_xmin_age 2,000,000; dbstats two
#     databases, blks_hit rising 900 and 8,100, blks_read 100 and 900 inside the window, and a third row outside it ->
#     conn_used_pct 80.0, idle_in_txn 3, hit_pct 90.00; non_default_settings fsync off -> fsync 'off',
#     full_page_writes 'on' (default).
#  E. the API (serve -no-login): /api/tables/top the same rows as A's function; /api/connections?by=application the
#     same rows as B's by-application call; /api/tiles one row equal to D(2); /api/dbchanges?days=30 equal to C's
#     fleet call; by=nonsense, n=0 and days=0 answer 400.
#  F. purge(30) runs (the new series are its candidates once the lead names them).
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
ADMIN_DSN=${ADMIN_DSN:-$PGVIGIL_REPO_DSN}
SUF=$RANDOM
REPO_DB=pgvigil_tcproof_$SUF; T1=pgvigil_tc1_$SUF; T2=pgvigil_tc2_$SUF; XDB=pgvigil_tcx_$SUF
dsn_for() { echo "$ADMIN_DSN dbname=$1"; }
TMPD=$(mktemp -d); BG=; SRVPID=
cleanup() {
  # shellcheck disable=SC2086
  [[ -n "$BG" ]] && kill $BG 2>/dev/null || true
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  rm -rf "$TMPD"
  for d in "$REPO_DB" "$T1" "$T2" "$XDB"; do psql "$ADMIN_DSN" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }
for d in "$REPO_DB" "$T1" "$T2"; do psql "$ADMIN_DSN" -XAtq -c "create database $d" >/dev/null; done
export PGVIGIL_REPO_DSN; PGVIGIL_REPO_DSN=$(dsn_for "$REPO_DB")
export TGT_DSN; TGT_DSN=$(dsn_for "$T1")
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
t1() { psql "$TGT_DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
t2() { psql "$(dsn_for "$T2")" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
# the cumulative statistics: each psql above is its own backend and flushes its counts as it exits; the wait covers
# the flush reaching the shared statistics on every version (13's statistics collector sends them by UDP)
flush() { sleep 1.2; }

cat > "$TMPD/cfg.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-tc-$SUF
    dsn: env:TGT_DSN
EOF
CFG=$TMPD/cfg.yaml
"$BIN" migrate -config "$CFG" >/dev/null
collect() { "$BIN" collect -config "$CFG" -once "$1" >/dev/null || fail "collect $1"; }

echo "--- A. the busiest tables"
t1 "create table a_scan (id int, pad text); insert into a_scan select g, 'a' from generate_series(1, 1000) g;
    create table b_ins (id int); create table c_upd (id int, n int); insert into c_upd select g, 0 from generate_series(1, 1000) g;
    create table d_del (id int); insert into d_del select generate_series(1, 1000);
    create table e_quiet (id int); insert into e_quiet values (1);"
t2 "create table t2_ins (id int)"
flush
hand() {  # schema.table|seq_scan|n_tup_ins|n_tup_upd|n_tup_del, both databases
  { psql "$TGT_DSN" -XAt -c "select relname, seq_scan, n_tup_ins, n_tup_upd, n_tup_del from pg_stat_user_tables order by relname"
    psql "$(dsn_for "$T2")" -XAt -c "select relname, seq_scan, n_tup_ins, n_tup_upd, n_tup_del from pg_stat_user_tables order by relname"; }
}
H0=$(hand); collect table_activity
R1=$(q "select max(snapshot_at) from pgvigil.table_activity"); iid=$(q "select instance_id from pgvigil.instances where name='proof-tc-$SUF'")
for _ in 1 2 3 4 5 6 7; do t1 "select count(*) from a_scan" >/dev/null; done
t1 "insert into b_ins select generate_series(1, 500)"
t1 "update c_upd set n = n + 1 where id <= 300"
t1 "delete from d_del where id <= 200"
t2 "insert into t2_ins select generate_series(1, 50)"
flush
sleep 1.1; collect table_activity; H2=$(hand)
t1 "select pg_stat_reset_single_table_counters('c_upd'::regclass)"
t1 "update c_upd set n = n + 1 where id <= 40"
flush
sleep 1.1; collect table_activity; H3=$(hand)
R3=$(q "select max(snapshot_at) from pgvigil.table_activity")
TOP=$(q "select table_name, seq_scan, n_tup_ins, n_tup_upd, n_tup_del, resets, coalesce(rank_seq,0), coalesce(rank_ins,0), coalesce(rank_upd,0), coalesce(rank_del,0), datname
           from pgvigil.table_activity_top($iid, '$R1', '$R3', 1000000) where datname in ('$T1', '$T2') order by table_name")
echo "$TOP" > "$TMPD/top.txt"
python3 - "$TMPD/top.txt" "$T2" <<PY || fail "A: the top tables against the hand deltas"
import sys
def parse(s):
    out = {}
    for l in s.strip().splitlines():
        n, a, b, c, d = l.split('|'); out[n] = [int(a or 0), int(b), int(c), int(d)]
    return out
h0, h2, h3 = parse("""$H0"""), parse("""$H2"""), parse("""$H3""")
top = {l.split('|')[0]: l.split('|') for l in open(sys.argv[1]).read().strip().splitlines()}
want = {}
for t in ('a_scan', 'b_ins', 'c_upd', 'd_del', 't2_ins'):
    first = [h2[t][i] - h0[t][i] for i in range(4)]
    # the third step: c_upd's counters were reset, so the step counts their value after the reset
    second = [h3[t][i] - h2[t][i] if h3[t][i] >= h2[t][i] else h3[t][i] for i in range(4)]
    want[t] = [first[i] + second[i] for i in range(4)]
assert set(top) == set(want), ('tables', sorted(top), sorted(want))
for t, w in want.items():
    got = [int(x) for x in top[t][1:5]]
    assert got == w, (t, got, w)
assert want['c_upd'][2] == 340 and top['c_upd'][5] == '1', ('c_upd', want['c_upd'], top['c_upd'])
assert want['a_scan'][0] >= 7, top['a_scan']
# the ranks are instance-wide (the sandbox's other databases are busier): among the proof's own tables the leader of
# each measure has the smallest rank
lead = lambda col: min((int(r[col]), t) for t, r in top.items() if r[col] != '0')[1]
assert (lead(6), lead(7), lead(8), lead(9)) == ('a_scan', 'b_ins', 'c_upd', 'd_del'), top
assert top['t2_ins'][10] == sys.argv[2], top['t2_ins']
print('A ok', want)
PY
ok "A: five tables equal the hand deltas, c_upd 340 with one reset, ranks 1 a_scan / b_ins / c_upd / d_del, t2_ins from $T2, e_quiet absent"

echo "--- B. connection sources (and D(1)'s live activity read)"
t1 "create table lk (id int primary key); insert into lk values (1)"
for i in 1 2 3; do (echo "select 1;"; sleep 60) | PGAPPNAME=pv_idle_$SUF psql "$TGT_DSN" -XAtq >/dev/null 2>&1 & BG="$BG $!"; done
IDLE_PIDS=$BG
(echo "begin; update lk set id = 1 where id = 1;"; sleep 60) | PGAPPNAME=pv_hold_$SUF psql "$TGT_DSN" -XAtq >/dev/null 2>&1 & BG="$BG $!"
sleep 0.5
(echo "update lk set id = 1 where id = 1;"; sleep 60) | PGAPPNAME=pv_wait_$SUF psql "$TGT_DSN" -XAtq >/dev/null 2>&1 & BG="$BG $!"
PGAPPNAME=pv_act_$SUF psql "$TGT_DSN" -XAtq -c "select pg_sleep(60)" >/dev/null 2>&1 & BG="$BG $!"
appcount() { psql "$ADMIN_DSN" -XAt -c "select application_name, count(*), count(*) filter (where state = 'idle'), count(*) filter (where state like 'idle in transaction%'), count(*) filter (where wait_event_type = 'Lock'), count(*) filter (where state = 'active') from pg_stat_activity where application_name like 'pv\_%\_$SUF' group by 1 order by 1"; }
for _ in $(seq 1 50); do [[ $(appcount | wc -l) == 4 && $(appcount | grep -c "pv_wait_$SUF|1|0|0|1|1") == 1 ]] && break; sleep 0.1; done
[[ $(appcount | grep -c "pv_wait_$SUF|1|0|0|1|1") == 1 ]] || fail "B setup: $(appcount)"
collect connections; sleep 1.1
# D(1): the hand read on either side of the activity collect
handact() { psql "$ADMIN_DSN" -XAt -c "select count(*) filter (where state like 'idle in transaction%'), count(*) filter (where wait_event_type = 'Lock'), count(*), current_setting('max_connections') from pg_stat_activity where backend_type = 'client backend' and pid <> pg_backend_pid()"; }
D1A=$(handact); collect activity; D1B=$(handact); collect instance
collect connections; HB=$(appcount); sleep 1.1
# shellcheck disable=SC2086
kill $IDLE_PIDS 2>/dev/null || true
for _ in $(seq 1 50); do [[ $(appcount | grep -c "pv_idle_$SUF") == 0 ]] && break; sleep 0.1; done
collect connections
CS=$(q "select application_name, avg_total, peak_total, avg_idle, avg_idle_in_txn, peak_idle_in_txn, peak_waiting_lock, avg_active, reads_seen, reads, (usename is not null and datname is not null and client is not null)
          from pgvigil.conn_sources_window($iid, '-infinity', 'infinity', '{application,user,database,client}') where application_name like 'pv\_%\_$SUF' order by 1")
echo "$CS"
[[ $(grep "^pv_idle_$SUF|" <<<"$CS") == "pv_idle_$SUF|2.0|3|2.0|0.0|0|0|0.0|2|3|t" ]] || fail "B: pv_idle"
[[ $(grep "^pv_hold_$SUF|" <<<"$CS" | cut -d'|' -f6) == 1 ]] || fail "B: pv_hold idle in transaction"
[[ $(grep "^pv_wait_$SUF|" <<<"$CS" | cut -d'|' -f7,8) == "1|1.0" ]] || fail "B: pv_wait"
[[ $(grep "^pv_act_$SUF|" <<<"$CS" | cut -d'|' -f8) == "1.0" ]] || fail "B: pv_act"
R2C=$(q "select max(snapshot_at) from pgvigil.conn_sources where snapshot_at < (select max(snapshot_at) from pgvigil.conn_sources)")
NOW2=$(q "select application_name, total, idle, idle_in_txn, waiting_lock, active from pgvigil.conn_sources where instance_id = $iid and snapshot_at = '$R2C' and application_name like 'pv\_%\_$SUF' order by 1")
[[ "$NOW2" == "$HB" ]] || fail "B: read 2 against the hand count: $NOW2 / $HB"
CA=$(q "select application_name, avg_total, peak_total, coalesce(usename, '-') || coalesce(datname, '-') || coalesce(client, '-')
          from pgvigil.conn_sources_window($iid, '-infinity', 'infinity', '{application}') where application_name like 'pv\_%\_$SUF' order by 1")
[[ $(grep "^pv_idle_$SUF|" <<<"$CA") == "pv_idle_$SUF|2.0|3|---" ]] || fail "B: by application: $CA"
ok "B: idle 2.0 avg / 3 peak / 2 of 3 reads, the holder idle in transaction, the waiter on the lock, read 2 = the hand count, by application alone"

echo "--- D(1). the live tiles"
# the collect's own repository connection is on the same server (the proof's repository and targets share it) and
# open during the activity read: total is the hand count + 1
TL=$(q "select idle_in_txn, waiting_lock, total - 1, max_connections from pgvigil.instance_tiles($iid, now() - interval '1 hour', now())")
[[ "$TL" == "$D1A" || "$TL" == "$D1B" ]] || fail "D(1): tiles $TL (total less the collect's repository connection), hand $D1A / $D1B"
TS=$(q "select fsync, full_page_writes, synchronous_commit, data_checksums, wal_level from pgvigil.instance_tiles($iid, now() - interval '1 hour', now())")
HS=$(psql "$ADMIN_DSN" -XAt -c "select current_setting('fsync'), current_setting('full_page_writes'), current_setting('synchronous_commit'), current_setting('data_checksums'), current_setting('wal_level')")
[[ "$TS" == "$HS" ]] || fail "D(1): settings $TS against $HS"
# shellcheck disable=SC2086
kill $BG 2>/dev/null || true; BG=
ok "D(1): idle in transaction, blocked, connections and max_connections = the hand read ($TL); settings = current_setting ($TS)"

echo "--- C. new and dropped databases"
collect databases; RD1=$(q "select max(snapshot_at) from pgvigil.database_sizes where instance_id = $iid")
psql "$ADMIN_DSN" -XAtq -c "create database $XDB" >/dev/null
psql "$(dsn_for "$XDB")" -XAtq -c "create table big as select g, repeat('x', 200) pad from generate_series(1, 8000) g" >/dev/null
sleep 1.1; collect databases; RD2=$(q "select max(snapshot_at) from pgvigil.database_sizes where instance_id = $iid")
XS=$(psql "$ADMIN_DSN" -XAt -c "select pg_database_size('$XDB')")
psql "$ADMIN_DSN" -XAtq -c "drop database $XDB with (force)" >/dev/null
sleep 1.1; collect databases; RD3=$(q "select max(snapshot_at) from pgvigil.database_sizes where instance_id = $iid")
CH=$(q "select change, coalesce(created_after = '$RD1', false), first_seen = '$RD2', last_seen = '$RD2', coalesce(dropped_by = '$RD3', false), size_bytes from pgvigil.database_changes(1, $iid) where datname = '$XDB' order by change")
echo "$CH"
[[ "$CH" == $'dropped|f|t|t|t|'"$XS"$'\nnew|t|t|t|f|'"$XS" ]] || fail "C: $XDB new then dropped (hand size $XS)"
[[ $(q "select count(*) from pgvigil.database_changes(1, $iid) where datname in ('$T1', '$T2')") == 0 ]] || fail "C: a database there before the first read counted as new"
# SQL Server, seeded
sid=$(q "select pgvigil.ensure_instance('proof-tc-ms-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
q "select pgvigil.ensure_month_partition('mssql_database_size', now()); select pgvigil.ensure_month_partition('mssql_database_size', now() - interval '2 days')" >/dev/null
q "insert into pgvigil.mssql_backup_state (instance_id, database_name, snapshot_at, is_present, created_at) values
     ($sid, 'ms_new', now(), true, now() - interval '2 days'),
     ($sid, 'ms_gone', now() - interval '1 day', false, now() - interval '100 days'),
     ($sid, 'ms_old', now(), true, now() - interval '400 days');
   insert into pgvigil.mssql_database_size (instance_id, snapshot_at, database_name, data_bytes, log_bytes) values
     ($sid, now() - interval '1 day 10 minutes', 'ms_gone', 100 * 1048576, 20 * 1048576),
     ($sid, now() - interval '1 day 10 minutes', 'ms_old', 1048576, 1048576),
     ($sid, now() - interval '20 hours', 'ms_old', 1048576, 1048576),
     ($sid, now() - interval '5 minutes', 'ms_new', 140 * 1048576, 10 * 1048576),
     ($sid, now() - interval '5 minutes', 'ms_old', 1048576, 1048576);" >/dev/null
MS=$(q "select change, datname, size_bytes, coalesce(dropped_by::text, '-') from pgvigil.database_changes(30, $sid) order by datname")
echo "$MS"
[[ $(grep -c . <<<"$MS") == 2 ]] || fail "C: SQL Server rows"
[[ $(grep "|ms_new|" <<<"$MS" | cut -d'|' -f1,3) == "new|157286400" ]] || fail "C: ms_new"
[[ $(grep "|ms_gone|" <<<"$MS" | cut -d'|' -f1,3) == "dropped|125829120" ]] || fail "C: ms_gone"
[[ $(q "select dropped_by = (select min(snapshot_at) from pgvigil.mssql_database_size where instance_id = $sid and snapshot_at > now() - interval '1 day') from pgvigil.database_changes(30, $sid) where datname = 'ms_gone'") == t ]] || fail "C: ms_gone dropped_by"
FL=$(q "select string_agg(instance || '/' || datname || '/' || change, ',' order by at desc) from pgvigil.database_changes(30) where instance in ('proof-tc-$SUF', 'proof-tc-ms-$SUF')")
[[ $(q "select bool_and(a >= b) from (select at a, lead(at) over (order by at desc) b from pgvigil.database_changes(30)) x where b is not null") == t ]] || fail "C: fleet order"
ok "C: $XDB new (between read 1 and 2) then dropped (last size $XS, by read 3); ms_new 150 MB new, ms_gone dropped at 120 MB, ms_old absent; fleet: $FL"

echo "--- D(2). the seeded tile wall"
did=$(q "select pgvigil.ensure_instance('proof-tc-seed-$SUF', 'onprem', '16.0', 160000, false, '{}')")
q "select pgvigil.ensure_month_partition('dbstats', now()); select pgvigil.ensure_month_partition('dbstats', now() - interval '3 hours')" >/dev/null
q "insert into pgvigil.activity_summary (instance_id, snapshot_at, total, active, idle, idle_in_txn, idle_in_txn_aborted, waiting_lock, active_client_wait, longest_active_secs, longest_idle_txn_secs, oldest_xmin_age, max_connections)
     values ($did, now() - interval '30 minutes', 10, 1, 9, 0, 0, 0, 0, 1, 0, 5, 100),
            ($did, now() - interval '2 minutes', 80, 20, 50, 2, 1, 4, 0, 700, 90, 2000000, 100);
   insert into pgvigil.dbstats (instance_id, snapshot_at, dbid, datname, stats_reset, blks_hit, blks_read, epoch) values
     ($did, now() - interval '3 hours', 1, 'a', null, 0, 0, 1),
     ($did, now() - interval '50 minutes', 1, 'a', null, 1000, 100, 1), ($did, now() - interval '1 minute', 1, 'a', null, 1900, 200, 1),
     ($did, now() - interval '50 minutes', 2, 'b', null, 100, 100, 1), ($did, now() - interval '1 minute', 2, 'b', null, 8200, 1000, 1);
   insert into pgvigil.instance_state (instance_id, snapshot_at, data_checksums, wal_level, non_default_settings)
     values ($did, now(), 'on', 'replica', '[{\"name\": \"fsync\", \"value\": \"off\"}]');" >/dev/null
D2=$(q "select total, max_connections, conn_used_pct, idle_in_txn, waiting_lock, longest_active_secs, oldest_xmin_age, hit_pct, fsync, full_page_writes, synchronous_commit from pgvigil.instance_tiles($did, now() - interval '1 hour', now())")
[[ "$D2" == "80|100|80.0|3|4|700|2000000|90.00|off|on|on" ]] || fail "D(2): $D2"
ok "D(2): $D2"

echo "--- E. the API"
PORT=$((20000 + RANDOM % 20000)); while ss -ltnH "sport = :$PORT" | grep -q .; do PORT=$((20000 + RANDOM % 20000)); done
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$TMPD/serve.yaml"
"$BIN" serve -config "$TMPD/serve.yaml" -listen "127.0.0.1:$PORT" -no-login > "$TMPD/serve.out" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || fail "E: serve exited: $(cat "$TMPD/serve.out")"
U="http://127.0.0.1:$PORT/api"
enc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }
F=$(enc "$(q "select to_char('$R1'::timestamptz at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')")")
T=$(enc "$(q "select to_char(now() at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")")
FA=$(enc "$(q "select to_char((now() - interval '1 hour') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")")
curl -fs "$U/tables/top?instance=$iid&from=$F&to=$T&n=5" > "$TMPD/top.json" || fail "E: /api/tables/top"
curl -fs "$U/connections?instance=$iid&from=$FA&to=$T&by=application" > "$TMPD/conn.json" || fail "E: /api/connections"
curl -fs "$U/tiles?instance=$did&from=$FA&to=$T" > "$TMPD/tiles.json" || fail "E: /api/tiles"
curl -fs "$U/dbchanges?days=30" > "$TMPD/chg.json" || fail "E: /api/dbchanges"
EXP_TOP=$(q "select string_agg(table_name || ':' || n_tup_ins, ',' order by table_name) from pgvigil.table_activity_top($iid, '$R1', now(), 5)")
EXP_CONN=$(q "select string_agg(application_name || ':' || avg_total, ',' order by application_name) from pgvigil.conn_sources_window($iid, now() - interval '1 hour', now(), '{application}') where application_name like 'pv\_%\_$SUF'")
EXP_CHG=$(q "select count(*) from pgvigil.database_changes(30)")
python3 - "$TMPD" "$EXP_TOP" "$EXP_CONN" "$EXP_CHG" "$SUF" <<'PY' || fail "E: the API against the functions"
import json, sys
d, top, conn, chg, suf = sys.argv[1:6]
def rows(t):
    return [dict(zip(t['columns'], r)) for r in (t or {}).get('rows') or []]
a = json.load(open(d + '/top.json'))
got = ','.join(sorted(f"{r['table_name']}:{r['n_tup_ins']}" for r in rows(a['tables'])))
assert got == ','.join(sorted(top.split(','))), (got, top)   # sorted on both sides: the server's collation is not Python's
assert rows(a['meta'])[0]['n'] == 5, a['meta']
c = json.load(open(d + '/conn.json'))
rs = [r for r in rows(c['sources']) if (r['application_name'] or '').startswith('pv_') and r['application_name'].endswith('_' + suf)]
got = ','.join(sorted(f"{r['application_name']}:{float(r['avg_total']):.1f}" for r in rs))
assert got == ','.join(sorted(conn.split(','))), (got, conn)
assert all(r['usename'] is None and r['datname'] is None and r['client'] is None for r in rs), rs
t = rows(json.load(open(d + '/tiles.json'))['tiles'])
assert len(t) == 1 and float(t[0]['hit_pct']) == 90.0 and t[0]['idle_in_txn'] == 3 and t[0]['fsync'] == 'off', t
g = json.load(open(d + '/chg.json'))
assert len(rows(g['changes'])) == int(chg), (len(rows(g['changes'])), chg)
print('E ok')
PY
for bad in "connections?instance=$iid&by=nonsense" "tables/top?instance=$iid&n=0" "dbchanges?days=0"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$U/$bad"); [[ "$code" == 400 ]] || fail "E: $bad answered $code"
done
ok "E: the four routes equal their functions; three bad parameters answer 400"

echo "--- F. purge"
q "select pgvigil.purge(30)" >/dev/null || fail "F: purge"
ok "F: purge(30) ran"
echo "PASS proof-tables-conn"
