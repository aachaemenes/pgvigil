#!/usr/bin/env bash
# Proof of blocking over the range in Erik Darling's shape (task 177, darling-open D04): the blocked-process reports
# pgvigil stores carry sp_HumanEventsBlockViewer's columns, pgvigil.mssql_block_findings equals the procedure's own
# findings over the same capture, the pairs of the minute snapshots equal the store's rows, system_health's
# QUERY_PROCESSING blockingTasks are stored where no capture of pgvigil runs, and the pages render under
# `pgvigil serve` in a headless Chromium with every link clicked and its landing named. Runs on a Linux box with docker
# (the project's build box).
#
# Needs: docker (pulls mcr.microsoft.com/mssql/server:2022-latest), go, psql, curl, python3, node, npm, chromium, git, and
#   ADMIN_DSN        a superuser connection to a PostgreSQL sandbox in KEYWORD form (default 'host=127.0.0.1 port=5432
#                    user=postgres dbname=postgres'); the proof makes its own pgvigil repository database and drops it
#   BLOCKVIEWER_SQL  sp_HumanEventsBlockViewer.sql of DarlingData (the version the port follows, 5.11), installed into
#                    the proof's own container only; the run fails without it
#   PGVIGIL_SHOTS    where the page shots go (default: a folder of the run, removed with it)
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment, never a command line.
#
# Expected (written before the first run):
#  A. a SQL Server 2022 container, 'blocked process threshold (s)' 5 (set by the proof on its own container), the blocked
#     session of `pgvigil mssql-xe -print -install-id p177d` created from the printed script; in database pgvblock a head
#     (host pgvb_h) updates id 1 in an open transaction held by a WAITFOR (suspended, user_transaction), two readers
#     (hosts pgvb_r1, pgvb_r2, READ COMMITTED) and a writer (host pgvb_w, SERIALIZABLE) wait on that key; held about
#     40 s while the minute collections run (mssql_requests three times, mssql_waiting_tasks once); then the threshold
#     goes back to 0 (no report after it) and mssql_xe reads the ring buffer: at least 6 reports stored, each with the
#     blocked side's isolation level, transaction name and last batch started, and the blocking side's status
#     suspended (WAITFOR) and last batch completed (a <blocking-process> carries no transaction name: run 4).
#  B. sp_HumanEventsBlockViewer @session_name = the blocked session, @target_type = 'ring_buffer', @end_date = the server's
#     clock just after pgvigil's read (the threshold back at 5 first: the procedure refuses to run with it at 0):
#     its findings result (check_id, database_name, object_name, finding_group, finding; its header row -1 and its
#     closing row left out) holds the same rows as pgvigil.mssql_block_findings over the window (both sides sorted:
#     the procedure's order is not compared; text compared with runs of white space as one space: the procedure
#     keeps an input buffer's leading line break as a space, pgvigil trims it);
#     the findings hold Database Locks, Object Locks naming dbo.pgvb_t, Blocking Involving Selects, Serializable
#     Blocking, Top Lead Blocker and the totals (1000, 1001).
#  C. GET /api/blocking/history part=pairs: the pairs (blocked, blocking, snapshots, longest wait) equal a direct read of
#     pgvigil.mssql_requests for the window; the trend part has reports in some step and a summed wait; the lead rollup
#     has one lead, the head's statement, with all the blocked wait (the database's total; the writer in the middle
#     of the chain is no lead), checked only when the chain has its middle (2 head statements: the writer the readers wait
#     behind).
#  D. pgvigil's blocked session dropped (the chain still held, the threshold 5 again): within about 6.5 minutes a read
#     of mssql_syshealth stores system_health's QUERY_PROCESSING blockingTasks as reports of source system_health
#     (the syshealth wiring, scripts/proof-darling-blockhistory-join.patch, applied to the run's copy while the join
#     does not hold it) and the component row's detail no longer carries them.
#  E. go test ./internal/mssql ./internal/web ./internal/repo and golangci-lint (0 issues) at the root and in app/, on
#     the run's copy.
#  F. `pgvigil serve` from the run's copy (web bundle rebuilt): #/mssql_blocked and #/mssql_running of the instance in
#     the light and the dark theme: the Blocked reports grid has as many rows as the store's head statements, the
#     findings grid as many as B's findings, the pairs grid as many as C's pairs; every link of both pages clicked, its
#     landing named (one 'click' line each) and rendered without an error box; each head's Open button clicked on a
#     fresh render: its panel (in place) lists as many reports as the head's row counts, each blocked by that head's
#     session, the object dbo.pgvb_t, the panels together as many reports as the store; shots of each page and of the
#     first head's opened panel in both themes; the Running tab shows the snapshot at= names (the pair link's own, then
#     the pairs' first snapshot by the same address).
#  G. 6,120 reports seeded in a window of their own (one chain, 120 monitor loops, 50 readers behind a writer behind a
#     head): mssql_block_rollup (one lead, the head, 51 blocked transactions) and mssql_block_findings each finish under
#     the pages' statement_timeout of 15 s.
# NOT PROVEN HERE: the checks this chain does not raise, whose rules are read and not run: a stored-procedure lead
# resolved to schema.procedure (check 9 is raised for this ad hoc head, run 8), repeatable read (4), the sleeping, background, done, compile-lock
# and application-lock groups of 6 (the head waits in a WAITFOR: suspended), the implicit-transaction and auto-stats groups of 7, non-lock reports (10); a page or
# RID lock's object; a report with several blocking processes; system_health's real monitorLoop value; reports stored
# before 0116; an object locked in another database than the waiting request's (D01's object_name prefix); Azure SQL and SQL Server 2016-2019; proof-a11y (its own script, run beside this one).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
: "${BLOCKVIEWER_SQL:?BLOCKVIEWER_SQL names sp_HumanEventsBlockViewer.sql}"
[ -f "$BLOCKVIEWER_SQL" ] || { echo "FAIL: no file $BLOCKVIEWER_SQL" >&2; exit 1; }
IMG_SQL=mcr.microsoft.com/mssql/server:2022-latest
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvb-sql-$SUF; HOSTN=pgvb$SUF; LBL=pgvigil-proof=s177d
PGDB=pgv_block_$SUF; MON=pgv_bmon_$SUF; USR=proofdba$SUF; XEID=p177d
fail() { echo "FAIL: $*" >&2; exit 1; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; CHRPID=; BG=()
SHOTS=${PGVIGIL_SHOTS:-$TMPD/shots}; mkdir -p "$SHOTS"
SA_PW=$(pw); MON_PW=$(pw); UPW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  if [[ -n "$CHRPID" ]]; then kill "$CHRPID" 2>/dev/null || true; wait "$CHRPID" 2>/dev/null || true; fi
  for p in "${BG[@]}"; do kill "$p" 2>/dev/null || true; done
  docker rm -f -v "$SQL" >/dev/null 2>&1 || { docker inspect "$SQL" >/dev/null 2>&1 && echo "CLEANUP: container $SQL not removed" >&2; }
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
# sq: T-SQL as sa (stdin, never a command line); sqok: output not wanted, a failure loud
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -W -h -1 -s "|" -d "$0" -i /dev/stdin' "${2:-master}"; }
sqok() { local out; out=$(sq "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
for t in docker go psql curl python3 node npm chromium git; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"

echo "== build: a copy of the tree with the wiring patch when present, the web bundle rebuilt =="
GSRC=$TMPD/src; mkdir -p "$GSRC"
tar -C . --exclude=./web/node_modules --exclude=./.lab --exclude=./.git --exclude=./.t177d -cf - . | tar -C "$GSRC" -xf -
P=scripts/proof-darling-blockhistory-join.patch
if [ ! -f "$GSRC/$P" ]; then
  grep -q BlockingTasksKey "$GSRC/internal/mssql/syshealth.go" || fail "build: no $P and syshealth.go does not hand over blockingTasks"
  echo "build: no $P in the tree: the release join carries it (the tree is used as it is)"
elif (cd "$GSRC" && git apply --check -R "$P" 2>/dev/null); then echo "build: $P is already in this tree"
elif (cd "$GSRC" && git apply "$P" 2>"$TMPD/apply.err"); then echo "build: $P applied to the run's copy"
else fail "build: $P neither applies nor is applied: $(cat "$TMPD/apply.err")"; fi
(cd "$GSRC/web" && npm ci --no-audit --no-fund >"$TMPD/web.log" 2>&1 && npm run build >>"$TMPD/web.log" 2>&1) || { tail -20 "$TMPD/web.log" >&2; fail "build: the web bundle"; }
(cd "$GSRC" && go build -o "$TMPD/pgvigil" ./cmd/pgvigil) || fail "build: go build"
BIN=$TMPD/pgvigil

echo "== A. a blocked chain on a SQL Server 2022 container, pgvigil's blocked session reading it =="
docker run -d --name "$SQL" --hostname "$HOSTN" --label "$LBL" --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
ready=
for _ in $(seq 1 90); do ready=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" 2>/dev/null || true); [[ "$ready" == 1 ]] && break; sleep 2; done
[[ "$ready" == 1 ]] || fail "A: the SQL Server container did not come up in 180 s"
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
sqok "A: the threshold" "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'blocked process threshold (s)', 5; RECONFIGURE;"
sqok "A: the database" "CREATE DATABASE pgvblock;"
sqok "A: the table" "CREATE TABLE dbo.pgvb_t (id int NOT NULL CONSTRAINT pk_pgvb_t PRIMARY KEY, pad char(200) NOT NULL DEFAULT 'a');
  INSERT dbo.pgvb_t (id) SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects;" pgvblock
sqok "A: the monitor login" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON];"
sqok "A: the monitor's user" "CREATE USER [$MON] FOR LOGIN [$MON]; GRANT VIEW DEFINITION TO [$MON];" pgvblock
"$BIN" mssql-xe -print -install-id "$XEID" > "$TMPD/xe.sql" || fail "A: mssql-xe -print"
# a script file through stdin (a file copied into the container keeps the run's 0600 mode: the mssql user cannot read it)
sqfile() { docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -d master -i /dev/stdin' < "$1"; }
sqfile "$TMPD/xe.sql" >"$TMPD/xe.out" 2>&1 || { cat "$TMPD/xe.out" >&2; fail "A: the session script"; }
XS=pgvigil_${XEID}_blocked
[[ "$(sq "SELECT COUNT(*) FROM sys.dm_xe_sessions WHERE name = N'$XS'")" == 1 ]] || fail "A: the session $XS is not running"
sqfile "$BLOCKVIEWER_SQL" >"$TMPD/bv.out" 2>&1 || { tail -5 "$TMPD/bv.out" >&2; fail "A: installing sp_HumanEventsBlockViewer"; }
BVV=$(grep -o "@version = '[0-9.]*'" "$BLOCKVIEWER_SQL" | head -1 | grep -o "[0-9.]*")
echo "A: sp_HumanEventsBlockViewer $BVV installed"
# the sessions: each a sqlcmd of its own, named by its host (-H); the head keeps its connection open and idle
sid() { sq "SELECT MIN(session_id) FROM sys.dm_exec_sessions WHERE host_name = '$1'"; }
sess() { printf '%s\n' "$2" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -d pgvblock -H "$0" -i /dev/stdin' "$1" >"$TMPD/s-$1.out" 2>&1 & BG+=($!); }
# what the server and the sessions say, on a failure of A
adump() { for h in pgvb_r1 pgvb_r2 pgvb_w; do echo "-- $h:"; cat "$TMPD/s-$h.out" 2>/dev/null; done
  sq "SELECT s.session_id, s.host_name, s.status, s.open_transaction_count, r.status, r.blocking_session_id, r.wait_type, r.wait_resource
        FROM sys.dm_exec_sessions s LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id WHERE s.host_name LIKE 'pgvb%'" 2>&1
  sq "SELECT request_session_id, resource_type, request_mode, request_status FROM sys.dm_tran_locks WHERE resource_database_id = DB_ID('pgvblock')" 2>&1; } >&2
# the head: one batch, its transaction held open by a WAITFOR (a transaction left open between two batches of one sqlcmd
# ended at once in run 3: the head's own row read open_transaction_count 0 while it stayed connected)
sess pgvb_h "BEGIN TRAN; UPDATE dbo.pgvb_t SET pad = 'h' WHERE id = 1; WAITFOR DELAY '00:20:00';"
for _ in $(seq 1 30); do H=$(sid pgvb_h); [[ "$H" =~ ^[0-9]+$ ]] && [[ "$(sq "SELECT COUNT(*) FROM sys.dm_tran_locks WHERE request_session_id = $H AND resource_type = 'KEY' AND request_mode = 'X'")" == 1 ]] && break; sleep 1; done
[[ "${H:-}" =~ ^[0-9]+$ ]] || fail "A: the head did not take its lock"
sess pgvb_r1 "SELECT pad FROM dbo.pgvb_t WHERE id = 1;"
sess pgvb_r2 "SELECT pad FROM dbo.pgvb_t WHERE id = 1;"
sess pgvb_w "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE; UPDATE dbo.pgvb_t SET pad = 'w' WHERE id = 1;"
for _ in $(seq 1 30); do n=$(sq "SELECT COUNT(*) FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.host_name IN ('pgvb_r1', 'pgvb_r2', 'pgvb_w') AND r.blocking_session_id > 0"); [[ "$n" == 3 ]] && break; sleep 1; done
[[ "${n:-0}" == 3 ]] || { adump; fail "A: $n of the 3 sessions wait"; }
[[ "$(sq "SELECT open_transaction_count FROM sys.dm_exec_sessions WHERE session_id = $H")" == 1 ]] || { adump; fail "A: the head's transaction is not open"; }
START=$(date -u +%Y-%m-%dT%H:%M:%SZ -d '-1 minute')
echo "ok   A: head $H holds its transaction open (WAITFOR); 3 sessions wait behind it"

PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
export PGV_B_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true"
cat > "$TMPD/b.yaml" <<EOF
repository:
  dsn: "$PGDSN"
instances:
  - name: sqlbox
    engine: sqlserver
    dsn: env:PGV_B_MON
EOF
"$BIN" migrate -config "$TMPD/b.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "A: migrate"; }
col() { "$BIN" collect -config "$TMPD/b.yaml" -instance sqlbox -once "$1" >"$TMPD/c-$1.out" 2>&1 || { cat "$TMPD/c-$1.out" >&2; fail "A: collect $1"; }; }
col mssql_requests; col mssql_waiting_tasks
sleep 15; col mssql_requests
sleep 15; col mssql_requests
sleep 5
sqok "A: the threshold back to 0" "EXEC sp_configure 'blocked process threshold (s)', 0; RECONFIGURE;"
sleep 12   # a report raised just before the change reaches the ring buffer (the session dispatches every 5 s)
col mssql_xe
# the cut: the server's clock just after pgvigil's read; the procedure reads up to it (it refuses to run with the threshold
# at 0, so the threshold goes back to 5 before it runs, and the reports raised after the cut are past its @end_date)
CUT=$(sq "SELECT CONVERT(varchar(27), SYSDATETIME(), 126)" | tail -1)
sqok "A: the threshold 5 again" "EXEC sp_configure 'blocked process threshold (s)', 5; RECONFIGURE;"
SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox'")
END=$(date -u +%Y-%m-%dT%H:%M:%SZ -d '+1 minute')
NREP=$(pq "SELECT count(*) FROM pgvigil.mssql_blocked_reports WHERE instance_id = $SB AND source = 'product'")
(( NREP >= 6 )) || fail "A: $NREP reports stored, want 6 or more"
NFULL=$(pq "SELECT count(*) FROM pgvigil.mssql_blocked_reports WHERE instance_id = $SB AND blocked_isolation IS NOT NULL AND blocked_transaction_name IS NOT NULL
             AND blocked_last_batch IS NOT NULL AND blocking_last_batch_completed IS NOT NULL AND transaction_id IS NOT NULL AND resource_owner_type IS NOT NULL")
[[ "$NFULL" == "$NREP" ]] || fail "A: $NFULL of $NREP reports carry the blocked side's isolation, transaction name and last batch, the blocking side's last batch completed, the event's transaction id and owner type"
# a <blocking-process> carries no transactionname (run 4; the repository's own fixture shows the same): the head's side is
# its status and its last batch completed
HEADROW=$(pq "SELECT DISTINCT blocking_status || '|' || (blocking_last_batch_completed IS NOT NULL) FROM pgvigil.mssql_blocked_reports WHERE instance_id = $SB AND blocking_spid = $H")
[[ "$HEADROW" == "suspended|true" ]] || fail "A: the head's side reads '$HEADROW', want suspended|true (status, a last batch completed)"
echo "ok   A: $NREP reports stored with both sides' columns; the head's side suspended with its last batch completed"

echo "== B. pgvigil.mssql_block_findings against sp_HumanEventsBlockViewer's own findings =="
# the procedure's output: its findings result set only (the rows whose first column is 'findings'; its header line, whose
# first column is named findings too, is skipped by its check_id); -y 0 keeps long text whole (sqlcmd refuses -h with it)
printf 'SET NOCOUNT ON;\nEXEC dbo.sp_HumanEventsBlockViewer @session_name = N'"'"'%s'"'"', @target_type = N'"'"'ring_buffer'"'"', @end_date = '"'"'%s'"'"', @skip_execution_plans = 1;\n' "$XS" "$CUT" \
  | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -y 0 -s "|" -d master -i /dev/stdin' >"$TMPD/bv-run.out" 2>&1 \
  || { tail -5 "$TMPD/bv-run.out" >&2; fail "B: the procedure"; }
norm() { python3 -c '
import re, sys
for line in sys.stdin:
    f = [re.sub(r"\s+", " ", x).strip() for x in line.rstrip("\n").split("|")]
    if f and f[0] == "findings": f = f[1:]
    if len(f) < 5 or f[0] in ("-1", "2147483647", "check_id") or set(f[0]) <= set("-"): continue
    f = ["" if x == "NULL" else x for x in f[:5]]
    print("|".join(f))' | sort; }
grep -a '^findings|' "$TMPD/bv-run.out" | norm > "$TMPD/bv.txt" || true
pq "SELECT check_id || '|' || coalesce(database_name, '') || '|' || coalesce(object_name, '') || '|' || finding_group || '|' || finding
      FROM pgvigil.mssql_block_findings($SB, '$START', '$END')" | norm > "$TMPD/pgv.txt"
NB=$(wc -l < "$TMPD/bv.txt")
(( NB >= 5 )) || { head -40 "$TMPD/bv-run.out" >&2; fail "B: the procedure gave $NB findings (want 5 or more)"; }
if ! diff "$TMPD/bv.txt" "$TMPD/pgv.txt" > "$TMPD/b.diff"; then
  echo "sp_HumanEventsBlockViewer:"; cat "$TMPD/bv.txt"; echo "pgvigil:"; cat "$TMPD/pgv.txt"; echo "diff:"; cat "$TMPD/b.diff"
  fail "B: the findings differ"
fi
for g in 'Database Locks' 'Object Locks' 'Blocking Involving Selects' 'Serializable Blocking' 'Top Lead Blocker' 'Total database block wait time' 'Total database and object block wait time'; do
  grep -qF "|$g|" "$TMPD/pgv.txt" || fail "B: no '$g' finding (the chain should raise it)"
done
grep -q '^2|pgvblock|dbo.pgvb_t|Object Locks|' "$TMPD/pgv.txt" || fail "B: the object finding does not name dbo.pgvb_t"
echo "ok   B: $NB findings, equal row for row:"; sed 's/^/       /' "$TMPD/pgv.txt"

echo "== C. the pairs of the minute snapshots and the trend through the API =="
PGVIGIL_PASSWORD="$UPW" "$BIN" user add -config "$TMPD/b.yaml" "$USR" >/dev/null 2>&1 || fail "C: user add"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$TMPD/b.yaml" -listen "127.0.0.1:$PORT" >"$TMPD/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.log" >&2; fail "C: serve exited"; }
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$TMPD/login.json"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "C: the UI login"
curl -s -b "$TMPD/cj" "$U/api/blocking/history?instance=$SB&from=$START&to=$END&part=pairs" > "$TMPD/pairs.json"
curl -s -b "$TMPD/cj" "$U/api/blocking/history?instance=$SB&from=$START&to=$END&part=trend" > "$TMPD/trend.json"
curl -s -b "$TMPD/cj" "$U/api/mssql/xe?instance=$SB&from=$START&to=$END" > "$TMPD/xe.json"
python3 - "$TMPD/pairs.json" > "$TMPD/api-pairs.txt" <<'EOF'
import json, sys
t = json.load(open(sys.argv[1]))["pairs"]
for r in t["rows"]:
    d = dict(zip(t["columns"], r)); print(f"{d['blocked_session_id']}|{d['blocking_session_id']}|{d['snapshots']}|{d['longest_wait_ms']}")
EOF
sort -o "$TMPD/api-pairs.txt" "$TMPD/api-pairs.txt"
pq "SELECT session_id || '|' || blocking_session_id || '|' || count(*) || '|' || max(wait_ms) FROM pgvigil.mssql_requests
     WHERE instance_id = $SB AND snapshot_at > '$START' AND snapshot_at <= '$END' AND blocking_session_id > 0 AND blocking_session_id <> session_id
     GROUP BY session_id, blocking_session_id" | sort > "$TMPD/db-pairs.txt"
NP=$(wc -l < "$TMPD/db-pairs.txt")
(( NP >= 3 )) || fail "C: the snapshots hold $NP pairs (want 3 or more)"
diff "$TMPD/api-pairs.txt" "$TMPD/db-pairs.txt" >/dev/null || { echo "API:"; cat "$TMPD/api-pairs.txt"; echo "store:"; cat "$TMPD/db-pairs.txt"; fail "C: the pairs differ"; }
read -r TREP TSUM <<<"$(python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["trend"]; c=t["columns"]; rs=[dict(zip(c,r)) for r in t["rows"]]; print(sum(int(r["reports"] or 0) for r in rs), max(int(r["summed_wait_ms"] or 0) for r in rs))' "$TMPD/trend.json")"
[[ "$TREP" == "$NREP" ]] && (( TSUM > 0 )) || fail "C: the trend's reports $TREP (want $NREP) and largest summed wait $TSUM (want more than 0)"
NHEADS=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["blocked"]["rows"]))' "$TMPD/xe.json")
NAPIF=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["block_findings"]["rows"]))' "$TMPD/xe.json")
[[ "$NAPIF" == "$(wc -l < "$TMPD/pgv.txt")" ]] || fail "C: the API's findings $NAPIF, the function's $(wc -l < "$TMPD/pgv.txt")"
# the lead rollup: the victims' wait belongs to the chain's head (the writer in the middle is not a lead), all of it
read -r NLEAD LEADOK LEADW DBW <<<"$(python3 -c '
import json, sys
t = json.load(open(sys.argv[1]))["block_rollup"]; rs = [dict(zip(t["columns"], r)) for r in t["rows"]]
lead = [r for r in rs if r["dimension"] == "lead"]; db = [r for r in rs if r["dimension"] == "database"]
print(len(lead), str(bool(lead) and str(lead[0]["name"]).startswith("BEGIN TRAN")).lower(), lead[0]["total_wait_ms"] if lead else -1, db[0]["total_wait_ms"] if db else -2)' "$TMPD/xe.json")"
[[ "$NHEADS" == 2 ]] || fail "C: $NHEADS head statement(s), want 2 (the head, and the writer the readers wait behind): without a session in the chain's middle the lead check below does not test the walk"
[[ "$NLEAD" == 1 && "$LEADOK" == true && "$LEADW" == "$DBW" ]] || fail "C: the lead rollup: $NLEAD lead(s), the head's statement $LEADOK, its wait $LEADW ms against the database's $DBW ms (want 1, true, equal)"
echo "ok   C: $NP pairs equal to the store's rows; the trend: $TREP reports, the largest summed wait ${TSUM} ms; $NHEADS head statement(s), $NAPIF findings"

echo "== D. system_health's blockingTasks where no capture of pgvigil runs =="
"$BIN" mssql-xe -print -drop -install-id "$XEID" > "$TMPD/xe-drop.sql" || fail "D: mssql-xe -print -drop"
sqfile "$TMPD/xe-drop.sql" >/dev/null 2>&1 || fail "D: dropping the sessions"
DSTART=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NSH=0
for i in $(seq 1 14); do
  col mssql_syshealth
  NSH=$(pq "SELECT count(*) FROM pgvigil.mssql_blocked_reports WHERE instance_id = $SB AND source = 'system_health'")
  (( NSH > 0 )) && break
  sleep 30
done
(( NSH > 0 )) || fail "D: no system_health report stored in about 7 minutes"
LEFT=$(pq "SELECT count(*) FROM pgvigil.mssql_health_components WHERE instance_id = $SB AND detail ? 'pgvigil_blocked_reports'")
[[ "$LEFT" == 0 ]] || fail "D: $LEFT component row(s) still carry the reports in their detail"
SHROW=$(pq "SELECT DISTINCT blocking_spid || '|' || coalesce(blocking_status, '') FROM pgvigil.mssql_blocked_reports WHERE instance_id = $SB AND source = 'system_health' AND blocking_spid = $H")
[[ "$SHROW" == "$H|suspended" ]] || fail "D: system_health's reports name the head as '$SHROW', want $H|suspended"
DEND=$(date -u +%Y-%m-%dT%H:%M:%SZ -d '+1 minute')
NSF=$(pq "SELECT count(*) FROM pgvigil.mssql_block_findings($SB, '$DSTART', '$DEND')")
(( NSF > 0 )) || fail "D: no finding over system_health's reports"
echo "ok   D: $NSH system_health report(s) stored (the head $H named), the detail without them; $NSF findings over them"

echo "== E. tests and lint on the run's copy =="
(cd "$GSRC" && go test -count=1 ./internal/mssql/ ./internal/web/ ./internal/repo/ >"$TMPD/test.out" 2>&1) || { tail -30 "$TMPD/test.out" >&2; fail "E: go test"; }
(cd "$GSRC" && golangci-lint run --allow-parallel-runners ./... >"$TMPD/lint.out" 2>&1) || { tail -30 "$TMPD/lint.out" >&2; fail "E: golangci-lint at the root"; }
(cd "$GSRC/app" && golangci-lint run --allow-parallel-runners ./... >"$TMPD/lint-app.out" 2>&1) || { tail -30 "$TMPD/lint-app.out" >&2; fail "E: golangci-lint in app/"; }
echo "ok   E: go test green; golangci-lint 0 issues at the root and in app/"

echo "== F. the pages in headless Chromium, every link clicked =="
CDP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu --window-size=1600,900 about:blank >"$TMPD/chrome.log" 2>&1 & CHRPID=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "F: chromium's CDP port never answered"
cat > "$TMPD/f.mjs" <<'JS'
// prints one line per check; the shell grades them
const [port, U, sb, shots, from, to] = process.argv.slice(2);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise }); if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300)); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const settled = async () => { for (let i = 0; i < 150; i++) { const ok = await ev(`(() => { const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector('p.empty'); return !(e && /^(Loading|Opening)/.test(e.textContent)) && m.children.length > 0 && !m.querySelector('.loading'); })()`); if (ok) { await sleep(600); return true; } await sleep(200); } return false; };
const go = async (hash) => { await cmd('Page.navigate', { url: U + hash }); await sleep(300); return settled(); };
const shot = async (name) => { const d = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }); fs.writeFileSync(`${shots}/${name}.png`, Buffer.from(d.result.data, 'base64')); };
// rows of the grid that follows a heading whose text starts with the given words
const gridRows = (head) => ev(`(() => { const m = document.querySelector('main'); const h = [...m.querySelectorAll('h2,h3,h4')].find(x => x.textContent.startsWith(${JSON.stringify(head)}));
  let g = h?.nextElementSibling; while (g && !g.querySelector('table') && g.tagName !== 'TABLE') g = g.nextElementSibling;
  return g ? [...g.querySelectorAll('tbody tr')].filter(tr => !tr.querySelector('.empty')).length : -1; })()`);
