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
#  R9. parallelism advice (Fixed 24, F10): R9a on ctrsyn's built rows (16 CPUs on one NUMA node; MAXDOP 0 and cost
#     threshold 5 in force 2 h to 1 h ago, 8 and 50 since; cost threshold 50 alone 3 h to 2 h ago): mssql_advised_maxdop
#     8 ('16 logical processors on one NUMA node: up to 8'), 16 with 32 CPUs over 2 nodes; the CXPACKET advice 90 min
#     ago 'This server's MAXDOP is 0 and cost threshold for parallelism is 5 (advised MAXDOP 8: ...). Bring them to
#     guidance: raise cost threshold for parallelism to 50, cap MAXDOP at 8 (...)', now 'Both are within topology
#     guidance', 150 min ago 'check the other setting by hand', 5 h ago none (the static text stays); the THREADPOOL
#     advice now 'Resolve the dominant cause ... Both are within topology guidance, so if it is parallelism the driver
#     is the volume of concurrent parallel queries'. R9b live: mssql_activity and mssql_checks read; the advisor equals
#     dbatools' rule over the container's own cpu_count and numa_node_count read by hand, and the advice now names the
#     container's MAXDOP and cost threshold (5: 'raise cost threshold for parallelism to 50'). Red on f8e89d2: no
#     mssql_advised_maxdop.
#  R6. max server memory (Fixed 8, F13): R6a on ctrsyn's built rows (mssql_instance's RAM, mssql_config's value in
#     use): 65,536 MB RAM unlimited = warning '... set max server memory to ~58,982 MB (leaving 6,554 MB for the OS)';
#     64,000 MB = review '... is 98% of physical RAM ... reducing to ~58,982 MB'; 16,000 MB = review '... is only 24%
#     ... raising to ~58,982 MB'; 50,000 MB = ok 'looks reasonable'; 4,096 MB RAM unlimited = warning ~2,048 MB (the
#     reserve capped at half); engine edition 8 (Managed Instance) = no row. R6b live: the container's RAM as
#     sys.dm_os_sys_info reads it (printed beside free -m in the container), max server memory at the default, then
#     at 97 % and 60 % of that RAM (mssql_instance, mssql_checks read each time): warning, review, ok, each suggestion
#     = RAM minus the reserve. Red on f8e89d2: no mssql_memory_suggestion.
#  R5. protection ages (Changed 46, F1, F2): on pmbox (tags env:pma, app:pmb) after mssql_backups, msdb's ages read
#     168 'the default' / 60 'the default'; tag rows env:pma 48 h and app:pmb 24 h: 24 'tag app:pmb (row n)' (the
#     strictest); env:pma at 0: still 24 (0 only when every tag says 0); a database row on msdb 1 h / 15 min: 1 and 15
#     'database row n', model keeps 24; pgvigil.yaml's mssql_thresholds full_backup_hours 100: model 100 'pgvigil.yaml',
#     msdb still 1 (the database row wins); msdb's row at 0: full_status 'not judged'; the door refuses a negative age,
#     a database row on an instance it does not know, and an instance scope (the yaml's); every row ended: model 100.
#     Red on f8e89d2: no import_mssql_protection_override.
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
# config [<yaml lines under the instance>]: the configuration, pmbox tagged env:pma and app:pmb
config() { printf 'repository:\n  dsn: "%s"\ninstances:\n  - name: pmbox\n    engine: sqlserver\n    dsn: env:PGV_PM_MON\n    tags: [env:pma, app:pmb]\n%s' "$PGDSN" "${1:-}" > "$CFG"; }
config
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

