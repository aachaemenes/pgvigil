#!/usr/bin/env bash
# Proof of task 402 (B4): the checks over SQL Server's performance counters - 0153's twenty-one fleet rules seeded OFF
# (twenty on the 'counters' metrics of 0152; one on the client timeouts per minute, B24 Fixed 1, part T), the join
# file's metric_rule (a seeded rule colours the Metrics grid on or off, and notifies only when on), each rule switched
# on through an enabled instance rule, its condition provoked on a SQL Server container (the client timeouts by a Go
# client's cancels), alert_rules_run's state and finding read, the load stopped and the clear read.
# Needs: docker (mcr.microsoft.com/mssql/server images), go, psql, curl, python3, ss, and:
#   ADMIN_DSN       a superuser connection to a PostgreSQL sandbox in keyword form (default 'host=127.0.0.1 port=5432
#                   user=postgres dbname=postgres'); the proof makes its own repository database and drops it.
#   PGVIGIL_IMAGE   the SQL Server image (default 2022-latest).
#   PGVIGIL_WIRING  1 (default) applies scripts/proof-mssql-counters-wiring.patch (401's) when the tree lacks the
#                   counters' runner hook, then scripts/proof-mssql-counter-checks-wiring.patch (this task's) when the
#                   join file lacks the seeded rules' metric_rule; 0 = the tree as it is. A patch the run applied is
#                   reversed at its exit (402 review part B: the tree is left as it was).
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment. Only the
# collection a step names runs (pgvigil collect -once). Each rule is judged with for_minutes 0 by an instance rule at
# the seeded thresholds (F20: the seeded fleet row is never edited), so a run stays short.
#
# Expected (written before the first run; red on 16240ee at A: '0 seeded rules', no 0153 there):
#  A. the seed (F22): after migrate, 21 rules at fleet scope (the twenty counters and B24 Fixed 1's client timeouts at
#     9.999 / 59.999 for 0 minutes), created_by 'pgvigil', client '0153 seed', enabled false, their thresholds and
#     for_minutes as the design's table; 21 alert_rule_log rows 'seed'; a second migrate adds nothing (21 and 21); the page reads rule ended through import_alert_rule, then 0153 run again by hand: no new
#     page reads rule and no new log row (a metric that ever had a fleet rule is never seeded again).
#  B. the owner line (the join file's metric_rule): 60 logins between two reads: metric_grid's counters.logins_s row
#     carries the seed's rule_id, 2 and 5, a name ending '(off: colours only, no alert)', and metric_status
#     'critical'; alert_rules_run writes no state and no finding for counters.logins_s; a user's own fleet rule on
#     counters.latch_waits_s added and then switched off: metric_rule gives no row for it.
#     B2 (402 S2, the lead's 22:0x; red on df1ffdc at B2a: 'none', the sandbox run s2-test of 11-14 22:2x read 10 of 14
#     there and 14 of 14 on this metric_rule): the seed of counters.lock_timeouts_gt0_s (the one seeded row the proof
#     edits, against F20: F leaves it out) edited to 0.5 / 2 while off: metric_rule gives the successor, 0.5 and 2, its
#     name ending '(off: colours only, no alert)'; edited again (never on): the second successor; that one switched on
#     is the rule in force (its name without the words); switched off: no row; an edit of it: no row (its chain was on).
#  C. on by an instance rule (F20): an enabled instance rule on counters.logins_s at 2 / 5 for 0 minutes; the same
#     load: state critical (warning is red here), one alert_rule_findings row naming it, the grid's rule the
#     instance's with metric_status critical (402 review part B, finding 4: metric_rule gives exactly that one row,
#     the grid row carries its id and a name without '(off'), read with the rule on; two quiet reads: state ok and no finding; the seed keeps its rule_id and enabled false; GET
#     /api/alertrules?part=rules lists the seed with enabled false; GET /api/metrics?family=counters gives the seeded page
#     lookups row rule_enabled false, its name ending '(off: colours only, no alert)', no rule state (402 part A's S1).
#  D. each provoked check, judged as C at the seeded thresholds (402 review part B folded). The fire leg (finding 3):
#     the read before the load, judged with the rule on, reads ok, 'na' or no state (else two more reads QUIET s apart,
#     then red), and the load's window is named (the XE session started before that read); for the batch ratios
#     (compiles_per_100_batches, page_splits_per_100_batches, page_lookups_per_batch, recompiles_per_100_compiles) the
#     proof's own batches and RPCs (its program, read by APP_NAME() at the setup) outnumber those of every program but
#     pgvigil, else red; then warning or critical with one finding. The clear leg: two quiet reads, the second 60 s
#     after the first (the product's interval, the lead's 19:0x; a run with QUIET other than 60 ends PARTIAL), the
#     window named (batches and RPCs by program, statistics updates, scans and seeks per object): ok with no finding,
#     or 'na' under a floor. A clear held up prints 'NOT PROVEN clear: <names>' only for a metric named background can
#     move (the batch ratios, full_scans_per_search, page_reads_s, readahead_pct; finding 2) and only after three more
#     quiet pairs each held up by named background; any other held clear is red, as is one held with only pgvigil's
#     own work in its window. The loads (each one that must not error runs with sqlcmd -b: an error is red):
#     errors_kill_s (3 at severity 20), lock_timeouts_gt0_s and lock_waits_s (6 probes at LOCK_TIMEOUT 200 behind a
#     held lock), avg_lock_wait_ms (3 probes at LOCK_TIMEOUT 1500: over 1000 ms), compiles_per_100_batches (60
#     distinct batches), page_splits_per_100_batches (random-key inserts, 40 batches), full_scans_per_search (20 heap
#     scans and 20 clustered index scans among 200 seeks; its two rates printed), page_lookups_per_batch (20 batches
#     each counting dbo.big, each followed by a SELECT 1 batch), readahead_pct and page_reads_s (a cold scan of dbo.big
#     after DBCC DROPCLEANBUFFERS; page reads by 1,500 cold random seeks), page_writes_s (dbo.big rewritten, then
#     CHECKPOINT, then 600 single-page writes each checkpointed), lock_requests_s (6,000 HOLDLOCK row seeks in one
#     batch), log_growths (database scope; finding 1: a database of the run's own, pgvlg, made just before its check,
#     its log 1 MB growing 1 MB at a time in SIMPLE recovery, 30,000 inserts in one transaction: SQL Server's own Log
#     Growths change for pgvlg over the load is 1 or more and equals the point, so no other database's growth is
#     counted); recompiles_per_100_compiles (a procedure whose temp table changes shape each run) NOT PROVEN live when
#     the load leaves the state ok or none and the point at or under its warning, red otherwise.
#  E. not provokable on a box, the rule's path only: free_list_stalls_s, lazy_writes_s, buffer_cache_hit_pct,
#     ple_per_4gb, errors_offline_s - an instance rule with a threshold the newest point crosses fires (the point
#     printed); NOT PROVEN live at the seeded threshold.
#  D with the floors (FL6, the lead's 19:4x / 19:5x; red on fd7b9bb at GC, on 3e745fa in D at compiles_per_100_batches:
#     0085's eval counts its NULL newest point as beyond, critical with a finding after the quiet reads - the floors'
#     review part B, finding 4): each floored check's load reads at its floor or more (5 Batch Requests/s; 1 Full
#     Scan/s), else it fails as too small; its clear leg reads ok, or 'na' with no finding and metric_floors' input
#     under its floor (the proof's own floored() line; the product's page words are NOT PROVEN, as G says) - a hard
#     clear either way, no NOT PROVEN for it; a clear read over its floor that still holds takes up to two more quiet
#     pairs, each printed, and stays hard (finding 6).
#  T. client timeouts (B24 Fixed 1, written before its first run): T0 mssql_attention_left_out on eleven built cases in
#     PerformanceMonitor's order: 'under 1 ms|counts|SSMS IntelliSense|counts|VS Code mssql metadata|Azure Data Studio
#     metadata|Azure Data Studio metadata|counts|under 1 ms|pgvigil's own reads|counts' (a NULL duration counts; a name
#     rule before the 1 ms floor, the floor before azdata's shapes). T1 built rows (chkxs1: reads 60 s apart, the newest
#     storing 200 counted rows): its point 66.67 (200 over the 3 minutes back to its base), an instance rule at the
#     seed's 9.999 / 59.999 goes critical at that read; a quiet read after it: still critical (the 3-minute window holds
#     the burst), as PerformanceMonitor's own text says of a storm. T2 built rows (chkxs2: a done read, a read cut
#     before the capture (no new_events) storing 6 rows, a done read storing 4): one point per metric, at the last read,
#     counted 5 (10 rows over 2 minutes), none at the cut read. T4 (the lead's 22:4x, F1 S3: PerformanceMonitor's
#     judged count; red on bfb184d: 50.00, warning) built reads a minute apart: 50 rows stored while the event_counter
#     moved 300: 300.00, critical at the seed's thresholds (a storm past the ring buffer); no row stored and the counter
#     +30: 30.00; the counter gone down (the session made again) with 20 rows: 20.00. The built reads' counters move
#     with their rows (T1 0 then 200; T2 0, 6, 10); T3's hand rule scales by the counter as the function does. T3 live on the container, pgvigil's attention session
#     made by sa from 'pgvigil mssql-xe -print': each mssql_xe read writes one mssql_attention_reads row (read_done);
#     a Go client (go-mssqldb, a connection per batch, a 2 s context timeout on WAITFOR DELAY 10 s, every batch of a
#     phase at once, the reads about 60 s apart): T3a 30 under 'proof-app' - exactly 30 rows with its marker, the
#     counter's change at that read at least the rows stored, every row's interrupt_us 1.5-3 s (PerformanceMonitor's
#     reading of the field: about the client's timeout), the point equal to PerformanceMonitor's span rule over the
#     stored rows, scaled by the counter's change as the function does (recomputed in python from the reads and the
#     rows), between 10 and 60, the instance rule warning; quiet reads until that rule's point is 0: state ok. T3b 60
#     under SSMS IntelliSense's name and 20 under 'vscode-mssql-ObjectExplorer': per program 60 rows 'SSMS
#     IntelliSense' and 20 'VS Code mssql metadata' (F1 part B, finding 4: each app's own count and reason), the
#     counted point 0, state ok, the left-out point as recomputed. T3c under
#     'azdata' 10 'create table #sver ...' batches (the marker after the statement) left out as Azure Data Studio
#     metadata, 10 query-editor batches counted; the counted point as recomputed. The XE API's attentions carry
#     left_out with those reasons. A cancel under 1 ms is proven on the function only, live 'NOT PROVEN live' unless
#     one occurs. The reads table's cost printed after T3 (F1 part B, finding 2; the design's F3): its rows, bytes a
#     row (pg_column_size), the table with its indexes, the attentions' read index over its partitions, and bytes a
#     day per instance at one read a minute - printed, not judged. T5 (F1 part B, finding 1) the trigger's path on a
#     built instance through import_mssql_xe: an attention state row with no new_events (a cut read) at 2 minutes
#     before XT, one with new_events 3 and counter 7 at 1 minute, the first payload again at its own time, a 'slow'
#     state row: the reads table holds '2m false -, 1m true 7' (the repeat changes nothing, 'slow' writes no row).
#  G. the floors: G0 at every instance read of the run each floored metric's point has no value exactly when an input
#     of the same read is under its floor (0152's metric_floors), both sides seen; G1 an instance rule
#     on compiles_per_100_batches at the seed's thresholds, a read 60 s after the one before with nothing of the proof
#     running: the point has no value, batch_requests_s under 5, state 'na', no finding, the state's value the
#     batch_requests_s point and its threshold 5; G2 the same on full_scans_per_search (value and threshold those of
#     an input under its floor); G3 the transitions through the alert sender ('pgvigil alerts', a file drop, clear
#     delay 0) on compiles_per_100_batches: a rule that never fires (critical 1e6) reads ok after a load, na after a
#     quiet read, ok again after a load, and the drop holds no file of it (ok -> na and na -> ok silent); a rule that
#     fires on any value (critical 0) reads na after a quiet read (no file), critical after a load (ONE firing file:
#     na -> critical as from ok), na after a quiet read (no resolved file yet: 0059 waits for an ok collection), and
#     after one more read and pass ONE resolved file, and no more after another (critical -> na resolved with its
#     normal notification). From the floors' pass (20261114-212721-reviewer): GC alert_rule_state holds ONE check on
#     state and it names 'na' (red on fd7b9bb: no 'na'; a run on fd7b9bb stops there, before G0-G2); G1 / G2 read
#     their quiet read 60 s after the one before and gated on the raw counters, unrounded (Batch Requests/sec under 5,
#     Full Scans/sec under 1); every quiet read of G that reads 5 batch requests a second or more (or a full scan, in
#     G2) takes up to two more reads 60 s apart, each printed (finding 6); G4 the run break: a rule warning above 0
#     for 3 minutes, three quiet reads 60 s apart (na) then a load straight after the third (so the point before the
#     load is the quiet read's no-value one): 'pending', no file - red only on this build with FL3's change 1
#     reverted (G_FROM=G4 starts there; on 3e745fa the run stops in D, finding 4); G5 warning: a rule warning above 0 with
#     no critical, a quiet read (na, no file), a load (warning, ONE firing file), a quiet read (na), one more read and
#     pass (ONE resolved); G6 a flap held by the clear delay (a destination with clear_after 5m; '300' with no unit was
#     refused by the configuration: finding 1): critical 0 for 0
#     minutes, a load (one firing), a quiet read (na), a second quiet read and pass (still na and no resolved: with
#     clear_after 0 that pass resolves, G3's b4), a load within the 5 minutes (critical): one firing and no resolved -
#     one open alert (a rule of 0 minutes; with more minutes a flap resolves and fires again, docs/alerts.md).
#     G_FROM=G3, G4, G5 or G6 starts G there (T, GC, G0-G2 and the G parts before it skipped; any other value refused
#     before the setup; such a run ends PARTIAL). G1 also reads FL4 through the API: the grid's
#     compilations row has no current value, floor 5, unit 'batch requests', input counters.batch_requests_s; its
#     state row 'na' with the unit 'batch requests' (red without 402's patch: no such columns). NOT PROVEN here: the
#     pages' N/A words as drawn (metrics.ts, alert_rules.ts) and FL5's summary flag (no row reads them yet).
#  F. at the end every seeded row but the two ended ones (page reads at A, lock timeouts at B2) keeps its rule_id, op,
#     thresholds, for_minutes and enabled false as read at A.
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
# G_FROM=<G3|G4|G5|G6>: a diagnostic run starts G at that part (T, GC, G0-G2 and the G parts before it skipped); any other
# value is refused here, before the setup (merge review NIT 2); such a run ends 'PARTIAL', never 'PROOF OK'
G_FROM=${G_FROM:-}
case "$G_FROM" in ''|G3|G4|G5|G6) ;; *) fail "G_FROM=$G_FROM (want G3, G4, G5 or G6)" ;; esac
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; APPLIED=
SA_PW=$(pw); MON_PW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\nMSSQL_PID=Developer\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  docker ps -aq --filter "label=$LBL-$SUF" | xargs -r docker rm -f -v >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  # the wiring patches this run applied, newest first (402 review part B: the tree is left as it was)
  for pf in $APPLIED; do git apply -R "$pf" 2>/dev/null || patch -R -p1 < "$pf" >/dev/null 2>&1 || echo "CLEANUP: $pf not reversed" >&2; done
  rm -rf "$TMPD"
}
trap cleanup EXIT
for t in docker go psql curl python3 ss; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
if [[ "${PGVIGIL_WIRING:-1}" == 1 ]]; then
  if ! grep -q 'ListCollector' internal/mssql/mssql.go; then
    git apply scripts/proof-mssql-counters-wiring.patch 2>/dev/null || patch -p1 --forward < scripts/proof-mssql-counters-wiring.patch >/dev/null \
      || fail "401's wiring patch"
    APPLIED="scripts/proof-mssql-counters-wiring.patch $APPLIED"; echo "401's wiring applied to this copy"
  fi
  if [[ -f scripts/proof-mssql-counter-checks-wiring.patch ]] && ! grep -q "0153 seed" internal/repo/sql/0190_join_release2.sql; then
    git apply scripts/proof-mssql-counter-checks-wiring.patch 2>/dev/null || patch -p1 --forward < scripts/proof-mssql-counter-checks-wiring.patch >/dev/null \
      || fail "402's wiring patch"
    APPLIED="scripts/proof-mssql-counter-checks-wiring.patch $APPLIED"; echo "402's wiring applied to this copy (0190: metric_rule)"
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
# the program name every sq / sqok batch of the proof carries (the loads' own, named in each load's window)
LOADAPP=$(sq "SELECT APP_NAME()" | tr -d '\r' | sed 's/[[:space:]]*$//'); [[ -n "$LOADAPP" ]] || fail "the proof's own program name"
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
NS=$(seeds); [[ "$NS" == 21 ]] || fail "A: $NS seeded rules (want 21)"
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
        'errors_kill_s': ('above', 0, 1, 0), 'errors_offline_s': ('above', 0, 1, 0), 'log_growths': ('above', 0, None, 0),
        'client_timeouts_per_min': ('above', 9.999, 59.999, 0)}
