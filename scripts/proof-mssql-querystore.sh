#!/usr/bin/env bash
# Proof of the SQL Server Query Store collection (migration 0083, internal/mssql/querystore.go), its API
# (internal/web/q_mssql_querystore.go) and its demo rows, against ONE SQL Server (real Query Stores) and the demo.
#
# Needs: docker, psql, curl, jq, iconv, sha256sum, go (unless PGVIGIL_BIN names a built binary), and
#   PGVIGIL_ADMIN_DSN   a superuser connection to a PostgreSQL in KEYWORD form, without dbname (PGVIGIL_REPO_DSN is
#                       taken when it is not set).
# The SQL Server: with MSSQL_SA_PASSWORD set, the container PGVIGIL_MSSQL_CONTAINER (default mssql-sandbox) reachable
# on PGVIGIL_MSSQL_ADDR (default localhost:1433); without it the proof starts its own container of
# PGVIGIL_MSSQL_IMAGE (default mcr.microsoft.com/mssql/server:2022-latest) with a throwaway sa password and removes
# it at the end. The proof builds ONE binary into its temp folder and uses it throughout. It makes two repository
# databases (pgvigil_p4s1_qs_*, pgvigil_p4s1_qsdemo_*), three logins and three databases (pgvproof_p4s1_qs*) on the
# server, and drops them at the end, on every exit path. It changes no server setting.
# PGVIGIL_SKIP_DEMO=1 leaves the demo part out (the last line then says so and does not say PASS for it).
#
# Expected (written before the first run):
#  A. store state. As the monitoring login (VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE), after
#     `collect -once mssql_querystore`: for each of the three proof databases the stored desired state, actual
#     state, read-only reason, max size, interval length, capture mode, cleanup mode, wait statistics mode, flush
#     interval, stale threshold and max plans per query equal sa's read of sys.database_query_store_options in
#     that database. The first has its store on (READ_WRITE, 1-minute intervals), the third OFF / OFF with no
#     judgement. master and tempdb are not listed.
#  B. the top list. In the first database four procedures ran 300, 5, 40 and 200 times. The stored runtime rows
#     give each procedure's statement exactly those executions; its duration, CPU and logical reads equal sa's
#     read of the store summed the same way (a total per plan and interval cut to whole microseconds; 50 either
#     way allowed for the float sums) and its largest memory grant and wait time equal sa's. Through the API, for
#     each of order = duration, cpu, reads, memory, executions the four statements come in sa's order by that
#     figure (ties by query id).
#  C. a forced plan that fails. A plan forced for a fifth procedure whose index is then dropped: the stored plan is
#     forced, its failure count equals sa's and is at least 1, its reason equals sa's (NO_INDEX); the finding
#     'a forced plan fails' names it; the API's forced part lists it.
#  D. a regression. A sixth procedure runs 50 times with an index in one interval; the index is dropped after the
#     interval's end and it runs 50 times again: the API's regressed part for the five minutes from that interval
#     end lists the procedure's new plan with new_plan true, 50 executions now and 50 before, and a duration
#     ratio of 1.5 or more; the query route gives its two plans and a series row per interval and plan.
#  E. a read-only store. The second database's store is filled past MAX_STORAGE_SIZE_MB = 1 until SQL Server sets
#     it READ_ONLY: the stored reason equals sa's (65536), the store is judged warning with a verdict naming the
#     max size, the finding 'Query Store is read-only' names the database, mssql_querystore_status counts it, and
#     the Summary's 'qs' cell of the instance reads warning 1 or more.
#  F. the text policy. The same server collected under query_text normalized and none: under full a stored text
#     carries the workload's literal 'pv-secret-7781' and plan XML is stored; under normalized no stored text
#     carries the literal, one carries "a.pad = ?", and no plan XML is stored (state 'policy'); under none no text
#     at all and no plan XML. A second run of the full instance reads no stored plan's XML again (its
#     xml_checked_at stays).
#  G. rights. A login without VIEW SERVER STATE: the run is skipped naming the right. A login with VIEW SERVER
#     STATE and no way into the databases: the proof databases are listed 'not read' naming CONNECT ANY DATABASE.
#  H. the .sqlplan download of the first procedure's plan is byte for byte sa's query_plan (SHA-256 of the UTF-16
#     text on both sides) with a .sqlplan file name; the same plan under the none instance answers 404.
# Then, without a server:
#  X. imports of written payloads for a database named 'a:b': a payload imported twice leaves the same rows; a
#     payload older than the stored read stores nothing; an interval read again is replaced whole (9 and 1
#     executions, not 5 + 9); a forced plan the next plan read does not list is no longer forced; the cursors
#     qs_since (the newest interval's start as epoch seconds) and qs_plan (the plan's hash while its XML is stored,
#     or was looked at under the policy within a day; NULL otherwise) answer, and jobs / jobs_mark still do; a
#     plan number that arrives with another hash loses its XML and its cursor, and the old runtime rows do not
#     join the new query's text; a database a later read no longer lists leaves the state.
#  Y. the judgements on written stores: ERROR critical; READ_ONLY by size warning; READ_ONLY as a secondary or in
#     a read-only database nothing; READ_ONLY by size on a secondary warning; READ_ONLY as asked for warning;
#     OFF though asked for warning; OFF and not asked for nothing; 95 of 100 MB with cleanup off info, with cleanup
#     auto nothing; a store not read nothing. The status row: critical 1, warning 4, value '7 of 10 on'.
#  Z. the import refuses a PostgreSQL instance; the collector role may execute the import and the cursor and the
#     reader may not execute the import; the reader may select the views.
#  V. 0083 on PostgreSQL 13 (the stopped container PG13_PROOF, default pgv-pg13-proof on 127.0.0.1:5413 with trust;
#     where there is none the proof starts a postgres:13 container of its own and removes it): a fresh database
#     migrates without error, X's first payload imported twice leaves 1|1|2|2|5 and the plan cursor 11, and Y's
#     payload gives the same judgements as on the repository's own PostgreSQL. PGVIGIL_SKIP_PG13=1 leaves it out.
#  P. the API: every part of /api/mssql/querystore answers; an unknown order, an over-long db, a query route
#     without db and a plan that does not exist answer 400, 400, 400 and 404.
#  DEMO. a two-day demo: DEMO-SQL01's top list has at least 8 queries; its regressed part for the last hour lists
#     query 1's plan 12 as a new plan at 1.5 times or more; forced lists Orders' plan 44 with at least 17 failures
#     and Sales' plan 5; tuning lists the recommendation PR_1; Reporting's store is READ_ONLY and judged warning;
#     the findings name both; the status row reads warning 1 for sql01 and 0 for sql02 (a secondary replica's
#     read-only store); plan 7's .sqlplan downloads and is a ShowPlanXML document.
#  NOT PROVEN HERE: SQL Server 2016, 2017 and 2019 (their column sets), Amazon RDS, Managed Instance, Azure SQL
#     Database (the collector says 'not yet'), a real automatic tuning recommendation, a store in the ERROR state on
#     a real server, a cleared store on a real server (X's renumbering is on written payloads), the 60,000-row and
#     64 MB bounds of one run, whether the interval floor seeks (the access path was not looked at), a browser
#     render of the page.
set -euo pipefail
ADMIN_DSN=${PGVIGIL_ADMIN_DSN:-${PGVIGIL_REPO_DSN:?PGVIGIL_ADMIN_DSN: a superuser connection without dbname}}
for t in psql curl jq docker iconv sha256sum; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
SUF=$RANDOM
REPO_DB=pgvigil_p4s1_qs_$SUF; DEMO_DB=pgvigil_p4s1_qsdemo_$SUF
L1=pgv_qs_$SUF; L2=pgv_qsbare_$SUF; L3=pgv_qsvss_$SUF
DB1=pgvproof_p4s1_qs_$SUF; DB2=pgvproof_p4s1_qsfull_$SUF; DB3=pgvproof_p4s1_qsoff_$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
P1=$(pw); P2=$(pw); P3=$(pw)
WORK=$(mktemp -d); CFG=$WORK/cfg.yaml; OUT=$WORK/out
fail() { echo "FAIL: $*" >&2; exit 1; }
MADE_REPO=; MADE_DEMO=; MADE_DBS=(); MADE_L=(); MADE_CT=; SRV_PID=; DEMO_PID=
V13=; V13DB=pgvigil_p4s1_qs13_$SUF; MADE_13=; PG13_STOP=; PG13_RM=
CT=${PGVIGIL_MSSQL_CONTAINER:-mssql-sandbox}; ADDR=${PGVIGIL_MSSQL_ADDR:-localhost:1433}
freeport() { for p in $(seq "$1" "$2"); do ss -ltn | grep -qE "(127.0.0.1|\[::1\]|\*|0.0.0.0):$p " || { echo "$p"; return; }; done; }
# sq <sql> [database]: as sa, the password through the environment by name
sq() { docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -W -h -1 -s '|' -U sa -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
# sqs [database]: as sa, the batch on stdin (a login's password never rides a command line)
sqs() { docker exec -i -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -U sa -d "${1:-master}" -i /dev/stdin; }
cleanup() {
  rc=$?
  for p in "$SRV_PID" "$DEMO_PID"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  if [ -n "$MADE_CT" ]; then
    docker rm -f "$CT" >/dev/null 2>&1 || echo "CLEANUP: container $CT not removed" >&2
  else
    for d in "${MADE_DBS[@]:-}"; do
      [ -n "$d" ] || continue
      sq "IF DB_ID('$d') IS NOT NULL BEGIN ALTER DATABASE [$d] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$d]; END" >/dev/null 2>&1 || echo "CLEANUP: database $d not dropped" >&2
    done
    for l in "${MADE_L[@]:-}"; do
      [ -n "$l" ] || continue
      sq "IF SUSER_ID('$l') IS NOT NULL DROP LOGIN [$l];" >/dev/null 2>&1 || echo "CLEANUP: login $l not dropped" >&2
    done
  fi
  [ -n "$MADE_13" ] && { psql "$V13" -XAtq -c "drop database if exists $V13DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $V13DB on PostgreSQL 13 not dropped" >&2; }
  [ -n "$PG13_STOP" ] && { docker stop "$PG13_STOP" >/dev/null 2>&1 || echo "CLEANUP: container $PG13_STOP not stopped" >&2; }
  [ -n "$PG13_RM" ] && { docker rm -f "$PG13_RM" >/dev/null 2>&1 || echo "CLEANUP: container $PG13_RM not removed" >&2; }
  for d in "$REPO_DB:$MADE_REPO" "$DEMO_DB:$MADE_DEMO"; do
    [ -n "${d#*:}" ] && { psql "$ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists ${d%%:*} with (force)" >/dev/null 2>&1 || echo "CLEANUP: database ${d%%:*} not dropped" >&2; }
  done
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT

# one binary for the whole proof
BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then
  BIN=$WORK/pgvigil
  CGO_ENABLED=0 go build -trimpath -o "$BIN" ./cmd/pgvigil || fail "the build"
fi

# the SQL Server: the sandbox named, or a container of the proof's own
if [ -z "${MSSQL_SA_PASSWORD:-}" ]; then
  export MSSQL_SA_PASSWORD; MSSQL_SA_PASSWORD=$(pw)
  CT=pgv-p4s1-qs-$SUF; MPORT=$(freeport 21433 21470); ADDR=127.0.0.1:$MPORT
  docker run -d --name "$CT" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -e MSSQL_PID=Developer -p "127.0.0.1:$MPORT:1433" \
    "${PGVIGIL_MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || fail "the SQL Server container did not start"
  MADE_CT=1
  export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
  for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
  sq "SELECT 1" >/dev/null 2>&1 || { docker logs --tail 20 "$CT" >&2; fail "the SQL Server container never answered"; }
fi
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
echo "SQL Server: $CT on $ADDR, $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(40))")"

adm() { psql "$ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

# the logins: the monitoring login, one without VIEW SERVER STATE, one with it and no way into a database
printf "CREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\n" "$L1" "$P1" | sqs >/dev/null; MADE_L+=("$L1")
sq "GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1]; GRANT CONNECT ANY DATABASE TO [$L1];" >/dev/null
printf "CREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\n" "$L2" "$P2" | sqs >/dev/null; MADE_L+=("$L2")
printf "CREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\n" "$L3" "$P3" | sqs >/dev/null; MADE_L+=("$L3")
sq "GRANT VIEW SERVER STATE TO [$L3];" >/dev/null
export MS_MON="sqlserver://$L1:$P1@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export MS_BARE="sqlserver://$L2:$P2@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export MS_VSS="sqlserver://$L3:$P3@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
N=proof-qs-$SUF; NN=proof-qsnorm-$SUF; NO=proof-qsnone-$SUF; NB=proof-qsbare-$SUF; NV=proof-qsvss-$SUF
{
  echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_MON\n' "$N"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_MON\n    query_text: normalized\n' "$NN"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_MON\n    query_text: none\n' "$NO"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_BARE\n' "$NB"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_VSS\n' "$NV"
} > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null || fail "migrate"
collect() { "$BIN" collect -config "$CFG" -once mssql_querystore -instance "$1" > "$OUT" 2>&1 || { cat "$OUT" >&2; return 1; }; cat "$OUT"; }
IDX="WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE)"

echo "--- the databases and the workload"
sq "CREATE DATABASE [$DB1]; ALTER DATABASE [$DB1] SET RECOVERY SIMPLE;" >/dev/null; MADE_DBS+=("$DB1")
sq "CREATE DATABASE [$DB2]; ALTER DATABASE [$DB2] SET RECOVERY SIMPLE;" >/dev/null; MADE_DBS+=("$DB2")
sq "CREATE DATABASE [$DB3]; ALTER DATABASE [$DB3] SET RECOVERY SIMPLE;" >/dev/null; MADE_DBS+=("$DB3")
sq "ALTER DATABASE [$DB1] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL, INTERVAL_LENGTH_MINUTES = 1, DATA_FLUSH_INTERVAL_SECONDS = 60, MAX_STORAGE_SIZE_MB = 100, WAIT_STATS_CAPTURE_MODE = ON);" >/dev/null
sq "ALTER DATABASE [$DB2] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL, INTERVAL_LENGTH_MINUTES = 1, DATA_FLUSH_INTERVAL_SECONDS = 60, MAX_STORAGE_SIZE_MB = 1, SIZE_BASED_CLEANUP_MODE = OFF);" >/dev/null
sq "ALTER DATABASE [$DB3] SET QUERY_STORE = OFF;" >/dev/null
sqs "$DB1" >/dev/null <<SQL
CREATE TABLE dbo.pv_orders (id int IDENTITY PRIMARY KEY, cust int NOT NULL, pad char(200) NOT NULL);
INSERT dbo.pv_orders (cust, pad)
SELECT TOP (20000) ABS(CHECKSUM(NEWID())) % 500, REPLICATE(CHAR(65 + ABS(CHECKSUM(NEWID())) % 26), 200) FROM sys.all_columns a CROSS JOIN sys.all_columns b;
CREATE INDEX IX_pv_cust ON dbo.pv_orders (cust) $IDX;
GO
CREATE PROCEDURE dbo.pv_by_cust @c int AS SELECT COUNT(*) AS n, MAX(pad) AS p FROM dbo.pv_orders WHERE cust = @c;
GO
CREATE PROCEDURE dbo.pv_scan AS SELECT COUNT_BIG(*) AS n FROM dbo.pv_orders a JOIN dbo.pv_orders b ON b.cust = a.cust AND b.id < a.id WHERE a.pad >= b.pad OPTION (MAXDOP 1);
GO
CREATE PROCEDURE dbo.pv_sort AS SELECT TOP (100) id, cust, pad FROM dbo.pv_orders ORDER BY pad DESC, id OPTION (MAXDOP 1);
GO
CREATE PROCEDURE dbo.pv_write @i int AS UPDATE dbo.pv_orders SET cust = cust WHERE id = @i;
GO
SQL
sqs "$DB1" >/dev/null <<'SQL'
SET NOCOUNT ON;
GO
EXEC dbo.pv_by_cust 7;
GO 300
EXEC dbo.pv_scan;
GO 5
EXEC dbo.pv_sort;
GO 40
DECLARE @i int = 1 + ABS(CHECKSUM(NEWID())) % 20000; EXEC dbo.pv_write @i;
GO 200
SELECT COUNT(*) AS n FROM dbo.pv_orders a JOIN dbo.pv_orders b ON b.id = a.id WHERE a.pad = 'pv-secret-7781';
GO
EXEC sys.sp_query_store_flush_db;
GO
SQL
PROCS="'dbo.pv_by_cust', 'dbo.pv_scan', 'dbo.pv_sort', 'dbo.pv_write'"
# sa's read of the store per procedure statement, summed as the collection sums it: name|query id|executions|duration|cpu|reads|max memory|wait ms
sahand() { sq "SELECT OBJECT_NAME(q.object_id) + '|' + CAST(q.query_id AS varchar(20)) + '|' + CAST(SUM(x.execs) AS varchar(20)) + '|' + CAST(SUM(x.dur) AS varchar(30)) + '|' + CAST(SUM(x.cpu) AS varchar(30)) + '|' + CAST(SUM(x.lr) AS varchar(30)) + '|' + CAST(MAX(x.mem) AS varchar(30)) + '|' + CAST(ISNULL((SELECT SUM(w.total_query_wait_time_ms) FROM sys.query_store_wait_stats w JOIN sys.query_store_plan wp ON wp.plan_id = w.plan_id WHERE wp.query_id = q.query_id), 0) AS varchar(30))
  FROM (SELECT r.plan_id, r.runtime_stats_interval_id, SUM(r.count_executions) AS execs, CAST(SUM(r.avg_duration * r.count_executions) AS bigint) AS dur,
               CAST(SUM(r.avg_cpu_time * r.count_executions) AS bigint) AS cpu, CAST(SUM(r.avg_logical_io_reads * r.count_executions) AS bigint) AS lr,
               CAST(MAX(r.max_query_max_used_memory) AS bigint) AS mem
          FROM sys.query_store_runtime_stats r GROUP BY r.plan_id, r.runtime_stats_interval_id) x
  JOIN sys.query_store_plan p ON p.plan_id = x.plan_id JOIN sys.query_store_query q ON q.query_id = p.query_id
 WHERE q.object_id IN (OBJECT_ID('dbo.pv_by_cust'), OBJECT_ID('dbo.pv_scan'), OBJECT_ID('dbo.pv_sort'), OBJECT_ID('dbo.pv_write'))
 GROUP BY q.object_id, q.query_id ORDER BY OBJECT_NAME(q.object_id)" "$DB1"; }

echo "--- A. store state"
collect "$N" >/dev/null
grep -q "partial\|skipped" "$OUT" && fail "A: the run is not ok: $(cat "$OUT")"
iid=$(q "select instance_id from pgvigil.instances where name='$N'")
saopt() { sq "SELECT desired_state_desc + '|' + actual_state_desc + '|' + CAST(readonly_reason AS varchar(10)) + '|' + CAST(max_storage_size_mb AS varchar(20)) + '|' + CAST(interval_length_minutes AS varchar(10)) + '|' + query_capture_mode_desc + '|' + size_based_cleanup_mode_desc + '|' + wait_stats_capture_mode_desc + '|' + CAST(flush_interval_seconds AS varchar(10)) + '|' + CAST(stale_query_threshold_days AS varchar(10)) + '|' + CAST(max_plans_per_query AS varchar(10)) FROM sys.database_query_store_options" "$1"; }
stored() { q "select desired_state || '|' || actual_state || '|' || readonly_reason || '|' || max_mb || '|' || interval_minutes || '|' || capture_mode || '|' || cleanup_mode || '|' || wait_stats_mode || '|' || flush_interval_s || '|' || stale_days || '|' || max_plans_per_query from pgvigil.mssql_qs_store where instance_id=$iid and database_name='$1'"; }
for d in "$DB1" "$DB3"; do
  [ "$(stored "$d")" = "$(saopt "$d")" ] || fail "A: $d stored $(stored "$d"), sa reads $(saopt "$d")"
done
case "$(stored "$DB1")" in "READ_WRITE|READ_WRITE|0|100|1|ALL|"*) ;; *) fail "A: the first database's store: $(stored "$DB1")";; esac
case "$(stored "$DB3")" in "OFF|OFF|"*) ;; *) fail "A: the third database's store: $(stored "$DB3")";; esac
[ "$(q "select coalesce(severity, '-') from pgvigil.mssql_qs_store_status where instance_id=$iid and database_name='$DB3'")" = "-" ] || fail "A: a store that is off and not asked for is judged"
[ "$(q "select count(*) from pgvigil.mssql_qs_store where instance_id=$iid and database_name in ('master', 'tempdb')")" = 0 ] || fail "A: master or tempdb is listed"
echo "  $DB1: $(stored "$DB1")"
echo "A: OK"