echo "== R9. parallelism advice (Fixed 24) =="
pq "INSERT INTO pgvigil.mssql_cpu_info (instance_id, snapshot_at, info) VALUES ($SY, now(), '{\"cpu_count\": 16, \"numa_node_count\": 1}')" >/dev/null
ch() { pq "INSERT INTO pgvigil.mssql_config_history (instance_id, name, valid_from, valid_to, value, value_in_use)
  VALUES ($SY, '$1', now() - interval '$2 minutes', $([[ -n "$3" ]] && echo "now() - interval '$3 minutes'" || echo NULL), $4, $4)" >/dev/null; }
ch 'cost threshold for parallelism' 180 120 50
ch 'max degree of parallelism' 120 60 0; ch 'cost threshold for parallelism' 120 60 5
ch 'max degree of parallelism' 60 '' 8; ch 'cost threshold for parallelism' 60 '' 50
adv() { pq "SELECT coalesce(pgvigil.mssql_parallelism_advice($SY, now() - interval '$1 minutes', '$2'), 'NULL')"; }
AM=$(pq "SELECT maxdop || '|' || basis FROM pgvigil.mssql_advised_maxdop($SY)")
C90=$(adv 90 cx); C0=$(adv 0 cx); C150=$(adv 150 cx); C300=$(adv 300 cx); T0=$(adv 0 threadpool)
for x in "$AM" "$C90" "$C0" "$C150" "$C300" "$T0"; do echo "   $x"; done
[[ "$AM" == "8|16 logical processors on one NUMA node: up to 8" ]] || fail "R9a: the advisor [$AM]"
[[ "$C90" == "This server's MAXDOP is 0 and cost threshold for parallelism is 5 (advised MAXDOP 8: 16 logical processors on one NUMA node: up to 8). Bring them to guidance: raise cost threshold for parallelism to 50, cap MAXDOP at 8 (16 logical processors on one NUMA node: up to 8). Most OLTP"* ]] \
  || fail "R9a: 90 minutes ago [$C90]"
[[ "$C0" == *"Both are within topology guidance, so the parallelism is coming from the plans themselves"* ]] || fail "R9a: now [$C0]"
[[ "$C150" == "This server's MAXDOP is not readable this window and cost threshold for parallelism is 50"*"check the other setting by hand"* ]] || fail "R9a: 150 minutes ago [$C150]"
[[ "$C300" == NULL ]] || fail "R9a: 5 hours ago, nothing read [$C300]"
[[ "$T0" == "Resolve the dominant cause: parallelism or blocking. This server's MAXDOP is 8"*"so if it is parallelism the driver is the volume of concurrent parallel queries"* ]] || fail "R9a: THREADPOOL now [$T0]"
pq "UPDATE pgvigil.mssql_cpu_info SET info = '{\"cpu_count\": 32, \"numa_node_count\": 2}' WHERE instance_id = $SY" >/dev/null
AM2=$(pq "SELECT maxdop FROM pgvigil.mssql_advised_maxdop($SY)"); [[ "$AM2" == 16 ]] || fail "R9a: 32 CPUs over 2 nodes [$AM2] (want 16)"
ok "R9a: the advisor 8 and 16; the four CXPACKET cases (off guidance, within, one by hand, none read) and THREADPOOL's within"
col mssql_activity mssql_checks
HW=$(sq "SELECT CAST(cpu_count AS varchar(10)) + '|' + CAST(numa_node_count AS varchar(10)) FROM sys.dm_os_sys_info")
LM=$(pq "SELECT maxdop FROM pgvigil.mssql_advised_maxdop($SB)")
WANT=$(python3 -c "import sys; c, n = map(int, sys.argv[1].split('|')); print(min(c, 8) if n <= 1 else min(max(c // n, 1), 16))" "$HW")
CL=$(pq "SELECT coalesce(pgvigil.mssql_parallelism_advice($SB, now(), 'cx'), 'NULL')")
MD=$(sq "SELECT CAST(value_in_use AS varchar(10)) FROM sys.configurations WHERE name = 'max degree of parallelism'")
echo "   live: sys_info cpus|nodes $HW, advised $LM (dbatools' rule $WANT); MAXDOP $MD; advice: $CL"
[[ "$LM" == "$WANT" ]] || fail "R9b: the advisor $LM, dbatools' rule over the container's own facts $WANT"
[[ "$CL" == "This server's MAXDOP is $MD and cost threshold for parallelism is 5 "*"raise cost threshold for parallelism to 50"* ]] || fail "R9b: the live advice [$CL]"
ok "R9b: the advisor equals dbatools' rule over the container's cpu_count and numa_node_count ($LM); the advice names its MAXDOP $MD and cost threshold 5"

echo "== R6. max server memory (Fixed 8) =="
pq "INSERT INTO pgvigil.mssql_instance (instance_id, snapshot_at, physical_memory_mb, engine_edition) VALUES ($SY, now(), 65536, 3)
    ON CONFLICT (instance_id) DO UPDATE SET physical_memory_mb = EXCLUDED.physical_memory_mb, engine_edition = EXCLUDED.engine_edition" >/dev/null
msm() { pq "INSERT INTO pgvigil.mssql_config (instance_id, name, value, value_in_use, snapshot_at, is_present) VALUES ($SY, 'max server memory (MB)', $1, $1, now(), true)
    ON CONFLICT (instance_id, name) DO UPDATE SET value = EXCLUDED.value, value_in_use = EXCLUDED.value_in_use, snapshot_at = EXCLUDED.snapshot_at" >/dev/null
  pq "SELECT status || '|' || suggested_mb || '|' || message FROM pgvigil.mssql_memory_suggestion($SY)"; }
M1=$(msm 2147483647); M2=$(msm 64000); M3=$(msm 16000); M4=$(msm 50000)
pq "UPDATE pgvigil.mssql_instance SET physical_memory_mb = 4096 WHERE instance_id = $SY" >/dev/null; M5=$(msm 2147483647)
pq "UPDATE pgvigil.mssql_instance SET physical_memory_mb = 65536, engine_edition = 8 WHERE instance_id = $SY" >/dev/null
M6=$(pq "SELECT count(*) FROM pgvigil.mssql_memory_suggestion($SY)")
for x in "$M1" "$M2" "$M3" "$M4" "$M5" "MI rows: $M6"; do echo "   $x"; done
[[ "$M1" == "warning|58982|Max server memory is at the default (unlimited). SQL Server will consume all available RAM, starving the OS and other processes. With 65,536 MB physical RAM, set max server memory to ~58,982 MB (leaving 6,554 MB for the OS)." ]] || fail "R6a: unlimited [$M1]"
[[ "$M2" == "review|58982|Max server memory (64,000 MB) is 98% of physical RAM (65,536 MB). Consider reducing to ~58,982 MB to leave room for the OS." ]] || fail "R6a: 98 % [$M2]"
[[ "$M3" == "review|58982|Max server memory (16,000 MB) is only 24% of physical RAM (65,536 MB)."* ]] || fail "R6a: 24 % [$M3]"
[[ "$M4" == "ok|50000|Max server memory (50,000 MB) looks reasonable for 65,536 MB physical RAM." ]] || fail "R6a: 76 % [$M4]"
[[ "$M5" == "warning|2048|"*"set max server memory to ~2,048 MB (leaving 2,048 MB for the OS)." ]] || fail "R6a: 4 GB of RAM [$M5]"
[[ "$M6" == 0 ]] || fail "R6a: a Managed Instance has a row ($M6)"
ok "R6a: unlimited warning, 98 % and 24 % review, 76 % ok, the reserve capped at half on 4 GB, no row on Managed Instance"
RAM=$(sq "SELECT CAST(physical_memory_kb / 1024 AS varchar(20)) FROM sys.dm_os_sys_info"); FREE=$(docker exec "$SQL" free -m | awk '/^Mem:/{print $2}')
echo "   the container: sys.dm_os_sys_info physical memory $RAM MB; free -m total $FREE MB"
live() { [[ "$1" == default ]] && v=2147483647 || v=$(( RAM * $1 / 100 ))
  sqok "max server memory $v" "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'max server memory (MB)', $v; RECONFIGURE;"
  col mssql_instance mssql_checks; pq "SELECT status || '|' || suggested_mb || '|' || ram_mb FROM pgvigil.mssql_memory_suggestion($SB)"; }
WANTS=$(python3 -c "import sys; r = int(sys.argv[1]); print(int(r - min(max(4096, r * 0.10), r / 2)))" "$RAM")
L1=$(live default); L2=$(live 97); L3=$(live 60)
echo "   live: default [$L1], 97 % [$L2], 60 % [$L3]; the suggestion by hand $WANTS"
[[ "$L1" == "warning|$WANTS|$RAM" && "$L2" == "review|$WANTS|$RAM" && "$L3" == "ok|$(( RAM * 60 / 100 ))|$RAM" ]] || fail "R6b: live [$L1] [$L2] [$L3] (want warning, review at $WANTS, ok)"
sqok "max server memory back to the default" "EXEC sp_configure 'max server memory (MB)', 2147483647; RECONFIGURE;"
ok "R6b: on the container's $RAM MB: unlimited warning, 97 % review, 60 % ok, the suggestion $WANTS MB"

echo "== R5. protection ages (Changed 46) =="
col mssql_backups
door() { pq "SELECT pgvigil.import_mssql_protection_override(now(), '$1'::jsonb)"; }
jb() { pq "SELECT full_backup_hours::float8 || '|' || full_hours_from || '|' || log_backup_minutes::float8 || '|' || log_minutes_from || '|' || full_status
  FROM pgvigil.mssql_backup_judged WHERE instance_id = $SB AND database_name = '$1'"; }
J0=$(jb msdb); [[ "$J0" == "168|the default|60|the default|"* ]] || fail "R5: msdb before any row [$J0]"
door '{"op":"add","ui_user":"proof405","scope":"tag","tag":"env:pma","full_backup_hours":48}' | grep -q '"done"' || fail "R5: the env:pma row"
door '{"op":"add","ui_user":"proof405","scope":"tag","tag":"app:pmb","full_backup_hours":24}' | grep -q '"done"' || fail "R5: the app:pmb row"
J1=$(jb msdb); [[ "$J1" == "24|tag app:pmb (row "*")|60|the default|"* ]] || fail "R5: two tag rows [$J1] (want 24 from app:pmb)"
door '{"op":"add","ui_user":"proof405","scope":"tag","tag":"env:pma","full_backup_hours":0}' | grep -q 'replaced' || fail "R5: env:pma at 0"
J2=$(jb msdb); [[ "$J2" == "24|tag app:pmb (row "* ]] || fail "R5: a tag at 0 beside one at 24 [$J2] (want 24)"
door '{"op":"add","ui_user":"proof405","scope":"database","instance_name":"pmbox","database_name":"msdb","full_backup_hours":1,"log_backup_minutes":15}' | grep -q '"done"' || fail "R5: the msdb row"
J3=$(jb msdb); J3M=$(jb model)
[[ "$J3" == "1|database row "*"|15|database row "* && "$J3M" == "24|tag app:pmb"* ]] || fail "R5: the database row [$J3], model [$J3M]"
config "    mssql_thresholds: {full_backup_hours: 100}
"; col mssql_backups
J4=$(jb msdb); J4M=$(jb model)
[[ "$J4" == "1|database row "* && "$J4M" == "100|pgvigil.yaml|"* ]] || fail "R5: the yaml at 100: msdb [$J4] (want the database row), model [$J4M] (want 100 pgvigil.yaml)"
door '{"op":"add","ui_user":"proof405","scope":"database","instance_name":"pmbox","database_name":"msdb","full_backup_hours":0}' | grep -q 'replaced' || fail "R5: msdb at 0"
J5=$(jb msdb); [[ "$J5" == "0|database row "*"|not judged" ]] || fail "R5: msdb at 0 [$J5] (want not judged)"
R1=$(door '{"op":"add","ui_user":"proof405","scope":"tag","tag":"env:pma","full_backup_hours":-1}')
R2=$(door '{"op":"add","ui_user":"proof405","scope":"database","instance_name":"nosuch","database_name":"x","full_backup_hours":1}')
R3=$(door '{"op":"add","ui_user":"proof405","scope":"instance","instance_name":"pmbox","full_backup_hours":1}')
grep -q '"refused"' <<<"$R1" && grep -q '"refused"' <<<"$R2" && grep -q 'mssql_thresholds' <<<"$R3" || fail "R5: the refusals [$R1] [$R2] [$R3]"
for o in $(pq "SELECT override_id FROM pgvigil.mssql_protection_overrides WHERE ended_at IS NULL"); do
  door "{\"op\":\"end\",\"ui_user\":\"proof405\",\"override_id\":\"$o\"}" | grep -q '"done"' || fail "R5: ending row $o"; done
J6=$(jb model); [[ "$J6" == "100|pgvigil.yaml|"* ]] || fail "R5: every row ended [$J6]"
NL=$(pq "SELECT count(*) FROM pgvigil.mssql_protection_override_log"); [[ "$NL" -ge 10 ]] || fail "R5: $NL log rows"
config; col mssql_backups
ok "R5: the default, the strictest tag, a tag at 0 beside 24, a database row over the tags and the yaml, the yaml over the tags, 0 = not judged; three refusals; $NL attempts logged"

echo "PROOF OK: pm313 rules (A R7 R9 R6 R5)"
