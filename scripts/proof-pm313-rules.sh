#!/usr/bin/env bash
# Proof of task 405 (B11): PerformanceMonitor 3.13.0's moved rules in pgvigil (0156) against a SQL Server container
# and rows built for the edges a container cannot reach.
# Needs: docker (mcr.microsoft.com/mssql/server images), go, psql, python3, curl, node, npm, chromium, ss, and:
#   ADMIN_DSN       a superuser connection to a PostgreSQL sandbox in keyword form (default 'host=127.0.0.1 port=5432
#                   user=postgres dbname=postgres'); the proof makes its own repository database and drops it.
#   PGVIGIL_IMAGE   the SQL Server image (default 2022-latest).
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment. Only the
# collection a step names runs (pgvigil collect -once).
#
# Expected (written before the first run; red on f8e89d2 at R7a with PGVIGIL_WIRING=0: no compiled_plans column there;
# with the default PGVIGIL_WIRING=1 f8e89d2 goes red at A's migrate, the patch's 0190 view calling mssql_runnable_queue):
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
#        compiled plans). The memory findings' plan cache sentence on ctrsyn (405 review part B, S1: live it never
#        reached a level): with 'optimize for ad hoc workloads' at 0 in mssql_config, the 100 MB at 60 % read is an
#        info 'plan cache bloat with optimize for ad hoc workloads off' whose words start '60.0 % of the 1000 compiled
#        plans are used once'. S4: the live RESOURCE_MONITOR records mssql_memory stored carry memory_node_id 0 and
#        ring_ms on every row (the wiring's memory.go; none stored = 'NOT PROVEN live' printed).
#  R9. parallelism advice (Fixed 24, F10): R9a on ctrsyn's built rows (16 CPUs on one NUMA node; MAXDOP 0 and cost
#     threshold 5 in force 2 h to 1 h ago, 8 and 50 since; cost threshold 50 alone 3 h to 2 h ago): mssql_advised_maxdop
#     8 ('16 logical processors on one NUMA node: up to 8'), 16 with 32 CPUs over 2 nodes; the CXPACKET advice 90 min
#     ago 'This server's MAXDOP is 0 and cost threshold for parallelism is 5 (advised MAXDOP 8: ...). Bring them to
#     guidance: raise cost threshold for parallelism to 50, cap MAXDOP at 8 (...)', now 'Both are within topology
#     guidance', 150 min ago 'check the other setting by hand', 5 h ago none (the static text stays); the THREADPOOL
#     advice now 'Resolve the dominant cause ... Both are within topology guidance, so if it is parallelism the driver
#     is the volume of concurrent parallel queries'. R9c (405 review part B, S2) the wait findings' wiring: ctrsyn's
#     wait reads with CXPACKET and THREADPOOL over 10 % of the read, one 90 minutes ago and one 5 hours ago:
#     mssql_wait_findings_between's Parallelism detail ends with mssql_parallelism_advice at the read's time (90 min)
#     and with the static 'Usually a cost threshold ...' text (5 h, nothing read); THREADPOOL's detail the same with
#     the 'threadpool' advice and its static text. R9b live: mssql_activity and mssql_checks read; the advisor equals
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
#     168 'the default' / 60 'the default'; tag rows app:pmb 24 h, then env:pma 48 h (the stricter first, so the
#     newest is not the strictest: 405 review part B, S3): 24 'tag app:pmb (row n)' (the strictest); env:pma at 0: still 24 (0 only when every tag says 0); a database row on msdb 1 h / 15 min: 1 and 15
#     'database row n', model keeps 24; pgvigil.yaml's mssql_thresholds full_backup_hours 100: model 100 'pgvigil.yaml',
#     msdb still 1 (the database row wins); msdb's row at 0: full_status 'not judged'; the door refuses a negative age,
#     a database row on an instance it does not know, and an instance scope (the yaml's); every row ended: model 100.
#     From 405 review part A (finding 5; red on 234aacc: 'MODEL' stored as typed and never applied, 'nosuchdb' done): a
#     database row named 'MODEL' is stored under the server's own name 'model' and gives model's log 30 'database row n';
#     a database the newest backup read does not list ('nosuchdb') is refused with 'no database'.
#     R5b (with the wiring patch) the API under pgvigil serve: GET /api/mssql/protection?instance=pmbox's id answers
#     overrides, log and limits with writable true; a POST without a session 401, without the X-Pgvigil header 403;
#     a tag row added 200, a negative age refused 409, the row ended 200; a -no-login serve reads with writable false and
#     its reason, and refuses a POST 403; the log holds done=2 refused=1 by the proof's user from 127.0.0.1.
#     Red on f8e89d2: no import_mssql_protection_override.
#  R2. High CPU (Changed 12, Release 5, D2 a, F12): R2a after migrate one fleet rule named 'SQL Server: High CPU' on cpu.sql_pct,
#     above 79.999 / 94.999 for 4 minutes, enabled false, created_by 'pgvigil', client '0156 seed', one 'seed' log row;
#     0156 run again by hand adds nothing, nor after the rule is ended. R2b on a built active instance cpusyn's CPU
#     records one minute apart, an instance rule at the seed's thresholds and minutes: four records at 96 % read
#     'pending', the fifth 'critical'; four at 85 % and a fifth at 85 % 'warning'; a record at 79 % after them 'ok'.
#     NOT PROVEN live: a CPU loop per scheduler on the shared box (the design pass's finding 18).
#  R1. write latency (Changed 2, F6, F7, D1 a): on a built active instance iosyn's file reads of the last hour: tempdb data
#     files at 12 ms (300 writes) warning, 32 ms critical, 9.9 ms and 249 writes at 20 ms none; a user data file at 200 ms
#     over 5,000 writes raises nothing (red on f8e89d2: 'slow data file writes' on it) and the tempdb sentences give its
#     average; log files at 12 ms over 300 writes warning, 35 ms critical, 19 ms over 1,000 writes warning (red on
#     f8e89d2: under 20 ms). The retirement: an open alert of 'slow data file writes' on the user file and one on tempdb;
#     0156 run again: the user file's closed with no recovery (alert_due with a recovery channel at clear delay 0 lists
#     no row for it) and a 'cleared' alert_log row 'rule retired', tempdb's open;
#     a third run adds no row. NOT PROVEN live: the box's disk cannot be slowed to an exact latency.
#  R3. Runnable Queue's reading (Changed 13, D3 b): on built scheduler reads of three instances, judged at a fixed time
#     T: five reads a minute apart in the last 5 minutes at 10 per scheduler read 10 over 'the 5 reads of the last 5
#     minutes'; reads 9, 7 and 6 minutes before T (none in 5 minutes) read their average over 'the newest 3 reads'
#     (within 10 minutes); reads 11, 9 and 7 minutes before read nothing (no evaluation); reads every 5 minutes, the
#     newest 5.5 minutes before T, read the newest 3 (the window 4 x 5 minutes = 20). The arm of darling_alert_findings
#     that reads it is WIRING: with the wiring patch, reads 9, 7 and 6 minutes ago at 10 per scheduler give a
#     'runnable queue per scheduler' warning 'over the newest 3 reads' (red on 0118's arm: under 3 reads in 5 minutes,
#     nothing). Red on f8e89d2: no mssql_runnable_queue.
#  R8. memory nodes (Fixed 20, F4): three payloads through import_mssql_memory for ctrsyn: read 1 with node 0's records 100
#     and 101 and node 1's 50 and 51 (copies: the same times and notification) and node 1's own 52 at another time stores 3
#     records (red on f8e89d2: 2, node 1's own lost under node 0's higher ids), the watermark {0: 101, 1: 52}; read 2 with
#     101 and 52 again, node 0's 102 and its copy 53 on node 1, and node 1's 49 stores 1 more (4); read 3 from a collector
#     without the node column, record 103, stores it (5); mssql_memory_rmon_hourly counts each event once (5 at
#     indicator 2, not 7). The live record's NodeId (0 on the container) is R7b's S4 row; NOT PROVEN live on two nodes
#     (a container has one).
#     R8b (with the wiring patch) the Memory page's records under pgvigil serve: GET /api/mssql/memory?part=rmon for
#     ctrsyn over the hours of R8's records answers 200 with a memory_node_id column, the 5 records per node
#     '0:3 1:1 none:1' (node 1's own 52; 103 read before the node column). Red without the patch: no such column. The
#     page's Node column itself (shown with 2+ nodes) waits for a page shot.
#     R8c (405 review part A, finding 3; red on 234aacc: 3 7 9, the sandbox run of the import's two statements
#     read 3 7 9 there and 3 4 5 on the fold) a server start of its own on ctrsyn: read A from a collector without
#     nodes, records 200-202 -> 3; read B from the new collector, the same ids on node 0 at times 0.3 ms later with
#     their ring_ms, and a new 203 -> 4; read C node 1's copy of 203 (id 70, the same ring_ms, its time 0.3 ms later)
#     and node 1's own 71 -> 5; the watermark {"0": 203, "1": 71}.
#  R4. the PostgreSQL poison wait (Changed 19, D4 changed): on built PostgreSQL instances' wait_sample rows judged at a
#     fixed time: IPC:BufferIO 700 s in the newest 10 minutes and 650 s in the 10 before = warning (1.17 and 1.08), its
#     query naming 'queryid 42: SELECT pgv_poison' from statement_text; IPC:BtreePage 6,100 s in the newest alone =
#     critical (10.17); 700 s then 300 s = nothing; an instance with no wait_sample row = one info row 'not judged: needs
#     pg_wait_sampling'; with the wiring patch an active instance's IPC:BtreePage at 6,100 s in the last 10 minutes
#     is a critical 'poison wait' in darling_alert_findings, and the 'not judged' info row is there too (405 review part A,
#     finding 4: the words reach the Findings page and a channel set to info; red on 234aacc: the info row left out).
#     NOT PROVEN live: no PostgreSQL image on
#     the box carries pg_wait_sampling.
#  R10. the readers (on S4: nothing a collection stores goes without a page; red on 3a36717: no
#     poison part, no suggestion part, nothing on the pages), with the wiring patch under pgvigil serve: R10a GET
#     /api/waits at R4's time gives a poison part - pgsyn1's warning on IPC:BufferIO with 'queryid 42: SELECT pgv_poison
#     FROM t' (statement_text's text, as the collector's text policy and credential mask stored it), pgsyn4's one info
#     row 'not judged: needs pg_wait_sampling ...'; R10b GET /api/mssql/memory?part=suggestion on pmbox at max server
#     memory's default gives 0156's mssql_memory_suggestion, the same number the Server options check states in its
#     words ('PerformanceMonitor's suggestion: about N MB', checks.go, read from mssql_server_option); R10c in headless
#     Chromium: the Waits page's 'Poison waits' holds a grid with pgsyn1's event and statement, pgsyn4's says 'not
#     judged: needs pg_wait_sampling' with no grid, the SQL Server Memory page's 'PerformanceMonitor's suggestion'
#     row starts with the API's number. NOT PROVEN here: the credential mask itself (task 415's, on the collector's
#     side: R4's statement is written straight into statement_text).
# NOT PROVEN HERE: SQL Server 2016, Managed Instance, a Windows host.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMAGE=${PGVIGIL_IMAGE:-2022-latest}
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
LBL=pgvigil-proof=pm313
PGDB=pgv_pm313_$SUF; MON=pgv_pmon_$SUF; SQL=pgv-pm313-$SUF; UIUSER=proofpm$SUF; SRVPID=; SRV2PID=; CHRPID=
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d)
SA_PW=$(pw); MON_PW=$(pw); UIPW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\nMSSQL_PID=Developer\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  [[ -n "$SRV2PID" ]] && kill "$SRV2PID" 2>/dev/null || true
  if [[ -n "$CHRPID" ]]; then kill -- "-$CHRPID" 2>/dev/null || kill "$CHRPID" 2>/dev/null || true; fi
  docker ps -aq --filter "label=$LBL-$SUF" | xargs -r docker rm -f -v >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  command rm -rf "$TMPD"
}
trap cleanup EXIT
for t in docker go psql python3 curl node npm chromium setsid ss; do command -v "$t" >/dev/null || fail "needs $t"; done
node -e 'process.exit(typeof WebSocket === "function" && typeof fetch === "function" ? 0 : 1)' || fail "node $(node --version) has no global WebSocket: R10c needs node 22 or later"
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
# PGVIGIL_WIRING 1 (default): this task's lines in other owners' files (scripts/proof-pm313-rules-wiring.patch) are
# applied to the run's own copy of the tree when it lacks them; 0 = the copy as it is. The web bundle and the binary
# are built in that copy (R10's pages need the patched bundle); the tree the proof runs from is never changed.
GSRC=$TMPD/src; mkdir -p "$GSRC"
tar -C . --exclude=./web/node_modules --exclude=./.lab --exclude=./.git -cf - . | tar -C "$GSRC" -xf -
if [[ "${PGVIGIL_WIRING:-1}" == 1 ]] && ! grep -q 'memory_node_id' "$GSRC/internal/mssql/memory.go"; then
  (cd "$GSRC" && { git apply scripts/proof-pm313-rules-wiring.patch 2>"$TMPD/apply.err" || patch -p1 --forward < scripts/proof-pm313-rules-wiring.patch >>"$TMPD/apply.err" 2>&1; }) \
    || fail "405's wiring patch: $(cat "$TMPD/apply.err")"
  echo "405's wiring applied to the run's copy"
