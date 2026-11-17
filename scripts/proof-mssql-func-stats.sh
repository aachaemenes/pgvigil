#!/usr/bin/env bash
# Proof of D467: the scalar functions' and the triggers' figures beside the procedures, and the inlineability mark
# (internal/mssql/funcstats.go, the collection mssql_funcstats; migration 0343_mssql_func_stats.sql;
# internal/web/q_mssql_procs.go's parts functions, triggers and func_state; web/src/mssql_procs.ts) against a real
# SQL Server.
#
# Needs: go (ONE binary is built into the temp folder, PGVIGIL_BIN names a built one instead), psql, curl, jq, ss,
# docker, and
#   PGVIGIL_ADMIN_DSN        a superuser connection to a PostgreSQL in KEYWORD form, no dbname and no password in it.
#   PGVIGIL_MSSQL_CONTAINER  an existing SQL Server sandbox container (PGVIGIL_MSSQL_ADDR, MSSQL_SA_PASSWORD). NOT set:
#                            the proof starts its own (MSSQL_IMAGE, default mcr.microsoft.com/mssql/server:2022-latest)
#                            with a throwaway sa password made here, and removes it at the end.
#   PGVIGIL_PAGE_CHECK=1     runs FS4 (needs chromium, node 22+ and npm; the web bundle internal/web/dist/app.js built
#                            from this tree first - npm run build in web/ - so the binary built here carries it).
# It makes, and drops on every exit path the shell can catch: its repository database (pgvigil_fs_<n>), on the SQL
# Server two databases and one login (random suffix and password), and - on its OWN container only, never a shared
# sandbox - one server DDL trigger and the two databases that fire it; its own container. No server setting changes.
#
# The rows and what each expects (written before the first run):
#  S0. A batch the server refuses - CREATE FUNCTION behind sq's SET NOCOUNT ON, Msg 111 - comes back through sq with
#      sqlcmd's exit and the server's message on stderr; else the proof stops.
#  FS1. Between two reads of mssql_funcstats: dbo.f_off (WITH INLINE = OFF) called over 7 rows stores 7 executions in
#      one interval, equal to the rise of sa's sys.dm_exec_function_stats; dbo.f_now (GETDATE() in its body) over 5
#      rows 5; dbo.f_inl called under OPTION (USE HINT('DISABLE_TSQL_SCALAR_UDF_INLINING')) over 4 rows 4. dbo.f_plain
#      (inlineable) called plainly over 6 rows, the multi-statement table-valued dbo.f_tvf and the inline table-valued
#      dbo.f_itvf, each over 3 rows: no row in sa's read of the view and none in the store (the server lists no
#      table-valued function and no scalar function it inlined - Microsoft Learn, sys.dm_exec_function_stats; trial
#      T5 on 2022 CU27). The function rows carry no spills (the view has none). The API's functions part holds the
#      three by name, the busiest CPU first, no spills column.
#  FS2. An AFTER INSERT trigger fired by 3 INSERT statements stores 3 executions, equal to the rise of sa's
#      sys.dm_exec_trigger_stats; a DATABASE DDL trigger (FOR CREATE_TABLE) fired twice stores 2, named from its
#      database's sys.triggers (the view's OBJECT_NAME is NULL for it: T2) with scope 'database'; on the proof's own
#      container a SERVER DDL trigger (FOR CREATE_DATABASE) fired twice stores 2 under master, named from
#      sys.server_triggers, scope 'server' (on a shared sandbox: NOT RUN, said). The API's triggers part holds them.
#  FS3. The marks at compatibility 160 (the API's functions part, inline_mark): f_now 'not inlineable', f_off
#      'inlining off', f_inl '' (inlineable and on: it ran without inlining for the call's hint), each equal to sa's
#      sys.sql_modules flags; dbo.f_d2 in a second database where the monitoring login has no user (and no CONNECT
#      ANY DATABASE): its calls stored (2), its mark 'not read', the run 'partial' with a note naming that database
#      (a part not read, never 'error': the figures of every function and trigger stored).
#  FS4. The page (scripts/func-stats-page.mjs, a headless Chromium, light and dark): the Procedures tab shows
#      'Functions (scalar, run without inlining)' with its line about the table-valued and inlined functions, an
#      'inlining' column holding the four forms, no spilled-pages column; 'Triggers' with a 'scope' column ('database',
#      and 'server' on the proof's own container) and the spilled pages; the Extremes box adds the extremes to both
#      (no spilled-pages extreme on the functions); axe 0 nodes (WCAG 2.1 A / AA).
#  NOT PROVEN HERE: SQL Server 2016-2019 (the view's columns an older build lacks and sys.sql_modules without the two
#  flags are Go rows), a logon trigger (one that failed would refuse every later sign-in: not fired here), a read cut
#  at the cap of 5,000 plans, RDS and Managed Instance, keyboard order and a screen reader on the page (axe judges what
#  a rule can), the purge of the new tables (join lines).
set -euo pipefail
: "${PGVIGIL_ADMIN_DSN:?a superuser connection in keyword form, no dbname}"
for t in psql curl jq ss docker go; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SUF=$RANDOM
WORK=$(mktemp -d); CFG=$WORK/cfg.yaml; OUT=$WORK/out
REPO_DB=pgvigil_fs_$SUF
D1=pvfs_$SUF; D2=pvfs2_$SUF
L1=pgv_fs_$SUF
SRVTRG=fs_srv_$SUF; FX=fsx_$SUF
N=proof-fs-$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
P1=$(pw)
fail() { echo "FAIL: $*" >&2; exit 1; }
# the listening sockets are read once into a variable: 'ss | grep -q' under pipefail would call a taken port free
# whenever grep left before ss had finished writing
freeport() { local l p; l=$(ss -ltn); for p in $(seq "$1" "$2"); do grep -qE "(127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|\*):$p " <<<"$l" || { echo "$p"; return; }; done; return 1; }
MADE_REPO=; MADE_DB=; MADE_L=; MADE_CT=; MADE_TRG=; SRV_PID=; CHR_PID=
CT=${PGVIGIL_MSSQL_CONTAINER:-}
# sq / sqs: sqlcmd prints a failed batch's error on stdout, and most callers here send stdout to /dev/null - so a
# failed batch says why on stderr (its first lines) before sqlcmd's exit is returned. sq puts SET NOCOUNT ON first:
# a statement that must open its batch (CREATE FUNCTION, CREATE TRIGGER) goes through sqs.
sqsay() { echo "sqlcmd exit $1: $(head -n 6 <<<"$2" | cut -c1-300)" >&2; }
sq() { local o rc=0; o=$(docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -W -h -1 -s '|' -t 600 -U sa -d "${2:-master}" -Q "SET NOCOUNT ON; $1") || rc=$?; [ -z "$o" ] || printf '%s\n' "$o"; [ "$rc" = 0 ] || sqsay "$rc" "$o"; return "$rc"; }
sqs() { local o rc=0; o=$(docker exec -i -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -U sa -i /dev/stdin) || rc=$?; [ -z "$o" ] || printf '%s\n' "$o"; [ "$rc" = 0 ] || sqsay "$rc" "$o"; return "$rc"; }
dropdb() { sq "IF DB_ID('$1') IS NOT NULL BEGIN ALTER DATABASE [$1] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$1]; END" >/dev/null 2>&1 || echo "CLEANUP: database $1 not dropped" >&2; }
cleanup() {
  rc=$?
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true
  [ -n "$CHR_PID" ] && kill "$CHR_PID" 2>/dev/null || true
  if [ -n "$MADE_CT" ]; then
    docker rm -f -v "$CT" >/dev/null 2>&1 || echo "CLEANUP: container $CT not removed" >&2
  elif [ -n "$CT" ]; then
    [ -n "$MADE_TRG" ] && { sq "IF EXISTS (SELECT 1 FROM sys.server_triggers WHERE name = '$SRVTRG') DROP TRIGGER [$SRVTRG] ON ALL SERVER;" >/dev/null 2>&1 || echo "CLEANUP: server trigger $SRVTRG not dropped" >&2; }
    [ -n "$MADE_DB" ] && { dropdb "$D1"; dropdb "$D2"; dropdb "${FX}_1"; dropdb "${FX}_2"; }
    [ -n "$MADE_L" ] && { sq "IF SUSER_ID('$L1') IS NOT NULL DROP LOGIN [$L1];" >/dev/null 2>&1 || echo "CLEANUP: login $L1 not dropped" >&2; }
  fi
  [ -n "$MADE_REPO" ] && { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; }
  rm -rf "$WORK" || true
  exit $rc
}
trap cleanup EXIT; trap 'exit 143' TERM; trap 'exit 130' INT
trap 'erc=$?; [ "$BASH_SUBSHELL" -eq 0 ] && echo "STOPPED: line $LINENO: ${BASH_COMMAND:0:200} (exit $erc)" >&2' ERR

