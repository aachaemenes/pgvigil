#!/usr/bin/env bash
# Proof of task 402 (B4): the checks over SQL Server's performance counters - 0153's twenty fleet rules seeded OFF on
# the 'counters' metrics of 0152, the join file's metric_rule (a seeded rule colours the Metrics grid on or off, and
# notifies only when on), each rule switched on through an enabled instance rule, its condition provoked on a SQL
# Server container, alert_rules_run's state and finding read, the load stopped and the clear read.
# Needs: docker (mcr.microsoft.com/mssql/server images), go, psql, curl, python3, ss, and:
#   ADMIN_DSN       a superuser connection to a PostgreSQL sandbox in keyword form (default 'host=127.0.0.1 port=5432
#                   user=postgres dbname=postgres'); the proof makes its own repository database and drops it.
#   PGVIGIL_IMAGE   the SQL Server image (default 2022-latest).
#   PGVIGIL_WIRING  1 (default) applies scripts/proof-mssql-counters-wiring.patch (401's) when the tree lacks the
#                   counters' runner hook, then scripts/proof-mssql-counter-checks-wiring.patch (this task's) when the
#                   join file lacks the seeded rules' metric_rule; 0 = the tree as it is.
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment. Only the
# collection a step names runs (pgvigil collect -once). Each rule is judged with for_minutes 0 by an instance rule at
# the seeded thresholds (F20: the seeded fleet row is never edited), so a run stays short.
#
# Expected (written before the first run; red on 16240ee at A: '0 seeded rules', no 0153 there):
#  A. the seed (F22): after migrate, 20 rules at fleet scope, created_by 'pgvigil', client '0153 seed', enabled false,
#     their thresholds and for_minutes as the design's table; 20 alert_rule_log rows 'seed'; a second migrate adds
#     nothing (20 and 20); the page reads rule ended through import_alert_rule, then 0153 run again by hand: no new
#     page reads rule and no new log row (a metric that ever had a fleet rule is never seeded again).
#  B. the owner line (the join file's metric_rule): 60 logins between two reads: metric_grid's counters.logins_s row
#     carries the seed's rule_id, 2 and 5, a name ending '(off: colours only, no alert)', and metric_status
#     'critical'; alert_rules_run writes no state and no finding for counters.logins_s; a user's own fleet rule on
#     counters.latch_waits_s added and then switched off: metric_rule gives no row for it.
#  C. on by an instance rule (F20): an enabled instance rule on counters.logins_s at 2 / 5 for 0 minutes; the same
#     load: state critical, one alert_rule_findings row naming it, the grid's rule the instance's with metric_status
#     critical; two quiet reads: state ok and no finding; the seed keeps its rule_id and enabled false; GET
#     /api/alertrules?part=rules lists the seed with enabled false; GET /api/metrics?family=counters gives the seeded page
#     lookups row rule_enabled false, its name ending '(off: colours only, no alert)', no rule state (402 part A's S1).
#  D. each provoked check, judged as C at the seeded thresholds (warning or critical after the load, ok after two
#     quiet reads; from run chk11 the second quiet read 60 s after the first, the product's interval, and the window
#     named: batches and RPCs by program, statistics updates, scans and seeks per object; a clear held up by named
#     background prints 'NOT PROVEN clear: <names>' and the fire leg stays hard; held up with only pgvigil's own
#     batches in the window = red): errors_kill_s (3 at severity 20), lock_timeouts_gt0_s and lock_waits_s (6 probes at LOCK_TIMEOUT
#     200 behind a held lock), avg_lock_wait_ms (3 probes at LOCK_TIMEOUT 1500: over 1000 ms), compiles_per_100_batches
#     (20 distinct batches; the quiet reads 12 s apart, so the collector's own batches stay under the ratios' 1
#     batch/s floor), page_splits_per_100_batches (random-key inserts, 20 batches), full_scans_per_search (20
#     heap scans and 20 clustered index scans among 200 seeks; its two rates printed), page_lookups_per_batch (10 batches each counting dbo.big), readahead_pct and
#     page_reads_s (a cold scan of dbo.big after DBCC DROPCLEANBUFFERS; page reads by 1,500 cold random seeks),
#     page_writes_s (dbo.big rewritten, then CHECKPOINT, then 600 single-page writes each checkpointed),
#     lock_requests_s (6,000 HOLDLOCK row seeks in one batch), log_growths (database scope: 30,000 inserts
#     into pgvctr with a 1 MB log); recompiles_per_100_compiles (a procedure whose temp table changes shape each run)
#     printed as read, NOT PROVEN live if it stays under its warning.
#  E. not provokable on a box, the rule's path only: free_list_stalls_s, lazy_writes_s, buffer_cache_hit_pct,
#     ple_per_4gb, errors_offline_s - an instance rule with a threshold the newest point crosses fires (the point
#     printed); NOT PROVEN live at the seeded threshold.
#  D with the floors (FL6, the lead's 19:4x / 19:5x; red on fd7b9bb at G, on 3e745fa at G1): each floored check's load
#     reads at its floor or more (5 Batch Requests/s; 1 Full Scan/s), else it fails as too
#     small; its clear leg reads ok, or 'na' with no finding and the floors' words naming the input under its floor - a
#     hard clear either way, no NOT PROVEN for it (the CEIP windows read 'na').
#  G. the floors: G0 at every instance read of the run each floored metric's point has no value exactly when an input
#     of the same read is under its floor (0152's metric_floors), both sides seen; G1 an instance rule
#     on compiles_per_100_batches at the seed's thresholds, a read 20 s after the one before with nothing of the proof
#     running: the point has no value, batch_requests_s under 5, state 'na', no finding, the state's value the
#     batch_requests_s point and its threshold 5; G2 the same on full_scans_per_search (value and threshold those of
#     an input under its floor); G3 the transitions through the alert sender ('pgvigil alerts', a file drop, clear
#     delay 0) on compiles_per_100_batches: a rule that never fires (critical 1e6) reads ok after a load, na after a
#     quiet read, ok again after a load, and the drop holds no file of it (ok -> na and na -> ok silent); a rule that
#     fires on any value (critical 0) reads na after a quiet read (no file), critical after a load (ONE firing file:
#     na -> critical as from ok), na after a quiet read (no resolved file yet: 0059 waits for an ok collection), and
#     after one more read and pass ONE resolved file, and no more after another (critical -> na resolved with its
#     normal notification). From the floors' pass (20261114-212721-reviewer): GC alert_rule_state holds ONE check on
#     state and it names 'na' (red on fd7b9bb: no 'na'); G1 / G2 run without metric_floors, their quiet read 60 s
#     after the one before and gated on the raw counters (Batch Requests/sec under 5, Full Scans/sec under 1), so on
#     fd7b9bb they are red for the right reason (a point of 0 and 'ok', not a missing view); G4 the run break: a rule
#     warning above 0 for 3 minutes, three quiet reads 60 s apart (na) then a load: 'pending', no file (red on
#     3e745fa: the na points counted beyond, a 3-minute run, warning at once); G5 warning: a rule warning above 0 with
#     no critical, a quiet read (na, no file), a load (warning, ONE firing file), a quiet read (na), one more read and
#     pass (ONE resolved); G6 a flap held by the clear delay (a destination with clear_after 300): critical 0 for 0
#     minutes, a load (one firing), a quiet read (na), a load within 300 s (critical): one firing and no resolved -
#     one open alert (a rule of 0 minutes; with more minutes a flap resolves and fires again, docs/alerts.md).
#     G_FROM=G3 starts G at G3 (G0-G2 skipped; such a run ends PARTIAL). G1 also reads FL4 through the API: the grid's
#     compilations row has no current value, floor 5, unit 'batch requests', input counters.batch_requests_s; its
#     state row 'na' with the unit 'batch requests' (red without 402's patch: no such columns). NOT PROVEN here: the
#     pages' N/A words as drawn (metrics.ts, alert_rules.ts) and FL5's summary flag (no row reads them yet).
#  F. at the end every seeded row but the ended one keeps its rule_id, op, thresholds, for_minutes and enabled false
#     as read at A.
# NOT PROVEN HERE: free list stalls, lazy writes, a low hit ratio, a low page life expectancy and a database taken
#   offline at the seeded thresholds (no memory pressure or offline database on a box); SQL Server 2016, Managed
#   Instance, a Windows host.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMAGE=${PGVIGIL_IMAGE:-2022-latest}
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
LBL=pgvigil-proof=chk
PGDB=pgv_chk_$SUF; MON=pgv_kmon_$SUF; SQL=pgv-chk-$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=
SA_PW=$(pw); MON_PW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\nMSSQL_PID=Developer\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  docker ps -aq --filter "label=$LBL-$SUF" | xargs -r docker rm -f -v >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
for t in docker go psql curl python3 ss; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
if [[ "${PGVIGIL_WIRING:-1}" == 1 ]]; then
  if ! grep -q 'ListCollector' internal/mssql/mssql.go; then
    git apply scripts/proof-mssql-counters-wiring.patch 2>/dev/null || patch -p1 --forward < scripts/proof-mssql-counters-wiring.patch >/dev/null \
      || fail "401's wiring patch"
    echo "401's wiring applied to this copy"
  fi
  if [[ -f scripts/proof-mssql-counter-checks-wiring.patch ]] && ! grep -q "0153 seed" internal/repo/sql/0190_join_release2.sql; then
    git apply scripts/proof-mssql-counter-checks-wiring.patch 2>/dev/null || patch -p1 --forward < scripts/proof-mssql-counter-checks-wiring.patch >/dev/null \
      || fail "402's wiring patch"
    echo "402's wiring applied to this copy (0190: metric_rule)"
  fi