const state = () => ev(`(() => { const m = document.querySelector('main'); return JSON.stringify({ hash: location.hash, errors: m.querySelectorAll('.error:not([role=status])').length,
  h: (m.querySelector('h2')?.textContent ?? ''), links: [...m.querySelectorAll('a[href]')].map(a => ({ t: a.textContent.trim().slice(0, 60), h: a.getAttribute('href') })) }); })()`).then(JSON.parse);
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
const st = await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(process.env.F_USR)}, password: ${JSON.stringify(process.env.F_UPW)} }) }).then(r => r.status)`, true);
console.log(`login ${st}`);
const range = `&from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`;
const pages = { blocked: `#/mssql_blocked?i=${sb}${range}`, running: `#/mssql_running?i=${sb}${range}` };
for (const theme of ['light', 'dark']) {
  await go('#/about');
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
  if (!await go(pages.blocked)) { console.log(`FAIL render blocked ${theme}`); continue; }
  const s = await state();
  console.log(`page blocked ${theme} errors=${s.errors} heads=${await gridRows('Blocked reports')} findings=${await gridRows('Findings over the range')} lead=${await gridRows('Blocked wait by lead blocker')} object=${await gridRows('Blocked wait by object')}`);
  await shot(`blocked-${theme}`);
  // the first head opened: the panel (in place, below the grid) shot alone, clipped to its box
  await ev(`[...document.querySelectorAll('main button.link')].find(b => b.textContent.trim() === 'Open')?.click(); 'ok'`);
  for (let k = 0; k < 50 && !(await ev(`!!document.querySelector('main section.detail tbody tr:not(:has(.empty))')`)); k++) await sleep(200);
  await sleep(400);
  const box = JSON.parse(await ev(`(() => { const b = document.querySelector('main section.detail')?.getBoundingClientRect(); return JSON.stringify(b ? { x: b.left + scrollX, y: b.top + scrollY, w: b.width, h: b.height } : null); })()`));
  if (box && box.h > 0) {
    const pd = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip: { x: box.x, y: box.y, width: box.w, height: box.h, scale: 1 } });
    fs.writeFileSync(`${shots}/blocked-open-${theme}.png`, Buffer.from(pd.result.data, 'base64'));
  }
  console.log(`shot blocked-open ${theme} panel=${box ? `${Math.round(box.w)}x${Math.round(box.h)}` : 'none'}`);
  if (!await go(pages.running)) { console.log(`FAIL render running ${theme}`); continue; }
  const r = await state();
  console.log(`page running ${theme} errors=${r.errors} pairs=${await gridRows('Who blocked whom')}`);
  await shot(`running-blocking-${theme}`);
}
// every link of both pages: its landing and whether the page it lands on renders without an error box
for (const [name, hash] of Object.entries(pages)) {
  await go(hash); const s = await state();
  const seen = new Set();
  for (const l of s.links) {
    if (seen.has(l.h)) continue; seen.add(l.h);
    if (!l.h.startsWith('#/')) { console.log(`click ${name} ${JSON.stringify(l.t)} -> ${l.h} (not followed: off the page)`); continue; }
    const ok = await go(l.h); const f = await state();
    console.log(`click ${name} ${JSON.stringify(l.t)} -> ${f.hash.split('?')[0]} (${f.h}) rendered=${ok} errors=${f.errors} at=${new URLSearchParams(f.hash.split('?')[1] ?? '').get('at') ?? '-'}`);
    await go(hash);
  }
}
// the Blocked reports grid's Open buttons (a head's reports into the panel below the grid, in place): each one clicked on
// a fresh render of the page (a navigation to the same address keeps the page, and the panel the last click filled: run 12)
const openBtns = `[...document.querySelectorAll('main button.link')].filter(b => b.textContent.trim() === 'Open')`;
await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200); await go(pages.blocked);
const nOpen = await ev(`${openBtns}.length`);
for (let i = 0; i < nOpen; i++) {
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
  await go(pages.blocked);
  // the head's own row, read before the click: its blocking session and its report count
  const head = JSON.parse(await ev(`(() => { const b = ${openBtns}[${i}]; const tr = b.closest('tr');
    const hs = [...tr.closest('table').querySelectorAll('thead th')].map(th => th.textContent.replace(/[\u25be\u25b4\u25bc\u25b2]/g, '').trim());
    const c = k => tr.children[hs.indexOf(k)]?.textContent.trim() ?? ''; b.click(); return JSON.stringify({ spid: c('blocking session'), reports: c('reports') }); })()`));
  let r = null;
  for (let k = 0; k < 50; k++) {
    r = JSON.parse(await ev(`(() => { const p = document.querySelector('main section.detail'); const trs = p ? [...p.querySelectorAll('tbody tr')].filter(tr => !tr.querySelector('.empty')) : [];
      const hs = p ? [...p.querySelectorAll('thead th')].map(th => th.textContent.replace(/[\u25be\u25b4\u25bc\u25b2]/g, '').trim()) : [];
      const col = k => { const j = hs.indexOf(k); return j < 0 ? [] : [...new Set(trs.map(tr => tr.children[j].textContent.trim()))]; };
      return JSON.stringify({ rows: trs.length, object: col('object').join(',') || '-', spids: col('blocking session').join(',') || '-', errors: p ? p.querySelectorAll('.error').length : -1, hash: location.hash }); })()`));
    if (r.rows > 0 || r.errors > 0) break; await sleep(200);
  }
  console.log(`click blocked Open#${i + 1} -> panel in place (${r.hash.split('?')[0]}) rows=${r.rows} of=${head.reports || '-'} session=${r.spids} head=${head.spid || '-'} object=${r.object} errors=${r.errors}`);
}
if (nOpen === 0) console.log('click blocked Open none');
// the Running tab shows the snapshot at= names: the pair link's own (the pairs' last), then the pairs' first by the same
// address with at= changed (the newest snapshot of the range would show either way without at=)
{
  const mainText = () => ev(`document.querySelector('main')?.textContent ?? ''`);
  const snapAt = t => ((t.match(/Snapshot (\d+\/\d+\/\d+, \d\d:\d\d:\d\d)/) ?? [])[1] ?? '-').slice(-8);
  const firstIso = (process.env.F_FIRST ?? '').replace(' ', 'T') + 'Z';
  await go(pages.running); const s = await state();
  const l = s.links.find(x => x.h.startsWith('#/mssql_running') && /[?&]at=/.test(x.h));
  if (l) {
    const lastIso = new URLSearchParams(l.h.split('?')[1]).get('at') ?? '';
    await go(l.h); const shownLast = snapAt(await mainText());
    await go(l.h.replace(/([?&]at=)[^&]*/, `$1${encodeURIComponent(firstIso)}`)); const shownFirst = snapAt(await mainText());
    console.log(`at running last=${lastIso.slice(11, 19)} shown=${shownLast} first=${firstIso.slice(11, 19)} shown=${shownFirst}`);
  } else console.log('at running none');
}
ws.close(); process.exit(0);
JS
FIRSTAT=$(pq "SELECT min(first_at) AT TIME ZONE 'UTC' FROM pgvigil.mssql_block_pairs($SB, '$START', '$DEND')")
out=$(F_USR="$USR" F_UPW="$UPW" F_FIRST="$FIRSTAT" node "$TMPD/f.mjs" "$CDP" "$U/" "$SB" "$SHOTS" "$START" "$DEND") || fail "F: the Chromium walk stopped: $out"
echo "$out"
echo "$out" | grep -q '^login 200$' || fail "F: the UI login in Chromium"
! echo "$out" | grep -q '^FAIL' || fail "F: a page did not render"
NHALL=$(pq "SELECT count(DISTINCT head_key) FROM pgvigil.mssql_blocked_reports WHERE instance_id = $SB AND event_at > '$START' AND event_at <= '$DEND' AND source = 'product'")
NFALL=$(pq "SELECT count(*) FROM pgvigil.mssql_block_findings($SB, '$START', '$DEND')")
NPALL=$(pq "SELECT count(*) FROM pgvigil.mssql_block_pairs($SB, '$START', '$DEND')")
for theme in light dark; do
  echo "$out" | grep -q "^page blocked $theme errors=0 heads=$NHALL findings=$NFALL " || fail "F: the Blocked reports page ($theme): $(echo "$out" | grep "^page blocked $theme") (want heads $NHALL, findings $NFALL)"
  echo "$out" | grep -q "^page running $theme errors=0 pairs=$NPALL$" || fail "F: the Running page's pairs ($theme): $(echo "$out" | grep "^page running $theme") (want $NPALL)"