echo "--- the binary"
BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then BIN=$WORK/pgvigil; (cd "$ROOT" && CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil) || fail "the build"; fi

echo "--- the SQL Server"
if [ -n "$CT" ]; then
  ADDR=${PGVIGIL_MSSQL_ADDR:-localhost:1433}; : "${MSSQL_SA_PASSWORD:?the sa password of the sandbox}"
else
  CT=pgv-fs-mssql-$SUF; MSSQL_SA_PASSWORD=$(pw); export MSSQL_SA_PASSWORD
  MPORT=$(freeport 22433 22499) || fail "no free port for the SQL Server container"; ADDR=127.0.0.1:$MPORT
  MADE_CT=1
  docker run -d --name "$CT" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -p "127.0.0.1:$MPORT:1433" "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || fail "docker run"
fi
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
sq "SELECT 1" >/dev/null 2>&1 || fail "the SQL Server in $CT does not answer"
echo "  $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(40)) + ' ' + CAST(SERVERPROPERTY('Edition') AS varchar(80))")"

echo "--- S0. a batch the server refuses comes back with its message"
if S0=$(sq "CREATE FUNCTION dbo.fs_never () RETURNS int AS BEGIN RETURN 1; END" 2>&1 >/dev/null); then fail "S0: a batch the server refuses returned 0 through sq"; fi
grep -q 'Msg 111' <<<"$S0" || fail "S0: sq did not say the server's error (it said: ${S0:0:200})"
echo "ok   S0: $(tr '\n' ' ' <<<"$S0" | cut -c1-230)"