fi
(cd "$GSRC/web" && npm ci --no-audit --no-fund >"$TMPD/web.log" 2>&1 && npm run build >>"$TMPD/web.log" 2>&1) || { tail -20 "$TMPD/web.log" >&2; fail "the web build"; }
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
(cd "$GSRC" && go build -o "$TMPD/pgvigil" ./cmd/pgvigil) || fail "the build"
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
# S1: the sentence on ctrsyn's 100 MB at 60 % read (S3's window), 'optimize for ad hoc workloads' at 0
pq "INSERT INTO pgvigil.mssql_config (instance_id, name, value, value_in_use, snapshot_at, is_present) VALUES ($SY, 'optimize for ad hoc workloads', 0, 0, now(), true)
    ON CONFLICT (instance_id, name) DO UPDATE SET value = 0, value_in_use = 0, snapshot_at = EXCLUDED.snapshot_at, is_present = true" >/dev/null
FS=$(pq "SELECT coalesce(string_agg(severity || '|' || check_name || '|' || detail, ' / '), '') FROM pgvigil.mssql_memory_findings_between($SY, now() - interval '57.5 minutes', now() - interval '56.5 minutes') WHERE check_name LIKE 'plan cache bloat%'")
echo "   ctrsyn's plan cache sentence: $FS"
[[ "$FS" == "info|plan cache bloat with optimize for ad hoc workloads off|60.0 % of the 1000 compiled plans are used once ("* && "$FS" != *" / "* ]] \
  || fail "R7b: the plan cache sentence on a built read [$FS] (want one info row starting '60.0 % of the 1000 compiled plans are used once')"