echo "--- B. the top list against sa's read"
HAND=$(sahand)
echo "$HAND" | sed 's/^/  sa: /'
rep() { q "select string_agg(x.o || '|' || x.qid || '|' || x.e || '|' || x.d || '|' || x.c || '|' || x.l || '|' || x.m || '|' || x.w, E'\n' order by x.o)
  from (select replace(qq.object_name, 'dbo.', '') as o, r.query_id as qid, sum(r.executions) as e, sum(r.duration_us) as d, sum(r.cpu_us) as c,
               sum(r.logical_reads) as l, max(r.max_memory_pages) as m, sum(r.wait_ms) as w
          from pgvigil.mssql_qs_runtime r
          join pgvigil.mssql_qs_query qq on qq.instance_id = r.instance_id and qq.database_name = r.database_name and qq.query_id = r.query_id and qq.query_hash = r.query_hash
         where r.instance_id=$iid and r.database_name='$DB1' and qq.object_name in ($PROCS)
         group by 1, 2) x"; }
REP=$(rep)
echo "$REP" | sed 's/^/  stored: /'
[ "$(echo "$REP" | cut -d'|' -f1,3 | tr '\n' ',')" = "pv_by_cust|300,pv_scan|5,pv_sort|40,pv_write|200," ] || fail "B: the stored executions are not the workload's 300 / 5 / 40 / 200"
[ "$(echo "$HAND" | wc -l)" = 4 ] || fail "B: sa reads $(echo "$HAND" | wc -l) statements, want 4"
paste -d'|' <(echo "$HAND") <(echo "$REP") | while IFS='|' read -r so sq_ se sd sc sl sm sw ro rq re rd rc rl rm rw; do
  [ "$so|$sq_|$se|$sm|$sw" = "$ro|$rq|$re|$rm|$rw" ] || fail "B: $so: sa $sq_|$se|mem $sm|wait $sw, stored $rq|$re|mem $rm|wait $rw"
  for pair in "$sd:$rd" "$sc:$rc" "$sl:$rl"; do
    a=${pair%%:*}; b=${pair#*:}; diff=$(( a > b ? a - b : b - a ))
    [ "$diff" -le 50 ] || fail "B: $so: sa $a, stored $b (duration, cpu, reads in that order)"
  done
done
PORT=$(freeport 18290 18330)
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" -no-login > "$WORK/serve.log" 2>&1 & SRV_PID=$!
U=http://127.0.0.1:$PORT/api
for _ in $(seq 1 40); do curl -fs "$U/health" >/dev/null 2>&1 && break; sleep 0.25; done
curl -fs "$U/health" >/dev/null || { cat "$WORK/serve.log" >&2; fail "the UI did not serve"; }
W="from=$(date -u -d '-2 hours' +%FT%TZ)&to=$(date -u -d '+10 minutes' +%FT%TZ)"
# objs <file> <part>: a part's rows as objects
objs() { jq -c --arg p "$2" '.[$p] | .columns as $c | [.rows[] | [$c, .] | transpose | map({(.[0]): .[1]}) | add]' "$1"; }
for o in duration:4 cpu:5 reads:6 memory:7 executions:3; do
  ord=${o%%:*}; f=${o#*:}
  curl -fs "$U/mssql/querystore?instance=$iid&$W&db=$DB1&order=$ord&part=top" > "$WORK/top.json" || fail "B: the API's top list ($ord)"
  API=$(objs "$WORK/top.json" top | jq -r '[.[] | select(.object_name != null and (.object_name | test("^dbo\\.pv_(by_cust|scan|sort|write)$"))) | .object_name | sub("^dbo\\."; "")] | join(",")')
  SAORD=$(echo "$HAND" | sort -t'|' -k"$f","$f"nr -k2,2n | cut -d'|' -f1 | paste -sd, -)
  echo "  order=$ord: $API"
  [ "$API" = "$SAORD" ] || fail "B: order=$ord gives $API, sa's order is $SAORD"
done
echo "B: OK"

echo "--- C. a forced plan that fails"
sqs "$DB1" >/dev/null <<SQL
CREATE TABLE dbo.pv_f (id int IDENTITY PRIMARY KEY, k int NOT NULL, pad char(100) NOT NULL);
INSERT dbo.pv_f (k, pad) SELECT TOP (5000) ABS(CHECKSUM(NEWID())) % 100, 'x' FROM sys.all_columns;
CREATE INDEX IX_pv_f ON dbo.pv_f (k) INCLUDE (pad) $IDX;
GO
CREATE PROCEDURE dbo.pv_forced @k int AS SELECT COUNT(*) AS n, MAX(pad) AS p FROM dbo.pv_f WHERE k = @k;
GO
EXEC dbo.pv_forced 3;
GO 20
EXEC sys.sp_query_store_flush_db;
DECLARE @q bigint, @p bigint;
SELECT TOP (1) @q = q.query_id, @p = p.plan_id FROM sys.query_store_query q JOIN sys.query_store_plan p ON p.query_id = q.query_id
 WHERE q.object_id = OBJECT_ID('dbo.pv_forced') ORDER BY p.plan_id DESC;
EXEC sys.sp_query_store_force_plan @q, @p;
DROP INDEX IX_pv_f ON dbo.pv_f;
GO
EXEC dbo.pv_forced 3;
EXEC sys.sp_recompile N'dbo.pv_forced';
GO 3
EXEC dbo.pv_forced 3;
EXEC sys.sp_query_store_flush_db;
GO
SQL
SAF=$(sq "SELECT CAST(p.query_id AS varchar(20)) + '|' + CAST(p.plan_id AS varchar(20)) + '|' + CAST(p.force_failure_count AS varchar(20)) + '|' + p.last_force_failure_reason_desc FROM sys.query_store_plan p JOIN sys.query_store_query q ON q.query_id = p.query_id WHERE q.object_id = OBJECT_ID('dbo.pv_forced') AND p.is_forced_plan = 1" "$DB1")
echo "  sa: query|plan|failures|reason = $SAF"
IFS='|' read -r FQ FP FN FR <<<"$SAF"
[ "${FN:-0}" -ge 1 ] || fail "C: SQL Server counts no force failure ($SAF): the case did not happen on this server"
collect "$N" >/dev/null
GOTF=$(q "select query_id || '|' || plan_id || '|' || force_failure_count || '|' || force_failure_reason from pgvigil.mssql_qs_plan where instance_id=$iid and database_name='$DB1' and is_forced")
[ "$GOTF" = "$SAF" ] || fail "C: stored $GOTF, sa reads $SAF"
[ "$FR" = NO_INDEX ] || fail "C: the reason is $FR, expected NO_INDEX"
[ "$(q "select count(*) from pgvigil.mssql_querystore_findings where instance_id=$iid and check_name='a forced plan fails' and object='$DB1: query $FQ, plan $FP' and severity='warning' and detail like '%NO_INDEX%'")" = 1 ] \
  || fail "C: the finding: $(q "select check_name || ' / ' || object || ' / ' || detail from pgvigil.mssql_querystore_findings where instance_id=$iid")"
curl -fs "$U/mssql/querystore?instance=$iid&$W&part=forced" > "$WORK/forced.json"
[ "$(objs "$WORK/forced.json" forced | jq --arg d "$DB1" --argjson p "$FP" '[.[] | select(.database_name == $d and .plan_id == $p and .object_name == "dbo.pv_forced" and .force_failure_count >= 1)] | length')" = 1 ] \
  || fail "C: the API's forced part: $(objs "$WORK/forced.json" forced | head -c 400)"
echo "C: OK"

echo "--- D. a regression across two intervals"
sqs "$DB1" >/dev/null <<SQL
CREATE TABLE dbo.pv_r (id int IDENTITY PRIMARY KEY, k int NOT NULL, pad char(400) NOT NULL);
INSERT dbo.pv_r (k, pad) SELECT TOP (40000) ABS(CHECKSUM(NEWID())) % 4000, 'r' FROM sys.all_columns a CROSS JOIN sys.all_columns b;
CREATE INDEX IX_pv_r ON dbo.pv_r (k) INCLUDE (pad) $IDX;
GO
CREATE PROCEDURE dbo.pv_reg @k int AS SELECT COUNT(*) AS n, MAX(pad) AS p FROM dbo.pv_r WHERE k = @k OPTION (MAXDOP 1);
GO
EXEC dbo.pv_reg 11;
GO 50
SQL
EDGE=$(sq "SELECT CONVERT(varchar(19), CAST(MAX(end_time) AT TIME ZONE 'UTC' AS datetime2(0)), 126) + 'Z|' + CAST(DATEDIFF(ms, SYSDATETIMEOFFSET(), MAX(end_time)) AS varchar(20)) FROM sys.query_store_runtime_stats_interval" "$DB1")
T=${EDGE%%|*}; WAITMS=${EDGE#*|}
[ "$WAITMS" -gt -1000 ] && [ "$WAITMS" -le 61000 ] || fail "D: the open interval ends in $WAITMS ms ($T): not a one-minute interval"
echo "  the first 50 ran before $T; waiting $(( WAITMS / 1000 + 3 )) s for the interval to end"
sleep $(( (WAITMS > 0 ? WAITMS : 0) / 1000 + 3 ))
sqs "$DB1" >/dev/null <<'SQL'
DROP INDEX IX_pv_r ON dbo.pv_r;
GO
EXEC dbo.pv_reg 11;
GO 50
EXEC sys.sp_query_store_flush_db;
GO
SQL
collect "$N" >/dev/null
RW="from=$T&to=$(date -u -d "$T + 5 minutes" +%FT%TZ)"
curl -fs "$U/mssql/querystore?instance=$iid&$RW&db=$DB1&part=regressed" > "$WORK/reg.json" || fail "D: the API's regressed part"
REG=$(objs "$WORK/reg.json" regressed | jq -c '[.[] | select(.object_name == "dbo.pv_reg")]')
echo "  regressed: $(echo "$REG" | jq -c '.[] | {query_id, plan_id, new_plan, executions, before_executions, duration_ratio, avg_duration_ms, before_avg_duration_ms}')"
[ "$(echo "$REG" | jq '[.[] | select(.new_plan == true and .executions == 50 and .before_executions == 50 and .duration_ratio >= 1.5)] | length')" = 1 ] \
  || fail "D: the regressed part does not list dbo.pv_reg's new plan at 50 / 50 and 1.5 times: $REG"
RQ=$(echo "$REG" | jq -r '.[0].query_id'); RH=$(echo "$REG" | jq -r '.[0].query_hash')
curl -fs "$U/mssql/querystore/query?instance=$iid&$W&db=$DB1&query=$RQ&hash=$RH" > "$WORK/one.json" || fail "D: the query route"
[ "$(objs "$WORK/one.json" plans | jq 'length')" = 2 ] || fail "D: the query's plans: $(objs "$WORK/one.json" plans | jq -c '[.[] | {plan_id, executions}]')"
[ "$(objs "$WORK/one.json" plans | jq '[.[].executions] | add')" = 100 ] || fail "D: the two plans' executions do not add to 100"
[ "$(objs "$WORK/one.json" series | jq '([.[].plan_id] | unique | length) == 2 and length >= 2')" = true ] || fail "D: the query's series: $(objs "$WORK/one.json" series | head -c 300)"
[ "$(objs "$WORK/one.json" query | jq -r '.[0].object_name')" = dbo.pv_reg ] || fail "D: the query's text row"
echo "D: OK"

echo "--- E. a store filled to read-only"
for round in $(seq 1 30); do
  sqs "$DB2" >/dev/null <<'SQL'
SET NOCOUNT ON;
DECLARE @i int = 0, @s nvarchar(max), @n int;
WHILE @i < 150 BEGIN
  SET @s = N'SELECT @n = COUNT(*) FROM sys.objects o JOIN sys.columns c ON c.object_id = o.object_id JOIN sys.types t ON t.user_type_id = c.user_type_id WHERE o.object_id > '
         + CAST(@i AS nvarchar(10)) + N' AND o.name <> N''' + REPLACE(CAST(NEWID() AS nvarchar(36)), N'-', N'') + N'''';
  EXEC sys.sp_executesql @s, N'@n int OUTPUT', @n = @n OUTPUT;
  SET @i += 1;
END;
EXEC sys.sp_query_store_flush_db;
GO
SQL
  ST=$(sq "SELECT actual_state_desc + '|' + CAST(readonly_reason AS varchar(10)) + '|' + CAST(current_storage_size_mb AS varchar(10)) FROM sys.database_query_store_options" "$DB2")
  case "$ST" in READ_ONLY\|*) break;; esac
  sleep 2
done
echo "  after $round round(s) of 150 statements: $ST"
case "$ST" in "READ_ONLY|65536|"*) ;; *) fail "E: SQL Server did not set the store read-only by size ($ST)";; esac
collect "$N" >/dev/null
[ "$(stored "$DB2")" = "$(saopt "$DB2")" ] || fail "E: stored $(stored "$DB2"), sa reads $(saopt "$DB2")"
[ "$(q "select severity || '|' || (verdict like '%max size%') || '|' || (readonly_reasons like '%max size%') from pgvigil.mssql_qs_store_status where instance_id=$iid and database_name='$DB2'")" = "warning|true|true" ] \
  || fail "E: the judgement: $(q "select severity, verdict from pgvigil.mssql_qs_store_status where instance_id=$iid and database_name='$DB2'")"
[ "$(q "select count(*) from pgvigil.mssql_querystore_findings where instance_id=$iid and check_name='Query Store is read-only' and object='$DB2' and severity='warning'")" = 1 ] || fail "E: the finding"
[ "$(q "select (warning >= 1) || '|' || sampled || '|' || (array_to_string(detail, ' ') like '%$DB2%') from pgvigil.mssql_querystore_status where instance_id=$iid")" = "true|true|true" ] \
  || fail "E: the status row: $(q "select * from pgvigil.mssql_querystore_status where instance_id=$iid")"
curl -fs "$U/mssql/summary?part=cells" > "$WORK/sum.json"
CELL=$(objs "$WORK/sum.json" cells | jq -c --argjson i "$iid" '[.[] | select(.instance_id == $i and .key == "qs")] | .[0]')
[ "$CELL" != null ] || fail "E: /api/mssql/summary has no 'qs' cell: the Summary wiring (q_mssql_summary.go, the lead's) is not on this tree"
[ "$(echo "$CELL" | jq '.sampled == true and .warning >= 1 and .critical == 0')" = true ] || fail "E: the Summary's qs cell: $CELL"
echo "  the Summary's qs cell: $(echo "$CELL" | jq -c '{state, critical, warning, value}')"
echo "E: OK"

echo "--- F. the text policy"
collect "$NN" >/dev/null; collect "$NO" >/dev/null
inn=$(q "select instance_id from pgvigil.instances where name='$NN'"); ino=$(q "select instance_id from pgvigil.instances where name='$NO'")
pol() { q "select count(*) filter (where q.query_text like '%pv-secret-7781%') || '|' || count(*) filter (where q.query_text like '%a.pad = ?%') || '|' || count(q.query_text) || '|' || (count(*) > 0)
             || '|' || (select count(p.plan_xml) || '|' || count(*) filter (where p.xml_state = 'stored') || '|' || (count(*) filter (where p.xml_state = 'policy') > 0)
                          from pgvigil.mssql_qs_plan p where p.instance_id = $1 and p.database_name = '$DB1')
        from pgvigil.mssql_qs_query q where q.instance_id = $1 and q.database_name = '$DB1'"; }
PF=$(pol "$iid"); PN=$(pol "$inn"); PO=$(pol "$ino")
echo "  literal|normalized form|texts|rows|plan XML|stored|policy seen: full $PF, normalized $PN, none $PO"
IFS='|' read -r f1 _ f3 f4 f5 f6 f7 <<<"$PF"
[ "$f1" -ge 1 ] && [ "$f3" -ge 5 ] && [ "$f4" = true ] && [ "$f5" -ge 5 ] && [ "$f5" = "$f6" ] && [ "$f7" = false ] || fail "F: full: $PF"
IFS='|' read -r n1 n2 n3 n4 n5 n6 n7 <<<"$PN"
[ "$n1" = 0 ] && [ "$n2" -ge 1 ] && [ "$n3" -ge 5 ] && [ "$n4" = true ] && [ "$n5" = 0 ] && [ "$n6" = 0 ] && [ "$n7" = true ] || fail "F: normalized: $PN"
IFS='|' read -r o1 o2 o3 o4 o5 o6 o7 <<<"$PO"
[ "$o1" = 0 ] && [ "$o2" = 0 ] && [ "$o3" = 0 ] && [ "$o4" = true ] && [ "$o5" = 0 ] && [ "$o6" = 0 ] && [ "$o7" = true ] || fail "F: none: $PO"
BEFORE=$(q "select count(*) || '|' || max(xml_checked_at) from pgvigil.mssql_qs_plan where instance_id=$iid and database_name='$DB1' and xml_state='stored'")
sleep 1; collect "$N" >/dev/null
AFTER=$(q "select count(*) filter (where xml_checked_at <= '${BEFORE#*|}') || '|' || max(xml_checked_at) filter (where xml_checked_at <= '${BEFORE#*|}') from pgvigil.mssql_qs_plan where instance_id=$iid and database_name='$DB1' and xml_state='stored'")
[ "$AFTER" = "$BEFORE" ] || fail "F: a stored plan's XML was read again: before $BEFORE, after $AFTER"
echo "F: OK"

echo "--- G. rights"
collect "$NB" | grep -q "skipped: the login lacks VIEW SERVER STATE" || fail "G: the bare login: $(cat "$OUT")"
collect "$NV" >/dev/null
inv=$(q "select instance_id from pgvigil.instances where name='$NV'")
[ "$(q "select count(*) || '|' || count(*) filter (where not options_read and note like '%CONNECT ANY DATABASE%') from pgvigil.mssql_qs_store where instance_id=$inv and database_name in ('$DB1', '$DB2', '$DB3')")" = "3|3" ] \
  || fail "G: VIEW SERVER STATE without a way in: $(q "select database_name, options_read, note from pgvigil.mssql_qs_store where instance_id=$inv")"
[ "$(q "select count(*) from pgvigil.mssql_qs_runtime where instance_id=$inv")" = 0 ] || fail "G: runtime rows were stored for a login that cannot enter a database"
echo "G: OK"

echo "--- H. the .sqlplan download"
HP=$(sq "SELECT TOP (1) CAST(p.plan_id AS varchar(20)) + '|' + CONVERT(varchar(64), HASHBYTES('SHA2_256', p.query_plan), 2) FROM sys.query_store_plan p JOIN sys.query_store_query q ON q.query_id = p.query_id WHERE q.object_id = OBJECT_ID('dbo.pv_by_cust') ORDER BY p.plan_id" "$DB1")
curl -fs -D "$WORK/plan.h" "$U/mssql/querystore/plan.sqlplan?instance=$iid&db=$DB1&plan=${HP%%|*}" > "$WORK/plan.sqlplan" || fail "H: the download of plan ${HP%%|*}"
GOTH=$(iconv -f UTF-8 -t UTF-16LE "$WORK/plan.sqlplan" | sha256sum | cut -d' ' -f1 | tr a-f A-F)
[ "$GOTH" = "${HP#*|}" ] || fail "H: the downloaded plan's SHA-256 is $GOTH, sa's query_plan gives ${HP#*|}"
grep -qi '^content-disposition: attachment; filename="plan-.*\.sqlplan"' "$WORK/plan.h" || fail "H: the file name: $(grep -i content-disposition "$WORK/plan.h")"
head -c 12 "$WORK/plan.sqlplan" | grep -q '<ShowPlanXML' || fail "H: the file is not a showplan"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$U/mssql/querystore/plan.sqlplan?instance=$ino&db=$DB1&plan=${HP%%|*}")" = 404 ] || fail "H: the none instance serves a plan"
echo "H: OK ($(wc -c < "$WORK/plan.sqlplan") bytes)"

echo "=== without a server"
echo "--- X. written payloads"
xi=$(q "select pgvigil.ensure_instance('proof-qs-x-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
I1=$(date -u -d '-3 hours' +%FT%H:00:00Z); I1E=$(date -u -d '-2 hours' +%FT%H:00:00Z); I2=$I1E; I2E=$(date -u -d '-1 hours' +%FT%H:00:00Z)
R0=$(date -u -d '-240 minutes' +%FT%TZ); R1=$(date -u -d '-50 minutes' +%FT%TZ); R2=$(date -u -d '-40 minutes' +%FT%TZ); R3=$(date -u -d '-30 minutes' +%FT%TZ); R4=$(date -u -d '-20 minutes' +%FT%TZ)
imp() { q "select pgvigil.import_mssql_querystore($1, '$2', '$3'::jsonb)" >/dev/null; }
STORE='{"kind":"store","database_id":5,"database_name":"a:b","database_state":"ONLINE","database_read_only":0,"read":1,"desired_state":"READ_WRITE","actual_state":"READ_WRITE","readonly_reason":0,"current_mb":10,"max_mb":100,"cleanup_mode":"AUTO","can_read":1}'
plan() { echo "{\"kind\":\"plan\",\"database_name\":\"a:b\",\"plan_id\":$1,\"query_id\":$2,\"query_hash_hex\":\"$3\",\"plan_hash_hex\":\"0x0B\",\"plan_hash_n\":$4,\"is_forced\":$5,\"forcing_type\":\"MANUAL\",\"force_failure_count\":$6,\"force_failure_reason\":\"NO_INDEX\",\"plan_count\":1,\"plan_xml_bytes\":40,\"query\":\"$7\"}"; }
rt() { echo "{\"kind\":\"runtime\",\"database_name\":\"a:b\",\"interval_start\":\"$1\",\"plan_id\":$2,\"executions\":$3,\"duration_us\":$(($3 * 1000)),\"cpu_us\":500,\"logical_reads\":50,\"max_memory_pages\":0,\"wait_ms\":1}"; }
iv() { echo "{\"kind\":\"interval\",\"database_name\":\"a:b\",\"interval_id\":$1,\"interval_start\":\"$2\",\"interval_end\":\"$3\",\"plans\":3,\"executions\":20,\"duration_us\":9000,\"cpu_us\":800,\"logical_reads\":70,\"wait_ms\":2}"; }
PL1="[$STORE,$(iv 1 "$I1" "$I1E"),$(rt "$I1" 7 5),$(plan 7 3 0x0A 11 1 2 'SELECT 1'),$(plan 9 4 0x0C 12 1 0 'SELECT 9'),{\"kind\":\"forced_read\",\"database_name\":\"a:b\"},{\"kind\":\"plan_xml\",\"kind_of\":\"plan\",\"database_name\":\"a:b\",\"plan_id\":7,\"statement\":\"<ShowPlanXML/>\"}]"
imp "$xi" "$R1" "$PL1"
cnt() { q "select (select count(*) from pgvigil.mssql_qs_interval where instance_id=$xi) || '|' || (select count(*) from pgvigil.mssql_qs_runtime where instance_id=$xi) || '|' || (select count(*) from pgvigil.mssql_qs_plan where instance_id=$xi) || '|' || (select count(*) from pgvigil.mssql_qs_query where instance_id=$xi) || '|' || (select coalesce(sum(executions), 0) from pgvigil.mssql_qs_runtime where instance_id=$xi)"; }
C1=$(cnt); imp "$xi" "$R1" "$PL1"
[ "$C1" = "1|1|2|2|5" ] && [ "$(cnt)" = "$C1" ] || fail "X: a payload imported twice: $C1 then $(cnt) (intervals|runtime|plans|queries|executions; want 1|1|2|2|5 both times)"
cur() { q "select coalesce(pgvigil.mssql_hadr_cursor($xi, '$1')::text, 'null')"; }
[ "$(cur 'qs_since:a:b')" = "$(date -u -d "$I1" +%s)" ] || fail "X: qs_since is $(cur 'qs_since:a:b'), want $(date -u -d "$I1" +%s)"
[ "$(cur 'qs_plan:7:a:b')|$(cur 'qs_plan:9:a:b')|$(cur 'qs_plan:7:other')|$(cur 'qs_since:other')|$(cur 'jobs')|$(cur 'nonsense')" = "11|null|null|null|null|null" ] \
  || fail "X: the cursors: $(cur 'qs_plan:7:a:b')|$(cur 'qs_plan:9:a:b')|$(cur 'qs_plan:7:other')|$(cur 'qs_since:other')|$(cur 'jobs')|$(cur 'nonsense')"
q "insert into pgvigil.mssql_jobs_cursor (instance_id, last_history_id, mark, updated_at) values ($xi, 77, 4242, now())" >/dev/null
[ "$(cur jobs)/$(cur jobs_mark)" = "77/4242" ] || fail "X: the jobs cursor after 0083: $(cur jobs)/$(cur jobs_mark)"
[ "$(q "select count(*) from pgvigil.mssql_querystore_findings where instance_id=$xi and check_name='a forced plan fails' and object='a:b: query 3, plan 7'")" = 1 ] || fail "X: the forced plan's finding"
imp "$xi" "$R0" "[$STORE,$(iv 1 "$I1" "$I1E"),$(rt "$I1" 7 99)]"
[ "$(cnt)" = "$C1" ] || fail "X: a payload older than the stored read changed the rows: $(cnt)"
# the interval read again (9 and 1 executions), a new interval, plan 7 no longer forced, plan 9 not listed at all
imp "$xi" "$R2" "[$STORE,$(iv 1 "$I1" "$I1E"),$(rt "$I1" 7 9),$(rt "$I1" 8 1),$(iv 2 "$I2" "$I2E"),$(rt "$I2" 8 4),$(plan 7 3 0x0A 11 0 0 'SELECT 1'),$(plan 8 3 0x0A 13 0 0 'SELECT 1'),{\"kind\":\"forced_read\",\"database_name\":\"a:b\"},{\"kind\":\"plan_xml\",\"kind_of\":\"plan\",\"database_name\":\"a:b\",\"plan_id\":8,\"statement\":null}]"
[ "$(q "select string_agg(plan_id || ':' || executions, ',' order by snapshot_at, plan_id) from pgvigil.mssql_qs_runtime where instance_id=$xi")" = "7:9,8:1,8:4" ] \
  || fail "X: an interval read again: $(q "select string_agg(plan_id || ':' || executions, ',' order by snapshot_at, plan_id) from pgvigil.mssql_qs_runtime where instance_id=$xi") (want 7:9,8:1,8:4)"
[ "$(q "select string_agg(plan_id || ':' || is_forced, ',' order by plan_id) from pgvigil.mssql_qs_plan where instance_id=$xi")" = "7:false,8:false,9:false" ] \
  || fail "X: the forced marks: $(q "select string_agg(plan_id || ':' || is_forced, ',' order by plan_id) from pgvigil.mssql_qs_plan where instance_id=$xi")"
[ "$(cur 'qs_since:a:b')|$(cur 'qs_plan:7:a:b')|$(cur 'qs_plan:8:a:b')" = "$(date -u -d "$I2" +%s)|11|13" ] \
  || fail "X: the cursors after the second read: $(cur 'qs_since:a:b')|$(cur 'qs_plan:7:a:b')|$(cur 'qs_plan:8:a:b') (plan 8 was looked at under the policy)"
[ "$(q "select string_agg(plan_id || ':' || coalesce(xml_state, '-') || ':' || (plan_xml is not null), ',' order by plan_id) from pgvigil.mssql_qs_plan where instance_id=$xi")" = "7:stored:true,8:policy:false,9:-:false" ] \
  || fail "X: the XML states: $(q "select string_agg(plan_id || ':' || coalesce(xml_state, '-') || ':' || (plan_xml is not null), ',' order by plan_id) from pgvigil.mssql_qs_plan where instance_id=$xi")"
q "update pgvigil.mssql_qs_plan set xml_checked_at = now() - interval '25 hours' where instance_id=$xi and plan_id=8" >/dev/null
[ "$(cur 'qs_plan:8:a:b')" = null ] || fail "X: a plan looked at under the policy over a day ago still needs no read"
# the store was cleared: plan 7 and query 3 come back as another statement
imp "$xi" "$R3" "[$STORE,$(plan 7 3 0xFF 99 0 0 'SELECT 2'),{\"kind\":\"forced_read\",\"database_name\":\"a:b\"}]"
[ "$(q "select coalesce(xml_state, '-') || '|' || (plan_xml is null) || '|' || plan_hash_n from pgvigil.mssql_qs_plan where instance_id=$xi and plan_id=7")|$(cur 'qs_plan:7:a:b')" = "-|true|99|null" ] \
  || fail "X: a plan number under another hash keeps its XML: $(q "select xml_state, plan_xml, plan_hash_n from pgvigil.mssql_qs_plan where instance_id=$xi and plan_id=7")|$(cur 'qs_plan:7:a:b')"
[ "$(q "select count(*) from pgvigil.mssql_qs_runtime r join pgvigil.mssql_qs_query qq on qq.instance_id = r.instance_id and qq.database_name = r.database_name and qq.query_id = r.query_id and qq.query_hash is not distinct from r.query_hash where r.instance_id=$xi")|$(q "select query_text from pgvigil.mssql_qs_query where instance_id=$xi and query_id=3")" = "0|SELECT 2" ] \
  || fail "X: the old runtime rows join the new statement's text"
[ "$(curl -fs "$U/mssql/querystore?instance=$xi&from=$(date -u -d '-6 hours' +%FT%TZ)&to=$(date -u +%FT%TZ)&part=top" | jq -c '[.top | .columns as $c | .rows[] | [.[($c | index("query_id"))], .[($c | index("executions"))], .[($c | index("query"))]]]')" = '[[3,14,null]]' ] \
  || fail "X: the top list over the written rows: $(curl -fs "$U/mssql/querystore?instance=$xi&from=$(date -u -d '-6 hours' +%FT%TZ)&to=$(date -u +%FT%TZ)&part=top" | jq -c '.top.rows')"
imp "$xi" "$R4" "[$(echo "$STORE" | sed 's/"a:b"/"c"/')]"
[ "$(q "select string_agg(database_name, ',') from pgvigil.mssql_qs_store where instance_id=$xi")" = c ] || fail "X: a database the read no longer lists stays in the state"
echo "X: OK"

echo "--- Y. the judgements"
xj=$(q "select pgvigil.ensure_instance('proof-qs-y-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
st() { echo "{\"kind\":\"store\",\"database_name\":\"$1\",\"database_state\":\"ONLINE\",\"database_read_only\":0,\"read\":${7:-1},\"desired_state\":\"$2\",\"actual_state\":\"$3\",\"readonly_reason\":$4,\"current_mb\":$5,\"max_mb\":100,\"cleanup_mode\":\"$6\",\"can_read\":1}"; }
YPAY="[$(st e_error READ_WRITE ERROR 0 10 AUTO),$(st f_full READ_WRITE READ_ONLY 65536 100 OFF),$(st g_replica READ_WRITE READ_ONLY 8 10 AUTO),$(st h_rodb READ_WRITE READ_ONLY 1 10 AUTO),$(st i_both READ_WRITE READ_ONLY 65544 100 AUTO),$(st j_asked READ_ONLY READ_ONLY 0 10 AUTO),$(st k_off READ_WRITE OFF 0 0 AUTO),$(st l_offok OFF OFF 0 0 AUTO),$(st m_near READ_WRITE READ_WRITE 0 95 OFF),$(st n_auto READ_WRITE READ_WRITE 0 95 AUTO),$(st o_notread READ_WRITE READ_ONLY 65536 100 OFF 0)]"
YWANT="e_error:critical,f_full:warning,g_replica:-,h_rodb:-,i_both:warning,j_asked:warning,k_off:warning,l_offok:-,m_near:info,n_auto:-,o_notread:-"
imp "$xj" "$(date -u +%FT%TZ)" "$YPAY"
JY=$(q "select string_agg(database_name || ':' || coalesce(severity, '-'), ',' order by database_name) from pgvigil.mssql_qs_store_status where instance_id=$xj")
echo "  $JY"
[ "$JY" = "$YWANT" ] || fail "Y: the judgements: $JY"
[ "$(q "select critical || '|' || warning || '|' || value || '|' || sampled || '|' || array_length(detail, 1) from pgvigil.mssql_querystore_status where instance_id=$xj")" = "1|4|7 of 10 on|true|5" ] \
  || fail "Y: the status row: $(q "select critical || '|' || warning || '|' || value || '|' || sampled || '|' || array_length(detail, 1) from pgvigil.mssql_querystore_status where instance_id=$xj")"
[ "$(q "select string_agg(severity || ':' || check_name || ':' || object, ',' order by object) from pgvigil.mssql_querystore_findings where instance_id=$xj")" \
  = "critical:Query Store in the ERROR state:e_error,warning:Query Store is read-only:f_full,warning:Query Store is read-only:i_both,warning:Query Store is read-only:j_asked,warning:Query Store is off though asked for:k_off,info:Query Store near its max size:m_near" ] \
  || fail "Y: the findings: $(q "select string_agg(severity || ':' || check_name || ':' || object, ',' order by object) from pgvigil.mssql_querystore_findings where instance_id=$xj")"
[ "$(q "select (select verdict like '%as asked for%' from pgvigil.mssql_qs_store_status where instance_id=$xj and database_name='j_asked') || '|' || (select verdict like '%not as asked for (READ_WRITE)%secondary replica%max size%' from pgvigil.mssql_qs_store_status where instance_id=$xj and database_name='i_both')")" = "true|true" ] \
  || fail "Y: the verdicts' words: $(q "select database_name || ': ' || verdict from pgvigil.mssql_qs_store_status where instance_id=$xj and database_name in ('j_asked', 'i_both')")"
echo "Y: OK"

echo "--- Z. the engine check and the roles"
pgi=$(q "select pgvigil.ensure_instance('proof-qs-pg-$SUF', 'onprem', 'x', 170000, false, '{}')")
if q "select pgvigil.import_mssql_querystore($pgi, now(), '[$STORE]'::jsonb)" >/dev/null 2>"$OUT"; then fail "Z: the import took a PostgreSQL instance"; fi
grep -q "is not a SQL Server instance" "$OUT" || fail "Z: the refusal: $(cat "$OUT")"
SIG="pgvigil.import_mssql_querystore(int, timestamptz, jsonb)"
[ "$(q "select has_function_privilege('pgvigil_collector', '$SIG', 'execute') || '|' || has_function_privilege('pgvigil_reader', '$SIG', 'execute') || '|' || has_function_privilege('pgvigil_collector', 'pgvigil.mssql_hadr_cursor(int, text)', 'execute') || '|' || has_table_privilege('pgvigil_reader', 'pgvigil.mssql_qs_runtime', 'select') || '|' || has_table_privilege('pgvigil_reader', 'pgvigil.mssql_querystore_status', 'select') || '|' || has_table_privilege('pgvigil_collector', 'pgvigil.mssql_qs_plan', 'select')")" = "true|false|true|true|true|false" ] \
  || fail "Z: the roles: $(q "select has_function_privilege('pgvigil_collector', '$SIG', 'execute'), has_function_privilege('pgvigil_reader', '$SIG', 'execute'), has_function_privilege('pgvigil_collector', 'pgvigil.mssql_hadr_cursor(int, text)', 'execute'), has_table_privilege('pgvigil_reader', 'pgvigil.mssql_qs_runtime', 'select'), has_table_privilege('pgvigil_reader', 'pgvigil.mssql_querystore_status', 'select'), has_table_privilege('pgvigil_collector', 'pgvigil.mssql_qs_plan', 'select')")"
echo "Z: OK"

echo "--- V. 0083 on PostgreSQL 13"
V_NOTE=
if [ -n "${PGVIGIL_SKIP_PG13:-}" ]; then
  echo "V: SKIPPED (PGVIGIL_SKIP_PG13 is set)"; V_NOTE=", V NOT RUN"
else
  PG13_PROOF=${PG13_PROOF:-pgv-pg13-proof}; P13=${PG13_PORT:-5413}
  case "$(docker inspect -f '{{.State.Running}}' "$PG13_PROOF" 2>/dev/null || echo missing)" in
    true) ;;
    false) docker start "$PG13_PROOF" >/dev/null || fail "V: $PG13_PROOF did not start"; PG13_STOP=$PG13_PROOF ;;
    *) P13=$(freeport 25413 25450); PG13_RM=pgv-p4s1-pg13-$SUF
       docker run -d --name "$PG13_RM" -p "127.0.0.1:$P13:5432" -e POSTGRES_HOST_AUTH_METHOD=trust postgres:13 >/dev/null || fail "V: a postgres:13 container did not start" ;;
  esac
  V13="host=127.0.0.1 port=$P13 user=postgres dbname=postgres sslmode=disable"
  for _ in $(seq 1 150); do psql "$V13" -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 0.2; done
  psql "$V13" -XAtqc "create database $V13DB" >/dev/null || fail "V: PostgreSQL 13 did not answer on port $P13"; MADE_13=1
  printf 'repository:\n  dsn: env:V13_REPO\ninstances: []\n' > "$WORK/v13.yaml"
  V13_REPO="${V13% dbname=postgres sslmode=disable} dbname=$V13DB sslmode=disable" "$BIN" migrate -config "$WORK/v13.yaml" > "$OUT" 2>&1 || { cat "$OUT" >&2; fail "V: migrate on PostgreSQL 13"; }
  v13() { psql "${V13% dbname=postgres sslmode=disable} dbname=$V13DB sslmode=disable" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
  [ "$(v13 "select current_setting('server_version_num')::int / 10000")" = 13 ] || fail "V: not PostgreSQL 13"
  va=$(v13 "select pgvigil.ensure_instance('proof-qs-13a', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
  vb=$(v13 "select pgvigil.ensure_instance('proof-qs-13b', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
  v13 "select pgvigil.import_mssql_querystore($va, '$R1', '$PL1'::jsonb)" >/dev/null
  v13 "select pgvigil.import_mssql_querystore($va, '$R1', '$PL1'::jsonb)" >/dev/null
  v13 "select pgvigil.import_mssql_querystore($vb, now(), '$YPAY'::jsonb)" >/dev/null
  GOT13=$(v13 "select (select count(*) from pgvigil.mssql_qs_interval where instance_id=$va) || '|' || (select count(*) from pgvigil.mssql_qs_runtime where instance_id=$va) || '|' || (select count(*) from pgvigil.mssql_qs_plan where instance_id=$va) || '|' || (select count(*) from pgvigil.mssql_qs_query where instance_id=$va) || '|' || (select sum(executions) from pgvigil.mssql_qs_runtime where instance_id=$va) || '|' || pgvigil.mssql_hadr_cursor($va, 'qs_plan:7:a:b') || '|' || (select string_agg(database_name || ':' || coalesce(severity, '-'), ',' order by database_name) from pgvigil.mssql_qs_store_status where instance_id=$vb) || '|' || (select critical || '/' || warning || '/' || value from pgvigil.mssql_querystore_status where instance_id=$vb)")
  [ "$GOT13" = "1|1|2|2|5|11|$YWANT|1/4/7 of 10 on" ] || fail "V: on PostgreSQL 13: $GOT13"
  echo "V: OK (PostgreSQL $(v13 "show server_version"))"
fi

echo "--- P. the API"
curl -fs "$U/mssql/querystore?instance=$iid&$W" > "$WORK/all.json" || fail "P: the page's read"
[ "$(jq -r 'keys | join(",")' "$WORK/all.json")" = "checks,forced,regressed,series,state,top,totals,tuning,tuning_options" ] || fail "P: the parts: $(jq -r 'keys | join(",")' "$WORK/all.json")"
[ "$(objs "$WORK/all.json" totals | jq '.[0] | (.intervals >= 2) and (.executions >= 545) and (.kept_executions <= .executions) and (.kept_duration_ms <= .duration_ms + 0.1)')" = true ] \
  || fail "P: the totals: $(objs "$WORK/all.json" totals)"
[ "$(objs "$WORK/all.json" series | jq 'length >= 2')" = true ] && [ "$(objs "$WORK/all.json" state | jq 'length >= 3')" = true ] || fail "P: series or state is short"
code() { curl -s -o /dev/null -w '%{http_code}' "$U/$1"; }
LONG=$(printf 'x%.0s' $(seq 1 129))
[ "$(code "mssql/querystore?instance=$iid&order=bogus")|$(code "mssql/querystore?instance=$iid&db=$LONG")|$(code "mssql/querystore/query?instance=$iid&query=1")|$(code "mssql/querystore/query?instance=$iid&db=$DB1&query=1&hash=zz")|$(code "mssql/querystore/plan.sqlplan?instance=$iid&db=$DB1&plan=999999999")|$(code "mssql/querystore?instance=$iid&part=nothing")" = "400|400|400|400|404|400" ] \
  || fail "P: the refusals: $(code "mssql/querystore?instance=$iid&order=bogus")|$(code "mssql/querystore?instance=$iid&db=$LONG")|$(code "mssql/querystore/query?instance=$iid&query=1")|$(code "mssql/querystore/query?instance=$iid&db=$DB1&query=1&hash=zz")|$(code "mssql/querystore/plan.sqlplan?instance=$iid&db=$DB1&plan=999999999")|$(code "mssql/querystore?instance=$iid&part=nothing")"
echo "P: OK"

if [ -n "${PGVIGIL_SKIP_DEMO:-}" ]; then
  echo "DEMO: SKIPPED (PGVIGIL_SKIP_DEMO is set)"
  echo "NOT PROVEN HERE: the demo's rows (skipped); SQL Server 2016-2019, RDS, Managed Instance, Azure SQL Database, a real tuning recommendation, a real ERROR store, a really cleared store, the run's bounds, the interval floor's access path, a browser render"
  echo "proof-mssql-querystore: A-H, X, Y, Z, P green${V_NOTE:-, V green}; DEMO NOT RUN"
  exit 0
fi

echo "--- DEMO. a two-day demo"
adm -c "create database $DEMO_DB"; MADE_DEMO=1
DPORT=$(freeport 18331 18370)
"$BIN" demo -dsn "$ADMIN_DSN dbname=$DEMO_DB" -days 2 -serve -listen "127.0.0.1:$DPORT" > "$WORK/demo.log" 2>&1 & DEMO_PID=$!
for _ in $(seq 1 600); do grep -q "demo serving" "$WORK/demo.log" && break; kill -0 $DEMO_PID 2>/dev/null || break; sleep 1; done
grep -q "demo serving" "$WORK/demo.log" || { tail -5 "$WORK/demo.log" >&2; fail "DEMO: the demo never served"; }
D=http://127.0.0.1:$DPORT/api
dq() { psql "$ADMIN_DSN dbname=$DEMO_DB" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
s1=$(dq "select instance_id from pgvigil.instances where name like '%-sql01'"); s2=$(dq "select instance_id from pgvigil.instances where name like '%-sql02'")
[ "$(dq "select count(*) from pgvigil.mssql_qs_store where instance_id=$s1")" -ge 1 ] || fail "DEMO: the demo carries no Query Store rows: the seed's wiring (mssql_demo.go, the lead's) is not on this tree"
DW="from=$(date -u -d '-6 hours' +%FT%TZ)&to=$(date -u -d '+1 minute' +%FT%TZ)"; D1="from=$(date -u -d '-1 hour' +%FT%TZ)&to=$(date -u -d '+1 minute' +%FT%TZ)"
curl -fs "$D/mssql/querystore?instance=$s1&$DW" > "$WORK/d.json" || fail "DEMO: the page's read"
curl -fs "$D/mssql/querystore?instance=$s1&$D1&part=regressed" > "$WORK/dr.json" || fail "DEMO: the regressed part"
echo "  sql01: top $(objs "$WORK/d.json" top | jq length), forced $(objs "$WORK/d.json" forced | jq length), tuning $(objs "$WORK/d.json" tuning | jq length), regressed (1 h) $(objs "$WORK/dr.json" regressed | jq length)"
[ "$(objs "$WORK/d.json" top | jq 'length >= 8')" = true ] || fail "DEMO: the top list has $(objs "$WORK/d.json" top | jq length) queries"
[ "$(objs "$WORK/dr.json" regressed | jq '[.[] | select(.database_name == "Sales" and .query_id == 1 and .plan_id == 12 and .new_plan == true and .duration_ratio >= 1.5)] | length')" = 1 ] \
  || fail "DEMO: the regressed part: $(objs "$WORK/dr.json" regressed | jq -c '[.[] | {database_name, query_id, plan_id, new_plan, duration_ratio}]')"
[ "$(objs "$WORK/d.json" forced | jq '([.[] | select(.database_name == "Orders" and .plan_id == 44 and .force_failure_count >= 17 and .force_failure_reason == "NO_INDEX")] | length) == 1 and ([.[] | select(.database_name == "Sales" and .plan_id == 5)] | length) == 1')" = true ] \
  || fail "DEMO: the forced plans: $(objs "$WORK/d.json" forced | jq -c '[.[] | {database_name, plan_id, force_failure_count}]')"
[ "$(objs "$WORK/d.json" tuning | jq '[.[] | select(.rec_name == "PR_1" and .rec_state == "Active" and .is_present == true)] | length')" = 1 ] || fail "DEMO: the recommendation"
[ "$(objs "$WORK/d.json" state | jq -r '[.[] | select(.database_name == "Reporting")] | .[0] | .actual_state + "|" + .severity')" = "READ_ONLY|warning" ] || fail "DEMO: Reporting's store"
DF=$(dq "select string_agg(check_name || ':' || object, ',' order by check_name collate \"C\") from pgvigil.mssql_querystore_findings where instance_id=$s1")
[ "$DF" = "Query Store is read-only:Reporting,a forced plan fails:Orders: query 31, plan 44" ] || fail "DEMO: sql01's findings: $DF"
[ "$(dq "select string_agg(instance_id || ':' || critical || ':' || warning, ',' order by instance_id) from pgvigil.mssql_querystore_status where instance_id in ($s1, $s2)")" = "$s1:0:1,$s2:0:0" ] \
  || fail "DEMO: the status rows: $(dq "select string_agg(instance_id || ':' || critical || ':' || warning, ',' order by instance_id) from pgvigil.mssql_querystore_status where instance_id in ($s1, $s2)")"
curl -fs "$D/mssql/querystore/plan.sqlplan?instance=$s1&db=Sales&plan=7" | head -c 12 | grep -q '<ShowPlanXML' || fail "DEMO: plan 7's .sqlplan"
echo "DEMO: OK"

echo "NOT PROVEN HERE: SQL Server 2016-2019, RDS, Managed Instance, Azure SQL Database, a real tuning recommendation, a real ERROR store, a really cleared store, the run's bounds, the interval floor's access path, a browser render"
if [ -n "$V_NOTE" ]; then echo "proof-mssql-querystore: A-H, X, Y, Z, P, DEMO green$V_NOTE"; else echo "proof-mssql-querystore: PASS (A-H, X, Y, Z, V, P, DEMO)"; fi
