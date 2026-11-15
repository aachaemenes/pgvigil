#!/usr/bin/env bash
# Proof of task 406 (B12): Query Store and plans. One SQL Server container per run (MSSQL_IMAGE; the box job runs it
# once per version: 2017, 2019, 2022, 2025), a repository database of its own, pgvigil built from this tree.
# Needs: docker, go, psql, curl, python3, and:
#   ADMIN_DSN            a superuser connection to a PostgreSQL sandbox in KEYWORD form (default 'host=127.0.0.1
#                        port=5432 user=postgres dbname=postgres'); the proof makes its own repository database and
#                        drops it.
#   MSSQL_IMAGE          the SQL Server image (default mcr.microsoft.com/mssql/server:2022-latest)
#   PGVIGIL_PLAN_EXTRACT the plan plugin's extract.py (default .lab/extract.py, git-ignored; never fetched): the
#                        .sqlplan check of part B
#   PGVIGIL_PARTS        the parts to run (default every part this file has)
#   PGVIGIL_WIRING       1 (default) applies scripts/proof-mssql-qs-plans-wiring.patch (web.go: the lead's file) to
#                        this copy when the tree has the handlers and web.go lacks their routes; 0 = the tree as it is.
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment.
#
# Expected (written before the first run):
#  A. the container: a monitor login (VIEW SERVER STATE, VIEW ANY DEFINITION, an msdb reader), database pgvqs with
#     dbo.t (5,000 rows), procedure dbo.p_two (two statements), dbo.p_enc WITH ENCRYPTION, a workload run; three
#     instances of the config on the one server: sqlfull (query_text full), sqlnone (none), sqlnorm (normalized);
#     mssql_plancache read twice for sqlfull and once each for the other two.
#  B. a cached plan by handle, on demand (rows O4b.10, F1, F4, F8):
#     B1 GET /api/mssql/plancache/entries for p_two's first statement (database id and query key) lists the cache
#        entry whose plan handle, start and end offsets and plan hash equal a hand read of sys.dm_exec_query_stats;
#        fetch_off '' on sqlfull;
#     B2 GET /api/mssql/plancache/plan at those offsets with the row's hash: state ok, plan_hash = the hand read's
#        query_plan_hash, objtype Proc, object dbo.p_two, the XML's root ShowPlanXML with one StmtSimple whose text is
#        the first statement's (not the second's); the file name ends .sqlplan; extract.py reads the saved file
#        (exit 0) and its digest names dbo.t; the batch read (0, -1) holds both statements;
#     B3 the same read with hash 0x1234: state changed, the words naming both hashes;
#     B4 p_enc's entry: state encrypted, no plan in the reply;
#     B5 the shell of a simple-parameterized statement (its handle read by hand from sys.dm_exec_cached_plans):
#        state parameterized, no plan;
#     B6 under full, a statement carrying PASSWORD = '<secret>' in a comment: the reply's plan holds '<masked>' and not
#        the secret and still parses as XML (when the raw showplan read by hand carries it; else NOT PROVEN with why);
#     B7 sqlnone and sqlnorm: entries' fetch_off names the policy ("none" / "normalized"), the plan read answers state
#        off with the same words and no plan;
#     B8 a handle evicted by hand (DBCC FREEPROCCACHE as sa) answers 404 with the 'no plan under this handle' words;
#     B9 a handle of odd length, one of 65 bytes, a bad key, an end before the start: 400 each;
#     B10 after the reads no session of the read login named pgvigil-plan stays open (each read closes its connection).
#     B11 every read above wrote its custom_report_log row first (op plan_read, done, the UI user, door file, the handle;
#        no row holds a plan); sqlsa (the read login is sa, a sysadmin) gets the plan (ok) and its row (task 406's FOLD);
#     B12 a serve with -no-login (no audit door): the read answers off, 'needs a signed-in user', no plan; the server's
#        Logins/sec count moves by the hand read's own login only, no plan_read row added; B12b signed in, the config's
#        repository login a reader (the actions log not writable: the audit off) and B12c a collector the audit function
#        import_custom_report_run was taken from: the read off with the words, the entries' fetch_off the same, nothing
#        sent, no row (NOT PROVEN when the cluster has no pgvigil roles).
#     Red on f8e89d2: the two routes do not exist (B1 is not a JSON reply with entries).
#  C. the plans of running queries (rows N55 and SQLWATCH COL#27's capture, F6, F7, F18 P1); instances rpon (schedules:
#     mssql_running_plans and mssql_live_plans 1m), rpoff (no schedules), rpnone (query_text none, schedules on):
#     C1 one case per threshold, each alone, read by 'collect -once mssql_running_plans -instance rpon' while it runs:
#        a statement blocked 12 s (reasons 'duration'), a CPU-bound statement read at 3 s ('cpu'), two sessions blocked
#        on one plan for 3 s ('count'), a sort over dbo.big blocked while it holds its memory grant ('grant', when the
#        grant read by hand is 50 MB or more; else NOT PROVEN with the grant read); each row's key equals the hand read
#        of sys.dm_exec_requests (query hash, plan hash, offsets), its plan stored (plan_state read, ShowPlanXML);
#     C2 below every threshold (one session blocked 2 s, little CPU, a small grant): no row; the blocker's WAITFOR
#        (a zero plan hash): no row with plan hash 0x0000000000000000;
#     C3 rpnone (query_text none) during the 12 s block: its row stored with plan_state 'policy' and no plan;
#     C4 GET /api/mssql/runningplans lists rpon's rows with their reasons; /runningplans/plan returns the duration case's
#        ShowPlanXML (extract.py reads it); rpnone's answers state none with the policy words;
#     C5 live plan: on a build LivePlanBuildOK passes and SQL Server 2019 or later, a CPU-bound statement read past 61 s
#        of CPU by 'collect -once mssql_live_plans': one mssql_live_plan row whose XML holds RunTimeCountersPerThread; on
#        2017 (CU26 or later) with trace flag 7412 off: no row and mssql_live_read's note names trace flag 7412;
#     C6 the switch under 'pgvigil run' with the wiring applied (review B2, the lead 17:5x): rppage added on Admin >
#        Instances, then the upgrade (running_plans dropped, 0157 run again): its box false (R1); rppage2 and rppage3 added
#        after: false (R2); the box on rpon (a file instance) refused naming pgvigil.yaml; rppage3 ticked (an admin_audit
#        row): under pgvigil run rpon and rppage3 store the blocked statement's plan, rppage, rppage2 and rpoff run no
#        mssql_running_plans (R3); rppage3's box cleared while it runs: no read of it starts 20 s past that (R5), rpon
#        reads on; the global schedules: mssql_running_plans: 0 in the file: ticked rppage3 runs none, rpon (its own
#        schedules:) runs (R4).
#     C7 SQLWATCH COL#27, a slow or long-wait event's plan by its hashes: GET /api/mssql/plansources for the duration
#        case (pgvqs, its query hash and plan hash) lists its running capture (has_plan) and its plan cache entry after a
#        plan cache read, and the running capture's plan reads as ShowPlanXML; a plan hash no plan has lists none.
#     C8 rpon's query_text full -> none, then its read: no plan or live plan kept (plan_state policy); serve again: the
#        running and live plan reads answer none with the policy's words, no plan (review B1).
#     C9 purge(30) (0190's line in the wiring): a running plan, a live capture, a plan statistic and a forced-plan failure
#        aged 40 days (an aged row inserted where the table has none) gone, the rest kept; pgvigil_reader may not EXECUTE
#        mssql_qs_plans_purge or mssql_plans_policy_drop (NOT PROVEN without the role) (review finding 6).
#     Red on f8e89d2: no such collection (collect -once refuses mssql_running_plans).
#  D. the statistics a plan was compiled with (PerformanceMonitor 3.13 Added 1, F10, P5), database pgvqs2 with Query Store
#     on: four tables of 20,000 rows, each with a statistic on v made WITH FULLSCAN, 30 % of rows changed, then one query
#     each read through mssql_querystore (and mssql_indexes for the rows):
#     D0 AUTO_UPDATE_STATISTICS on, synchronous: the statistic is updated before the compile: stale_at_compile false;
#     D1 AUTO_UPDATE_STATISTICS off: stale true; D2 on with ASYNC: stale true (the compile uses the old statistic);
#     D3 on, the statistic made WITH NORECOMPUTE: stale true;
#     each row's modification_count equals the plan's own StatisticsInfo read by hand from sys.query_store_plan, table
#     rows 20,000, the auto-update line min(4,500, sqrt(1000 x 20,000)) = 4,472; the finding 'a plan compiled on stale
#     statistics' names D1-D3's plans and not D0's; GET /api/mssql/planstats answers D1's rows.
#     On a server whose plans carry no OptimizerStatsUsage (before 2017 / 2016 SP2) D is NOT PROVEN, said so.
#     Red on f8e89d2: no mssql_plan_stat table.
#  E. a forced plan's failures (PerformanceMonitor 3.13 Changed 15, F9, P6), in pgvqs2: a query (OPTION (RECOMPILE)) whose
#     plan seeks ix_f is forced, ix_f dropped, then each run is one failure; mssql_querystore read after each step:
#     E1 one failure in one read: the finding 'a forced plan fails' is info, its detail 'Held: it failed once';
#     E2 two more failures in the next read (one read saw 2): warning, 'one read saw 2 or more';
#     E3 the plan forced anew (count back to 0): a reset row; one failure after it: info again (a new window);
#     E4 one more failure in the next read: warning, 'two within 24 hours';
#     E5 every row before E4's failure moved 25 h back in the repository (the reset too, so E3's failure stays in the
#        window): two failure reads, not paged, info 'Held: no two of its 2 failures ... (read <E4's read> UTC)';
#     GET /api/mssql/forcefail lists the plan with its reads.
#     Red on f8e89d2: no mssql_qs_force_fail table; 'a forced plan fails' is a warning at E1.
#  F. one statement on every instance, statements by their text (PerformanceMonitor 3.13 Added 14, 15, 16; F13, F14,
#     P7, P8), a second container (instance f2) beside the first (sqlfull):
#     F1 a statement run 3 times on the first (in pgvqs, and twice in pgvqs2 under Query Store) and 5 on the second
#        between two plan cache reads: GET /api/mssql/everywhere for its query hash lists sqlfull's plan cache (3),
#        sqlfull's Query Store (2) and f2's plan cache (5) executions, each equal to the server's own count read by hand
#        (sys.dm_exec_query_stats execution_count; sys.query_store_runtime_stats count_executions), the CPU within
#        1 ms of total_worker_time / 1000;
#     F2 GET /api/mssql/search?q=marker%_x finds the statement on sqlfull and f2 (plan cache), each row's key = the
#        hash; q=marker__x finds nothing (% and _ taken as they are); sqlnone is named under no_text and sqlnorm under
#        normalized; with instance=f2 only f2's rows;
#     F3 text_indexes: both absent; after the DBA's statements (CREATE EXTENSION pg_trgm; CREATE INDEX CONCURRENTLY
#        mssql_pc_text_query_trgm ... gin_trgm_ops) the plan cache's is present, valid and ready, and the search still
#        finds the statement;
#     F4 no note while the repository holds no PostgreSQL instance; after one is registered the replies carry the
#        'PostgreSQL instances are not compared or searched here' note.
#     F5 the policy NOW (j15's fix review finding 4): sqlfull's query_text set full -> none and serve again, its stored
#        texts still in the repository (a policy change clears neither the plan cache's texts nor the Query Store's: a
#        text goes only when its key is sent again): the search returns no row of sqlfull from either source, names
#        sqlfull under no_text, and instance=sqlfull returns no row; f2's rows still come. Set back to full after.
#        Red on 92fc66cd: sqlfull's stored rows come back while no_text names it.
#     Red on f8e89d2: the routes do not exist.
#  G. the STATISTICS IO / TIME reader (DBA Dash N62-N67, F11, P9): web/src/mssql_statsio.ts compiled by esbuild; its unit
#     tests (web/src/mssql_statsio.test.mjs: sqlcmd, SSMS and Azure Data Studio shapes, a German text, the
#     DBADash-Compare runs, temporary tables, the save round trip) all ok; then a messages file captured on the box
#     (sqlcmd, SET STATISTICS IO, TIME ON, NOCOUNT OFF, two statements at MAXDOP 1): the reader's logical reads and
#     rows per statement equal the server's last_logical_reads and last_rows (sys.dm_exec_query_stats).
#     Red on f8e89d2: no web/src/mssql_statsio.ts.
#  H. evict one plan through the actions door (Opserver O4b.13, F2-F5, F16, F17, P4); actions logins: one with
#     EXECUTE on the certificate-signed master.dbo.pgvigil_evict_plan (docs/sqlserver-actions.md's script, as is), one
#     with ALTER SERVER STATE, one with nothing, one sysadmin; instances ev_signed, ev_off (plan_evict not on its list),
#     ev_noright, ev_sa, ev_none (query_text none), ev_direct; the plan of dbo.p_two read by hand:
#     H1 ev_off: preview not ok, 'not on the instance's actions: list'; H2 a handle of odd length: the preview says
#        'plan_handle: ...', the run is refused (409) before any connection; H3 p_two's SQL handle: 'no plan under this
#        handle'; H4 ev_noright: failed (502) with the server's own message, the plan still cached; H5 ev_sa: refused,
#        'sysadmin or holds CONTROL SERVER'; H6 a compile time other than the one shown: refused, 'another plan under
#        this handle'; H7 ev_none's preview: no batch text, a note naming the policy 'none'; H10 two plans of p_two (ARITHABORT ON and
#        OFF) get two codes in the preview; '00000000' and the other plan's code are refused ('typed confirmation'),
#        both plans still cached;
#     H8 ev_signed: the preview says Proc dbo.p_two in pgvqs, 2 statements, the signed procedure's route, and the plan's
#        code = the first 8 hex digits of SHA-256 over the handle (computed here); the run with that code (lower case):
#        done, 'gone from the cache'; the plan absent by hand, the other plan of p_two still cached; its actions_log row
#        (plan_evict, done, target 'Proc dbo.p_two in pgvqs', target_id the handle); H9 the same handle again: refused;
#     H11 the route is the actions login's own right (review 20261114-183110 finding 1): ev_direct (ALTER SERVER STATE, no
#        EXECUTE) while the procedure exists: preview 'direct', DBCC FREEPROCCACHE itself, done, gone; H13 ev_rd, whose
#        read login lacks VIEW ANY DEFINITION (it cannot see the procedure): preview 'signed procedure', the EXEC, done;
#        H11b the procedure dropped: ev_signed's preview 'direct', ev_direct done again;
#     H12 GET actions/state: ev_signed's actions login may EXECUTE the procedure and holds neither VIEW nor ALTER SERVER
#        STATE; ev_direct's holds both.
#     Red on f8e89d2: the gate refuses the action (400 'action must be one of kill, job_start, job_stop').
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
# the proof's own logins connect where ADMIN_DSN does, never at a fixed port: ADMIN_DSN itself with user, password and
# dbname appended (a repeated keyword's last value wins in libpq and pgx), so its host, port, service and ssl settings
# all carry over
IMG_SQL=${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
EXTRACT=${PGVIGIL_PLAN_EXTRACT:-.lab/extract.py}
PARTS=${PGVIGIL_PARTS:-ABCDEFGH}
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvqs-sql-$SUF; SQL2=pgvqs-sql2-$SUF; LBL=pgvigil-proof=406
PGDB=pgv_qs_$SUF; MON=pgv_qmon_$SUF; USR=proofdba$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
part() { [[ "$PARTS" == *"$1"* ]]; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; RUNPID=; BG=()
SA_PW=$(pw); MON_PW=$(pw); UPW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  [[ -n "$RUNPID" ]] && kill "$RUNPID" 2>/dev/null || true
  for p in "${BG[@]}"; do kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true; done
  docker rm -f -v "$SQL" >/dev/null 2>&1 || { docker inspect "$SQL" >/dev/null 2>&1 && echo "CLEANUP: container $SQL not removed" >&2; }
  docker rm -f -v "$SQL2" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
for t in docker go psql curl python3 setsid; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
[[ -s "$EXTRACT" ]] || fail "needs $EXTRACT (the plan plugin's extract.py)"
if [[ "${PGVIGIL_WIRING:-1}" == 1 ]] && grep -q 'func (s \*Server) MSSQLPlanCachePlan' internal/web/*.go && ! grep -q 'mssql/plancache/plan' internal/web/web.go; then
  git apply scripts/proof-mssql-qs-plans-wiring.patch 2>/dev/null || patch -p1 < scripts/proof-mssql-qs-plans-wiring.patch >/dev/null || fail "the wiring patch"
  echo "wiring applied to this copy (web.go)"
fi

echo "== A. the container ($IMG_SQL) =="
docker run -d --name "$SQL" --label "$LBL" --memory 6g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
SQLCMD=
for _ in $(seq 1 60); do
  for c in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do docker exec "$SQL" test -x "$c" 2>/dev/null && SQLCMD=$c && break 2; done
  sleep 1
done
[[ -n "$SQLCMD" ]] || fail "A: no sqlcmd in the image"
TRUST=; [[ "$SQLCMD" == *tools18* ]] && TRUST=-C
# sq: T-SQL as sa (stdin; -I: QUOTED_IDENTIFIER ON); sqok: loud
sq() { printf 'SET NOCOUNT ON;\nGO\n%s\n' "$1" | timeout "${3:-120}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa '"$TRUST"' -b -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
# sqbig: the same for one long value (a showplan): no column width cut (-y 0; sqlcmd takes neither -W nor -h with it)
sqbig() { printf 'SET NOCOUNT ON;\nGO\n%s\n' "$1" | timeout 120 docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa '"$TRUST"' -b -I -y 0 -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
sqok() { local out; out=$(sq "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
up() { local r=; for _ in $(seq 1 150); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" master 15 2>/dev/null || true); [[ "$r" == 1 ]] && return 0; sleep 2; done
  docker logs --tail 40 "$SQL" >&2 2>&1 || true; fail "A: the SQL Server container did not come up in 300 s"; }
up
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
VER=$(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))")
sqok "A: the monitor login (docs/sqlserver.md's)" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON]; GRANT CONNECT ANY DATABASE TO [$MON];"
sqok "A: the monitor's msdb user" "CREATE USER [$MON] FOR LOGIN [$MON]; ALTER ROLE db_datareader ADD MEMBER [$MON];" msdb
sqok "A: the database" "CREATE DATABASE pgvqs; ALTER DATABASE pgvqs SET RECOVERY SIMPLE;"
sqok "A: the table" "CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, a int NOT NULL, pad char(100) NOT NULL DEFAULT 'p');
  INSERT dbo.t (id, a) SELECT TOP (5000) n, n FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects x CROSS JOIN sys.all_objects y) z;
  CREATE INDEX ix_a ON dbo.t (a) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE);" pgvqs
sqok "A: dbo.big (the grant case of C)" "CREATE TABLE dbo.big (id int NOT NULL PRIMARY KEY, pad char(100) NOT NULL);
  INSERT dbo.big (id, pad) SELECT TOP (600000) n, CONVERT(char(100), NEWID()) FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects x CROSS JOIN sys.all_objects y CROSS JOIN (SELECT TOP 10 1 z FROM sys.all_objects) w) q;" pgvqs
sqok "A: p_two" "CREATE PROCEDURE dbo.p_two AS
BEGIN
  SELECT COUNT(*) FROM dbo.t t1 JOIN dbo.t t2 ON t2.id = t1.id WHERE t1.a < 100;
  SELECT MAX(t1.pad) FROM dbo.t t1 JOIN dbo.t t2 ON t2.id = t1.id WHERE t1.id > 10;
END" pgvqs
sqok "A: p_enc" "CREATE PROCEDURE dbo.p_enc WITH ENCRYPTION AS SELECT COUNT(*) FROM dbo.t t1 JOIN dbo.t t2 ON t2.id = t1.id WHERE t1.a > 4000;" pgvqs
WORK="EXEC dbo.p_two; EXEC dbo.p_two; EXEC dbo.p_two; EXEC dbo.p_enc; EXEC dbo.p_enc;
SELECT /* PASSWORD = 'pgvsecret$SUF' */ COUNT(*) FROM dbo.t t1 JOIN dbo.t t2 ON t2.id = t1.id WHERE t1.a = -1;
GO
SELECT a FROM dbo.t WHERE id = 7"
sqok "A: the workload" "$WORK" pgvqs

go build -o "$TMPD/pgvigil" ./cmd/pgvigil
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
export PGV_Q_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
cat > "$TMPD/m.yaml" <<EOF
repository:
  dsn: "$PGDSN"
instances:
  - name: sqlfull
    engine: sqlserver
    dsn: env:PGV_Q_MON
    query_text: full
  - name: sqlnone
    engine: sqlserver
    dsn: env:PGV_Q_MON
    query_text: none
  - name: sqlnorm
    engine: sqlserver
    dsn: env:PGV_Q_MON
    query_text: normalized
EOF
# part B's sysadmin read login (B11: sa itself; the plan read by handle does not refuse it)
if part B; then cat >> "$TMPD/m.yaml" <<'EOF'
  - name: sqlsa
    engine: sqlserver
    dsn: env:PGV_Q_SA
    query_text: full
EOF
fi
export PGV_Q_SA="sqlserver://sa:$(urlq "$SA_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
# part C's instances only when C runs: their schedules name collections a tree without them refuses (its red is C's own)
if part C; then cat >> "$TMPD/m.yaml" <<'EOF'
  - name: rpon
    engine: sqlserver
    dsn: env:PGV_Q_MON
    query_text: full
    schedules:
      mssql_running_plans: 1m
      mssql_live_plans: 1m
  - name: rpoff
    engine: sqlserver
    dsn: env:PGV_Q_MON
    query_text: full
  - name: rpnone
    engine: sqlserver
    dsn: env:PGV_Q_MON
    query_text: none
    schedules:
      mssql_running_plans: 1m
EOF
fi
"$TMPD/pgvigil" migrate -config "$TMPD/m.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "A: migrate"; }
col() { local i=$1; shift; for c in "$@"; do timeout 180 "$TMPD/pgvigil" collect -config "$TMPD/m.yaml" -instance "$i" -once "$c" >"$TMPD/col-$i-$c.out" 2>&1 || { cat "$TMPD/col-$i-$c.out" >&2; fail "collect $i $c"; }; done; }
col sqlfull mssql_instance mssql_plancache
sqok "A: the workload again" "$WORK" pgvqs
col sqlfull mssql_plancache
col sqlnone mssql_instance mssql_plancache
col sqlnorm mssql_instance mssql_plancache
IF=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlfull'"); IN=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlnone'"); IZ=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlnorm'")
echo "ok   A: SQL Server $VER, pgvqs, the workload, sqlfull $IF / sqlnone $IN / sqlnorm $IZ read"

PGVIGIL_PASSWORD="$UPW" "$TMPD/pgvigil" user add -config "$TMPD/m.yaml" "$USR" >/dev/null 2>&1 || fail "A: user add"
WPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$WPORT"
"$TMPD/pgvigil" serve -config "$TMPD/m.yaml" -listen "127.0.0.1:$WPORT" >"$TMPD/serve.out" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.out" >&2; fail "A: serve exited"; }
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$TMPD/login.json"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "A: the API login"
# api <path?query> <out>: the reply's body in <out>, the HTTP code printed
api() { curl -s -o "$2" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/$1"; }
# serve_restart <tag>: serve again with m.yaml as it is now (a policy changed), signed in again
serve_restart() { kill "$SRVPID" 2>/dev/null; wait "$SRVPID" 2>/dev/null || true
  "$TMPD/pgvigil" serve -config "$TMPD/m.yaml" -listen "127.0.0.1:$WPORT" >"$TMPD/serve-$1.out" 2>&1 & SRVPID=$!
  for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
  kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve-$1.out" >&2; fail "$1: serve exited"; }
  [[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "$1: the API login"; }
# set_qt <instance> <policy>: an instance's query_text in m.yaml
set_qt() { python3 - "$TMPD/m.yaml" "$1" "$2" <<'PY'
import sys
p, inst, v = sys.argv[1:]
out, cur = [], None
for l in open(p).read().split('\n'):
    if l.startswith('  - name: '): cur = l.split(': ', 1)[1]
    if cur == inst and l.strip().startswith('query_text:'): l = '    query_text: ' + v
    out.append(l)
open(p, 'w').write('\n'.join(out))
PY
}

if part B; then
echo "== B. a cached plan by handle, on demand =="
DBID=$(sq "SELECT DB_ID('pgvqs')")
# the hand read: p_two's two statements and p_enc's, with their keys and handles as the collector writes them (0x, upper)
sq "SELECT CASE WHEN SUBSTRING(t.text, qs.statement_start_offset / 2 + 1, 400) LIKE '%t1.a < 100%' THEN 'first'
                WHEN SUBSTRING(t.text, qs.statement_start_offset / 2 + 1, 400) LIKE '%t1.id > 10%' THEN 'second'
                WHEN t.objectid = OBJECT_ID('pgvqs.dbo.p_enc') THEN 'enc'
                WHEN SUBSTRING(t.text, qs.statement_start_offset / 2 + 1, 400) LIKE '%pgvsecret%' THEN 'secret' END
  + '|' + CONVERT(varchar(140), qs.plan_handle, 1) + '|' + CAST(qs.statement_start_offset AS varchar(10)) + '|' + CAST(qs.statement_end_offset AS varchar(10))
  + '|' + CONVERT(varchar(40), qs.query_hash, 1) + '|' + CONVERT(varchar(40), qs.query_plan_hash, 1)
  FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
 WHERE (t.dbid = DB_ID('pgvqs') AND t.objectid IN (OBJECT_ID('pgvqs.dbo.p_two'), OBJECT_ID('pgvqs.dbo.p_enc')))
    OR (SUBSTRING(t.text, qs.statement_start_offset / 2 + 1, 400) LIKE '%pgvsecret%' AND t.text NOT LIKE '%dm_exec%')" >"$TMPD/hand-stmts.out" || fail "B: the hand read"
sq "SELECT CONVERT(varchar(140), cp.plan_handle, 1) FROM sys.dm_exec_cached_plans cp CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) t
 WHERE cp.objtype = 'Adhoc' AND t.text LIKE 'SELECT a FROM dbo.t WHERE id = 7%'" >"$TMPD/hand-shell.out" || fail "B: the shell's handle"
sqbig "SELECT q.query_plan FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
 CROSS APPLY sys.dm_exec_text_query_plan(qs.plan_handle, qs.statement_start_offset, qs.statement_end_offset) q WHERE SUBSTRING(t.text, qs.statement_start_offset / 2 + 1, 400) LIKE '%pgvsecret%' AND t.text NOT LIKE '%dm_exec%'" >"$TMPD/hand-secret.out" 2>&1 || true
python3 - "$TMPD" "$U" "$IF" "$IN" "$IZ" "$DBID" "$EXTRACT" "$SUF" <<'PYEND' || fail "B: see above"
import json, os, subprocess, sys, urllib.parse
d, u, i_full, i_none, i_norm, dbid, extract, suf = sys.argv[1:]
bad = []
def api(path, **q):
    out = f"{d}/r.json"
    code = subprocess.run(['curl', '-s', '-o', out, '-w', '%{http_code}', '-b', f"{d}/cj", '-H', 'X-Pgvigil: 1',
                           f"{u}/api/{path}?{urllib.parse.urlencode(q)}"], capture_output=True, text=True).stdout
    try: body = json.load(open(out))
    except Exception: body = open(out, errors='replace').read()[:200]
    return int(code), body
hand = {}
for l in open(f"{d}/hand-stmts.out"):
    p = l.strip().split('|')
    hx = lambda v: '0x' + v[2:].upper()   # the collector's form: 0x and upper-case digits
    if len(p) == 6 and p[0]: hand[p[0]] = dict(handle=hx(p[1]), start=int(p[2]), end=int(p[3]), qhash=hx(p[4]), phash=hx(p[5]))
for k in ('first', 'second', 'enc', 'secret'):
    if k not in hand: bad.append(f"B the hand read has no {k} statement: {open(d + '/hand-stmts.out').read()[:400]}")
if bad: print('\n'.join('DIFF ' + b for b in bad)); sys.exit(1)
f = hand['first']
# B1
code, b = api('mssql/plancache/entries', instance=i_full, db=dbid, key=f['qhash'])
if code != 200 or not isinstance(b, dict) or 'entries' not in b:
    print(f"DIFF B1 entries: HTTP {code} {str(b)[:200]}"); sys.exit(1)
cols = b['entries']['columns']; rows = [dict(zip(cols, r)) for r in b['entries']['rows']]
mine = [r for r in rows if str(r['plan_handle']) == f['handle'] and r['stmt_start'] == f['start'] and r['stmt_end'] == f['end']]
if not mine: bad.append(f"B1 no entry equals the hand read {f}: {rows}")
elif str(mine[0]['plan_hash']) != f['phash']: bad.append(f"B1 plan hash {mine[0]['plan_hash']} != hand {f['phash']}")
if b.get('fetch_off'): bad.append(f"B1 fetch_off on sqlfull: {b['fetch_off']}")
# B2
code, b = api('mssql/plancache/plan', instance=i_full, handle=f['handle'], start=f['start'], end=f['end'], hash=f['phash'])
if code != 200 or b.get('state') != 'ok': bad.append(f"B2 state: HTTP {code} {str(b)[:300]}")
else:
    x = b.get('plan', '')
    if b.get('plan_hash', '') != f['phash']: bad.append(f"B2 plan_hash {b.get('plan_hash')} != {f['phash']}")
    if b.get('objtype') != 'Proc' or b.get('object') != 'dbo.p_two': bad.append(f"B2 objtype/object {b.get('objtype')} {b.get('object')}")
    if not x.lstrip().startswith('<ShowPlanXML') or x.count('<StmtSimple') != 1 or ('t1.a &lt; 100' not in x and 't1.a < 100' not in x) or 't1.id &gt; 10' in x or 't1.id > 10' in x:
        bad.append(f"B2 the statement's plan: root/StmtSimple/text wrong: {x[:300]}")
    if not str(b.get('file', '')).endswith('.sqlplan'): bad.append(f"B2 file {b.get('file')}")
    open(f"{d}/p.sqlplan", 'w', encoding='utf-8').write(x)
    r = subprocess.run([sys.executable, '-I', extract, f"{d}/p.sqlplan"], capture_output=True, text=True)
    if r.returncode != 0 or not ('ix_a' in r.stdout or 'PK__t' in r.stdout): bad.append(f"B2 extract.py rc {r.returncode}: {(r.stdout + r.stderr)[:400]}")
    else: print(f"B2 extract.py read the file: {r.stdout.splitlines()[0][:120] if r.stdout else ''}")
code, b = api('mssql/plancache/plan', instance=i_full, handle=f['handle'], start=0, end=-1)
if code != 200 or b.get('state') != 'ok' or b.get('plan', '').count('<StmtSimple') < 2: bad.append(f"B2 the batch read: HTTP {code} {b.get('state') if isinstance(b, dict) else b} statements {b.get('plan', '').count('<StmtSimple') if isinstance(b, dict) else '-'}")
# B3
code, b = api('mssql/plancache/plan', instance=i_full, handle=f['handle'], start=f['start'], end=f['end'], hash='0x1234')
if code != 200 or b.get('state') != 'changed' or f['phash'].upper() not in b.get('words', '').upper() or '0X1234' not in b.get('words', '').upper(): bad.append(f"B3 changed: HTTP {code} {str(b)[:300]}")
# B4
e = hand['enc']
code, b = api('mssql/plancache/plan', instance=i_full, handle=e['handle'], start=e['start'], end=e['end'])
if code != 200 or b.get('state') != 'encrypted' or b.get('plan'): bad.append(f"B4 encrypted: HTTP {code} {str(b)[:300]}")
# B5
sh = open(f"{d}/hand-shell.out").read().split()
if not sh: bad.append("B5 no shell plan was cached for 'SELECT a FROM dbo.t WHERE id = 7' (simple parameterization)")
else:
    code, b = api('mssql/plancache/plan', instance=i_full, handle='0x' + sh[0][2:].upper(), start=0, end=-1)
    if code != 200 or b.get('state') != 'parameterized' or b.get('plan'): bad.append(f"B5 parameterized: HTTP {code} {str(b)[:300]}")
# B6
s = hand['secret']; raw = open(f"{d}/hand-secret.out", errors='replace').read()
code, b = api('mssql/plancache/plan', instance=i_full, handle=s['handle'], start=s['start'], end=s['end'])
if 'pgvsecret' + suf in raw:
    if code != 200 or 'pgvsecret' in b.get('plan', '') or '<masked>' not in b.get('plan', '').replace('&lt;', '<').replace('&gt;', '>'):
        bad.append(f"B6 the mask: HTTP {code} state {b.get('state')} secret kept {'pgvsecret' in b.get('plan', '')}")
    else:
        import xml.etree.ElementTree as ET
        try: ET.fromstring(b['plan']); print("B6 the raw showplan carries the secret; the reply's plan holds <masked>, not the secret, and parses as XML")
        except Exception as e: bad.append(f"B6 the masked plan is not XML: {e}")
else: print("NOT PROVEN B6: the raw showplan read by hand does not carry the comment's PASSWORD = '...' (so there is nothing to mask): " + raw[:160].replace('\n', ' '))
# B7
for inst, word in ((i_none, 'none'), (i_norm, 'normalized')):
    code, b = api('mssql/plancache/entries', instance=inst, db=dbid, key=f['qhash'])
    if code != 200 or f'"{word}"' not in b.get('fetch_off', ''): bad.append(f"B7 {word} entries fetch_off: {str(b)[:300]}")
    code, b = api('mssql/plancache/plan', instance=inst, handle=f['handle'], start=f['start'], end=f['end'])
    if code != 200 or b.get('state') != 'off' or f'"{word}"' not in b.get('words', '') or b.get('plan'): bad.append(f"B7 {word} plan: HTTP {code} {str(b)[:300]}")
# B9
for q, why in ((dict(handle='0x123'), 'odd'), (dict(handle='0x' + '00' * 65), '65 bytes'), (dict(handle=f['handle'], start=100, end=50), 'end before start')):
    code, b = api('mssql/plancache/plan', instance=i_full, **q)
    if code != 400: bad.append(f"B9 {why}: HTTP {code}")
code, b = api('mssql/plancache/entries', instance=i_full, db=dbid, key="0x12;DROP")
if code != 400: bad.append(f"B9 bad key: HTTP {code}")
json.dump(hand, open(f"{d}/hand.json", 'w'))
for x in bad: print('DIFF', x)
sys.exit(1 if bad else 0)
PYEND
NPLAN=$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name = 'pgvigil-plan' AND login_name = '$MON'")
[[ "$NPLAN" == 0 ]] || fail "B10: $NPLAN session(s) named pgvigil-plan still open after the reads"
# B8: evict the first statement's plan by hand, then read it
H1=$(python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["first"]; print(h["handle"], h["start"], h["end"])' "$TMPD/hand.json")
read -r HH HS HE <<<"$H1"
sqok "B8: the hand evict" "DBCC FREEPROCCACHE ($HH) WITH NO_INFOMSGS;"
CODE=$(api "mssql/plancache/plan?instance=$IF&handle=$HH&start=$HS&end=$HE" "$TMPD/b8.json")
[[ "$CODE" == 404 ]] && grep -q 'no plan under this handle' "$TMPD/b8.json" || fail "B8: an evicted handle: HTTP $CODE $(head -c 300 "$TMPD/b8.json")"
# B11: every read wrote its audit row first (op plan_read: who, the door, the handle; never the plan); a sysadmin read
# login (sqlsa: sa itself) gets the plan, and its row is written too
AUD=$(pq "SELECT count(*) FILTER (WHERE outcome = 'done' AND ui_user = '$USR' AND door = 'file' AND payload ? 'plan_handle') || '|' ||
              count(*) FILTER (WHERE coalesce(detail, '') || coalesce(statement, '') || coalesce(payload::text, '') LIKE '%ShowPlanXML%')
          FROM pgvigil.custom_report_log WHERE op = 'plan_read' AND instance = 'sqlfull'")
[[ "${AUD%%|*}" -ge 6 && "${AUD##*|}" == 0 ]] || fail "B11: sqlfull's plan_read rows (done by $USR through the file door | rows holding a plan): $AUD"
col sqlsa mssql_instance
ISA=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlsa'")
read -r SXH SXS SXE <<<"$(python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["secret"]; print(h["handle"], h["start"], h["end"])' "$TMPD/hand.json")"
CODE=$(api "mssql/plancache/plan?instance=$ISA&handle=$SXH&start=$SXS&end=$SXE" "$TMPD/b11.json")
[[ "$CODE" == 200 ]] && grep -q '"state":"ok"' "$TMPD/b11.json" && grep -q 'ShowPlanXML' "$TMPD/b11.json" || fail "B11: the sysadmin read login's plan: HTTP $CODE $(head -c 300 "$TMPD/b11.json")"
SROW=$(pq "SELECT outcome || '|' || ui_user || '|' || (payload->>'plan_handle') || '|' || (coalesce(detail, '') LIKE 'ok:%')::text || '|' || (statement IS NULL)::text
          FROM pgvigil.custom_report_log WHERE op = 'plan_read' AND instance = 'sqlsa' ORDER BY log_id DESC LIMIT 1")
[[ "$SROW" == "done|$USR|$SXH|true|true" ]] || fail "B11: sqlsa's audit row '$SROW'"
# B12: a serve without the audit door (-no-login: no signed-in user) reads no plan: refused in words, nothing sent to the
# server (its login counter moves by the second hand read's own login only), no audit row
NPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
"$TMPD/pgvigil" serve -config "$TMPD/m.yaml" -listen "127.0.0.1:$NPORT" -no-login >"$TMPD/serve-nl.out" 2>&1 & NLPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$NPORT/api/session" 2>/dev/null && break; sleep 0.1; done
LOGINS="SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'Logins/sec' AND object_name LIKE '%General Statistics%'"
N0=$(pq "SELECT count(*) FROM pgvigil.custom_report_log WHERE op = 'plan_read'"); L0=$(sq "$LOGINS")
CODE=$(curl -s -o "$TMPD/b12.json" -w '%{http_code}' -H 'X-Pgvigil: 1' "http://127.0.0.1:$NPORT/api/mssql/plancache/plan?instance=$ISA&handle=$SXH&start=$SXS&end=$SXE")
L1=$(sq "$LOGINS"); N1=$(pq "SELECT count(*) FROM pgvigil.custom_report_log WHERE op = 'plan_read'")
kill "$NLPID" 2>/dev/null; wait "$NLPID" 2>/dev/null || true
[[ "$CODE" == 200 ]] && grep -q '"state":"off"' "$TMPD/b12.json" && grep -q 'needs a signed-in user' "$TMPD/b12.json" && ! grep -q ShowPlanXML "$TMPD/b12.json" \
  || fail "B12: without the audit door: HTTP $CODE $(head -c 300 "$TMPD/b12.json")"
[[ $((L1 - L0)) == 1 && "$N1" == "$N0" ]] || fail "B12: logins on the server $L0 -> $L1 (want +1: the hand read's own), plan_read rows $N0 -> $N1"
# B12b / B12c: signed in, but the config's repository login (the audit login) is a reader (no actions log: the door's
# audit is off), or a collector the read's audit function was taken from: the entries' fetch_off and the read say so in
# words, nothing is sent, no row
if [[ "$(pq "SELECT count(*) FROM pg_roles WHERE rolname IN ('pgvigil_reader', 'pgvigil_auth', 'pgvigil_collector')")" == 3 ]]; then
  ARO=pgv_qro_$SUF; AAU=pgv_qau_$SUF; ARO_PW=$(pw); AAU_PW=$(pw)
  printf "CREATE ROLE %s LOGIN PASSWORD '%s' IN ROLE pgvigil_reader, pgvigil_auth;\nCREATE ROLE %s LOGIN PASSWORD '%s' IN ROLE pgvigil_collector, pgvigil_reader, pgvigil_auth;\n" "$ARO" "$ARO_PW" "$AAU" "$AAU_PW" | psql "$ADMIN_DSN" -Xq -v ON_ERROR_STOP=1 >/dev/null
  for case in "b12b $ARO $ARO_PW" "b12c $AAU $AAU_PW"; do
    read -r tag who wpw <<<"$case"
    [[ $tag == b12c ]] && pq "REVOKE EXECUTE ON FUNCTION pgvigil.import_custom_report_run(timestamptz, jsonb) FROM pgvigil_collector" >/dev/null
    sed "s|dsn: \"$PGDSN\"|dsn: \"$ADMIN_DSN user=$who password=$wpw dbname=$PGDB\"|" "$TMPD/m.yaml" > "$TMPD/m-$tag.yaml"
    NPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
    "$TMPD/pgvigil" serve -config "$TMPD/m-$tag.yaml" -listen "127.0.0.1:$NPORT" >"$TMPD/serve-$tag.out" 2>&1 & NLPID=$!
    for _ in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$NPORT/api/session" 2>/dev/null && break; sleep 0.1; done
    [[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj-$tag" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "http://127.0.0.1:$NPORT/api/login")" == 200 ]] || { cat "$TMPD/serve-$tag.out" >&2; fail "$tag: the API login"; }
    N0=$(pq "SELECT count(*) FROM pgvigil.custom_report_log WHERE op = 'plan_read'"); L0=$(sq "$LOGINS")
    CE=$(curl -s -o "$TMPD/$tag-e.json" -w '%{http_code}' -b "$TMPD/cj-$tag" -H 'X-Pgvigil: 1' "http://127.0.0.1:$NPORT/api/mssql/plancache/entries?instance=$ISA&db=$DBID&key=0x0000000000000001")
    CODE=$(curl -s -o "$TMPD/$tag.json" -w '%{http_code}' -b "$TMPD/cj-$tag" -H 'X-Pgvigil: 1' "http://127.0.0.1:$NPORT/api/mssql/plancache/plan?instance=$ISA&handle=$SXH&start=$SXS&end=$SXE")
    L1=$(sq "$LOGINS"); N1=$(pq "SELECT count(*) FROM pgvigil.custom_report_log WHERE op = 'plan_read'")
    kill "$NLPID" 2>/dev/null; wait "$NLPID" 2>/dev/null || true
    [[ $tag == b12c ]] && pq "GRANT EXECUTE ON FUNCTION pgvigil.import_custom_report_run(timestamptz, jsonb) TO pgvigil_collector" >/dev/null
    want='audit login, and it is off'; [[ $tag == b12c ]] && want='import_custom_report_run'
    [[ "$CODE" == 200 ]] && grep -q '"state":"off"' "$TMPD/$tag.json" && grep -q "$want" "$TMPD/$tag.json" && ! grep -q ShowPlanXML "$TMPD/$tag.json" \
      || fail "$tag: the read: HTTP $CODE $(head -c 300 "$TMPD/$tag.json")"
    [[ "$CE" == 200 ]] && grep -q "$want" "$TMPD/$tag-e.json" || fail "$tag: the entries' fetch_off: HTTP $CE $(head -c 300 "$TMPD/$tag-e.json")"
    [[ $((L1 - L0)) == 1 && "$N1" == "$N0" ]] || fail "$tag: logins on the server $L0 -> $L1 (want +1), plan_read rows $N0 -> $N1"
    echo "$tag: refused in words ('$want'), the entries' buttons off with the same words, nothing sent, no row"
  done
  psql "$ADMIN_DSN" -Xqc "DROP ROLE IF EXISTS $ARO; DROP ROLE IF EXISTS $AAU;" >/dev/null 2>&1 || true
else
  echo "NOT PROVEN B12b / B12c: the cluster has no pgvigil_reader, pgvigil_auth and pgvigil_collector roles ('pgvigil roles' not run on it)"
fi
echo "ok   B: entries equal the hand read; the statement's plan (ok, its hash, Proc dbo.p_two, one statement, extract.py reads it), the batch's; changed; encrypted; parameterized; the mask; none / normalized refused with their words; 404 once evicted; 400 on bad input; no pgvigil-plan session left open; every read audited (plan_read, no plan in the row), a sysadmin read login served and audited; no audit door (no login, a reader as the audit login, a collector without import_custom_report_run): refused in words, the buttons off before a click, nothing sent"
fi

if part C; then
echo "== C. the plans of running queries =="
# bg <tag> <seconds> <batch>: sa runs the batch in pgvqs in a session of its own (program name pgvqs-<tag>), held open
cat > "$TMPD/bg.sh" <<'BGS'
{ printf 'SET NOCOUNT ON;\nGO\n%s\nGO\n' "$4"; sleep "$3"; } | docker exec -i --env-file "$2" "$1" bash -c 'SQLCMDPASSWORD=$SA_PW exec '"$5"' -S localhost -U sa '"$6"' -d pgvqs -H "$0" -l 120' "pgvqs-$7" >/dev/null 2>&1
BGS
bg() { setsid bash "$TMPD/bg.sh" "$SQL" "$TMPD/sa.env" "$2" "$3" "$SQLCMD" "$TRUST" "$1" & BG+=($!); }
stopbg() { for p in "${BG[@]}"; do kill -- "-$p" 2>/dev/null || true; done; BG=()
  sq "DECLARE @s nvarchar(max) = N''; SELECT @s += N'KILL ' + CAST(session_id AS nvarchar(10)) + N'; ' FROM sys.dm_exec_sessions WHERE host_name LIKE 'pgvqs-%' AND session_id <> @@SPID; EXEC (@s);" >/dev/null 2>&1 || true; sleep 1; }
# req <marker>: the hand read of a running request whose text holds the marker: query hash|plan hash|start|end|cpu|grant pages|running ms
req() { sq "SELECT TOP (1) CONVERT(varchar(40), r.query_hash, 1) + '|' + CONVERT(varchar(40), r.query_plan_hash, 1) + '|' + CAST(r.statement_start_offset AS varchar(10)) + '|' + CAST(r.statement_end_offset AS varchar(10))
  + '|' + CAST(r.cpu_time AS varchar(20)) + '|' + CAST(r.granted_query_memory AS varchar(20)) + '|' + CAST(DATEDIFF_BIG(millisecond, r.start_time, GETDATE()) AS varchar(20))
  FROM sys.dm_exec_requests r CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t WHERE t.text LIKE '%$1%' AND t.text NOT LIKE '%dm_exec_requests%' ORDER BY r.cpu_time DESC"; }
waitreq() { local v=; for _ in $(seq 1 60); do v=$(req "$1" 2>/dev/null || true); [[ -n "$v" ]] && { echo "$v"; return 0; }; sleep 0.5; done
  sq "SELECT s.host_name + '|' + s.status + '|' + ISNULL(r.status, '-') + '|' + ISNULL(r.wait_type, '-') + '|' + CAST(ISNULL(r.blocking_session_id, 0) AS varchar(10)) + '|' + ISNULL(LEFT(t.text, 120), '-')
    FROM sys.dm_exec_sessions s LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t WHERE s.host_name LIKE 'pgvqs-%'" >&2 || true
  req "$1" >&2 || true
  fail "C: no running request $1"; }
# each case its own statement shape (a literal alone leaves the query and plan hash as they are): victim <shape> <id>
victim() { case $1 in
  dur) echo "SELECT COUNT(*) FROM dbo.t t1 JOIN dbo.t t2 ON t2.id = t1.id WHERE t1.id = $2" ;;
  cnt) echo "SELECT MAX(t1.a) FROM dbo.t t1 JOIN dbo.t t2 ON t2.id = t1.id WHERE t1.id = $2" ;;
  low) echo "SELECT MIN(t2.a), COUNT(t1.pad) FROM dbo.t t1 JOIN dbo.t t2 ON t2.id = t1.id WHERE t1.id = $2" ;;
  sw)  echo "SELECT SUM(t1.a), MAX(t2.pad) FROM dbo.t t1 JOIN dbo.t t2 ON t2.id = t1.id WHERE t1.id = $2" ;;
  esac; }
# held <tag>: until the blocker of that tag sits in its WAITFOR (its lock is taken)
held() { local n=; for _ in $(seq 1 60); do n=$(sq "SELECT COUNT(*) FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.host_name = 'pgvqs-$1' AND r.wait_type = 'WAITFOR'" 2>/dev/null || echo 0); [[ "$n" == 1 ]] && return 0; sleep 0.5; done; fail "C: the blocker $1 never held its lock"; }
hold() { bg "hold$1" "$2" "BEGIN TRAN; UPDATE dbo.t SET a = a + 1 WHERE id = $1; WAITFOR DELAY '00:03:00'; ROLLBACK;"; held "hold$1"; }
: >"$TMPD/cases.txt"
# C1 duration: blocked 12 s (and C3: rpnone reads the same moment)
hold 5 100; bg dur 100 "$(victim dur 5) /* pgvc-dur */"; waitreq pgvc-dur >/dev/null; sleep 12
echo "duration|$(req pgvc-dur)" >>"$TMPD/cases.txt"
col rpon mssql_running_plans; col rpnone mssql_running_plans
DURQ=$(req pgvc-dur); stopbg
# C1 cpu: a CPU-bound statement read at 3 s
bg cpu 60 "SELECT COUNT_BIG(*) FROM dbo.t a CROSS JOIN dbo.t b CROSS JOIN (SELECT TOP 8 1 x FROM dbo.t) c WHERE a.pad <> b.pad OR a.a > b.a OPTION (MAXDOP 1) /* pgvc-cpu */"
waitreq pgvc-cpu >/dev/null; sleep 3; echo "cpu|$(req pgvc-cpu)" >>"$TMPD/cases.txt"; col rpon mssql_running_plans; stopbg
# C1 count: two sessions on one plan, blocked 3 s
hold 6 100; bg cnt1 100 "$(victim cnt 6) /* pgvc-cnt */"; bg cnt2 100 "$(victim cnt 6) /* pgvc-cnt */"; waitreq pgvc-cnt >/dev/null; sleep 3
echo "count|$(req pgvc-cnt)" >>"$TMPD/cases.txt"; col rpon mssql_running_plans; stopbg
# C1 grant: a sort over dbo.big holding its grant while it waits on a locked row
bg holdbig 100 "BEGIN TRAN; UPDATE dbo.big SET pad = REVERSE(pad) WHERE id = 300000; WAITFOR DELAY '00:03:00'; ROLLBACK;"; held holdbig
bg grant 100 "SELECT TOP (550000) id, pad FROM dbo.big WHERE id > 0 ORDER BY pad DESC OPTION (MAXDOP 1) /* pgvc-grant */"; waitreq pgvc-grant >/dev/null; sleep 3
echo "grant|$(req pgvc-grant)" >>"$TMPD/cases.txt"; col rpon mssql_running_plans; stopbg
# C2 below every threshold: one session blocked 2 s
hold 7 100; bg low 100 "$(victim low 7) /* pgvc-low */"; waitreq pgvc-low >/dev/null; sleep 1
echo "low|$(req pgvc-low)" >>"$TMPD/cases.txt"; col rpon mssql_running_plans; stopbg
SQLC="$SQL|$SQLCMD|$TRUST|$(victim dur 0 | sed 's/ 0$//')" python3 - "$TMPD" "$PGDSN" "$U" "$EXTRACT" <<'PYEND' || fail "C1-C4: see above"
import json, subprocess, sys, urllib.parse
d, dsn, u, extract = sys.argv[1:]
import os
sqlc = os.environ['SQLC'].split('|', 3)
def q(s): return [l.split('|') for l in subprocess.run(['psql', dsn, '-XAtq', '-c', s], check=True, capture_output=True, text=True).stdout.splitlines() if l]
def api(path, **qs):
    out = f"{d}/rc.json"
    code = subprocess.run(['curl', '-s', '-o', out, '-w', '%{http_code}', '-b', f"{d}/cj", '-H', 'X-Pgvigil: 1', f"{u}/api/{path}?{urllib.parse.urlencode(qs)}"], capture_output=True, text=True).stdout
    try: return int(code), json.load(open(out))
    except Exception: return int(code), {}
hx = lambda v: '0x' + v[2:].upper()
bad = []
iid = {n: i for n, i in q("SELECT name, instance_id FROM pgvigil.instances")}
cases = {}
for l in open(f"{d}/cases.txt"):
    k, rest = l.strip().split('|', 1)
    p = rest.split('|')
    if len(p) < 7: bad.append(f"C1 {k}: no hand read ({rest})"); continue
    cases[k] = dict(qh=hx(p[0]), ph=hx(p[1]), start=int(p[2]), end=int(p[3]), cpu=int(p[4]), grant=int(p[5]), running=int(p[6]))
rows = {(r[0], r[1], int(r[2]), int(r[3])): r for r in q(f"SELECT query_hash, plan_hash, stmt_start, stmt_end, reasons, coalesce(plan_state, ''), (plan_xml LIKE '<ShowPlanXML%')::text, max_requests FROM pgvigil.mssql_running_plan WHERE instance_id = {iid['rpon']}")}
want = {'duration': 'duration', 'cpu': 'cpu', 'count': 'count', 'grant': 'grant'}
for k, reason in want.items():
    c = cases.get(k)
    if not c: continue
    r = rows.get((c['qh'], c['ph'], c['start'], c['end']))
    if k == 'grant' and c['grant'] < 6400:
        print(f"NOT PROVEN C1 grant: the sort's grant read by hand was {c['grant']} pages (under 6,400)"); continue
    if not r: bad.append(f"C1 {k}: no row for the hand read {c}; rows {list(rows)[:6]}"); continue
    if reason not in r[4].split(','): bad.append(f"C1 {k}: reasons {r[4]} (want {reason}); hand {c}")
    if r[5] != 'read' or r[6] != 'true': bad.append(f"C1 {k}: plan_state {r[5]}, plan stored {r[6]}")
    others = set(r[4].split(',')) - {reason}
    if others: print(f"C1 {k}: also met {sorted(others)} (hand read cpu {c['cpu']} ms, grant {c['grant']} pages, running {c['running']} ms)")
low = cases.get('low')
if low and (low['qh'], low['ph'], low['start'], low['end']) in rows: bad.append(f"C2 below every threshold, yet stored: {low}")
z = q(f"SELECT count(*) FROM pgvigil.mssql_running_plan WHERE plan_hash ~ '^0x0+$'")
if z[0][0] != '0': bad.append(f"C2 a zero plan hash stored: {z}")
dur = cases.get('duration', {})
n = q(f"SELECT coalesce(plan_state, ''), (plan_xml IS NULL)::text FROM pgvigil.mssql_running_plan WHERE instance_id = {iid['rpnone']} AND query_hash = '{dur.get('qh')}' AND plan_hash = '{dur.get('ph')}'")
if n != [['policy', 'true']]: bad.append(f"C3 rpnone: {n} (want policy, no plan)")
import datetime
now = datetime.datetime.now(datetime.timezone.utc)
iso = lambda t: t.strftime('%Y-%m-%dT%H:%M:%SZ')
code, b = api('mssql/runningplans', instance=iid['rpon'], **{'from': iso(now - datetime.timedelta(hours=1)), 'to': iso(now + datetime.timedelta(hours=1))})
listed = [dict(zip(b['plans']['columns'], r)) for r in b.get('plans', {}).get('rows', [])] if code == 200 else []
if code != 200 or not any(x['query_hash'] == dur.get('qh') and 'duration' in (x['reasons'] or '') for x in listed): bad.append(f"C4 list: HTTP {code} {str(b)[:200]}")
code, b = api('mssql/runningplans/plan', instance=iid['rpon'], qh=dur.get('qh'), ph=dur.get('ph'), start=dur.get('start'), end=dur.get('end'))
if code != 200 or b.get('state') != 'ok' or not b.get('plan', '').startswith('<ShowPlanXML'): bad.append(f"C4 plan: HTTP {code} {str(b)[:200]}")
else:
    open(f"{d}/c.sqlplan", 'w', encoding='utf-8').write(b['plan'])
    r = subprocess.run([sys.executable, '-I', extract, f"{d}/c.sqlplan"], capture_output=True, text=True)
    if r.returncode != 0: bad.append(f"C4 extract.py rc {r.returncode}: {r.stderr[:300]}")
code, b = api('mssql/runningplans/plan', instance=iid['rpnone'], qh=dur.get('qh'), ph=dur.get('ph'), start=dur.get('start'), end=dur.get('end'))
if code != 200 or b.get('state') != 'none' or 'query_text' not in b.get('words', ''): bad.append(f"C4 rpnone plan: HTTP {code} {str(b)[:200]}")
# C7: the duration case's plans by its hashes; its statement run once to completion first (the blocked request was
# killed, and a request that never completed leaves no sys.dm_exec_query_stats row), then a plan cache read
subprocess.run(['docker', 'exec', '-i', '--env-file', f"{d}/sa.env", sqlc[0], 'bash', '-c', 'SQLCMDPASSWORD=$SA_PW ' + sqlc[1] + ' -S localhost -U sa ' + sqlc[2] + ' -b -d pgvqs -i /dev/stdin'],
               input=sqlc[3] + ' 5;\n', capture_output=True, text=True)
subprocess.run([f"{d}/pgvigil", 'collect', '-config', f"{d}/m.yaml", '-instance', 'rpon', '-once', 'mssql_plancache'], capture_output=True)
code, b = api('mssql/plansources', instance=iid['rpon'], db='pgvqs', qh=dur.get('qh'), ph=dur.get('ph'))
srcs = [dict(zip(b['sources']['columns'], r)) for r in b.get('sources', {}).get('rows', [])] if code == 200 else []
kinds = {x['source'] for x in srcs}
if code != 200 or 'running' not in kinds or not any(x['source'] == 'running' and x['has_plan'] for x in srcs): bad.append(f"C7 plansources: HTTP {code} {srcs}")
if 'plan cache' not in kinds: bad.append(f"C7 no plan cache entry for the duration case after it completed and a plan cache read: {sorted(kinds)}")
if code == 200 and (b.get('fetch_off') or b.get('running_off')): bad.append(f"C7 a source is off on rpon (full, the audit door open): {b.get('fetch_off')} / {b.get('running_off')}")
for x in srcs:
    if x['source'] == 'running' and x['has_plan']:
        c2, p2 = api('mssql/runningplans/plan', instance=iid['rpon'], qh=dur.get('qh'), ph=dur.get('ph'), start=x['stmt_start'], end=x['stmt_end'])
        if c2 != 200 or p2.get('state') != 'ok' or '<ShowPlanXML' not in p2.get('plan', ''): bad.append(f"C7 the running capture's plan: HTTP {c2} {str(p2)[:200]}")
code, b = api('mssql/plansources', instance=iid['rpon'], db='pgvqs', qh=dur.get('qh'), ph='0x1234')
if code != 200 or b.get('sources', {}).get('rows'): bad.append(f"C7 a plan hash with no plan: HTTP {code} {str(b)[:200]}")
for x in bad: print('DIFF', x)
print(f"C1-C4, C7: cases {sorted(cases)}; rpon rows {len(rows)}; plan sources of the duration case {sorted(kinds)}")
sys.exit(1 if bad else 0)
PYEND
echo "ok   C1-C4, C7: one row per threshold case with its plan, none below the thresholds or for a zero plan hash, rpnone kept no plan, the API's list and plan; the duration case's plan sources (running, plan cache)"

# C5 the live plan
MAJ=${VER%%.*}
# row mode on every version (a recursive CTE has no batch mode): one statement running for minutes on one core
bg live 300 "WITH n AS (SELECT CAST(1 AS bigint) AS i UNION ALL SELECT i + 1 FROM n WHERE i < 2000000000) SELECT COUNT_BIG(*) FROM n OPTION (MAXDOP 1, MAXRECURSION 0) /* pgvc-live */"
waitreq pgvc-live >/dev/null
for _ in $(seq 1 150); do C=$(req pgvc-live | cut -d'|' -f5); [[ -n "$C" && "$C" -ge 61000 ]] && break; sleep 1; done
[[ -n "$C" && "$C" -ge 61000 ]] || fail "C5: the CPU-bound statement did not reach 61 s of CPU (at $C ms)"
col rpon mssql_live_plans; stopbg
LV=$(pq "SELECT count(*) FILTER (WHERE live_xml LIKE '%RunTimeCountersPerThread%') FROM pgvigil.mssql_live_plan l JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'rpon'")
LN=$(pq "SELECT coalesce(r.note, '') FROM pgvigil.mssql_live_read r JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'rpon'")
if (( MAJ >= 15 )); then [[ "$LV" -ge 1 ]] || fail "C5: no live plan with operator counters on $VER (note: $LN)"; echo "ok   C5: a live plan with RunTimeCountersPerThread on $VER"
else [[ "$LV" == 0 && "$LN" == *7412* ]] || fail "C5: on $VER want no live plan and the trace flag 7412 note (live plans $LV, note '$LN')"; echo "ok   C5: on $VER no live plan, the note: $LN"; fi

# C8 the policy leaves full (review 20261114-173221 B1): rpon's next read drops every plan and live plan it kept, and the
# plan reads answer none with the policy's words (serve reads the policy again when it starts)
RK=$(pq "SELECT p.query_hash || ' ' || p.plan_hash || ' ' || p.stmt_start || ' ' || p.stmt_end FROM pgvigil.mssql_running_plan p JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'rpon' AND p.plan_xml IS NOT NULL LIMIT 1")
[[ -n "$RK" ]] || fail "C8: rpon keeps no plan before its policy changes"
read -r KQ KP KS KE <<<"$RK"
LID=$(pq "SELECT coalesce(max(l.live_id), 0) FROM pgvigil.mssql_live_plan l JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'rpon' AND l.live_xml IS NOT NULL")
set_qt rpon none
col rpon mssql_running_plans
KEPT=$(pq "SELECT count(*) FILTER (WHERE p.plan_xml IS NOT NULL) || '|' || count(*) FILTER (WHERE p.plan_state = 'policy') FROM pgvigil.mssql_running_plan p JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'rpon'")
LKEPT=$(pq "SELECT count(*) FROM pgvigil.mssql_live_plan l JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'rpon' AND l.live_xml IS NOT NULL")
[[ "${KEPT%%|*}" == 0 && "${KEPT##*|}" -ge 1 && "$LKEPT" == 0 ]] || fail "C8: after rpon's read under none: plans kept | policy rows $KEPT, live plans kept $LKEPT (before: live $LID)"
serve_restart C8
IRP=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'rpon'")
for q in "" "&live=$LID"; do
  [[ "$q" == "&live=0" ]] && continue
  CODE=$(api "mssql/runningplans/plan?instance=$IRP&qh=$KQ&ph=$KP&start=$KS&end=$KE$q" "$TMPD/c8.json")
  [[ "$CODE" == 200 ]] && grep -q '"state":"none"' "$TMPD/c8.json" && grep -q 'policy is \\"none\\"' "$TMPD/c8.json" && ! grep -q ShowPlanXML "$TMPD/c8.json" \
    || fail "C8: the plan read$q under none: HTTP $CODE $(head -c 300 "$TMPD/c8.json")"
done
set_qt rpon full
echo "ok   C8: rpon's policy full -> none: its next read dropped every kept plan and live plan (plan_state policy); the plan and live reads answer none with the policy's words"

# C6 the switch under pgvigil run (review B2, the lead 17:5x): the running plans box of Admin > Instances is off for every
# page instance (present at the upgrade or added after) until an admin ticks it; cleared, the reads stop; the file's
# global schedules: mssql_running_plans: 0 stops a ticked one; a file instance keeps its own schedules:
COL=pgv_qcol_$SUF; COL_PW=$(pw)
printf "CREATE ROLE %s LOGIN PASSWORD '%s' IN ROLE pgvigil_collector;\n" "$COL" "$COL_PW" | psql "$ADMIN_DSN" -Xq -v ON_ERROR_STOP=1 >/dev/null
export PGV_Q_COL="$ADMIN_DSN user=$COL password=$COL_PW dbname=$PGDB"
sed "s|dsn: \"$PGDSN\"|dsn: env:PGV_Q_COL|" "$TMPD/m.yaml" | python3 -c 'import sys
out, skip = [], False
for l in sys.stdin.read().split("\n"):
    if l.startswith("  - name: "): skip = l.split(": ", 1)[1] not in ("rpon", "rpoff")
    if not skip: out.append(l)
print("\n".join(out))' > "$TMPD/collector.yaml"
export ADD_PW="$MON_PW"
# admin <json>: POST /api/admin/instances, the code; the reply in $TMPD/adm.out
admin() { curl -s -o "$TMPD/adm.out" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "$1" "$U/api/admin/instances"; }
addpage() { python3 -c 'import json, os, sys; print(json.dumps({"op": "add", "name": sys.argv[3], "engine": "sqlserver", "auth": "sql", "host": "127.0.0.1", "port": sys.argv[1], "login": sys.argv[2], "password": os.environ["ADD_PW"], "options": "encrypt=true&TrustServerCertificate=true"}))' "$PORT_SQL" "$MON" "$1"; }
box() { admin "{\"op\":\"running_plans\",\"name\":\"$1\",\"on\":$2}"; }
CODE=$(admin "$(addpage rppage)"); [[ "$CODE" == 200 ]] || fail "C6: adding rppage on Admin > Instances: HTTP $CODE $(head -c 300 "$TMPD/adm.out")"
# the upgrade: rppage is in admin_instances before 0157 adds running_plans (the column dropped, 0157 run again by migrate)
pq "ALTER TABLE pgvigil.admin_instances DROP COLUMN running_plans; DELETE FROM pgvigil.schema_version WHERE version LIKE '0157%'" >/dev/null
"$TMPD/pgvigil" migrate -config "$TMPD/m.yaml" >"$TMPD/migrate2.out" 2>&1 || { cat "$TMPD/migrate2.out" >&2; fail "C6: 0157 again (the upgrade)"; }
[[ "$(pq "SELECT running_plans FROM pgvigil.admin_instances WHERE name = 'rppage'")" == f ]] || fail "C6 R1: rppage after the upgrade: running_plans $(pq "SELECT running_plans FROM pgvigil.admin_instances WHERE name = 'rppage'")"
for n in rppage2 rppage3; do CODE=$(admin "$(addpage $n)"); [[ "$CODE" == 200 ]] || fail "C6: adding $n: HTTP $CODE $(head -c 300 "$TMPD/adm.out")"; done
[[ "$(pq "SELECT string_agg(name || '=' || running_plans, ' ' ORDER BY name) FROM pgvigil.admin_instances WHERE name LIKE 'rppage%'")" == "rppage=false rppage2=false rppage3=false" ]] \
  || fail "C6 R2: new page instances' box: $(pq "SELECT string_agg(name || '=' || running_plans, ' ' ORDER BY name) FROM pgvigil.admin_instances WHERE name LIKE 'rppage%'")"
CODE=$(box rpon true); [[ "$CODE" == 409 ]] && grep -q 'pgvigil.yaml' "$TMPD/adm.out" || fail "C6: the box on a file instance: HTTP $CODE $(head -c 300 "$TMPD/adm.out")"
CODE=$(box rppage3 true); [[ "$CODE" == 200 ]] || fail "C6 R3: ticking rppage3: HTTP $CODE $(head -c 300 "$TMPD/adm.out")"
[[ "$(pq "SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'instance running_plans' AND target = 'rppage3' AND outcome = 'done' AND ui_user = '$USR'")" == 1 ]] || fail "C6 R3: no audit row for the tick"
lastrun() { pq "SELECT coalesce(max(c.snapshot_at)::text, '') FROM pgvigil.collection_dates c JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$1' AND c.collection = 'mssql_running_plans'"; }
# the blocked statement past the duration threshold (10 s) before the collector starts, so each first read keeps it
hold 8 200; bg sw 200 "$(victim sw 8) /* pgvc-switch */"; waitreq pgvc-switch >/dev/null; sleep 12
SWQ=$(req pgvc-switch | cut -d'|' -f1); SWQ="0x${SWQ:2}"; SWQ=${SWQ^^}; SWQ="0x${SWQ:2}"
"$TMPD/pgvigil" run -config "$TMPD/collector.yaml" >"$TMPD/run.log" 2>&1 & RUNPID=$!
swrows() { pq "SELECT count(*) FROM pgvigil.mssql_running_plan p JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$1' AND p.query_hash = '$SWQ'"; }
for _ in $(seq 1 65); do [[ "$(swrows rppage3)" -ge 1 && "$(swrows rpon)" -ge 1 ]] && break; sleep 2; done
# R5: the box cleared while pgvigil run runs: no read of rppage3 starts after the collector's next read of the list
CODE=$(box rppage3 false); [[ "$CODE" == 200 ]] || fail "C6 R5: clearing rppage3: HTTP $CODE $(head -c 300 "$TMPD/adm.out")"
TOFF=$(pq "SELECT now()")
sleep 80
kill "$RUNPID" 2>/dev/null || true; wait "$RUNPID" 2>/dev/null || true; RUNPID=
stopbg
for n in rpon rppage3 rppage rppage2 rpoff; do
  R=$(pq "SELECT count(*) FROM pgvigil.mssql_running_plan p JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$n' AND p.query_hash = '$SWQ'")
  K=$(lastrun $n)
  echo "C6 $n: rows $R, last run '${K}'"
  case $n in
    rpon|rppage3) [[ "$R" -ge 1 && -n "$K" ]] || { tail -20 "$TMPD/run.log" >&2; fail "C6: $n did not read the running plan under pgvigil run"; } ;;
    *) [[ "$R" == 0 && -z "$K" ]] || fail "C6: $n (box not ticked / no schedules) read plans: rows $R, last run '$K'" ;;
  esac
done
[[ "$(pq "SELECT ('$(lastrun rppage3)'::timestamptz < '$TOFF'::timestamptz + interval '20 seconds')::text")" == true ]] || fail "C6 R5: rppage3 read at $(lastrun rppage3), after its box was cleared at $TOFF"
[[ "$(pq "SELECT ('$(lastrun rpon)'::timestamptz > '$TOFF'::timestamptz + interval '20 seconds')::text")" == true ]] || fail "C6 R5: rpon's own reads stopped too (last $(lastrun rpon), the box cleared at $TOFF)"
# R4: the file's global schedules: mssql_running_plans: 0 beats a ticked box; rpon's own schedules: beat the global line
CODE=$(box rppage3 true); [[ "$CODE" == 200 ]] || fail "C6 R4: ticking rppage3 again: HTTP $CODE"
{ cat "$TMPD/collector.yaml"; printf 'schedules:\n  mssql_running_plans: 0s\n'; } > "$TMPD/collector0.yaml"
T4=$(pq "SELECT now()")
"$TMPD/pgvigil" run -config "$TMPD/collector0.yaml" >"$TMPD/run0.log" 2>&1 & RUNPID=$!
sleep 75
kill "$RUNPID" 2>/dev/null || true; wait "$RUNPID" 2>/dev/null || true; RUNPID=
[[ "$(pq "SELECT ('$(lastrun rppage3)'::timestamptz < '$T4'::timestamptz)::text")" == true ]] || { tail -20 "$TMPD/run0.log" >&2; fail "C6 R4: rppage3 read at $(lastrun rppage3) under the global 0 (started $T4)"; }
[[ "$(pq "SELECT ('$(lastrun rpon)'::timestamptz > '$T4'::timestamptz)::text")" == true ]] || { tail -20 "$TMPD/run0.log" >&2; fail "C6 R4: rpon (its own schedules:) did not read under the global 0"; }
CODE=$(box rppage3 false)
echo "ok   C6: the box is off for every page instance (rppage present at the upgrade, rppage2 added after: no read); ticked, rppage3 reads (audited); cleared, it stops within the list's read; the global 0 stops a ticked one, not a file instance's own schedules:; rpoff ran none; the box refused on a file instance"

# C9 purge() with the wiring's 0190 line (review finding 6): a running plan, a live capture and a plan statistic aged 40
# days are gone after purge(30), the rest kept; the reader may not call mssql_qs_plans_purge
AGE="interval '40 days'"
pq "UPDATE pgvigil.mssql_running_plan SET first_seen = first_seen - $AGE, last_seen = last_seen - $AGE WHERE (instance_id, query_hash, plan_hash, stmt_start, stmt_end) IN
      (SELECT instance_id, query_hash, plan_hash, stmt_start, stmt_end FROM pgvigil.mssql_running_plan ORDER BY last_seen LIMIT 1)" >/dev/null
# a table with no row of its own here (2017 keeps no live plan; E's failures are another part) gets one aged row
pq "INSERT INTO pgvigil.mssql_live_plan (instance_id, captured_at, query_hash, plan_hash, stmt_start, stmt_end, plan_state)
      SELECT instance_id, now() - $AGE, '0x01', '0x01', 0, -1, 'policy' FROM pgvigil.instances WHERE name = 'rpon' AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_live_plan)" >/dev/null
pq "INSERT INTO pgvigil.mssql_qs_force_fail (instance_id, database_name, plan_id, seen_at, count_before, count_after, rise)
      SELECT instance_id, 'pgvqs', -1, now() - $AGE, 0, 1, 1 FROM pgvigil.instances WHERE name = 'rpon'" >/dev/null
pq "UPDATE pgvigil.mssql_live_plan SET captured_at = captured_at - $AGE WHERE live_id = (SELECT min(live_id) FROM pgvigil.mssql_live_plan) AND captured_at > now() - interval '30 days'" >/dev/null
pq "UPDATE pgvigil.mssql_plan_stat SET captured_at = captured_at - $AGE WHERE ctid = (SELECT ctid FROM pgvigil.mssql_plan_stat LIMIT 1)" >/dev/null
CNT="SELECT (SELECT count(*) FROM pgvigil.mssql_running_plan WHERE last_seen < now() - interval '30 days') || '|' || (SELECT count(*) FROM pgvigil.mssql_running_plan)
       || '|' || (SELECT count(*) FROM pgvigil.mssql_live_plan WHERE captured_at < now() - interval '30 days') || '|' || (SELECT count(*) FROM pgvigil.mssql_live_plan)
       || '|' || (SELECT count(*) FROM pgvigil.mssql_plan_stat WHERE captured_at < now() - interval '30 days') || '|' || (SELECT count(*) FROM pgvigil.mssql_plan_stat)
       || '|' || (SELECT count(*) FROM pgvigil.mssql_qs_force_fail WHERE seen_at < now() - interval '30 days') || '|' || (SELECT count(*) FROM pgvigil.mssql_qs_force_fail)"
IFS='|' read -r A1 T1 A2 T2 A3 T3 A4 T4 <<<"$(pq "$CNT")"
pq "SELECT pgvigil.purge(30)" >/dev/null || fail "C9: purge(30)"
IFS='|' read -r B1 U1 B2 U2 B3 U3 B4 U4 <<<"$(pq "$CNT")"
echo "C9 aged / all before: running $A1/$T1, live $A2/$T2, statistics $A3/$T3, forced-plan failures $A4/$T4; after: running $B1/$U1, live $B2/$U2, statistics $B3/$U3, failures $B4/$U4"
[[ "$A1" == 1 && "$B1" == 0 && "$U1" == $((T1 - 1)) ]] || fail "C9: the aged running plan"
[[ "$A2" -ge 1 && "$B2" == 0 && "$U2" == $((T2 - A2)) ]] || fail "C9: the aged live capture"
[[ "$A3" -ge 1 && "$B3" == 0 && "$U3" == $((T3 - A3)) ]] || fail "C9: the aged plan statistic (none to age: the running plans stored no statistics)"
[[ "$A4" -ge 1 && "$B4" == 0 && "$U4" == $((T4 - A4)) ]] || fail "C9: the aged forced-plan failure"
if [[ "$(pq "SELECT count(*) FROM pg_roles WHERE rolname = 'pgvigil_reader'")" == 1 ]]; then
  [[ "$(pq "SELECT has_function_privilege('pgvigil_reader', 'pgvigil.mssql_qs_plans_purge(int)', 'EXECUTE')::text || '|' || has_function_privilege('pgvigil_reader', 'pgvigil.mssql_plans_policy_drop(int, jsonb)', 'EXECUTE')::text")" == "false|false" ]] \
    || fail "C9: the reader may call mssql_qs_plans_purge or mssql_plans_policy_drop"
  RDR="the reader may not call the purge"
else
  RDR="NOT PROVEN: the reader's grant (no pgvigil_reader role on this cluster)"
fi
echo "ok   C9: purge(30) removed the aged running plan, live capture, plan statistic and forced-plan failure and kept the rest; $RDR"
fi

if part D || part E; then
  sqok "D: pgvqs2 with Query Store" "CREATE DATABASE pgvqs2; ALTER DATABASE pgvqs2 SET RECOVERY SIMPLE;
    ALTER DATABASE pgvqs2 SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL, INTERVAL_LENGTH_MINUTES = 1, DATA_FLUSH_INTERVAL_SECONDS = 60);"
fi

if part D; then
echo "== D. the statistics a plan was compiled with =="
for c in d0 d1 d2 d3; do
  NR=; [[ $c == d3 ]] && NR=", NORECOMPUTE"
  sqok "D: table $c" "CREATE TABLE dbo.$c (id int NOT NULL PRIMARY KEY, v int NOT NULL);
    INSERT dbo.$c (id, v) SELECT TOP (20000) n, n FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects x CROSS JOIN sys.all_objects y) z;
    CREATE STATISTICS st_v ON dbo.$c (v) WITH FULLSCAN$NR;" pgvqs2
done
# each case under its own database setting, the change and the compile in that setting
dcase() { local c=$1 opt=$2
  sqok "D: $c setting" "$opt" pgvqs2
  sqok "D: $c change" "UPDATE dbo.$c SET v = v + 1 WHERE id % 10 < 3;" pgvqs2
  # a join: no simple parameterization (it would store the statement's text without the marker)
  sqok "D: $c query" "SELECT COUNT(*) /* pgvd-$c */ FROM dbo.$c a JOIN dbo.$c b ON b.id = a.id WHERE a.v BETWEEN 100 AND 200;" pgvqs2
  sleep 1; }
dcase d0 "ALTER DATABASE pgvqs2 SET AUTO_UPDATE_STATISTICS ON; ALTER DATABASE pgvqs2 SET AUTO_UPDATE_STATISTICS_ASYNC OFF;"
dcase d1 "ALTER DATABASE pgvqs2 SET AUTO_UPDATE_STATISTICS OFF;"
dcase d2 "ALTER DATABASE pgvqs2 SET AUTO_UPDATE_STATISTICS ON; ALTER DATABASE pgvqs2 SET AUTO_UPDATE_STATISTICS_ASYNC ON;"
dcase d3 "ALTER DATABASE pgvqs2 SET AUTO_UPDATE_STATISTICS ON; ALTER DATABASE pgvqs2 SET AUTO_UPDATE_STATISTICS_ASYNC OFF;"
sqok "D: the store flushed" "EXEC sys.sp_query_store_flush_db;" pgvqs2
sqbig "SELECT 'PLAN|' + qt.query_sql_text + '|' + CAST(p.plan_id AS varchar(20)) + '|' + CAST(p.query_plan AS nvarchar(max))
  FROM sys.query_store_plan p JOIN sys.query_store_query q ON q.query_id = p.query_id JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
 WHERE qt.query_sql_text LIKE '%pgvd-d%' AND qt.query_sql_text NOT LIKE '%query_store%'" pgvqs2 2>&1 | sed 's/^/X/' > "$TMPD/d-hand.out" || true
sed -i 's/^X//' "$TMPD/d-hand.out"
col sqlfull mssql_indexes mssql_querystore; col sqlfull mssql_querystore
DRC=0; python3 - "$TMPD" "$PGDSN" "$U" <<'PYEND' || DRC=$?
import json, re, subprocess, sys, urllib.parse
d, dsn, u = sys.argv[1:]
def q(s): return [l.split('|') for l in subprocess.run(['psql', dsn, '-XAtq', '-c', s], check=True, capture_output=True, text=True).stdout.splitlines() if l]
bad = []
raw = open(f"{d}/d-hand.out", errors='replace').read()
hand = {}
for m in re.finditer(r"PLAN\|.*?pgvd-(d\d).*?\|(\d+)\|(<ShowPlanXML.*?</ShowPlanXML>)", raw, re.S):
    c, plan_id, x = m.group(1), m.group(2), m.group(3)
    st = re.search(r'<StatisticsInfo[^>]*Table="\[' + c + r'\]"[^>]*Statistics="\[st_v\]"[^>]*>', x) or re.search(r'<StatisticsInfo[^>]*Statistics="\[st_v\]"[^>]*Table="\[' + c + r'\]"[^>]*>', x)
    mc = re.search(r'ModificationCount="(\d+)"', st.group(0)).group(1) if st else None
    hand[c] = (plan_id, mc)
if not hand:
    print("NOT PROVEN D: no plan of the four queries read by hand from sys.query_store_plan: " + raw[:300].replace('\n', ' ')); sys.exit(3)
if all(v[1] is None for v in hand.values()):
    print(f"NOT PROVEN D: the plans carry no OptimizerStatsUsage on this server ({hand})"); sys.exit(3)
iid = q("SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlfull'")[0][0]
want = {'d0': 'f', 'd1': 't', 'd2': 't', 'd3': 't'}
for c, stale in want.items():
    if c not in hand: bad.append(f"D {c}: no plan read by hand"); continue
    plan_id, mc = hand[c]
    rows = q(f"SELECT modification_count, table_rows, update_line, coalesce(stale_at_compile::text, ''), modified_pct FROM pgvigil.mssql_plan_stat_status WHERE instance_id = {iid} AND source = 'qs' AND database_name = 'pgvqs2' AND plan_id = {plan_id} AND stat_table = '{c}' AND stat_name = 'st_v'")
    if not rows: bad.append(f"D {c}: no stored statistic for plan {plan_id}"); continue
    r = rows[0]
    if r[0] != mc: bad.append(f"D {c}: modification_count {r[0]} != the plan's {mc}")
    if r[1] != '20000' or r[2] != '4472': bad.append(f"D {c}: table rows {r[1]} / line {r[2]} (want 20000 / 4472)")
    if r[3] != {'t': 'true', 'f': 'false'}[stale]: bad.append(f"D {c}: stale_at_compile {r[3]} (want {stale}; modification count {r[0]})")
    f = q(f"SELECT count(*) FROM pgvigil.mssql_querystore_findings WHERE instance_id = {iid} AND check_name = 'a plan compiled on stale statistics' AND object LIKE 'pgvqs2: query %, plan {plan_id}'")
    if (f[0][0] == '1') != (stale == 't'): bad.append(f"D {c}: the finding count {f[0][0]} (stale {stale})")
    print(f"D {c}: plan {plan_id} rows changed {r[0]} of {r[1]} ({r[4]} %), line {r[2]}, stale {r[3]}")
p1 = hand.get('d1', (None,))[0]
out = f"{d}/d.json"
code = subprocess.run(['curl', '-s', '-o', out, '-w', '%{http_code}', '-b', f"{d}/cj", '-H', 'X-Pgvigil: 1', f"{u}/api/mssql/planstats?" + urllib.parse.urlencode({'instance': iid, 'source': 'qs', 'db': 'pgvqs2', 'plan': p1})], capture_output=True, text=True).stdout
b = json.load(open(out)) if code == '200' else {}
rows = [dict(zip(b['stats']['columns'], r)) for r in b.get('stats', {}).get('rows', [])] if b else []
if not any(x['statistic'] == 'st_v' and x['stale_at_compile'] is True for x in rows): bad.append(f"D the API for d1: HTTP {code} {str(b)[:300]}")
for x in bad: print('DIFF', x)
sys.exit(1 if bad else 0)
PYEND
[[ $DRC == 0 || $DRC == 3 ]] || fail "D: see above"
if [[ $DRC == 3 ]]; then echo "NOT PROVEN D on $VER (above)"; else
echo "ok   D: the statistics stored per plan equal the plans' own; stale at compile under AUTO_UPDATE off, ASYNC and NORECOMPUTE, not under synchronous updates; the finding and the API"; fi
fi

if part E; then
echo "== E. a forced plan's failures =="
sqok "E: dbo.f" "CREATE TABLE dbo.f (id int NOT NULL PRIMARY KEY, k int NOT NULL, pad char(200) NOT NULL DEFAULT 'f');
  INSERT dbo.f (id, k) SELECT TOP (20000) n, n FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects x CROSS JOIN sys.all_objects y) z;
  CREATE INDEX ix_f ON dbo.f (k) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE);" pgvqs2