# S4: the live records' node and ring time (the wiring's memory.go)
RN=$(pq "SELECT count(*) || '|' || count(memory_node_id) || '|' || count(ring_ms) || '|' || coalesce(string_agg(DISTINCT memory_node_id::text, ','), '') FROM pgvigil.mssql_memory_rmon WHERE instance_id = $SB")
echo "   live RESOURCE_MONITOR records stored|with a node|with ring_ms|nodes: $RN"
if [[ "${RN%%|*}" == 0 ]]; then echo "NOT PROVEN live: no RESOURCE_MONITOR record on the container, so memory.go's node and ring_ms reads were not exercised"
else IFS='|' read -r rn1 rn2 rn3 rn4 <<<"$RN"; [[ "$rn1" == "$rn2" && "$rn1" == "$rn3" && "$rn4" == 0 ]] || fail "R7b: the live records' node and ring_ms [$RN] (want every row with node 0 and ring_ms)"; fi
ok "R7b: with optimize for ad hoc workloads on, $LV single-use stubs read live and counted as compiled plans by the summary ($LS); the sentence names the compiled plans; the live records' node and ring time [$RN]"

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
# R9c: the advice in the wait findings (16 CPUs again for C90's words); a read 90 minutes and one 5 hours ago
pq "UPDATE pgvigil.mssql_cpu_info SET info = '{\"cpu_count\": 16, \"numa_node_count\": 1}' WHERE instance_id = $SY" >/dev/null
pq "SELECT pgvigil.ensure_month_partition('mssql_wait_sample', now() - interval '5 hours'), pgvigil.ensure_month_partition('mssql_wait_sample', now())" >/dev/null
for ago in 90 300; do pq "INSERT INTO pgvigil.mssql_wait_sample (instance_id, snapshot_at, wait_type, category, is_benign, waiting_tasks, wait_ms, signal_ms, interval_secs)
  VALUES ($SY, now() - interval '$ago minutes', 'CXPACKET', 'Parallelism', false, 100, 30000, 0, 60), ($SY, now() - interval '$ago minutes', 'THREADPOOL', 'CPU', false, 100, 12000, 0, 60)" >/dev/null; done
# wfa <minutes ago> <wait type> <advice kind> <static text>: t when the detail's text ends with the advice at the read's time
# (or the static text when none) - right before the source suffix ' (sp_PerfCheck check 6001, priority ...)' the
# function appends to every detail (box run 405green1: the tail compared without it read false) - and which
wfa() { pq "SELECT coalesce(string_agg(CASE WHEN pgvigil.mssql_parallelism_advice($SY, f.at, '$3') IS NOT NULL
      THEN 'advice|' || (strpos(f.detail, pgvigil.mssql_parallelism_advice($SY, f.at, '$3') || ' (sp_PerfCheck check 6001, ') > 0)
      ELSE 'static|' || (strpos(f.detail, '$4' || ' (sp_PerfCheck check 6001, ') > 0) END, ','), 'none')
  FROM pgvigil.mssql_wait_findings_between($SY, now() - interval '$1 minutes' - interval '1 minute', now() - interval '$1 minutes' + interval '1 minute') f WHERE f.object LIKE '$2 (%'"; }
CXS='Usually a cost threshold for parallelism / MAXDOP tuning issue rather than a problem in itself.'
TPS='Scheduling pressure. Review parallelism settings and plan quality; THREADPOOL specifically means worker-thread exhaustion.'
W90=$(wfa 90 CXPACKET cx "$CXS"); W300=$(wfa 300 CXPACKET cx "$CXS"); P90=$(wfa 90 THREADPOOL threadpool "$TPS"); P300=$(wfa 300 THREADPOOL threadpool "$TPS")
echo "   the wait findings: CXPACKET 90 min $W90, 5 h $W300; THREADPOOL 90 min $P90, 5 h $P300"
[[ "$W90|$W300|$P90|$P300" == "advice|true|static|true|advice|true|static|true" ]] || fail "R9c: the advice in the wait findings [$W90|$W300|$P90|$P300]"
pq "UPDATE pgvigil.mssql_cpu_info SET info = '{\"cpu_count\": 32, \"numa_node_count\": 2}' WHERE instance_id = $SY" >/dev/null
ok "R9c: the wait findings' Parallelism and THREADPOOL details carry the advice at the read's time, the static text where nothing was read"
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
door '{"op":"add","ui_user":"proof405","scope":"tag","tag":"app:pmb","full_backup_hours":24}' | grep -q '"done"' || fail "R5: the app:pmb row"
door '{"op":"add","ui_user":"proof405","scope":"tag","tag":"env:pma","full_backup_hours":48}' | grep -q '"done"' || fail "R5: the env:pma row"
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
grep -q '"refused"' <<<"$R1" && grep -q '"refused"' <<<"$R2" && grep -q '"refused"' <<<"$R3" && grep -q 'mssql_thresholds' <<<"$R3" || fail "R5: the refusals [$R1] [$R2] [$R3]"
# the database row's name as the server spells it (405 review part A, finding 5)
door '{"op":"add","ui_user":"proof405","scope":"database","instance_name":"pmbox","database_name":"MODEL","log_backup_minutes":30}' | grep -q '"done"' || fail "R5: the MODEL row"
DBN=$(pq "SELECT database_name FROM pgvigil.mssql_protection_overrides WHERE ended_at IS NULL AND scope = 'database' AND lower(database_name) = 'model'")
J7=$(jb model); echo "   the row typed MODEL: stored as [$DBN]; model now $J7"
[[ "$DBN" == model && "$J7" == "100|pgvigil.yaml|30|database row "* ]] || fail "R5: a database row typed MODEL [$DBN] [$J7] (want model, 30 from the database row)"
R4=$(door '{"op":"add","ui_user":"proof405","scope":"database","instance_name":"pmbox","database_name":"nosuchdb","full_backup_hours":1}')
grep -q '"refused"' <<<"$R4" && grep -q 'no database' <<<"$R4" || fail "R5: a database the backup read does not list [$R4]"
for o in $(pq "SELECT override_id FROM pgvigil.mssql_protection_overrides WHERE ended_at IS NULL"); do
  door "{\"op\":\"end\",\"ui_user\":\"proof405\",\"override_id\":\"$o\"}" | grep -q '"done"' || fail "R5: ending row $o"; done
J6=$(jb model); [[ "$J6" == "100|pgvigil.yaml|"* ]] || fail "R5: every row ended [$J6]"
NL=$(pq "SELECT count(*) FROM pgvigil.mssql_protection_override_log"); [[ "$NL" -ge 10 ]] || fail "R5: $NL log rows"
config; col mssql_backups
ok "R5: the default, the strictest tag, a tag at 0 beside 24, a database row over the tags and the yaml, the yaml over the tags, 0 = not judged; a database row under the server's own name; four refusals; $NL attempts logged"
freeport() { local lo=$1 hi=$2 p used
  used=$(ss -Htan) || fail "ss -Htan failed: the ports in use cannot be read"
  used=$(awk '{n = split($4, a, ":"); print a[n]}' <<<"$used" | sort -u)
  for _ in $(seq 1 50); do p=$((lo + RANDOM % (hi - lo + 1))); grep -qx "$p" <<<"$used" || { echo "$p"; return 0; }; done
  fail "no free port in $lo-$hi"; }
