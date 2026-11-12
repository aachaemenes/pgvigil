#!/usr/bin/env bash
# Proof of task 150: the SQL Server plan cache, indexes and statistics (migration 0092_mssql_plancache_indexes.sql;
# internal/mssql/plancache.go, indexes.go, stats.go; internal/web/q_mssql_plancache.go, q_mssql_indexes.go) against a
# real SQL Server and, for the rules no fresh server can show (a usage window of 7 days, a statistic 30 days old, a
# cut read, a late read), on the proof's own repository rows.
#
# Needs: go (ONE binary is built into the temp folder; PGVIGIL_BIN names a built one instead), psql, curl, jq, ss,
# docker, and
#   PGVIGIL_ADMIN_DSN        a superuser connection to a PostgreSQL in KEYWORD form, no dbname and no password in it.
#   PGVIGIL_MSSQL_CONTAINER  an existing SQL Server sandbox container (PGVIGIL_MSSQL_ADDR, MSSQL_SA_PASSWORD). NOT set:
#                            the proof starts its own (MSSQL_IMAGE, default mcr.microsoft.com/mssql/server:2022-latest)
#                            with a throwaway sa password made here, and removes it at the end.
# The binary must carry the routes /api/mssql/plancache and /api/mssql/indexes (the lead's wiring in web.go).
# It makes, and drops on every exit path the shell can catch: its repository database (pgvigil_s150_<n>), on the SQL
# Server two databases and two logins (random suffix and passwords), its own container. No server setting is changed.
#
# Expected (written before the first run):
#  A. mssql_plancache. A parameterized statement (sp_executesql, MAXDOP 1) in pvpc_<n> (Query Store off) run 3
#     times, a first read (it stores no sample and no read row), 7 more runs, a second read: the sample of its query
#     hash in its database holds executions 7 and CPU, duration and logical reads equal to the rise of sa's own read
#     of sys.dm_exec_query_stats for that hash over the same span. The API's top part for that database lists that
#     hash FIRST (the most CPU) with the same figures (CPU and duration in ms, one decimal) and its text, exactly the
#     statement as the offsets cut it. [Corrected after run 2: the expectation was the marker comment 'pvheavy' in
#     the text; the comment follows the statement's last token, the offsets end before it, and the stored text is
#     the statement alone, as the server defines it.] scope=noqs keeps it; a statement run in pvqs_<n> (Query Store on) is listed without
#     the scope and not with it. A read row per difference (1), no figure below zero.
#  B. mssql_plancache_health. 150 ad hoc joins in pvpc_<n>, each with another literal (a join is never simple-
#     parameterized: one plan each, one query hash): the health row of pvpc_<n> holds 150 or more single-use plans
#     and one or more query hashes with several plans covering 150 or more statements; the findings view holds
#     'single-use plans in the cache' and 'one statement compiled into many plans' for pvpc_<n>; both lists name
#     pvpc_<n>.
#  C. mssql_indexes on pv_ix (50,000 rows, clustered PK; ix_a(a), ix_a2(a) the exact duplicate, ix_ab(a, b),
#     ix_c(c)), after 2 hinted seeks on ix_a, 4 on ix_ab and an update of 100 rows' c: the stored user_seeks of
#     ix_ab and user_updates of ix_c equal sa's read of sys.dm_db_index_usage_stats; the usage window's guard
#     starts 'too early' (the server started minutes ago) and judged is false; the verdicts: ix_a2 'exact
#     duplicate' kept instead ix_a with exactly 'ALTER INDEX [ix_a2] ON [dbo].[pv_ix] DISABLE;'; ix_a 'key subset'
#     kept instead ix_ab; ix_c NO verdict (too early to call it unused). A query on b alone leaves a missing-index
#     request: a stored row for pvpc_<n> on pv_ix whose equality columns name [b]; no text of the missing part
#     holds 'CREATE'. Then, in the proof's own repository, the window and the table's age are moved back 10 days:
#     the guard no longer says 'too early', ix_c is 'unused' with its DISABLE line and the under-14-days warning,
#     and the findings view holds 'unused indexes' and 'exact duplicate indexes' for pvpc_<n>.
#  D. mssql_stats: st_b on pv_ix(b) WITH NORECOMPUTE, then 20,000 rows of b changed: the stored modifications of
#     st_b equal sa's sys.dm_db_stats_properties modification_counter, props_read true (the login has a user with
#     db_datareader in pvpc_<n>), flags NORECOMPUTE and not stale (updated today). Its last update moved back 40 days
#     in the repository: flags start with stale, severity warning, and the findings view holds 'stale statistics'
#     for pvpc_<n>. In pvqs_<n>, where the login has no user: the database's row counts fewer statistics with
#     properties than statistics and its note says they were read without their properties.
#  F. a login with neither VIEW SERVER STATE nor any database right: mssql_plancache and mssql_indexes are skipped
#     naming VIEW SERVER STATE.
#  X. imported rows (no server): five plan cache reads 300 s apart and the second again, late: samples
#     K1:15,K1:5,K1:2,K3:7,K1:3,K2:10 (a statement new after a CUT read and compiled before it gives nothing, then its
#     difference; one compiled after it its whole count; lower counters give their whole count), read rows with
#     1,1,2,2 keys and capped f,t,f,f; the late read changes nothing.
#     [Added with the review fold, before the run that had it: K4, compiled before the cut read and run once, its run
#     ending after that read's clock, gives its whole count 1; the samples are K1:15,K1:5,K1:2,K3:7,K4:1,K1:3,K2:10
#     and the read rows 1,1,3,2.]
#  R. the index rules on imported rows (a 30-day window), written with the review fold before its first run: the kept
#     index of a key subset with no read (A1) is never called unused (its rule is 'same leading column', no text); the
#     subset's text merges [c] into A1 with DROP_EXISTING, then disables B1; in a chain A2 < B2 < C2, A2's text merges
#     [q] into B2 and B2 (itself kept for A2) has no text; a merge into a keeper with MIXED compression gives no text;
#     a unique index a foreign key is bound to, beside a unique constraint on the same key, is 'duplicate constraint'
#     with no text; a merge into a unique keeper with IGNORE_DUP_KEY = ON keeps it ON; an index of an AUTO_CLOSE
#     database is not judged ('the usage window is not known: AUTO_CLOSE is on'); a second read with lower counters
#     makes the window 'usage counters reset' and not judged; both databases have their read cursor.
#  P. the API: /api/mssql/plancache and /api/mssql/indexes answer with exactly their parts (10 and 8 names); an
#     unknown part is refused with 400. Step A also holds CPU and duration in ms to PostgreSQL's rounding of sa's
#     rise, and C and D hold the workload's own numbers (4 seeks, 1 write, 20,000 modifications).
#  NOT PROVEN HERE: SQL Server 2016-2019 (proof-mssql-versions.sh runs the SQL Server proofs on them once this proof
#  is on its list), RDS, Managed Instance, a list cut on a real server, a server with more databases than one run
#  reaches, the pages in a browser, the per-day missing-index finding (its threshold needs days of uptime).
set -euo pipefail
: "${PGVIGIL_ADMIN_DSN:?a superuser connection in keyword form, no dbname}"
for t in psql curl jq ss docker; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SUF=$RANDOM
WORK=$(mktemp -d); CFG=$WORK/cfg.yaml; OUT=$WORK/out
REPO_DB=pgvigil_s150_$SUF
DPC=pvpc_$SUF; DQS=pvqs_$SUF
L1=pgv_s150_$SUF; L2=pgv_s150bare_$SUF
N=proof-s150-$SUF; NB=proof-s150bare-$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
P1=$(pw); P2=$(pw)
fail() { echo "FAIL: $*" >&2; exit 1; }
# the listening sockets are read once into a variable: 'ss | grep -q' under pipefail would call a taken port free
# whenever grep left before ss had finished writing
freeport() { local l p; l=$(ss -ltn); for p in $(seq "$1" "$2"); do grep -qE "(127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|\*):$p " <<<"$l" || { echo "$p"; return; }; done; return 1; }
MADE_REPO=; MADE_DB=; MADE_L=(); MADE_CT=; SRV_PID=
CT=${PGVIGIL_MSSQL_CONTAINER:-}
sq() { docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -W -h -1 -s '|' -U sa -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
sqs() { docker exec -i -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -U sa -i /dev/stdin; }
cleanup() {
  rc=$?
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true
  if [ -n "$MADE_CT" ]; then
    docker rm -f "$CT" >/dev/null 2>&1 || echo "CLEANUP: container $CT not removed" >&2
  elif [ -n "$CT" ]; then
    if [ -n "$MADE_DB" ]; then
      for d in "$DPC" "$DQS"; do sq "IF DB_ID('$d') IS NOT NULL BEGIN ALTER DATABASE [$d] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$d]; END" >/dev/null 2>&1 || echo "CLEANUP: database $d not dropped" >&2; done
    fi
    for l in "${MADE_L[@]:-}"; do [ -n "$l" ] && { sq "IF SUSER_ID('$l') IS NOT NULL DROP LOGIN [$l];" >/dev/null 2>&1 || echo "CLEANUP: login $l not dropped" >&2; }; done
  fi
  [ -n "$MADE_REPO" ] && { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; }
  rm -rf "$WORK" || true
  exit $rc
}
trap cleanup EXIT; trap 'exit 143' TERM; trap 'exit 130' INT

echo "--- the binary"
BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then BIN=$WORK/pgvigil; (cd "$ROOT" && CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil) || fail "the build"; fi

echo "--- the SQL Server"
if [ -n "$CT" ]; then
  ADDR=${PGVIGIL_MSSQL_ADDR:-localhost:1433}; : "${MSSQL_SA_PASSWORD:?the sa password of the sandbox}"
else
  CT=pgv-s150-mssql-$SUF; MSSQL_SA_PASSWORD=$(pw); export MSSQL_SA_PASSWORD
  MPORT=$(freeport 22433 22499) || fail "no free port for the SQL Server container"; ADDR=127.0.0.1:$MPORT
  MADE_CT=1
  docker run -d --name "$CT" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -p "127.0.0.1:$MPORT:1433" "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || fail "docker run"
fi
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
sq "SELECT 1" >/dev/null 2>&1 || fail "the SQL Server in $CT does not answer"
echo "  $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(40)) + ' ' + CAST(SERVERPROPERTY('Edition') AS varchar(80))")"

