#!/usr/bin/env bash
# Proof of SQL Server running queries, blocking and waits (migration 0064, internal/mssql/requests.go and waits.go):
# the minute snapshot names the head of a blocking chain by the head rule, as a least-privilege login.
#
# Needs: docker with a SQL Server container (PGVIGIL_MSSQL_CONTAINER, default mssql-sandbox) reachable from this
# machine on PGVIGIL_MSSQL_ADDR (default localhost:1433), its sa password in MSSQL_SA_PASSWORD, psql, and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form (host=... user=... dbname=...).
# The proof makes its own repository database, its own SQL Server database (one table, two rows), two logins
# (random suffix, random passwords) and, in part B only, a user for one of them in master with EXECUTE on
# sp_WhoIsActive; it drops every one of them at the end, on every exit path, and nothing else. It changes no server
# setting. Its three sessions run in its own database: a session that updates row 1 inside a transaction and then
# sleeps (the head), a second that updates row 2 and then waits for row 1, a third that waits for row 2.
#
# Expected (written before the first run):
#  A. the DMV read, as the login with VIEW SERVER STATE: `collect -once mssql_requests` stores a snapshot whose
#     summary says source dmv, at least 2 blocked and 1 head (the sandbox is shared: another proof's sessions may
#     be in the same snapshot, so every check below is on this proof's own three sessions), and the server's own
#     UTC clock within 10 s of the collector's;
#     the sleeping session is the head (depth 0, its own session as head, status sleeping, no request, an open
#     transaction with log bytes and a transaction id, 2 victims) and its statement is its last batch (the UPDATE
#     of row 1); the second session has depth 1 behind it, waits on a lock (LCK_M_*) for the time since it started
#     within 4 s, and its statement cut by the offsets is the second statement of its batch and nothing else (the
#     statements carry a subquery so the server does not auto-parameterise them; the stored text is also compared
#     with the server's own cut of the same handle and offsets); the
#     third has depth 2, blocked by the second. mssql_blocking holds one row: the head, 2 victims, the longest wait
#     = the second session's, the head's last batch, its transaction's age over 3 s. The handles read back as 0x
#     text (sql_handle, plan_handle, query_hash of the second session) and the sql_handle joins the text table.
#     The same instance under query_text: none stores the keys with no text.
#  B. where sp_WhoIsActive is installed in master: after sa grants the login EXECUTE on it, the next snapshot says
#     source sp_whoisactive and holds the same chain (head depth 0 with 2 victims, depths 1 and 2), with the
#     second session's sql_handle and plan_handle filled from the DMVs. Where it is not installed the proof prints
#     "sp_WhoIsActive path NOT PROVEN: not installed". After the grant is taken back the source is dmv again and
#     its note says the login has no EXECUTE permission.
#  C. the finding: once the victims have waited over 30 s, mssql_running_findings holds 'a blocking chain'
#     (warning) for the instance, its object the head's session, its detail naming the login and the last
#     statement.
#  D. after the head commits and the two victims finish (the table's values prove all three updates committed),
#     the next snapshot holds no chain of theirs: no mssql_blocking row headed by one of the three, none of the
#     three in the snapshot, and no finding left on them.
#  E. waits: the first `collect -once mssql_waits` stores the starting counters and no sample; after a WAITFOR
#     DELAY of 3 s the proof runs, the second stores samples, among them WAITFOR with at least 2,900 ms, marked
#     benign, with an interval above 0, and at least one wait that is not benign. A read whose counters went down
#     (a restart, a clear) stores no sample and starts the counters again.
#  F. a login without VIEW SERVER STATE: both collections print "skipped" with the missing right, and
#     collection_dates says skipped with it.
#  G. the other engine and retention: import_mssql_requests refuses a PostgreSQL instance; a snapshot 40 days old
#     gets its own day partition, and mssql_running_purge(30) drops that partition and its summary row and keeps
#     today's.
#  H. the statements on the server and their cost (go test, NOT RUN without a go toolchain): both collections as
#     the monitoring login (TestRunningLive), and the DMV read timed with PGVIGIL_PROOF_SESSIONS (default 300)
#     sessions each holding an open transaction (TestRequestsManySessionsLive prints the milliseconds). The cost at
#     10,000 sessions is NOT MEASURED here: the proof prints an estimate, marked as one.
#  NOT PROVEN HERE: SQL Server 2016-2019, Azure SQL Database (the database filter, sys.dm_db_wait_stats), Managed
#  Instance, RDS, a parallel request's task sums on a real parallel plan, a MARS session, a negative blocker, and
#  anything on Windows.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${MSSQL_SA_PASSWORD:?the sa password of the SQL Server sandbox}"
CT=${PGVIGIL_MSSQL_CONTAINER:-mssql-sandbox}; ADDR=${PGVIGIL_MSSQL_ADDR:-localhost:1433}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_mssqlrun_$SUF
SDB=pgvrun_$SUF
L1=pgv_run_$SUF; L2=pgv_runbare_$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
P1=$(pw); P2=$(pw)
CFG=$(mktemp); OUT=$(mktemp); TMPD=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; exit 1; }
# the sa password reaches sqlcmd through the environment, by name: never on a command line another user can list
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
MADE_DB=; MADE_L1=; MADE_L2=; MADE_SDB=; MADE_UM=; HEAD_OPEN=
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
sq() { docker exec -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -U sa -C -b -W -h -1 -s '|' -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
cleanup() {
  rc=$?
  if [ -n "$HEAD_OPEN" ]; then exec 7>&- 2>/dev/null || true; fi
  # only what THIS run created: a name that existed before the run (another run's, by a suffix collision) stays
  if [ -n "$MADE_SDB" ]; then sq "IF DB_ID('$SDB') IS NOT NULL BEGIN ALTER DATABASE [$SDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$SDB]; END" >/dev/null 2>&1 || echo "CLEANUP: database $SDB not dropped" >&2; fi
  if [ -n "$MADE_UM" ]; then sq "IF USER_ID('$L1') IS NOT NULL DROP USER [$L1];" master >/dev/null 2>&1 || echo "CLEANUP: master user $L1 not dropped" >&2; fi
  if [ -n "$MADE_L1" ]; then sq "IF SUSER_ID('$L1') IS NOT NULL DROP LOGIN [$L1];" >/dev/null 2>&1 || echo "CLEANUP: login $L1 not dropped" >&2; fi
  if [ -n "$MADE_L2" ]; then sq "IF SUSER_ID('$L2') IS NOT NULL DROP LOGIN [$L2];" >/dev/null 2>&1 || echo "CLEANUP: login $L2 not dropped" >&2; fi
  if [ -n "$MADE_DB" ]; then psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; fi
  rm -rf "$CFG" "$OUT" "$TMPD"
  exit $rc
}
trap cleanup EXIT
adm() { psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"; MADE_DB=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
[ "$(sq "SELECT CASE WHEN DB_ID('$SDB') IS NULL AND SUSER_ID('$L1') IS NULL AND SUSER_ID('$L2') IS NULL THEN 1 ELSE 0 END")" = 1 ] || fail "a name of this run exists already (suffix $SUF): run again"
sq "CREATE DATABASE [$SDB];"; MADE_SDB=1
sq "CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, v int NOT NULL); INSERT dbo.t VALUES (1, 0), (2, 0);" "$SDB"
sq "CREATE LOGIN [$L1] WITH PASSWORD = '$P1', CHECK_POLICY = OFF;"; MADE_L1=1
sq "GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1];"
sq "CREATE LOGIN [$L2] WITH PASSWORD = '$P2', CHECK_POLICY = OFF;"; MADE_L2=1
export MSSQL_MON_DSN="sqlserver://$L1:$P1@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export MSSQL_BARE_DSN="sqlserver://$L2:$P2@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export PG_MON_DSN="$ADMIN_DSN"
N1=proof-run-$SUF; N2=proof-run-bare-$SUF; N3=proof-run-notext-$SUF; NP=proof-run-pg-$SUF
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $N1
    engine: sqlserver
    dsn: env:MSSQL_MON_DSN
  - name: $N2
    engine: sqlserver
    dsn: env:MSSQL_BARE_DSN
  - name: $N3
    engine: sqlserver
    dsn: env:MSSQL_MON_DSN
    query_text: none
  - name: $NP
    dsn: env:PG_MON_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$2" | tee "$OUT"; }
latest() { q "select max(snapshot_at) from pgvigil.mssql_requests_summary where instance_id=$1"; }

# the three sessions, told apart by the workstation name sqlcmd sends (-H)
H1=pgvh1$SUF; H2=pgvh2$SUF; H3=pgvh3$SUF
# each statement carries a subquery, so the server does not auto-parameterise it: a trivial statement runs under its
# parameterised form, (@1 int,@2 tinyint)UPDATE [dbo].[t] set [v] = [v]+@1 WHERE [id]=@2, and that form is what
# the handle and offsets of its request name (seen in this proof's first run; it is the server's text, not an error)
STMT1="UPDATE dbo.t SET v = v + 1 WHERE id = (SELECT 1)"
STMT2="UPDATE dbo.t SET v = v + 10 WHERE id = (SELECT 1)"
STMT3="UPDATE dbo.t SET v = v + 100 WHERE id = (SELECT 2)"
sid() { sq "SELECT session_id FROM sys.dm_exec_sessions WHERE host_name = '$1'"; }
mkfifo "$TMPD/head"
docker exec -i -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -U sa -C -b -d "$SDB" -H "$H1" < "$TMPD/head" > "$TMPD/head.out" 2>&1 &
PID1=$!
exec 7>"$TMPD/head"; HEAD_OPEN=1
printf 'BEGIN TRAN; %s;\nGO\n' "$STMT1" >&7
for _ in $(seq 1 50); do S1=$(sid "$H1"); [ -n "$S1" ] && [ "$(sq "SELECT open_transaction_count FROM sys.dm_exec_sessions WHERE session_id = $S1")" = 1 ] && break; sleep 0.2; done
[ -n "${S1:-}" ] || fail "the head session did not start: $(cat "$TMPD/head.out")"
T2=$(date +%s%3N)
docker exec -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -U sa -C -b -d "$SDB" -H "$H2" -Q "BEGIN TRAN; UPDATE dbo.t SET v = v + 1 WHERE id = (SELECT 2); $STMT2; COMMIT;" > "$TMPD/s2.out" 2>&1 &
PID2=$!
for _ in $(seq 1 50); do S2=$(sid "$H2"); [ -n "$S2" ] && [ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE session_id = $S2 AND blocking_session_id = $S1")" = 1 ] && break; sleep 0.2; done
[ -n "${S2:-}" ] || fail "the second session did not start: $(cat "$TMPD/s2.out")"
docker exec -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -U sa -C -b -d "$SDB" -H "$H3" -Q "$STMT3;" > "$TMPD/s3.out" 2>&1 &
PID3=$!
for _ in $(seq 1 50); do S3=$(sid "$H3"); [ -n "$S3" ] && [ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE session_id = $S3 AND blocking_session_id = $S2")" = 1 ] && break; sleep 0.2; done
[ -n "${S3:-}" ] || fail "the third session did not start: $(cat "$TMPD/s3.out")"
echo "  sessions: head $S1 (sleeping, transaction open), $S2 behind it, $S3 behind $S2"
sleep 4

# chain <instance_id> <snapshot_at>: head|depth|blocked_by|victims of the three sessions, in their order
chain() { q "select string_agg(coalesce(head_session_id::text,'-') || '/' || coalesce(chain_depth::text,'-') || '/' || coalesce(nullif(blocking_session_id,0)::text,'-') || '/' || coalesce(victims::text,'-'), ' ' order by ord)
               from unnest(array[$S1,$S2,$S3]) with ordinality u(sid, ord)
               left join pgvigil.mssql_requests_v r on r.instance_id=$1 and r.snapshot_at='$2' and r.session_id=u.sid"; }
WANT_CHAIN="$S1/0/-/2 $S1/1/$S1/- $S1/2/$S2/-"

echo "--- A. the DMV read as the least-privilege login"
WIA=$(sq "SELECT CASE WHEN OBJECT_ID('master.dbo.sp_WhoIsActive', 'P') IS NULL THEN 0 ELSE 1 END")
collect mssql_requests "$N1"
if grep -q "partial\|skipped" "$OUT"; then fail "A: the run says partial or skipped"; fi
iid=$(q "select instance_id from pgvigil.instances where name='$N1'")
AT=$(latest "$iid")
[ "$(q "select source || '|' || (blocked >= 2) || '|' || (heads >= 1) || '|' || (abs(extract(epoch from server_utc - snapshot_at)) < 10) from pgvigil.mssql_requests_summary where instance_id=$iid and snapshot_at='$AT'")" = "dmv|true|true|true" ] \
  || fail "A: the summary: $(q "select source, source_note, blocked, heads, server_utc, snapshot_at from pgvigil.mssql_requests_summary where instance_id=$iid and snapshot_at='$AT'")"
[ "$(chain "$iid" "$AT")" = "$WANT_CHAIN" ] || fail "A: the chain (head/depth/blocked by/victims): $(chain "$iid" "$AT"); want $WANT_CHAIN"
[ "$(q "select status || '|' || (request_id is null) || '|' || (open_tran >= 1) || '|' || (tran_log_bytes > 0) || '|' || (transaction_id is not null) || '|' || (tran_age_ms > 3000) || '|' || stmt_start || '|' || stmt_end
          from pgvigil.mssql_requests_v where instance_id=$iid and snapshot_at='$AT' and session_id=$S1")" = "sleeping|true|true|true|true|true|-1|-1" ] \
  || fail "A: the head's row: $(q "select status, request_id, open_tran, tran_log_bytes, transaction_id, tran_age_ms, stmt_start, stmt_end from pgvigil.mssql_requests_v where instance_id=$iid and snapshot_at='$AT' and session_id=$S1")"
[ "$(q "select btrim(statement, E' \t\r\n;') from pgvigil.mssql_requests_v where instance_id=$iid and snapshot_at='$AT' and session_id=$S1")" = "BEGIN TRAN; $STMT1" ] \
  || fail "A: the head's last batch: $(q "select statement from pgvigil.mssql_requests_v where instance_id=$iid and snapshot_at='$AT' and session_id=$S1")"
W2=$(q "select wait_ms from pgvigil.mssql_requests_v where instance_id=$iid and snapshot_at='$AT' and session_id=$S2")
SINCE=$(q "select (extract(epoch from '$AT'::timestamptz) * 1000)::bigint - $T2")
echo "  the second session's wait: $W2 ms in the snapshot; $SINCE ms between its start and the collector's"
[ "$(q "select abs($W2 - $SINCE) < 4000")" = t ] || fail "A: the wait time is off by more than 4 s"
[ "$(q "select (wait_type like 'LCK_M_%') || '|' || btrim(statement, E' \t\r\n;') || '|' || (transaction_id is not null) from pgvigil.mssql_requests_v where instance_id=$iid and snapshot_at='$AT' and session_id=$S2")" = "true|$STMT2|true" ] \
  || fail "A: the second session's statement by its offsets: $(q "select wait_type, stmt_start, stmt_end, statement from pgvigil.mssql_requests_v where instance_id=$iid and snapshot_at='$AT' and session_id=$S2")"
[ "$(q "select btrim(statement, E' \t\r\n;') from pgvigil.mssql_requests_v where instance_id=$iid and snapshot_at='$AT' and session_id=$S3")" = "$STMT3" ] || fail "A: the third session's statement"
# and it is the server's own cut of the same handle and offsets, character for character
[ "$(sq "SELECT SUBSTRING(t.text, r.statement_start_offset / 2 + 1, (CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text) ELSE r.statement_end_offset END - r.statement_start_offset) / 2 + 1) FROM sys.dm_exec_requests r CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t WHERE r.session_id = $S2")" \
  = "$(q "select statement from pgvigil.mssql_requests_v where instance_id=$iid and snapshot_at='$AT' and session_id=$S2")" ] || fail "A: the stored statement is not the server's cut of the same offsets"
[ "$(q "select (sql_handle ~ '^0x[0-9A-F]{40,}$') || '|' || (plan_handle ~ '^0x[0-9A-F]{40,}$') || '|' || (query_hash ~ '^0x[0-9A-F]{16}$')
          || '|' || (select count(*) from pgvigil.mssql_statement_text t where t.instance_id=$iid and pgvigil.mssql_hex(t.sql_handle) = r.sql_handle and t.stmt_start = r.stmt_start and t.stmt_end = r.stmt_end and t.text_id = r.text_id)
          from pgvigil.mssql_requests_v r where instance_id=$iid and snapshot_at='$AT' and session_id=$S2")" = "true|true|true|1" ] \
  || fail "A: the handles as 0x text: $(q "select sql_handle, plan_handle, query_hash, text_id from pgvigil.mssql_requests_v where instance_id=$iid and snapshot_at='$AT' and session_id=$S2")"
[ "$(sq "SELECT CONVERT(varchar(200), sql_handle, 1) FROM sys.dm_exec_requests WHERE session_id = $S2")" = "$(q "select sql_handle from pgvigil.mssql_requests_v where instance_id=$iid and snapshot_at='$AT' and session_id=$S2")" ] || fail "A: the stored sql_handle is not the server's"
[ "$(q "select count(*) || '|' || min(head_session_id) || '|' || min(victims) || '|' || (min(longest_wait_ms) = $W2) || '|' || bool_and(in_snapshot) || '|' || min(head_status) || '|' || (min(head_tran_age_ms) > 3000)
          || '|' || (select btrim(t.statement, E' \t\r\n;') from pgvigil.mssql_statement_text t where t.text_id = min(b.head_text_id))
          from pgvigil.mssql_blocking b where instance_id=$iid and snapshot_at='$AT' and head_session_id=$S1")" = "1|$S1|2|true|true|sleeping|true|BEGIN TRAN; $STMT1" ] \
  || fail "A: mssql_blocking: $(q "select * from pgvigil.mssql_blocking where instance_id=$iid and snapshot_at='$AT'")"
echo "  the read took $(q "select read_ms from pgvigil.mssql_requests_summary where instance_id=$iid and snapshot_at='$AT'") ms on the SQL Server side with $(q "select sessions from pgvigil.mssql_requests_summary where instance_id=$iid and snapshot_at='$AT'") session(s) listed"
collect mssql_requests "$N3" >/dev/null
nid=$(q "select instance_id from pgvigil.instances where name='$N3'")
[ "$(q "select (count(*) >= 3) || '|' || count(statement) from pgvigil.mssql_statement_text where instance_id=$nid")" = "true|0" ] || fail "A: under query_text none: $(q "select count(*), count(statement) from pgvigil.mssql_statement_text where instance_id=$nid")"
[ "$(q "select count(*) from pgvigil.mssql_requests_v where instance_id=$nid and session_id=$S2 and sql_handle is not null and statement is null")" = 1 ] || fail "A: under query_text none the key is kept without the text"
echo "A: OK"

echo "--- B. sp_WhoIsActive, called where it is installed"
if [ "$WIA" = 1 ]; then
  [ "$(q "select source_note like '%no EXECUTE permission%' from pgvigil.mssql_requests_summary where instance_id=$iid and snapshot_at='$AT'")" = t ] || fail "B: the DMV read's note does not say why sp_WhoIsActive was not called"
  [ "$(sq "SELECT CASE WHEN USER_ID('$L1') IS NULL THEN 1 ELSE 0 END" master)" = 1 ] || fail "B: a user $L1 exists in master already"
  sq "CREATE USER [$L1] FOR LOGIN [$L1]; GRANT EXECUTE ON dbo.sp_WhoIsActive TO [$L1];" master; MADE_UM=1
  collect mssql_requests "$N1"
  if grep -q "partial" "$OUT"; then fail "B: the run says partial: sp_WhoIsActive failed and the DMV read ran"; fi
  BT=$(latest "$iid")
  [ "$(q "select source from pgvigil.mssql_requests_summary where instance_id=$iid and snapshot_at='$BT'")" = sp_whoisactive ] || fail "B: the source: $(q "select source, source_note from pgvigil.mssql_requests_summary where instance_id=$iid and snapshot_at='$BT'")"
  [ "$(chain "$iid" "$BT")" = "$WANT_CHAIN" ] || fail "B: the chain from sp_WhoIsActive's rows: $(chain "$iid" "$BT"); want $WANT_CHAIN"
  [ "$(q "select (sql_handle ~ '^0x[0-9A-F]{40,}$') || '|' || (plan_handle ~ '^0x[0-9A-F]{40,}$') || '|' || (wait_type like 'LCK_M_%') || '|' || (position('$STMT2' in statement) > 0)
            from pgvigil.mssql_requests_v where instance_id=$iid and snapshot_at='$BT' and session_id=$S2")" = "true|true|true|true" ] \
    || fail "B: the second session's row: $(q "select sql_handle, plan_handle, wait_type, statement from pgvigil.mssql_requests_v where instance_id=$iid and snapshot_at='$BT' and session_id=$S2")"
  [ "$(q "select status || '|' || (position('$STMT1' in statement) > 0) from pgvigil.mssql_requests_v where instance_id=$iid and snapshot_at='$BT' and session_id=$S1")" = "sleeping|true" ] || fail "B: the head's row"
  sq "DROP USER [$L1];" master; MADE_UM=
  echo "B: OK (source sp_whoisactive, the chain and the handles as in A)"
else
  echo "B: sp_WhoIsActive path NOT PROVEN: not installed"
  [ "$(q "select source_note like '%not installed%' from pgvigil.mssql_requests_summary where instance_id=$iid and snapshot_at='$AT'")" = t ] || fail "B: the DMV read's note"
fi

echo "--- C. the finding, once the victims have waited over 30 s"
NOW=$(date +%s%3N); LEFT=$(( (T2 + 33000 - NOW) / 1000 + 1 )); [ "$LEFT" -gt 0 ] && sleep "$LEFT"
collect mssql_requests "$N1" >/dev/null
CT2=$(latest "$iid")
[ "$(q "select source from pgvigil.mssql_requests_summary where instance_id=$iid and snapshot_at='$CT2'")" = dmv ] || fail "C: the source after the grant was taken back"
[ "$(q "select severity || '|' || object || '|' || (detail like '%Login sa%') || '|' || (detail like '%$STMT1%') || '|' || (detail like '%2 session(s) wait behind it%')
          from pgvigil.mssql_running_findings where instance_id=$iid and check_name='a blocking chain' and object='session $S1'")" = "warning|session $S1|true|true|true" ] \
  || fail "C: the finding: $(q "select severity, object, detail from pgvigil.mssql_running_findings where instance_id=$iid")"
echo "C: OK"

echo "--- D. the head commits: no chain in the next snapshot"
printf 'COMMIT;\nGO\n' >&7
wait $PID2 || fail "D: the second session failed: $(cat "$TMPD/s2.out")"
wait $PID3 || fail "D: the third session failed: $(cat "$TMPD/s3.out")"
exec 7>&-; HEAD_OPEN=
wait $PID1 || fail "D: the head session failed: $(cat "$TMPD/head.out")"
[ "$(sq "SELECT CAST(SUM(v) AS varchar(20)) FROM dbo.t" "$SDB")" = 112 ] || fail "D: the three sessions' updates did not all commit"
collect mssql_requests "$N1" >/dev/null
DT=$(latest "$iid")
[ "$DT" != "$CT2" ] || fail "D: no new snapshot"
[ "$(q "select (select count(*) from pgvigil.mssql_blocking b where b.instance_id=$iid and b.snapshot_at='$DT' and b.head_session_id in ($S1,$S2,$S3))
          || '|' || (select count(*) from pgvigil.mssql_requests r where r.instance_id=$iid and r.snapshot_at='$DT' and (r.session_id in ($S1,$S2,$S3) or r.head_session_id in ($S1,$S2,$S3)))
          || '|' || (blocked = (select count(distinct r.session_id) from pgvigil.mssql_requests r where r.instance_id=$iid and r.snapshot_at='$DT' and r.chain_depth > 0))
          from pgvigil.mssql_requests_summary where instance_id=$iid and snapshot_at='$DT'")" = "0|0|true" ] \
  || fail "D: after the commit: $(q "select blocked, heads from pgvigil.mssql_requests_summary where instance_id=$iid and snapshot_at='$DT'")"
[ "$(q "select count(*) from pgvigil.mssql_running_findings where instance_id=$iid and object in ('session $S1','session $S2','session $S3')")" = 0 ] || fail "D: a finding outlived the chain"
echo "D: OK"

echo "--- E. waits: the differences between two reads"
collect mssql_waits "$N1" >/dev/null
[ "$(q "select (select count(*) from pgvigil.mssql_wait_sample where instance_id=$iid) || '|' || (select count(*) from pgvigil.mssql_wait_state where instance_id=$iid) || '|' || (select count(*) > 10 from pgvigil.mssql_wait_last where instance_id=$iid)")" = "0|1|true" ] \
  || fail "E: the first read: $(q "select (select count(*) from pgvigil.mssql_wait_sample where instance_id=$iid), (select count(*) from pgvigil.mssql_wait_last where instance_id=$iid)")"
sq "WAITFOR DELAY '00:00:03';" >/dev/null
collect mssql_waits "$N1" >/dev/null
[ "$(q "select (wait_ms >= 2900) || '|' || is_benign || '|' || (interval_secs > 0) || '|' || (waiting_tasks >= 1) from pgvigil.mssql_wait_sample where instance_id=$iid and wait_type='WAITFOR'")" = "true|true|true|true" ] \
  || fail "E: the WAITFOR sample: $(q "select * from pgvigil.mssql_wait_sample where instance_id=$iid and wait_type='WAITFOR'")"
[ "$(q "select count(*) > 0 from pgvigil.mssql_wait_sample where instance_id=$iid and not is_benign")" = t ] || fail "E: no wait that is not benign"
echo "  the WAITFOR sample: $(q "select wait_ms || ' ms in ' || round(interval_secs::numeric, 1) || ' s, ' || waiting_tasks || ' wait(s)' from pgvigil.mssql_wait_sample where instance_id=$iid and wait_type='WAITFOR'"); $(q "select count(*) from pgvigil.mssql_wait_sample where instance_id=$iid") wait types moved"
BEFORE=$(q "select count(*) from pgvigil.mssql_wait_sample where instance_id=$iid")
q "select pgvigil.import_mssql_waits($iid, now() + interval '1 minute', '[{\"kind\":\"state\",\"server_utc\":\"$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)\",\"source\":\"sys.dm_os_wait_stats\"},{\"kind\":\"wait\",\"wait_type\":\"WAITFOR\",\"waiting_tasks\":1,\"wait_ms\":5,\"signal_ms\":0,\"max_wait_ms\":5}]'::jsonb)" >/dev/null
[ "$(q "select (select count(*) from pgvigil.mssql_wait_sample where instance_id=$iid) || '|' || (select count(*) from pgvigil.mssql_wait_last where instance_id=$iid)")" = "$BEFORE|1" ] \
  || fail "E: a read whose counters went down stored a sample or kept the old counters"
echo "E: OK"

echo "--- F. a login without VIEW SERVER STATE"
for c in mssql_requests mssql_waits; do
  collect "$c" "$N2"
  grep -q "skipped: the login lacks VIEW SERVER STATE" "$OUT" || fail "F: $c was not skipped with the reason"
done
bid=$(q "select instance_id from pgvigil.instances where name='$N2'")
[ "$(q "select count(*) from pgvigil.collection_dates where instance_id=$bid and collection in ('mssql_requests','mssql_waits') and status='skipped' and note like '%VIEW SERVER STATE%'")" = 2 ] \
  || fail "F: collection_dates: $(q "select collection, status, note from pgvigil.collection_dates where instance_id=$bid")"
[ "$(q "select count(*) from pgvigil.mssql_requests_summary where instance_id=$bid")" = 0 ] || fail "F: a snapshot was stored"
echo "F: OK"

echo "--- G. the other engine, and retention"
"$BIN" collect -config "$CFG" -once databases -instance "$NP" >/dev/null || fail "G: the PostgreSQL instance's own collection"
pid=$(q "select instance_id from pgvigil.instances where name='$NP'")
if q "select pgvigil.import_mssql_requests($pid, now(), '[{\"kind\":\"summary\",\"source\":\"dmv\"}]'::jsonb)" >"$OUT" 2>&1; then fail "G: a PostgreSQL instance was accepted"; fi
grep -q "is not a SQL Server instance" "$OUT" || { cat "$OUT"; fail "G: the refusal's text"; }
OLD=$(q "select to_char((now() - interval '40 days') at time zone 'UTC', 'YYYYMMDD')")
q "select pgvigil.import_mssql_requests($iid, now() - interval '40 days', '[{\"kind\":\"summary\",\"source\":\"dmv\"},{\"kind\":\"request\",\"session_id\":60,\"blocking_session_id\":0}]'::jsonb)" >/dev/null
[ "$(q "select to_regclass('pgvigil.mssql_requests_$OLD') is not null")" = t ] || fail "G: the old day's partition was not made"
TODAY=$(q "select to_char(now() at time zone 'UTC', 'YYYYMMDD')")
q "select pgvigil.mssql_running_purge(30)" >/dev/null
[ "$(q "select (to_regclass('pgvigil.mssql_requests_$OLD') is null) || '|' || (to_regclass('pgvigil.mssql_requests_$TODAY') is not null) || '|' || (select count(*) from pgvigil.mssql_requests_summary where instance_id=$iid and snapshot_at < now() - interval '30 days')
          || '|' || (select count(*) > 0 from pgvigil.mssql_requests_summary where instance_id=$iid) || '|' || (select count(*) > 0 from pgvigil.mssql_statement_text where instance_id=$iid)")" = "true|true|0|true|true" ] \
  || fail "G: after the purge"
echo "G: OK"

echo "--- H. the statements on the server as the monitoring login, and their cost"
if command -v go >/dev/null 2>&1 && [ -f go.mod ]; then
  NS=${PGVIGIL_PROOF_SESSIONS:-300}
  PGVIGIL_MSSQL_TEST_DSN="$MSSQL_MON_DSN" PGVIGIL_MSSQL_TEST_SESSIONS=$NS go test ./internal/mssql -run 'TestRunningLive|TestRequestsManySessionsLive' -count=1 -v > "$OUT" 2>&1 || { cat "$OUT"; fail "H: the live tests"; }
  grep -q -- "--- PASS: TestRunningLive" "$OUT" && grep -q -- "--- PASS: TestRequestsManySessionsLive" "$OUT" || { cat "$OUT"; fail "H: a live test did not run"; }
  grep -o "MANY-SESSIONS: .*" "$OUT" | sed 's/^/  /'
  echo "  ESTIMATE, not measured: at 10,000 sessions the read is expected to stay under about 2 s (the DMV joins are hash joins over the session list; DBA Dash's issue 1663 reports 0.3-1.9 s for its read at that size). Measure it before relying on it."
  echo "H: OK"
else
  echo "H: NOT RUN (no go toolchain or not at the repository root)"
fi
echo "proof-mssql-running: PASS (A, $([ "$WIA" = 1 ] && echo B || echo 'B not proven'), C-H)"