adm() { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

# the monitoring login: the server's views and every definition, and a user in the first database alone (no CONNECT
# ANY DATABASE): the second database is one it cannot enter
printf "CREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\n" "$L1" "$P1" | sqs >/dev/null; MADE_L=1
sq "GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1];" >/dev/null
export MS_MON="sqlserver://$L1:$P1@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
{ echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_MON\n' "$N"; } > "$CFG"
MADE_DB=1   # before the batch: a half-made database is still this run's to drop (the drops are guarded)
for d in "$D1" "$D2"; do
  sq "CREATE DATABASE [$d]; ALTER DATABASE [$d] SET RECOVERY SIMPLE; ALTER DATABASE [$d] SET COMPATIBILITY_LEVEL = 160;" >/dev/null
  sq "CREATE TABLE dbo.fs_n (id int PRIMARY KEY); INSERT dbo.fs_n (id) SELECT TOP (20) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns;" "$d" >/dev/null
done
sq "CREATE USER [$L1] FOR LOGIN [$L1];" "$D1" >/dev/null
sqs >/dev/null <<SQL
USE [$D1];
GO
CREATE FUNCTION dbo.f_off (@a int) RETURNS int WITH INLINE = OFF AS BEGIN RETURN @a + 1; END;
GO
CREATE FUNCTION dbo.f_now (@a int) RETURNS int AS BEGIN RETURN @a + DATEPART(second, GETDATE()); END;
GO
CREATE FUNCTION dbo.f_inl (@a int) RETURNS int AS BEGIN RETURN @a + 1; END;
GO
CREATE FUNCTION dbo.f_plain (@a int) RETURNS int AS BEGIN RETURN @a + 2; END;
GO
CREATE FUNCTION dbo.f_tvf (@a int) RETURNS @t TABLE (v int) AS BEGIN INSERT @t VALUES (@a); RETURN; END;
GO
CREATE FUNCTION dbo.f_itvf (@a int) RETURNS TABLE AS RETURN (SELECT @a AS v);
GO
CREATE TABLE dbo.fs_t (id int IDENTITY PRIMARY KEY, v int);
GO
CREATE TRIGGER dbo.fs_t_ai ON dbo.fs_t AFTER INSERT AS BEGIN SET NOCOUNT ON; DECLARE @c int = (SELECT COUNT(*) FROM inserted); END;
GO
CREATE TRIGGER fs_ddl ON DATABASE FOR CREATE_TABLE AS BEGIN SET NOCOUNT ON; DECLARE @c int = (SELECT COUNT(*) FROM sys.objects); END;
GO
USE [$D2];
GO
CREATE FUNCTION dbo.f_d2 (@a int) RETURNS int WITH INLINE = OFF AS BEGIN RETURN @a + 3; END;
GO
SQL
SRV=
if [ -n "$MADE_CT" ]; then
  MADE_TRG=1
  sqs >/dev/null <<SQL
USE master;
GO
CREATE TRIGGER [$SRVTRG] ON ALL SERVER FOR CREATE_DATABASE AS BEGIN SET NOCOUNT ON; DECLARE @c int = (SELECT COUNT(*) FROM sys.databases); END;
GO
SQL
  SRV=1
fi
DB1=$(sq "SELECT DB_ID('$D1')"); DB2=$(sq "SELECT DB_ID('$D2')")
oid() { sq "SELECT OBJECT_ID('$1')" "$2"; }
"$BIN" migrate -config "$CFG" >/dev/null || fail "migrate"
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$N" > "$OUT" 2>&1 || { cat "$OUT" >&2; return 1; }; cat "$OUT"; }
win() { echo "from=$(date -u -d '-6 hours' +%FT%TZ)&to=$(date -u -d '+1 minute' +%FT%TZ)"; }
objs() { jq -c --arg p "$2" '.[$p] as $t | [$t.rows[] | [$t.columns, .] | transpose | map({(.[0]): .[1]}) | add]' "$1"; }
# FV / TV: sa's read of one object in the function or the trigger view (0 when it is not listed)
FV() { sq "SELECT CAST(ISNULL(SUM(execution_count), 0) AS varchar(20)) FROM sys.dm_exec_function_stats WHERE database_id = $1 AND object_id = $2"; }
TV() { sq "SELECT CAST(ISNULL(SUM(execution_count), 0) AS varchar(20)) FROM sys.dm_exec_trigger_stats WHERE object_id = $1"; }
# ST <kind> <database id> <object id>: the newest stored interval's executions, 'none' without one
ST() { q "select coalesce((select executions::text from pgvigil.mssql_func_sample where instance_id=$iid and kind='$1' and database_id=$2 and object_id=$3 order by snapshot_at desc limit 1), 'none')"; }

echo "--- the first read, then the workload"
collect mssql_funcstats | sed 's/^/  /' | cut -c1-300
iid=$(q "select instance_id from pgvigil.instances where name='$N'")
declare -A OID=([f_off]=$(oid dbo.f_off "$D1") [f_now]=$(oid dbo.f_now "$D1") [f_inl]=$(oid dbo.f_inl "$D1") [f_plain]=$(oid dbo.f_plain "$D1")
  [f_tvf]=$(oid dbo.f_tvf "$D1") [f_itvf]=$(oid dbo.f_itvf "$D1") [f_d2]=$(oid dbo.f_d2 "$D2") [fs_t_ai]=$(oid dbo.fs_t_ai "$D1")
  [fs_ddl]=$(sq "SELECT object_id FROM sys.triggers WHERE name = 'fs_ddl' AND parent_class = 0" "$D1"))
[ -n "$SRV" ] && OID[srv]=$(sq "SELECT object_id FROM sys.server_triggers WHERE name = '$SRVTRG'")
declare -A B
for f in f_off f_now f_inl f_plain f_tvf f_itvf; do B[$f]=$(FV "$DB1" "${OID[$f]}"); done
B[f_d2]=$(FV "$DB2" "${OID[f_d2]}"); B[fs_t_ai]=$(TV "${OID[fs_t_ai]}"); B[fs_ddl]=$(TV "${OID[fs_ddl]}")
[ -n "$SRV" ] && B[srv]=$(TV "${OID[srv]}")
sq "DECLARE @s bigint;
    SELECT @s = SUM(dbo.f_off(id)) FROM dbo.fs_n WHERE id <= 7;
    SELECT @s = COUNT(dbo.f_now(id)) FROM dbo.fs_n WHERE id <= 5;
    SELECT @s = SUM(dbo.f_inl(id)) FROM dbo.fs_n WHERE id <= 4 OPTION (USE HINT('DISABLE_TSQL_SCALAR_UDF_INLINING'));
    SELECT @s = SUM(dbo.f_plain(id)) FROM dbo.fs_n WHERE id <= 6;
    SELECT @s = SUM(x.v) FROM dbo.fs_n t CROSS APPLY dbo.f_tvf(t.id) x WHERE t.id <= 3;
    SELECT @s = SUM(x.v) FROM dbo.fs_n t CROSS APPLY dbo.f_itvf(t.id) x WHERE t.id <= 3;
    INSERT dbo.fs_t (v) VALUES (1); INSERT dbo.fs_t (v) VALUES (2); INSERT dbo.fs_t (v) VALUES (3);
    CREATE TABLE dbo.fs_b1 (id int); CREATE TABLE dbo.fs_b2 (id int);" "$D1" >/dev/null
sq "DECLARE @s bigint; SELECT @s = SUM(dbo.f_d2(id)) FROM dbo.fs_n WHERE id <= 2;" "$D2" >/dev/null
if [ -n "$SRV" ]; then for i in 1 2; do sq "CREATE DATABASE [${FX}_$i];" >/dev/null; dropdb "${FX}_$i"; done; fi
declare -A A
for f in f_off f_now f_inl f_plain f_tvf f_itvf; do A[$f]=$(FV "$DB1" "${OID[$f]}"); done
A[f_d2]=$(FV "$DB2" "${OID[f_d2]}"); A[fs_t_ai]=$(TV "${OID[fs_t_ai]}"); A[fs_ddl]=$(TV "${OID[fs_ddl]}")
[ -n "$SRV" ] && A[srv]=$(TV "${OID[srv]}")
sleep 2
collect mssql_funcstats | sed 's/^/  /' | cut -c1-300
echo "  the collection's state: $(q "select status || '|' || coalesce(note, '') from pgvigil.collection_dates where instance_id=$iid and collection='mssql_funcstats'" | cut -c1-300)"
[ "$(q "select status from pgvigil.collection_dates where instance_id=$iid and collection='mssql_funcstats'")" != error ] || fail "the collection's run is 'error'"

echo "--- FS1. the functions against sa's read"
fs1() {  # fs1 <name> <want executions>
  local f=$1 want=$2 rise st
  rise=$(( ${A[$f]} - ${B[$f]} )); st=$(ST function "$DB1" "${OID[$f]}")
  echo "  $f: sa's rise $rise, stored $st"
  [ "$rise" = "$want" ] && [ "$st" = "$want" ] || fail "FS1: $f - sa's rise $rise, stored $st, want $want"
}
fs1 f_off 7; fs1 f_now 5; fs1 f_inl 4
for f in f_plain f_tvf f_itvf; do
  st=$(q "select count(*) from pgvigil.mssql_func_sample where instance_id=$iid and object_id=${OID[$f]} and database_id=$DB1")
  echo "  $f: sa's read ${A[$f]} (not listed), stored rows $st"
  [ "${A[$f]}" = 0 ] && [ "$st" = 0 ] || fail "FS1: $f is listed by the view (${A[$f]}) or stored ($st rows): an inlined or table-valued function"
done
[ "$(q "select count(*) from pgvigil.mssql_func_sample where instance_id=$iid and kind='function' and (spills is not null or min_spills is not null or max_spills is not null)")" = 0 ] || fail "FS1: a function row carries spills"
curl_parts() { curl -fs "$U/mssql/procs?instance=$iid&$(win)&part=$1" > "$WORK/$1.json" || fail "the API's $1 part"; objs "$WORK/$1.json" "$1"; }

PORT=$(freeport 18440 18480) || fail "no free port for the UI"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" -no-login > "$WORK/serve.log" 2>&1 & SRV_PID=$!
U=http://127.0.0.1:$PORT/api
for _ in $(seq 1 40); do curl -fs "$U/health" >/dev/null 2>&1 && break; sleep 0.25; done
FN=$(curl_parts functions)
echo "  the API's functions: $(jq -r 'map(.object_name + "=" + (.inline_mark // "NULL") + "|" + (.executions|tostring)) | join(" ")' <<<"$FN")"
[ "$(jq -r --arg d "$DB1" '[.[] | select((.database_id | tostring) == $d) | .object_name] | join(" ")' <<<"$FN" | tr ' ' '\n' | sort | tr '\n' ' ')" = "f_inl f_now f_off " ] || fail "FS1: the functions part's names in $D1"
[ "$(jq -r '.[0] | has("spills") or has("min_spills") or has("max_spills")' <<<"$FN")" = false ] || fail "FS1: the functions part has a spills column"
[ "$(jq -r '[.[].cpu_ms | tonumber] | . == (sort | reverse)' <<<"$FN")" = true ] || fail "FS1: the functions part is not the busiest CPU first"
echo "FS1: OK"

echo "--- FS2. the triggers against sa's read"
fs2() {  # fs2 <label> <database id> <want executions> <want name> <want scope>
  local k=$1 db=$2 want=$3 name=$4 scope=$5 rise st row
  rise=$(( ${A[$k]} - ${B[$k]} )); st=$(ST trigger "$db" "${OID[$k]}")
  row=$(q "select coalesce(object_name, 'NULL') || '|' || coalesce(trigger_scope, 'NULL') || '|' || coalesce(database_name, 'NULL') from pgvigil.mssql_func_sample where instance_id=$iid and kind='trigger' and object_id=${OID[$k]} order by snapshot_at desc limit 1")
  echo "  $k: sa's rise $rise, stored $st, name|scope|database $row"
  [ "$rise" = "$want" ] && [ "$st" = "$want" ] || fail "FS2: $k - sa's rise $rise, stored $st, want $want"
  [ "${row%|*}" = "$name|$scope" ] || fail "FS2: $k stored as '$row', want '$name|$scope'"
}
fs2 fs_t_ai "$DB1" 3 fs_t_ai NULL
fs2 fs_ddl "$DB1" 2 fs_ddl database
if [ -n "$SRV" ]; then
  SDB=$(q "select database_id from pgvigil.mssql_func_sample where instance_id=$iid and kind='trigger' and object_id=${OID[srv]} order by snapshot_at desc limit 1")
  echo "  the server trigger's database id: $SDB"
  fs2 srv "${SDB:-1}" 2 "$SRVTRG" server
else
  echo "  the server DDL trigger: NOT RUN (a shared sandbox: no server trigger is made on it)"
fi
TR=$(curl_parts triggers)
echo "  the API's triggers: $(jq -r 'map(.object_name + "|" + (.trigger_scope // "NULL") + "|" + (.executions|tostring) + "|" + (.spills // "NULL" | tostring)) | join(" ")' <<<"$TR")"
[ "$(jq -r '[.[] | select(.object_name == "fs_t_ai" or .object_name == "fs_ddl")] | length' <<<"$TR")" = 2 ] || fail "FS2: the triggers part lacks fs_t_ai or fs_ddl"
[ "$(jq -r '.[0] | has("spills") and has("trigger_scope")' <<<"$TR")" = true ] || fail "FS2: the triggers part lacks spills or trigger_scope"
echo "FS2: OK"

echo "--- FS3. the marks against sa's sys.sql_modules"
sq "SELECT o.name + '|' + CAST(m.is_inlineable AS varchar(1)) + '|' + CAST(m.inline_type AS varchar(1)) FROM sys.sql_modules m JOIN sys.objects o ON o.object_id = m.object_id WHERE o.name IN ('f_off', 'f_now', 'f_inl') ORDER BY o.name" "$D1" | sed 's/^/  sa: /'
mark() { jq -r --arg o "$1" '[.[] | select((.object_id | tostring) == $o) | .inline_mark // "NULL"] | first // "no row"' <<<"$FN"; }
for pair in "f_now:not inlineable" "f_off:inlining off" "f_inl:"; do
  f=${pair%%:*}; want=${pair#*:}; got=$(mark "${OID[$f]}")
  echo "  $f: '$got'"
  [ "$got" = "$want" ] || fail "FS3: $f's mark is '$got', want '$want'"
done
got=$(mark "${OID[f_d2]}"); rise=$(( ${A[f_d2]} - ${B[f_d2]} )); st=$(ST function "$DB2" "${OID[f_d2]}")
echo "  f_d2 in $D2 (the login has no user there): '$got', sa's rise $rise, stored $st"
[ "$got" = "not read" ] && [ "$rise" = 2 ] && [ "$st" = 2 ] || fail "FS3: f_d2 - mark '$got' (want 'not read'), rise $rise, stored $st (want 2)"
NOTE=$(q "select status || '|' || coalesce(note, '') from pgvigil.collection_dates where instance_id=$iid and collection='mssql_funcstats'")
echo "  the run: $(cut -c1-260 <<<"$NOTE")"
[ "${NOTE%%|*}" = partial ] && grep -q "$D2" <<<"$NOTE" || fail "FS3: the run is not 'partial' with a note naming $D2"
echo "FS3: OK"

if [ -n "${PGVIGIL_PAGE_CHECK:-}" ]; then
  echo "--- FS4. the page in a browser"
  for t in chromium node npm; do command -v $t >/dev/null || fail "FS4: $t is not on this machine"; done
  grep -q 'run without inlining' "$ROOT/internal/web/dist/app.js" || fail "FS4: internal/web/dist/app.js is not built from this tree (npm run build in web/, before this proof builds its binary)"
  (cd "$WORK" && npm install --silent --no-audit --no-fund --no-package-lock axe-core@4.14.0 >/dev/null 2>&1) || fail "FS4: npm install axe-core"
  CDP=$(freeport 19440 19480) || fail "FS4: no free port for the browser"
  chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 & CHR_PID=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
  curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "FS4: chromium's CDP port never answered"
  node "$ROOT/scripts/func-stats-page.mjs" "$CDP" "http://127.0.0.1:$PORT/" "$WORK/node_modules/axe-core/axe.min.js" "$iid" "${SRV:+server}" > "$WORK/page.txt" 2>&1 || { sed 's/^/  /' "$WORK/page.txt" | cut -c1-600; fail "FS4: the page check"; }
  sed 's/^/  /' "$WORK/page.txt" | cut -c1-300
  kill "$CHR_PID" 2>/dev/null || true; CHR_PID=
  [ "$(tail -1 "$WORK/page.txt")" = "func-stats page: OK" ] || fail "FS4: the page check's last line is '$(tail -1 "$WORK/page.txt")'"
  echo "FS4: OK"
else
  echo "FS4: NOT RUN (PGVIGIL_PAGE_CHECK is not set: the page was not opened in a browser)"
fi
echo "PROOF OK"
