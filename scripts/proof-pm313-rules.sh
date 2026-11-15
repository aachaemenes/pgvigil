#!/usr/bin/env bash
# Proof of task 405 (B11): PerformanceMonitor 3.13.0's moved rules in pgvigil (0156) against a SQL Server container
# and rows built for the edges a container cannot reach.
# Needs: docker (mcr.microsoft.com/mssql/server images), go, psql, python3, and:
#   ADMIN_DSN       a superuser connection to a PostgreSQL sandbox in keyword form (default 'host=127.0.0.1 port=5432
#                   user=postgres dbname=postgres'); the proof makes its own repository database and drops it.
#   PGVIGIL_IMAGE   the SQL Server image (default 2022-latest).
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment. Only the
# collection a step names runs (pgvigil collect -once).
#
# Expected (written before the first run; red on f8e89d2 at R7a: no compiled_plans column there):
#  A. the container, a database pgvctr, a monitor login with VIEW SERVER STATE; migrate ok; mssql_memory runs.
#  R7. plan cache bloat (Fixed 10, PlanCacheBloatRule.cs):
#     R7a on a built instance ctrsyn's plan cache rows (mssql_plancache_type, one read each): a whole cache of 80 MB
#        reads NORMAL 'Plan cache is too small to judge: ...'; 600 MB with 99 MB of single-use compiled plans at 60 %
#        NORMAL 'Single-use compiled plans take 99 MB of the 600 MB plan cache ... under the 100 MB bloat floor'
#        (red on f8e89d2: CRITICAL); 100 MB at 60 % CRITICAL with the advice 'Optimize for ad hoc workloads is the
#        low-risk first step ...'; 35 % HIGH, 25 % MEDIUM, 20 % NORMAL 'Plan cache composition is healthy'; single-use
#        Compiled Plan Stub rows count as compiled and 300 MB of single-use Parse Tree and Extended Proc rows do not
#        (single_use_pct and compiled_plans over Compiled Plan and its stubs only).
#     R7b live: 'optimize for ad hoc workloads' on, 400 distinct ad hoc batches run once each, mssql_memory: the
#        newest read holds Compiled Plan Stub rows and the summary's compiled_plans counts them (400 or more single-use
#        compiled plans); the memory findings' plan cache sentence, when a level is reached, names 'compiled plans'.
# NOT PROVEN HERE: SQL Server 2016, Managed Instance, a Windows host.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMAGE=${PGVIGIL_IMAGE:-2022-latest}
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
LBL=pgvigil-proof=pm313
PGDB=pgv_pm313_$SUF; MON=pgv_pmon_$SUF; SQL=pgv-pm313-$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d)
SA_PW=$(pw); MON_PW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\nMSSQL_PID=Developer\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  docker ps -aq --filter "label=$LBL-$SUF" | xargs -r docker rm -f -v >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
for t in docker go psql python3; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout "${3:-180}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
sqb() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout "${3:-180}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
sqok() { local out; out=$(sqb "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
col() { for c in "$@"; do timeout 180 "$TMPD/pgvigil" collect -config "$CFG" -instance pmbox -once "$c" > "$TMPD/col-$c.out" 2>&1 \
  || { cat "$TMPD/col-$c.out" >&2; fail "collect $c"; }; done; }

echo "== A. the container, the repository =="
docker run -d --name "$SQL" --label "$LBL-$SUF" --memory 6g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "mcr.microsoft.com/mssql/server:$IMAGE" >/dev/null
r=; for _ in $(seq 1 150); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" master 15 2>/dev/null || true); [[ "$r" == 1 ]] && break; sleep 2; done
[[ "$r" == 1 ]] || { docker logs --tail 20 "$SQL" >&2 2>&1 || true; fail "the $IMAGE container did not come up in 300 s"; }
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://'); [[ "$PORT_SQL" =~ ^[0-9]+$ ]] || fail "the host port [$PORT_SQL]"
sqok "the database" "CREATE DATABASE pgvctr; ALTER DATABASE pgvctr SET RECOVERY SIMPLE;"
sqok "the table" "CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, v int NOT NULL DEFAULT 0);
  INSERT dbo.t (id) SELECT TOP (2000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) FROM sys.all_objects a CROSS JOIN sys.all_objects b;" pgvctr
sqok "the monitor login" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF;
  GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON];"
export PGV_PM_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
go build -o "$TMPD/pgvigil" ./cmd/pgvigil
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="${ADMIN_DSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
CFG=$TMPD/m.yaml
printf 'repository:\n  dsn: "%s"\ninstances:\n  - name: pmbox\n    engine: sqlserver\n    dsn: env:PGV_PM_MON\n' "$PGDSN" > "$CFG"
"$TMPD/pgvigil" migrate -config "$CFG" > "$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "A: migrate"; }
col mssql_instance mssql_memory
SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'pmbox'")
[[ "$SB" =~ ^[0-9]+$ ]] || fail "A: no instance pmbox [$SB]"
SY=$(pq "INSERT INTO pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
         VALUES ('ctrsyn', 'sqlserver', '{}', now(), now(), false, 'sqlserver') RETURNING instance_id" | head -1)
[[ "$SY" =~ ^[0-9]+$ ]] || fail "A: the built instance [$SY]"
ok "A: the $IMAGE container, migrate, mssql_memory read; a built instance ctrsyn ($SY) for the edges"

echo "== R7. plan cache bloat (Fixed 10) =="
pq "SELECT pgvigil.ensure_month_partition('mssql_plancache_type', now())" >/dev/null
# pc <minutes ago> <rows: cache_type,object_type,plans,size_mb,single_use_plans,single_use_mb ...>: one read of ctrsyn
pc() { local at="now() - interval '$1 minutes'" v= r; shift
  for r in "$@"; do IFS=, read -r ct ot n mb su sumb <<<"$r"
    v+="${v:+, }($SY, $at, '$ct', '$ot', $n, $((mb * 1024)), $su, $((sumb * 1024)), $((n - su)), $(((mb - sumb) * 1024)), 2)"; done
  pq "INSERT INTO pgvigil.mssql_plancache_type (instance_id, snapshot_at, cache_type, object_type, plans, size_kb, single_use_plans,
        single_use_kb, multi_use_plans, multi_use_kb, avg_use_count) VALUES $v" >/dev/null; }
# sm <from minutes ago> <to minutes ago>: the summary of that window as level|pct|compiled_plans|single_use_plans|text
sm() { pq "SELECT bloat_level || '|' || single_use_pct || '|' || compiled_plans || '|' || single_use_plans || '|' || recommendation
  FROM pgvigil.mssql_plancache_summary_between($SY, now() - interval '$1 minutes', now() - interval '$2 minutes')"; }
pc 59 "Compiled Plan,Adhoc,1000,80,600,40"
pc 58 "Compiled Plan,Adhoc,1000,600,600,99"
pc 57 "Compiled Plan,Adhoc,1000,600,600,100"
pc 56 "Compiled Plan,Adhoc,1000,600,350,150"
pc 55 "Compiled Plan,Adhoc,1000,600,250,150"
pc 54 "Compiled Plan,Adhoc,1000,600,200,150"
pc 53 "Compiled Plan,Prepared,400,300,0,0" "Compiled Plan Stub,Adhoc,600,120,600,120" "Parse Tree,View,2000,300,2000,300" "Extended Proc,Proc,500,10,500,10"
S1=$(sm 60 58.5); S2=$(sm 58.5 57.5); S3=$(sm 57.5 56.5); S4=$(sm 56.5 55.5); S5=$(sm 55.5 54.5); S6=$(sm 54.5 53.5); S7=$(sm 53.5 52.5)
for s in "$S1" "$S2" "$S3" "$S4" "$S5" "$S6" "$S7"; do echo "   $s"; done
[[ "$S1" == "NORMAL|60.0|1000|600|Plan cache is too small to judge: 1,000 plans using 80 MB, with 40 MB in single-use compiled plans (the floor is 100 MB)" ]] \
  || fail "R7a: an 80 MB cache [$S1]"
[[ "$S2" == "NORMAL|60.0|1000|600|Single-use compiled plans take 99 MB of the 600 MB plan cache (1,000 plans), under the 100 MB bloat floor, so no action is needed" ]] \
  || fail "R7a: 99 MB of single-use compiled plans at 60 % [$S2] (want NORMAL under the floor)"
[[ "$S3" == "CRITICAL|60.0|1000|600|Optimize for ad hoc workloads is the low-risk first step"* ]] || fail "R7a: 100 MB at 60 % [$S3] (want CRITICAL, the advice in its new order)"
[[ "$S4" == HIGH\|35.0\|* && "$S5" == MEDIUM\|25.0\|* && "$S6" == "NORMAL|20.0|1000|200|Plan cache composition is healthy" ]] || fail "R7a: the bands [$S4] [$S5] [$S6]"
[[ "$S7" == "CRITICAL|60.0|1000|600|"* ]] || fail "R7a: stubs count and Parse Tree / Extended Proc do not [$S7] (want CRITICAL|60.0|1000|600: 600 single-use of 1,000 compiled)"
ok "R7a: too small, under the floor, CRITICAL / HIGH / MEDIUM / NORMAL at 60 / 35 / 25 / 20 %, stubs counted, parse trees and extended procedures not"
sqok "optimize for ad hoc workloads on" "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'optimize for ad hoc workloads', 1; RECONFIGURE;"
sq "$(for i in $(seq 1 400); do echo "SELECT COUNT(*) FROM dbo.t WHERE v >= 0 AND id <> $((RANDOM * 1000 + i));"; echo GO; done)" pgvctr >/dev/null
col mssql_memory
LV=$(pq "SELECT coalesce(sum(single_use_plans), 0) FROM pgvigil.mssql_plancache_type WHERE instance_id = $SB AND cache_type = 'Compiled Plan Stub'
  AND snapshot_at = (SELECT max(snapshot_at) FROM pgvigil.mssql_plancache_type WHERE instance_id = $SB)")
LS=$(pq "SELECT compiled_plans || '|' || single_use_plans || '|' || bloat_level FROM pgvigil.mssql_plancache_summary_between($SB, now() - interval '5 minutes', now())")
echo "   live: $LV single-use stubs in the newest read; the summary compiled_plans|single_use_plans|level = $LS"
(( LV >= 400 )) || fail "R7b: $LV single-use Compiled Plan Stub plans read (want 400 or more)"
(( $(cut -d'|' -f2 <<<"$LS") >= LV && $(cut -d'|' -f1 <<<"$LS") >= LV )) || fail "R7b: the summary does not count the stubs [$LS]"
FT=$(pq "SELECT coalesce(string_agg(detail, ' / '), '') FROM pgvigil.mssql_memory_findings_between($SB, now() - interval '5 minutes', now()) WHERE check_name LIKE 'plan cache bloat%'")
[[ -z "$FT" || "$FT" == *"compiled plans are used once"* ]] || fail "R7b: the plan cache finding's sentence [$FT]"
ok "R7b: with optimize for ad hoc workloads on, $LV single-use stubs read live and counted as compiled plans by the summary ($LS)"

echo "PROOF OK: pm313 rules (A R7)"
