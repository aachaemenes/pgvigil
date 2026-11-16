#!/usr/bin/env bash
# Proof of task 412 (B19; SQLMonitor C53 / A10, G494 / G496 / G497 / G837): wait seconds per core per minute
# (0152's mssql_wait_core_points over the newest five minutes of reads, SQLMonitor's per-core list, the scheduler
# count; the seed of 0153; the 'waits' family of the join file) and the documentation links (doclinks.ts; the build's
# own page from the catalogue at serve time). Lab only: a SQL Server container and a repository database of its own.
# Needs: docker (mcr.microsoft.com/mssql/server images), go, psql, python3, curl, node (22 or later), npm, chromium, ss, and:
#   ADMIN_DSN       a superuser connection to a PostgreSQL sandbox in keyword form (default 'host=127.0.0.1 port=5432
#                   user=postgres dbname=postgres'); the proof makes its own repository database and drops it.
#   PGVIGIL_IMAGE   the SQL Server image (default 2022-latest).
#   PGVIGIL_WIRING  1 (default): 401's, 402's and this task's wiring patches applied to the run's own copy of the tree
#                   (never the tree itself), in that order, where the copy lacks them; 0 = the copy as it is.
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment.
#
# Expected (written 11-15 before the first run; red on 5cc11319 at B: no 'waits' family, no mssql_wait_core_points):
#  A. the run's copy with the three wiring patches: npm ci and npm run build (tsc --noEmit, then esbuild) exit 0; go vet
#     ./internal/mssql ./internal/web clean; go test ./internal/mssql -run 'TestBuildDocs' ok.
#  B. migrate: one seed on waits.wait_s_per_core_min (off, fleet, above 180 / 299.999, for_minutes 0, created_by
#     'pgvigil', client '0153 seed') with one 'seed' log row; a second migrate adds neither; metric_catalog's row
#     (unit s_core_min); mssql_wait_percore_ignored 27 types, none of them in waits.go's benign list and with it 84
#     (python reads both files); metric_na_reasons' row for the metric.
#  C. built rows in the run's repository, an instance a case (the pg sandbox's cases of 11-15): printed
#     'c1 T:185|c2 T:15|c3 T-0.03m:30,T:30|c5 T:6|c6a T:null|c6b T:null|c7 T-5m:60,T-4m:60,T-2m:60,T-1m:60,T:60' and no
#     point for c1x and c4 (the burst; 120 s reads; a read 2 s after; a fresh instance; a hash spill counted with
#     WAITFOR, CXCONSUMER, WAITFOR_TASKSHUTDOWN and MEMORY_ALLOCATION_EXT left out; no scheduler count, 0 schedulers; a
#     restart's read); metric_points(.., 'waits', ..) equal to mssql_wait_core_points for every case; the summary
#     'c1:185|c1x:-|c2:15|c3:30|c4:-|c5:6|c6a:1.5|c6b:-|c7:60'. The off seed colours c1's grid row: current 185,
#     'warning', the rule's name ending '(off: colours only, no alert)'. An instance rule (warning 100, critical 180,
#     0 minutes) on c1 reads 'critical' after alert_rules_run, on c6a 'na' with GET /api/alertrules?part=state's
#     na_why 'not judged: no scheduler count (the mssql_cpu collection is off, or Azure SQL Database)'.
#  D. live on the container: mssql_cpu and mssql_waits read at t0 and then three times about 110 s apart (the server's
#     clock: three stored reads, a span of 300 s or more); a WAITFOR DELAY of 10 s ends in the second interval, a lock
#     wait of about 10 s (a holder of 15 s, the waiter started once the holder is seen in its WAITFOR) in the third.
#     The second read stores WAITFOR benign with at least 9,000 ms; the third an LCK_M_ row not benign with at least
#     8,000 ms; the scheduler count stored equals the container's VISIBLE ONLINE schedulers; the point at the fourth
#     read equals python's hand formula over the stored rows (is_benign and the proof's own copy of the 27 types left
#     out); it holds the lock wait and not the WAITFOR.
#  E. the APIs: GET /api/metrics/series?metric=waits.wait_s_per_core_min gives D's point; GET /api/perfsummary's
#     wait_s_core_min for the container equals mssql_wait_core_summary over the same window; GET /api/mssql/checks
#     ?part=build_docs for the container's version (the dotted build inside the instance row's first line of
#     @@VERSION) equals python's reading of checks.go's catalogue (the build's own
#     page when listed, Microsoft's build list in words when not, the newest build's page).
#  F. the links' data (python over doclinks.ts): 25 error ranges from 0 to 49999 with no gap or overlap, both sides of
#     every boundary in the range that holds it, 50000 in none; the URL forms of the wait types and the ranges (no
#     page is fetched).
#  G. the pages in headless Chromium, light and dark: the Waits page's 'Wait seconds per core per minute' section,
#     its two tiles in 's/core/min' and a chart; a wait type's two links (Microsoft's list, SQLskills' lowercase page)
#     with target _blank, rel 'noopener noreferrer' and an accessible name ending '(opens in a new tab)'; the error
#     log's 18456 (a failed login the proof makes, kept by the instance search string 'Login failed for user': a
#     severity-14 18456 is noise to the reader otherwise; at least one such row stored, marked custom) linking
#     ...-18000-to-18999; the checks' Build view's version link
#     equal to E's build_url; the Performance summary's column 'wait s per core per minute' with the container's value.
#  PASS: 'PROOF OK: waits per core and doc links (A B C D E F G)'.
set -uo pipefail
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMAGE=${PGVIGIL_IMAGE:-2022-latest}
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
LBL=pgvigil-proof=wpc
PGDB=pgv_wpc_$SUF; MON=pgv_wmon_$SUF; SQL=pgv-wpc-$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; CHRPID=
SA_PW=$(pw); MON_PW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\nMSSQL_PID=Developer\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  [[ -n "$CHRPID" ]] && kill "$CHRPID" 2>/dev/null || true
  docker ps -aq --filter "label=$LBL-$SUF" | xargs -r docker rm -f -v >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