fi
freeport() { local lo=$1 hi=$2 p used
  used=$(ss -Htan) || fail "ss -Htan failed: the ports in use cannot be read"
  used=$(awk '{n = split($4, a, ":"); print a[n]}' <<<"$used" | sort -u)
  for _ in $(seq 1 50); do p=$((lo + RANDOM % (hi - lo + 1))); grep -qx "$p" <<<"$used" || { echo "$p"; return 0; }; done
  fail "no free port in $lo-$hi"
}
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout "${3:-180}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
sqb() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout "${3:-180}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
sqok() { local out; out=$(sqb "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
# bg <seconds> <T-SQL>: a session of its own in the background (a lock holder)
bg() { ( printf '%s\n' "$2" | timeout "$1" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -d pgvctr -i /dev/stdin' >/dev/null 2>&1 & ); }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
col() { for c in "$@"; do timeout 180 "$TMPD/pgvigil" collect -config "$CFG" -instance chkbox -once "$c" > "$TMPD/col-$c.out" 2>&1 \
  || { cat "$TMPD/col-$c.out" >&2; fail "collect $c"; }; done; }
rule() { pq "SELECT pgvigil.import_alert_rule(now(), '$1'::jsonb)"; }
run() { pq "SELECT count(*) FROM (SELECT pgvigil.alert_rules_run(now())) x" >/dev/null; }
state() { pq "SELECT state FROM pgvigil.alert_rule_state WHERE instance_id = $SB AND metric = 'counters.$1' AND database = ''"; }
findings() { pq "SELECT count(*) FROM pgvigil.alert_rule_findings WHERE instance_id = $SB AND detail LIKE '%): counters.$1 %'"; }
point() { pq "SELECT value FROM pgvigil.metric_points($SB, 'counters', now() - interval '10 minutes', now()) WHERE metric = '$1' ORDER BY at DESC LIMIT 1"; }

# the container, the database and its tables, the monitor login
docker run -d --name "$SQL" --label "$LBL-$SUF" --memory 6g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "mcr.microsoft.com/mssql/server:$IMAGE" >/dev/null
r=; for _ in $(seq 1 150); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" master 15 2>/dev/null || true); [[ "$r" == 1 ]] && break; sleep 2; done
[[ "$r" == 1 ]] || { docker logs --tail 20 "$SQL" >&2 2>&1 || true; fail "the $IMAGE container did not come up in 300 s"; }
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://'); [[ "$PORT_SQL" =~ ^[0-9]+$ ]] || fail "the host port [$PORT_SQL]"
sqok "the database" "CREATE DATABASE pgvctr ON (NAME = pgvctr, FILENAME = '/var/opt/mssql/data/pgvctr.mdf', SIZE = 64MB)
  LOG ON (NAME = pgvctr_log, FILENAME = '/var/opt/mssql/data/pgvctr_log.ldf', SIZE = 1MB, FILEGROWTH = 1MB);
  ALTER DATABASE pgvctr SET RECOVERY FULL;"
sqok "the full backup that starts the log chain" "BACKUP DATABASE pgvctr TO DISK = '/var/opt/mssql/data/pgvctr.bak' WITH INIT;"
sqok "the tables" "CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, v int NOT NULL DEFAULT 0, pad char(200) NOT NULL DEFAULT 'a');
  INSERT dbo.t (id) SELECT TOP (2000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) FROM sys.all_objects a CROSS JOIN sys.all_objects b;
  CREATE TABLE dbo.big (id int NOT NULL PRIMARY KEY, pad char(200) NOT NULL);
  INSERT dbo.big SELECT TOP (60000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)), 'b' FROM sys.all_objects a CROSS JOIN sys.all_objects b;
  CREATE TABLE dbo.h (id int NOT NULL, pad char(100) NOT NULL);
  INSERT dbo.h SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)), 'h' FROM sys.all_objects;
  CREATE TABLE dbo.sp (id uniqueidentifier NOT NULL PRIMARY KEY DEFAULT NEWID(), pad char(800) NOT NULL DEFAULT 'x');" pgvctr
sqok "the procedure" "GO
CREATE PROCEDURE dbo.rc AS BEGIN SET NOCOUNT ON; CREATE TABLE #r (a int); ALTER TABLE #r ADD b int;
  INSERT #r (a) SELECT TOP (10) object_id FROM sys.objects; SELECT COUNT(*) FROM #r; END" pgvctr
sqok "the monitor login" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF;
  GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON];"
export PGV_CHK_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"

go build -o "$TMPD/pgvigil" ./cmd/pgvigil
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="${ADMIN_DSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
CFG=$TMPD/m.yaml
printf 'repository:\n  dsn: "%s"\ninstances:\n  - name: chkbox\n    engine: sqlserver\n    dsn: env:PGV_CHK_MON\n' "$PGDSN" > "$CFG"

echo "== A. the seed =="
"$TMPD/pgvigil" migrate -config "$CFG" > "$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "A: migrate"; }
col mssql_instance mssql_counters mssql_counters_db
SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'chkbox'")
seeds() { pq "SELECT count(*) FROM pgvigil.alert_rules WHERE created_by = 'pgvigil' AND client = '0153 seed'"; }
slog() { pq "SELECT count(*) FROM pgvigil.alert_rule_log WHERE op = 'seed' AND client = '0153 seed'"; }
NS=$(seeds); [[ "$NS" == 20 ]] || fail "A: $NS seeded rules (want 20)"
pq "SELECT metric || '|' || rule_id || '|' || op || '|' || coalesce(warning::text, '') || '|' || coalesce(critical::text, '') || '|' || for_minutes || '|' || enabled || '|' || scope
      FROM pgvigil.alert_rules WHERE created_by = 'pgvigil' AND client = '0153 seed' ORDER BY metric" > "$TMPD/seed-a"