adm() { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

mklogin() { printf "CREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\n" "$1" "$2" | sqs >/dev/null; MADE_L+=("$1"); }
mklogin "$L1" "$P1"; mklogin "$L2" "$P2"
sq "GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1]; GRANT CONNECT ANY DATABASE TO [$L1];" >/dev/null
export MS_MON="sqlserver://$L1:$P1@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export MS_BARE="sqlserver://$L2:$P2@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
{ echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_MON\n' "$N"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_BARE\n' "$NB"; } > "$CFG"
MADE_DB=1   # before the batch: a half-made pair is still this run's to drop (the drops are guarded)
sq "CREATE DATABASE [$DPC]; ALTER DATABASE [$DPC] SET RECOVERY SIMPLE; ALTER DATABASE [$DPC] SET QUERY_STORE = OFF;
    CREATE DATABASE [$DQS]; ALTER DATABASE [$DQS] SET RECOVERY SIMPLE; ALTER DATABASE [$DQS] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);" >/dev/null
sq "CREATE TABLE dbo.pv_t (id int IDENTITY PRIMARY KEY, grp int NOT NULL, pad char(100) NOT NULL DEFAULT 'x');
    INSERT dbo.pv_t (grp) SELECT TOP (20000) ABS(CHECKSUM(NEWID())) % 10 FROM sys.all_columns a CROSS JOIN sys.all_columns b;
    CREATE TABLE dbo.pv_ix (id int NOT NULL CONSTRAINT PK_pv_ix PRIMARY KEY CLUSTERED, a int NOT NULL, b int NOT NULL, c int NOT NULL, pad char(50) NOT NULL DEFAULT 'x');
    INSERT dbo.pv_ix (id, a, b, c) SELECT n, n % 500, n % 97, n % 1000 FROM (SELECT TOP (50000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_columns a CROSS JOIN sys.all_columns b) x;
    CREATE INDEX ix_a ON dbo.pv_ix (a); CREATE INDEX ix_a2 ON dbo.pv_ix (a); CREATE INDEX ix_ab ON dbo.pv_ix (a, b); CREATE INDEX ix_c ON dbo.pv_ix (c);
    CREATE STATISTICS st_b ON dbo.pv_ix (b) WITH FULLSCAN, NORECOMPUTE;
    CREATE USER [$L1] FOR LOGIN [$L1]; ALTER ROLE db_datareader ADD MEMBER [$L1];" "$DPC" >/dev/null
sq "CREATE TABLE dbo.pv_q (id int NOT NULL PRIMARY KEY, v int NOT NULL);
    INSERT dbo.pv_q (id, v) SELECT TOP (20000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 1 FROM sys.all_columns a CROSS JOIN sys.all_columns b;" "$DQS" >/dev/null
"$BIN" migrate -config "$CFG" >/dev/null || fail "migrate"
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$2" > "$OUT" 2>&1 || { cat "$OUT" >&2; return 1; }; cat "$OUT"; }
win() { echo "from=$(date -u -d '-6 hours' +%FT%TZ)&to=$(date -u -d '+1 minute' +%FT%TZ)"; }
objs() { jq -c --arg p "$2" '.[$p] as $t | [$t.rows[] | [$t.columns, .] | transpose | map({(.[0]): .[1]}) | add]' "$1"; }

echo "--- A. mssql_plancache"
HEAVY="SELECT COUNT_BIG(*) FROM dbo.pv_t a CROSS JOIN dbo.pv_t b WHERE a.grp = @g AND b.id < 3000 OPTION (MAXDOP 1) /*pvheavy*/"
runheavy() { sq "DECLARE @i int = 0; WHILE @i < $1 BEGIN EXEC sys.sp_executesql N'$HEAVY', N'@g int', @g = 3; SET @i += 1; END" "$DPC" >/dev/null; }
# HS: sa's read of the heavy statement (hash|executions|CPU us|duration us|logical reads)
HS() { sq "SELECT CONVERT(varchar(20), MAX(qs.query_hash), 1) + '|' + CAST(SUM(qs.execution_count) AS varchar(20)) + '|' + CAST(SUM(qs.total_worker_time) AS varchar(20)) + '|' + CAST(SUM(qs.total_elapsed_time) AS varchar(20)) + '|' + CAST(SUM(qs.total_logical_reads) AS varchar(20))
           FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t WHERE t.text LIKE N'(@g int)%pvheavy%'"; }
runheavy 3
collect mssql_plancache "$N" >/dev/null
iid=$(q "select instance_id from pgvigil.instances where name='$N'")
[ "$(q "select (select count(*) from pgvigil.mssql_pc_sample where instance_id=$iid) || '|' || (select count(*) from pgvigil.mssql_pc_read where instance_id=$iid)")" = "0|0" ] || fail "A: the first read stored a sample or a read row"
H0=$(HS); runheavy 7; H1=$(HS)
sq "EXEC sys.sp_executesql N'SELECT COUNT(*) FROM dbo.pv_q WHERE v = @v /*pvqsstmt*/', N'@v int', @v = 1;" "$DQS" >/dev/null
sleep 1
collect mssql_plancache "$N"
IFS='|' read -r HASH E0 C0 D0 R0 <<<"$H0"; IFS='|' read -r _ E1 C1 D1 R1 <<<"$H1"
WANT="$((E1 - E0))|$((C1 - C0))|$((D1 - D0))|$((R1 - R0))"
GOT=$(q "select coalesce((select executions || '|' || cpu_us || '|' || duration_us || '|' || logical_reads from pgvigil.mssql_pc_sample where instance_id=$iid and query_key='$HASH' and database_name='$DPC'), 'none')")
echo "  $HASH in $DPC (executions|CPU us|duration us|logical reads): stored $GOT, sa's rise $WANT"
[ "$GOT" = "$WANT" ] && [ "${WANT%%|*}" = 7 ] || fail "A: stored $GOT, sa's rise $WANT"
[ "$(q "select count(*) from pgvigil.mssql_pc_read where instance_id=$iid")" = 1 ] || fail "A: the read rows"
[ "$(q "select count(*) from pgvigil.mssql_pc_sample where instance_id=$iid and (executions <= 0 or cpu_us < 0 or duration_us < 0 or logical_reads < 0)")" = 0 ] || fail "A: a figure below zero"

PORT=$(freeport 18340 18380) || fail "no free port for the UI"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" -no-login > "$WORK/serve.log" 2>&1 & SRV_PID=$!
U=http://127.0.0.1:$PORT/api
for _ in $(seq 1 40); do curl -fs "$U/health" >/dev/null 2>&1 && break; sleep 0.25; done
for r in plancache indexes; do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$U/mssql/$r?instance=$iid")" != 404 ] || fail "the binary has no route /api/mssql/$r (the lead's wiring in web.go)"
done
DBID=$(sq "SELECT DB_ID('$DPC')")
curl -fs "$U/mssql/plancache?instance=$iid&$(win)&db=$DBID" > "$WORK/pc.json" || fail "A: /api/mssql/plancache"
TOP=$(objs "$WORK/pc.json" top | jq -c '.[0]')
echo "  the API's first row for $DPC: $(jq -c '{query_key, executions, cpu_ms, duration_ms, logical_reads, q: (.query // "" | .[0:60])}' <<<"$TOP")"
[ "$(jq -r '.query_key' <<<"$TOP")" = "$HASH" ] || fail "A: the top statement is not the heavy one: $TOP"
[ "$(jq -r '"\(.executions)|\(.logical_reads)"' <<<"$TOP")" = "7|$((R1 - R0))" ] || fail "A: the top row's figures: $TOP"
# CPU and duration in ms with PostgreSQL's own rounding (awk's differs at a half)
WMS=$(q "select round($((C1 - C0)) / 1000.0, 1) || '|' || round($((D1 - D0)) / 1000.0, 1)")
[ "$(jq -r '"\(.cpu_ms)|\(.duration_ms)"' <<<"$TOP" | sed 's/\.0|/|/; s/\.0$//')" = "$(sed 's/\.0|/|/; s/\.0$//' <<<"$WMS")" ] || fail "A: CPU|duration ms $(jq -r '"\(.cpu_ms)|\(.duration_ms)"' <<<"$TOP"), want $WMS"
jq -e '.query == "SELECT COUNT_BIG(*) FROM dbo.pv_t a CROSS JOIN dbo.pv_t b WHERE a.grp = @g AND b.id < 3000 OPTION (MAXDOP 1)"' <<<"$TOP" >/dev/null || fail "A: the top row's text is not the statement's: $TOP"
QSH=$(sq "SELECT TOP (1) CONVERT(varchar(20), qs.query_hash, 1) FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t WHERE t.text LIKE N'(@v int)%pvqsstmt%'")
curl -fs "$U/mssql/plancache?instance=$iid&$(win)" > "$WORK/pc_all.json"; curl -fs "$U/mssql/plancache?instance=$iid&$(win)&scope=noqs" > "$WORK/pc_noqs.json"
[ "$(objs "$WORK/pc_all.json" top | jq --arg h "$QSH" '[.[] | select(.query_key == $h)] | length')" -ge 1 ] || fail "A: the Query Store database's statement $QSH is not listed"
[ "$(objs "$WORK/pc_noqs.json" top | jq --arg h "$QSH" --arg k "$HASH" '[.[] | select(.query_key == $h)] | length')" = 0 ] || fail "A: scope=noqs lists the Query Store database's statement"
[ "$(objs "$WORK/pc_noqs.json" top | jq --arg k "$HASH" '[.[] | select(.query_key == $k)] | length')" = 1 ] || fail "A: scope=noqs lost the heavy statement"
echo "A: OK"

echo "--- B. mssql_plancache_health"
sq "DECLARE @i int = 1, @s nvarchar(400); WHILE @i <= 150 BEGIN SET @s = N'SELECT COUNT(*) FROM dbo.pv_t a JOIN dbo.pv_t b ON b.id = a.id WHERE a.id < ' + CAST(@i AS nvarchar(10)) + N' /*pvsingle*/'; EXEC (@s); SET @i += 1; END" "$DPC" >/dev/null
collect mssql_plancache_health "$N"
HR=$(q "select single_use || '|' || duplicate_hashes || '|' || duplicate_statements from pgvigil.mssql_pc_health where instance_id=$iid and database_name='$DPC'")
echo "  $DPC: single-use|hashes with several plans|their statements = $HR"
IFS='|' read -r SU DH DS <<<"$HR"
[ "${SU:-0}" -ge 150 ] && [ "${DH:-0}" -ge 1 ] && [ "${DS:-0}" -ge 150 ] || fail "B: the health row $HR"
for c in 'single-use plans in the cache' 'one statement compiled into many plans'; do
  [ "$(q "select count(*) from pgvigil.mssql_plancache_findings where instance_id=$iid and object='$DPC' and check_name='$c'")" = 1 ] || fail "B: no finding '$c'"
done
[ "$(q "select count(distinct list) from pgvigil.mssql_pc_list where instance_id=$iid and database_name='$DPC'")" = 2 ] || fail "B: the lists"
echo "B: OK"

echo "--- C. mssql_indexes"
sq "UPDATE dbo.pv_ix SET b = b + 1 WHERE id <= 20000;" "$DPC" >/dev/null   # D's change, before the index reads
for _ in 1 2; do sq "SELECT COUNT(*) FROM dbo.pv_ix WITH (INDEX(ix_a)) WHERE a = 5;" "$DPC" >/dev/null; done
for _ in 1 2 3 4; do sq "SELECT COUNT(*) FROM dbo.pv_ix WITH (INDEX(ix_ab)) WHERE a = 5 AND b = 3;" "$DPC" >/dev/null; done
sq "UPDATE dbo.pv_ix SET c = c + 1 WHERE id <= 100;" "$DPC" >/dev/null
for _ in 1 2 3; do sq "SELECT id, pad FROM dbo.pv_ix WHERE b = 7;" "$DPC" >/dev/null; done
collect mssql_indexes "$N"
US=$(sq "SELECT (SELECT CAST(user_seeks AS varchar(20)) FROM sys.dm_db_index_usage_stats WHERE database_id = DB_ID() AND object_id = OBJECT_ID('dbo.pv_ix') AND index_id = INDEXPROPERTY(OBJECT_ID('dbo.pv_ix'), 'ix_ab', 'IndexID')) + '|' + (SELECT CAST(user_updates AS varchar(20)) FROM sys.dm_db_index_usage_stats WHERE database_id = DB_ID() AND object_id = OBJECT_ID('dbo.pv_ix') AND index_id = INDEXPROPERTY(OBJECT_ID('dbo.pv_ix'), 'ix_c', 'IndexID'))" "$DPC")
ST=$(q "select (select user_seeks from pgvigil.mssql_index where instance_id=$iid and database_name='$DPC' and index_name='ix_ab') || '|' || (select user_updates from pgvigil.mssql_index where instance_id=$iid and database_name='$DPC' and index_name='ix_c')")
echo "  ix_ab seeks | ix_c writes: stored $ST, sa reads $US"
[ "$ST" = "$US" ] && [ "$US" = "4|1" ] || fail "C: usage stored $ST, sa reads $US, the workload makes 4|1"
G=$(q "select judged || '|' || guard from pgvigil.mssql_index_db_status where instance_id=$iid and database_name='$DPC'")
echo "  guard: $G"
[[ $G == "false|too early:"* ]] || fail "C: the guard on a fresh server: $G"
verdict() { q "select coalesce((select rule || '|' || coalesce(keeper, '') || '|' || coalesce(script, '') from pgvigil.mssql_index_verdicts($iid) v join pgvigil.mssql_index x on x.instance_id=$iid and x.database_name=v.database_name and x.object_id=v.object_id and x.index_id=v.index_id where v.database_name='$DPC' and x.index_name='$1'), 'none')"; }
q "select x.index_name, v.rule, v.keeper from pgvigil.mssql_index_verdicts($iid) v join pgvigil.mssql_index x on x.instance_id=$iid and x.database_name=v.database_name and x.object_id=v.object_id and x.index_id=v.index_id where v.database_name='$DPC' order by 1" | sed 's/^/  verdict: /'
[ "$(verdict ix_a2)" = "exact duplicate|ix_a|ALTER INDEX [ix_a2] ON [dbo].[pv_ix] DISABLE;" ] || fail "C: ix_a2: $(verdict ix_a2)"
[[ $(verdict ix_a) == "key subset|ix_ab|"* ]] || fail "C: ix_a: $(verdict ix_a)"
[ "$(verdict ix_c)" = none ] || fail "C: ix_c is judged on a fresh server: $(verdict ix_c)"
[ "$(q "select count(*) from pgvigil.mssql_missing_index where instance_id=$iid and database_name='$DPC' and table_ref like '%pv_ix%' and equality_columns like '%[b]%'")" -ge 1 ] || fail "C: no missing-index request on b: $(q "select string_agg(coalesce(table_ref,'?') || ' eq ' || coalesce(equality_columns,'-') || ' in ' || coalesce(inequality_columns,'-'), '; ') from pgvigil.mssql_missing_index where instance_id=$iid")"
curl -fs "$U/mssql/indexes?instance=$iid&part=missing" > "$WORK/mi.json" || fail "C: the missing part"
! grep -qi 'create' "$WORK/mi.json" || fail "C: the missing part holds CREATE"
# the window and the table moved back 10 days in this proof's own repository
q "update pgvigil.mssql_index_db set usage_since = read_at - interval '10 days' where instance_id=$iid and database_name='$DPC';
   update pgvigil.mssql_index set table_created = snapshot_at - interval '10 days', table_modified = snapshot_at - interval '10 days' where instance_id=$iid and database_name='$DPC'" >/dev/null
G=$(q "select judged || '|' || guard from pgvigil.mssql_index_db_status where instance_id=$iid and database_name='$DPC'")
[[ $G == "true|the usage counters cover 10.0 day(s)"* ]] || fail "C: the guard after 10 days: $G"
V=$(verdict ix_c)
echo "  ix_c after 10 days: $V"
[ "$V" = "unused||ALTER INDEX [ix_c] ON [dbo].[pv_ix] DISABLE;" ] || fail "C: ix_c after 10 days: $V"
q "select detail from pgvigil.mssql_index_verdicts($iid) v join pgvigil.mssql_index x on x.instance_id=$iid and x.database_name=v.database_name and x.object_id=v.object_id and x.index_id=v.index_id where x.index_name='ix_c' and v.database_name='$DPC'" | grep -q 'Under 14 days' || fail "C: ix_c's detail lacks the 14-day warning"
for c in 'unused indexes' 'exact duplicate indexes'; do
  [ "$(q "select count(*) from pgvigil.mssql_indexes_findings where instance_id=$iid and object='$DPC' and check_name='$c'")" = 1 ] || fail "C: no finding '$c'"
done
echo "C: OK"

echo "--- D. mssql_stats"
collect mssql_stats "$N"
MOD=$(sq "SELECT CAST(sp.modification_counter AS varchar(20)) FROM sys.stats s CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp WHERE s.object_id = OBJECT_ID('dbo.pv_ix') AND s.name = 'st_b'" "$DPC")
SR=$(q "select modifications || '|' || props_read || '|' || array_to_string(flags, ',') from pgvigil.mssql_stat_status where instance_id=$iid and database_name='$DPC' and stats_name='st_b'")
echo "  st_b: stored modifications|props|flags $SR, sa's modification_counter $MOD"
[ "$SR" = "$MOD|true|NORECOMPUTE" ] && [ "$MOD" = 20000 ] || fail "D: st_b $SR, sa's counter $MOD (the workload changes 20000 rows)"
q "update pgvigil.mssql_stat set last_updated = snapshot_at - interval '40 days' where instance_id=$iid and database_name='$DPC' and stats_name='st_b'" >/dev/null
SR=$(q "select severity || '|' || array_to_string(flags, ',') from pgvigil.mssql_stat_status where instance_id=$iid and database_name='$DPC' and stats_name='st_b'")
[ "$SR" = "warning|stale,NORECOMPUTE" ] || fail "D: st_b 40 days old: $SR"
[ "$(q "select count(*) from pgvigil.mssql_stats_findings where instance_id=$iid and object='$DPC' and check_name='stale statistics'")" = 1 ] || fail "D: no stale statistics finding"
QR=$(q "select (statistics > statistics_with_props) || '|' || coalesce(note, '') from pgvigil.mssql_stats_db where instance_id=$iid and database_name='$DQS'")
echo "  $DQS: $QR"
[[ $QR == "true|"*"without their properties"* ]] || fail "D: $DQS without a user: $QR"
echo "D: OK"

echo "--- F. a login with no right"
for c in mssql_plancache mssql_indexes; do
  collect "$c" "$NB" > "$WORK/bare.out" || true
  grep -q "skipped: .*VIEW SERVER STATE" "$WORK/bare.out" || fail "F: $c: $(cat "$WORK/bare.out")"
done
echo "F: OK"

echo "--- X. imported rows"
NOW=$(date -u +%s)
UT() { date -u -d "@$((NOW - $1))" +%FT%TZ; }
LT_() { date -u -d "@$((NOW - $1 - 28800))" +%FT%T; }
xp=$(q "select pgvigil.ensure_instance('proof-s150-x-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
pimp() { q "select pgvigil.import_mssql_plancache($xp, '$(UT "$1")', ('[{\"kind\":\"state\",\"server_utc\":\"$(UT "$1")\",\"server_start\":\"2026-01-01T00:00:00Z\",\"server_local\":\"$(LT_ "$1")\",\"capped\":$2}' || '$3' || ']')::jsonb)" >/dev/null; }
srow() { echo ",{\"kind\":\"stmt\",\"plan_handle\":\"0x06$1\",\"stmt_start\":0,\"stmt_end\":-1,\"creation_time\":\"$(LT_ "$3")\",\"query_key\":\"$2\",\"database_id\":5,\"database_name\":\"appdb\",\"execution_count\":$4,\"worker_us\":$(($4 * 100))${5:+,\"last_execution\":\"$(LT_ "${5:-0}")\",\"last_elapsed_us\":${6:-0}}}"; }
pimp 1500 false "$(srow 01 K1 4000 10)"
pimp 1200 false "$(srow 01 K1 4000 25)"
pimp 900 true "$(srow 01 K1 4000 30)"
pimp 600 false "$(srow 01 K1 4000 32)$(srow 02 K2 4000 50)$(srow 03 K3 700 7)$(srow 04 K4 1000 1 950 100000000)"   # K4: compiled before the cut read, run once 950 s ago for 100 s: ended after it
pimp 300 false "$(srow 01 K1 4000 3)$(srow 02 K2 4000 60)"
pimp 1200 false "$(srow 01 K1 4000 999)"   # the second read again, late
GOT=$(q "select string_agg(query_key || ':' || executions, ',' order by snapshot_at, query_key) from pgvigil.mssql_pc_sample where instance_id=$xp")
[ "$GOT" = "K1:15,K1:5,K1:2,K3:7,K4:1,K1:3,K2:10" ] || fail "X: samples $GOT"
GOT=$(q "select string_agg(statements || '/' || capped, ',' order by snapshot_at) from pgvigil.mssql_pc_read where instance_id=$xp")
[ "$GOT" = "1/false,1/true,3/false,2/false" ] || fail "X: read rows $GOT"
echo "X: OK"

echo "--- R. the index rules on imported rows"
xi=$(q "select pgvigil.ensure_instance('proof-s150-r-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
D30=$(date -u -d '-30 days' +%FT%TZ)
# ix <object> <index id> <name> <keys json> <includes json> <reads> [extra fields]
ix() { echo ",{\"kind\":\"index\",\"database_name\":\"$DBN\",\"database_id\":7,\"object_id\":$1,\"index_id\":$2,\"schema_name\":\"dbo\",\"table_name\":\"t$1\",\"index_name\":\"$3\",\"index_type\":\"NONCLUSTERED\",\"key_columns\":$4,\"include_columns\":$5,\"user_seeks\":$6,\"user_updates\":0,\"compression\":\"NONE\",\"table_created\":\"$D30\",\"table_modified\":\"$D30\"${7:-}}"; }
# imp <seconds ago> <database> <auto_close> <rows>
imp() { q "select pgvigil.import_mssql_indexes($xi, '$(UT "$1")', ('[{\"kind\":\"state\",\"server_utc\":\"$(UT "$1")\",\"server_start\":\"$D30\"},{\"kind\":\"db\",\"database_name\":\"$2\",\"database_id\":7,\"database_state\":\"ONLINE\",\"created_at\":\"$D30\",\"restore_read\":true,\"auto_close\":$3,\"read\":true}' || '$4' || ']')::jsonb)" >/dev/null; }
DBN=rdb
ROWS="$(ix 1 2 A1 '["[x]","[y]"]' '[]' 0)$(ix 1 3 B1 '["[x]"]' '["[c]"]' 5000)"
ROWS+="$(ix 2 2 A2 '["[p]"]' '["[q]"]' 1)$(ix 2 3 B2 '["[p]","[r]"]' '[]' 1)$(ix 2 4 C2 '["[p]","[r]","[s]"]' '[]' 1)"
ROWS+="$(ix 3 2 D3 '["[m]"]' '["[n]"]' 1)$(ix 3 3 E3 '["[m]","[o]"]' '[]' 1 ',"compression":"MIXED"')"
ROWS+="$(ix 4 2 UQ4 '["[k]"]' '[]' 1 ',"is_unique":1,"is_unique_constraint":1')$(ix 4 3 UX4 '["[k]"]' '[]' 1 ',"is_unique":1,"fk_referenced":1')"
ROWS+="$(ix 5 2 UXK5 '["[k1]","[k2]"]' '[]' 1 ',"is_unique":1,"ignore_dup_key":1')$(ix 5 3 IXK5 '["[k1]"]' '["[p]"]' 1)"
imp 7200 rdb false "$ROWS"
DBN=adb; imp 7200 adb true "$(ix 9 2 U9 '["[z]"]' '[]' 0)"
rv() { q "select coalesce((select v.rule || '|' || coalesce(v.keeper, '') || '|' || coalesce(v.script, '') from pgvigil.mssql_index_verdicts($xi) v join pgvigil.mssql_index x on x.instance_id=$xi and x.database_name=v.database_name and x.object_id=v.object_id and x.index_id=v.index_id where x.index_name='$1'), 'none')"; }
q "select x.index_name || ': ' || v.rule || ' / ' || coalesce(v.keeper, '-') || ' / ' || replace(coalesce(v.script, '(no text)'), chr(10), ' + ') from pgvigil.mssql_index_verdicts($xi) v join pgvigil.mssql_index x on x.instance_id=$xi and x.database_name=v.database_name and x.object_id=v.object_id and x.index_id=v.index_id order by 1" | sed 's/^/  /'
V=$(rv A1); [[ $V == "same leading column||" ]] || fail "R: A1, the kept index of a merge with no read, is named: $V"
V=$(rv B1); [[ $V == "key subset|A1|CREATE NONCLUSTERED INDEX [A1] ON [dbo].[t1] ([x], [y]) INCLUDE ([c]) WITH (DROP_EXISTING = ON,"*$'\n'"ALTER INDEX [B1] ON [dbo].[t1] DISABLE;" ]] || fail "R: B1: $V"
V=$(rv A2); [[ $V == "key subset|B2|CREATE NONCLUSTERED INDEX [B2] ON [dbo].[t2] ([p], [r]) INCLUDE ([q])"*"ALTER INDEX [A2] ON [dbo].[t2] DISABLE;" ]] || fail "R: A2: $V"
V=$(rv B2); [ "$V" = "key subset|C2|" ] || fail "R: B2, kept in place of A2, has a text: $V"
V=$(rv D3); [ "$V" = "key subset|E3|" ] || fail "R: D3, its merge cannot be written (MIXED), has a text: $V"
V=$(rv UX4); [ "$V" = "duplicate constraint|UQ4|" ] || fail "R: UX4, a foreign key's index: $V"
V=$(rv IXK5); [[ $V == "key subset|UXK5|CREATE UNIQUE NONCLUSTERED INDEX [UXK5]"*"INCLUDE ([p])"*"IGNORE_DUP_KEY = ON"*"ALTER INDEX [IXK5] ON [dbo].[t5] DISABLE;" ]] || fail "R: IXK5: $V"
V=$(rv U9); [ "$V" = none ] || fail "R: an index of an AUTO_CLOSE database is judged: $V"
G=$(q "select judged || '|' || guard from pgvigil.mssql_index_db_status where instance_id=$xi and database_name='adb'")
[[ $G == "false|the usage window is not known: AUTO_CLOSE is on"* ]] || fail "R: the AUTO_CLOSE guard: $G"
# a reset between two reads: B1's counters went down
DBN=rdb; imp 3600 rdb false "$(ix 1 2 A1 '["[x]","[y]"]' '[]' 0)$(ix 1 3 B1 '["[x]"]' '["[c]"]' 10)"
G=$(q "select judged || '|' || usage_reason from pgvigil.mssql_index_db_status where instance_id=$xi and database_name='rdb'")
[ "$G" = "false|usage counters reset (the database was closed or taken offline)" ] || fail "R: the reset: $G"
[ "$(q "select count(*) from pgvigil.mssql_cursor where instance_id=$xi and source in ('ix:rdb', 'ix:adb')")" = 2 ] || fail "R: the read cursors"
echo "R: OK"

echo "--- P. the API's parts"
declare -A PARTS=([plancache]="databases duplicates findings health reads series singles state top totals" [indexes]="databases findings indexes missing state stats statsdbs verdicts")
for r in plancache indexes; do
  curl -fs "$U/mssql/$r?instance=$iid&$(win)" > "$WORK/p.json" || fail "P: /api/mssql/$r"
  [ "$(jq -r 'keys | join(" ")' "$WORK/p.json")" = "${PARTS[$r]}" ] || fail "P: /api/mssql/$r parts $(jq -r 'keys | join(" ")' "$WORK/p.json"), want ${PARTS[$r]}"
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$U/mssql/$r?instance=$iid&part=nosuch")" = 400 ] || fail "P: an unknown part of $r"
done
echo "P: OK"
echo "NOT PROVEN HERE: SQL Server 2016-2019, RDS, Managed Instance, a list cut on a real server, a server with more databases than one run reaches, the pages in a browser, the per-day missing-index finding"
echo "proof-mssql-plancache-indexes: PASS (A, B, C, D, F, X, R, P)"