done
! echo "$out" | grep '^click ' | grep -v 'not followed' | grep -v '^click blocked Open#' | grep -qv 'rendered=true errors=0' || fail "F: a link landed on a page with an error: $(echo "$out" | grep '^click ' | grep -v '^click blocked Open#' | grep -v 'rendered=true errors=0' | head -3)"
echo "$out" | grep '^click running ' | grep -q -- '-> #/mssql_running (.*) rendered=true errors=0 at=20' || fail "F: a pair's 'last seen' does not land on a Running snapshot with at="
NOPEN=$(echo "$out" | grep -c '^click blocked Open#' || true)
[[ "$NOPEN" == "$NHALL" ]] || fail "F: $NOPEN Open button(s) clicked, the grid has $NHALL head(s)"
# each panel is its own head's reports: as many rows as the head's row counts, every row blocked by that head's session
OPENRE='rows=([0-9]+) of=([0-9]+) session=([0-9]+) head=([0-9]+) object=([^ ]+) errors=(-?[0-9]+)$'
while IFS= read -r line; do
  [[ "$line" =~ $OPENRE ]] || fail "F: an Open line out of shape: $line"
  [[ "${BASH_REMATCH[1]}" != 0 && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" && "${BASH_REMATCH[3]}" == "${BASH_REMATCH[4]}" && "${BASH_REMATCH[5]}" == dbo.pgvb_t && "${BASH_REMATCH[6]}" == 0 ]] \
    || fail "F: an Open panel is not its head's reports: $line (want rows = of > 0, session = head, object dbo.pgvb_t, errors 0)"
done < <(echo "$out" | grep '^click blocked Open#')
for theme in light dark; do
  echo "$out" | grep -q "^shot blocked-open $theme panel=[0-9]" && [[ -s "$SHOTS/blocked-open-$theme.png" ]] || fail "F: no shot of an opened head's panel ($theme): $(echo "$out" | grep "^shot blocked-open $theme")"
done
SUMOPEN=$(echo "$out" | sed -n 's/^click blocked Open#.* rows=\([0-9]*\) .*/\1/p' | awk '{ n += $1 } END { print n + 0 }')
NRALL=$(pq "SELECT count(*) FROM pgvigil.mssql_blocked_reports WHERE instance_id = $SB AND event_at > '$START' AND event_at <= '$DEND' AND source = 'product'")
[[ "$SUMOPEN" == "$NRALL" ]] || fail "F: the Open panels hold $SUMOPEN report(s), the store $NRALL"
ATRE='^at running last=([0-9:]{8}) shown=([0-9:]{8}) first=([0-9:]{8}) shown=([0-9:]{8})$'
ATL=$(echo "$out" | grep '^at running ' || true)
[[ "$ATL" =~ $ATRE && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" && "${BASH_REMATCH[3]}" == "${BASH_REMATCH[4]}" && "${BASH_REMATCH[1]}" != "${BASH_REMATCH[3]}" ]] \
  || fail "F: the Running tab does not show the snapshot at= names: '$ATL' (want shown = last, shown = first, first before last)"
echo "ok   F: $ATL"
echo "ok   F: both pages in light and dark (heads $NHALL, findings $NFALL, pairs $NPALL as the store), $(echo "$out" | grep -c '^click ') link(s) clicked, each landing named; shots in $SHOTS"
echo "== G. the findings and the rollup over a seeded convoy, inside the pages' statement timeout =="
# 120 monitor loops of one chain: head 51 <- writer 52 <- 50 readers (6,120 reports), in a window of its own after every
# real report; the pages' pool runs with statement_timeout 15 s (internal/web/web.go)
GFROM=$(date -u +%Y-%m-%dT%H:%M:%SZ -d '+2 hours'); GTO=$(date -u +%Y-%m-%dT%H:%M:%SZ -d '+3 hours')
pq "SELECT pgvigil.mssql_event_partition('mssql_blocked_reports', '$GFROM'::timestamptz), pgvigil.mssql_event_partition('mssql_blocked_reports', '$GTO'::timestamptz)" >/dev/null
pq "INSERT INTO pgvigil.mssql_blocked_reports (instance_id, event_at, event_key, snapshot_at, database_name, wait_resource, wait_ms, lock_mode,
      blocked_spid, blocked_ecid, blocked_statement, blocked_login, blocked_host, blocked_program, blocked_isolation, blocked_status,
      blocking_spid, blocking_ecid, blocking_statement, blocking_login, blocking_host, blocking_program, blocking_status, blocking_sql_handle,
      head_key, monitor_loop, transaction_id, blocked_wait_ms, resource_owner_type, source)
    SELECT $SB, '$GFROM'::timestamptz + make_interval(secs => l * 5), 'pgvb-g-' || l || '-' || v, now(), 'pgvblock',
           'KEY: 5:72057594045726720 (8194443284a0)', l * 5000, CASE WHEN v = 0 THEN 'X' ELSE 'S' END,
           CASE WHEN v = 0 THEN 52 ELSE 100 + v END, 0, CASE WHEN v = 0 THEN 'G WRITER' ELSE 'G READER' END, 'sa', 'g_h', 'G',
           'read committed (2)', 'suspended',
           CASE WHEN v = 0 THEN 51 ELSE 52 END, 0, CASE WHEN v = 0 THEN 'G HEAD STATEMENT' ELSE 'G WRITER' END, 'sa', 'g_h', 'G',
           'suspended', '0x0200', md5(CASE WHEN v = 0 THEN 'G HEAD STATEMENT' ELSE 'G WRITER' END), 1000000 + l, 900000 + v, l * 5000,
           'LOCK', 'product'
      FROM generate_series(1, 120) l, generate_series(0, 50) v"
gtime() { local t0 t1 res; t0=$(date +%s%N); res=$(PGOPTIONS='-c statement_timeout=15000' pq "$1" 2>&1) || { echo "ERR ${res//$'\n'/ }"; return 0; }; t1=$(date +%s%N); echo "$(( (t1 - t0) / 1000000 )) $res"; }
read -r GMSR GLEAD <<<"$(gtime "SELECT count(*) FILTER (WHERE dimension = 'lead') || ':' || string_agg(CASE WHEN dimension = 'lead' THEN name || '|' || blocked_sessions || '|' || reports END, ',') FROM pgvigil.mssql_block_rollup($SB, '$GFROM', '$GTO')")"
read -r GMSF GNF <<<"$(gtime "SELECT count(*) FROM pgvigil.mssql_block_findings($SB, '$GFROM', '$GTO')")"
pq "DELETE FROM pgvigil.mssql_blocked_reports WHERE instance_id = $SB AND event_key LIKE 'pgvb-g-%'" >/dev/null
[[ "$GMSR" =~ ^[0-9]+$ && "$GLEAD" == "1:G HEAD STATEMENT|51|6120" ]] || fail "G: the rollup over 6,120 reports: '$GMSR $GLEAD' (want under 15 s, one lead 'G HEAD STATEMENT' with 51 blocked transactions and 6120 reports)"
[[ "$GMSF" =~ ^[0-9]+$ && "$GNF" =~ ^[1-9][0-9]*$ ]] || fail "G: the findings over 6,120 reports: '$GMSF $GNF' (want under 15 s, some findings)"
echo "ok   G: 6,120 seeded reports (one chain, 120 monitor loops): the rollup in $GMSR ms (one lead, the head, 51 blocked transactions), the findings in $GMSF ms ($GNF), both under the pages' 15 s"
echo "proof-darling-blockhistory: OK (the reports with sp_HumanEventsBlockViewer's columns; its findings equal over the same capture; the pairs equal to the store; system_health's blockingTasks stored without a capture; the pages and their links in Chromium)"