python3 - "$TMPD/seed-a" <<'PY' || fail "A: a seeded rule differs from the design's table"
import sys
want = {'full_scans_per_search': ('above', 0.001, 0.01, 15), 'compiles_per_100_batches': ('above', 10, 15, 15),
        'recompiles_per_100_compiles': ('above', 10, 15, 15), 'page_splits_per_100_batches': ('above', 20, 25, 15),
        'free_list_stalls_s': ('above', 2, 5, 5), 'lazy_writes_s': ('above', 20, 25, 5), 'page_reads_s': ('above', 90, 120, 15),
        'page_lookups_per_batch': ('above', 100, 120, 15), 'page_writes_s': ('above', 90, 120, 15),
        'avg_lock_wait_ms': ('above', 500, 1000, 15), 'lock_requests_s': ('above', 1000, 1200, 15),
        'lock_timeouts_gt0_s': ('above', 0, 1, 15), 'lock_waits_s': ('above', 0.1, 0.9995, 15), 'readahead_pct': ('above', 20, 25, 15),
        'buffer_cache_hit_pct': ('below', 90, None, 15), 'ple_per_4gb': ('below', 300, 200, 15), 'logins_s': ('above', 2, 5, 15),
        'errors_kill_s': ('above', 0, 1, 0), 'errors_offline_s': ('above', 0, 1, 0), 'log_growths': ('above', 0, None, 0)}
got, bad = {}, []
for l in open(sys.argv[1]):
    m, rid, op, w, c, f, en, sc = l.rstrip('\n').split('|')
    got[m.split('.', 1)[1]] = (op, float(w) if w else None, float(c) if c else None, int(f))
    if en != 'false' or sc != 'fleet': bad.append(f'{m} enabled {en} scope {sc}')   # a boolean in || reads 'false'
for k, v in want.items():
    if got.get(k) != v: bad.append(f'{k}: {got.get(k)} != {v}')
print(f'   {len(got)} seeded rules read; differences: {len(bad)}')
for b in bad: print('   FAIL ' + b)
sys.exit(1 if bad or len(got) != 20 else 0)
PY
NL=$(slog); [[ "$NL" == 20 ]] || fail "A: $NL seed log rows (want 20)"
"$TMPD/pgvigil" migrate -config "$CFG" > "$TMPD/migrate2.out" 2>&1 || { cat "$TMPD/migrate2.out" >&2; fail "A: the second migrate"; }
[[ "$(seeds)|$(slog)" == "20|20" ]] || fail "A: the second migrate: $(seeds) rules, $(slog) log rows"
PR=$(pq "SELECT rule_id FROM pgvigil.alert_rules WHERE metric = 'counters.page_reads_s' AND client = '0153 seed'")
rule "{\"op\":\"end\",\"ui_user\":\"proof402\",\"rule_id\":\"$PR\"}" | grep -q '"done"' || fail "A: ending the page reads rule"
psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -f internal/repo/sql/0153_mssql_counter_checks.sql >/dev/null || fail "A: 0153 run again by hand"
[[ "$(seeds)|$(slog)" == "20|20" && $(pq "SELECT count(*) FROM pgvigil.alert_rules WHERE metric = 'counters.page_reads_s' AND ended_at IS NULL") == 0 ]] \
  || fail "A: 0153 again after the end: $(seeds) rules, $(slog) log rows"
ok "A: 20 rules seeded off at fleet scope as the design's table, 20 log rows; a second migrate and 0153 again after an end add nothing"

# the provocations; each ends with nothing of its own still running
# 60 logins in one container session's loop (a docker exec per login is too slow to pass 5 a second)
p_logins() { timeout 120 docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'for i in $(seq 1 60); do SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -h -1 -Q "SET NOCOUNT ON; SELECT 1" >/dev/null; done'; }
p_kill() { for _ in 1 2 3; do sq "RAISERROR('pgvigil proof severe error', 20, 1) WITH LOG;" >/dev/null 2>&1 || true; done; }
p_timeouts() { bg 20 "BEGIN TRAN; UPDATE dbo.t SET v = v + 1 WHERE id = 1; WAITFOR DELAY '00:00:05'; ROLLBACK;"; sleep 1.5
  for _ in $(seq 1 6); do sq "SET LOCK_TIMEOUT 200; SELECT v FROM dbo.t WHERE id = 1;" pgvctr >/dev/null 2>&1 || true; done; sleep 3; }
p_longwait() { bg 20 "BEGIN TRAN; UPDATE dbo.t SET v = v + 1 WHERE id = 1; WAITFOR DELAY '00:00:07'; ROLLBACK;"; sleep 1.5
  for _ in 1 2 3; do sq "SET LOCK_TIMEOUT 1500; SELECT v FROM dbo.t WHERE id = 1;" pgvctr >/dev/null 2>&1 || true; done; sleep 2; }