for t in docker go psql python3 curl node npm chromium setsid ss; do command -v "$t" >/dev/null || fail "needs $t"; done
node -e 'process.exit(typeof WebSocket === "function" && typeof fetch === "function" ? 0 : 1)' || fail "node $(node --version) has no global WebSocket: G needs node 22 or later"
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"

echo "== A. the run's copy, its wiring, the build, vet and the catalogue's test =="
GSRC=$TMPD/src; mkdir -p "$GSRC"
tar -C . --exclude=./web/node_modules --exclude=./.lab --exclude=./.git -cf - . | tar -C "$GSRC" -xf -
wire() { (cd "$GSRC" && { git apply "$1" 2>"$TMPD/apply.err" || patch -p1 --forward < "$1" >>"$TMPD/apply.err" 2>&1; }) || fail "A: $1: $(cat "$TMPD/apply.err")"; echo "   applied $1"; }
if [[ "${PGVIGIL_WIRING:-1}" == 1 ]]; then
  grep -q 'ListCollector' "$GSRC/internal/mssql/mssql.go" || wire scripts/proof-mssql-counters-wiring.patch
  grep -q "0153 seed" "$GSRC/internal/repo/sql/0190_join_release2.sql" || wire scripts/proof-mssql-counter-checks-wiring.patch
  grep -q "mssql_wait_core_points" "$GSRC/internal/repo/sql/0190_join_release2.sql" || wire scripts/proof-mssql-waits-percore-wiring.patch
fi
(cd "$GSRC/web" && npm ci --no-audit --no-fund >"$TMPD/web.log" 2>&1 && npm run build >>"$TMPD/web.log" 2>&1) || { tail -30 "$TMPD/web.log" >&2; fail "A: the web build (tsc --noEmit, esbuild)"; }
(cd "$GSRC" && go vet ./internal/mssql ./internal/web) > "$TMPD/vet.out" 2>&1 || { tail -20 "$TMPD/vet.out" >&2; fail "A: go vet"; }
(cd "$GSRC" && go test ./internal/mssql -run 'TestBuildDocs' -count=1) > "$TMPD/test.out" 2>&1 || { tail -30 "$TMPD/test.out" >&2; fail "A: go test TestBuildDocs"; }
(cd "$GSRC" && go build -o "$TMPD/pgvigil" ./cmd/pgvigil) || fail "A: the build"
ok "A: tsc and the bundle, go vet, TestBuildDocs and the binary over the three wiring patches"

sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout "${3:-180}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
sqb() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout "${3:-180}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
sqok() { local out; out=$(sqb "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
# bg <seconds> <T-SQL>: a session of its own in the background (a lock holder, a waiter)
bg() { ( printf '%s\n' "$2" | timeout "$1" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -d pgvctr -i /dev/stdin' >/dev/null 2>&1 & ); }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
col() { for c in "$@"; do timeout 180 "$TMPD/pgvigil" collect -config "$CFG" -instance wpcbox -once "$c" > "$TMPD/col-$c.out" 2>&1 \
  || { cat "$TMPD/col-$c.out" >&2; fail "collect $c"; }; done; }
freeport() { local lo=$1 hi=$2 p used
  used=$(ss -Htan) || fail "ss -Htan failed: the ports in use cannot be read"
  used=$(awk '{n = split($4, a, ":"); print a[n]}' <<<"$used" | sort -u)
  for _ in $(seq 1 50); do p=$((lo + RANDOM % (hi - lo + 1))); grep -qx "$p" <<<"$used" || { echo "$p"; return 0; }; done
  fail "no free port in $lo-$hi"
}

echo "== B. the container, the repository, the seed =="
docker run -d --name "$SQL" --label "$LBL-$SUF" --memory 6g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "mcr.microsoft.com/mssql/server:$IMAGE" >/dev/null
r=; for _ in $(seq 1 150); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" master 15 2>/dev/null || true); [[ "$r" == 1 ]] && break; sleep 2; done
[[ "$r" == 1 ]] || { docker logs --tail 20 "$SQL" >&2 2>&1 || true; fail "the $IMAGE container did not come up in 300 s"; }
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://'); [[ "$PORT_SQL" =~ ^[0-9]+$ ]] || fail "the host port [$PORT_SQL]"
sqok "the database" "CREATE DATABASE pgvctr; ALTER DATABASE pgvctr SET RECOVERY SIMPLE;"
sqok "the table" "CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, v int NOT NULL DEFAULT 0);
  INSERT dbo.t (id) SELECT TOP (100) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) FROM sys.all_objects;" pgvctr
sqok "the monitor login" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF;
  GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON];
  USE msdb; CREATE USER [$MON] FOR LOGIN [$MON]; ALTER ROLE SQLAgentReaderRole ADD MEMBER [$MON];"
export PGV_WPC_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="${ADMIN_DSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
CFG=$TMPD/w.yaml
printf 'repository:\n  dsn: "%s"\ninstances:\n  - name: wpcbox\n    engine: sqlserver\n    dsn: env:PGV_WPC_MON\n' "$PGDSN" > "$CFG"
"$TMPD/pgvigil" migrate -config "$CFG" > "$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "B: migrate"; }
seed() { pq "SELECT count(*) || '|' || coalesce(string_agg(r.enabled || ' ' || r.scope || ' ' || r.op || ' ' || r.warning || ' ' || r.critical || ' ' || r.for_minutes
  || ' ' || r.created_by || ' ' || r.client, ','), '') || '|' || (SELECT count(*) FROM pgvigil.alert_rule_log l WHERE l.metric = 'waits.wait_s_per_core_min' AND l.op = 'seed')
  FROM pgvigil.alert_rules r WHERE r.metric = 'waits.wait_s_per_core_min'"; }
S1=$(seed); echo "   the seed: $S1"
[[ "$S1" == "1|false fleet above 180 299.999 0 pgvigil 0153 seed|1" ]] || fail "B: the seed [$S1]"
"$TMPD/pgvigil" migrate -config "$CFG" > "$TMPD/migrate2.out" 2>&1 || { cat "$TMPD/migrate2.out" >&2; fail "B: the second migrate"; }
S2=$(seed); [[ "$S2" == "$S1" ]] || fail "B: a second migrate changed the seed [$S2]"
CAT=$(pq "SELECT unit || '|' || family || '|' || engine FROM pgvigil.metric_catalog WHERE key = 'waits.wait_s_per_core_min'")
[[ "$CAT" == "s_core_min|waits|sqlserver" ]] || fail "B: metric_catalog's row [$CAT]"
NAW=$(pq "SELECT why FROM pgvigil.metric_na_reasons WHERE key = 'waits.wait_s_per_core_min'")
WHY='not judged: no scheduler count (the mssql_cpu collection is off, or Azure SQL Database)'
[[ "$NAW" == "$WHY" ]] || fail "B: metric_na_reasons' row [$NAW]"
pq "SELECT wait_type FROM pgvigil.mssql_wait_percore_ignored ORDER BY 1" > "$TMPD/ignored.txt"
python3 - "$TMPD/ignored.txt" internal/mssql/waits.go <<'PY' || fail "B: the per-core list against waits.go's benign list"
import re, sys
ign = [l.strip() for l in open(sys.argv[1]) if l.strip()]
src = open(sys.argv[2]).read()
m = re.search(r'var benignWaits = func\(\) map\[string\]bool \{.*?strings\.Fields\(`(.*?)`\)', src, re.S)
benign = set(m.group(1).split()) if m else set()
both = set(ign) & benign
print(f"   the per-core list {len(ign)}, waits.go's benign {len(benign)}, in both {len(both)}, together {len(set(ign) | benign)}")
sys.exit(0 if len(ign) == 27 and len(benign) == 57 and not both and len(set(ign) | benign) == 84 else 1)
PY
ok "B: one seed off at 180 / 299.999 for 0 minutes, unchanged by a second migrate; the catalog row; the N/A reason; 27 + 57 = 84 types"

echo "== C. built rows: the window, the list, the scheduler count, the rule engine =="
XT=$(pq "SELECT date_trunc('minute', now())")
pq "SELECT pgvigil.ensure_month_partition('mssql_wait_sample', '$XT'::timestamptz - interval '1 hour'), pgvigil.ensure_month_partition('mssql_wait_sample', '$XT'),
           pgvigil.ensure_month_partition('mssql_sched_sample', '$XT'::timestamptz - interval '1 hour'), pgvigil.ensure_month_partition('mssql_sched_sample', '$XT')" >/dev/null
declare -A CI
for k in c1 c1x c2 c3 c4 c5 c6a c6b c7; do
  CI[$k]=$(pq "INSERT INTO pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
    VALUES ('wpc$k', 'sqlserver', '{}', now(), now(), true, 'sqlserver') RETURNING instance_id" | head -1)
  [[ "${CI[$k]}" =~ ^[0-9]+$ ]] || fail "C: the built instance $k [${CI[$k]}]"
done
# wrow <case> <minutes before XT> <interval s> <wait type> <ms> <benign>
rows=""
wrow() { rows+="(${CI[$1]}, '$XT'::timestamptz - $2 * interval '1 minute', '$4', $6, 1, $5, 0, $3),"; }
wrow c1 4 60 LCK_M_X 7000000 false; for m in 3 2 1 0; do wrow c1 $m 60 LCK_M_X 100000 false; done
wrow c1 4 60 LAZYWRITER_SLEEP 60000 true; wrow c1 0 60 LAZYWRITER_SLEEP 60000 true; wrow c1 4 60 CXCONSUMER 900000 false; wrow c1 0 60 CXCONSUMER 900000 false
wrow c1x 4 60 LCK_M_X 99000000 false; wrow c1x 0 60 LCK_M_X 99000000 false
for m in 4 2 0; do wrow c2 $m 120 LCK_M_S 120000 false; done
for m in 4.0333333 3.0333333 2.0333333 1.0333333 0.0333333; do wrow c3 $m 60 LCK_M_S 60000 false; done; wrow c3 0 2 LCK_M_S 2000 false
wrow c4 0 2 LCK_M_S 2000 false
for m in 4 3 2 1 0; do wrow c5 $m 60 SLEEP_TASK 6000 false; done
for t in CXCONSUMER WAITFOR_TASKSHUTDOWN MEMORY_ALLOCATION_EXT; do wrow c5 0 60 $t 600000 false; done; wrow c5 0 60 WAITFOR 600000 true
for k in c6a c6b; do for m in 4 3 2 1 0; do wrow $k $m 60 LCK_M_S 6000 false; done; done
for m in 0 1 2 4 5 6 7 8 9; do wrow c7 $m 60 LCK_M_S 60000 false; done
pq "INSERT INTO pgvigil.mssql_wait_sample (instance_id, snapshot_at, wait_type, is_benign, waiting_tasks, wait_ms, signal_ms, interval_secs) VALUES ${rows%,}" >/dev/null
sched() { pq "INSERT INTO pgvigil.mssql_sched_sample (instance_id, snapshot_at, schedulers) VALUES (${CI[$1]}, '$XT'::timestamptz + $2 * interval '1 second', $3)" >/dev/null; }
sched c1 -300 8; sched c1x -300 8; sched c2 -300 4; sched c3 -300 2; sched c4 -300 2; sched c5 -300 1; sched c6b -300 0; sched c7 -300 1; sched c7 -600 1
sched c1 10 1        # after R: never read for R
sched c6a -1200 4    # 20 minutes before: beyond the 15 minutes a point reads back
PTS=""; for k in c1 c1x c2 c3 c4 c5 c6a c6b c7; do
  pt=$(pq "SELECT string_agg(CASE WHEN at = '$XT'::timestamptz THEN 'T' ELSE 'T-' || trim(trailing '.' FROM trim(trailing '0' FROM round(extract(epoch FROM '$XT'::timestamptz - at)::numeric / 60, 2)::text)) || 'm' END
    || ':' || coalesce(value::text, 'null'), ',' ORDER BY at) FROM pgvigil.mssql_wait_core_points(${CI[$k]}, '$XT'::timestamptz - interval '30 minutes', '$XT')")
  same=$(pq "SELECT count(*) FROM (SELECT * FROM pgvigil.metric_points(${CI[$k]}, 'waits', '$XT'::timestamptz - interval '30 minutes', '$XT')
    EXCEPT SELECT * FROM pgvigil.mssql_wait_core_points(${CI[$k]}, '$XT'::timestamptz - interval '30 minutes', '$XT')) x")
  [[ "$same" == 0 ]] || fail "C: $k's metric_points differ from mssql_wait_core_points ($same rows)"
  [[ -n "$pt" ]] && PTS+="$k $pt|"
done
PTS=${PTS%|}; echo "   the points: $PTS"
[[ "$PTS" == "c1 T:185|c2 T:15|c3 T-0.03m:30,T:30|c5 T:6|c6a T:null|c6b T:null|c7 T-5m:60,T-4m:60,T-2m:60,T-1m:60,T:60" ]] || fail "C: the points [$PTS]"
SUM=$(for k in c1 c1x c2 c3 c4 c5 c6a c6b c7; do printf '%s:%s|' "$k" "$(pq "SELECT coalesce(pgvigil.mssql_wait_core_summary(${CI[$k]}, '$XT'::timestamptz - interval '30 minutes', '$XT')::text, '-')")"; done)
SUM=${SUM%|}; echo "   the summary: $SUM"
[[ "$SUM" == "c1:185|c1x:-|c2:15|c3:30|c4:-|c5:6|c6a:1.5|c6b:-|c7:60" ]] || fail "C: the summary [$SUM]"
# the owner line: the off seed colours c1's grid row before any rule of its own
GR=$(pq "SELECT g.current_value || '|' || pgvigil.metric_status(g.op, g.current_value, g.warning, g.critical) || '|' || g.rule_name
  FROM pgvigil.metric_grid(${CI[c1]}, '$XT'::timestamptz - interval '30 minutes', '$XT'::timestamptz + interval '1 second', interval '15 minutes', NULL::text, 'waits') g
  WHERE g.key = 'waits.wait_s_per_core_min'" 2>&1)
echo "   c1's grid row: $GR"
[[ "$GR" == "185|warning|"*"(off: colours only, no alert)" ]] || fail "C: the off seed's colour on c1 [$GR]"
rule() { pq "SELECT pgvigil.import_alert_rule(now(), '$1'::jsonb)" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("rule_id") if d.get("outcome") == "done" else "refused: " + json.dumps(d))'; }
R1=$(rule "{\"op\":\"add\",\"ui_user\":\"proof412\",\"metric\":\"waits.wait_s_per_core_min\",\"op_dir\":\"above\",\"scope\":\"instance\",\"instance_name\":\"wpcc1\",\"warning\":100,\"critical\":180,\"for_minutes\":0}")
R6=$(rule "{\"op\":\"add\",\"ui_user\":\"proof412\",\"metric\":\"waits.wait_s_per_core_min\",\"op_dir\":\"above\",\"scope\":\"instance\",\"instance_name\":\"wpcc6a\",\"warning\":100,\"critical\":180,\"for_minutes\":0}")
[[ "$R1" =~ ^[0-9]+$ && "$R6" =~ ^[0-9]+$ ]] || fail "C: the instance rules [$R1] [$R6]"
pq "SELECT count(*) FROM (SELECT pgvigil.alert_rules_run(now())) x" >/dev/null
ST=$(pq "SELECT string_agg(i.name || ':' || s.state, ',' ORDER BY i.name) FROM pgvigil.alert_rule_state s JOIN pgvigil.instances i USING (instance_id)
  WHERE s.metric = 'waits.wait_s_per_core_min' AND i.name IN ('wpcc1', 'wpcc6a')")
echo "   the rule states: $ST"
[[ "$ST" == "wpcc1:critical,wpcc6a:na" ]] || fail "C: the rule states [$ST]"
ok "C: the five-minute span, the list, the scheduler count, the summary, the off seed's colour, critical and 'na' through the engine"

echo "== D. live on the container: WAITFOR left out, a lock wait counted, the hand formula =="
VO=$(sq "SELECT COUNT(*) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE'" | tr -d '\r ')
[[ "$VO" =~ ^[0-9]+$ ]] || fail "D: the container's schedulers [$VO]"
col mssql_cpu mssql_waits                      # t0: the counters' start
SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'wpcbox'"); [[ "$SB" =~ ^[0-9]+$ ]] || fail "D: wpcbox [$SB]"
sleep 100; col mssql_cpu mssql_waits           # read 1
sqok "the WAITFOR" "WAITFOR DELAY '00:00:10';" pgvctr
sleep 98; col mssql_cpu mssql_waits            # read 2: the WAITFOR ended in its interval
bg 40 "BEGIN TRAN; UPDATE dbo.t SET v = v + 1 WHERE id = 1; WAITFOR DELAY '00:00:15'; COMMIT;"
# the waiter starts only once the holder sits in its WAITFOR with the row locked (the build review's S4: a fixed sleep
# on a loaded box let the waiter run first); the holder's 15 s leave the waiter 8 s or more when it is seen within 7 s
HT=$SECONDS; HS=0
for _ in $(seq 1 60); do HS=$(sq "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE database_id = DB_ID('pgvctr') AND wait_type = 'WAITFOR'" master 15 | tr -d '\r '); [[ "$HS" == 1 ]] && break; sleep 0.3; done
[[ "$HS" == 1 ]] || fail "D: the lock holder never reached its WAITFOR [$HS]"
echo "   the holder in its WAITFOR after $((SECONDS - HT)) s"
sqok "the lock wait" "UPDATE dbo.t SET v = v + 1 WHERE id = 1;" pgvctr
sleep 96; col mssql_cpu mssql_waits            # read 3: the lock wait ended in its interval
sleep 5; col mssql_cpu mssql_waits             # read 4: the span of reads 2-4 (and 1) covers 300 s or more
pq "SELECT snapshot_at, wait_type, is_benign, wait_ms, interval_secs FROM pgvigil.mssql_wait_sample WHERE instance_id = $SB ORDER BY snapshot_at, wait_type" > "$TMPD/live.txt"
NS=$(pq "SELECT schedulers FROM pgvigil.mssql_sched_sample WHERE instance_id = $SB ORDER BY snapshot_at DESC LIMIT 1")
[[ "$NS" == "$VO" ]] || fail "D: the stored scheduler count [$NS] (the container's VISIBLE ONLINE $VO)"
LP=$(pq "SELECT at || '|' || coalesce(value::text, 'null') FROM pgvigil.mssql_wait_core_points($SB, now() - interval '30 minutes', now()) ORDER BY at DESC LIMIT 1")
echo "   the newest point: [$LP], $NS schedulers"
python3 - "$TMPD/live.txt" "$LP" "$NS" <<'PY' || fail "D: the live point against the hand formula"
import sys, collections
ign = set("""CHKPT CXCONSUMER EXECSYNC FSAGENT MEMORY_ALLOCATION_EXT PREEMPTIVE_OS_FLUSHFILEBUFFERS PREEMPTIVE_XE_GETTARGETSTATE
PVS_PREALLOCATE PWAIT_ALL_COMPONENTS_INITIALIZED PWAIT_DIRECTLOGCONSUMER_GETNEXT PWAIT_EXTENSIBILITY_CLEANUP_TASK SERVER_IDLE_CHECK
SLEEP_BPOOL_FLUSH SLEEP_DBSTARTUP SLEEP_DCOMSTARTUP SLEEP_MASTERDBREADY SLEEP_MASTERMDREADY SLEEP_MASTERUPGRADED SLEEP_MSDBSTARTUP
SLEEP_TEMPDBSTARTUP SQLTRACE_WAIT_ENTRIES VDI_CLIENT_OTHER WAITFOR_TASKSHUTDOWN WAIT_XTP_CKPT_CLOSE WAIT_XTP_HOST_WAIT WAIT_XTP_RECOVERY
XE_DISPATCHER_JOIN""".split())
reads = collections.OrderedDict()
for line in open(sys.argv[1]):
    at, wt, benign, ms, secs = line.rstrip('\n').split('|')
    r = reads.setdefault(at, {'secs': float(secs), 'counted': 0, 'waitfor': None, 'lock': 0})
    if wt == 'WAITFOR': r['waitfor'] = (benign, int(ms))
    if wt.startswith('LCK_M_') and benign == 'f': r['lock'] += int(ms)
    if benign == 'f' and wt not in ign: r['counted'] += int(ms)
ats = list(reads)
if len(ats) < 4: print(f"   {len(ats)} stored reads (want 4)"); sys.exit(1)
w2, l3 = reads[ats[1]]['waitfor'], reads[ats[2]]['lock']
print(f"   read 2's WAITFOR {w2}, read 3's lock waits {l3} ms; intervals {[round(reads[a]['secs'], 1) for a in ats]}")
if not w2 or w2[0] != 't' or w2[1] < 9000 or l3 < 8000: sys.exit(1)
span = wait = 0.0
for a in reversed(ats):                      # newest first while the reads before sum under 300 s, within 10 minutes
    if span >= 300: break
    span += reads[a]['secs']; wait += reads[a]['counted'] / 1000
want = round(wait / int(sys.argv[3]) / (span / 60), 2)
at, val = sys.argv[2].split('|')
print(f"   the hand formula: {wait:.3f} s over {sys.argv[3]} schedulers and {span:.1f} s = {want}; the point {val}")
sys.exit(0 if val != 'null' and abs(float(val) - want) < 0.006 and span >= 300 else 1)
PY
ok "D: WAITFOR stored benign and left out, the lock wait counted, the point equal to the hand formula"

echo "== E. the APIs =="
PORT=$(freeport 20000 29999)
"$TMPD/pgvigil" serve -config "$CFG" -listen "127.0.0.1:$PORT" -no-login > "$TMPD/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 60); do grep -q "url=http://127.0.0.1:$PORT/" "$TMPD/serve.log" 2>/dev/null && break; sleep 0.5; done
FROM=$(date -u -d '-30 min' +%Y-%m-%dT%H:%M:%SZ); TO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -fs -m 20 "http://127.0.0.1:$PORT/api/metrics/series?instance=$SB&metric=waits.wait_s_per_core_min&from=$(urlq "$FROM")&to=$(urlq "$TO")" > "$TMPD/series.json" || fail "E: GET /api/metrics/series: $(tail -3 "$TMPD/serve.log")"
curl -fs -m 30 "http://127.0.0.1:$PORT/api/perfsummary?from=$(urlq "$FROM")&to=$(urlq "$TO")&part=mssql" > "$TMPD/perf.json" || fail "E: GET /api/perfsummary"
curl -fs -m 20 "http://127.0.0.1:$PORT/api/mssql/checks?instance=$SB&part=build_docs" > "$TMPD/docs.json" || fail "E: GET /api/mssql/checks?part=build_docs"
PSUM=$(pq "SELECT coalesce(pgvigil.mssql_wait_core_summary($SB, '$FROM', '$TO')::text, '-')")
VER=$(pq "SELECT coalesce(server_version, '') FROM pgvigil.instances WHERE instance_id = $SB")
python3 - "$TMPD/series.json" "$TMPD/perf.json" "$TMPD/docs.json" "$LP" "$PSUM" "$VER" "$SB" "$GSRC/internal/mssql/checks.go" <<'PY' || fail "E: the APIs"
import json, sys, re
def rows(f, part):
    t = json.load(open(f)).get(part) or {}
    return [dict(zip(t.get('columns') or [], r)) for r in t.get('rows') or []]
ser, lp, psum, ver, sb = rows(sys.argv[1], 'series'), sys.argv[4], sys.argv[5], sys.argv[6], int(sys.argv[7])
newest = ser[-1]['value'] if ser else None
ok1 = newest is not None and abs(float(newest) - float(lp.split('|')[1])) < 0.006
perf = [r for r in rows(sys.argv[2], 'mssql') if r.get('instance_id') == sb]
pv = perf[0].get('wait_s_core_min') if perf else 'no row'
ok2 = (pv is None and psum == '-') or (pv not in (None, 'no row') and psum != '-' and abs(float(pv) - float(psum)) < 0.006)
d = (rows(sys.argv[3], 'build_docs') or [{}])[0]
src = open(sys.argv[8]).read()
cat = src[src.index('const buildCatalogue = `') + 24:]; cat = cat[:cat.index('`')]
# the instance row's version is the first line of @@VERSION ('Microsoft SQL Server 2022 (RTM-CU28) (KB5125472) -
# 16.0.4325.4 (X64)'): the dotted build inside it (box run 412proof1 read the whole line as a product version)
vm = re.search(r'\b(\d+)\.(\d+)\.(\d+)(?:\.\d+)?\b', ver)
major, build = (int(vm.group(1)), int(vm.group(3))) if vm else (0, 0)
rowsm = [l.split('|') for l in cat.strip().splitlines() if l.split('|')[0] == str(major)]
lst = 'https://support.microsoft.com/kb/321185'
def page(r): return lst if (r[7].strip() == '' or 'info.microsoft.com' in r[7]) else r[7].strip()
# a build listed twice keeps its earlier-released line, as checks.go's loader does (the first among equal dates)
def keep(rs): return min(rs, key=lambda r: r[3])
nb = max((int(r[1]) for r in rowsm), default=None)
newest_row = keep([r for r in rowsm if int(r[1]) == nb]) if rowsm else None
exact = [r for r in rowsm if int(r[1]) == build]
want = page(keep(exact)) if exact else lst
ok3 = bool(rowsm) and d.get('build_url') == want and d.get('newest_url') == page(newest_row) and d.get('newest_build') == f"{major}.0.{newest_row[1]}"
print(f"   series newest {newest} (the point {lp}); perfsummary {pv} (the function {psum}); version {ver}: build_url {d.get('build_url')} "
      f"[{d.get('build_url_words')}] (want {want}, {'listed' if exact else 'not listed'}), newest {d.get('newest_build')} {d.get('newest_url')}")
sys.exit(0 if ok1 and ok2 and ok3 else 1)
PY
BURL=$(python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["build_docs"]; print(dict(zip(t["columns"], t["rows"][0])).get("build_url") or "")' "$TMPD/docs.json")
ok "E: the series, the summary column and the build's links as the catalogue says"

echo "== F. the links' data =="
python3 - "$GSRC/web/src/doclinks.ts" <<'PY' || fail "F: the links' data"
import re, sys
src = open(sys.argv[1]).read()
block = src[src.index('const errorRanges'):]; block = block[:block.index('];')]
rng = [(int(a), int(b)) for a, b in re.findall(r'\[(\d+), (\d+)\]', block)]
want = [(0, 999)] + [(k, k + 999) for k in range(1000, 11000, 1000)] + [(11000, 12999), (13000, 13999), (14000, 14999), (15000, 15999),
        (16000, 17999), (18000, 18999), (19000, 20999), (21000, 21999), (22000, 22999), (23000, 25999), (26000, 27999), (28000, 30999),
        (31000, 41399), (41400, 49999)]
cont = all(rng[i][1] + 1 == rng[i + 1][0] for i in range(len(rng) - 1)) and rng[0][0] == 0 and rng[-1][1] == 49999
find = lambda n: next(((lo, hi) for lo, hi in rng if lo <= n <= hi), None)
sides = all(find(lo) == (lo, hi) and find(hi) == (lo, hi) and (lo == 0 or find(lo - 1) != (lo, hi)) for lo, hi in rng)
base = re.search(r"msErrorsBase = '([^']+)'", src).group(1)
forms = base == 'https://learn.microsoft.com/en-us/sql/relational-databases/errors-events/database-engine-events-and-errors-' \
    and "'https://www.sqlskills.com/help/waits/' + encodeURIComponent(type.toLowerCase())" in src \
    and 'sys-dm-os-wait-stats-transact-sql' in src
print(f"   {len(rng)} ranges, contiguous {cont}, both sides of every boundary {sides}, 50000 in none {find(50000) is None}, the URL forms {forms}")
sys.exit(0 if rng == want and cont and sides and find(50000) is None and forms else 1)
PY
ok "F: 25 error ranges 0-49999 with no gap, every boundary on its side, 50,000 none; the URL forms"

echo "== G. the pages in headless Chromium, light and dark =="
# a 'Login failed' line (18456, severity 14) is on the reader's noise list (errorlog.go): the instance's own search
# string keeps it (a custom match), as a DBA who wants failed logins on the error log page sets it (the build review's B2)
SS=$(pq "SELECT pgvigil.mssql_errorlog_search_set('wpcbox', ARRAY['Login failed for user'])"); [[ "$SS" == 1 ]] || fail "G: the search string [$SS]"
sq "SELECT 1" master 15 >/dev/null 2>&1 || true
docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c "$SQLCMD -S localhost -U pgv_nobody_$SUF -P 'Wrong9pw!' -C -Q 'SELECT 1'" >/dev/null 2>&1 || true
col mssql_errorlog mssql_checks
N18=$(pq "SELECT count(*) FROM pgvigil.mssql_errorlog WHERE instance_id = $SB AND error_number = 18456 AND custom")
[[ "$N18" =~ ^[1-9][0-9]*$ ]] || fail "G: no 18456 row stored by the error log reader [$N18] ($(tail -3 "$TMPD/col-mssql_errorlog.out" | tr '\n' ' '))"
echo "   18456 rows kept by the search string: $N18"
setsid chromium --headless=new --remote-debugging-port=0 --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu about:blank > "$TMPD/chrome.log" 2>&1 & CHRPID=$!
CDP=; for _ in $(seq 1 60); do [ -s "$TMPD/chrome/DevToolsActivePort" ] && CDP=$(head -1 "$TMPD/chrome/DevToolsActivePort"); [ -n "$CDP" ] && curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
[[ "$CDP" =~ ^[0-9]+$ ]] || fail "G: Chromium never answered"
cat > "$TMPD/g.mjs" <<'PAGE'
const [port, base, sb, burl, perf] = process.argv.slice(2);
setTimeout(() => { console.log('FAIL the page check did not end in 240 s'); process.exit(2); }, 240000).unref();
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
// open(hash): a new document through about:blank, settled on its own hash (404green1d's race)
const blank = async () => { await cmd('Page.navigate', { url: 'about:blank' }); for (let i = 0; i < 50; i++) { if ((await ev('location.href')) === 'about:blank') return; await sleep(100); } throw new Error('about:blank never loaded'); };
const open = async hash => { await blank(); await cmd('Page.navigate', { url: base + '/' + hash });
  return until(`location.hash === ${JSON.stringify(hash)} && document.readyState === 'complete' && !!document.querySelector('main h2')`); };
const linkOk = `a => a.target === '_blank' && a.rel === 'noopener noreferrer' && (a.getAttribute('aria-label') || '').endsWith('(opens in a new tab)')`;
for (const theme of ['light', 'dark']) {
  await open(`#/mssql_waits?i=${sb}&w=1h`); await ev(`localStorage.setItem('pgvigil.theme', '${theme}')`);
  await open(`#/mssql_waits?i=${sb}&w=1h`);
  const sec = await until(`(() => { const h = [...document.querySelectorAll('main h3')].find(x => x.textContent.startsWith('Wait seconds per core per minute')); if (!h) return null;
    const box = h.parentElement; const tiles = [...box.querySelectorAll('.tile')].map(t => t.textContent); return { tiles, chart: !!box.querySelector('.chart canvas, .chart svg, .chart .uplot') }; })()`);
  check(`waits ${theme}`, !!sec && sec.tiles.length === 2 && sec.tiles.every(t => t.includes('s/core/min')) && sec.chart, sec ? `${sec.tiles.join(' / ')}, chart ${sec.chart}` : 'no section');
  const wl = await ev(`(() => { const as = [...document.querySelectorAll('main table.grid a.doclink')]; const ms = as.find(a => a.textContent === 'Microsoft'); const sk = as.find(a => a.textContent === 'SQLskills');
    const ok = ${linkOk}; return ms && sk ? { ms: ms.href, sk: sk.href, ok: ok(ms) && ok(sk), name: sk.getAttribute('aria-label') } : null; })()`);
  check(`waits ${theme}`, !!wl && wl.ok && wl.ms.includes('sys-dm-os-wait-stats-transact-sql') && /^https:\/\/www\.sqlskills\.com\/help\/waits\/[a-z0-9_]+$/.test(wl.sk),
    wl ? `${wl.sk} [${wl.name}]` : 'no wait type link');
}
await open(`#/mssqlerrorlog?i=${sb}&w=1h`);
const el = await until(`(() => { const a = [...document.querySelectorAll('main a.doclink')].find(x => x.href.endsWith('database-engine-events-and-errors-18000-to-18999')); return a ? a.parentElement.textContent : null; })()`);
check('error log', !!el && el.includes('18456'), el ?? 'no link to 18000-18999');
await open(`#/mssqlchecks?i=${sb}&cv=build`);
const bl = await until(`(() => { const a = [...document.querySelectorAll('main table.props a.doclink')][0]; return a ? { href: a.href, ok: (${linkOk})(a) } : null; })()`);
check('build', !!bl && bl.ok && bl.href === burl, bl ? bl.href : 'no build link');
await open(`#/perfsummary?w=1h`);
const pc = await until(`(() => { const t = [...document.querySelectorAll('main table.grid')].find(x => [...x.querySelectorAll('th')].some(h => h.textContent.trim() === 'wait s per core per minute')); if (!t) return null;
  const i = [...t.querySelectorAll('th')].findIndex(h => h.textContent.trim() === 'wait s per core per minute');
  return [...t.querySelectorAll('tbody tr')].map(r => r.children[i]?.textContent ?? '').join(' / '); })()`);
check('perf summary', pc != null && (perf === '-' ? pc.includes('not read') : pc.split(' / ').some(c => Math.abs(Number(c.replace(/,/g, '')) - Number(perf)) < 0.006)), pc ?? 'no column');
check('no exception', thrown.length === 0, thrown.slice(0, 3).join(' | ') || 'none');
process.exit(failed ? 1 : 0);
PAGE
PV=$(python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["mssql"]; rs=[dict(zip(t["columns"], r)) for r in t["rows"]]; v=[r.get("wait_s_core_min") for r in rs if r.get("instance_id")==int(sys.argv[2])]; print("-" if not v or v[0] is None else v[0])' "$TMPD/perf.json" "$SB")
node "$TMPD/g.mjs" "$CDP" "http://127.0.0.1:$PORT" "$SB" "$BURL" "$PV" || fail "G: the pages"
ok "G: the Waits page's section and links, the error log's range link, the build's link, the summary's column, light and dark"

echo "PROOF OK: waits per core and doc links (A B C D E F G)"