got, bad = {}, []
for l in open(sys.argv[1]):
    m, rid, op, w, c, f, en, sc = l.rstrip('\n').split('|')
    got[m.split('.', 1)[1]] = (op, float(w) if w else None, float(c) if c else None, int(f))
    if en != 'false' or sc != 'fleet': bad.append(f'{m} enabled {en} scope {sc}')   # a boolean in || reads 'false'
for k, v in want.items():
    if got.get(k) != v: bad.append(f'{k}: {got.get(k)} != {v}')
print(f'   {len(got)} seeded rules read; differences: {len(bad)}')
for b in bad: print('   FAIL ' + b)
sys.exit(1 if bad or len(got) != 21 else 0)
PY
NL=$(slog); [[ "$NL" == 21 ]] || fail "A: $NL seed log rows (want 21)"
"$TMPD/pgvigil" migrate -config "$CFG" > "$TMPD/migrate2.out" 2>&1 || { cat "$TMPD/migrate2.out" >&2; fail "A: the second migrate"; }
[[ "$(seeds)|$(slog)" == "21|21" ]] || fail "A: the second migrate: $(seeds) rules, $(slog) log rows"
PR=$(pq "SELECT rule_id FROM pgvigil.alert_rules WHERE metric = 'counters.page_reads_s' AND client = '0153 seed'")
rule "{\"op\":\"end\",\"ui_user\":\"proof402\",\"rule_id\":\"$PR\"}" | grep -q '"done"' || fail "A: ending the page reads rule"
psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -f internal/repo/sql/0153_mssql_counter_checks.sql >/dev/null || fail "A: 0153 run again by hand"
[[ "$(seeds)|$(slog)" == "21|21" && $(pq "SELECT count(*) FROM pgvigil.alert_rules WHERE metric = 'counters.page_reads_s' AND ended_at IS NULL") == 0 ]] \
  || fail "A: 0153 again after the end: $(seeds) rules, $(slog) log rows"
ok "A: 21 rules seeded off at fleet scope as the design's table, 21 log rows; a second migrate and 0153 again after an end add nothing"

# the provocations; each ends with nothing of its own still running
# 60 logins in one container session's loop (a docker exec per login is too slow to pass 5 a second)
p_logins() { timeout 120 docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'for i in $(seq 1 60); do SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -h -1 -Q "SET NOCOUNT ON; SELECT 1" >/dev/null; done'; }
p_kill() { for _ in 1 2 3; do sq "RAISERROR('pgvigil proof severe error', 20, 1) WITH LOG;" >/dev/null 2>&1 || true; done; }
p_timeouts() { bg 20 "BEGIN TRAN; UPDATE dbo.t SET v = v + 1 WHERE id = 1; WAITFOR DELAY '00:00:05'; ROLLBACK;"; sleep 1.5
  for _ in $(seq 1 6); do sq "SET LOCK_TIMEOUT 200; SELECT v FROM dbo.t WHERE id = 1;" pgvctr >/dev/null 2>&1 || true; done; sleep 3; }