QF="SELECT id /* pgve-forced */ FROM dbo.f WHERE k = 5 OPTION (RECOMPILE);"
sqok "E: the query" "$QF $QF $QF" pgvqs2
sqok "E: flushed" "EXEC sys.sp_query_store_flush_db;" pgvqs2
QP=$(sq "SELECT TOP (1) CAST(q.query_id AS varchar(20)) + '|' + CAST(p.plan_id AS varchar(20)) FROM sys.query_store_query q JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
  JOIN sys.query_store_plan p ON p.query_id = q.query_id WHERE qt.query_sql_text LIKE '%pgve-forced%' AND qt.query_sql_text NOT LIKE '%query_store%' ORDER BY p.plan_id" pgvqs2)
QID=${QP%%|*}; PID=${QP##*|}; [[ -n "$QID" && -n "$PID" ]] || fail "E: the query's ids ($QP)"
sqok "E: forced" "EXEC sys.sp_query_store_force_plan @query_id = $QID, @plan_id = $PID;" pgvqs2
sqok "E: ix_f dropped" "DROP INDEX ix_f ON dbo.f;" pgvqs2
sleep 11   # the forced plan's last run is now more than 10 s before the query's next one
fail_runs() { local i; for i in $(seq 1 "$1"); do sq "$QF" pgvqs2 >/dev/null 2>&1 || true; done; sq "EXEC sys.sp_query_store_flush_db;" pgvqs2 >/dev/null; }
fcount() { sq "SELECT CAST(force_failure_count AS varchar(20)) FROM sys.query_store_plan WHERE plan_id = $PID" pgvqs2; }
judge() { pq "SELECT severity || '|' || detail FROM pgvigil.mssql_querystore_findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'sqlfull' AND f.check_name = 'a forced plan fails' AND f.object = 'pgvqs2: query $QID, plan $PID'"; }
expect() { local got; got=$(judge); [[ "${got%%|*}" == "$2" && "$got" == *"$3"* ]] || fail "$1: want $2 with '$3', got '$got' (server count $(fcount))"; echo "ok   $1: $2 ($(fcount) failure(s) on the server)"; }
fail_runs 1; [[ "$(fcount)" == 1 ]] || echo "E1: the server's count after one run: $(fcount)"
col sqlfull mssql_querystore; expect E1 info "Held: it failed once"
fail_runs 2; col sqlfull mssql_querystore; expect E2 warning "one read saw 2 or more"
sqok "E3: forced anew" "EXEC sys.sp_query_store_unforce_plan @query_id = $QID, @plan_id = $PID; EXEC sys.sp_query_store_force_plan @query_id = $QID, @plan_id = $PID;" pgvqs2
col sqlfull mssql_querystore
[[ "$(pq "SELECT count(*) FROM pgvigil.mssql_qs_force_fail WHERE database_name = 'pgvqs2' AND plan_id = $PID AND reset")" -ge 1 ]] || fail "E3: no reset row after forcing anew (server count $(fcount))"
sleep 11; fail_runs 1; col sqlfull mssql_querystore; expect E3 info "Held: it failed once"
fail_runs 1; col sqlfull mssql_querystore; expect E4 warning "two within 24 hours"
# E5: every row before E4's failure moved 25 h back (the reset with them, so E3's failure stays in the window): two
# failures since the plan was forced anew, 25 h apart - held, and the read named is E4's (the newest starts the 24 h)
E4AT=$(pq "SELECT to_char(max(seen_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') FROM pgvigil.mssql_qs_force_fail WHERE database_name = 'pgvqs2' AND plan_id = $PID AND rise > 0")
pq "UPDATE pgvigil.mssql_qs_force_fail f SET seen_at = seen_at - interval '25 hours'
     WHERE f.database_name = 'pgvqs2' AND f.plan_id = $PID
       AND f.seen_at < (SELECT max(x.seen_at) FROM pgvigil.mssql_qs_force_fail x WHERE x.database_name = 'pgvqs2' AND x.plan_id = $PID AND x.rise > 0)" >/dev/null
[[ "$(pq "SELECT failure_reads || '|' || paged FROM pgvigil.mssql_qs_force_fail_status WHERE database_name = 'pgvqs2' AND plan_id = $PID")" == "2|false" ]] \
  || fail "E5: the window after the move: $(pq "SELECT failure_reads || '|' || paged FROM pgvigil.mssql_qs_force_fail_status WHERE database_name = 'pgvqs2' AND plan_id = $PID") (want 2 failure reads, not paged)"
expect E5 info "Held: no two of its 2 failures since it was forced lie within 24 hours of each other (read $E4AT UTC)"
CODE=$(api "mssql/forcefail?instance=$IF" "$TMPD/e.json"); [[ "$CODE" == 200 ]] && grep -q "\"$PID\"\|,$PID," "$TMPD/e.json" || fail "E: GET /api/mssql/forcefail: HTTP $CODE $(head -c 300 "$TMPD/e.json")"
echo "ok   E: held at one failure, paged at two in one read and at two within 24 h, a new window after forcing anew, held again past 24 h; the API lists it"
fi

if part F; then
echo "== F. one statement on every instance; statements by their text =="
docker run -d --name "$SQL2" --label "$LBL" --memory 4g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
sq2() { printf 'SET NOCOUNT ON;\nGO\n%s\n' "$1" | timeout 120 docker exec -i --env-file "$TMPD/sa.env" "$SQL2" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa '"$TRUST"' -b -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
for _ in $(seq 1 150); do [[ "$(sq2 "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" 2>/dev/null)" == 1 ]] && break; sleep 2; done
PORT2=$(docker port "$SQL2" 1433/tcp | head -1 | sed 's/.*://')
sq2 "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON]; GRANT CONNECT ANY DATABASE TO [$MON];" >/dev/null || fail "F: the second server's login"
TBL="CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, a int NOT NULL, pad char(100) NOT NULL DEFAULT 'p'); INSERT dbo.t (id, a) SELECT TOP (5000) n, n FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects x CROSS JOIN sys.all_objects y) z;"
sq2 "CREATE DATABASE pgvqs;" >/dev/null && sq2 "$TBL" pgvqs >/dev/null || fail "F: the second server's table"
part D || part E || sqok "F: pgvqs2" "CREATE DATABASE pgvqs2; ALTER DATABASE pgvqs2 SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL, INTERVAL_LENGTH_MINUTES = 1);"
sqok "F: dbo.t in pgvqs2" "$TBL" pgvqs2
export PGV_Q_MON2="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT2?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
printf '  - name: f2\n    engine: sqlserver\n    dsn: env:PGV_Q_MON2\n    query_text: full\n' >> "$TMPD/m.yaml"
col sqlfull mssql_plancache; col f2 mssql_instance mssql_plancache
STF="SELECT COUNT(*) FROM dbo.t t1 JOIN dbo.t t2 ON t2.id = t1.id WHERE t1.a > 4990 AND t1.pad <> 'pgvf_marker%_x';"
sqok "F: three runs" "$STF $STF $STF" pgvqs; sqok "F: two runs under Query Store" "$STF $STF EXEC sys.sp_query_store_flush_db;" pgvqs2
sq2 "$STF $STF $STF $STF $STF" pgvqs >/dev/null || fail "F: five runs on f2"
col sqlfull mssql_plancache mssql_querystore; col f2 mssql_plancache
HAND1=$(sq "SELECT CONVERT(varchar(40), qs.query_hash, 1) + '|' + CAST(qs.execution_count AS varchar(20)) + '|' + CAST(qs.total_worker_time AS varchar(20)) + '|' + ISNULL(CAST(t.dbid AS varchar(10)), '0')
  FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t WHERE t.text LIKE '%pgvf[_]marker%' AND t.text NOT LIKE '%dm_exec%'")
HAND2=$(sq2 "SELECT CONVERT(varchar(40), qs.query_hash, 1) + '|' + CAST(qs.execution_count AS varchar(20)) + '|' + CAST(qs.total_worker_time AS varchar(20))
  FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t WHERE t.text LIKE '%pgvf[_]marker%' AND t.text NOT LIKE '%dm_exec%'")
HANDQ=$(sq "SELECT CAST(SUM(rs.count_executions) AS varchar(20)) FROM sys.query_store_runtime_stats rs JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
  JOIN sys.query_store_query q ON q.query_id = p.query_id JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id WHERE qt.query_sql_text LIKE '%pgvf[_]marker%'" pgvqs2)
IF2=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'f2'")
python3 - "$TMPD" "$U" "$IF" "$IF2" "$HAND1" "$HAND2" "$HANDQ" "$PGDSN" <<'PYEND' || fail "F: see above"
import json, subprocess, sys, urllib.parse, datetime
d, u, i1, i2, h1, h2, hq, dsn = sys.argv[1:]
bad = []
def api(path, **q):
    out = f"{d}/f.json"
    code = subprocess.run(['curl', '-s', '-o', out, '-w', '%{http_code}', '-b', f"{d}/cj", '-H', 'X-Pgvigil: 1', f"{u}/api/{path}?{urllib.parse.urlencode(q)}"], capture_output=True, text=True).stdout
    try: return int(code), json.load(open(out))
    except Exception: return int(code), {}
rows1 = [l.split('|') for l in h1.splitlines() if l.count('|') == 3]
rows2 = [l.split('|') for l in h2.splitlines() if l.count('|') == 2]
pc1 = [r for r in rows1 if r[3] != str(0)]
if not rows1 or not rows2: print(f"DIFF F1 the hand reads: {h1!r} {h2!r}"); sys.exit(1)
qh = '0x' + rows1[0][0][2:].upper()
want = {}
for r in rows1:   # the server's statements of the hash: pgvqs's runs (3) and pgvqs2's (2) are two plans in two databases
    want.setdefault('sqlfull', []).append((int(r[1]), int(r[2])))
now = datetime.datetime.now(datetime.timezone.utc); iso = lambda t: t.strftime('%Y-%m-%dT%H:%M:%SZ')
code, b = api('mssql/everywhere', hash=qh, **{'from': iso(now - datetime.timedelta(hours=1)), 'to': iso(now + datetime.timedelta(minutes=5))})
got = [dict(zip(b['rows']['columns'], r)) for r in b.get('rows', {}).get('rows', [])] if code == 200 else []
if code != 200: bad.append(f"F1 HTTP {code} {str(b)[:200]}")
pcfull = sum(float(x['executions']) for x in got if x['instance'] == 'sqlfull' and x['source'] == 'plan cache')
pcf2 = [x for x in got if x['instance'] == 'f2' and x['source'] == 'plan cache']
qsfull = [x for x in got if x['instance'] == 'sqlfull' and x['source'] == 'Query Store']
hand_full = sum(e for e, _ in want['sqlfull']); hand_f2 = sum(int(r[1]) for r in rows2); cpu_f2 = sum(int(r[2]) for r in rows2) / 1000.0
if pcfull != hand_full: bad.append(f"F1 sqlfull plan cache executions {pcfull} != hand {hand_full} ({rows1})")
if not pcf2 or float(pcf2[0]['executions']) != hand_f2: bad.append(f"F1 f2 plan cache {pcf2} != hand {hand_f2}")
elif abs(float(pcf2[0]['cpu_ms']) - cpu_f2) > 1: bad.append(f"F1 f2 CPU {pcf2[0]['cpu_ms']} vs hand {cpu_f2}")
if not qsfull or float(qsfull[0]['executions']) != float(hq or 0): bad.append(f"F1 sqlfull Query Store {qsfull} != hand {hq}")
if b.get('note'): bad.append(f"F4 a PostgreSQL note with no PostgreSQL instance: {b.get('note')}")
print(f"F1 {qh}: plan cache sqlfull {pcfull} / f2 {hand_f2}, Query Store {hq}")
code, b = api('mssql/search', q='marker%_x')
srcs = {x['source']: x for x in b.get('sources', [])} if code == 200 else {}
pc = [dict(zip(srcs['plan cache']['rows']['columns'], r)) for r in srcs['plan cache']['rows']['rows']] if srcs.get('plan cache', {}).get('rows') else []
names = {x['instance'] for x in pc if x['statement_key'] == qh}
if code != 200 or not {'sqlfull', 'f2'} <= names: bad.append(f"F2 search: HTTP {code} instances {names} {str(b)[:300]}")
if 'sqlnone' not in (b.get('no_text') or []) or 'sqlnorm' not in (b.get('normalized') or []): bad.append(f"F2 policy lists: no_text {b.get('no_text')} normalized {b.get('normalized')}")
if any(not (x.get('present') is False) for x in [dict(zip(b['text_indexes']['columns'], r)) for r in b['text_indexes']['rows']]): bad.append(f"F3 an index present before the DBA's statements: {b['text_indexes']}")
code, b = api('mssql/search', q='marker__x')
n = sum(len(x['rows']['rows']) for x in b.get('sources', []) if x.get('rows'))
if code != 200 or n != 0: bad.append(f"F2 '_' taken as a wildcard: HTTP {code}, {n} rows")
code, b = api('mssql/search', q='marker%_x', instance=i2)
pc = [dict(zip(x['rows']['columns'], r)) for x in b.get('sources', []) if x.get('rows') for r in x['rows']['rows']]
if code != 200 or not pc or {x['instance'] for x in pc} != {'f2'}: bad.append(f"F2 instance=f2: {pc}")
for x in bad: print('DIFF', x)
sys.exit(1 if bad else 0)
PYEND
psql "$ADMIN_DSN dbname=$PGDB" -Xq -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_trgm" >/dev/null 2>&1 || pq "CREATE EXTENSION IF NOT EXISTS pg_trgm" >/dev/null || fail "F3: CREATE EXTENSION pg_trgm"
psql "$PGDSN" -Xq -v ON_ERROR_STOP=1 -c "CREATE INDEX CONCURRENTLY IF NOT EXISTS mssql_pc_text_query_trgm ON pgvigil.mssql_pc_text USING gin (query gin_trgm_ops)" >/dev/null || fail "F3: CREATE INDEX CONCURRENTLY"
CODE=$(api "mssql/search?q=marker%25_x" "$TMPD/f3.json")
python3 - "$TMPD/f3.json" <<'PYEND' || fail "F3: see above"
import json, sys
b = json.load(open(sys.argv[1]))
idx = {r[0]: dict(zip(b['text_indexes']['columns'], r)) for r in b['text_indexes']['rows']}
p = idx.get('mssql_pc_text_query_trgm', {})
if not (p.get('present') and p.get('valid') and p.get('ready')): print('DIFF F3 the index state', idx); sys.exit(1)
if not any(x.get('rows') and x['rows']['rows'] for x in b['sources']): print('DIFF F3 the search found nothing with the index'); sys.exit(1)
PYEND
pq "SELECT pgvigil.ensure_instance('pgf_$SUF', 'auto', '17.0', 170000, false, '{}'::text[])" >/dev/null || fail "F4: a PostgreSQL instance"
CODE=$(api "mssql/search?q=marker%25_x" "$TMPD/f4.json"); grep -q 'PostgreSQL instances are not compared or searched here' "$TMPD/f4.json" || fail "F4: no note with a PostgreSQL instance held: $(head -c 300 "$TMPD/f4.json")"
# F5: the search follows each instance's policy NOW, not the policy its stored texts were sent under
STORED=$(pq "SELECT (SELECT count(*) FROM pgvigil.mssql_pc_text WHERE instance_id = $IF AND query ILIKE '%marker%') + (SELECT count(*) FROM pgvigil.mssql_qs_query WHERE instance_id = $IF AND query_text ILIKE '%marker%')")
[[ "$STORED" -ge 1 ]] || fail "F5: sqlfull holds no stored text with the marker to begin with"
set_qt sqlfull none; serve_restart f5
CODE=$(api "mssql/search?q=marker%25_x" "$TMPD/f5a.json"); CODE2=$(api "mssql/search?q=marker%25_x&instance=$IF" "$TMPD/f5b.json")
python3 - "$TMPD/f5a.json" "$TMPD/f5b.json" <<'PYEND' || fail "F5: see above (red on 92fc66cd: sqlfull's stored texts come back)"
import json, sys
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
rows = lambda d: [dict(zip(x['rows']['columns'], r)) for x in d.get('sources', []) if x.get('rows') for r in x['rows']['rows']]
full = [x for x in rows(a) if x['instance'] == 'sqlfull']
bad = []
if full: bad.append(f"every instance: {len(full)} row(s) of sqlfull (policy none): {[(x['source'], x['statement'][:40]) for x in full][:3]}")
if 'sqlfull' not in (a.get('no_text') or []): bad.append(f"no_text {a.get('no_text')}")
if not [x for x in rows(a) if x['instance'] == 'f2']: bad.append("f2's rows are gone too")
if rows(b): bad.append(f"instance=sqlfull: {len(rows(b))} row(s)")
for x in bad: print('DIFF F5', x)
sys.exit(1 if bad else 0)
PYEND
echo "ok   F5: sqlfull's policy set to none: none of its $STORED stored text(s) is returned (every instance, or it alone), it is named under no_text, f2's rows still come"
set_qt sqlfull full; serve_restart f5back
echo "ok   F: one statement's executions per instance and source equal the servers' own; the search finds it on both, % and _ as they are, the policies named; the trigram index's state; the PostgreSQL note; the policy now (F5)"
fi

if part G; then
echo "== G. the STATISTICS IO / TIME reader =="
[[ -f web/src/mssql_statsio.ts ]] || fail "G: no web/src/mssql_statsio.ts"
[[ -x web/node_modules/.bin/esbuild ]] || (cd web && npm ci --no-audit --no-fund >"$TMPD/npm.log" 2>&1) || { tail -20 "$TMPD/npm.log" >&2; fail "G: npm ci"; }
web/node_modules/.bin/esbuild web/src/mssql_statsio.ts --format=esm --outfile="$TMPD/mssql_statsio.mjs" --log-level=warning || fail "G: esbuild"
G1="SELECT COUNT(*) FROM dbo.t WHERE a < 2500 OPTION (MAXDOP 1) /* pgvg1 */;"
G2="SELECT TOP (100) id FROM dbo.big ORDER BY id OPTION (MAXDOP 1) /* pgvg2 */;"
printf 'SET NOCOUNT OFF;\nSET STATISTICS IO, TIME ON;\nGO\n%s\nGO\n%s\nGO\n' "$G1" "$G2" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa '"$TRUST"' -d pgvqs -i /dev/stdin' > "$TMPD/captured.txt" 2>&1 || fail "G: the capture"
EXP=$(sq "SELECT CAST(qs.last_logical_reads AS varchar(20)) + '|' + CAST(qs.last_rows AS varchar(20)) + '|' + CASE WHEN t.text LIKE '%pgvg1%' THEN '1' ELSE '2' END
  FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t WHERE (t.text LIKE '%pgvg1%' OR t.text LIKE '%pgvg2%') AND t.text NOT LIKE '%dm_exec%'")
python3 - "$TMPD/captured.txt.expect.json" "$EXP" <<'PYEND' || fail "G: the expected figures"
import json, sys
rows = sorted((l.split('|') for l in sys.argv[2].splitlines() if l.count('|') == 2), key=lambda r: r[2])
if len(rows) != 2: print('DIFF G the server read', sys.argv[2]); sys.exit(1)
json.dump({'statements': 2, 'logical_reads': [int(r[0]) for r in rows], 'rows': [int(r[1]) for r in rows]}, open(sys.argv[1], 'w'))
PYEND
node web/src/mssql_statsio.test.mjs "$TMPD/mssql_statsio.mjs" "$TMPD/captured.txt" > "$TMPD/g.out" 2>&1 || { cat "$TMPD/g.out"; head -40 "$TMPD/captured.txt"; fail "G: the reader's tests"; }
grep -E '^ok   captured|of [0-9]+ ok' "$TMPD/g.out"
echo "ok   G: the reader's unit tests, and a captured messages file read equal to the server's own figures"
fi

if part H; then
echo "== H. evict one plan through the actions door =="
ACT1=pgv_ev1_$SUF; ACT2=pgv_ev2_$SUF; ACT3=pgv_ev3_$SUF; ACTS=pgv_evs_$SUF; P1=$(pw); P2=$(pw); P3=$(pw); PS=$(pw); CERTPW=$(pw)
sqok "H: the logins" "CREATE LOGIN [$ACT1] WITH PASSWORD = '$P1', CHECK_POLICY = OFF; CREATE LOGIN [$ACT2] WITH PASSWORD = '$P2', CHECK_POLICY = OFF;
  CREATE LOGIN [$ACT3] WITH PASSWORD = '$P3', CHECK_POLICY = OFF; CREATE LOGIN [$ACTS] WITH PASSWORD = '$PS', CHECK_POLICY = OFF;
  GRANT ALTER SERVER STATE TO [$ACT2]; ALTER SERVER ROLE sysadmin ADD MEMBER [$ACTS];"
# docs/sqlserver-actions.md's script, the actions login's name and the passwords put in
python3 - docs/sqlserver-actions.md "$ACT1" "$CERTPW" > "$TMPD/signed.sql" <<'PYEND' || fail "H: the documented script"
import re, sys
doc, act, pw = sys.argv[1:]
t = open(doc).read().split('### For plan_evict: a certificate-signed procedure')[1]
sql = re.search(r'```sql\n(.*?)```', t, re.S).group(1)
print(sql.replace('[pgvigil_actions]', '[' + act + ']').replace('<a long random password>', pw).replace('<the password above>', pw).replace('USE master;', ''))
PYEND
docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa '"$TRUST"' -b -I -d master -i /dev/stdin' <"$TMPD/signed.sql" >"$TMPD/signed.out" 2>&1 || { cat "$TMPD/signed.out"; fail "H: the signed procedure (the docs' script)"; }
dsn() { echo "sqlserver://$1:$(urlq "$2")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"; }
export EV1="$(dsn "$ACT1" "$P1")" EV2="$(dsn "$ACT2" "$P2")" EV3="$(dsn "$ACT3" "$P3")" EVS="$(dsn "$ACTS" "$PS")"
# a read login without VIEW ANY DEFINITION (docs/sqlserver.md calls it optional): it cannot see the signed procedure
MONV=pgv_qmonv_$SUF; MONV_PW=$(pw)
sqok "H: the read login without VIEW ANY DEFINITION" "CREATE LOGIN [$MONV] WITH PASSWORD = '$MONV_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MONV]; GRANT CONNECT ANY DATABASE TO [$MONV];"
export PGV_Q_MONV="$(dsn "$MONV" "$MONV_PW")"
for spec in "ev_signed EV1 [plan_evict] full" "ev_off EV1 [kill] full" "ev_noright EV3 [plan_evict] full" "ev_sa EVS [plan_evict] full" "ev_none EV1 [plan_evict] none" "ev_direct EV2 [plan_evict] full" "ev_rd EV1 [plan_evict] full PGV_Q_MONV"; do
  read -r n a l qt rd <<<"$spec"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:%s\n    actions_dsn: env:%s\n    actions: %s\n    query_text: %s\n' "$n" "${rd:-PGV_Q_MON}" "$a" "$l" "$qt" >> "$TMPD/m.yaml"
  pq "SELECT pgvigil.ensure_instance('$n', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')" >/dev/null
done
kill "$SRVPID" 2>/dev/null; wait "$SRVPID" 2>/dev/null || true
"$TMPD/pgvigil" serve -config "$TMPD/m.yaml" -listen "127.0.0.1:$WPORT" >"$TMPD/serve2.out" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve2.out" >&2; fail "H: serve exited (a binary without the wiring refuses plan_evict in actions:)"; }
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "H: the API login"
iid() { pq "SELECT instance_id FROM pgvigil.instances WHERE name = '$1'"; }
# act <preview|run> <instance> <json fields>: the code; the reply in $TMPD/h.json
act() { local body; body=$(python3 -c 'import json, sys; d = json.loads(sys.argv[2]); d["instance_id"] = int(sys.argv[1]); d["action"] = "plan_evict"; print(json.dumps(d))' "$(iid "$2")" "$3")
  curl -s -o "$TMPD/h.json" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "$body" "$U/api/mssql/actions/$1"; }
jv() { python3 -c 'import json, sys; v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else v)' "$TMPD/h.json" "$1"; }
# plan2: two plans of dbo.p_two (ARITHABORT ON and OFF: another cache key), one line each 'plan handle|sql handle'
plan2() { sq "SET ARITHABORT ON; EXEC dbo.p_two;" pgvqs >/dev/null; sq "SET ARITHABORT OFF; EXEC dbo.p_two;" pgvqs >/dev/null
  sq "SELECT CONVERT(varchar(140), cp.plan_handle, 1) + '|' + CONVERT(varchar(140), MIN(qs.sql_handle), 1) FROM sys.dm_exec_cached_plans cp CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) t
       JOIN sys.dm_exec_query_stats qs ON qs.plan_handle = cp.plan_handle WHERE t.objectid = OBJECT_ID('pgvqs.dbo.p_two') AND t.dbid = DB_ID('pgvqs') GROUP BY cp.plan_handle ORDER BY cp.plan_handle"; }
up0x() { local h="0x${1:2}"; h=${h^^}; echo "0x${h:2}"; }
# code: the plan's code as the lead wrote it (the first 8 hex digits of SHA-256 over the handle's bytes), computed here
code() { python3 -c 'import hashlib, sys; print(hashlib.sha256(bytes.fromhex(sys.argv[1][2:])).hexdigest()[:8].upper())' "$1"; }
HH=$(plan2); L1=$(sed -n 1p <<<"$HH"); L2=$(sed -n 2p <<<"$HH"); PH=$(up0x "${L1%%|*}"); SH=${L1##*|}; PH2=$(up0x "${L2%%|*}")
[[ ${#PH} -gt 10 && ${#PH2} -gt 10 && "$PH" != "$PH2" ]] || fail "H0: want two plans of dbo.p_two in the cache (ARITHABORT ON and OFF): $HH"
CODE=$(code "$PH"); CODE2=$(code "$PH2")
echo "H0: two plans of dbo.p_two: ...${PH: -8} and ...${PH2: -8} (last 8 digits), bytes 4-7 ${PH:10:8} / ${PH2:10:8}, codes $CODE / $CODE2"
C=$(act preview ev_off "{\"plan_handle\":\"$PH\"}"); [[ $C == 200 && "$(jv ok)" == False && "$(jv reason)" == *"not on the instance's actions: list"* ]] || fail "H1: $C $(cat "$TMPD/h.json")"
C=$(act preview ev_signed '{"plan_handle":"0x123"}'); [[ "$(jv reason)" == plan_handle:* ]] || fail "H2 preview: $C $(cat "$TMPD/h.json")"
C=$(act run ev_signed '{"plan_handle":"0x123","objtype":"Proc","reason":"the proof asks","confirm":"123"}'); [[ $C == 409 ]] || fail "H2 run: $C $(cat "$TMPD/h.json")"
C=$(act preview ev_signed "{\"plan_handle\":\"$SH\"}"); [[ "$(jv ok)" == False && "$(jv reason)" == *"no plan under this handle"* ]] || fail "H3: $C $(cat "$TMPD/h.json")"
C=$(act preview ev_signed "{\"plan_handle\":\"$PH2\"}"); [[ $C == 200 && "$(jv confirm)" == "$CODE2" ]] || fail "H10 the other plan's code: $C $(cat "$TMPD/h.json")"
C=$(act preview ev_signed "{\"plan_handle\":\"$PH\"}"); [[ $C == 200 && "$(jv ok)" == True ]] || fail "H8 preview: $C $(cat "$TMPD/h.json")"
[[ "$(jv confirm)" == "$CODE" && "$CODE" != "$CODE2" ]] || fail "H10: the preview's code $(jv confirm), want $CODE (the other plan's $CODE2)"
CREATED=$(jv target.plan_created); [[ "$(jv target.objtype)" == Proc && "$(jv what)" == "Proc dbo.p_two in pgvqs" && "$(jv target.plan_statements)" == 2 && "$(jv target.plan_route)" == "signed procedure" ]] || fail "H8 preview's target: $(cat "$TMPD/h.json")"
C=$(act preview ev_none "{\"plan_handle\":\"$PH\"}"); [[ -z "$(jv target.plan_batch)" && "$(jv note)" == *'"none"'* ]] || fail "H7: $C $(cat "$TMPD/h.json")"
run_body() { echo "{\"plan_handle\":\"$PH\",\"objtype\":\"Proc\",\"plan_created\":\"$1\",\"job_name\":\"Proc dbo.p_two in pgvqs\",\"reason\":\"the proof asks for it\",\"confirm\":\"$2\"}"; }
C=$(act run ev_noright "$(run_body "$CREATED" "$CODE")"); [[ $C == 502 && "$(jv server_message)" == Msg* ]] || fail "H4: $C $(cat "$TMPD/h.json")"
C=$(act run ev_sa "$(run_body "$CREATED" "$CODE")"); [[ $C == 409 && "$(jv detail)" == *"sysadmin or holds CONTROL SERVER"* ]] || fail "H5: $C $(cat "$TMPD/h.json")"
C=$(act run ev_signed "$(run_body "2001-01-01T00:00:00" "$CODE")"); [[ $C == 409 && "$(jv detail)" == *"another plan under this handle"* ]] || fail "H6: $C $(cat "$TMPD/h.json")"
for wrong in 00000000 "$CODE2"; do
  C=$(act run ev_signed "$(run_body "$CREATED" "$wrong")"); [[ $C == 409 && "$(jv detail)" == *"typed confirmation"* ]] || fail "H10 '$wrong': $C $(cat "$TMPD/h.json")"
done
[[ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_cached_plans WHERE plan_handle IN ($PH, $PH2)")" == 2 ]] || fail "H4-H10: a plan left the cache before the evict"
C=$(act run ev_signed "$(run_body "$CREATED" "${CODE,,}")"); [[ $C == 200 && "$(jv outcome)" == done && "$(jv detail)" == *"gone from the cache"* ]] || fail "H8 run: $C $(cat "$TMPD/h.json")"
[[ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_cached_plans WHERE plan_handle = $PH")" == 0 ]] || fail "H8: the plan is still cached"
LOGROW=$(pq "SELECT action || '|' || outcome || '|' || coalesce(target, '') || '|' || coalesce(target_id, '') FROM pgvigil.actions_log WHERE instance_name = 'ev_signed' AND outcome = 'done'")
[[ "$LOGROW" == "plan_evict|done|Proc dbo.p_two in pgvqs|$PH" ]] || fail "H8: the audit row '$LOGROW'"
[[ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_cached_plans WHERE plan_handle = $PH2")" == 1 ]] || fail "H8: the other plan of dbo.p_two left the cache too"
C=$(act run ev_signed "$(run_body "$CREATED" "$CODE")"); [[ $C == 409 && "$(jv detail)" == *"no plan under"* ]] || fail "H9: $C $(cat "$TMPD/h.json")"
C=$(curl -s -o "$TMPD/h.json" -w '%{http_code}' -b "$TMPD/cj" "$U/api/mssql/actions/state?instance=$(iid ev_signed)")
[[ "$(jv actions_login.may_execute)" == True && "$(jv actions_login.view_server_state)" == False && "$(jv actions_login.alter_server_state)" == False ]] || fail "H12 ev_signed: $(cat "$TMPD/h.json" | head -c 400)"
# H11: the route is the actions login's: ev_direct (ALTER SERVER STATE, no EXECUTE on the procedure) while the procedure
# exists goes direct; H13: ev_rd (its read login cannot see the procedure) goes through it
HH=$(plan2); PH=$(up0x "$(sed -n 1p <<<"$HH" | cut -d'|' -f1)")
C=$(act preview ev_direct "{\"plan_handle\":\"$PH\"}"); CREATED=$(jv target.plan_created); [[ "$(jv target.plan_route)" == direct && "$(jv confirm)" == "$(code "$PH")" ]] || fail "H11 preview: $C $(cat "$TMPD/h.json")"
C=$(act run ev_direct "$(run_body "$CREATED" "$(code "$PH")")"); [[ $C == 200 && "$(jv detail)" == *"gone from the cache"* && "$(jv statement)" == "DBCC FREEPROCCACHE ($PH)" ]] || fail "H11 run (the procedure in master): $C $(cat "$TMPD/h.json")"
[[ "$(sq "SELECT CAST(CASE WHEN OBJECT_ID(N'master.dbo.pgvigil_evict_plan', N'P') IS NULL THEN 0 ELSE 1 END AS varchar(1))")" == 1 ]] || fail "H11: the procedure is gone before H13"
HH=$(plan2); PH=$(up0x "$(sed -n 1p <<<"$HH" | cut -d'|' -f1)")
C=$(act preview ev_rd "{\"plan_handle\":\"$PH\"}"); CREATED=$(jv target.plan_created); [[ "$(jv target.plan_route)" == "signed procedure" ]] || fail "H13 preview: $C $(cat "$TMPD/h.json")"
C=$(act run ev_rd "$(run_body "$CREATED" "$(code "$PH")")"); [[ $C == 200 && "$(jv detail)" == *"gone from the cache"* && "$(jv statement)" == "EXEC master.dbo.pgvigil_evict_plan @plan_handle = $PH" ]] || fail "H13 run (a read login without VIEW ANY DEFINITION): $C $(cat "$TMPD/h.json")"
sqok "H11b: the procedure dropped" "DROP PROCEDURE dbo.pgvigil_evict_plan;"
HH=$(plan2); PH=$(up0x "$(sed -n 1p <<<"$HH" | cut -d'|' -f1)")
C=$(act preview ev_signed "{\"plan_handle\":\"$PH\"}"); [[ "$(jv target.plan_route)" == direct ]] || fail "H11b: without the procedure ev_signed's route: $C $(cat "$TMPD/h.json")"
C=$(act preview ev_direct "{\"plan_handle\":\"$PH\"}"); CREATED=$(jv target.plan_created); [[ "$(jv target.plan_route)" == direct ]] || fail "H11b preview: $C $(cat "$TMPD/h.json")"
C=$(act run ev_direct "$(run_body "$CREATED" "$(code "$PH")")"); [[ $C == 200 && "$(jv detail)" == *"gone from the cache"* && "$(jv statement)" == "DBCC FREEPROCCACHE ($PH)" ]] || fail "H11b run: $C $(cat "$TMPD/h.json")"
C=$(curl -s -o "$TMPD/h.json" -w '%{http_code}' -b "$TMPD/cj" "$U/api/mssql/actions/state?instance=$(iid ev_direct)")
[[ "$(jv actions_login.alter_server_state)" == True && "$(jv actions_login.view_server_state)" == True ]] || fail "H12 ev_direct: $(head -c 400 "$TMPD/h.json")"
echo "ok   H: refused when off, malformed, a SQL handle, another plan, a wrong confirmation (00000000, the other plan's code), a sysadmin login; two plans of one procedure, two codes; failed with the server's words without the right; done through the signed procedure and directly, the plan gone, the audit row; the route by the actions login's right (direct with the procedure present, signed with a read login that cannot see it); the actions login's rights"
fi

echo "PASS: proof-mssql-qs-plans parts $PARTS on SQL Server $VER"