PGVIGIL_PASSWORD=$UIPW "$TMPD/pgvigil" user add -config "$CFG" "$UIUSER" > /dev/null 2>&1 || fail "R5b: user add"
serve() { local p; for _ in 1 2 3; do p=$(freeport 29000 32499)
    "$TMPD/pgvigil" serve -config "$CFG" -listen "127.0.0.1:$p" "$@" > "$TMPD/serve-$p.log" 2>&1 & local pid=$!
    for _ in $(seq 1 60); do grep -q "url=http://127.0.0.1:$p/" "$TMPD/serve-$p.log" 2>/dev/null && { echo "$pid $p"; return 0; }; kill -0 $pid 2>/dev/null || break; sleep 0.5; done
    kill $pid 2>/dev/null || true; done; fail "R5b: serve never answered: $(tail -3 "$TMPD"/serve-*.log)"; }
read -r SRVPID SPORT <<<"$(serve)"; read -r SRV2PID SPORT2 <<<"$(serve -no-login)"
[[ -n "$SPORT" && -n "$SPORT2" ]] || fail "R5b: serve never answered: $(tail -3 "$TMPD"/serve-*.log 2>/dev/null)"
U=http://127.0.0.1:$SPORT; U2=http://127.0.0.1:$SPORT2; JAR=$TMPD/jar
code() { curl -s -m 20 -o "$TMPD/body" -w '%{http_code}' "$@"; }
NOW_LOG=$(pq "SELECT count(*) FROM pgvigil.mssql_protection_override_log")
[[ $(code -X POST -H 'X-Pgvigil: 1' -d '{}' "$U/api/mssql/protection") == 401 ]] || fail "R5b: a POST without a session: $(cat "$TMPD/body")"
# the password from a file, never curl's argv (the header's rule; 401 review part 4, finding 9)
printf '{"username":"%s","password":"%s"}' "$UIUSER" "$UIPW" > "$TMPD/login.json"
[[ $(code -c "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login") == 200 ]] || fail "R5b: the UI login: $(cat "$TMPD/body")"
[[ $(code -b "$JAR" -X POST -d '{}' "$U/api/mssql/protection") == 403 ]] || fail "R5b: a POST without the header"
[[ $(code -b "$JAR" "$U/api/mssql/protection?instance=$SB") == 200 ]] || fail "R5b: GET: $(cat "$TMPD/body")"
python3 - "$TMPD/body" <<'PY2' || fail "R5b: GET's parts"
import json, sys
d = json.load(open(sys.argv[1])); miss = [p for p in ('overrides', 'log', 'limits') if not isinstance(d.get(p), dict)]
lim = d.get('limits') or {}; rows = [dict(zip(lim.get('columns', []), r)) for r in lim.get('rows', [])]
print(f"   GET: writable {d.get('writable')}, parts {sorted(k for k in d if isinstance(d[k], dict))}, msdb {[r for r in rows if r.get('database_name') == 'msdb'][:1]}")
sys.exit(1 if miss or d.get('writable') is not True or not any(r.get('database_name') == 'msdb' for r in rows) else 0)
PY2
A1=$(code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{"op":"add","scope":"tag","tag":"env:pma","full_backup_hours":36}' "$U/api/mssql/protection")
OID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("override_id") or "")' "$TMPD/body")
A2=$(code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{"op":"add","scope":"tag","tag":"env:pma","full_backup_hours":-2}' "$U/api/mssql/protection")
A3=$(code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"op\":\"end\",\"override_id\":$OID}" "$U/api/mssql/protection")
[[ "$A1 $A2 $A3" == "200 409 200" ]] || fail "R5b: POST add / refused / end: $A1 $A2 $A3"
[[ $(code "$U2/api/mssql/protection") == 200 ]] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["writable"] is False and "-no-login" in d["reason"] else 1)' "$TMPD/body" \
  || fail "R5b: the -no-login serve's GET: $(cat "$TMPD/body")"