p_compiles() { sq "$(for i in $(seq 1 60); do echo "SELECT COUNT(*) FROM dbo.t WHERE v >= 0 AND id <> $((RANDOM * 100 + i));"; echo GO; done)" pgvctr >/dev/null; }
p_splits() { sq "$(for _ in $(seq 1 40); do echo "INSERT dbo.sp (pad) SELECT TOP (400) 'x' FROM sys.all_objects;"; echo GO; done)" pgvctr >/dev/null; }
p_scans() { sq "DECLARE @i int = 0, @x int; WHILE @i < 200 BEGIN SELECT @x = v FROM dbo.t WHERE id = @i + 1; SET @i += 1; END;
  $(for _ in $(seq 1 20); do echo "SELECT @x = COUNT(*) FROM dbo.h; SELECT @x = COUNT(*) FROM dbo.big;"; done)" pgvctr >/dev/null; }
# the inputs of a ratio at the newest instance read: object|counter|rate per second
rates() { pq "SELECT string_agg(v.counter || ' ' || coalesce(round(v.rate::numeric, 2)::text, 'no rate'), ', ' ORDER BY v.counter)
  FROM pgvigil.mssql_counter_values($SB, (SELECT max(snapshot_at) FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance') - interval '1 second', now(), 'instance') v
  WHERE v.object = '$1' AND v.counter IN ($2) AND v.inst = '_Total'"; }
p_lookups() { sq "$(for _ in $(seq 1 20); do echo "SELECT COUNT(*) FROM dbo.big;"; echo GO; echo "SELECT 1;"; echo GO; done)" pgvctr >/dev/null; }
p_cold() { sq "CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;" pgvctr >/dev/null; sq "SELECT COUNT(*) FROM dbo.big WHERE pad <> 'z';" pgvctr >/dev/null; }
# cold single-page reads: 1,500 random seeks after DROPCLEANBUFFERS (one page an I/O, whether the counter counts pages or I/Os)
p_coldseek() { sq "CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;" pgvctr >/dev/null
  sq "DECLARE @i int = 0, @x int; WHILE @i < 1500 BEGIN SELECT @x = LEN(pad) FROM dbo.big WHERE id = ABS(CHECKSUM(NEWID())) % 60000 + 1; SET @i += 1; END" pgvctr >/dev/null; }
# every page of dbo.big rewritten and checkpointed, then 600 single-page writes each with its CHECKPOINT
p_writes() { sq "UPDATE dbo.big SET pad = REPLICATE(CHAR(65 + ABS(CHECKSUM(NEWID())) % 26), 200); CHECKPOINT;" pgvctr >/dev/null
  sq "DECLARE @i int = 0; WHILE @i < 600 BEGIN UPDATE dbo.big SET pad = 'w' WHERE id = ABS(CHECKSUM(NEWID())) % 60000 + 1; CHECKPOINT; SET @i += 1; END" pgvctr >/dev/null; }
p_lockreq() { sq "DECLARE @i int = 0, @x int; WHILE @i < 6000 BEGIN SELECT @x = v FROM dbo.t WITH (ROWLOCK, HOLDLOCK) WHERE id = @i % 2000 + 1; SET @i += 1; END" pgvctr >/dev/null; }
p_recompiles() { sq "$(for _ in $(seq 1 20); do echo "EXEC dbo.rc;"; echo GO; done)" pgvctr >/dev/null; }
# the log is shrunk to a few MB first: D's earlier loads leave it larger than this one transaction (run chk11 read no
# growth with a 36 MB log; chk12, those checks skipped, read +5). The full backup at the setup started the log chain, so
# only a log backup frees it (chk13's CHECKPOINT and shrink left 77 MB): a log backup and a shrink, twice; a log over
# 4 MB after them fails here, so the check never passes on the log's own history
p_growth() { sq "BACKUP LOG pgvctr TO DISK = N'/var/opt/mssql/data/pgvctr_log.trn' WITH INIT; DBCC SHRINKFILE (pgvctr_log, 1) WITH NO_INFOMSGS;
BACKUP LOG pgvctr TO DISK = N'/var/opt/mssql/data/pgvctr_log.trn' WITH INIT; DBCC SHRINKFILE (pgvctr_log, 1) WITH NO_INFOMSGS;" pgvctr >/dev/null
  local mb; mb=$(sq "SELECT CAST(size / 128 AS varchar(10)) FROM sys.database_files WHERE type = 1" pgvctr | tr -d '[:space:]')
  echo "   pgvctr's log before the load: $mb MB"
  [[ "$mb" =~ ^[0-9]+$ && "$mb" -le 4 ]] || fail "D: log_growths: the shrink left pgvctr's log at [$mb] MB"
  sq "INSERT dbo.t (id, pad) SELECT TOP (30000) 200000 + ROW_NUMBER() OVER (ORDER BY (SELECT 1)) + (SELECT count(*) FROM dbo.t), REPLICATE('g', 200) FROM sys.all_objects a CROSS JOIN sys.all_objects b" pgvctr >/dev/null; }

echo "== B. the owner line: a seeded rule colours while off and raises nothing =="
LS=$(pq "SELECT rule_id FROM pgvigil.alert_rules WHERE metric = 'counters.logins_s' AND client = '0153 seed'")
col mssql_counters; p_logins; col mssql_counters; run
G=$(pq "SELECT g.rule_id || '|' || g.warning || '|' || g.critical || '|' || g.rule_name || '|' || coalesce(pgvigil.metric_status(g.op, g.current_value, g.warning, g.critical), 'none') || '|' || round(g.current_value::numeric, 2)
          FROM pgvigil.metric_grid($SB, now() - interval '10 minutes', now(), interval '15 minutes', NULL, 'counters') g WHERE g.key = 'counters.logins_s'")
echo "   grid counters.logins_s: $G"
[[ "$G" == "$LS|2|5|SQL Server: logins (off: colours only, no alert)|critical|"* ]] || fail "B: the grid row [$G]"
[[ -z "$(state logins_s)" && "$(findings logins_s)" == 0 ]] || fail "B: an off rule raised [$(state logins_s)] $(findings logins_s)"
U=$(rule '{"op":"add","ui_user":"proof402","metric":"counters.latch_waits_s","op_dir":"above","scope":"fleet","warning":0,"for_minutes":0}')
UID_=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["rule_id"])' "$U")
rule "{\"op\":\"disable\",\"ui_user\":\"proof402\",\"rule_id\":\"$UID_\"}" | grep -q '"done"' || fail "B: switching the user's rule off"
[[ $(pq "SELECT count(*) FROM pgvigil.metric_rule($SB, 'counters.latch_waits_s')") == 0 ]] || fail "B: a user's own off rule colours"
rule "{\"op\":\"end\",\"ui_user\":\"proof402\",\"rule_id\":\"$UID_\"}" >/dev/null
ok "B: the grid colours counters.logins_s critical by the seeded rule while it is off, its name says so; no state, no finding; a user's own off rule colours nothing"

echo "== C. on by an instance rule (F20) =="
# judge <metric> <provoke> [collection]: an enabled instance rule at the seed's thresholds for 0 minutes; a read, the
# load, a read, the run (warning or critical); two quiet reads, the run (ok); the instance rule ended
SEEDOF() { grep "^counters.$1|" "$TMPD/seed-a"; }
# the quiet reads' spacing: the rule judges the newest point, so the first quiet read comes 2 s after the load's (it
# takes what SQL Server publishes late) and the second QUIET s after it, the product's own 60 s interval (the lead's
# 19:0x: runs chk3, chk9 and chk10 at 3, 12 and 30 s read the collector's own batches and an unnamed background over
# the ratios' thresholds).
QUIET=${QUIET:-60}
# the clear leg's window (between the scope's two newest reads) is named: every batch and RPC by program and the
# automatic statistics updates (the XE session pgv_chk_diag, started before the first quiet read), and the scans and
# seeks per object, user and system (sys.dm_db_index_usage_stats before the first quiet read and after the second).
# The collector's own batches carry the program 'pgvigil'. A clear held up by NAMED background (a program but pgvigil,
# an automatic statistics update, or a user object scanned or sought) prints 'NOT PROVEN clear: <names>'; the fire
# leg stays a hard check; a clear held up with nothing but pgvigil's own in the window is red.
usage() { sq "SELECT DB_NAME(u.database_id) + '|' + ISNULL(OBJECT_NAME(u.object_id, u.database_id), CAST(u.object_id AS varchar(12))) + '|' + CAST(u.index_id AS varchar(6))
  + '|' + CAST(u.user_scans AS varchar(20)) + '|' + CAST(u.user_seeks AS varchar(20)) + '|' + CAST(u.system_scans AS varchar(20)) + '|' + CAST(u.system_seeks AS varchar(20))
  FROM sys.dm_db_index_usage_stats u" > "$1"; }
diag_on() {
  sqok "the diagnostic XE session" "IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'pgv_chk_diag') DROP EVENT SESSION pgv_chk_diag ON SERVER;
CREATE EVENT SESSION pgv_chk_diag ON SERVER
  ADD EVENT sqlserver.sql_batch_completed (ACTION (sqlserver.client_app_name)),
  ADD EVENT sqlserver.rpc_completed (ACTION (sqlserver.client_app_name)),
  ADD EVENT sqlserver.auto_stats (ACTION (sqlserver.client_app_name))
  ADD TARGET package0.ring_buffer (SET max_memory = 16384) WITH (MAX_DISPATCH_LATENCY = 1 SECONDS);
ALTER EVENT SESSION pgv_chk_diag ON SERVER STATE = START;"
  usage "$TMPD/usage-a"; }
# diag_read <scope>: prints the window's names; DIAG_OTHER holds the named background ('' = pgvigil's own only)
diag_read() {
  local w a b
  w=$(pq "SELECT string_agg(to_char(server_utc AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US'), ' ' ORDER BY server_utc)
    FROM (SELECT server_utc FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = '$1' ORDER BY snapshot_at DESC LIMIT 2) r")
  read -r a b <<<"$w"
  usage "$TMPD/usage-b"
  sq "DECLARE @x xml = (SELECT CAST(t.target_data AS xml) FROM sys.dm_xe_session_targets t JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address
                     WHERE s.name = N'pgv_chk_diag' AND t.target_name = N'ring_buffer');
SELECT 'xe|' + e.n + '|' + ISNULL(NULLIF(e.app, N''), N'(no program)') + '|' + CAST(COUNT(*) AS varchar(10)) + '|' + CAST(SUM(ISNULL(e.lr, 0)) AS varchar(20))
  FROM (SELECT v.value('@name', 'nvarchar(60)') AS n, v.value('@timestamp', 'datetime2') AS ts,
               v.value('(action[@name=\"client_app_name\"]/value)[1]', 'nvarchar(256)') AS app,
               v.value('(data[@name=\"logical_reads\"]/value)[1]', 'bigint') AS lr
          FROM @x.nodes('/RingBufferTarget/event') x(v)) e
 WHERE e.ts > '$a' AND e.ts <= '$b'
 GROUP BY e.n, e.app;
DROP EVENT SESSION pgv_chk_diag ON SERVER;" > "$TMPD/xe-w" 2>&1
  python3 - "$TMPD/usage-a" "$TMPD/usage-b" "$TMPD/xe-w" "$a" "$b" > "$TMPD/diag-w" <<'PY'
import sys
def rows(p):
    out = {}
    for l in open(p):
        f = l.strip().split('|')
        if len(f) == 7 and all(x.isdigit() for x in f[3:]):
            out[tuple(f[:3])] = [int(x) for x in f[3:]]
    return out
a, b = rows(sys.argv[1]), rows(sys.argv[2])
other = []
print(f'      the window {sys.argv[4]} .. {sys.argv[5]} UTC:')
xe = [l.strip().split('|') for l in open(sys.argv[3]) if l.startswith('xe|')]
for _, n, app, c, lr in sorted(xe, key=lambda r: -int(r[3])):
    own = app == 'pgvigil'
    tag = " (the collector's own)" if own else ""
    print(f"      {n} by {app}{tag}: {c} events, {lr} logical reads")
    if not own:
        other.append(f'{app} ({n} x{c})')
if not xe:
    said = ' '.join(l.strip() for l in open(sys.argv[3]) if l.strip())[:300]
    print('      no batch, RPC or statistics update in the window' + (f' (the read said: {said})' if said else ''))
moved = []
for k, v in b.items():
    d = [x - y for x, y in zip(v, a.get(k, [0, 0, 0, 0]))]
    if any(d):
        moved.append((sum(d), k, d))
for _, k, d in sorted(moved, reverse=True)[:8]:
    print(f'      {k[0]}.{k[1]} index {k[2]}: user scans +{d[0]} seeks +{d[1]}, system scans +{d[2]} seeks +{d[3]} (over both quiet reads)')
    if (d[0] or d[1]) and k[0] not in ('master', 'msdb', 'model', 'tempdb'):
        other.append(f'{k[0]}.{k[1]} user scans +{d[0]} seeks +{d[1]}')
print('OTHER=' + '; '.join(other))
PY
  grep -v '^OTHER=' "$TMPD/diag-w"
  DIAG_OTHER=$(sed -n 's/^OTHER=//p' "$TMPD/diag-w")
}
# D_FROM=<metric>: a diagnostic run starts D at that check (the checks before it skipped); such a run ends 'PARTIAL', never
# 'PROOF OK'
D_FROM=${D_FROM:-}; D_REACHED=0
# the floors (FL6): HAVE_FLOORS when 0152 holds metric_floors (fd7b9bb does not: D runs as before, G is red)
HAVE_FLOORS=$(pq "SELECT to_regclass('pgvigil.metric_floors') IS NOT NULL")
# floored <metric>: each floor of the metric with its input's point at the metric's newest read ('' = no floor)
floored() { [[ "$HAVE_FLOORS" == t ]] || return 0
  pq "WITH p AS (SELECT x.at, x.metric, x.value FROM pgvigil.metric_points($SB, 'counters', now() - interval '10 minutes', now()) x),
  n AS (SELECT max(p.at) AS at FROM p WHERE p.metric = '$1')
  SELECT string_agg(f.unit || ' ' || coalesce(pgvigil.metric_num(i.value), 'none') || '/s (floor ' || pgvigil.metric_num(f.floor) || '/s'
                    || CASE WHEN i.value IS NULL OR i.value < f.floor THEN ': under it)' ELSE ')' END, ', ' ORDER BY f.unit)
    FROM pgvigil.metric_floors f CROSS JOIN n LEFT JOIN p i ON i.metric = split_part(f.input_key, '.', 2) AND i.at = n.at
   WHERE f.key = 'counters.$1'"; }
judge() {
  local m=$1 fn=$2 c=${3:-mssql_counters} s op w cr rid st1 st2 f1 f2 v v2 fl fl2
  if [[ -n "$D_FROM" && $D_REACHED == 0 && "$m" != logins_s ]]; then
    if [[ "$m" == "$D_FROM" ]]; then D_REACHED=1; else echo "   $m skipped (D_FROM=$D_FROM)"; CLEARED=1; return 0; fi
  fi
  s=$(SEEDOF "$m"); op=$(cut -d'|' -f3 <<<"$s"); w=$(cut -d'|' -f4 <<<"$s"); cr=$(cut -d'|' -f5 <<<"$s")
  rid=$(rule "{\"op\":\"add\",\"ui_user\":\"proof402\",\"metric\":\"counters.$m\",\"op_dir\":\"$op\",\"scope\":\"instance\",\"instance_name\":\"chkbox\",\"warning\":${w:-null},\"critical\":${cr:-null},\"for_minutes\":0}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["rule_id"] if d["outcome"] == "done" else "")')
  [[ -n "$rid" ]] || fail "$m: the instance rule was refused"
  # the read after the load waits 2 s: SQL Server publishes some counters a moment after the statement ends (run chk5
  # read a ratio's full scans and its index searches in two reads 0.3 s apart)
  col "$c"; $fn; sleep 2; col "$c"; run; st1=$(state "$m"); f1=$(findings "$m"); v=$(point "$m"); fl=$(floored "$m")
  [[ -n "${4:-}" ]] && echo "   $m's inputs at that read: $($4)"
  [[ -n "$fl" ]] && echo "   $m's floors at that read: $fl"
  local scope=instance; [[ "$c" == mssql_counters_db ]] && scope=database
  sleep 2; diag_on; col "$c"; sleep "$QUIET"; col "$c"; diag_read "$scope"; run; st2=$(state "$m"); f2=$(findings "$m"); v2=$(point "$m")
  fl2=$(floored "$m")
  [[ -n "${4:-}" ]] && echo "   $m's inputs after the quiet reads: $($4)"
  [[ -n "$fl2" ]] && echo "   $m's floors after the quiet reads: $fl2"
  rule "{\"op\":\"end\",\"ui_user\":\"proof402\",\"rule_id\":\"$rid\"}" >/dev/null
  echo "   $m ($op ${w:-} / ${cr:-}): $v after the load -> $st1 ($f1 finding); quiet ($v2) -> $st2 ($f2)"
  if [[ "$fl" == *"under it"* ]]; then echo "   $m: the load's read is under a floor ($fl): the load is too small to judge it"; return 1; fi
  [[ ( "$st1" == warning || "$st1" == critical ) && "$f1" == 1 ]] || return 1
  CLEARED=1; [[ "$st2" == ok && "$f2" == 0 ]] && return 0
  # FL3: under a floor the check is not judged ('na', no finding): a hard clear, the window's background named above
  [[ -n "$fl2" && "$st2" == na && "$f2" == 0 && "$fl2" == *"under it"* ]] && return 0
  CLEARED=0
  if [[ -z "$fl2" && -n "$DIAG_OTHER" ]]; then echo "NOT PROVEN clear: $m stayed $st2 at $v2 with named background in the window: $DIAG_OTHER"; return 0; fi
  return 1
}
judge logins_s p_logins && [[ $CLEARED == 1 ]] || fail "C: logins_s (fire and clear both hard here)"
[[ $(pq "SELECT rule_id || '|' || enabled FROM pgvigil.alert_rules WHERE metric = 'counters.logins_s' AND client = '0153 seed' AND ended_at IS NULL") == "$LS|false" ]] \
  || fail "C: the seeded logins rule changed"
PORT=$(freeport 29000 32499)
"$TMPD/pgvigil" serve -config "$CFG" -listen "127.0.0.1:$PORT" -no-login > "$TMPD/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 60); do grep -q "url=http://127.0.0.1:$PORT/" "$TMPD/serve.log" 2>/dev/null && break; sleep 0.5; done
curl -fs -m 20 "http://127.0.0.1:$PORT/api/alertrules?part=rules" > "$TMPD/rules.json" || fail "C: GET /api/alertrules: $(tail -3 "$TMPD/serve.log")"
python3 - "$TMPD/rules.json" "$LS" <<'PY' || fail "C: the Alert rules API's seeded row"
import json, sys
t = json.load(open(sys.argv[1]))['rules']; rows = [dict(zip(t['columns'], r)) for r in t['rows']]
r = [x for x in rows if str(x.get('rule_id')) == sys.argv[2]]
print(f"   /api/alertrules: rule {sys.argv[2]} enabled {r[0].get('enabled') if r else 'no row'}")
sys.exit(0 if r and r[0].get('enabled') is False else 1)
PY
ok "C: on by an instance rule: critical with its finding, ok after two quiet reads; the seed kept its rule_id and stays off (the API says so)"
# the review's S1 (402 part A): the grid says a seeded rule is off, never 'not judged yet' (the wiring's q_metrics.go
# rule_enabled; metrics.ts writes 'off: colours only, no alert' in the rule cell)
curl -fs -m 20 "http://127.0.0.1:$PORT/api/metrics?instance=$SB&family=counters" > "$TMPD/grid.json" || fail "C: GET /api/metrics: $(tail -3 "$TMPD/serve.log")"
python3 - "$TMPD/grid.json" <<'PY2' || fail "C: the grid's off seed"
import json, sys
t = json.load(open(sys.argv[1]))['grid']; rows = [dict(zip(t['columns'], r)) for r in t['rows']]
r = [x for x in rows if x.get('key') == 'counters.page_lookups_per_batch' and x.get('database') in (None, '')]
got = (r[0].get('rule_enabled'), str(r[0].get('rule_name', '')).endswith('(off: colours only, no alert)'), r[0].get('rule_state')) if r else None
print(f"   the grid's page lookups row: rule_enabled, the name says off, the state: {got}")
sys.exit(0 if got == (False, True, None) else 1)
PY2
ok "C: the grid marks the seeded page lookups rule off (rule_enabled false, its name says so, no state)"

echo "== D. each provoked check =="
judge errors_kill_s p_kill || fail "D: errors_kill_s"
judge lock_timeouts_gt0_s p_timeouts || fail "D: lock_timeouts_gt0_s"
judge lock_waits_s p_timeouts || fail "D: lock_waits_s"
judge avg_lock_wait_ms p_longwait || fail "D: avg_lock_wait_ms"
judge compiles_per_100_batches p_compiles || fail "D: compiles_per_100_batches"
judge page_splits_per_100_batches p_splits || fail "D: page_splits_per_100_batches"
# perread <'object', ...> <'counter', ...> <metric>: each listed series of the newest three instance reads (value, change,
# rate) and the metric's points: which read holds which input of a ratio
perread() { echo; pq "SELECT '      ' || r.snapshot_at || ' ' || k.counter || ' [' || k.inst || '] value ' || s.value || ' change ' || coalesce(s.dvalue::text, '-') || ' rate ' || coalesce(s.rate::text, '-')
  FROM (SELECT * FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance' ORDER BY snapshot_at DESC LIMIT 3) r
  JOIN pgvigil.mssql_counter_sample s ON s.instance_id = $SB AND s.snapshot_at = r.snapshot_at
  JOIN pgvigil.mssql_counter_series k ON k.series_id = s.series_id AND k.object IN ($1) AND k.counter IN ($2)
  ORDER BY r.snapshot_at DESC, k.counter, k.inst"
  pq "SELECT '      point ' || at || ' ' || value FROM pgvigil.metric_points($SB, 'counters', now() - interval '2 minutes', now()) WHERE metric = '$3' ORDER BY at DESC LIMIT 3"; }
d_scans() { perread "'Access Methods'" "'Full Scans/sec', 'Index Searches/sec'" full_scans_per_search; }
d_ahead() { perread "'Buffer Manager'" "'Page reads/sec', 'Readahead pages/sec'" readahead_pct; }
d_lookups() { perread "'Buffer Manager', 'SQL Statistics'" "'Page lookups/sec', 'Batch Requests/sec'" page_lookups_per_batch; }
d_lockreq() { perread "'Locks'" "'Lock Requests/sec'" lock_requests_s | grep -E '\[_Total\]|point'; }
# d_growths: Log Growths of _Total and pgvctr at the newest three database reads (stored, or named in zero_series), the
# metric's points, and SQL Server's own read now with pgvctr's log size
d_growths() { echo; pq "SELECT '      ' || r.snapshot_at || ' Log Growths [' || k.inst || '] value ' || coalesce(s.value::text, CASE WHEN k.series_id = ANY (r.zero_series) THEN '0 (zero_series)' ELSE '-' END) || ' change ' || coalesce(s.dvalue::text, '-')
  FROM (SELECT * FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'database' ORDER BY snapshot_at DESC LIMIT 3) r
  JOIN pgvigil.mssql_counter_series k ON k.instance_id = $SB AND k.object = 'Databases' AND k.counter = 'Log Growths' AND k.inst IN ('_Total', 'pgvctr')
  LEFT JOIN pgvigil.mssql_counter_sample s ON s.instance_id = $SB AND s.series_id = k.series_id AND s.snapshot_at = r.snapshot_at
  ORDER BY r.snapshot_at DESC, k.inst"
  pq "SELECT '      point ' || at || ' ' || value FROM pgvigil.metric_points($SB, 'counters', now() - interval '10 minutes', now()) WHERE metric = 'log_growths' ORDER BY at DESC LIMIT 3"
  sq "SELECT '      SQL Server now: Log Growths [' + RTRIM(instance_name) + '] ' + CAST(cntr_value AS varchar(20)) FROM sys.dm_os_performance_counters WHERE RTRIM(counter_name) = N'Log Growths' AND RTRIM(instance_name) IN (N'_Total', N'pgvctr', N'master', N'tempdb');
SELECT '      pgvctr log ' + CAST(size / 128 AS varchar(10)) + ' MB, growth ' + CAST(growth AS varchar(10)) + CASE WHEN is_percent_growth = 1 THEN ' %' ELSE ' pages' END FROM pgvctr.sys.database_files WHERE type = 1;"; }
judge full_scans_per_search p_scans mssql_counters d_scans || fail "D: full_scans_per_search"
judge page_lookups_per_batch p_lookups mssql_counters d_lookups || fail "D: page_lookups_per_batch"
judge readahead_pct p_cold mssql_counters d_ahead || fail "D: readahead_pct"
judge page_reads_s p_coldseek || fail "D: page_reads_s"
judge page_writes_s p_writes || fail "D: page_writes_s"
judge lock_requests_s p_lockreq mssql_counters d_lockreq || fail "D: lock_requests_s"
judge log_growths p_growth mssql_counters_db d_growths || fail "D: log_growths"
if judge recompiles_per_100_compiles p_recompiles; then ok "D: recompiles_per_100_compiles fired and cleared"
else echo "NOT PROVEN live: recompiles_per_100_compiles did not reach its warning with a procedure whose temp table changes shape (the line above)"; fi
ok "D: thirteen provoked checks fired at their seeded thresholds; each cleared after two quiet reads 60 s apart, or its clear is NOT PROVEN above with the background named"

echo "== E. not provokable on a box: the rule's path =="
for m in free_list_stalls_s lazy_writes_s buffer_cache_hit_pct ple_per_4gb errors_offline_s; do
  col mssql_counters; col mssql_counters; v=$(point "$m"); [[ -n "$v" ]] || fail "E: no point for $m"
  op=$(SEEDOF "$m" | cut -d'|' -f3)
  th=$(python3 -c "import sys; v=float(sys.argv[1]); print(v - 1 if sys.argv[2] == 'above' else v + 1)" "$v" "$op")
  rid=$(rule "{\"op\":\"add\",\"ui_user\":\"proof402\",\"metric\":\"counters.$m\",\"op_dir\":\"$op\",\"scope\":\"instance\",\"instance_name\":\"chkbox\",\"warning\":$th,\"for_minutes\":0}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["rule_id"] if d["outcome"] == "done" else "")')
  [[ -n "$rid" ]] || fail "E: the instance rule on $m was refused"
  run; st=$(state "$m"); rule "{\"op\":\"end\",\"ui_user\":\"proof402\",\"rule_id\":\"$rid\"}" >/dev/null
  echo "   $m: the newest point $v, an instance rule $op $th -> $st"
  [[ "$st" == warning ]] || fail "E: $m [$st]"
done
ok "E: free list stalls, lazy writes, hit ratio, page life expectancy per 4 GB, offline errors: each metric reaches its rule (NOT PROVEN live at the seeded thresholds)"

echo "== G. the floors: not judged under a floor (FL6) =="
G_FROM=${G_FROM:-}
# GC: one CHECK on alert_rule_state.state, naming 'na' (a DROP CONSTRAINT IF EXISTS of a wrong name passes silently)
GC=$(pq "SELECT count(*) || '|' || coalesce(bool_and(pg_get_constraintdef(oid) LIKE '%''na''%'), false) FROM pg_constraint
  WHERE conrelid = 'pgvigil.alert_rule_state'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%state%'")
[[ "$GC" == "1|t" ]] || fail "GC: alert_rule_state's checks on state [$GC] (want one, naming 'na')"
ok "GC: one check on alert_rule_state.state, 'na' in it"
# instance rule helpers: on <metric> <warning> <critical> -> rule_id; off <rule_id>
on() { rule "{\"op\":\"add\",\"ui_user\":\"proof402\",\"metric\":\"counters.$1\",\"op_dir\":\"above\",\"scope\":\"instance\",\"instance_name\":\"chkbox\",\"warning\":$2,\"critical\":$3,\"for_minutes\":0}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["rule_id"] if d["outcome"] == "done" else "")'; }
off() { rule "{\"op\":\"end\",\"ui_user\":\"proof402\",\"rule_id\":\"$1\"}" >/dev/null; }
vt() { pq "SELECT coalesce(pgvigil.metric_num(value), 'NULL') || '|' || coalesce(pgvigil.metric_num(threshold), 'NULL') FROM pgvigil.alert_rule_state
  WHERE instance_id = $SB AND metric = 'counters.$1' AND database = ''"; }
newest() { pq "SELECT coalesce(pgvigil.metric_num(value), 'NULL') FROM pgvigil.metric_points($SB, 'counters', now() - interval '10 minutes', now()) WHERE metric = '$1' ORDER BY at DESC LIMIT 1"; }
quiet() { sleep 60; col mssql_counters; }
# the raw rate of a counter at the newest instance read (no metric of 0152 needed: G1 / G2 are red on fd7b9bb too)
raw() { rates "$1" "'$2'" | awk '{print $NF}'; }
if [[ -z "$G_FROM" ]]; then
# G0: 0152's no-value points against 0152's floors over every instance read of the run
[[ "$HAVE_FLOORS" == t ]] || fail "G0: no pgvigil.metric_floors (FL1 not in this tree)"
G0=$(pq "WITH p AS (SELECT x.at, x.metric, x.value FROM pgvigil.metric_points($SB, 'counters', now() - interval '3 hours', now()) x),
  j AS (SELECT f.key, r.at, r.value, bool_or(i.value < f.floor) AS under, count(i.value) AS inputs, count(*) AS floors
          FROM pgvigil.metric_floors f JOIN p r ON r.metric = split_part(f.key, '.', 2)
          LEFT JOIN p i ON i.metric = split_part(f.input_key, '.', 2) AND i.at = r.at
         GROUP BY f.key, r.at, r.value)
  SELECT count(*) FILTER (WHERE j.inputs < j.floors OR (j.value IS NULL) <> coalesce(j.under, false)) || '|' || count(*) || '|' || count(*) FILTER (WHERE j.under) FROM j")
[[ "$(cut -d'|' -f1 <<<"$G0")" == 0 && "$(cut -d'|' -f3 <<<"$G0")" -gt 0 && "$(cut -d'|' -f3 <<<"$G0")" -lt "$(cut -d'|' -f2 <<<"$G0")" ]] \
  || fail "G0: floored points against metric_floors [$G0] (want 0 differences | points | under a floor, both sides seen)"
ok "G0: at each of $(cut -d'|' -f2 <<<"$G0") floored points the value is missing exactly when an input of the same read is under its floor ($(cut -d'|' -f3 <<<"$G0") under)"
# G1, G2: one quiet read under each floor
for m in compiles_per_100_batches full_scans_per_search; do
  s=$(SEEDOF "$m"); rid=$(on "$m" "$(cut -d'|' -f4 <<<"$s")" "$(cut -d'|' -f5 <<<"$s")"); [[ -n "$rid" ]] || fail "G: the instance rule on $m was refused"
  col mssql_counters; quiet; run
  st=$(state "$m"); f=$(findings "$m"); fl=$(floored "$m"); p=$(newest "$m"); got=$(vt "$m")
  b=$(newest batch_requests_s); fs=$(newest full_scans_s)
  rb=$(raw 'SQL Statistics' 'Batch Requests/sec'); rf=$(raw 'Access Methods' 'Full Scans/sec')
  off "$rid"
  echo "   $m after a quiet read: point $p, state $st, $f finding(s), value|threshold $got; raw batches $rb/s, full scans $rf/s"
  if [[ "$m" == compiles_per_100_batches ]]; then under=$(python3 -c "import sys; print('y' if float(sys.argv[1]) < 5 else '')" "${rb:-99}"); want="$b|5"
  else under=$(python3 -c "import sys; print('y' if float(sys.argv[1]) < 1 else '')" "${rf:-99}"); want="$fs|1"; fi
  [[ -n "$under" ]] || fail "G: $m: the quiet read is over its floor (batches $rb/s, full scans $rf/s): something ran in the window"
  ok1=$([[ "$got" == "$want" ]] && echo y)
  [[ "$p" == NULL && "$st" == na && "$f" == 0 && -n "$ok1" ]] || fail "G: $m under its floor: point $p (want NULL), state $st (want na), $f finding(s) (want 0), value|threshold $got (want $want)"
  # FL4 (the wiring's q_metrics.go and q_alert_rules.go): the grid row carries its floor, the state row its floor's unit
  if [[ "$m" == compiles_per_100_batches ]]; then
    curl -fs -m 20 "http://127.0.0.1:$PORT/api/metrics?instance=$SB&family=counters" > "$TMPD/g1grid.json" || fail "G1: GET /api/metrics"
    curl -fs -m 20 "http://127.0.0.1:$PORT/api/alertrules?part=state" > "$TMPD/g1state.json" || fail "G1: GET /api/alertrules?part=state"
    python3 - "$TMPD/g1grid.json" "$TMPD/g1state.json" <<'PY2' || fail "G1: the pages' floor words (FL4)"
import json, sys
def rows(f, part):
    t = json.load(open(f))[part]; return [dict(zip(t['columns'], r)) for r in t['rows']]
g = [r for r in rows(sys.argv[1], 'grid') if r.get('key') == 'counters.compiles_per_100_batches' and r.get('database') in (None, '')]
s = [r for r in rows(sys.argv[2], 'state') if r.get('metric') == 'counters.compiles_per_100_batches' and r.get('instance') == 'chkbox']
got = ((g[0].get('current_value'), g[0].get('floor'), g[0].get('floor_unit'), g[0].get('floor_input')) if g else None,
       (s[0].get('state'), s[0].get('floor_unit')) if s else None)
print(f'   FL4: the grid row (current, floor, unit, input) and the state row (state, unit): {got}')
sys.exit(0 if got == ((None, 5, 'batch requests', 'counters.batch_requests_s'), ('na', 'batch requests')) else 1)
PY2
  fi
done
ok "G1, G2: under a floor compiles_per_100_batches and full_scans_per_search read 'na' with no finding; the state carries the input's value and the floor"
else echo "   G0-G2 skipped (G_FROM=$G_FROM)"; fi
# G3: the transitions through the sender
mkdir -p "$TMPD/drop"; CFGA=$TMPD/ma.yaml; cp "$CFG" "$CFGA"
printf 'alerts:\n  - {name: drop, kind: file, min_severity: warning, clear_after: 0, instances: [chkbox], file: {dir: %s}}\n' "$TMPD/drop" >> "$CFGA"
pass() { "$TMPD/pgvigil" alerts -config "$CFGA" > "$TMPD/pass.$1.out" 2>&1 || fail "G3: the sender's pass $1: $(tail -3 "$TMPD/pass.$1.out")"
  ! grep -q 'alert rules not judged' "$TMPD/pass.$1.out" || fail "G3: pass $1: $(cat "$TMPD/pass.$1.out")"; }
files() { python3 -c 'import glob, json, sys
print(sum(1 for f in glob.glob(sys.argv[1] + "/*.json") if json.load(open(f)).get("event") == sys.argv[2]
          and "compilations per 100 batch requests" in json.load(open(f)).get("setting", "")))' "$TMPD/drop" "$1"; }
sent() { echo "firing $(files firing) resolved $(files resolved) escalated $(files escalated) repeat $(files repeat)"; }
loadread() { col mssql_counters; p_compiles; sleep 2; col mssql_counters; }
M=compiles_per_100_batches
step() { # step <label> <want state> <want files>
  local st; st=$(state "$M"); echo "   $1: $st, point $(newest "$M"), batch requests $(newest batch_requests_s)/s; drop: $(sent)"
  [[ "$st" == "$2" && "$(sent)" == "$3" ]] || fail "G3: $1: state $st (want $2), drop [$(sent)] (want [$3])"; }
NONE="firing 0 resolved 0 escalated 0 repeat 0"
rid=$(on "$M" null 1000000); [[ -n "$rid" ]] || fail "G3: the never-firing rule was refused"
loadread; pass a1; step "a never-firing rule after a load" ok "$NONE"
quiet; pass a2; step "after a quiet read (ok -> na)" na "$NONE"
loadread; pass a3; step "after a load (na -> ok)" ok "$NONE"
off "$rid"
rid=$(on "$M" null 0); [[ -n "$rid" ]] || fail "G3: the firing rule was refused"
quiet; pass b1; step "a rule firing on any value, after a quiet read" na "$NONE"
loadread; pass b2; step "after a load (na -> critical)" critical "firing 1 resolved 0 escalated 0 repeat 0"
quiet; pass b3; step "after a quiet read (critical -> na)" na "firing 1 resolved 0 escalated 0 repeat 0"
quiet; pass b4; step "after one more read and pass" na "firing 1 resolved 1 escalated 0 repeat 0"
quiet; pass b5; step "after another" na "firing 1 resolved 1 escalated 0 repeat 0"
off "$rid"
ok "G3: ok -> na and na -> ok send nothing; na -> critical sends one firing; critical -> na sends one resolved (after the read 0059 waits for), and nothing more"
# G4: the run break (FL3's change 1)
r3=$(rule "{\"op\":\"add\",\"ui_user\":\"proof402\",\"metric\":\"counters.$M\",\"op_dir\":\"above\",\"scope\":\"instance\",\"instance_name\":\"chkbox\",\"warning\":0,\"critical\":null,\"for_minutes\":3}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["rule_id"] if d["outcome"] == "done" else "")'); [[ -n "$r3" ]] || fail "G4: the 3-minute rule was refused"
rm -f "$TMPD"/drop/*.json
quiet; quiet; quiet; pass g4a; step "a 3-minute rule after three quiet reads" na "$NONE"
loadread; pass g4b; step "after one load (the run starts at the load: pending)" pending "$NONE"
off "$r3"
ok "G4: a read under the floor breaks the run: three quiet minutes and one load read 'pending', no file"
# G5: warning -> na -> warning, then resolved
rm -f "$TMPD"/drop/*.json
rid=$(on "$M" 0 null); [[ -n "$rid" ]] || fail "G5: the warning rule was refused"
quiet; pass g5a; step "a warning-only rule after a quiet read" na "$NONE"
loadread; pass g5b; step "after a load (na -> warning)" warning "firing 1 resolved 0 escalated 0 repeat 0"
quiet; pass g5c; step "after a quiet read (warning -> na)" na "firing 1 resolved 0 escalated 0 repeat 0"
quiet; pass g5d; step "after one more read and pass" na "firing 1 resolved 1 escalated 0 repeat 0"
off "$rid"
ok "G5: na -> warning sends one firing; warning -> na one resolved"
# G6: a flap inside the clear delay stays one open alert (a destination with clear_after 300)
CFGA0=$CFGA; CFGA=$TMPD/mb.yaml; cp "$CFG" "$CFGA"; rm -f "$TMPD"/drop/*.json
printf 'alerts:\n  - {name: drop, kind: file, min_severity: warning, clear_after: 300, instances: [chkbox], file: {dir: %s}}\n' "$TMPD/drop" >> "$CFGA"
rid=$(on "$M" null 0); [[ -n "$rid" ]] || fail "G6: the firing rule was refused"
loadread; pass g6a; step "a firing rule after a load" critical "firing 1 resolved 0 escalated 0 repeat 0"
quiet; pass g6b; step "after a quiet read (na, inside the clear delay)" na "firing 1 resolved 0 escalated 0 repeat 0"
loadread; pass g6c; step "after a load within 300 s (critical again)" critical "firing 1 resolved 0 escalated 0 repeat 0"
off "$rid"; CFGA=$CFGA0
ok "G6: a flap across the floor inside the clear delay stays one open alert (one firing, no resolved)"

echo "== F. the seeded rows at the end =="
pq "SELECT metric || '|' || rule_id || '|' || op || '|' || coalesce(warning::text, '') || '|' || coalesce(critical::text, '') || '|' || for_minutes || '|' || enabled || '|' || scope
      FROM pgvigil.alert_rules WHERE created_by = 'pgvigil' AND client = '0153 seed' AND ended_at IS NULL ORDER BY metric" > "$TMPD/seed-f"
grep -v '^counters.page_reads_s|' "$TMPD/seed-a" | diff - "$TMPD/seed-f" >&2 || fail "F: a seeded row changed"
ok "F: the 19 live seeded rows as read at A (rule_id, op, thresholds, for_minutes, off)"

echo "NOT PROVEN HERE: free list stalls, lazy writes, a low hit ratio, a low page life expectancy and a database taken offline at the seeded thresholds; SQL Server 2016, Managed Instance, a Windows host"
[[ -n "$D_FROM" ]] && { echo "PARTIAL: D from $D_FROM (a diagnostic run, not a proof)"; exit 3; }
[[ -n "$G_FROM" ]] && { echo "PARTIAL: G from $G_FROM (a diagnostic run, not a proof)"; exit 3; }
echo "PROOF OK: mssql counter checks (A B C D E G F)"