p_longwait() { bg 20 "BEGIN TRAN; UPDATE dbo.t SET v = v + 1 WHERE id = 1; WAITFOR DELAY '00:00:07'; ROLLBACK;"; sleep 1.5
  for _ in 1 2 3; do sq "SET LOCK_TIMEOUT 1500; SELECT v FROM dbo.t WHERE id = 1;" pgvctr >/dev/null 2>&1 || true; done; sleep 2; }
p_compiles() { sqok "the compiles load" "$(for i in $(seq 1 60); do echo "SELECT COUNT(*) FROM dbo.t WHERE v >= 0 AND id <> $((RANDOM * 100 + i));"; echo GO; done)" pgvctr; }
p_splits() { sqok "the splits load" "$(for _ in $(seq 1 40); do echo "INSERT dbo.sp (pad) SELECT TOP (400) 'x' FROM sys.all_objects;"; echo GO; done)" pgvctr; }
p_scans() { sqok "the scans load" "DECLARE @i int = 0, @x int; WHILE @i < 200 BEGIN SELECT @x = v FROM dbo.t WHERE id = @i + 1; SET @i += 1; END;
  $(for _ in $(seq 1 20); do echo "SELECT @x = COUNT(*) FROM dbo.h; SELECT @x = COUNT(*) FROM dbo.big;"; done)" pgvctr; }
# the inputs of a ratio at the newest instance read: object|counter|rate per second
rates() { pq "SELECT string_agg(v.counter || ' ' || coalesce(round(v.rate::numeric, 2)::text, 'no rate'), ', ' ORDER BY v.counter)
  FROM pgvigil.mssql_counter_values($SB, (SELECT max(snapshot_at) FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance') - interval '1 second', now(), 'instance') v
  WHERE v.object = '$1' AND v.counter IN ($2) AND v.inst = '_Total'"; }
p_lookups() { sqok "the lookups load" "$(for _ in $(seq 1 20); do echo "SELECT COUNT(*) FROM dbo.big;"; echo GO; echo "SELECT 1;"; echo GO; done)" pgvctr; }
p_cold() { sqok "the cold buffers" "CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;" pgvctr; sqok "the cold scan" "SELECT COUNT(*) FROM dbo.big WHERE pad <> 'z';" pgvctr; }
# cold single-page reads: 1,500 random seeks after DROPCLEANBUFFERS (one page an I/O, whether the counter counts pages or I/Os)
p_coldseek() { sqok "the cold buffers" "CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;" pgvctr
  sqok "the cold seeks" "DECLARE @i int = 0, @x int; WHILE @i < 1500 BEGIN SELECT @x = LEN(pad) FROM dbo.big WHERE id = ABS(CHECKSUM(NEWID())) % 60000 + 1; SET @i += 1; END" pgvctr; }
# every page of dbo.big rewritten and checkpointed, then 600 single-page writes each with its CHECKPOINT
p_writes() { sqok "the rewrite" "UPDATE dbo.big SET pad = REPLICATE(CHAR(65 + ABS(CHECKSUM(NEWID())) % 26), 200); CHECKPOINT;" pgvctr
  sqok "the single-page writes" "DECLARE @i int = 0; WHILE @i < 600 BEGIN UPDATE dbo.big SET pad = 'w' WHERE id = ABS(CHECKSUM(NEWID())) % 60000 + 1; CHECKPOINT; SET @i += 1; END" pgvctr; }
p_lockreq() { sqok "the lock requests load" "DECLARE @i int = 0, @x int; WHILE @i < 6000 BEGIN SELECT @x = v FROM dbo.t WITH (ROWLOCK, HOLDLOCK) WHERE id = @i % 2000 + 1; SET @i += 1; END" pgvctr; }
p_recompiles() { sqok "the recompiles load" "$(for _ in $(seq 1 20); do echo "EXEC dbo.rc;"; echo GO; done)" pgvctr; }
# log_growths (402 review part B, finding 1): a database of the run's own, made just before its check (lg_db), its log
# 1 MB growing 1 MB at a time in SIMPLE recovery; one transaction of 30,000 rows grows it. SQL Server's own Log Growths
# for pgvlg is read before and after the load (LG_OWN), and D holds it equal to the point, so a growth of another
# database in the window is red (pgvctr's log, which D's earlier loads grow, is never shrunk or backed up here)
lg_db() { sqok "the log growth database" "CREATE DATABASE pgvlg ON (NAME = pgvlg, FILENAME = '/var/opt/mssql/data/pgvlg.mdf', SIZE = 16MB)
  LOG ON (NAME = pgvlg_log, FILENAME = '/var/opt/mssql/data/pgvlg_log.ldf', SIZE = 1MB, FILEGROWTH = 1MB);
  ALTER DATABASE pgvlg SET RECOVERY SIMPLE;"
  sqok "the log growth table" "CREATE TABLE dbo.g (id int NOT NULL PRIMARY KEY, pad char(200) NOT NULL);" pgvlg; }
lgc() { sq "SELECT CAST(cntr_value AS varchar(20)) FROM sys.dm_os_performance_counters WHERE RTRIM(counter_name) = N'Log Growths' AND RTRIM(instance_name) = N'pgvlg'" | tr -d '[:space:]'; }
LG_OWN=
p_growth() { local a b mb
  mb=$(sq "SELECT CAST(size / 128 AS varchar(10)) FROM sys.database_files WHERE type = 1" pgvlg | tr -d '[:space:]')
  echo "   pgvlg's log before the load: $mb MB"
  [[ "$mb" =~ ^[0-9]+$ && "$mb" -le 2 ]] || fail "D: log_growths: pgvlg's log at [$mb] MB before the load (want 1 or 2)"
  a=$(lgc)
  sqok "the log growth load" "INSERT dbo.g (id, pad) SELECT TOP (30000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)), REPLICATE('g', 200) FROM sys.all_objects a CROSS JOIN sys.all_objects b" pgvlg
  b=$(lgc); [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || fail "D: log_growths: pgvlg's Log Growths counter [$a] [$b]"
  LG_OWN=$((b - a)); echo "   pgvlg's own Log Growths over the load: $a -> $b"; }

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
# B2 (402 S2): an Edit of an off seed keeps its colours while no rule of its chain was ever on
S2M=counters.lock_timeouts_gt0_s
mr() { pq "SELECT coalesce(string_agg(m.rule_id || '|' || coalesce(m.warning::text, '') || '|' || coalesce(m.critical::text, '') || '|' || m.rule_name, ' ; '), 'none') FROM pgvigil.metric_rule($SB, '$S2M') m"; }
redit() { rule "{\"op\":\"edit\",\"ui_user\":\"proof402\",\"rule_id\":\"$1\",\"metric\":\"$S2M\",\"op_dir\":\"above\",\"scope\":\"fleet\",\"warning\":$2,\"critical\":$3,\"for_minutes\":15,\"name\":\"$4\"}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["rule_id"] if d["outcome"] == "done" else "")'; }
S2S=$(pq "SELECT rule_id FROM pgvigil.alert_rules WHERE metric = '$S2M' AND client = '0153 seed' AND ended_at IS NULL")
[[ -n "$S2S" ]] || fail "B2: no live seed on $S2M"
E1=$(redit "$S2S" 0.5 2 "proof402 fitted"); [[ -n "$E1" ]] || fail "B2: the edit of the off seed was refused"
G=$(mr); echo "   B2a the off seed $S2S edited ($E1, off): $G"
[[ "$G" == "$E1|0.5|2|proof402 fitted (off: colours only, no alert)" ]] || fail "B2a: an edited off seed lost its colours [$G]"
E2=$(redit "$E1" 0.5 3 "proof402 fitted again"); [[ -n "$E2" ]] || fail "B2: the second edit was refused"
G=$(mr); echo "   B2a3 edited again ($E2, never on): $G"
[[ "$G" == "$E2|0.5|3|proof402 fitted again (off: colours only, no alert)" ]] || fail "B2a3: a second edit, never on, lost the colours [$G]"
rule "{\"op\":\"enable\",\"ui_user\":\"proof402\",\"rule_id\":\"$E2\"}" | grep -q '"done"' || fail "B2: switching the successor on"
G=$(mr); [[ "$G" == "$E2|0.5|3|proof402 fitted again" ]] || fail "B2b1: the successor switched on is not the rule in force [$G]"
rule "{\"op\":\"disable\",\"ui_user\":\"proof402\",\"rule_id\":\"$E2\"}" | grep -q '"done"' || fail "B2: switching the successor off"
G=$(mr); echo "   B2b switched on, then off: $G"
[[ "$G" == none ]] || fail "B2b: an on-then-off successor colours [$G]"
E3=$(redit "$E2" 0.5 4 "proof402 after on"); [[ -n "$E3" ]] || fail "B2: the edit of the on-then-off rule was refused"
G=$(mr); echo "   B2c that rule edited ($E3): $G"
[[ "$G" == none ]] || fail "B2c: an edit of an on-then-off rule colours [$G]"
rule "{\"op\":\"end\",\"ui_user\":\"proof402\",\"rule_id\":\"$E3\"}" >/dev/null
ok "B2: an off seed edited keeps its colours, its name says off, through a second edit; switched on and off its chain colours nothing, nor does an edit of it"

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
  python3 - "$TMPD/usage-a" "$TMPD/usage-b" "$TMPD/xe-w" "$a" "$b" "$LOADAPP" > "$TMPD/diag-w" <<'PY' || fail "the window's names"
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
loadapp = sys.argv[6]
loadb = sum(int(r[3]) for r in xe if r[2] == loadapp and r[1] in ('sql_batch_completed', 'rpc_completed'))
otherb = sum(int(r[3]) for r in xe if r[2] not in ('pgvigil', loadapp) and r[1] in ('sql_batch_completed', 'rpc_completed'))
for _, n, app, c, lr in sorted(xe, key=lambda r: -int(r[3])):
    own = app == 'pgvigil'
    tag = " (the collector's own)" if own else (" (the proof's own)" if app == loadapp else "")
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
print(f'LOADB={loadb}')
print(f'OTHERB={otherb}')
PY
  grep -vE '^(OTHER|LOADB|OTHERB)=' "$TMPD/diag-w"
  DIAG_OTHER=$(sed -n 's/^OTHER=//p' "$TMPD/diag-w")
  LOADB=$(sed -n 's/^LOADB=//p' "$TMPD/diag-w"); OTHERB=$(sed -n 's/^OTHERB=//p' "$TMPD/diag-w"); LOADB=${LOADB:-0}; OTHERB=${OTHERB:-0}
}
# D_FROM=<metric>: a diagnostic run starts D at that check (the checks before it skipped); such a run ends 'PARTIAL', never
# 'PROOF OK'
D_FROM=${D_FROM:-}; D_REACHED=0
# the floors (FL6): HAVE_FLOORS when 0152 holds metric_floors (fd7b9bb does not: D runs as before, G is red at GC)
HAVE_FLOORS=$(pq "SELECT to_regclass('pgvigil.metric_floors') IS NOT NULL")
# floored <metric>: each floor of the metric with its input's point at the metric's newest read ('' = no floor)
floored() { [[ "$HAVE_FLOORS" == t ]] || return 0
  pq "WITH p AS (SELECT x.at, x.metric, x.value FROM pgvigil.metric_points($SB, 'counters', now() - interval '10 minutes', now()) x),
  n AS (SELECT max(p.at) AS at FROM p WHERE p.metric = '$1')
  SELECT string_agg(f.unit || ' ' || coalesce(pgvigil.metric_num(i.value), 'none') || '/s (floor ' || pgvigil.metric_num(f.floor) || '/s'
                    || CASE WHEN i.value IS NULL OR i.value < f.floor THEN ': under it)' ELSE ')' END, ', ' ORDER BY f.unit)
    FROM pgvigil.metric_floors f CROSS JOIN n LEFT JOIN p i ON i.metric = split_part(f.input_key, '.', 2) AND i.at = n.at
   WHERE f.key = 'counters.$1'"; }
# judge <metric> <provoke> [collection] [inputs printer] [hook]: an enabled instance rule at the seed's thresholds for
# 0 minutes. The read before the load judged with the rule on: ok, 'na' or no state (else two more reads QUIET s
# apart, then red: the fire leg must be the load's; 402 review part B, finding 3), the XE session started before it so
# the load's window is named; the load, a read, the run: warning or critical with one finding (the batch ratios: the
# proof's own batches outnumber every other program's but pgvigil's); the hook called with the rule's id. Two quiet
# reads, the run: ok, or 'na' under a floor; a metric named background can move gets three more quiet pairs while
# named background holds its clear, then 'NOT PROVEN clear' (finding 2); any other held clear is red. Returns 0 (fired;
# CLEARED 1 cleared, 0 NOT PROVEN), 2 the load left the state ok or none and the point at or under the warning, 1 red.
# Every read is checked by hand: a caller's || switches set -e off for the whole body (finding 6).
MOVABLE=' compiles_per_100_batches page_splits_per_100_batches page_lookups_per_batch recompiles_per_100_compiles full_scans_per_search page_reads_s readahead_pct '
BATCHY=' compiles_per_100_batches page_splits_per_100_batches page_lookups_per_batch recompiles_per_100_compiles '
JUDGED=0; J_ST1=; J_V1=; LOADB=0; OTHERB=0
judge() {
  local m=$1 fn=$2 c=${3:-mssql_counters} s op w cr rid st0 st1 st2 f1 f2 v v2 fl fl2 try scope=instance
  J_ST1=; J_V1=; CLEARED=0
  if [[ -n "$D_FROM" && $D_REACHED == 0 && "$m" != logins_s ]]; then
    if [[ "$m" == "$D_FROM" ]]; then D_REACHED=1; else echo "   $m skipped (D_FROM=$D_FROM)"; CLEARED=1; return 0; fi
  fi
  JUDGED=$((JUDGED + 1))
  [[ "$c" == mssql_counters_db ]] && scope=database
  s=$(SEEDOF "$m") || fail "$m: no seed row read at A"
  op=$(cut -d'|' -f3 <<<"$s"); w=$(cut -d'|' -f4 <<<"$s"); cr=$(cut -d'|' -f5 <<<"$s")
  rid=$(rule "{\"op\":\"add\",\"ui_user\":\"proof402\",\"metric\":\"counters.$m\",\"op_dir\":\"$op\",\"scope\":\"instance\",\"instance_name\":\"chkbox\",\"warning\":${w:-null},\"critical\":${cr:-null},\"for_minutes\":0}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["rule_id"] if d["outcome"] == "done" else "")') || fail "$m: the instance rule"
  [[ -n "$rid" ]] || fail "$m: the instance rule was refused"
  # the read before the load, the rule on (finding 3)
  for try in 1 2 3; do
    diag_on; col "$c"; run || fail "$m: alert_rules_run"; st0=$(state "$m") || fail "$m: the state read"
    [[ -z "$st0" || "$st0" == ok || "$st0" == na ]] && break
    echo "   $m: $st0 at the read before the load, the point $(point "$m") (try $try of 3)"
    [[ $try == 3 ]] && { echo "   $m: the read before the load never read ok: a fire after the load would not be the load's"; return 1; }
    sleep "$QUIET"
  done
  # the read after the load waits 2 s: SQL Server publishes some counters a moment after the statement ends (run chk5
  # read a ratio's full scans and its index searches in two reads 0.3 s apart)
  $fn; sleep 2; col "$c"; echo "   $m: the load's window"; diag_read "$scope"
  run || fail "$m: alert_rules_run"
  st1=$(state "$m") || fail "$m: the state read"; f1=$(findings "$m") || fail "$m: the findings read"
  v=$(point "$m") || fail "$m: the point read"; fl=$(floored "$m") || fail "$m: the floors read"
  J_ST1=$st1; J_V1=$v
  [[ -n "${4:-}" ]] && echo "   $m's inputs at that read: $($4)"
  [[ -n "$fl" ]] && echo "   $m's floors at that read: $fl"
  [[ -n "${5:-}" ]] && "$5" "$rid"
  echo "   $m ($op ${w:-} / ${cr:-}): before the load ${st0:-no state}; $v after the load -> $st1 ($f1 finding); the load's batches and RPCs $LOADB, other programs' $OTHERB"
  if [[ "$fl" == *"under it"* ]]; then echo "   $m: the load's read is under a floor ($fl): the load is too small to judge it"; return 1; fi
  if [[ "$BATCHY" == *" $m "* ]] && (( LOADB <= OTHERB )); then echo "   $m: the load's window holds $LOADB batches and RPCs of the proof against $OTHERB of other programs: the load does not dominate it"; return 1; fi
  if ! [[ ( "$st1" == warning || "$st1" == critical ) && "$f1" == 1 ]]; then
    rule "{\"op\":\"end\",\"ui_user\":\"proof402\",\"rule_id\":\"$rid\"}" >/dev/null
    [[ ( -z "$st1" || "$st1" == ok ) && "$f1" == 0 && -n "$v" && -n "$w" ]] && python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' "$v" "$w" && return 2
    return 1
  fi
  # the clear leg: two quiet reads; while named background holds a movable metric, three more quiet pairs (finding 2)
  sleep 2; diag_on; col "$c"; sleep "$QUIET"; col "$c"; diag_read "$scope"
  for try in 0 1 2 3; do
    if (( try > 0 )); then echo "   $m held at $st2 ($v2)$([[ -n "$fl2" ]] && echo " over its floor ($fl2)" || echo ' with named background'): quiet pair $try more"; diag_on; col "$c"; sleep "$QUIET"; col "$c"; diag_read "$scope"; fi
    run || fail "$m: alert_rules_run"
    st2=$(state "$m") || fail "$m: the state read"; f2=$(findings "$m") || fail "$m: the findings read"
    v2=$(point "$m") || fail "$m: the point read"; fl2=$(floored "$m") || fail "$m: the floors read"
    [[ "$st2" == ok && "$f2" == 0 ]] && { CLEARED=1; break; }
    # FL3: under a floor the check is not judged ('na', no finding): a hard clear, the window's background named above
    [[ -n "$fl2" && "$st2" == na && "$f2" == 0 && "$fl2" == *"under it"* ]] && { CLEARED=1; break; }
    # a floored check held over its floor gets up to two more quiet pairs and stays hard (the floors' part B, finding 6)
    if [[ -n "$fl2" ]]; then [[ "$fl2" != *"under it"* ]] && (( try < 2 )) || break
    else [[ "$MOVABLE" == *" $m "* && -n "$DIAG_OTHER" ]] || break; fi
  done
  [[ -n "${4:-}" ]] && echo "   $m's inputs after the quiet reads: $($4)"
  [[ -n "$fl2" ]] && echo "   $m's floors after the quiet reads: $fl2"
  rule "{\"op\":\"end\",\"ui_user\":\"proof402\",\"rule_id\":\"$rid\"}" >/dev/null
  echo "   $m: quiet ($v2) -> $st2 ($f2)"
  [[ $CLEARED == 1 ]] && return 0
  if [[ "$MOVABLE" == *" $m "* && -z "$fl2" && -n "$DIAG_OTHER" ]]; then echo "NOT PROVEN clear: $m stayed $st2 at $v2 after four quiet pairs, each with named background in its window (the last: $DIAG_OTHER)"; return 0; fi
  return 1
}
# C's hook (402 review part B, finding 4): with the instance rule on, metric_rule gives exactly that rule and the grid row
# carries it, its name without '(off', critical
C_GRID=
c_grid() { C_GRID=$(pq "SELECT (SELECT count(*) FROM pgvigil.metric_rule($SB, 'counters.logins_s')) || '|'
    || coalesce((SELECT string_agg(r.rule_id::text, ',') FROM pgvigil.metric_rule($SB, 'counters.logins_s') r), '') || '|'
    || coalesce((SELECT g.rule_id || '|' || (g.rule_name LIKE '%(off%') || '|' || coalesce(pgvigil.metric_status(g.op, g.current_value, g.warning, g.critical), 'none')
         FROM pgvigil.metric_grid($SB, now() - interval '10 minutes', now(), interval '15 minutes', NULL, 'counters') g WHERE g.key = 'counters.logins_s'), 'no row')") \
    || fail "C: the grid read"
  C_GRID="$1=$C_GRID"; }
judge logins_s p_logins mssql_counters '' c_grid && [[ $CLEARED == 1 && "$J_ST1" == critical ]] || fail "C: logins_s (critical and clear both hard here; the state after the load [$J_ST1])"
echo "   C with the rule on: metric_rule rows|their ids|the grid row's rule|its name says off|its status = $C_GRID"
[[ "$C_GRID" =~ ^([0-9]+)=1\|([0-9]+)\|([0-9]+)\|false\|critical$ && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[3]}" ]] \
  || fail "C: the rule in force with the instance rule on [$C_GRID] (want <id>=1|<id>|<id>|false|critical)"
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
ok "C: on by an instance rule: critical with its finding, the grid's one rule in force the instance's; ok after two quiet reads; the seed kept its rule_id and stays off (the API says so)"
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
J0=$JUDGED
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
# d_growths: Log Growths of _Total and pgvlg at the newest three database reads (stored, or named in zero_series), the
# metric's points, and SQL Server's own read now with pgvctr's log size
d_growths() { echo; pq "SELECT '      ' || r.snapshot_at || ' Log Growths [' || k.inst || '] value ' || coalesce(s.value::text, CASE WHEN k.series_id = ANY (r.zero_series) THEN '0 (zero_series)' ELSE '-' END) || ' change ' || coalesce(s.dvalue::text, '-')
  FROM (SELECT * FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'database' ORDER BY snapshot_at DESC LIMIT 3) r
  JOIN pgvigil.mssql_counter_series k ON k.instance_id = $SB AND k.object = 'Databases' AND k.counter = 'Log Growths' AND k.inst IN ('_Total', 'pgvlg')
  LEFT JOIN pgvigil.mssql_counter_sample s ON s.instance_id = $SB AND s.series_id = k.series_id AND s.snapshot_at = r.snapshot_at
  ORDER BY r.snapshot_at DESC, k.inst"
  pq "SELECT '      point ' || at || ' ' || value FROM pgvigil.metric_points($SB, 'counters', now() - interval '10 minutes', now()) WHERE metric = 'log_growths' ORDER BY at DESC LIMIT 3"
  sq "SELECT '      SQL Server now: Log Growths [' + RTRIM(instance_name) + '] ' + CAST(cntr_value AS varchar(20)) FROM sys.dm_os_performance_counters WHERE RTRIM(counter_name) = N'Log Growths' AND RTRIM(instance_name) IN (N'_Total', N'pgvlg', N'pgvctr', N'master', N'tempdb');
SELECT '      pgvlg log ' + CAST(size / 128 AS varchar(10)) + ' MB, growth ' + CAST(growth AS varchar(10)) + CASE WHEN is_percent_growth = 1 THEN ' %' ELSE ' pages' END FROM pgvlg.sys.database_files WHERE type = 1;"; }
judge full_scans_per_search p_scans mssql_counters d_scans || fail "D: full_scans_per_search"
judge page_lookups_per_batch p_lookups mssql_counters d_lookups || fail "D: page_lookups_per_batch"
judge readahead_pct p_cold mssql_counters d_ahead || fail "D: readahead_pct"
judge page_reads_s p_coldseek || fail "D: page_reads_s"
judge page_writes_s p_writes || fail "D: page_writes_s"
judge lock_requests_s p_lockreq mssql_counters d_lockreq || fail "D: lock_requests_s"
lg_db
judge log_growths p_growth mssql_counters_db d_growths || fail "D: log_growths"
if [[ -n "$J_V1" ]]; then
  echo "   log_growths: the point $J_V1, pgvlg's own Log Growths over the load $LG_OWN"
  [[ "$LG_OWN" =~ ^[0-9]+$ && "$LG_OWN" -ge 1 ]] && python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) == float(sys.argv[2]) else 1)' "$J_V1" "$LG_OWN" \
    || fail "D: log_growths: the point [$J_V1] is not pgvlg's own growth [$LG_OWN] (another database grew in the window, or none did)"
fi
RC=0; judge recompiles_per_100_compiles p_recompiles || RC=$?
case $RC in
  0) ok "D: recompiles_per_100_compiles fired$([[ $CLEARED == 1 ]] && echo ' and cleared')" ;;
  2) echo "NOT PROVEN live: recompiles_per_100_compiles did not reach its warning with a procedure whose temp table changes shape (the state ok or none, the point at or under the warning: the line above)" ;;
  *) fail "D: recompiles_per_100_compiles (a state or a point the load cannot explain: the line above)" ;;
esac
ok "D: $((JUDGED - J0)) provoked checks judged at their seeded thresholds, each fired from a quiet read before its load; each cleared after quiet reads 60 s apart, or its clear is NOT PROVEN above with the background named"

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

echo "== T. client timeouts (B24 Fixed 1) =="
if [[ -n "$D_FROM" || -n "$G_FROM" ]]; then echo "   T skipped (D_FROM='$D_FROM' G_FROM='$G_FROM')"; else
XM=xe.client_timeouts_per_min
xstate() { pq "SELECT state FROM pgvigil.alert_rule_state WHERE instance_id = $1 AND metric = '$XM' AND database = ''"; }
xrule() { rule "{\"op\":\"add\",\"ui_user\":\"proof402\",\"metric\":\"$XM\",\"op_dir\":\"above\",\"scope\":\"instance\",\"instance_name\":\"$1\",\"warning\":9.999,\"critical\":59.999,\"for_minutes\":0}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["rule_id"] if d["outcome"] == "done" else "")'; }
xend() { rule "{\"op\":\"end\",\"ui_user\":\"proof402\",\"rule_id\":\"$1\"}" >/dev/null; }
# the function's newest point of a metric over the last 30 minutes
xpoint() { pq "SELECT round(value::numeric, 2) FROM pgvigil.mssql_attention_points($1, now() - interval '30 minutes', now()) WHERE metric = '$2' ORDER BY at DESC LIMIT 1"; }

# T0: the left-out rules on built cases, in PerformanceMonitor's order
LO=$(pq "SELECT string_agg(coalesce(pgvigil.mssql_attention_left_out(p, s, d), 'counts'), '|' ORDER BY n) FROM (VALUES
  (1, 'proof-app', 'x', 500::bigint), (2, 'proof-app', 'x', NULL::bigint),
  (3, 'Microsoft SQL Server Management Studio - Transact-SQL IntelliSense  ', 'x', 500), (4, 'vscode-mssql', 'x', 5000000),
  (5, ' VSCODE-MSSQL-ObjectExplorer ', 'x', 5000000), (6, 'azdata', '  create table #SVer (a int)', 5000000),
  (7, 'azdata', 'select c.name from sys.all_columns as clmns', 5000000), (8, 'azdata', 'select 1', 5000000),
  (9, 'azdata', 'create table #sver (a int)', 500), (10, 'pgvigil', 'x', 5000000), (11, NULL, NULL, NULL)) v(n, p, s, d)")
echo "   T0: $LO"
[[ "$LO" == "under 1 ms|counts|SSMS IntelliSense|counts|VS Code mssql metadata|Azure Data Studio metadata|Azure Data Studio metadata|counts|under 1 ms|pgvigil's own reads|counts" ]] \
  || fail "T0: the left-out reasons"
ok "T0: the left-out rules in PerformanceMonitor's order (names, then under 1 ms with NULL counted, then azdata's shapes), pgvigil's own reads"

# built instances: reads 60 s apart, rows stored at a read (snapshot_at) one second after their event
for m in "now()" "now() - interval '1 hour'"; do pq "SELECT pgvigil.mssql_event_partition('mssql_attentions', $m)" >/dev/null; done
xinst() { pq "INSERT INTO pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
  VALUES ('$1', 'sqlserver', '{}', now(), now(), true, 'sqlserver') RETURNING instance_id" | head -1; }
# the built reads and rows hang off one time XT (each psql call has its own now(): a row must sit at its read exactly)
XT=$(pq "SELECT date_trunc('second', now())")
# xread <instance> <minutes before XT> <done: true|false> [<the event_counter's count at that read>, default 0]: the
# rate is PerformanceMonitor's judged count, so a built read's counter moves with the rows it stores (F1 S3)
xread() { pq "INSERT INTO pgvigil.mssql_attention_reads (instance_id, snapshot_at, state, read_done, new_events, counter, missed_events)
  VALUES ($1, '$XT'::timestamptz - interval '$2 minutes', 'running', $3, CASE WHEN $3 THEN 0 END, ${4:-0}, 0)" >/dev/null; }
# xrows <instance> <minutes before XT> <n> <program>: n rows stored at that read, each a second before it
xrows() { pq "INSERT INTO pgvigil.mssql_attentions (instance_id, event_at, event_key, snapshot_at, session_id, interrupt_us, statement, program_name)
  SELECT $1, '$XT'::timestamptz - interval '$2 minutes' - interval '1 second', 'b$2-' || g, '$XT'::timestamptz - interval '$2 minutes',
         60, 2000000, 'WAITFOR DELAY ''00:00:10''', '$4' FROM generate_series(1, $3) g" >/dev/null; }

# T1: the burst (the pass's F1): reads at 5, 4, 3, 2 minutes back, the read 1 minute back stores 200 counted rows
XS1=$(xinst chkxs1); [[ "$XS1" =~ ^[0-9]+$ ]] || fail "T1: the built instance [$XS1]"
for t in 5 4 3 2; do xread "$XS1" "$t" true 0; done; xread "$XS1" 1 true 200; xrows "$XS1" 1 200 proof-app
P1=$(xpoint "$XS1" client_timeouts_per_min)
R1=$(xrule chkxs1); [[ -n "$R1" ]] || fail "T1: the instance rule on chkxs1 was refused"
run; S1=$(xstate "$XS1")
xread "$XS1" 0 true 200; P1b=$(xpoint "$XS1" client_timeouts_per_min); run; S1b=$(xstate "$XS1"); xend "$R1"
echo "   T1: the burst read's point $P1 -> $S1; a quiet read after it: $P1b -> $S1b"
[[ "$P1|$S1|$P1b|$S1b" == "66.67|critical|66.67|critical" ]] || fail "T1: the burst [$P1|$S1|$P1b|$S1b] (want 66.67|critical|66.67|critical)"
ok "T1: 200 timeouts in one read go critical at that read (200 over the 3 minutes back) and stay critical a quiet read later"

# T2: a read cut before the capture (no new_events) stores 6 rows; the next done read's span holds them
XS2=$(xinst chkxs2); [[ "$XS2" =~ ^[0-9]+$ ]] || fail "T2: the built instance [$XS2]"
xread "$XS2" 3 true 0; xread "$XS2" 2 false 6; xread "$XS2" 1 true 10; xrows "$XS2" 2 6 proof-app; xrows "$XS2" 1 4 proof-app
P2=$(pq "SELECT string_agg(round(extract(epoch FROM '$XT'::timestamptz - at) / 60) || 'm ' || metric || ' ' || round(value::numeric, 2), ', ' ORDER BY at, metric)
  FROM pgvigil.mssql_attention_points($XS2, now() - interval '30 minutes', now())")
echo "   T2: $P2"
[[ "$P2" == "1m client_timeouts_left_out_per_min 0.00, 1m client_timeouts_per_min 5.00" ]] || fail "T2: the points around a cut read [$P2]"
ok "T2: a cut read gives no point and its 6 rows count in the next done read's span (10 over 2 minutes)"

# T4 (the lead's 22:4x, F1 S3; red on bfb184d: 50.00, warning): PerformanceMonitor's judged count - a storm past the
# ring buffer (the read stores 50 rows, the event_counter moved 300) reads 300 a minute, critical; T4b no row stored,
# the counter +30: 30 (the whole change); T4c the counter gone down (the session made again), 20 rows: 20 (the rows alone)
XS4=$(xinst chkxs4); [[ "$XS4" =~ ^[0-9]+$ ]] || fail "T4: the built instance [$XS4]"
xread "$XS4" 2 true 1000; xread "$XS4" 1 true 1300; xrows "$XS4" 1 50 proof-app
P4=$(xpoint "$XS4" client_timeouts_per_min)
R4=$(xrule chkxs4); [[ -n "$R4" ]] || fail "T4: the instance rule on chkxs4 was refused"
run; S4=$(xstate "$XS4"); xend "$R4"
XS4b=$(xinst chkxs4b); xread "$XS4b" 2 true 0; xread "$XS4b" 1 true 30; P4b=$(xpoint "$XS4b" client_timeouts_per_min)
XS4c=$(xinst chkxs4c); xread "$XS4c" 2 true 1000; xread "$XS4c" 1 true 15; xrows "$XS4c" 1 20 proof-app; P4c=$(xpoint "$XS4c" client_timeouts_per_min)
echo "   T4: a storm past the ring buffer $P4 -> $S4; no row stored, the counter +30: $P4b; the counter gone down, 20 rows: $P4c"
[[ "$P4|$S4|$P4b|$P4c" == "300.00|critical|30.00|20.00" ]] || fail "T4: [$P4|$S4|$P4b|$P4c] (want 300.00|critical|30.00|20.00)"
ok "T4: a storm the ring buffer cut reads 300 a minute, critical; the whole counter change with no row stored; the stored rows after a counter reset"

# T5 (F1 part B, finding 1): the trigger's path - four imports through import_mssql_xe on a built instance
XS5=$(xinst chkxs5); [[ "$XS5" =~ ^[0-9]+$ ]] || fail "T5: the built instance [$XS5]"
xi() { pq "SELECT pgvigil.import_mssql_xe($XS5, '$XT'::timestamptz - interval '$1 minutes', '[$2]'::jsonb)" >/dev/null; }
xi 2 '{"kind":"state","capture":"attention","state":"running"}'
xi 1 '{"kind":"state","capture":"attention","state":"running","new_events":3,"counter":7}'
xi 2 '{"kind":"state","capture":"attention","state":"running"}'
xi 1 '{"kind":"state","capture":"slow","state":"running","new_events":1}'
P5=$(pq "SELECT coalesce(string_agg(round(extract(epoch FROM '$XT'::timestamptz - snapshot_at) / 60) || 'm ' || read_done || ' ' || coalesce(counter::text, '-'), ', ' ORDER BY snapshot_at), 'none')
  FROM pgvigil.mssql_attention_reads WHERE instance_id = $XS5")
echo "   T5: the reads table after four imports: $P5"
[[ "$P5" == "2m false -, 1m true 7" ]] || fail "T5: the trigger's rows [$P5] (want '2m false -, 1m true 7')"
pq "UPDATE pgvigil.instances SET is_active = false WHERE instance_id = $XS5" >/dev/null
ok "T5: through import_mssql_xe a cut read is not done, a done read keeps its counter, a repeat and another capture add no row"

# T3: live. pgvigil's sessions made by sa from the printed script; a Go client's cancels
"$TMPD/pgvigil" mssql-xe -print -install-id "c$SUF" > "$TMPD/xe.sql" || fail "T3: mssql-xe -print"
XO=$(sq "$(cat "$TMPD/xe.sql")" master 300 2>&1) || fail "T3: the printed script: $XO"
[[ $(grep -c "^started: pgvigil_c${SUF}_" <<<"$XO") == 4 ]] || fail "T3: four sessions started: $XO"
mkdir -p "$TMPD/attn"; cp go.mod go.sum "$TMPD/attn/"; sed -i 's/^module .*/module attnproof/' "$TMPD/attn/go.mod"
cat > "$TMPD/attn/main.go" <<'GO'
// attn: the proof's client timeouts. Every batch on a connection of its own, connected first, then run under a
// context that times out; all batches of a call at once.
package main

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"net/url"
	"os"
	"sync"
	"time"

	_ "github.com/microsoft/go-mssqldb"
)

func main() {
	app := flag.String("app", "", "the application name of every connection")
	n := flag.Int("n", 1, "how many batches, all at once")
	batch := flag.String("sql", "", "the batch")
	timeout := flag.Duration("timeout", 2*time.Second, "the context timeout of each batch")
	flag.Parse()
	dsn := os.Getenv("ATTN_DSN") + "&app+name=" + url.QueryEscape(*app)
	var wg sync.WaitGroup
	var mu sync.Mutex
	cancelled, other := 0, []string{}
	for i := 0; i < *n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			err := one(dsn, *batch, *timeout)
			mu.Lock()
			defer mu.Unlock()
			if errors.Is(err, context.DeadlineExceeded) {
				cancelled++
			} else {
				other = append(other, fmt.Sprint(err))
			}
		}()
	}
	wg.Wait()
	fmt.Printf("cancelled %d of %d\n", cancelled, *n)
	for _, e := range other {
		fmt.Println("not cancelled:", e)
	}
	if cancelled != *n {
		os.Exit(1)
	}
}

func one(dsn, batch string, timeout time.Duration) error {
	db, err := sql.Open("sqlserver", dsn)
	if err != nil {
		return err
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	cctx, cc := context.WithTimeout(context.Background(), 30*time.Second)
	defer cc()
	if err := db.PingContext(cctx); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	_, err = db.ExecContext(ctx, batch)
	if ctx.Err() == context.DeadlineExceeded {
		return context.DeadlineExceeded
	}
	if err == nil {
		return errors.New("the batch ended before its timeout")
	}
	return err
}
GO
(cd "$TMPD/attn" && GOFLAGS=-mod=mod go build -o "$TMPD/attn-bin" .) || fail "T3: the Go client's build"
export ATTN_DSN="sqlserver://sa:$(urlq "$SA_PW")@127.0.0.1:$PORT_SQL?database=pgvctr&encrypt=true&TrustServerCertificate=true"
attn() { "$TMPD/attn-bin" -app "$1" -n "$2" -sql "$3" -timeout 2s > "$TMPD/attn.out" 2>&1 || { cat "$TMPD/attn.out" >&2; fail "T3: the client ($1, $2)"; }; }
NX=0; LASTX=0
# a read of the capture about 60 s after the one before (the sessions dispatch every 5 s: 7 s after a load at least)
xr() { local w=$(( 60 - ($(date +%s) - LASTX) )); (( w > 7 )) || w=7; sleep "$w"; col mssql_xe; LASTX=$(date +%s); NX=$((NX + 1)); }
# PerformanceMonitor's rule in python over the stored reads and rows: the newest done read's counted and left-out rates
hand() { pq "SELECT 'r|' || extract(epoch FROM snapshot_at) || '|' || coalesce(counter::text, '') FROM pgvigil.mssql_attention_reads WHERE instance_id = $SB AND read_done AND state = 'running'
  UNION ALL SELECT 'e|' || extract(epoch FROM snapshot_at) || '|' || coalesce(pgvigil.mssql_attention_left_out(program_name, statement, interrupt_us), '')
    FROM pgvigil.mssql_attentions WHERE instance_id = $SB" > "$TMPD/hand"
  python3 - "$TMPD/hand" <<'PY'
import sys
reads, rows, ctr = [], [], {}
for l in open(sys.argv[1]):
    f = l.rstrip('\n').split('|')
    if f[0] == 'r':
        reads.append(float(f[1])); ctr[float(f[1])] = int(f[2]) if f[2] else None
    else: rows.append((float(f[1]), f[2]))
runs = sorted(reads, reverse=True)
runs = [r for r in runs if r >= runs[0] - 3600] if runs else runs   # ReadLookbackMinutes 60
if len(runs) < 2: print('none'); sys.exit(0)
oldest = 0
for k in range(len(runs) - 1):            # AttentionEvaluator.OldestTaken
    oldest = k
    if (runs[0] - runs[k + 1]) / 60 >= 3: break
base, newest = runs[oldest + 1], runs[0]
cov = max(1.0, (newest - base) / 60)
c = sum(1 for s, w in rows if base < s <= newest and w == '')
x = sum(1 for s, w in rows if base < s <= newest and w != '')
# PerformanceMonitor's judged count: the counter's change times the stored share; the whole change with no row; the
# rows alone when a counter is missing or went down
tot = None if ctr.get(newest) is None or ctr.get(base) is None else ctr[newest] - ctr[base]
if tot is not None and tot >= 0:
    c, x = (tot, 0) if c + x == 0 else (tot * c / (c + x), tot * x / (c + x))
print(f'{c / cov:.2f}|{x / cov:.2f}')
PY
}
fn() { echo "$(xpoint "$SB" client_timeouts_per_min)|$(xpoint "$SB" client_timeouts_left_out_per_min)"; }
# same <a|b> <c|d>: the two pairs within 0.01 (PostgreSQL's numeric round and python's format may differ in the last digit)
same() { python3 -c "import sys; a = [float(x) for x in sys.argv[1].split('|')]; b = [float(x) for x in sys.argv[2].split('|')]; sys.exit(0 if len(a) == len(b) == 2 and all(abs(x - y) <= 0.011 for x, y in zip(a, b)) else 1)" "$1" "$2" 2>/dev/null; }
ctr() { pq "SELECT coalesce(counter, 0) FROM pgvigil.mssql_attention_reads WHERE instance_id = $SB ORDER BY snapshot_at DESC LIMIT 1"; }
# mark <marker>: the stored rows with the marker per program and reason, 'program:rows:reason ; ...' in order (F1 part
# B, finding 4: each app's own count, so a double on one and a loss on another cannot sum to the total)
mark() { pq "SELECT coalesce(string_agg(x.program_name || ':' || x.n || ':' || x.reason, ' ; ' ORDER BY x.program_name COLLATE \"C\", x.reason COLLATE \"C\"), 'none')
  FROM (SELECT program_name, coalesce(pgvigil.mssql_attention_left_out(program_name, statement, interrupt_us), 'counts') AS reason, count(*) AS n
          FROM pgvigil.mssql_attentions WHERE instance_id = $SB AND statement LIKE '%$1%' GROUP BY 1, 2) x"; }
pq "SELECT count(*) FROM pgvigil.mssql_attention_reads WHERE instance_id = $SB" > "$TMPD/nx0"; NX0=$(cat "$TMPD/nx0")
xr; xr
RX=$(xrule chkbox); [[ -n "$RX" ]] || fail "T3: the instance rule on chkbox was refused"

# T3a: 30 cancels under an application of no rule
M1="pgvchk-t3a-$SUF"; C0=$(ctr)
attn proof-app 30 "WAITFOR DELAY '00:00:10'; /* $M1 */"; xr
K1=$(mark "$M1"); C1=$(ctr); H1=$(hand); F1=$(fn); run; S3a=$(xstate "$SB")
IU=$(pq "SELECT min(interrupt_us) || '|' || max(interrupt_us) FROM pgvigil.mssql_attentions WHERE instance_id = $SB AND statement LIKE '%$M1%'")
echo "   T3a: rows $K1, the counter $C0 -> $C1, interrupt_us $IU, by hand $H1, the function $F1 -> $S3a"
[[ "$K1" == "proof-app:30:counts" ]] || fail "T3a: the stored rows [$K1] (want proof-app:30:counts)"
(( C1 - C0 >= 30 )) || fail "T3a: the counter moved $((C1 - C0)) for 30 stored rows"
python3 -c "import sys; a, b = map(int, sys.argv[1].split('|')); sys.exit(0 if 1500000 <= a and b <= 3000000 else 1)" "$IU" \
  || fail "T3a: interrupt_us [$IU] is not about the client's 2 s timeout (PerformanceMonitor's reading)"
same "$H1" "$F1" || fail "T3a: the function [$F1] against PerformanceMonitor's rule by hand [$H1]"
python3 -c "import sys; v = float(sys.argv[1].split('|')[0]); sys.exit(0 if 9.999 < v < 59.999 else 1)" "$F1" || fail "T3a: the point [$F1] is outside the warning band (the reads' spacing)"
[[ "$S3a" == warning ]] || fail "T3a: the rule's state [$S3a] (want warning)"
for _ in 1 2 3 4 5; do xr; H=$(hand); [[ "${H%%|*}" == 0.00 ]] && break; done
F=$(fn); run; S=$(xstate "$SB"); echo "   T3a clear: by hand $H, the function $F -> $S"
[[ "${H%%|*}" == 0.00 && "$S" == ok ]] && same "$H" "$F" || fail "T3a: the clear [$H|$F|$S]"
ok "T3a: 30 cancels stored once each (interrupt_us about the timeout), the rate as PerformanceMonitor's rule, warning, then ok"

# T3b: SSMS IntelliSense and a VS Code metadata connection, left out by name
M2="pgvchk-t3b-$SUF"
attn "Microsoft SQL Server Management Studio - Transact-SQL IntelliSense" 60 "WAITFOR DELAY '00:00:10'; /* $M2 */"
attn vscode-mssql-ObjectExplorer 20 "WAITFOR DELAY '00:00:10'; /* $M2 */"; xr
K2=$(mark "$M2"); H2=$(hand); F2=$(fn); run; S3b=$(xstate "$SB")
echo "   T3b: rows $K2, by hand $H2, the function $F2 -> $S3b"
[[ "$K2" == "Microsoft SQL Server Management Studio - Transact-SQL IntelliSense:60:SSMS IntelliSense ; vscode-mssql-ObjectExplorer:20:VS Code mssql metadata" ]] \
  || fail "T3b: the stored rows [$K2]"
same "$H2" "$F2" && [[ "${F2%%|*}" == 0.00 && "$S3b" == ok ]] || fail "T3b: [$H2|$F2|$S3b] (want the counted rate 0, ok)"
ok "T3b: 80 tool cancels left out by name, 60 and 20 each under its own reason: the counted rate 0, ok; the left-out rate as recomputed"

# T3c: azdata - the metadata shape left out, the query editor's batches counted
M3="pgvchk-t3c-$SUF"
attn azdata 10 "create table #sver (a int); WAITFOR DELAY '00:00:10'; /* $M3 s */"
attn azdata 10 "WAITFOR DELAY '00:00:10'; /* $M3 q */"; xr
K3s=$(mark "$M3 s"); K3q=$(mark "$M3 q"); H3=$(hand); F3=$(fn)
echo "   T3c: the metadata shape $K3s, the editor $K3q, by hand $H3, the function $F3"
[[ "$K3s|$K3q" == "azdata:10:Azure Data Studio metadata|azdata:10:counts" ]] && same "$H3" "$F3" || fail "T3c: [$K3s|$K3q|$H3|$F3]"
ok "T3c: azdata's 'create table #sver' left out, its query editor's batches counted"

NR=$(pq "SELECT count(*) || '|' || bool_and(read_done) FROM pgvigil.mssql_attention_reads WHERE instance_id = $SB")
[[ "$NR" == "$((NX0 + NX))|true" ]] || fail "T3: the reads table [$NR] (want $((NX0 + NX)) rows, every one done)"
# the reads table's cost (F1 part B, finding 2; the design's F3): printed for the report, not judged
CS=$(pq "SELECT count(*) || ' reads, ' || coalesce(round(avg(pg_column_size(a.*)))::text, '-') || ' bytes a row, about '
  || coalesce(round(avg(pg_column_size(a.*)) * 1440)::text, '-') || ' bytes a day per instance at one read a minute (before its index entries)'
  FROM pgvigil.mssql_attention_reads a WHERE a.instance_id = $SB")
CT=$(pq "SELECT pg_size_pretty(pg_total_relation_size('pgvigil.mssql_attention_reads')) || ' the reads table with its indexes; '
  || pg_size_pretty(coalesce((SELECT sum(pg_relation_size(t.relid)) FROM pg_partition_tree('pgvigil.mssql_attentions_read_idx') t), 0)) || ' the attentions'' read index over its partitions'")
echo "   the cost: $CS; $CT"
NS1=$(pq "SELECT count(*) FROM pgvigil.mssql_attentions WHERE instance_id = $SB AND interrupt_us < 1000")
if [[ "$NS1" == 0 ]]; then echo "NOT PROVEN live: no cancel under 1 ms (the floor is proven on the function, T0)"
else [[ $(pq "SELECT count(*) FROM pgvigil.mssql_attentions WHERE instance_id = $SB AND interrupt_us < 1000 AND pgvigil.mssql_attention_left_out(program_name, statement, interrupt_us) IS NULL") == 0 ]] \
  || fail "T3: a cancel under 1 ms counted"; ok "T3: $NS1 live cancel(s) under 1 ms left out"; fi
curl -fs -m 20 "http://127.0.0.1:$PORT/api/mssql/xe?instance=$SB&part=attentions&from=$(urlq "$(date -u -d '-30 min' +%Y-%m-%dT%H:%M:%SZ)")&to=$(urlq "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" > "$TMPD/att.json" \
  || fail "T3: GET /api/mssql/xe?part=attentions: $(tail -3 "$TMPD/serve.log")"
python3 - "$TMPD/att.json" "$M2" "$M3" <<'PY' || fail "T3: the XE API's left_out"
import json, sys
t = json.load(open(sys.argv[1]))['attentions']; rows = [dict(zip(t['columns'], r)) for r in t['rows']]
def why(m): return sorted({str(r.get('left_out')) for r in rows if m in (r.get('statement') or '')})
got = (why(sys.argv[2]), why(sys.argv[3] + ' s'), why(sys.argv[3] + ' q'))
print(f'   the XE API: {got}')
sys.exit(0 if got == (['SSMS IntelliSense', 'VS Code mssql metadata'], ['Azure Data Studio metadata'], ['None']) else 1)
PY
xend "$RX"
ok "T3: one mssql_attention_reads row per read, all done; the XE API names each left-out reason"
fi

echo "== G. the floors: not judged under a floor (FL6) =="
# gpart <G3|G4|G5|G6>: true when the run judges that part (all of G, or from G_FROM on)
gpart() { [[ -z "$G_FROM" || "${1#G}" -ge "${G_FROM#G}" ]]; }
# GC: one CHECK on alert_rule_state.state, naming 'na' (a DROP CONSTRAINT IF EXISTS of a wrong name passes silently)
if [[ -z "$G_FROM" ]]; then
GC=$(pq "SELECT count(*) || '|' || coalesce(bool_and(pg_get_constraintdef(oid) LIKE '%''na''%'), false) FROM pg_constraint
  WHERE conrelid = 'pgvigil.alert_rule_state'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%state%'")
[[ "$GC" == "1|t" ]] || fail "GC: alert_rule_state's checks on state [$GC] (want one, naming 'na')"
ok "GC: one check on alert_rule_state.state, 'na' in it"
fi
# instance rule helpers: on <metric> <warning> <critical> -> rule_id; off <rule_id>
on() { rule "{\"op\":\"add\",\"ui_user\":\"proof402\",\"metric\":\"counters.$1\",\"op_dir\":\"above\",\"scope\":\"instance\",\"instance_name\":\"chkbox\",\"warning\":$2,\"critical\":$3,\"for_minutes\":0}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["rule_id"] if d["outcome"] == "done" else "")'; }
off() { rule "{\"op\":\"end\",\"ui_user\":\"proof402\",\"rule_id\":\"$1\"}" >/dev/null; }
vt() { pq "SELECT coalesce(pgvigil.metric_num(value), 'NULL') || '|' || coalesce(pgvigil.metric_num(threshold), 'NULL') FROM pgvigil.alert_rule_state
  WHERE instance_id = $SB AND metric = 'counters.$1' AND database = ''"; }
newest() { pq "SELECT coalesce(pgvigil.metric_num(value), 'NULL') FROM pgvigil.metric_points($SB, 'counters', now() - interval '10 minutes', now()) WHERE metric = '$1' ORDER BY at DESC LIMIT 1"; }
# quiet: a read 60 s after the one before; while it reads 5 batch requests a second or more (QUIET_FS=1: or a full scan
# a second), up to two more reads 60 s apart, each printed (a CEIP burst over one window: finding 6)
QUIET_FS=0
quiet() { local n b f; sleep 60; col mssql_counters
  for n in 1 2; do b=$(raw 'SQL Statistics' 'Batch Requests/sec'); f=$(raw 'Access Methods' 'Full Scans/sec')
    python3 -c "import sys; b, f = (float(x or 99) for x in sys.argv[1:3]); sys.exit(0 if b >= 5 or (sys.argv[3] == '1' and f >= 1) else 1)" "$b" "$f" "$QUIET_FS" || return 0
    echo "   the quiet read is over a floor (batch requests ${b:-none}/s, full scans ${f:-none}/s): one more read 60 s later ($n of 2)"
    sleep 60; col mssql_counters; done; }
# raw <object> <counter>: the counter's rate at the newest instance read, unrounded (rates() rounds to 2 places: a rate
# in [4.995, 5) printed 5.00 and failed G1's gate though 0152 read it under the floor; finding 8); '' = no rate
raw() { pq "SELECT max(v.rate)::double precision FROM pgvigil.mssql_counter_values($SB, (SELECT max(snapshot_at) FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance') - interval '1 second', now(), 'instance') v
  WHERE v.object = '$1' AND v.counter = '$2' AND v.inst = '_Total'"; }
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
  QUIET_FS=$([[ "$m" == full_scans_per_search ]] && echo 1 || echo 0)
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
QUIET_FS=0
ok "G1, G2: under a floor compiles_per_100_batches and full_scans_per_search read 'na' with no finding; the state carries the input's value and the floor"
else echo "   GC, G0-G2 skipped (G_FROM=$G_FROM)"; fi
# G3: the transitions through the sender
mkdir -p "$TMPD/drop"; CFGA=$TMPD/ma.yaml; cp "$CFG" "$CFGA"
printf 'alerts:\n  - {name: drop, kind: file, min_severity: warning, clear_after: 0, instances: [chkbox], file: {dir: %s}}\n' "$TMPD/drop" >> "$CFGA"
pass() { "$TMPD/pgvigil" alerts -config "$CFGA" > "$TMPD/pass.$1.out" 2>&1 || fail "G: the sender's pass $1: $(tail -3 "$TMPD/pass.$1.out")"
  ! grep -q 'alert rules not judged' "$TMPD/pass.$1.out" || fail "G: pass $1: $(cat "$TMPD/pass.$1.out")"; }
files() { python3 -c 'import glob, json, sys
print(sum(1 for f in glob.glob(sys.argv[1] + "/*.json") if json.load(open(f)).get("event") == sys.argv[2]
          and "compilations per 100 batch requests" in json.load(open(f)).get("setting", "")))' "$TMPD/drop" "$1"; }
sent() { echo "firing $(files firing) resolved $(files resolved) escalated $(files escalated) repeat $(files repeat)"; }
loadread() { col mssql_counters; p_compiles; sleep 2; col mssql_counters; }
M=compiles_per_100_batches
step() { # step <label> <want state> <want files>
  local st; st=$(state "$M"); echo "   $1: $st, point $(newest "$M"), batch requests $(newest batch_requests_s)/s; drop: $(sent)"
  [[ "$st" == "$2" && "$(sent)" == "$3" ]] || fail "G: $1: state $st (want $2), drop [$(sent)] (want [$3])"; }
NONE="firing 0 resolved 0 escalated 0 repeat 0"
if gpart G3; then
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
fi
# G4: the run break (FL3's change 1)
if gpart G4; then
r3=$(rule "{\"op\":\"add\",\"ui_user\":\"proof402\",\"metric\":\"counters.$M\",\"op_dir\":\"above\",\"scope\":\"instance\",\"instance_name\":\"chkbox\",\"warning\":0,\"critical\":null,\"for_minutes\":3}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["rule_id"] if d["outcome"] == "done" else "")'); [[ -n "$r3" ]] || fail "G4: the 3-minute rule was refused"
rm -f "$TMPD"/drop/*.json
quiet; quiet; quiet; pass g4a; step "a 3-minute rule after three quiet reads" na "$NONE"
# the load straight after the third quiet read: the point before it is that read's no-value one (finding 9)
p_compiles; sleep 2; col mssql_counters; pass g4b; step "after one load (the run starts at the load: pending)" pending "$NONE"
off "$r3"
ok "G4: a read under the floor breaks the run: three quiet minutes and one load read 'pending', no file"
fi
# G5: warning -> na -> warning, then resolved
if gpart G5; then
rm -f "$TMPD"/drop/*.json
rid=$(on "$M" 0 null); [[ -n "$rid" ]] || fail "G5: the warning rule was refused"
quiet; pass g5a; step "a warning-only rule after a quiet read" na "$NONE"
loadread; pass g5b; step "after a load (na -> warning)" warning "firing 1 resolved 0 escalated 0 repeat 0"
quiet; pass g5c; step "after a quiet read (warning -> na)" na "firing 1 resolved 0 escalated 0 repeat 0"
quiet; pass g5d; step "after one more read and pass" na "firing 1 resolved 1 escalated 0 repeat 0"
off "$rid"
ok "G5: na -> warning sends one firing; warning -> na one resolved"
fi
# G6: a flap inside the clear delay stays one open alert (a destination with clear_after 5m: a duration needs its unit,
# '300' was refused by the configuration - finding 1)
if gpart G6; then
CFGA0=$CFGA; CFGA=$TMPD/mb.yaml; cp "$CFG" "$CFGA"; rm -f "$TMPD"/drop/*.json
printf 'alerts:\n  - {name: drop, kind: file, min_severity: warning, clear_after: 5m, instances: [chkbox], file: {dir: %s}}\n' "$TMPD/drop" >> "$CFGA"
rid=$(on "$M" null 0); [[ -n "$rid" ]] || fail "G6: the firing rule was refused"
loadread; pass g6a; step "a firing rule after a load" critical "firing 1 resolved 0 escalated 0 repeat 0"
quiet; pass g6b; step "after a quiet read (na, inside the clear delay)" na "firing 1 resolved 0 escalated 0 repeat 0"
# a second quiet read and pass: with clear_after 0 this pass resolves (G3's b4); held by the 5 minutes, it does not
# (finding 3: without it the row could not fail on the delay)
quiet; pass g6b2; step "after a second quiet read (na, still inside the 5-minute clear delay)" na "firing 1 resolved 0 escalated 0 repeat 0"
loadread; pass g6c; step "after a load within the 5 minutes (critical again)" critical "firing 1 resolved 0 escalated 0 repeat 0"
off "$rid"; CFGA=$CFGA0
ok "G6: a flap across the floor inside the clear delay stays one open alert (one firing, no resolved, through two passes that would resolve without the delay)"
fi

echo "== F. the seeded rows at the end =="
pq "SELECT metric || '|' || rule_id || '|' || op || '|' || coalesce(warning::text, '') || '|' || coalesce(critical::text, '') || '|' || for_minutes || '|' || enabled || '|' || scope
      FROM pgvigil.alert_rules WHERE created_by = 'pgvigil' AND client = '0153 seed' AND ended_at IS NULL ORDER BY metric" > "$TMPD/seed-f"
# the two seeds the proof ends: page reads at A, lock timeouts at B2
grep -vE '^counters\.(page_reads_s|lock_timeouts_gt0_s)\|' "$TMPD/seed-a" | diff - "$TMPD/seed-f" >&2 || fail "F: a seeded row changed"
ok "F: the $(wc -l < "$TMPD/seed-f") live seeded rows as read at A (rule_id, op, thresholds, for_minutes, off)"

echo "NOT PROVEN HERE: free list stalls, lazy writes, a low hit ratio, a low page life expectancy and a database taken offline at the seeded thresholds; SQL Server 2016, Managed Instance, a Windows host"
[[ -n "$D_FROM" ]] && { echo "PARTIAL: D from $D_FROM (a diagnostic run, not a proof)"; exit 3; }
[[ "$QUIET" != 60 ]] && { echo "PARTIAL: QUIET=$QUIET, not the product's 60 s (a diagnostic run, not a proof)"; exit 3; }
[[ -n "$G_FROM" ]] && { echo "PARTIAL: G from $G_FROM (a diagnostic run, not a proof)"; exit 3; }
echo "PROOF OK: mssql counter checks (A B C D E T G F)"