[[ $(code -X POST -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{"op":"add","scope":"tag","tag":"x","full_backup_hours":1}' "$U2/api/mssql/protection") == 403 ]] || fail "R5b: the -no-login serve took a POST"
LOGS=$(pq "SELECT string_agg(outcome || '=' || n, ' ' ORDER BY outcome) FROM (SELECT outcome, count(*) n FROM pgvigil.mssql_protection_override_log WHERE ui_user = '$UIUSER' AND client = '127.0.0.1' GROUP BY 1) x")
[[ "$LOGS" == "done=2 refused=1" && $(pq "SELECT count(*) FROM pgvigil.mssql_protection_override_log") == $((NOW_LOG + 3)) ]] || fail "R5b: the log [$LOGS]"
ok "R5b: the API: GET with limits; POST 401 / 403 / add 200 / refused 409 / end 200; a -no-login serve read only and refusing; done=2 refused=1 logged"

echo "== R2. High CPU (Changed 12) =="
HC=$(pq "SELECT rule_id || '|' || name || '|' || op || '|' || warning || '|' || critical || '|' || for_minutes || '|' || enabled || '|' || scope || '|' || created_by
  FROM pgvigil.alert_rules WHERE metric = 'cpu.sql_pct' AND client = '0156 seed'")
HL=$(pq "SELECT count(*) FROM pgvigil.alert_rule_log WHERE op = 'seed' AND client = '0156 seed'")
echo "   the seed: $HC; log rows $HL"
[[ "$HC" =~ ^[0-9]+\|SQL\ Server:\ High\ CPU\|above\|79\.999\|94\.999\|4\|false\|fleet\|pgvigil$ && "$HL" == 1 ]] || fail "R2a: the seeded rule [$HC], $HL log row(s)"
HID=${HC%%|*}
psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -f internal/repo/sql/0156_pm313_rules.sql >/dev/null || fail "R2a: 0156 run again by hand"
pq "SELECT pgvigil.import_alert_rule(now(), '{\"op\":\"end\",\"ui_user\":\"proof405\",\"rule_id\":\"$HID\"}'::jsonb)" | grep -q '"done"' || fail "R2a: ending the seed"
psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -f internal/repo/sql/0156_pm313_rules.sql >/dev/null || fail "R2a: 0156 again after the end"
[[ $(pq "SELECT count(*) FROM pgvigil.alert_rules WHERE metric = 'cpu.sql_pct' AND client = '0156 seed'") == 1 && \
   $(pq "SELECT count(*) FROM pgvigil.alert_rule_log WHERE op = 'seed' AND client = '0156 seed'") == 1 ]] || fail "R2a: a re-run seeded again"
ok "R2a: seeded off as PerformanceMonitor's numbers; 0156 again, and again after the end, adds nothing"
CS=$(pq "INSERT INTO pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
         VALUES ('cpusyn', 'sqlserver', '{}', now(), now(), true, 'sqlserver') RETURNING instance_id" | head -1)
T0=$(pq "SELECT to_char((date_trunc('minute', now()) - interval '30 minutes') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
pq "SELECT pgvigil.ensure_month_partition('mssql_cpu_sample', '$T0'::timestamptz)" >/dev/null
pq "SELECT pgvigil.import_alert_rule(now(), '{\"op\":\"add\",\"ui_user\":\"proof405\",\"metric\":\"cpu.sql_pct\",\"op_dir\":\"above\",\"scope\":\"instance\",\"instance_name\":\"cpusyn\",\"warning\":79.999,\"critical\":94.999,\"for_minutes\":4}'::jsonb)" | grep -q '"done"' || fail "R2b: the instance rule"
# rec <minute after T0> <pct>: one CPU record of cpusyn; judge <minute>: the rules judged at that record's time
rec() { pq "INSERT INTO pgvigil.mssql_cpu_sample (instance_id, snapshot_at, record_id, sql_pct, other_pct, idle_pct)
  VALUES ($CS, '$T0'::timestamptz + interval '$1 minutes', $1, $2, NULL, NULL)" >/dev/null; }
judge() { pq "SELECT count(*) FROM (SELECT pgvigil.alert_rules_run('$T0'::timestamptz + interval '$1 minutes' + interval '5 seconds')) x" >/dev/null
  pq "SELECT state FROM pgvigil.alert_rule_state WHERE instance_id = $CS AND metric = 'cpu.sql_pct' AND database = ''"; }
for m in 0 1 2 3; do rec $m 96; done; A4=$(judge 3); rec 4 96; A5=$(judge 4)
for m in 10 11 12 13 14; do rec $m 85; done; B5=$(judge 14); rec 15 79; B6=$(judge 15)
echo "   96 %: after 4 records $A4, after 5 $A5; 85 %: after 5 $B5; then 79 %: $B6"
[[ "$A4" == pending && "$A5" == critical && "$B5" == warning && "$B6" == ok ]] || fail "R2b: [$A4 $A5 $B5 $B6] (want pending critical warning ok)"
pq "UPDATE pgvigil.instances SET is_active = false WHERE instance_id = $CS" >/dev/null
ok "R2b: at the seed's numbers four records read pending and the fifth fires (critical at 96 %, warning at 85 %); 79 % clears"

echo "== R1. write latency (Changed 2) =="
IO=$(pq "INSERT INTO pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
         VALUES ('iosyn', 'sqlserver', '{}', now(), now(), true, 'sqlserver') RETURNING instance_id" | head -1)
pq "SELECT pgvigil.ensure_month_partition('mssql_fileio_sample', now() - interval '10 minutes')" >/dev/null
# io <db id> <file id> <db> <file> <ROWS|LOG> <writes> <write stall ms>
io() { pq "INSERT INTO pgvigil.mssql_fileio_sample (instance_id, snapshot_at, database_id, file_id, database_name, file_name, type_desc,
  reads, read_bytes, read_stall_ms, writes, write_bytes, write_stall_ms, interval_secs)
  VALUES ($IO, now() - interval '10 minutes', $1, $2, '$3', '$4', '$5', 0, 0, 0, $6, 0, $7, 60)" >/dev/null; }
io 2 1 tempdb tempdev ROWS 300 3600; io 2 3 tempdb temp2 ROWS 300 9600; io 2 4 tempdb temp3 ROWS 300 2970; io 2 5 tempdb temp4 ROWS 249 4980
io 5 1 userdb ud1 ROWS 5000 1000000; io 5 2 userdb udlog LOG 300 3600; io 6 2 userdb2 log2 LOG 300 10500; io 7 2 userdb3 log3 LOG 1000 19000
CF=$(pq "SELECT string_agg(severity || ' ' || check_name || ' ' || object, '; ' ORDER BY object COLLATE \"C\") FROM pgvigil.mssql_cpu_findings WHERE instance_id = $IO")
PF=$(pq "SELECT string_agg(severity || ' ' || check_name || ' ' || object, '; ' ORDER BY object COLLATE \"C\") FROM pgvigil.mssql_perf_findings WHERE instance_id = $IO")
TD=$(pq "SELECT detail FROM pgvigil.mssql_cpu_findings WHERE instance_id = $IO AND object = 'tempdb: tempdev'")
echo "   data files: $CF"; echo "   log files: $PF"; echo "   tempdev: $TD"
[[ "$CF" == "critical slow data file writes tempdb: temp2; warning slow data file writes tempdb: tempdev" ]] \
  || fail "R1: the data file findings [$CF] (want tempdev warning, temp2 critical, nothing on userdb)"
[[ "$TD" == *"The user databases' data files averaged 200.0 ms per write over 5000 writes"* ]] || fail "R1: the tempdb sentence [$TD]"
[[ "$PF" == "critical slow log writes userdb2: log2; warning slow log writes userdb3: log3; warning slow log writes userdb: udlog" ]] \
  || fail "R1: the log file findings [$PF] (want udlog warning, log2 critical, log3 warning)"
ok "R1: tempdb data files judged at 10 / 30 ms over 250 writes, a user data file never; log files at 10 / 30 ms over 250 writes"
ast() { pq "INSERT INTO pgvigil.alert_state (channel, finding_key, instance_id, instance_name, source, setting, value, severity, first_sent_at, last_sent_at)
  VALUES ('drop', '$1', $IO, 'iosyn', 'mssql_cpu', 'slow data file writes', '$2', 'warning', now() - interval '1 hour', now() - interval '1 hour')" >/dev/null; }
ast proofkey-user 'userdb: ud1'; ast proofkey-tempdb 'tempdb: tempdev'
psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -f internal/repo/sql/0156_pm313_rules.sql >/dev/null || fail "R1: 0156 run again"
RU=$(pq "SELECT (cleared_at IS NOT NULL) || '|' || (recovery_sent_at IS NULL) FROM pgvigil.alert_state WHERE finding_key = 'proofkey-user'")
RT=$(pq "SELECT (cleared_at IS NULL) FROM pgvigil.alert_state WHERE finding_key = 'proofkey-tempdb'")
RL=$(pq "SELECT count(*) FROM pgvigil.alert_log WHERE outcome = 'cleared' AND error LIKE 'rule retired (task 405, D1)%' AND 'proofkey-user' = ANY (keys)")
RD=$(pq "SELECT count(*) FROM pgvigil.alert_due(now(), '[{\"name\":\"drop\",\"recovery\":true,\"clear_after_secs\":0}]'::jsonb) WHERE finding_key = 'proofkey-user'")
psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -f internal/repo/sql/0156_pm313_rules.sql >/dev/null || fail "R1: 0156 a third time"
RL2=$(pq "SELECT count(*) FROM pgvigil.alert_log WHERE outcome = 'cleared' AND error LIKE 'rule retired (task 405, D1)%'")
# RU joins two booleans with ||, which PostgreSQL writes as 'true' / 'false' (psql's own t / f is only for a bare boolean):
# box run 405green2 read [true|true] with every value right
[[ "$RU" == "true|true" && "$RD" == 0 && "$RT" == t && "$RL" == 1 && "$RL2" == 1 ]] || fail "R1: the retirement: user file [$RU] (want cleared, no recovery), alert_due rows for it $RD (want 0), tempdb open [$RT], log rows $RL then $RL2 (want 1, 1)"
pq "UPDATE pgvigil.instances SET is_active = false WHERE instance_id = $IO" >/dev/null
ok "R1: the open alert on a user data file closed as 'rule retired' with no recovery, tempdb's kept; a re-run adds nothing"

echo "== R3. Runnable Queue's reading (Changed 13) =="
TQ=$(pq "SELECT to_char((date_trunc('minute', now()) - interval '2 hours') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
pq "SELECT pgvigil.ensure_month_partition('mssql_sched_sample', '$TQ'::timestamptz - interval '1 hour')" >/dev/null
rq() { pq "INSERT INTO pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
         VALUES ('$1', 'sqlserver', '{}', now(), now(), false, 'sqlserver') RETURNING instance_id" | head -1; }
# sch <instance> <seconds before TQ> <runnable tasks> (4 schedulers)
sch() { pq "INSERT INTO pgvigil.mssql_sched_sample (instance_id, snapshot_at, schedulers, runnable_tasks)
  VALUES ($1, '$TQ'::timestamptz - make_interval(secs => $2), 4, $3)" >/dev/null; }
# 'none' when the function gives no row (no evaluation): the coalesce goes round a scalar subquery (box run 405green3 read
# '' for rqsyn3, the function rightly returning nothing)
rqv() { pq "SELECT coalesce((SELECT round(per_sched, 2)::text || '|' || reads || '|' || window_text FROM pgvigil.mssql_runnable_queue($1, '$TQ'::timestamptz)), 'none')"; }
Q1=$(rq rqsyn1); for t in 0 60 120 180 240; do sch "$Q1" $t 40; done
Q2=$(rq rqsyn2); sch "$Q2" 540 40; sch "$Q2" 420 32; sch "$Q2" 360 48
Q3=$(rq rqsyn3); sch "$Q3" 660 40; sch "$Q3" 540 40; sch "$Q3" 420 40
Q4=$(rq rqsyn4); for t in 1530 1230 930 630 330; do sch "$Q4" $t 36; done
V1=$(rqv "$Q1"); V2=$(rqv "$Q2"); V3=$(rqv "$Q3"); V4=$(rqv "$Q4")
for x in "$V1" "$V2" "$V3" "$V4"; do echo "   $x"; done
[[ "$V1" == "10.00|5|the 5 reads of the last 5 minutes" ]] || fail "R3: five reads in 5 minutes [$V1]"
[[ "$V2" == "10.00|3|the newest 3 reads (fewer than 3 in the last 5 minutes; the 3 within 10 minutes)" ]] || fail "R3: a late collector [$V2]"
[[ "$V3" == none ]] || fail "R3: three reads, the oldest 11 minutes back [$V3] (want no evaluation)"
[[ "$V4" == "9.00|3|the newest 3 reads (fewer than 3 in the last 5 minutes; the 3 within 20 minutes)" ]] || fail "R3: reads every 5 minutes [$V4]"
ok "R3: the 5-minute average, the newest-3 fallback (10 minutes, 20 at a 5-minute spacing), no evaluation past it"
pq "SELECT pgvigil.ensure_month_partition('mssql_sched_sample', now())" >/dev/null
Q5=$(rq rqsyn5); for t in 540 420 360; do pq "INSERT INTO pgvigil.mssql_sched_sample (instance_id, snapshot_at, schedulers, runnable_tasks)
  VALUES ($Q5, now() - make_interval(secs => $t), 4, 40)" >/dev/null; done
RA=$(pq "SELECT coalesce(string_agg(severity || '|' || detail, ' ; '), 'none') FROM pgvigil.darling_alert_findings WHERE instance_id = $Q5 AND setting = 'runnable queue per scheduler'")
echo "   the arm: $RA"
[[ "$RA" == "warning|runnable tasks averaged 10.0 per scheduler over the newest 3 reads"* ]] || fail "R3: darling_alert_findings' runnable arm on a late collector [$RA]"
ok "R3: darling_alert_findings' runnable arm judges a late collector's newest 3 reads"

echo "== R8. memory nodes (Fixed 20) =="
TM=$(pq "SELECT to_char((date_trunc('hour', now()) - interval '3 hours') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
# rmrec <record id> <node or ''> <minutes after TM>: one RING_BUFFER_RESOURCE_MONITOR row of a payload (never a function
# named rm: the cleanup trap's rm would call it; 405 review part B, B2)
rmrec() { local n=; [[ -n "$2" ]] && n=",\"memory_node_id\":$2"
  local at; at=$(pq "SELECT to_char(('$TM'::timestamptz + interval '$3 minutes') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
  [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || echo "FAIL: rmrec $1: the event time [$at]" >&2
  echo "{\"kind\":\"rmon\",\"server_start\":\"2026-11-01T00:00:00\",\"record_id\":$1$n,\"sample_at\":\"$at\",\"notification\":\"RESOURCE_MEMPHYSICAL_LOW\",\"ind_process\":2,\"ind_system\":0}"; }
mem() { local at=$1; shift; local rows; rows=$(IFS=,; echo "$*")
  pq "SELECT pgvigil.import_mssql_memory($SY, '$at'::timestamptz, '[{\"kind\":\"memory\"},$rows]'::jsonb)" >/dev/null; }
nrm() { pq "SELECT count(*) FROM pgvigil.mssql_memory_rmon WHERE instance_id = $SY"; }
mem "$(pq "SELECT now() - interval '20 minutes'")" "$(rmrec 100 0 1)" "$(rmrec 101 0 2)" "$(rmrec 50 1 1)" "$(rmrec 51 1 2)" "$(rmrec 52 1 3)"
N1=$(nrm); WM=$(pq "SELECT rmon_last_by_node::text FROM pgvigil.mssql_memory_reads WHERE instance_id = $SY")
mem "$(pq "SELECT now() - interval '15 minutes'")" "$(rmrec 101 0 2)" "$(rmrec 52 1 3)" "$(rmrec 102 0 4)" "$(rmrec 53 1 4)" "$(rmrec 49 1 0)"
N2=$(nrm)
mem "$(pq "SELECT now() - interval '10 minutes'")" "$(rmrec 103 '' 5)"
N3=$(nrm); HR=$(pq "SELECT sum(sql_medium) FROM pgvigil.mssql_memory_rmon_hourly($SY, '$TM'::timestamptz - interval '1 hour', '$TM'::timestamptz + interval '1 hour')")
echo "   records stored after each read: $N1 $N2 $N3; watermark $WM; events at indicator 2 in the hours: $HR"
[[ "$N1" == 3 && "$WM" == '{"0": 101, "1": 52}' && "$N2" == 4 && "$N3" == 5 && "$HR" == 5 ]] \
  || fail "R8: stored $N1 $N2 $N3 (want 3 4 5), watermark [$WM] (want {0: 101, 1: 52}), hourly $HR (want 5)"
ok "R8: records keyed per node, the copies of one event stored once, the watermark per node, a collector without nodes still read"
# R8b: the Memory page's records through the API (the wiring patch's q_mssql_perf.go line), the window in UTC words
TA=$(pq "SELECT to_char(('$TM'::timestamptz - interval '1 hour') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
TB=$(pq "SELECT to_char(('$TM'::timestamptz + interval '1 hour') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
[[ $(code -b "$JAR" "$U/api/mssql/memory?instance=$SY&part=rmon&from=$TA&to=$TB") == 200 ]] || fail "R8b: GET rmon: $(cat "$TMPD/body")"
NB=$(python3 - "$TMPD/body" <<'PY3'
import json, sys
t = json.load(open(sys.argv[1])).get('rmon') or {}
cols = t.get('columns') or []
rows = [dict(zip(cols, r)) for r in t.get('rows') or []]
c = {}
for r in rows:
    k = 'none' if r.get('memory_node_id') is None else str(r['memory_node_id'])
    c[k] = c.get(k, 0) + 1
print(' '.join(f'{k}:{c[k]}' for k in sorted(c)) if 'memory_node_id' in cols else 'no memory_node_id column')
PY3
)
echo "   the API's records per node: $NB"
[[ "$NB" == "0:3 1:1 none:1" ]] || fail "R8b: /api/mssql/memory's rmon per node [$NB] (want 0:3 1:1 none:1)"
ok "R8b: the Memory page's records carry their node (0:3 1:1 none:1)"
# R8c: the switch from a collector without nodes, and a copy on another node in a later read (405 review part A, finding 3)
S8C=2026-11-03T00:00:00; T8C=$(pq "SELECT date_trunc('hour', now()) - interval '6 hours'")
# rc <record id> <node or ''> <ms after T8C> <ring_ms or ''>: one record, its time to the microsecond
rc() { local n= g=; [[ -n "$2" ]] && n=",\"memory_node_id\":$2"; [[ -n "$4" ]] && g=",\"ring_ms\":$4"
  local at; at=$(pq "SELECT to_char(('$T8C'::timestamptz + $3 * interval '1 millisecond') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')")
  [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$ ]] || echo "FAIL: rc $1: the event time [$at]" >&2
  echo "{\"kind\":\"rmon\",\"server_start\":\"$S8C\",\"record_id\":$1$n$g,\"sample_at\":\"$at\",\"notification\":\"RESOURCE_MEMPHYSICAL_LOW\",\"ind_process\":2,\"ind_system\":0}"; }
n8c() { pq "SELECT count(*) FROM pgvigil.mssql_memory_rmon WHERE instance_id = $SY AND server_start = '$S8C'"; }
mem "$(pq "SELECT now() - interval '9 minutes'")" "$(rc 200 '' 1000 '')" "$(rc 201 '' 2000 '')" "$(rc 202 '' 3000 '')"; C1=$(n8c)
mem "$(pq "SELECT now() - interval '8 minutes'")" "$(rc 200 0 1000.3 5001000)" "$(rc 201 0 2000.3 5002000)" "$(rc 202 0 3000.3 5003000)" "$(rc 203 0 4000.3 5004000)"; C2=$(n8c)
mem "$(pq "SELECT now() - interval '7 minutes'")" "$(rc 70 1 4000.6 5004000)" "$(rc 71 1 5000.6 5005000)"; C3=$(n8c)
WC=$(pq "SELECT rmon_last_by_node::text FROM pgvigil.mssql_memory_reads WHERE instance_id = $SY")
echo "   R8c records of its server start after each read: $C1 $C2 $C3; watermark $WC"
[[ "$C1 $C2 $C3" == "3 4 5" && "$WC" == '{"0": 203, "1": 71}' ]] || fail "R8c: stored $C1 $C2 $C3 (want 3 4 5), watermark [$WC] (want {0: 203, 1: 71})"
ok "R8c: the records stored without a node are not stored again under node 0; a copy on another node in a later read is matched by its ring time"

echo "== R4. the PostgreSQL poison wait (Changed 19) =="
TP=$(pq "SELECT to_char((date_trunc('minute', now()) - interval '1 hour') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
pq "SELECT pgvigil.ensure_month_partition('wait_sample', '$TP'::timestamptz - interval '20 minutes')" >/dev/null
pgi() { pq "INSERT INTO pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
         VALUES ('$1', 'postgres', '{}', now(), now(), false, 'postgres') RETURNING instance_id" | head -1; }
# wsa <instance> <minutes before TP> <event> <queryid> <wait secs>
wsa() { pq "INSERT INTO pgvigil.wait_sample (instance_id, snapshot_at, interval_secs, source, event_type, event, queryid, samples, wait_secs)
  VALUES ($1, '$TP'::timestamptz - interval '$2 minutes', 300, 'pg_wait_sampling', 'IPC', '$3', $4, 1, $5)" >/dev/null; }
pw1=$(pgi pgsyn1); wsa "$pw1" 2 BufferIO 42 400; wsa "$pw1" 7 BufferIO 42 300; wsa "$pw1" 12 BufferIO 42 650
pq "INSERT INTO pgvigil.statement_text (instance_id, queryid, first_seen, last_seen, query) VALUES ($pw1, 42, now(), now(), 'SELECT pgv_poison FROM t')" >/dev/null
pw2=$(pgi pgsyn2); wsa "$pw2" 3 BtreePage 7 6100
pw3=$(pgi pgsyn3); wsa "$pw3" 4 BufferIO 9 700; wsa "$pw3" 14 BufferIO 9 300
pw4=$(pgi pgsyn4)
pf() { pq "SELECT coalesce(string_agg(severity || '|' || object || '|' || coalesce(query, ''), ' ; '), 'none') FROM pgvigil.pg_poison_wait_findings($1, '$TP'::timestamptz)"; }
P1=$(pf "$pw1"); P2=$(pf "$pw2"); P3=$(pf "$pw3"); P4=$(pf "$pw4")
P1D=$(pq "SELECT detail FROM pgvigil.pg_poison_wait_findings($pw1, '$TP'::timestamptz)")
for x in "$P1" "$P2" "$P3" "$P4" "$P1D"; do echo "   $x"; done
[[ "$P1" == "warning|IPC:BufferIO|queryid 42: SELECT pgv_poison FROM t" && "$P1D" == *"averaged 1.17 waiting backends over the last 10 minutes and 1.08 over the 10 before"* ]] || fail "R4: two windows over 1.0 [$P1] [$P1D]"
[[ "$P2" == "critical|IPC:BtreePage|queryid 7: (no text stored)" ]] || fail "R4: 10.17 at once [$P2]"
[[ "$P3" == none ]] || fail "R4: 1.17 then 0.5 [$P3] (want none)"
[[ "$P4" == "info|not judged|" ]] || fail "R4: no wait_sample [$P4] (want the info row)"
ok "R4: warning over two windows at 1.0+, critical at once at 10.0+, nothing on one window, 'not judged: needs pg_wait_sampling' without the samples"
pq "SELECT pgvigil.ensure_month_partition('wait_sample', now())" >/dev/null
pw5=$(pgi pgsyn5); pq "UPDATE pgvigil.instances SET is_active = true WHERE instance_id IN ($pw5, $pw4)" >/dev/null
pq "INSERT INTO pgvigil.wait_sample (instance_id, snapshot_at, interval_secs, source, event_type, event, queryid, samples, wait_secs)
  VALUES ($pw5, now() - interval '2 minutes', 300, 'pg_wait_sampling', 'IPC', 'BtreePage', 7, 1, 6100)" >/dev/null
PA=$(pq "SELECT coalesce(string_agg(instance_id || '|' || severity || '|' || value, ' ; ' ORDER BY instance_id), 'none') FROM pgvigil.darling_alert_findings WHERE setting = 'poison wait' AND instance_id IN ($pw5, $pw4)")
pq "UPDATE pgvigil.instances SET is_active = false WHERE instance_id IN ($pw5, $pw4)" >/dev/null
echo "   the arm: $PA"
PW=("$pw4|info|not judged" "$pw5|critical|IPC:BtreePage"); (( pw4 < pw5 )) && PWANT="${PW[0]} ; ${PW[1]}" || PWANT="${PW[1]} ; ${PW[0]}"
[[ "$PA" == "$PWANT" ]] || fail "R4: darling_alert_findings' poison arm [$PA] (want [$PWANT]: $pw5's critical and $pw4's 'not judged' info row)"
ok "R4: darling_alert_findings' poison arm: the critical and the 'not judged' info row"

echo "== R10. the readers (the lead's 22:4x on S4: nothing a collection stores goes without a page) =="
# R10a the Waits API's poison part at R4's time: pgsyn1's warning with its statement as statement_text holds it (the
# text policy and the credential mask apply before the store), pgsyn4's 'not judged: needs pg_wait_sampling'
pq "UPDATE pgvigil.instances SET is_active = true WHERE instance_id IN ($pw1, $pw4)" >/dev/null
WF=$(pq "SELECT to_char(('$TP'::timestamptz - interval '30 minutes') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
for pi in "$pw1" "$pw4"; do
  [[ $(code "$U2/api/waits?instance=$pi&from=$WF&to=$TP") == 200 ]] || fail "R10a: GET /api/waits for $pi: $(cat "$TMPD/body")"
  cp "$TMPD/body" "$TMPD/waits-$pi.json"; done
python3 - "$TMPD/waits-$pw1.json" "$TMPD/waits-$pw4.json" <<'PY10' || fail "R10a: the Waits API's poison part"
import json, sys
def rows(p):
    t = json.load(open(p)).get('poison') or {}
    return [dict(zip(t.get('columns') or [], r)) for r in t.get('rows') or []]
a, b = rows(sys.argv[1]), rows(sys.argv[2])
print(f"   pgsyn1: {[(r.get('severity'), r.get('object'), r.get('query')) for r in a]}; pgsyn4: {[(r.get('severity'), str(r.get('detail'))[:40]) for r in b]}")
ok = (len(a) == 1 and a[0].get('severity') == 'warning' and a[0].get('object') == 'IPC:BufferIO'
      and a[0].get('query') == 'queryid 42: SELECT pgv_poison FROM t'
      and len(b) == 1 and b[0].get('severity') == 'info' and str(b[0].get('detail')).startswith('not judged: needs pg_wait_sampling'))
sys.exit(0 if ok else 1)
PY10
ok "R10a: GET /api/waits' poison part: pgsyn1's warning with its statement as stored, pgsyn4's 'not judged: needs pg_wait_sampling'"
# R10b the Memory API's suggestion = 0156's function = the number the Server options check states (checks.go's words in
# mssql_server_option), on the container at max server memory's default
col mssql_instance mssql_checks
CN=$(pq "SELECT substring(detail from 'PerformanceMonitor''s suggestion: about ([0-9]+) MB') FROM pgvigil.mssql_server_option
  WHERE instance_id = $SB AND lower(name) = 'max server memory (mb)' ORDER BY snapshot_at DESC LIMIT 1")
FN=$(pq "SELECT suggested_mb FROM pgvigil.mssql_memory_suggestion($SB)")
[[ $(code "$U2/api/mssql/memory?instance=$SB&part=suggestion") == 200 ]] || fail "R10b: GET the suggestion: $(cat "$TMPD/body")"
AN=$(python3 -c 'import json, sys; t = json.load(open(sys.argv[1])).get("suggestion") or {}; r = [dict(zip(t.get("columns") or [], x)) for x in t.get("rows") or []]; print(r[0].get("suggested_mb") if r else "")' "$TMPD/body")
echo "   the suggestion: the Server options check's words $CN MB, 0156's $FN MB, the Memory API's $AN MB"
[[ -n "$CN" && "$CN" == "$FN" && "$FN" == "$AN" ]] || fail "R10b: checks.go [$CN], mssql_memory_suggestion [$FN], the API [$AN] (want one number)"
ok "R10b: the Memory page's suggestion ($AN MB) is the number the Server options check states"
# R10c the pages in headless Chromium: the Waits page's poison grid with pgsyn1's statement, pgsyn4's words and no grid,
# the SQL Server Memory page's 'PerformanceMonitor's suggestion' with the API's number
setsid chromium --headless=new --remote-debugging-port=0 --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu about:blank > "$TMPD/chrome.log" 2>&1 & CHRPID=$!
CDP=; for _ in $(seq 1 60); do [ -s "$TMPD/chrome/DevToolsActivePort" ] && CDP=$(head -1 "$TMPD/chrome/DevToolsActivePort"); [ -n "$CDP" ] && curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
[[ "$CDP" =~ ^[0-9]+$ ]] || fail "R10c: Chromium never answered"
cat > "$TMPD/r10.mjs" <<'PAGE'
const [port, base, p1, p4, sb, wf, tp, sugg] = process.argv.slice(2);
setTimeout(() => { console.log('FAIL the page check did not end in 120 s'); process.exit(2); }, 120000).unref();
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map(); const thrown = [];
ws.addEventListener('message', m => { const d = JSON.parse(m.data);
  if (d.method === 'Runtime.exceptionThrown') thrown.push(d.params.exceptionDetails?.exception?.description ?? 'exception');
  if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => (await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true })).result?.result?.value;
const until = async (e, ms = 45000) => { const t = Date.now(); while (Date.now() - t < ms) { const v = await ev(e); if (v) return v; await sleep(300); } return null; };
let failed = 0; const check = (l, ok, w) => { if (!ok) failed++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${l}: ${w}`); };
await cmd('Page.enable'); await cmd('Runtime.enable');
// the section after the 'Poison waits' heading, up to the next heading: its text and whether it holds a grid
const poison = `(() => { const h = [...document.querySelectorAll('main h3')].find(x => x.textContent.trim() === 'Poison waits'); if (!h) return null;
  let t = h.nextElementSibling, text = '', grid = false; while (t && t.tagName !== 'H3') { text += t.textContent + ' '; if (t.matches?.('table.grid') || t.querySelector?.('table.grid')) grid = true; t = t.nextElementSibling; }
  return { text, grid }; })()`;
const range = `&from=${encodeURIComponent(wf)}&to=${encodeURIComponent(tp)}`;
await cmd('Page.navigate', { url: `${base}/#/waits?i=${p1}${range}` });
const a = await until(poison);
check('waits pgsyn1', !!a && a.grid && a.text.includes('IPC:BufferIO') && a.text.includes('queryid 42: SELECT pgv_poison FROM t'), a ? a.text.slice(0, 160) : 'no Poison waits section');
await cmd('Page.navigate', { url: `${base}/#/waits?i=${p4}${range}` }); await sleep(300);
const b = await until(`(() => { const v = ${poison}; return v && v.text.trim() ? v : null; })()`);
check('waits pgsyn4', !!b && !b.grid && b.text.trim().startsWith('not judged: needs pg_wait_sampling'), b ? b.text.slice(0, 120) : 'no Poison waits section');
await cmd('Page.navigate', { url: `${base}/#/mssqlmemory?i=${sb}&w=1h` });
const s = await until(`(() => { const td = [...document.querySelectorAll('main table.props th, main table.props td')].find(x => x.textContent.trim() === "PerformanceMonitor's suggestion");
  return td ? td.nextElementSibling?.textContent ?? '' : null; })()`);
const n = s ? (s.match(/^[\d,. ]+/)?.[0] ?? '').replace(/[^\d]/g, '') : '';
check('memory', n === sugg, `'PerformanceMonitor's suggestion' ${s ? s.slice(0, 120) : 'not shown'} (the API's ${sugg} MB)`);
check('pages', thrown.length === 0, thrown.length ? thrown.slice(0, 3).join(' | ') : 'no exception');
process.exit(failed ? 1 : 0);
PAGE
timeout 140 node "$TMPD/r10.mjs" "$CDP" "$U2" "$pw1" "$pw4" "$SB" "$WF" "$TP" "$AN" || fail "R10c: a page check failed"
pq "UPDATE pgvigil.instances SET is_active = false WHERE instance_id IN ($pw1, $pw4)" >/dev/null
ok "R10c: the Waits page draws pgsyn1's poison wait with its statement and pgsyn4's 'not judged' words without a grid; the Memory page states the suggestion"

echo "PROOF OK: pm313 rules (A R7 R9 R6 R5 R2 R1 R3 R8 R4 R10)"
