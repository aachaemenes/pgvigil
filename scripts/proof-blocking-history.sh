#!/usr/bin/env bash
# Proof of the blocking history and the drawn deadlocks (task 120: migration 0075, internal/web/q_blocking_history.go,
# web/src/blocking_history.ts, deadlock_graph.ts, mssql_deadlocks.ts, the head columns of mssql_running.ts).
#
# Needs: psql, curl, python3, a PostgreSQL sandbox, docker with a SQL Server container (PGVIGIL_MSSQL_CONTAINER,
# default mssql-sandbox) on PGVIGIL_MSSQL_ADDR (default localhost:1433), its sa password in MSSQL_SA_PASSWORD, and for
# part D chromium and node:
#   PGVIGIL_REPO_DSN   a superuser connection to the PostgreSQL sandbox in KEYWORD form (host=... user=...), no dbname
#   PGVIGIL_BIN        the binary (default bin/pgvigil), built from a tree whose Deadlocks tab renders mssql_deadlocks.ts
#                      (the lead's wiring) and whose bundle is current
# The proof makes, and drops on every exit path: its own repository database and its own scratch database on the
# PostgreSQL sandbox (one table), its own SQL Server database (three tables) and one SQL Server login (VIEW SERVER
# STATE, VIEW ANY DEFINITION; random suffix and password); its own pgvigil serve and Chromium, stopped by their pids.
# It changes no server setting and creates no event session: the deadlock is read from system_health (or from a
# pgvigil session a DBA already made). Every check is on this proof's own sessions: the sandboxes are shared.
#
# Expected (written before the first run):
#  A. a PostgreSQL chain held over three captures. A head session (application pgvbh_head_<n>, REPEATABLE READ)
#     updates row 1 and stays idle in its transaction; a first waiter updates row 1 (it waits on the head's
#     transactionid), a second waiter updates row 1 (it waits on the tuple lock the first holds); a bystander opens a
#     READ COMMITTED transaction, reads, and stays idle in it. Three `collect -once activity` runs two seconds apart:
#     blocking_history_chains has, for each of the three captures, one row headed by the head's pid with 2 victims,
#     1 direct, depth 2, the head's state 'idle in transaction', the same rows blocking_chains (0002) gives for that
#     capture (head, victims, depth); blocking_history_episodes has ONE row for the head's transaction: samples 3,
#     idle in transaction 3 of 3, last state idle in transaction, victims 2, direct 1, depth 2, its transaction older
#     at its last capture than at its first, longest blocked at least 2 s, and its last statement the head's UPDATE.
#     blocking_history_summary over the proof's window: captures 3, with blocking 3, 100.0 %, and captures with a
#     cycle equal to the captures where blocking_chains gives a headless row. blocking_history_trend: the steps sum to 3
#     captures, 3 with blocking, the most blocked at least 2. (The sandbox is shared: another workload's chain may be
#     in the same captures, so an instance-wide number is graded against an independent count of the samples, and
#     this proof's chain by its head's pid. First run, 2026-11-10: a standing chain of another database's workload
#     was in every capture; the expectation 'with a cycle 0' and B's '3 with blocking of 4' assumed a quiet server.)
#  B. the xmin horizon over the same three captures: the head (REPEATABLE READ, a snapshot held) is in xmin_pins with
#     3 captures with an xmin and its state at the peak 'idle in transaction'; the bystander (READ COMMITTED, idle
#     between statements) is NOT in xmin_pins, and xmin_pins_summary counts it among the idle-in-transaction sessions
#     that pinned nothing (at least 1). The head's 'held the oldest xmin' equals the captures where its xmin age is
#     the largest of its capture (counted from the samples directly). Per sample, in a rolled-back transaction: a
#     synthetic session seen active with an xmin and then idle in transaction without one counts as an idle session
#     that pinned nothing, one seen idle in transaction WITH an xmin does not (the counts move by 2 and 1).
#     After the head commits and one more capture: 4 captures, the fourth with no
#     chain headed by the head; the summary's captures with blocking equal the captures whose samples hold a Lock
#     waiter that names a blocker (counted from activity_sample directly), its share that count over 4; the episode
#     still has 3 samples.
#  C. SQL Server: a blocking chain held over two `collect -once mssql_requests` runs (a session holds a row lock in
#     an open transaction, a second waits on it), then a deadlock between two of the proof's own sessions, read by
#     `collect -once mssql_xe` (retried for up to 60 s while the event reaches the file): one row in mssql_deadlocks
#     for the proof's database, 2 processes, 1 victim, the graph XML whole. The API (/api/blocking/history, pgvigil
#     serve -no-login): for the SQL Server instance the parts meta, trend, deadlock_trend, pairs (since task 177 D04: at least one
#     blocked / blocking pair, the chain both snapshots saw); the trend's steps sum to 2
#     snapshots, 2 with a blocked session, the most blocked at least 1, a longest wait above 0; deadlock_trend's steps
#     sum to the repository's count of the instance's deadlocks in the window (at least 1); every step of the window
#     is a row (both parts hold floor((to - floor(from / step) * step) / step) + 1 rows). For the PostgreSQL instance the parts meta, summary, episodes, trend, xmin_summary, xmin_pins,
#     xmin_now, the episode of the head among them; part=nonsense is a 400; a window of 30 days says cut, from_at
#     seven days before to_at.
#  D. the pages, in a headless Chromium of the proof's own: the SQL Server Deadlocks tab opens the newest deadlock
#     (the proof's) and draws it from the XML ('Drawn from the deadlock XML SQL Server wrote.'): one svg.deadlock-graph
#     with 2 session boxes, exactly one of them the victim (class dl-victim, its text 'VICTIM' and 'Session <the
#     victim's spid>'), 2 resource boxes naming the proof's two tables, 2 edge labels 'holds <mode>' and 2 'waits for
#     <mode>', each session box with the first line of its statement ('BEGIN TRAN; UPDATE dbo.dl_'), and a Save XML
#     link whose file starts with <deadlock>. The PostgreSQL Running queries tab shows the Blocking history with
#     the tiles 4 captures and B's count with blocking, and a chain row of the head's pid; its xmin section lists the head.
#  E. a lock queue (review 2026-11-10: each waiter names the holder AND every waiter ahead of it, which made a path
#     walk grow as 2^n): a head holds ACCESS EXCLUSIVE on a table in an open transaction and 20 sessions queue for the
#     same lock; one more capture: one chain headed by the head with 20 victims, 20 direct, depth 1, 20 blocked in the
#     capture; blocking_chains names the same head for the same 20 waiters; blocking_history_chains over the proof's
#     window returns in under 2 s.
#  NOT PROVEN HERE: a chain under a minute (it falls between captures: the counts are floors, the page says so), a
#  head that is a background worker (autovacuum), a deadlock of more than two sessions or with a parallel exchange,
#  Azure SQL Database and Managed Instance, the page's look (looked at by hand against Darling 13.5 and 14.2 / 14.3).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${MSSQL_SA_PASSWORD:?the sa password of the SQL Server sandbox}"
CT=${PGVIGIL_MSSQL_CONTAINER:-mssql-sandbox}; ADDR=${PGVIGIL_MSSQL_ADDR:-localhost:1433}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_bh_$SUF; PGDB=pgvbh_$SUF; SDB=pgvbh_$SUF; L1=pgv_bh_$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
P1=$(pw)
TMPD=$(mktemp -d); CFG=$TMPD/cfg.yaml; OUT=$TMPD/out
fail() { echo "FAIL: $*" >&2; exit 1; }
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
MADE_REPO=; MADE_PGDB=; MADE_SDB=; MADE_L1=; SRVPID=; CHRPID=; PG_OPEN=; MS_OPEN=; Q_OPEN=
sq() { docker exec -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -U sa -C -I -b -W -h -1 -s '|' -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
cleanup() {
  rc=$?
  set +e
  [ -n "$CHRPID" ] && kill "$CHRPID" 2>/dev/null
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null
  [ -n "$PG_OPEN" ] && { { exec 5>&- 6>&-; } 2>/dev/null; }
  [ -n "$MS_OPEN" ] && { { exec 7>&-; } 2>/dev/null; }
  [ -n "$Q_OPEN" ] && { { exec 8>&-; } 2>/dev/null; }
  sleep 1
  if [ -n "$MADE_SDB" ]; then sq "IF DB_ID('$SDB') IS NOT NULL BEGIN ALTER DATABASE [$SDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$SDB]; END" >/dev/null 2>&1 || echo "CLEANUP: SQL Server database $SDB not dropped" >&2; fi
  if [ -n "$MADE_L1" ]; then sq "IF SUSER_ID('$L1') IS NOT NULL DROP LOGIN [$L1];" >/dev/null 2>&1 || echo "CLEANUP: login $L1 not dropped" >&2; fi
  if [ -n "$MADE_PGDB" ]; then psql "$ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $PGDB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2; fi
  if [ -n "$MADE_REPO" ]; then psql "$ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; fi
  rm -rf "$TMPD"
  exit $rc
}
trap cleanup EXIT
adm() { psql "$ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 "$@"; }
[ "$(adm -c "select count(*) from pg_database where datname in ('$REPO_DB', '$PGDB')")" = 0 ] || fail "a database of this run exists already (suffix $SUF): run again"
adm -c "create database $REPO_DB"; MADE_REPO=1
adm -c "create database $PGDB"; MADE_PGDB=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
pq() { psql "$ADMIN_DSN dbname=$PGDB" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
pq "create table t (id int primary key, v int not null); insert into t values (1, 0), (2, 0); create table qt (id int)"
[ "$(sq "SELECT CASE WHEN DB_ID('$SDB') IS NULL AND SUSER_ID('$L1') IS NULL THEN 1 ELSE 0 END")" = 1 ] || fail "a SQL Server name of this run exists already (suffix $SUF): run again"
sq "CREATE DATABASE [$SDB];"; MADE_SDB=1
sq "CREATE TABLE dbo.dl_a (id int NOT NULL PRIMARY KEY, v int NOT NULL); CREATE TABLE dbo.dl_b (id int NOT NULL PRIMARY KEY, v int NOT NULL);
    CREATE TABLE dbo.bl (id int NOT NULL PRIMARY KEY, v int NOT NULL); INSERT dbo.dl_a VALUES (1, 0); INSERT dbo.dl_b VALUES (1, 0); INSERT dbo.bl VALUES (1, 0);" "$SDB"
# the login's password reaches the server in a file, never on a command line (ps lists docker exec's arguments)
umask 077; printf "CREATE LOGIN [%s] WITH PASSWORD = N'%s', CHECK_POLICY = OFF;\n" "$L1" "$P1" > "$TMPD/login.sql"
docker cp -q "$TMPD/login.sql" "$CT:/tmp/pgvbh_login_$SUF.sql"; rm -f "$TMPD/login.sql"; MADE_L1=1
rc=0; docker exec -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -U sa -C -b -i "/tmp/pgvbh_login_$SUF.sql" >/dev/null || rc=$?
docker exec -u 0 "$CT" rm -f "/tmp/pgvbh_login_$SUF.sql"
[ $rc = 0 ] || fail "the login was not created"
sq "GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1];"
export MSSQL_MON_DSN="sqlserver://$L1:$P1@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export PG_MON_DSN="$ADMIN_DSN dbname=$PGDB"
NP=proof-bh-pg-$SUF; NS=proof-bh-ms-$SUF
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $NP
    dsn: env:PG_MON_DSN
  - name: $NS
    engine: sqlserver
    dsn: env:MSSQL_MON_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$2" > "$OUT" 2>&1 || { cat "$OUT"; fail "collect $1 $2"; }; }
T0=$(date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%SZ)

echo "--- A. a PostgreSQL chain held over three captures"
APPH=pgvbh_head_$SUF; APPW=pgvbh_wait_$SUF; APPB=pgvbh_by_$SUF
mkfifo "$TMPD/head" "$TMPD/by"
PGAPPNAME=$APPH psql "$ADMIN_DSN dbname=$PGDB" -XAtq < "$TMPD/head" > "$TMPD/head.out" 2>&1 &
exec 5>"$TMPD/head"; PG_OPEN=1
PGAPPNAME=$APPB psql "$ADMIN_DSN dbname=$PGDB" -XAtq < "$TMPD/by" > "$TMPD/by.out" 2>&1 &
exec 6>"$TMPD/by"
HEAD_STMT="UPDATE t SET v = v + 1 WHERE id = 1"
printf 'BEGIN ISOLATION LEVEL REPEATABLE READ;\nSELECT count(*) FROM t;\n%s;\n' "$HEAD_STMT" >&5
printf 'BEGIN;\nSELECT count(*) FROM t;\n' >&6
pid_of() { adm -c "select pid from pg_stat_activity where application_name = '$1' order by backend_start limit 1"; }
for _ in $(seq 1 50); do HP=$(pid_of "$APPH"); [ -n "$HP" ] && [ "$(adm -c "select state from pg_stat_activity where pid = $HP")" = "idle in transaction" ] && break; sleep 0.2; done
[ -n "${HP:-}" ] || fail "A: the head did not start: $(cat "$TMPD/head.out")"
PGAPPNAME=${APPW}1 psql "$ADMIN_DSN dbname=$PGDB" -XAtq -c "UPDATE t SET v = v + 10 WHERE id = 1" > "$TMPD/w1.out" 2>&1 &
for _ in $(seq 1 50); do W1=$(pid_of "${APPW}1"); [ -n "$W1" ] && [ "$(adm -c "select wait_event_type from pg_stat_activity where pid = $W1")" = Lock ] && break; sleep 0.2; done
PGAPPNAME=${APPW}2 psql "$ADMIN_DSN dbname=$PGDB" -XAtq -c "UPDATE t SET v = v + 100 WHERE id = 1" > "$TMPD/w2.out" 2>&1 &
for _ in $(seq 1 50); do W2=$(pid_of "${APPW}2"); [ -n "$W2" ] && [ "$(adm -c "select wait_event_type from pg_stat_activity where pid = $W2")" = Lock ] && break; sleep 0.2; done
[ -n "${W1:-}" ] && [ -n "${W2:-}" ] || fail "A: the waiters did not start"
BP=$(adm -c "select pid || ':' || pg_blocking_pids(pid)::text from pg_stat_activity where pid in ($W1, $W2) order by pid")
echo "  head $HP, waiters $W1 and $W2; pg_blocking_pids: $(echo $BP)"
sleep 2
collect activity "$NP"; sleep 2; collect activity "$NP"; sleep 2; collect activity "$NP"
iid=$(q "select instance_id from pgvigil.instances where name='$NP'")
T1=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)
W="'$T0'::timestamptz, '$T1'::timestamptz"
[ "$(q "select count(*) from pgvigil.activity_summary where instance_id=$iid")" = 3 ] || fail "A: three captures stored"
[ "$(q "select string_agg(victims || '/' || direct || '/' || depth || '/' || head_state, ' ' order by snapshot_at) from pgvigil.blocking_history_chains($iid, $W) where head_pid = $HP")" \
  = "2/1/2/idle in transaction 2/1/2/idle in transaction 2/1/2/idle in transaction" ] \
  || fail "A: the chains of the head: $(q "select snapshot_at, victims, direct, depth, head_state from pgvigil.blocking_history_chains($iid, $W) where head_pid = $HP")"
DIFF=$(q "with old as (select a.snapshot_at, c.head_pid, count(distinct c.pid)::int v, max(c.depth)::int d from pgvigil.activity_summary a, pgvigil.blocking_chains($iid, a.snapshot_at) c where a.instance_id=$iid group by 1, 2),
               new as (select snapshot_at, head_pid, victims, depth from pgvigil.blocking_history_chains($iid, $W))
          select count(*) from ((select * from old except select * from new) union all (select * from new except select * from old)) x")
[ "$DIFF" = 0 ] || fail "A: blocking_history_chains and blocking_chains differ in $DIFF row(s)"
[ "$(q "select count(*) || '|' || min(samples) || '|' || min(idle_in_txn_samples) || '|' || min(last_state) || '|' || min(victims) || '|' || min(direct) || '|' || min(depth)
          || '|' || (min(longest_blocked_secs) >= 2) || '|' || btrim(min(head_query), E' ;\n')
          from pgvigil.blocking_history_episodes($iid, $W) where head_pid = $HP")" = "1|3|3|idle in transaction|2|1|2|true|$HEAD_STMT" ] \
  || fail "A: the episode: $(q "select * from pgvigil.blocking_history_episodes($iid, $W) where head_pid = $HP")"
XA=$(q "select string_agg(head_xact_secs::text, ' ' order by snapshot_at) from pgvigil.blocking_history_chains($iid, $W) where head_pid = $HP")
[ "$(q "select (string_to_array('$XA', ' '))[3]::int > (string_to_array('$XA', ' '))[1]::int")" = t ] || fail "A: the transaction's age did not grow: $XA"
CYC=$(q "select count(distinct a.snapshot_at) from pgvigil.activity_summary a, pgvigil.blocking_chains($iid, a.snapshot_at) c where a.instance_id=$iid and c.head_pid is null")
[ "$(q "select captures || '|' || with_blocking || '|' || pct_with_blocking || '|' || with_cycle from pgvigil.blocking_history_summary($iid, $W)")" = "3|3|100.0|$CYC" ] \
  || fail "A: the summary: $(q "select * from pgvigil.blocking_history_summary($iid, $W)"), want 3|3|100.0|$CYC"
[ "$(q "select sum(captures) || '|' || sum(with_blocking) || '|' || (max(blocked_max) >= 2) from pgvigil.blocking_history_trend($iid, $W, 60)")" = "3|3|true" ] \
  || fail "A: the trend: $(q "select * from pgvigil.blocking_history_trend($iid, $W, 60)")"
echo "A: OK (the head's transaction age over the captures: $XA s)"

echo "--- B. who pinned the xmin horizon"
BYP=$(pid_of "$APPB")
[ "$(q "select samples || '|' || state_at_peak from pgvigil.xmin_pins($iid, $W) where pid = $HP")" = "3|idle in transaction" ] \
  || fail "B: the head in xmin_pins: $(q "select * from pgvigil.xmin_pins($iid, $W) where pid = $HP")"
[ "$(q "select count(*) from pgvigil.activity_sample where instance_id=$iid and pid=$BYP and state='idle in transaction'")" = 3 ] || fail "B: the bystander was not sampled idle in transaction"
[ "$(q "select count(*) from pgvigil.xmin_pins($iid, $W) where pid = $BYP")" = 0 ] || fail "B: the READ COMMITTED bystander is listed as pinning the horizon"
[ "$(q "select idle_in_txn_no_xmin >= 1 from pgvigil.xmin_pins_summary($iid, $W)")" = t ] || fail "B: xmin_pins_summary: $(q "select * from pgvigil.xmin_pins_summary($iid, $W)")"
PIN=$(q "select count(*) from (select snapshot_at, max(backend_xmin_age) m from pgvigil.activity_sample where instance_id=$iid and backend_xmin_age is not null group by 1) c
          join pgvigil.activity_sample a on a.instance_id=$iid and a.snapshot_at=c.snapshot_at and a.pid=$HP and a.backend_xmin_age=c.m")
[ "$(q "select pinned_samples from pgvigil.xmin_pins($iid, $W) where pid = $HP")" = "$PIN" ] || fail "B: the head held the oldest xmin in $PIN capture(s), xmin_pins says $(q "select pinned_samples from pgvigil.xmin_pins($iid, $W) where pid = $HP")"
SYN=$(psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 <<SQL
BEGIN;
CREATE TEMP TABLE before_syn AS SELECT idle_in_txn_sessions s, idle_in_txn_no_xmin n FROM pgvigil.xmin_pins_summary($iid, $W);
INSERT INTO pgvigil.activity_sample (instance_id, snapshot_at, pid, backend_start, state, backend_xmin_age) VALUES
  ($iid, now() - interval '20 s', 2000000001, '2026-01-01', 'active', 7),
  ($iid, now() - interval '10 s', 2000000001, '2026-01-01', 'idle in transaction', NULL),
  ($iid, now() - interval '20 s', 2000000002, '2026-01-01', 'idle in transaction', 9);
SELECT (a.idle_in_txn_sessions - b.s) || '|' || (a.idle_in_txn_no_xmin - b.n) FROM pgvigil.xmin_pins_summary($iid, $W) a, before_syn b;
ROLLBACK;
SQL
)
[ "$SYN" = "2|1" ] || fail "B: per sample, the synthetic sessions moved the counts by $SYN, want 2|1"
printf 'COMMIT;\n' >&5; printf 'COMMIT;\n' >&6
for _ in $(seq 1 50); do [ "$(adm -c "select count(*) from pg_stat_activity where pid in ($W1, $W2)")" = 0 ] && break; sleep 0.2; done
[ "$(pq "select v from t where id = 1")" = 111 ] || fail "B: the three updates did not all commit: v = $(pq "select v from t where id = 1")"
collect activity "$NP"
LAST=$(q "select max(snapshot_at) from pgvigil.activity_summary where instance_id=$iid")
[ "$(q "select count(*) from pgvigil.blocking_history_chains($iid, $W) where head_pid = $HP and snapshot_at = '$LAST'")" = 0 ] || fail "B: the fourth capture still has the head's chain"
RAW=$(q "select count(distinct snapshot_at) from pgvigil.activity_sample where instance_id=$iid and wait_event_type = 'Lock' and coalesce(cardinality(blocking_pids), 0) > 0")
[ "$(q "select captures || '|' || with_blocking || '|' || pct_with_blocking from pgvigil.blocking_history_summary($iid, $W)")" = "4|$RAW|$(q "select round(100.0 * $RAW / 4, 1)")" ] \
  || fail "B: the summary after the commit: $(q "select * from pgvigil.blocking_history_summary($iid, $W)"), want 4|$RAW"
[ "$RAW" = 3 ] || echo "  the fourth capture holds another workload's chain on the shared sandbox: $RAW of 4 captures with blocking"
[ "$(q "select samples from pgvigil.blocking_history_episodes($iid, $W) where head_pid = $HP")" = 3 ] || fail "B: the episode after the commit"
echo "B: OK (the bystander $BYP pinned nothing)"

echo "--- C. SQL Server: a chain over two snapshots, a deadlock, and the API"
mkfifo "$TMPD/ms"
docker exec -i -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -U sa -C -b -d "$SDB" -H "pgvbh$SUF" < "$TMPD/ms" > "$TMPD/ms.out" 2>&1 &
exec 7>"$TMPD/ms"; MS_OPEN=1
printf 'BEGIN TRAN; UPDATE dbo.bl SET v = v + 1 WHERE id = (SELECT 1);\nGO\n' >&7
# the waiter starts only once the head holds its open transaction (else it runs first and nothing blocks)
for _ in $(seq 1 50); do [ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE host_name = 'pgvbh$SUF' AND open_transaction_count = 1")" = 1 ] && break; sleep 0.2; done
[ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE host_name = 'pgvbh$SUF' AND open_transaction_count = 1")" = 1 ] || fail "C: the SQL Server head did not open its transaction: $(cat "$TMPD/ms.out")"
docker exec -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -U sa -C -b -d "$SDB" -H "pgvbhw$SUF" -Q "UPDATE dbo.bl SET v = v + 10 WHERE id = (SELECT 1);" > "$TMPD/msw.out" 2>&1 &
blocked_ms() { sq "SELECT COUNT(*) FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.host_name = 'pgvbhw$SUF' AND r.blocking_session_id > 0"; }
for _ in $(seq 1 50); do [ "$(blocked_ms)" = 1 ] && break; sleep 0.2; done
[ "$(blocked_ms)" = 1 ] || fail "C: the SQL Server waiter is not blocked: $(cat "$TMPD/msw.out")"
sleep 2
collect mssql_requests "$NS"; sleep 2; collect mssql_requests "$NS"
printf 'COMMIT;\nGO\n' >&7
sid=$(q "select instance_id from pgvigil.instances where name='$NS'")
S1="BEGIN TRAN; UPDATE dbo.dl_a SET v = 1 WHERE id = 1; WAITFOR DELAY '00:00:03'; UPDATE dbo.dl_b SET v = 1 WHERE id = 1; COMMIT;"
S2="BEGIN TRAN; UPDATE dbo.dl_b SET v = 2 WHERE id = 1; WAITFOR DELAY '00:00:03'; UPDATE dbo.dl_a SET v = 2 WHERE id = 1; COMMIT;"
( docker exec -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -U sa -C -I -d "$SDB" -H "pgvbhd$SUF" -Q "$S1" >/dev/null 2>&1 || true ) & D1=$!
( docker exec -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -U sa -C -I -d "$SDB" -H "pgvbhd$SUF" -Q "$S2" >/dev/null 2>&1 || true ) & D2=$!
wait $D1 $D2
dl() { q "select $1 from pgvigil.mssql_deadlocks where instance_id=$sid and database_names = '$SDB'"; }
for _ in $(seq 1 12); do collect mssql_xe "$NS"; [ "$(dl "count(*)")" = 1 ] && break; sleep 5; done
[ "$(dl "count(*) || '|' || min(process_count) || '|' || min(victim_count) || '|' || bool_and(graph like '<deadlock>%</deadlock>')")" = "1|2|1|true" ] \
  || fail "C: the deadlock row: $(dl "count(*), min(process_count), min(victim_count), min(left(graph, 20))")"
VSPID=$(dl "victim_spid")
PORT=$((20000 + RANDOM % 20000)); while ss -ltnH "sport = :$PORT" | grep -q .; do PORT=$((20000 + RANDOM % 20000)); done
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$TMPD/serve.yaml"
"$BIN" serve -config "$TMPD/serve.yaml" -listen "127.0.0.1:$PORT" -no-login > "$TMPD/serve.out" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || fail "C: serve exited: $(cat "$TMPD/serve.out")"
U="http://127.0.0.1:$PORT/api/blocking/history"
T2=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)
curl -fs "$U?instance=$sid&from=$T0&to=$T2" > "$TMPD/ms.json" || fail "C: the SQL Server history"
NDL=$(q "select count(*) from pgvigil.mssql_deadlocks where instance_id=$sid and event_at > '$T0' and event_at <= '$T2'")
python3 - "$TMPD/ms.json" "$NDL" <<'PY' || fail "C: the SQL Server parts"
import json, sys
d = json.load(open(sys.argv[1])); ndl = int(sys.argv[2])
rows = lambda p: [dict(zip(d[p]["columns"], r)) for r in d[p]["rows"]]
assert sorted(d) == ["deadlock_trend", "meta", "pairs", "trend"], sorted(d)
# pairs since task 177 D04 (the blocked / blocking pairs of the minute snapshots, pgvigil.mssql_block_pairs): a grid
assert isinstance(d["pairs"].get("columns"), list) and isinstance(d["pairs"].get("rows"), list), sorted(d["pairs"])
assert len(d["pairs"]["rows"]) >= 1, d["pairs"]  # the chain both snapshots saw is one pair at least
t = rows("trend"); dt = rows("deadlock_trend"); m = rows("meta")[0]
assert m["engine"] == "sqlserver" and m["cut"] is False, m
assert sum(r["snapshots"] for r in t) == 2 and sum(r["with_blocking"] for r in t) == 2, t
assert max(r["blocked_max"] for r in t) >= 1 and max((r["longest_wait_ms"] or 0) for r in t) > 0, t
assert sum(r["deadlocks"] for r in dt) == ndl and ndl >= 1, (ndl, dt)
import datetime as dtm
f, to, st = dtm.datetime.fromisoformat(m["from_at"]).timestamp(), dtm.datetime.fromisoformat(m["to_at"]).timestamp(), m["step_secs"]
want = int((to - (f // st) * st) // st) + 1
assert len(t) == want and len(dt) == want, (len(t), len(dt), want)
print(f"  trend: {len(t)} steps of {m['step_secs']} s, 2 snapshots with a blocked session; {ndl} deadlock(s) in the window")
PY
curl -fs "$U?instance=$iid&from=$T0&to=$T2" > "$TMPD/pg.json" || fail "C: the PostgreSQL history"
python3 - "$TMPD/pg.json" "$HP" "$RAW" <<'PY' || fail "C: the PostgreSQL parts"
import json, sys
d = json.load(open(sys.argv[1])); hp = int(sys.argv[2])
rows = lambda p: [dict(zip(d[p]["columns"], r)) for r in d[p]["rows"]]
assert sorted(d) == ["episodes", "meta", "summary", "trend", "xmin_now", "xmin_pins", "xmin_summary"], sorted(d)
e = [r for r in rows("episodes") if r["head_pid"] == hp]
assert len(e) == 1 and e[0]["samples"] == 3 and e[0]["victims"] == 2, e
s = rows("summary")[0]
assert s["captures"] == 4 and s["with_blocking"] == int(sys.argv[3]), s
assert any(r["pid"] == hp for r in rows("xmin_pins")), rows("xmin_pins")
PY
code=$(curl -s -o /dev/null -w '%{http_code}' "$U?instance=$iid&part=nonsense"); [ "$code" = 400 ] || fail "C: an unknown part answered $code"
F30=$(date -u -d '-30 days' +%Y-%m-%dT%H:%M:%SZ)
curl -fs "$U?instance=$sid&from=$F30&to=$T2&part=meta" | python3 -c "
import json, sys, datetime as dt
m = json.load(sys.stdin)['meta']; r = dict(zip(m['columns'], m['rows'][0]))
f, t = dt.datetime.fromisoformat(r['from_at']), dt.datetime.fromisoformat(r['to_at'])
assert r['cut'] is True and abs((t - f).total_seconds() - 7 * 86400) < 1, r" || fail "C: a 30-day window is not cut to seven days"
echo "C: OK (the deadlock's victim is session $VSPID)"

echo "--- D. the pages in a headless Chromium"
for t in chromium node; do command -v $t >/dev/null || fail "D: $t is not on this machine"; done
CDP=$((PORT + 1)); while ss -ltnH "sport = :$CDP" | grep -q .; do CDP=$((CDP + 1)); done
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu about:blank > "$TMPD/chrome.out" 2>&1 &
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
CHRPID=$(pgrep -o -f -- "--user-data-dir=$TMPD/chrome") || fail "D: chromium did not start: $(cat "$TMPD/chrome.out")"
cat > "$TMPD/look.mjs" <<'JS'
const [port, U, sid, iid, hp, vspid, raw] = process.argv.slice(2);
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (e) => (await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true })).result?.result?.value;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (e, ms = 20000) => { const t = Date.now(); while (Date.now() - t < ms) { if (await ev(e)) return true; await sleep(200); } return false; };
const fails = [];
const check = (ok, what) => { if (!ok) fails.push(what); };
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: `${U}#/mssql_deadlocks?i=${sid}&w=1h` });
check(await until(`!!document.querySelector('svg.deadlock-graph')`), 'no svg.deadlock-graph on the Deadlocks tab (is the tab wired to mssql_deadlocks.ts?)');
const g = await ev(`(() => {
  const svg = document.querySelector('svg.deadlock-graph'); if (!svg) return null;
  const txt = n => [...n.querySelectorAll('text')].map(t => t.textContent).join(' | ');
  return { procs: [...svg.querySelectorAll('g.dl-process')].map(txt), victims: [...svg.querySelectorAll('g.dl-victim')].map(txt),
    res: [...svg.querySelectorAll('g.dl-resource')].map(txt), labels: [...svg.querySelectorAll('g.dl-edge-label text')].map(t => t.textContent),
    from: [...document.querySelectorAll('.detail p.meta')].map(p => p.textContent).join(' '),
    save: [...document.querySelectorAll('.detail a')].find(a => a.textContent === 'Save XML')?.getAttribute('href') ?? null };
})()`);
if (g) {
  check(g.procs.length === 2, `2 session boxes, got ${g.procs.length}`);
  check(g.victims.length === 1 && g.victims[0].includes('VICTIM') && g.victims[0].includes(`Session ${vspid}`), `one victim box, Session ${vspid}, VICTIM: ${JSON.stringify(g.victims)}`);
  check(g.procs.every(p => p.includes('BEGIN TRAN; UPDATE dbo.dl_')), `each box with its statement's first line: ${JSON.stringify(g.procs)}`);
  check(g.res.length === 2 && g.res.some(r => r.includes('.dbo.dl_a')) && g.res.some(r => r.includes('.dbo.dl_b')), `2 resource boxes on dl_a and dl_b: ${JSON.stringify(g.res)}`);
  check(g.labels.filter(l => l.startsWith('holds ')).length === 2 && g.labels.filter(l => l.startsWith('waits for ')).length === 2, `2 holds and 2 waits: ${JSON.stringify(g.labels)}`);
  check(g.from.includes('Drawn from the deadlock XML SQL Server wrote.'), `drawn from the XML: ${g.from}`);
  check(!!g.save, 'a Save XML link');
  if (g.save) { const x = await (await fetch(U + g.save.replace(/^\//, ''))).text(); check(x.startsWith('<deadlock>'), `the saved XML starts with <deadlock>: ${x.slice(0, 30)}`); }
  console.log(`  drawn: ${g.procs.length} sessions, victim ${JSON.stringify(g.victims[0]?.split(' | ').slice(0, 2))}, resources ${g.res.length}, labels ${JSON.stringify(g.labels)}`);
}
await cmd('Page.navigate', { url: `${U}#/activity?i=${iid}&w=1h` });
check(await until(`!!document.querySelector('.blocking-history .tiles')`), 'no Blocking history on the PostgreSQL Running queries tab');
const p = await ev(`(() => {
  const h = document.querySelector('.blocking-history'); if (!h) return null;
  const tiles = Object.fromEntries([...h.querySelectorAll('.tiles')[0].querySelectorAll('.tile')].map(t => [t.querySelector('.tile-l').textContent, t.querySelector('.tile-v').textContent]));
  const cells = [...h.querySelectorAll('table')][0]?.querySelectorAll('tbody tr') ?? [];
  const pids = [...cells].map(r => [...r.children].map(c => c.textContent));
  const xmin = [...(document.querySelector('.xmin-pins')?.querySelectorAll('table') ?? [])].map(t => t.textContent).join(' ');
  return { tiles, pids, xmin };
})()`);
if (p) {
  check(p.tiles['captures'] === '4' && p.tiles['with blocking'] === raw, `tiles 4 captures, ${raw} with blocking: ${JSON.stringify(p.tiles)}`);
  check(p.pids.some(r => r.includes(hp)), `a chain row of the head ${hp}: ${JSON.stringify(p.pids)}`);
  check(p.xmin.includes(hp), `the head ${hp} in the xmin section`);
  console.log(`  PostgreSQL: tiles ${JSON.stringify(p.tiles)}; ${p.pids.length} chain row(s)`);
}
ws.close();
if (fails.length) { console.log('FAIL ' + fails.join('; ')); process.exit(1); }
JS
node "$TMPD/look.mjs" "$CDP" "http://127.0.0.1:$PORT/" "$sid" "$iid" "$HP" "$VSPID" "$RAW" || fail "D: the pages"
echo "D: OK"

echo "--- E. a lock queue of 20 sessions"
mkfifo "$TMPD/qh"
PGAPPNAME=pgvbh_qh_$SUF psql "$ADMIN_DSN dbname=$PGDB" -XAtq < "$TMPD/qh" > "$TMPD/qh.out" 2>&1 &
exec 8>"$TMPD/qh"; Q_OPEN=1
printf 'BEGIN;\nLOCK TABLE qt IN ACCESS EXCLUSIVE MODE;\n' >&8
for _ in $(seq 1 50); do QH=$(pid_of "pgvbh_qh_$SUF"); [ -n "$QH" ] && [ "$(adm -c "select state from pg_stat_activity where pid = $QH")" = "idle in transaction" ] && break; sleep 0.2; done
[ -n "${QH:-}" ] || fail "E: the queue's head did not start: $(cat "$TMPD/qh.out")"
for i in $(seq 1 20); do
  # LOCK TABLE runs only inside a transaction block (first run: every waiter was refused at once)
  PGAPPNAME=pgvbh_q_$SUF psql "$ADMIN_DSN dbname=$PGDB" -XAtq -c "BEGIN" -c "LOCK TABLE qt IN ACCESS EXCLUSIVE MODE" -c "COMMIT" > "$TMPD/q$i.out" 2>&1 &
  sleep 0.1
done
qwait() { adm -c "select count(*) from pg_stat_activity where application_name = 'pgvbh_q_$SUF' and wait_event_type = 'Lock'"; }
for _ in $(seq 1 100); do [ "$(qwait)" = 20 ] && break; sleep 0.2; done
[ "$(qwait)" = 20 ] || fail "E: $(qwait) of 20 sessions queued: $(cat "$TMPD"/q*.out | sort | uniq -c | head -3)"
echo "  the last in the queue names: $(adm -c "select pg_blocking_pids(pid)::text from pg_stat_activity where application_name = 'pgvbh_q_$SUF' order by backend_start desc limit 1")"
collect activity "$NP"
QAT=$(q "select max(snapshot_at) from pgvigil.activity_summary where instance_id=$iid")
T3=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ); W3="'$T0'::timestamptz, '$T3'::timestamptz"
[ "$(q "select victims || '|' || direct || '|' || depth || '|' || (blocked_in_capture >= 20) from pgvigil.blocking_history_chains($iid, $W3) where snapshot_at = '$QAT' and head_pid = $QH")" = "20|20|1|true" ] \
  || fail "E: the queue's chain: $(q "select head_pid, victims, direct, depth, blocked_in_capture from pgvigil.blocking_history_chains($iid, $W3) where snapshot_at = '$QAT'")"
[ "$(q "select count(distinct c.pid) from pgvigil.blocking_chains($iid, '$QAT') c join pgvigil.activity_sample a on a.instance_id=$iid and a.snapshot_at='$QAT' and a.pid=c.pid where c.head_pid = $QH and a.application_name = 'pgvbh_q_$SUF'")" = 20 ] \
  || fail "E: blocking_chains does not name the same head for the 20"
MS=$(psql "$PGVIGIL_REPO_DSN" -XAtq -c "select extract(epoch from clock_timestamp() - now()) from (select count(*) from pgvigil.blocking_history_chains($iid, $W3)) x" | head -1)
[ "$(q "select $MS < 2")" = t ] || fail "E: blocking_history_chains took $MS s"
printf 'COMMIT;\n' >&8
for _ in $(seq 1 100); do [ "$(adm -c "select count(*) from pg_stat_activity where application_name = 'pgvbh_q_$SUF'")" = 0 ] && break; sleep 0.2; done
echo "E: OK (the chain function over the window in $MS s)"
echo "OK: proof-blocking-history"
