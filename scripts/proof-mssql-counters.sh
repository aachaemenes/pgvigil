#!/usr/bin/env bash
# Proof of task 401 (B3): the SQL Server counter list made configurable, the base arithmetic, the counters the tools
# agree pgvigil lacks - mssql_counters, mssql_counters_db and mssql_counter_catalog (internal/mssql/counters.go), 0152,
# GET / POST /api/mssql/counteradmin, the Metrics page's counters section and Admin > Counters - against hand reads of
# sys.dm_os_performance_counters on the same server.
# Needs: docker (mcr.microsoft.com/mssql/server images), go, psql, curl, python3, node, npm, chromium, ss, and:
#   ADMIN_DSN          a superuser connection to a PostgreSQL sandbox in keyword form (default 'host=127.0.0.1 port=5432
#                      user=postgres dbname=postgres'), with no password in it (PGPASSWORD or .pgpass: it reaches psql's
#                      argv); the proof makes its own repository database and drops it.
#   PGVIGIL_IMAGES     the SQL Server images, the first the full run, the others the version run (default
#                      '2022-latest 2019-latest').
#   PGVIGIL_SHOTS      where the page shots go (default: a folder of the run, removed with it).
#   PGVIGIL_WIRING     1 (default) applies scripts/proof-mssql-counters-wiring.patch (the lead's files) to the run's own copy
#                      of the tree (under its folder) when it lacks the counters' runner hook; 0 = the copy as it is. The
#                      web bundle and the binary are built in that copy; the tree the proof runs from is never changed.
#   PGVIGIL_LOGINS_WANT  the count the logins rows of D and L want (default 41: the 40 provoked and the collector's
#                      own). Any other value is the red row of the rows' own witness: the proof stops at D with the
#                      FAIL line carrying what its event session saw (see lgs_start).
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment. Only the
# collection a step names runs (pgvigil collect -once): no other mssql_* collection reads the server meanwhile.
#
# Expected (written before the first run; red on f8e89d2 at A: 'unknown collection mssql_counters'):
#  A. the first image's container, a database pgvctr (log 1 MB, growth 1 MB, full recovery with one full backup taken,
#     so the log grows and stays), snapshot isolation allowed; a monitor login with VIEW SERVER STATE; migrate ok;
#     mssql_counters, mssql_counters_db and mssql_counter_catalog each run; the list = every default (the same
#     object, counter and instance rows, not only as many).
#  B. a hand read right before and right after one mssql_counters read: every stored raw value of a rate, count or
#     average series (and an average's base) lies between the two hand reads (before <= stored <= after: they only
#     grow); the gauges and fractions outside [min, max] of the two hand reads are counted and listed, not judged.
#     From review part 4 (finding 1): an average's or a fraction's base is checked against the hand reads of ITS base
#     row, named by the proof's own rule (the PERF_LARGE_RAW_BASE row, type 1073939712, next after the counter within
#     its object and instance in the DMV's order - not counters.go's names): an average's stored base between them, a
#     fraction's listed when outside; a stored series in neither hand read, or an average or fraction with no base row
#     so found, fails B. The same bracket on one mssql_counters_db read (finding 2).
#  C. from two stored reads: every rate = (value - value before) / the reads' interval by the server's clock (3
#     places), every count's change = value - value before, every average = change in value / change in base, every
#     fraction = 100 * value / base, as mssql_counter_newest and metric_points return them; the ratio metrics equal
#     their rates (read as double precision, as 0152's points are), a floored ratio under its floor (0152's
#     metric_floors) a point with no value (NULL); C's 3 s window judges the floor on whichever side it reads (printed)
#     for compiles_per_100_batches and full_scans_per_search - both sides of all four floored keys are the 402 proof's G0.
#     Between the two reads 20 runs of a procedure that recompiles and 20 distinct batches (review part 4, finding 11):
#     compilations at 1/s or more and recompiles_per_100_compiles above 0, equal to 100 x its two rates (a wrong formula
#     no longer hides under the floor).
#  D. provoked between two reads with nothing else connected, each change read from the store minus pgvigil's own
#     logins (one per collector read):
#     Logins/sec and Logouts/sec + 40 each, exact (under the proof's own event session on login, logout and error
#     18456 by program, read only when the count is off: its rows in the FAIL line; PGVIGIL_LOGINS_WANT=40 is its red
#     row); Batch Requests/sec + 200 (200 batches) over the collector's own count per
#     read (the least of three quiet pairs; review part 4, finding 2), more than 20 over it printed as background;
#     SQL Errors User Errors + 12 (RAISERROR 16), Info Errors + 7 (RAISERROR 10) and two more per login in the window
#     (5701 / 5703: runs proof4-proof6 read + 13) - read and printed, not judged, Kill Connection Errors + 3 (RAISERROR 20 WITH LOG, three connections, in a
#     phase of their own: run 3 read User Errors + 15 with them in the same phase) read and printed with that phase's
#     User Errors; DB Offline Errors: not provable on a box (Microsoft: a severe error that takes the database
#     offline), read at 0 in zero_series; pgvctr Write Transactions/sec + 500 or more (500 one-row commits), Log Flush
#     Waits/sec more than 0; Log Growths of pgvctr 1 or more, then a flat read with its row stored at a change of 0 and
#     log_growths 0 in metric_points (F2's case 1); Lock Timeouts (timeout > 0)/sec + 6 (LOCK_TIMEOUT 200 behind a held
#     lock, its X lock seen in sys.dm_tran_locks before each phase) and unmoved by 6 more at LOCK_TIMEOUT 0 while it
#     still holds, those six on the plain Lock Timeouts/sec (+ 6 or more there, + 12 or more in all); the average lock wait
#     between 150 and 600 ms; Update conflict ratio's value + 4 (four 3960 conflicts, each UPDATE sent once the snapshot
#     transaction is seen in its WAITFOR) over a base change of 4 or more;
#     Auto-Param Attempts/sec + 20 or more (20 literal queries), Forced Parameterizations/sec + 20 or more under
#     PARAMETERIZATION FORCED; Page compression attempts/sec more than 0 (a PAGE-compressed insert); Cursor
#     Requests/sec + 5 or more; Deprecated Features Usage of '::' function calling syntax + 3; Batch Resp Statistics
#     Elapsed Time:Requests + 5 or more in the 100-200 ms bucket (125 ms waits) and + 3 or more in the 1-2 s bucket (and the histogram
#     function says the same); Resource Pool Stats CPU usage % (default) read under a CPU loop above 0 and at most 100,
#     equal to 100 * value / base of its stored pair; Misguided plan executions/sec read and printed (a plan guide whose
#     index was dropped: the guide's creation and the drop checked, not swallowed) - NOT PROVEN live if it does not
#     move (review part 4's probe on the proof box: it stayed at 0).
#  E. the list: a pgvigil.yaml instance line adds General Statistics / Logical Connections (read at the next read) and
#     removes Deprecated Features / Usage (not read); an Admin fleet row adding Usage back loses to the instance's yaml
#     line (narrowest scope); an Admin instance row adding it wins over the yaml line at the same scope (read again);
#     an Admin tag row (the instance's tag env:ctrproof) removing Plan Cache / Cache Pages takes it out, an Admin
#     instance row adding it back wins; Admin and yaml both refuse removing Logins/sec ('read by ...'), Admin a Batch Resp
#     Statistics bucket too (the histogram, part 3's finding 4); a removal of a
#     counter in use from the yaml is refused at load; mssql_counter_yaml holds the lines the runner used. Admin and the
#     yaml both refuse a kind on SQL Errors / Errors/sec ('its kind stays') and on a DMV column (sys.dm_os_schedulers /
#     yield_count: 'is a DMV column'). A yaml line removing one instance of
#     Deprecated Features / Usage (a feature the server lists) takes that feature out of the next read (no stored row,
#     not in zero_series) while another feature of the same counter is still read; the list's every-instance line
#     names it in 'except'.
#  F. the gap rule: Pages Allocated/sec removed for two reads and added back: the two reads without it hold no row and
#     do not name it in zero_series; its first read back has a stored row (not a zero_series 0) with no change and no
#     rate; the read after has both. F15 (a gap in time, review part 1 S3): a read 125 s after the one before (over twice
#     the 60 s default) has no change and no rate on any series; the read 3 s after it has them.
#  G. a restart (docker restart): the first read after it has no rate, no change and no average on any series, by the
#     restart rule (that read's after_gap false, so F15's gap rule did not make it so; review part 4, finding 14); the
#     read after has them.
#  H. zero points: errors_offline_s is 0 at every instance read of the window (as many points as reads); errors_kill_s
#     is not: at D's severe-phase read its point is above 0 and equal to that read's stored rate (review part 4,
#     finding 3: a zero_series 0 winning over a sample row would chart it as 0).
#  P. review part 2's rows, on a synthetic instance ctrsyn (tags env:synx, env:syny; no server: the counter import
#     called with built payloads, the jobs import's writes made as 0094's import_mssql_jobs makes them):
#     P1 (finding 1, G329) a job that ends between two counter reads and is read by the jobs read after them: the
#        newest agent_jobs_failed point (at that jobs read) is 1, agent_jobs_started 1, agent_active_jobs 0; a job
#        running at the next jobs read: agent_active_jobs 1 and agent_jobs_started 1 there (red today: the newest
#        point is the counter read's, 0).
#     P2 (finding 2, F15) reads at 10:00, 13:00, 17:00 and 17:01: no change and no rate at 13:00 nor at 17:00 (a stop
#        right after a gap read), both at 17:01 (red today: 17:00 has a rate over four hours).
#     P3 (finding 4) update_conflict_pct 0 with 1 snapshot update in 60 s (under 1/s, one conflict), 5 with 6
#        conflicts in 120 updates (red today: 100).
#     P4 (finding 3) two tag rows at one level: a removal (older) and an add (newer) - the counter is in the list, and
#     mssql_counter_layers_won names ONE winner, the add (part 3's finding 2: the Admin page's 'in force');
#        the removal written again (newer) - it is not (red today: the older row wins by the plan's order).
#     P5 (finding 3) a fleet row, then one naming the same counter in lower case: the second answers 'row <n>
#        replaced by row <m>' (red today: 'added', two live rows).
#     P6 (finding 7) a fleet add of Databases / Log Growths with no kind: the list's kind is 'count', the default's
#        (red today: empty). P7 (finding 8) Admin refuses SYS.DM_OS_SCHEDULERS / yield_count with a kind ('is a DMV
#        column'; red today: done). P8 (review part 4, finding 11; F9) an average over one 5-minute step spanning two
#        reads with unequal base changes (60 / 120, then 6 / 600): mssql_counter_series_between gives 66 / 720 = 0.0917,
#        not the mean of the two figures (0.255). Every row P makes is ended; ctrsyn is made inactive at the end.
#  I. F1: mssql_cpu_newest's rg_active_requests NULL with 0124's own body (made in pg_temp from the file) after the
#     counters left mssql_cpu, not NULL with the join's body.
#  J. the API: GET /api/mssql/counteradmin (no instance: config, defaults, log, catalog; with the instance: layers,
#     catalog, absent, histogram) answers every part; with the UI login and the actions door's audit login: POST add
#     done (200), a removal of a counter in use refused (409, 'read by', the body's error naming it: part 3's finding 1), end done; without a session 401, without the
#     header 403; a -no-login serve: writable false naming -no-login, POST 403, nothing written; mssql_counter_config_log
#     holds exactly the done and refused attempts by the proof's user from 127.0.0.1.
#  K. the pages in headless Chromium, light and dark: the instance's Metrics page shows the counters grid with the kind
#     and figure columns (rows = /api/mssql/counters' now part), 'Batch response times' with 17 buckets, 'Listed but
#     not read', the 'Counters' family grid; Admin > Counters shows 'Rows made here' (rows = the config part),
#     'The defaults' (rows = the defaults part), 'Counters the servers have', 'Log', and its Save and End controls off
#     with their reason on a -no-login serve (Save row: the -no-login reason beside it; each End: a space, then 'off
#     here: the line above says why', the long reason in its title; the page's line 'Edits are off here: ...
#     -no-login'); no error box, no exception.
#  N. D6 (the rows on other slices' pages, WIRING hunks), over five reads (R0 early in a minute; R1 in the next, the wait
#     busy at six batches a second; R2 after 20 distinct batches; R3 mssql_cpu alone in a later minute; R4 30 s idle
#     after it; R0-R2 with mssql_counters): /api/perfsummary's mssql part over (R0, R2] reads at least 1 batch/s (5
#     with 402's FL5 in the tree, its response carrying compiles_floor: the floors' part B, finding 5) and
#     gives ctrbox compiles_per_100 = 100 x the change in SQL Compilations / Batch Requests read by hand from SQL Server
#     around those reads (within the 10 batches and 10 compilations the reads around the hand reads add); over (R3, R4]
#     under 1 batch/s it gives 0 (with FL5: under 5 batch requests/s no ratio, compiles_under_floor true and
#     compiles_floor 5; else 'NOT PROVEN live: the floor'); the CPU API's sched part carries
#     failed_to_create_worker on exactly the steps that hold an instance counter read (0 on a healthy box), on two steps
#     at least, NULL on R3's; the Memory API's clerk_stats names MEMORYCLERK_SQLBUFFERPOOL 'Buffer Pool'; the pages
#     show ctrbox's 'compilations per 100 batches' cell = the API's over the hour, the scheduler trend's 'schedulers that
#     failed to create a worker' (listed only when a step has a value), the clerks grid's 'what it is' with Buffer Pool.
#  L. the version run on each further image: A's setup, B's bracket and C's arithmetic, D's logins, errors and log
#     growth, the list = every default.
#  M. the measured size (review part 4, finding 10): rows per read of each scope, the sample rows stored per read and
#     their share of the rows read, the box's database count; the bytes measured as pg_total_relation_size of
#     mssql_counter_sample before and after the run's reads (not pg_column_size); a day at one instance read a minute and
#     one database read per 5 minutes stated per instance as measured, per database, and for a busy server (every row
#     read stored); printed, not judged.
# NOT PROVEN HERE: SQL Server 2016 (no Linux image: dba-lab-win's queue), Managed Instance, RDS, Cloud SQL, a Windows
#   host; DB Offline Errors moving; two memory nodes (one Buffer Node in a container); Misguided plan executions moving
#   if D says so.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
read -r -a IMAGES <<<"${PGVIGIL_IMAGES:-2022-latest 2019-latest}"
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
LBL=pgvigil-proof=ctr
PGDB=pgv_ctr_$SUF; MON=pgv_cmon_$SUF; UIUSER=proofctr$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SQL=; SRVPID=; SRV2PID=; CHRPID=
SHOTS=${PGVIGIL_SHOTS:-$TMPD/shots}; mkdir -p "$SHOTS"
SA_PW=$(pw); MON_PW=$(pw); UIPW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\nMSSQL_PID=Developer\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  [[ -n "$SRV2PID" ]] && kill "$SRV2PID" 2>/dev/null || true
  if [[ -n "$CHRPID" ]]; then kill -- "-$CHRPID" 2>/dev/null || kill "$CHRPID" 2>/dev/null || true; fi
  docker ps -aq --filter "label=$LBL-$SUF" | xargs -r docker rm -f -v >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
for t in docker go psql curl python3 node npm chromium setsid ss; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
# the run's own copy of the tree (review part 4, findings 7 and 8): the wiring applied there, the web bundle and the binary
# built there; the tree the proof runs from is never changed
GSRC=$TMPD/src; mkdir -p "$GSRC"
tar -C . --exclude=./web/node_modules --exclude=./.lab --exclude=./.git --exclude=./.sqltb -cf - . | tar -C "$GSRC" -xf -
if [[ "${PGVIGIL_WIRING:-1}" == 1 ]] && ! grep -q 'ListCollector' "$GSRC/internal/mssql/mssql.go"; then
  (cd "$GSRC" && { git apply scripts/proof-mssql-counters-wiring.patch 2>"$TMPD/apply.err" || patch -p1 --forward < scripts/proof-mssql-counters-wiring.patch >>"$TMPD/apply.err" 2>&1; }) \
    || fail "the wiring patch: $(cat "$TMPD/apply.err")"
  echo "wiring applied to the run's copy (config.go, mssql.go, repo.go, cpu.go, activity.go, 0190, web.go, router.ts, main.ts; D6: q_perfsummary.go, perfsummary.ts, q_mssql_perf.go, mssql_perf.ts)"
fi
freeport() { local lo=$1 hi=$2 p used
  used=$(ss -Htan) || fail "ss -Htan failed: the ports in use cannot be read"
  used=$(awk '{n = split($4, a, ":"); print a[n]}' <<<"$used" | sort -u)
  for _ in $(seq 1 50); do p=$((lo + RANDOM % (hi - lo + 1))); grep -qx "$p" <<<"$used" || { echo "$p"; return 0; }; done
  fail "no free port in $lo-$hi"
}
# sq: T-SQL as sa on the current container (stdin; -I: QUOTED_IDENTIFIER ON)
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout "${3:-180}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
sqb() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout "${3:-180}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
sqok() { local out; out=$(sqb "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
# hand: every counter row now, as object (prefix dropped) | counter | instance ('' read as _Total) | value | type
hand() { sq "SELECT SUBSTRING(RTRIM(object_name), CHARINDEX(':', object_name) + 1, 200) + '|' + RTRIM(counter_name) + '|'
  + CASE WHEN RTRIM(instance_name) = '' THEN '_Total' ELSE RTRIM(instance_name) END + '|' + CAST(cntr_value AS varchar(30)) + '|' + CAST(cntr_type AS varchar(20))
  FROM sys.dm_os_performance_counters" > "$1"; }
col() { for c in "$@"; do timeout 180 "$TMPD/pgvigil" collect -config "$CFG" -instance ctrbox -once "$c" > "$TMPD/col-$c.out" 2>&1 \
  || { cat "$TMPD/col-$c.out" >&2; fail "collect $c"; }; done; }
# the stored raw value / base / change / rate of one series at the scope's newest read ('' = no row at that read)
stored() { pq "SELECT coalesce(s.value::text, CASE WHEN k.series_id = ANY (r.zero_series) THEN '0' END, '') || '|' || coalesce(s.base::text, '') || '|' || coalesce(s.dvalue::text, '') || '|' || coalesce(s.dbase::text, '') || '|' || coalesce(s.rate::text, '')
  FROM pgvigil.mssql_counter_series k
  JOIN LATERAL (SELECT * FROM pgvigil.mssql_counter_read c WHERE c.instance_id = k.instance_id AND c.scope = pgvigil.mssql_counter_scope(k.object) ORDER BY c.snapshot_at DESC LIMIT 1) r ON true
  LEFT JOIN pgvigil.mssql_counter_sample s ON s.instance_id = k.instance_id AND s.series_id = k.series_id AND s.snapshot_at = r.snapshot_at
  WHERE k.instance_id = $SB AND k.object = '$1' AND k.counter = '$2' AND k.inst = '$3'"; }
field() { cut -d'|' -f"$2" <<<"$1"; }
chg() { field "$(stored "$1" "$2" "$3")" 3; }       # the change of a series at its scope's newest read
listed() { pq "SELECT count(*) FROM jsonb_array_elements(pgvigil.import_mssql_counter_list($SB, '$1'::jsonb)) e WHERE e->>'object' = '$2' AND e->>'counter' = '$3'"; }
readat() { pq "SELECT count(*) FROM pgvigil.mssql_counter_series k JOIN pgvigil.mssql_counter_last l ON l.series_id = k.series_id
  WHERE k.instance_id = $SB AND k.object = '$1' AND k.counter = '$2'
    AND l.server_utc = (SELECT server_utc FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = pgvigil.mssql_counter_scope('$1') ORDER BY snapshot_at DESC LIMIT 1)"; }
# The logins rows' own witness (the lead's 11-15 10:5x): an event session of the proof's own on login, logout and the
# failed login's error (18456), by program, started before a logins phase's first read and read ONLY when the count is
# not the one wanted. Its rows go into the FAIL line, so a red names the program of an extra login: box run 401m1 read
# +42 / +42 once and no log named it (a failed login moves both counters, one each, and the 2022 image makes no login by
# itself in its first four minutes: the box probe of 11-15). The verdict stays exact.
LGW=${PGVIGIL_LOGINS_WANT:-41}
lgs_start() { sqok "$1: the proof's login event session" "IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'pgv_proof_logins') DROP EVENT SESSION pgv_proof_logins ON SERVER;
CREATE EVENT SESSION pgv_proof_logins ON SERVER
  ADD EVENT sqlserver.login (ACTION (sqlserver.client_app_name, sqlserver.server_principal_name, sqlserver.client_hostname)),
  ADD EVENT sqlserver.logout (ACTION (sqlserver.client_app_name, sqlserver.server_principal_name, sqlserver.client_hostname)),
  ADD EVENT sqlserver.error_reported (ACTION (sqlserver.client_app_name, sqlserver.client_hostname) WHERE ([error_number] = (18456)))
  ADD TARGET package0.ring_buffer (SET max_memory = 8192)
  WITH (MAX_DISPATCH_LATENCY = 1 SECONDS, STARTUP_STATE = OFF);
ALTER EVENT SESSION pgv_proof_logins ON SERVER STATE = START;"; }
lgs_drop() { sq "IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'pgv_proof_logins') DROP EVENT SESSION pgv_proof_logins ON SERVER;" >/dev/null 2>&1 || true; }
# lgs_rows: the session's rows as one line, each group placed by the server's own clock at the phase's two reads (as
# stored): BETWEEN the reads is what the counters' change is made of; read after the session's 1 s dispatch latency
lgs_rows() { local t out
  sleep 2
  t=$(pq "SELECT string_agg(to_char(server_utc AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US'), '|' ORDER BY snapshot_at) FROM (SELECT server_utc, snapshot_at FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance' ORDER BY snapshot_at DESC LIMIT 2) r" 2>/dev/null) || t=
  out=$(sq "DECLARE @t0 datetime2(6) = TRY_CONVERT(datetime2(6), '${t%%|*}'), @t1 datetime2(6) = TRY_CONVERT(datetime2(6), '${t##*|}');
WITH x AS (SELECT CAST(t.target_data AS xml) AS d FROM sys.dm_xe_sessions s JOIN sys.dm_xe_session_targets t ON t.event_session_address = s.address
            WHERE s.name = N'pgv_proof_logins' AND t.target_name = N'ring_buffer'),
     e AS (SELECT n.value('@name', 'varchar(30)') AS ev, n.value('@timestamp', 'datetime2(3)') AS ts,
                  n.value('(action[@name=\"client_app_name\"]/value)[1]', 'nvarchar(128)') AS app,
                  n.value('(action[@name=\"server_principal_name\"]/value)[1]', 'nvarchar(128)') AS who,
                  n.value('(action[@name=\"client_hostname\"]/value)[1]', 'nvarchar(128)') AS host,
                  n.value('(data[@name=\"is_cached\"]/value)[1]', 'varchar(10)') AS cached,
                  n.value('(data[@name=\"message\"]/value)[1]', 'nvarchar(200)') AS msg
             FROM x CROSS APPLY x.d.nodes('/RingBufferTarget/event') q(n)),
     p AS (SELECT CASE WHEN ts > @t0 AND ts <= @t1 THEN 0 WHEN ts <= @t0 THEN -1 WHEN ts > @t1 THEN 1 ELSE 2 END AS side, ev, app, who, host, cached, msg FROM e),
     g AS (SELECT side, ev, app, who, host, cached, msg, COUNT(*) AS n FROM p GROUP BY side, ev, app, who, host, cached, msg)
SELECT CASE side WHEN 0 THEN 'BETWEEN the reads' WHEN -1 THEN 'before them' WHEN 1 THEN 'after them' ELSE 'time not placed' END + ': ' + ev + ' x' + CAST(n AS varchar(10))
       + ' program [' + ISNULL(app, '') + '] login [' + ISNULL(who, '') + '] host [' + ISNULL(host, '') + ']' + CASE WHEN cached = 'true' THEN ' (pooled)' ELSE '' END
       + ISNULL(' [' + msg + ']', '')
  FROM g ORDER BY CASE side WHEN 0 THEN 0 ELSE 1 END, side, ev, n DESC;" 2>&1 | tr '\n' ';') || true
  echo "the proof's own event session, placed by the server's clock at the two reads (${t:-not read} UTC), saw: ${out:-no row}"; }

# start <image>: a container of the image, the database and the monitor login; PORT_SQL
start() {
  SQL=pgv-ctr-$1-$SUF
  docker run -d --name "$SQL" --label "$LBL-$SUF" --memory 6g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "mcr.microsoft.com/mssql/server:$1" >/dev/null
  local r=; for _ in $(seq 1 150); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" master 15 2>/dev/null || true); [[ "$r" == 1 ]] && break; sleep 2; done
  [[ "$r" == 1 ]] || { docker logs --tail 20 "$SQL" >&2 2>&1 || true; fail "A: the $1 container did not come up in 300 s"; }
  mondsn
  sqok "A: the database" "CREATE DATABASE pgvctr ON (NAME = pgvctr, FILENAME = '/var/opt/mssql/data/pgvctr.mdf', SIZE = 16MB)
    LOG ON (NAME = pgvctr_log, FILENAME = '/var/opt/mssql/data/pgvctr_log.ldf', SIZE = 1MB, FILEGROWTH = 1MB);
    ALTER DATABASE pgvctr SET RECOVERY FULL; ALTER DATABASE pgvctr SET ALLOW_SNAPSHOT_ISOLATION ON;"
  sqok "A: the full backup that starts the log chain" "BACKUP DATABASE pgvctr TO DISK = '/var/opt/mssql/data/pgvctr.bak' WITH INIT;"
  sqok "A: the table" "CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, v int NOT NULL DEFAULT 0, pad char(200) NOT NULL DEFAULT 'a');
    INSERT dbo.t (id) SELECT TOP (2000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) FROM sys.all_objects a CROSS JOIN sys.all_objects b;" pgvctr
  sqok "A: the monitor login" "IF SUSER_ID('$MON') IS NULL CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF;
    GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON];"
}
# mondsn: the container's host port (random; a docker restart may give it a new one) and the monitor's DSN on it
mondsn() {
  PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
  [[ "$PORT_SQL" =~ ^[0-9]+$ ]] || fail "the host port of $SQL: [$PORT_SQL]"
  export PGV_CTR_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
}

# config <yaml lines for the instance>: the proof's pgvigil.yaml
config() {
  CFG=$TMPD/m.yaml
  { printf 'repository:\n  dsn: "%s"\ninstances:\n  - name: ctrbox\n    engine: sqlserver\n    dsn: env:PGV_CTR_MON\n    tags: [env:ctrproof]\n' "$PGDSN"
    if [[ -n "${1:-}" ]]; then printf '%s\n' "$1"; fi; } > "$CFG"
}

(cd "$GSRC/web" && npm ci --no-audit --no-fund >"$TMPD/web.log" 2>&1 && npm run build >>"$TMPD/web.log" 2>&1) || { tail -20 "$TMPD/web.log" >&2; fail "the web build"; }
(cd "$GSRC" && go build -o "$TMPD/pgvigil" ./cmd/pgvigil) || fail "the build"
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="${ADMIN_DSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"

echo "== A. the first image (${IMAGES[0]}) =="
start "${IMAGES[0]}"
config
"$TMPD/pgvigil" migrate -config "$CFG" > "$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "A: migrate"; }
col mssql_instance mssql_counters mssql_counters_db mssql_counter_catalog
SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'ctrbox'")
NDEF=$(pq "SELECT count(*) FROM pgvigil.mssql_counter_defaults"); NL=$(pq "SELECT jsonb_array_length(pgvigil.import_mssql_counter_list($SB, '[]'))")
# the same rows both ways, not only as many (review part 4, finding 16)
LX=$(pq "SELECT count(*) FROM ((SELECT object, counter, inst FROM pgvigil.mssql_counter_defaults
    EXCEPT SELECT e->>'object', e->>'counter', e->>'inst' FROM jsonb_array_elements(pgvigil.import_mssql_counter_list($SB, '[]')) e)
  UNION ALL (SELECT e->>'object', e->>'counter', e->>'inst' FROM jsonb_array_elements(pgvigil.import_mssql_counter_list($SB, '[]')) e
    EXCEPT SELECT object, counter, inst FROM pgvigil.mssql_counter_defaults)) d")
[[ "$NDEF" == "$NL" && "$LX" == 0 ]] || fail "A: the list holds $NL, the defaults $NDEF, $LX rows in one and not the other"
ok "A: SQL Server $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))"), migrate, the three collections, the list = every default ($NL)"
# M's measure (review part 4, finding 10): the sample table's bytes and rows here, against the end of the run's reads
# a partitioned parent holds no storage (401proof15 measured 0 bytes): the sum over its partitions
M_BYTES0=$(pq "SELECT coalesce(sum(pg_total_relation_size(relid)), 0) FROM pg_partition_tree('pgvigil.mssql_counter_sample')"); M_ROWS0=$(pq "SELECT count(*) FROM pgvigil.mssql_counter_sample")

# bracket <tag> [scope] [least]: a hand read before and after one read of the scope (instance: mssql_counters; database:
# mssql_counters_db); the stored raw values of that read between them, and an average's or fraction's base against the
# hand reads of its base row, named by the proof's own rule: the PERF_LARGE_RAW_BASE row (type 1073939712) next after the
# counter within its object and instance in the DMV's order (review part 4, finding 1: not counters.go's names)
bracket() {
  local tag=$1 sc=${2:-instance} least=${3:-300} cl=mssql_counters
  [[ "$sc" == database ]] && cl=mssql_counters_db
  sleep 2; hand "$TMPD/h0"; col "$cl"; hand "$TMPD/h1"
  pq "SELECT k.object || '|' || k.counter || '|' || k.inst || '|' || k.kind || '|' || coalesce(s.value, 0) || '|' || coalesce(s.base::text, '')
        FROM pgvigil.mssql_counter_series k
        JOIN (SELECT * FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = '$sc' ORDER BY snapshot_at DESC LIMIT 1) r ON true
        LEFT JOIN pgvigil.mssql_counter_sample s ON s.instance_id = $SB AND s.series_id = k.series_id AND s.snapshot_at = r.snapshot_at
       WHERE k.instance_id = $SB AND pgvigil.mssql_counter_scope(k.object) = '$sc' AND k.object NOT LIKE 'sys.dm_os_%'
         AND (s.series_id IS NOT NULL OR k.series_id = ANY (r.zero_series))" > "$TMPD/stored"
  python3 - "$TMPD/h0" "$TMPD/h1" "$TMPD/stored" "$tag" "$least" <<'PY'
import sys
BASE = 1073939712                      # PERF_LARGE_RAW_BASE
def load(p):
    d, seq = {}, {}
    for l in open(p):
        f = l.rstrip('\n').split('|')
        if len(f) == 5 and f[3].lstrip('-').isdigit() and f[4].isdigit():
            d[(f[0], f[1], f[2])] = int(f[3])
            seq.setdefault((f[0], f[2]), []).append((f[1], int(f[4])))
    return d, seq
(h0, seq0), (h1, _) = load(sys.argv[1]), load(sys.argv[2])
def base_of(o, c, i):
    rows = seq0.get((o, i), [])
    for k, (name, _) in enumerate(rows):
        if name == c:
            return rows[k + 1][0] if k + 1 < len(rows) and rows[k + 1][1] == BASE else None
    return None
cum_bad, moved, gone, came, unpaired, base_bad, base_moved, n, nb = [], [], [], [], [], [], [], 0, 0
for l in open(sys.argv[3]):
    o, c, i, k, v, b = l.rstrip('\n').split('|')
    v = int(v); key = (o, c, i)
    if key not in h0 and key not in h1:
        gone.append(f'{o}/{c}/{i}')
        continue
    if key not in h0 or key not in h1:
        came.append(f'{o}/{c}/{i}')
        continue
    n += 1
    lo, hi = h0[key], h1[key]
    if k in ('rate', 'count', 'average'):
        if not (lo <= v <= hi):
            cum_bad.append(f'{o}/{c}/{i} {lo} <= {v} <= {hi}')
    elif not (min(lo, hi) <= v <= max(lo, hi)):
        moved.append(f'{o}/{c}/{i} {lo} {v} {hi}')
    if b != '' and k in ('average', 'fraction'):
        bn = base_of(o, c, i)
        bk = (o, bn, i) if bn else None
        if not bk or bk not in h0 or bk not in h1:
            unpaired.append(f'{o}/{c}/{i}: no base row next after it')
            continue
        nb += 1
        blo, bhi, bv = h0[bk], h1[bk], int(b)
        if k == 'average' and not (blo <= bv <= bhi):
            base_bad.append(f'{o}/{c}/{i} base {bn}: {blo} <= {bv} <= {bhi}')
        elif k == 'fraction' and not (min(blo, bhi) <= bv <= max(blo, bhi)):
            base_moved.append(f'{o}/{c}/{i} base {bn}: {blo} {bv} {bhi}')
print(f'{sys.argv[4]}: {n} stored series bracketed, {nb} bases; cumulative outside: {len(cum_bad)}; averages\' bases outside: {len(base_bad)}; '
      f'gauges / fractions outside their two hand reads: {len(moved)}, fractions\' bases: {len(base_moved)}; in one hand read only: {len(came)}')
for x in moved[:10] + base_moved[:5]: print('   moved: ' + x)
for x in came[:5]: print('   in one hand read only: ' + x)
for x in cum_bad[:15] + base_bad[:15] + gone[:10] + unpaired[:10]: print('   FAIL ' + x)
sys.exit(1 if cum_bad or base_bad or gone or unpaired or n < int(sys.argv[5]) else 0)
PY
}

echo "== B. the bracket =="
bracket "B" || fail "B: a stored cumulative value or base outside its hand reads, a series in neither, a base not found (or under 300 series)"
bracket "B db" database 20 || fail "B: the database read: a stored cumulative value or base outside its hand reads, a series in neither, a base not found (or under 20 series)"
ok "B: every stored rate, count and average, and every average's base by the proof's own pairing, between the hand read before and after, on an instance read and a database read"

echo "== C. the arithmetic from the stored pairs =="
# between C's two reads: 20 runs of a procedure whose temp table changes shape each run (a recompile each) and 20
# distinct batches, so compilations run at 1/s or more and the recompile ratio is judged, not floored (review part 4,
# finding 11)
# GO first: sqb puts SET NOCOUNT ON ahead of every batch, and CREATE PROCEDURE must lead its own (box run 401proof11: Msg 111)
sqok "C: the recompiling procedure" "GO
CREATE OR ALTER PROCEDURE dbo.pgv_rc AS BEGIN CREATE TABLE #r (a int); INSERT #r VALUES (1); ALTER TABLE #r ADD b int; SELECT a, b FROM #r; END" pgvctr
sleep 2; col mssql_counters
sq "$(for i in $(seq 1 20); do echo "EXEC dbo.pgv_rc;"; echo GO; echo "SELECT v FROM dbo.t WHERE id = $((i * 13)) AND pad <> 'c$i';"; echo GO; done)" pgvctr >/dev/null
col mssql_counters
# arith <label>: C's arithmetic on the newest two instance reads of $SB (C here, L on each further image)
arith() {
python3 - "$PGDSN" "$SB" "$1" <<'PY' || return 1
import subprocess, sys
dsn, sb = sys.argv[1], sys.argv[2]
q = lambda s: subprocess.run(['psql', dsn, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-F', '|', '-c', s], capture_output=True, text=True, check=True).stdout
# the interval in SQL, as the import divides by it (extract(epoch FROM p_now - l.server_utc), exact): two absolute
# epochs near 1.8e9 s subtracted as floats carry about 2e-7 s each, which moved a 0.320 s pair's rate at 12651/s by 0.002
reads = q(f"SELECT snapshot_at, server_utc, extract(epoch FROM server_utc - lead(server_utc) OVER (ORDER BY snapshot_at DESC))::text FROM pgvigil.mssql_counter_read WHERE instance_id = {sb} AND scope = 'instance' ORDER BY snapshot_at DESC LIMIT 2").split('\n')
(at1, _, e1), (at0, _, e0) = [r.split('|') for r in reads[:2]]
secs = float(e1)
rows = q(f"""SELECT k.series_id, k.kind, s1.value, s1.base, s1.dvalue, s1.dbase, s1.rate, s0.value, s0.base,
                    (SELECT figure FROM pgvigil.mssql_counter_newest({sb}, now() - interval '1 hour', now()) n WHERE n.series_id = k.series_id)
               FROM pgvigil.mssql_counter_series k
               JOIN pgvigil.mssql_counter_sample s1 ON s1.series_id = k.series_id AND s1.instance_id = {sb} AND s1.snapshot_at = '{at1}'
               LEFT JOIN pgvigil.mssql_counter_sample s0 ON s0.series_id = k.series_id AND s0.instance_id = {sb} AND s0.snapshot_at = '{at0}'
              WHERE k.instance_id = {sb}""")
bad, n = [], {}
for l in rows.strip().split('\n'):
    sid, kind, v1, b1, dv, db, rate, v0, b0, fig = l.split('|')
    n[kind] = n.get(kind, 0) + 1
    f = lambda x: None if x == '' else float(x)
    v1, b1, dv, db, rate, v0, b0, fig = map(f, (v1, b1, dv, db, rate, v0, b0, fig))
    if kind in ('rate', 'count') and v0 is not None:
        if dv != v1 - v0: bad.append(f'{sid} {kind} change {dv} != {v1} - {v0}')
        if kind == 'rate' and (rate is None or abs(rate - round((v1 - v0) / secs, 3)) > 0.0015): bad.append(f'{sid} rate {rate} != {(v1 - v0) / secs:.3f}')
    if kind == 'average' and v0 is not None and b0 is not None:
        if dv != v1 - v0 or db != b1 - b0: bad.append(f'{sid} average changes {dv} {db}')
        if db and abs(fig - dv / db) > 1e-6: bad.append(f'{sid} average {fig} != {dv / db}')
    if kind == 'fraction' and b1:
        if abs(fig - 100.0 * v1 / b1) > 1e-6: bad.append(f'{sid} fraction {fig} != {100 * v1 / b1}')
    if kind == 'gauge' and fig != v1: bad.append(f'{sid} gauge {fig} != {v1}')
print(f'{sys.argv[3]}: {sum(n.values())} series over {secs:.3f} s by the server clock: ' + ', '.join(f'{k} {v}' for k, v in sorted(n.items())))
for b in bad[:20]: print('   FAIL ' + b)
sys.exit(1 if bad else 0)
PY
# the ratio metrics recomputed from the same read's rates (the floors included)
python3 - "$PGDSN" "$SB" "$1" <<'PY' || return 2
import subprocess, sys
dsn, sb = sys.argv[1], sys.argv[2]
q = lambda s: subprocess.run(['psql', dsn, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-F', '|', '-c', s], capture_output=True, text=True, check=True).stdout.strip()
at = q(f"SELECT snapshot_at FROM pgvigil.mssql_counter_read WHERE instance_id = {sb} AND scope = 'instance' ORDER BY snapshot_at DESC LIMIT 1")
# rate is stored real: read it as float8 so Python gets the very value SQL divides (psql prints a real by its shortest
# text, 112.827, against SQL's 112.82700347...: box run 401proof13 read 136.73499899 against 136.73500137; 0152's points
# are double precision too: the floors' part B, 2); the row AT this read only, as pt below (a second read under 1 s
# before this one would hand max() another read's rate, and with the floors a ratio on the wrong side of one)
rate = lambda o, c, i='_Total': float(q(f"SELECT coalesce(max(v.rate)::float8, 0) FROM pgvigil.mssql_counter_values({sb}, '{at}'::timestamptz - interval '1 second', '{at}', 'instance') v WHERE v.object = '{o}' AND v.counter = '{c}' AND v.inst = '{i}' AND v.snapshot_at = '{at}'::timestamptz") or 0)
# the point AT this read (a 1 s window can hold a second read under 1 s before this one: box run 401proof12 read
# '136.73...\n16.00...' for one metric; metric_points is (from, to]); a point with no value reads NULL (a floored ratio
# under its floor: not judged); no point at all reads ''
pt = lambda m: q(f"SELECT coalesce(value::text, 'NULL') FROM pgvigil.metric_points({sb}, 'counters', '{at}'::timestamptz - interval '1 second', '{at}') WHERE metric = '{m}' AND at = '{at}'::timestamptz")
b, c, rc = rate('SQL Statistics', 'Batch Requests/sec'), rate('SQL Statistics', 'SQL Compilations/sec'), rate('SQL Statistics', 'SQL Re-Compilations/sec')
fs, se = rate('Access Methods', 'Full Scans/sec'), rate('Access Methods', 'Index Searches/sec')
# the floors are 0152's metric_floors (5 Batch Requests/s; 1 Full Scan/s): None = no value; no index search = one
exp = {'batch_requests_s': b, 'full_scans_s': fs, 'index_searches_s': se,
       'compiles_per_100_batches': None if b < 5 else 100 * c / b, 'recompiles_per_100_compiles': 0 if c < 1 else 100 * rc / c,
       'full_scans_per_search': None if fs < 1 else fs / (se if se > 0 else 1)}
def wrong(g, e):
    if g == '': return True
    if e is None: return g != 'NULL'
    return g == 'NULL' or abs(float(g) - e) > 1e-6
bad = [f'{m} {pt(m)} != {e}' for m, e in exp.items() if wrong(pt(m), e)]
print(f'{sys.argv[3]}: ratios at batches {b}/s, full scans {fs}/s, index searches {se}/s: ' + ', '.join(f'{m} {pt(m)}' for m in exp))
print(f"{sys.argv[3]}: the floors' side this read judged: batch requests {'under' if b < 5 else 'at or over'} 5/s, full scans {'under' if fs < 1 else 'at or over'} 1/s")
for x in bad: print('   FAIL ' + x)
sys.exit(1 if bad else 0)
PY
}
arith C || fail "C: a figure differs from its recomputation (arith $?: 1 a stored figure, 2 a ratio metric)"
CPS=$(field "$(stored 'SQL Statistics' 'SQL Compilations/sec' '_Total')" 5)
RCP=$(pq "SELECT value FROM pgvigil.metric_points($SB, 'counters', now() - interval '1 minute', now()) WHERE metric = 'recompiles_per_100_compiles' ORDER BY at DESC LIMIT 1")
echo "   C's window: compilations ${CPS:-none}/s, recompiles_per_100_compiles ${RCP:-none}"
python3 -c "import sys; sys.exit(0 if float('${CPS:-0}') >= 1 and float('${RCP:-0}') > 0 else 1)" \
  || fail "C: compilations ${CPS:-none}/s, recompiles_per_100_compiles ${RCP:-none} (want 1/s or more and a ratio above 0: judged, not floored)"
ok "C: every rate, change, average, fraction and gauge equals its recomputation from the stored raw pairs; the ratios equal their rates"

echo "== D. the provoked counters =="
# a phase: one read, the provocation, one read; each change read from the store. The logins phase takes a read of its
# own first, after the proof's event session started (lgs_start; the session is read only on a red and dropped after)
lgs_start D; col mssql_counters
for _ in $(seq 1 40); do sq "SELECT 1" >/dev/null; done
col mssql_counters
DL=$(chg 'General Statistics' 'Logins/sec' '_Total'); DO=$(chg 'General Statistics' 'Logouts/sec' '_Total')
# the collector's own login of this read is counted (+1); its logout of the read before happened after that read
[[ "$DL" == "$LGW" && "$DO" == "$LGW" ]] || fail "D: logins +$DL logouts +$DO (want $LGW each: 40 and the collector's own); $(lgs_rows)"
lgs_drop
ok "D: Logins/sec and Logouts/sec + 40 each beside the collector's own (+41 stored)"
# Batch Requests/sec over the collector's own (review part 4, finding 2): its own batches per read, the least of three
# quiet pairs, then 200 batches between two reads
OWNB=; for _ in 1 2 3; do col mssql_counters; sleep 1; col mssql_counters; c=$(chg 'SQL Statistics' 'Batch Requests/sec' '_Total')
  [[ "$c" =~ ^[0-9]+$ ]] || fail "D: Batch Requests over a quiet pair [$c]"; [[ -z "$OWNB" || "$c" -lt "$OWNB" ]] && OWNB=$c; done
col mssql_counters; sq "$(for _ in $(seq 1 200); do echo 'SELECT 1;'; echo GO; done)" >/dev/null; col mssql_counters
BRQ=$(chg 'SQL Statistics' 'Batch Requests/sec' '_Total')
echo "   batch requests: +$BRQ over 200 batches; the collector's own $OWNB per read (the least of three quiet pairs)"
[[ "$BRQ" =~ ^[0-9]+$ && "$BRQ" -ge $((200 + OWNB)) ]] || fail "D: Batch Requests +$BRQ (want 200 and the collector's own $OWNB at least)"
(( BRQ > 200 + OWNB + 20 )) && echo "NOT PROVEN exact: Batch Requests +$BRQ is $((BRQ - 200 - OWNB)) over 200 and the collector's own (background batches such as SQLServerCEIP's)"
ok "D: Batch Requests/sec +$BRQ: 200 provoked and the collector's own $OWNB (+$((BRQ - 200 - OWNB)) beside them)"

sq "$(printf "RAISERROR('pgvigil proof user error', 16, 1);\n%.0s" $(seq 1 12))" >/dev/null 2>&1 || true
sq "$(printf "RAISERROR('pgvigil proof info message', 10, 1);\n%.0s" $(seq 1 7))" >/dev/null 2>&1 || true
col mssql_counters
EU=$(chg 'SQL Errors' 'Errors/sec' 'User Errors'); EI=$(chg 'SQL Errors' 'Errors/sec' 'Info Errors')
# the severe errors in a phase of their own: in one phase with the 12 above, User Errors read +15 (sqltb-s1-proof3)
for _ in 1 2 3; do sq "RAISERROR('pgvigil proof severe error', 20, 1) WITH LOG;" >/dev/null 2>&1 || true; done
col mssql_counters
EKAT=$(pq "SELECT snapshot_at FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance' ORDER BY snapshot_at DESC LIMIT 1")   # H reads errors_kill_s here
EK=$(chg 'SQL Errors' 'Errors/sec' 'Kill Connection Errors'); EUK=$(chg 'SQL Errors' 'Errors/sec' 'User Errors')
EO=$(stored 'SQL Errors' 'Errors/sec' 'DB Offline Errors'); ET=$(chg 'SQL Errors' 'Errors/sec' '_Total')
echo "   errors: user +$EU, info +$EI (12 at severity 16, 7 at 10); then kill connection +$EK, user +$EUK, total +$ET (3 at severity 20 WITH LOG); DB Offline Errors stored as [$EO]"
[[ "$EU" == 12 ]] || fail "D: User Errors +$EU (want 12)"
[[ -n "$EK" && "$EK" -ge 3 ]] || fail "D: Kill Connection Errors +$EK (want 3: three severity 20 errors)"
[[ "$(field "$EO" 1)" == 0 ]] || fail "D: DB Offline Errors [$EO] (want 0, in zero_series)"
ok "D: User Errors +12, Info Errors +$EI (read as they are); Kill Connection Errors +$EK with User Errors +$EUK in the severe phase; DB Offline Errors 0 (not provable on a box)"

col mssql_counters_db
sq "DECLARE @i int = 0; WHILE @i < 500 BEGIN UPDATE dbo.t SET v = v + 1 WHERE id = @i % 2000 + 1; SET @i += 1; END" pgvctr >/dev/null
sq "INSERT dbo.t (id, pad) SELECT TOP (30000) 100000 + ROW_NUMBER() OVER (ORDER BY (SELECT 1)), REPLICATE('g', 200) FROM sys.all_objects a CROSS JOIN sys.all_objects b" pgvctr >/dev/null
col mssql_counters_db
WT=$(chg 'Databases' 'Write Transactions/sec' 'pgvctr'); LF=$(chg 'Databases' 'Log Flush Waits/sec' 'pgvctr'); LG=$(chg 'Databases' 'Log Growths' 'pgvctr')
LW=$(chg 'Databases' 'Log Flush Wait Time' 'pgvctr')
[[ -n "$WT" && "$WT" -ge 500 ]] || fail "D: pgvctr Write Transactions + $WT (want 500 or more)"
[[ -n "$LF" && "$LF" -gt 0 ]] || fail "D: pgvctr Log Flush Waits + $LF (want more than 0)"
[[ -n "$LG" && "$LG" -ge 1 ]] || fail "D: pgvctr Log Growths + $LG (want 1 or more)"
sleep 2; col mssql_counters_db
FLAT=$(stored 'Databases' 'Log Growths' 'pgvctr'); FV=$(field "$FLAT" 1); FC=$(field "$FLAT" 3)
INROW=$(pq "SELECT count(*) FROM pgvigil.mssql_counter_sample s JOIN pgvigil.mssql_counter_series k ON k.series_id = s.series_id
  WHERE k.instance_id = $SB AND k.object = 'Databases' AND k.counter = 'Log Growths' AND k.inst = 'pgvctr'
    AND s.snapshot_at = (SELECT max(snapshot_at) FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'database')")
LGP=$(pq "SELECT value FROM pgvigil.metric_points($SB, 'counters', now() - interval '20 seconds', now(), interval '15 minutes', 'pgvctr') WHERE metric = 'log_growths' ORDER BY at DESC LIMIT 1")
[[ "$FV" -ge 1 && "$FC" == 0 && "$INROW" == 1 && "$LGP" == 0 ]] || fail "D: the flat read [$FLAT] row $INROW log_growths [$LGP] (want a row at a change of 0 and the point 0)"
ok "D: pgvctr Write Transactions +$WT, Log Flush Waits +$LF (wait time +$LW ms), Log Growths +$LG; the flat read after it keeps its row at a change of 0 and log_growths is 0 (F2 case 1)"

# held: the holder's X key lock on pgvctr, granted (review part 4, findings 4 and 5: seen, not a fixed sleep)
held() { sq "SELECT COUNT(*) FROM sys.dm_tran_locks WHERE resource_database_id = DB_ID('pgvctr') AND resource_type = 'KEY' AND request_mode = 'X' AND request_status = 'GRANT'" | tr -d '[:space:]'; }
waitheld() { local h=; for _ in $(seq 1 50); do h=$(held); [[ "$h" =~ ^[0-9]+$ && "$h" -ge 1 ]] && return 0; sleep 0.2; done; fail "D: $1: no granted X key lock in sys.dm_tran_locks"; }
col mssql_counters
( printf 'BEGIN TRAN; UPDATE dbo.t SET v = v + 1 WHERE id = 1; WAITFOR DELAY '"'"'00:00:25'"'"'; ROLLBACK;\n' | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -d pgvctr -i /dev/stdin' >/dev/null 2>&1 & ) ; waitheld "the lock holder"
for _ in $(seq 1 6); do sq "SET LOCK_TIMEOUT 200; SELECT v FROM dbo.t WHERE id = 1;" pgvctr >/dev/null 2>&1 || true; done
col mssql_counters
TG=$(chg 'Locks' 'Lock Timeouts (timeout > 0)/sec' '_Total'); TP=$(chg 'Locks' 'Lock Timeouts/sec' '_Total')
AW=$(pq "SELECT round(value::numeric, 1) FROM pgvigil.metric_points($SB, 'counters', now() - interval '20 seconds', now()) WHERE metric = 'avg_lock_wait_ms' ORDER BY at DESC LIMIT 1")
waitheld "the holder before the LOCK_TIMEOUT 0 phase"
for _ in $(seq 1 6); do sq "SET LOCK_TIMEOUT 0; SELECT v FROM dbo.t WHERE id = 1;" pgvctr >/dev/null 2>&1 || true; done
col mssql_counters
TG2=$(chg 'Locks' 'Lock Timeouts (timeout > 0)/sec' '_Total'); TP2=$(chg 'Locks' 'Lock Timeouts/sec' '_Total')
echo "   lock timeouts: (timeout > 0) +$TG then +$TG2; all +$TP then +$TP2; average lock wait $AW ms"
[[ "$TG" == 6 && "$TG2" == 0 && "$TP2" -ge 6 && "$((TP + TP2))" -ge 12 ]] || fail "D: lock timeouts (timeout > 0) +$TG / +$TG2, all +$TP / +$TP2 (want 6 / 0, the second six on the plain counter: 6 or more)"
python3 -c "import sys; sys.exit(0 if 150 <= float('${AW:-0}') <= 600 else 1)" || fail "D: the average lock wait $AW ms (want 150-600)"
ok "D: Lock Timeouts (timeout > 0) +6 at 200 ms and +0 at LOCK_TIMEOUT 0; all lock timeouts +$((TP + TP2)); the average lock wait $AW ms"
sleep 25

# snapw: the snapshot transaction in its WAITFOR (isolation level 5), its SELECT done (review part 4, finding 5)
snapw() { sq "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE database_id = DB_ID('pgvctr') AND wait_type = 'WAITFOR' AND transaction_isolation_level = 5" | tr -d '[:space:]'; }
col mssql_counters
for _ in 1 2 3 4; do
  ( printf 'SET TRANSACTION ISOLATION LEVEL SNAPSHOT; BEGIN TRAN; SELECT v FROM dbo.t WHERE id = 2; WAITFOR DELAY '"'"'00:00:02'"'"'; UPDATE dbo.t SET v = v + 1 WHERE id = 2; COMMIT;\n' \
      | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -d pgvctr -i /dev/stdin' >/dev/null 2>&1 & )
  w=; for _ in $(seq 1 50); do w=$(snapw); [[ "$w" =~ ^[0-9]+$ && "$w" -ge 1 ]] && break; sleep 0.1; done
  [[ "$w" =~ ^[0-9]+$ && "$w" -ge 1 ]] || fail "D: the snapshot transaction never reached its WAITFOR"
  sq "UPDATE dbo.t SET v = v + 1 WHERE id = 2;" pgvctr >/dev/null
  for _ in $(seq 1 50); do [[ "$(snapw)" == 0 ]] && break; sleep 0.1; done
done
sleep 1; col mssql_counters
UC=$(stored 'Transactions' 'Update conflict ratio' '_Total')
[[ "$(field "$UC" 3)" == 4 && "$(field "$UC" 4)" -ge 4 ]] || fail "D: Update conflict ratio [$UC] (want a change of 4 over a base change of 4 or more)"
ok "D: Update conflict ratio +4 conflicts over +$(field "$UC" 4) snapshot updates"

col mssql_counters
sq "$(for i in $(seq 1 20); do echo "SELECT v FROM dbo.t WHERE id = $((i * 7));"; echo GO; done)" pgvctr >/dev/null
col mssql_counters
AP=$(chg 'SQL Statistics' 'Auto-Param Attempts/sec' '_Total')
sq "ALTER DATABASE pgvctr SET PARAMETERIZATION FORCED;" >/dev/null
sq "$(for i in $(seq 1 20); do echo "SELECT v, pad FROM dbo.t WHERE id = $((i * 11)) AND v >= 0;"; echo GO; done)" pgvctr >/dev/null
col mssql_counters
FP=$(chg 'SQL Statistics' 'Forced Parameterizations/sec' '_Total')
sq "ALTER DATABASE pgvctr SET PARAMETERIZATION SIMPLE;" >/dev/null
[[ -n "$AP" && "$AP" -ge 20 && -n "$FP" && "$FP" -ge 20 ]] || fail "D: Auto-Param Attempts +$AP, Forced Parameterizations +$FP (want 20 or more each)"
ok "D: Auto-Param Attempts +$AP, Forced Parameterizations +$FP"

col mssql_counters
sq "CREATE TABLE dbo.pc (id int NOT NULL, pad char(500) NOT NULL) WITH (DATA_COMPRESSION = PAGE);
  INSERT dbo.pc WITH (TABLOCK) SELECT TOP (30000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)), REPLICATE('p', 500) FROM sys.all_objects a CROSS JOIN sys.all_objects b;" pgvctr >/dev/null
sq "$(for i in 1 2 3 4 5; do echo "DECLARE c$i CURSOR LOCAL FOR SELECT TOP (3) id FROM dbo.t; OPEN c$i; FETCH NEXT FROM c$i; CLOSE c$i; DEALLOCATE c$i;"; done)" pgvctr >/dev/null
sq "SELECT COUNT(*) FROM ::fn_helpcollations(); SELECT COUNT(*) FROM ::fn_helpcollations(); SELECT COUNT(*) FROM ::fn_helpcollations();" >/dev/null
sq "$(for _ in 1 2 3 4 5; do echo "WAITFOR DELAY '00:00:00.125';"; echo GO; done; for _ in 1 2 3; do echo "WAITFOR DELAY '00:00:01.200';"; echo GO; done)" >/dev/null
col mssql_counters
PC=$(chg 'Access Methods' 'Page compression attempts/sec' '_Total'); CR=$(chg 'Cursor Manager by Type' 'Cursor Requests/sec' '_Total')
DF=$(pq "SELECT s.dvalue FROM pgvigil.mssql_counter_series k JOIN pgvigil.mssql_counter_sample s ON s.series_id = k.series_id
  WHERE k.instance_id = $SB AND k.object = 'Deprecated Features' AND k.inst LIKE '%::%function calling syntax%'
    AND s.snapshot_at = (SELECT max(snapshot_at) FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance')")
B100=$(chg 'Batch Resp Statistics' 'Batches >=000100ms & <000200ms' 'Elapsed Time:Requests'); B1K=$(chg 'Batch Resp Statistics' 'Batches >=001000ms & <002000ms' 'Elapsed Time:Requests')
PREV=$(pq "SELECT snapshot_at FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance' ORDER BY snapshot_at DESC OFFSET 1 LIMIT 1")
H100=$(pq "SELECT elapsed_batches FROM pgvigil.mssql_counter_histogram($SB, '$PREV', now()) WHERE lo_ms = 100")
echo "   page compression attempts +$PC, cursor requests +$CR, '::' syntax +$DF, batches 100-200 ms +$B100, 1-2 s +$B1K (histogram 100-200 ms: $H100)"
[[ -n "$PC" && "$PC" -gt 0 && -n "$CR" && "$CR" -ge 5 && "$DF" == 3 && -n "$B100" && "$B100" -ge 5 && -n "$B1K" && "$B1K" -ge 3 && "$H100" == "$B100" ]] \
  || fail "D: compression / cursors / deprecated / batch buckets"
ok "D: Page compression attempts +$PC, Cursor Requests +$CR, Deprecated Features '::' +3, batches 100-200 ms +$B100 and 1-2 s +$B1K (the histogram the same)"

( printf "DECLARE @e datetime2 = DATEADD(second, 25, SYSDATETIME()), @i bigint = 0; WHILE SYSDATETIME() < @e SET @i += 1;\n" \
    | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -i /dev/stdin' >/dev/null 2>&1 & )
sleep 8; col mssql_counters
CPU=$(stored 'Resource Pool Stats' 'CPU usage %' 'default'); CF=$(pq "SELECT figure FROM pgvigil.mssql_counter_newest($SB, now() - interval '1 hour', now()) WHERE object = 'Resource Pool Stats' AND counter = 'CPU usage %' AND inst = 'default'")
python3 - "$CPU" "$CF" <<'PY' || fail "D: Resource Pool CPU usage % [$CPU] figure [$CF]"
import sys
v, b = [float(x) for x in sys.argv[1].split('|')[:2]]
f = float(sys.argv[2]); print(f'   default pool CPU usage %: value {v:.0f} base {b:.0f} figure {f:.3f}')
sys.exit(0 if 0 < f <= 100 and abs(f - 100 * v / b) < 1e-6 else 1)
PY
ok "D: Resource Pool Stats CPU usage % read under a CPU loop: $CF % = 100 * value / base"
sleep 18

# the guide's setup checked, not swallowed (review part 4, finding 13)
sqok "D: the index the plan guide names" "CREATE INDEX ix_v ON dbo.t (v);" pgvctr
sqok "D: the plan guide" "EXEC sp_create_plan_guide @name = N'pgv_ctr_guide', @stmt = N'SELECT id FROM dbo.t WHERE v > 100000;', @type = N'SQL', @module_or_batch = NULL, @params = NULL, @hints = N'OPTION (TABLE HINT (dbo.t, INDEX (ix_v)))';" pgvctr
col mssql_counters
sqok "D: the guide's index dropped" "DROP INDEX ix_v ON dbo.t;" pgvctr
PGD=$(sq "SELECT CAST((SELECT COUNT(*) FROM sys.plan_guides WHERE name = N'pgv_ctr_guide') AS varchar(5)) + '|' + CAST((SELECT COUNT(*) FROM sys.indexes WHERE name = N'ix_v' AND object_id = OBJECT_ID(N'dbo.t')) AS varchar(5))" pgvctr | tr -d '[:space:]')
[[ "$PGD" == "1|0" ]] || fail "D: the plan guide and its index [$PGD] (want the guide 1, the index 0)"
for _ in 1 2 3; do printf 'SELECT id FROM dbo.t WHERE v > 100000;\nGO\n' | timeout 60 docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -d pgvctr -i /dev/stdin' >/dev/null 2>&1 || true
  sq "DBCC FREEPROCCACHE WITH NO_INFOMSGS;" >/dev/null 2>&1 || true; done
col mssql_counters
MG=$(chg 'SQL Statistics' 'Misguided plan executions/sec' '_Total')
if [[ -n "$MG" && "$MG" -gt 0 ]]; then ok "D: Misguided plan executions +$MG (a plan guide whose index was dropped)"
else echo "NOT PROVEN live: Misguided plan executions/sec did not move (+${MG:-no change}) with a plan guide whose index was dropped; the counter is read ($(stored 'SQL Statistics' 'Misguided plan executions/sec' '_Total'))"; fi

echo "== E. the list =="
config "    mssql_counters:
      add:
        - object: General Statistics
          counter: Logical Connections
      remove:
        - object: Deprecated Features
          counter: Usage"
col mssql_counters
[[ $(readat 'General Statistics' 'Logical Connections') -ge 1 && $(readat 'Deprecated Features' 'Usage') == 0 ]] \
  || fail "E: the yaml lines: Logical Connections read $(readat 'General Statistics' 'Logical Connections'), Usage read $(readat 'Deprecated Features' 'Usage')"
Y=$(pq "SELECT jsonb_array_length(lines) FROM pgvigil.mssql_counter_yaml WHERE instance_id = $SB"); [[ "$Y" == 2 ]] || fail "E: mssql_counter_yaml holds $Y lines"
ok "E: pgvigil.yaml's instance lines: Logical Connections read, Deprecated Features Usage not; the runner's 2 lines kept"
door() { pq "SELECT pgvigil.import_mssql_counter_config(now(), '$1'::jsonb)"; }
door '{"op":"add","ui_user":"proof-e","scope":"fleet","object":"Deprecated Features","counter":"Usage","action":"add"}' | grep -q '"done"' || fail "E: the fleet row"
col mssql_counters
[[ $(readat 'Deprecated Features' 'Usage') == 0 ]] || fail "E: an Admin fleet row won over the instance's yaml line"
door '{"op":"add","ui_user":"proof-e","scope":"instance","instance_name":"ctrbox","object":"Deprecated Features","counter":"Usage","action":"add"}' | grep -q '"done"' || fail "E: the instance row"
col mssql_counters
[[ $(readat 'Deprecated Features' 'Usage') -ge 1 ]] || fail "E: an Admin instance row lost to the instance's yaml line"
door '{"op":"add","ui_user":"proof-e","scope":"tag","tag":"env:ctrproof","object":"Plan Cache","counter":"Cache Pages","action":"remove"}' | grep -q '"done"' || fail "E: the tag row"
col mssql_counters
[[ $(readat 'Plan Cache' 'Cache Pages') == 0 ]] || fail "E: the tag row's removal did not hold"
door '{"op":"add","ui_user":"proof-e","scope":"instance","instance_name":"ctrbox","object":"Plan Cache","counter":"Cache Pages","action":"add"}' | grep -q '"done"' || fail "E: the instance add"
col mssql_counters
[[ $(readat 'Plan Cache' 'Cache Pages') -ge 1 ]] || fail "E: the instance row lost to the tag row"
R=$(door '{"op":"add","ui_user":"proof-e","scope":"fleet","object":"General Statistics","counter":"Logins/sec","action":"remove"}')
grep -q '"refused"' <<<"$R" && grep -q 'read by' <<<"$R" || fail "E: removing Logins/sec: $R"
# review part 3's finding 4: the histogram's buckets are read by the Metrics page: a removal is refused
R=$(door '{"op":"add","ui_user":"proof-e","scope":"fleet","object":"Batch Resp Statistics","counter":"Batches >=000000ms & <000001ms","action":"remove"}')
grep -q '"refused"' <<<"$R" && grep -q 'histogram' <<<"$R" || fail "E: removing a Batch Resp Statistics bucket: $R"
config "    mssql_counters:
      remove:
        - object: General Statistics
          counter: Logins/sec"
O=$("$TMPD/pgvigil" collect -config "$CFG" -instance ctrbox -once mssql_counters 2>&1 || true); grep -q 'is read by' <<<"$O" || fail "E: the yaml removal of Logins/sec: $O"
config
R=$(door '{"op":"add","ui_user":"proof-e","scope":"fleet","object":"SQL Errors","counter":"Errors/sec","action":"add","kind":"gauge"}')
grep -q '"refused"' <<<"$R" && grep -q 'its kind stays' <<<"$R" || fail "E: a gauge kind on Errors/sec at Admin: $R"
config "    mssql_counters:
      add:
        - object: SQL Errors
          counter: Errors/sec
          kind: gauge"
O=$("$TMPD/pgvigil" collect -config "$CFG" -instance ctrbox -once mssql_counters 2>&1 || true); grep -q 'its kind stays' <<<"$O" || fail "E: a gauge kind on Errors/sec in the yaml: $O"
config
R=$(door '{"op":"add","ui_user":"proof-e","scope":"fleet","object":"sys.dm_os_schedulers","counter":"yield_count","action":"add","kind":"gauge"}')
grep -q '"refused"' <<<"$R" && grep -q 'is a DMV column' <<<"$R" || fail "E: a gauge kind on a DMV column at Admin: $R"
config "    mssql_counters:
      add:
        - object: sys.dm_os_schedulers
          counter: yield_count
          kind: gauge"
O=$("$TMPD/pgvigil" collect -config "$CFG" -instance ctrbox -once mssql_counters 2>&1 || true); grep -q 'is a DMV column' <<<"$O" || fail "E: a gauge kind on a DMV column in the yaml: $O"
config
ok "E: Admin and the yaml refuse a kind on SQL Errors / Errors/sec (its kind stays as SQL Server types it) and on a DMV column (sys.dm_os_schedulers / yield_count)"
# seen: a series is in the scope's newest read (a stored row or named in zero_series)
seen() { pq "SELECT count(*) FROM pgvigil.mssql_counter_series k
  JOIN LATERAL (SELECT * FROM pgvigil.mssql_counter_read c WHERE c.instance_id = k.instance_id AND c.scope = pgvigil.mssql_counter_scope(k.object) ORDER BY c.snapshot_at DESC LIMIT 1) r ON true
  LEFT JOIN pgvigil.mssql_counter_last l ON l.series_id = k.series_id
  WHERE k.instance_id = $SB AND k.object = '$1' AND k.counter = '$2' AND k.inst = '$3' AND (l.server_utc = r.server_utc OR k.series_id = ANY (r.zero_series))"; }
col mssql_counters
DF=$(pq "SELECT string_agg(k.inst, ' ' ORDER BY k.inst) FROM (SELECT k.inst FROM pgvigil.mssql_counter_series k WHERE k.instance_id = $SB
  AND k.object = 'Deprecated Features' AND k.counter = 'Usage' AND k.inst ~ '^[A-Za-z_]+$' ORDER BY k.inst LIMIT 2) k")
read -r DFX DFY <<<"$DF"
[[ -n "$DFX" && -n "$DFY" && $(seen 'Deprecated Features' 'Usage' "$DFX") == 1 && $(seen 'Deprecated Features' 'Usage' "$DFY") == 1 ]] \
  || fail "E: two Deprecated Features / Usage features read before the removal [$DF]"
config "    mssql_counters:
      remove:
        - object: Deprecated Features
          counter: Usage
          instance: $DFX"
col mssql_counters
EX=$(pq "SELECT e->>'except' FROM jsonb_array_elements(pgvigil.mssql_counter_list($SB, pgvigil.mssql_counter_yaml_of($SB))) e WHERE e->>'object' = 'Deprecated Features' AND e->>'counter' = 'Usage' AND e->>'inst' = ''")
[[ $(seen 'Deprecated Features' 'Usage' "$DFX") == 0 && $(seen 'Deprecated Features' 'Usage' "$DFY") == 1 && "$EX" == "[\"$DFX\"]" ]] \
  || fail "E: one feature removed: $DFX seen $(seen 'Deprecated Features' 'Usage' "$DFX") (want 0), $DFY seen $(seen 'Deprecated Features' 'Usage' "$DFY") (want 1), except [$EX]"
config
ok "E: a yaml line removing one feature of Deprecated Features / Usage ($DFX) takes it out of the read; $DFY still read; the list's line says except [\"$DFX\"]"
ok "E: an Admin fleet row loses to the instance's yaml line, an Admin instance row wins over it; a tag row removes, an instance row adds back; Admin and yaml refuse removing Logins/sec"

echo "== F. the gap rule =="
# heldout: Pages Allocated/sec at the scope's newest read - its stored rows (0 or 1) and
# whether zero_series names it (review part 4, finding 15: a zero_series 0 is not a value)
heldout() { pq "SELECT count(s.series_id) || '|' || coalesce(bool_or(k.series_id = ANY (coalesce(r.zero_series, '{}'))), false)::text
  FROM pgvigil.mssql_counter_series k
  JOIN LATERAL (SELECT * FROM pgvigil.mssql_counter_read c WHERE c.instance_id = k.instance_id AND c.scope = 'instance' ORDER BY c.snapshot_at DESC LIMIT 1) r ON true
  LEFT JOIN pgvigil.mssql_counter_sample s ON s.instance_id = k.instance_id AND s.series_id = k.series_id AND s.snapshot_at = r.snapshot_at
  WHERE k.instance_id = $SB AND k.object = 'Access Methods' AND k.counter = 'Pages Allocated/sec' AND k.inst = '_Total'"; }
door '{"op":"add","ui_user":"proof-f","scope":"instance","instance_name":"ctrbox","object":"Access Methods","counter":"Pages Allocated/sec","action":"remove"}' >/dev/null
col mssql_counters; GO1=$(heldout); sleep 2; col mssql_counters; GO2=$(heldout)
[[ "$GO1" == "0|false" && "$GO2" == "0|false" ]] || fail "F: the two reads without it [$GO1] [$GO2] (want no row and not in zero_series: 0|false)"
GID=$(pq "SELECT config_id FROM pgvigil.mssql_counter_config WHERE ended_at IS NULL AND counter = 'Pages Allocated/sec'")
door "{\"op\":\"end\",\"ui_user\":\"proof-f\",\"config_id\":\"$GID\"}" | grep -q '"done"' || fail "F: end"
sleep 2; col mssql_counters; G1=$(stored 'Access Methods' 'Pages Allocated/sec' '_Total'); GB=$(heldout)
sleep 2; col mssql_counters; G2=$(stored 'Access Methods' 'Pages Allocated/sec' '_Total')
[[ "$GB" == "1|false" && -n "$(field "$G1" 1)" && -z "$(field "$G1" 3)" && -z "$(field "$G1" 5)" && -n "$(field "$G2" 3)" && -n "$(field "$G2" 5)" ]] || fail "F: back from the gap [$G1] ($GB) then [$G2]"
ok "F: Pages Allocated/sec gone for two reads (no row, not in zero_series), back after them: a stored row with no change and no rate at its first read back [$G1], both at the next [$G2]"
withrate() { pq "SELECT count(*) FILTER (WHERE s.rate IS NOT NULL OR s.dvalue IS NOT NULL) || '|' || count(*) FROM pgvigil.mssql_counter_sample s
  WHERE s.instance_id = $SB AND s.snapshot_at = (SELECT max(snapshot_at) FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance')"; }
sleep 125; col mssql_counters; T1=$(withrate); sleep 3; col mssql_counters; T2=$(withrate)
[[ "$(field "$T1" 1)" == 0 && "$(field "$T2" 1)" -gt 0 ]] || fail "F: F15, after 125 s [$T1] (rows with a change or rate | rows), then [$T2]"
ok "F: F15: the read 125 s after the one before has no change or rate on any of its $(field "$T1" 2) rows; the read 3 s later has $(field "$T2" 1)"

echo "== G. a restart =="
docker restart "$SQL" >/dev/null
for _ in $(seq 1 150); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('pgvctr', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" master 15 2>/dev/null || true); [[ "$r" == 1 ]] && break; sleep 2; done
[[ "$r" == 1 ]] || fail "G: pgvctr not online 300 s after the restart"
mondsn
col mssql_counters
GAPG=$(pq "SELECT coalesce(after_gap::text, 'null') FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance' ORDER BY snapshot_at DESC LIMIT 1")
NR=$(pq "SELECT count(*) FILTER (WHERE s.rate IS NOT NULL OR s.dvalue IS NOT NULL), count(*) FROM pgvigil.mssql_counter_sample s
  WHERE s.instance_id = $SB AND s.snapshot_at = (SELECT max(snapshot_at) FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance')")
sleep 3; col mssql_counters
NR2=$(pq "SELECT count(*) FILTER (WHERE s.rate IS NOT NULL OR s.dvalue IS NOT NULL) FROM pgvigil.mssql_counter_sample s
  WHERE s.instance_id = $SB AND s.snapshot_at = (SELECT max(snapshot_at) FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance')")
[[ "$GAPG" == false ]] || fail "G: the first read after the restart has after_gap [$GAPG]: F15's gap rule, not the restart rule, would empty it (review part 4, finding 14)"
[[ "$(field "$NR" 1)" == 0 && "$NR2" -gt 0 ]] || fail "G: after the restart [$NR] changes, then $NR2"
ok "G: the first read after a restart has no rate or change on any of its $(field "$NR" 2) rows; the read after has $NR2"

echo "== H. zero points =="
NRD=$(pq "SELECT count(*) FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance' AND snapshot_at > now() - interval '30 minutes'")
ZK=$(pq "SELECT count(*) FILTER (WHERE value = 0) || '|' || count(*) FROM pgvigil.metric_points($SB, 'counters', now() - interval '30 minutes', now()) WHERE metric = 'errors_offline_s'")
[[ "$ZK" == "$NRD|$NRD" ]] || fail "H: errors_offline_s points [$ZK] for $NRD reads"
# errors_kill_s at D's severe-phase read (review part 4, finding 3): above 0 there, equal to that read's stored rate
KR=$(pq "SELECT s.rate::float8 FROM pgvigil.mssql_counter_series k JOIN pgvigil.mssql_counter_sample s ON s.instance_id = k.instance_id AND s.series_id = k.series_id
  WHERE k.instance_id = $SB AND k.object = 'SQL Errors' AND k.counter = 'Errors/sec' AND k.inst = 'Kill Connection Errors' AND s.snapshot_at = '$EKAT'")
# a read under 1 s before the severe read sits in the 1 s window too (401proof14: '0' and '3.935' on two lines; the
# window is (from, to]): the point AT the severe read only
KP=$(pq "SELECT coalesce(string_agg(value::text, ',' ORDER BY at), '') FROM pgvigil.metric_points($SB, 'counters', '$EKAT'::timestamptz - interval '1 second', '$EKAT')
  WHERE metric = 'errors_kill_s' AND at = '$EKAT'::timestamptz")
echo "   errors_kill_s at D's severe read: point [$KP], the stored rate [$KR]"
python3 -c "import sys; p, r = sys.argv[1], sys.argv[2]; sys.exit(0 if p and r and ',' not in p and float(p) > 0 and abs(float(p) - float(r)) < 1e-6 else 1)" "$KP" "$KR" 2>/dev/null \
  || fail "H: errors_kill_s at D's severe read [$KP] (want above 0 and equal to the stored rate [$KR])"
ok "H: errors_offline_s is 0 at every one of the $NRD instance reads (the counter at raw 0, named in zero_series); errors_kill_s $KP at D's severe read, its stored rate"

echo "== P. review part 2's rows on a synthetic instance =="
SY=$(pq "INSERT INTO pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
         VALUES ('ctrsyn', 'sqlserver', '{env:synx,env:syny}', now(), now(), true, 'sqlserver') RETURNING instance_id" | head -1)
[[ "$SY" =~ ^[0-9]+$ ]] || fail "P: the synthetic instance [$SY]"
DAY=$(pq "SELECT to_char(date_trunc('day', now() AT TIME ZONE 'UTC') - interval '1 day', 'YYYY-MM-DD')")
at() { echo "${DAY}T$1Z"; }
# syn_ctr <hh:mm:ss> <ctr rows, a JSON array>: one instance read of ctrsyn, its server time and its snapshot the same
syn_ctr() { pq "SELECT pgvigil.import_mssql_counters($SY, '$(at "$1")'::timestamptz,
  '[{\"kind\":\"state\",\"server_utc\":\"$(at "$1")\",\"server_start\":\"2026-11-01T00:00:00Z\"}]'::jsonb || '$2'::jsonb)" >/dev/null; }
br() { echo "[{\"kind\":\"ctr\",\"object\":\"SQL Statistics\",\"counter\":\"Batch Requests/sec\",\"instance\":\"_Total\",\"type\":272696576,\"ckind\":\"rate\",\"value\":$1}]"; }
# syn_jobs <hh:mm:ss> <cursor> <running_since or ''> [<history_id> <run start hh:mm:ss> <status> <duration_s>]: a jobs
# read as import_mssql_jobs (0094) leaves it - the run stored once, the cursor stamped with the read's time, mssql_jobs
# replaced
syn_jobs() {
  local t; t=$(at "$1")
  if [[ -n "${4:-}" ]]; then
    pq "SELECT pgvigil.ensure_month_partition('mssql_job_runs', '$(at "$5")'::timestamptz)" >/dev/null
    pq "INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, run_status, duration_s)
        VALUES ($SY, '$(at "$5")', $4, 'J1', 'syn job', 0, $6, $7)" >/dev/null
  fi
  pq "INSERT INTO pgvigil.mssql_jobs_cursor (instance_id, last_history_id, mark, updated_at) VALUES ($SY, $2, 1, '$t')
      ON CONFLICT (instance_id) DO UPDATE SET last_history_id = EXCLUDED.last_history_id, mark = EXCLUDED.mark, updated_at = EXCLUDED.updated_at" >/dev/null
  pq "DELETE FROM pgvigil.mssql_jobs WHERE instance_id = $SY;
      INSERT INTO pgvigil.mssql_jobs (instance_id, job_id, snapshot_at, name, running_since)
      VALUES ($SY, 'J1', '$t', 'syn job', $([[ -n "$3" ]] && echo "'$(at "$3")'" || echo NULL))" >/dev/null; }
synpt() { pq "SELECT coalesce(to_char(at AT TIME ZONE 'UTC', 'HH24:MI:SS'), '') || '=' || coalesce(value::text, 'NULL')
  FROM pgvigil.metric_points($SY, 'counters', '$(at 00:00:01)', '$(at 23:59:59)') WHERE metric = '$1' ORDER BY at DESC LIMIT 1"; }
synrd() { pq "SELECT coalesce(s.dvalue::text, '') || '|' || coalesce(s.rate::text, '') FROM pgvigil.mssql_counter_series k
  JOIN pgvigil.mssql_counter_sample s ON s.instance_id = k.instance_id AND s.series_id = k.series_id AND s.snapshot_at = '$(at "$1")'
  WHERE k.instance_id = $SY AND k.object = '$2' AND k.counter = '$3'"; }
# P2: the gap rule over two stops close together
syn_ctr 10:00:00 "$(br 1000)"; syn_ctr 13:00:00 "$(br 2000)"; syn_ctr 17:00:00 "$(br 3000)"; syn_ctr 17:01:00 "$(br 3600)"
G13=$(synrd 13:00:00 'SQL Statistics' 'Batch Requests/sec'); G17=$(synrd 17:00:00 'SQL Statistics' 'Batch Requests/sec'); G1701=$(synrd 17:01:00 'SQL Statistics' 'Batch Requests/sec')
[[ "$G13" == "|" && "$G17" == "|" && "$G1701" == "600|10" ]] || fail "P2: change|rate at 13:00 [$G13], 17:00 [$G17] (want none: a stop right after a gap read), 17:01 [$G1701] (want 600|10)"
ok "P2: F15 over two stops close together: no change or rate at 13:00 nor 17:00; 600 and 10/s at 17:01"
# P1: the SQL Agent counts at the jobs reads
syn_jobs 20:00:00 100 ''; syn_ctr 20:01:00 "$(br 4000)"
syn_ctr 20:02:00 "$(br 4100)"
syn_jobs 20:03:00 101 '' 101 20:01:10 0 20; syn_ctr 20:04:00 "$(br 4200)"
F1=$(synpt agent_jobs_failed); S1=$(synpt agent_jobs_started); A1=$(synpt agent_active_jobs)
[[ "$F1" == "20:03:00=1" && "$S1" == "20:03:00=1" && "$A1" == "20:03:00=0" ]] \
  || fail "P1: after the jobs read that read a failed run: newest failed [$F1], started [$S1], running [$A1] (want 20:03:00=1, =1, =0)"
syn_jobs 20:08:00 101 20:06:00; syn_ctr 20:09:00 "$(br 4300)"
S2=$(synpt agent_jobs_started); A2=$(synpt agent_active_jobs); F2=$(synpt agent_jobs_failed)
[[ "$S2" == "20:08:00=1" && "$A2" == "20:08:00=1" && "$F2" == "20:08:00=0" ]] \
  || fail "P1: a job running at the next jobs read: started [$S2], running [$A2], failed [$F2] (want 20:08:00=1, =1, =0)"
ok "P1: G329 at the jobs reads: a run that ended between two counter reads counts at the jobs read that read it (failed 1, started 1); a job running at the next jobs read counts there (running 1, started 1)"
# P3: the update conflict ratio's floor
uc() { echo "[{\"kind\":\"ctr\",\"object\":\"Transactions\",\"counter\":\"Update conflict ratio\",\"instance\":\"\",\"type\":1073874176,\"ckind\":\"average\",\"value\":$1,\"base\":$2}]"; }
syn_ctr 21:00:00 "$(uc 0 0)"; syn_ctr 21:01:00 "$(uc 1 1)"; U1=$(synpt update_conflict_pct)
syn_ctr 21:02:00 "$(uc 7 121)"; U2=$(synpt update_conflict_pct)
[[ "$U1" == "21:01:00=0" && "$U2" == "21:02:00=5" ]] || fail "P3: update_conflict_pct [$U1] (one update in 60 s: want 0), [$U2] (6 of 120: want 5)"
ok "P3: update_conflict_pct 0 under 1 snapshot update/s, 5 over it"
# P8 (review part 4, finding 11; F9): an average over a step that spans two reads with unequal base changes is the
# summed change over the summed base change, never the mean of the reads' figures
syn_ctr 22:00:00 "$(uc 100 1000)"; syn_ctr 22:01:00 "$(uc 160 1120)"; syn_ctr 22:02:00 "$(uc 166 1720)"
UCS=$(pq "SELECT series_id FROM pgvigil.mssql_counter_series WHERE instance_id = $SY AND object = 'Transactions' AND counter = 'Update conflict ratio'")
P8=$(pq "SELECT round(value::numeric, 4) FROM pgvigil.mssql_counter_series_between($SY, '$(at 21:59:59)', '$(at 22:04:59)', 300, ARRAY[$UCS])")
[[ "$P8" == 0.0917 ]] || fail "P8: the 5-minute step over 60 / 120 and 6 / 600 [$P8] (want 66 / 720 = 0.0917, not the mean of 0.5 and 0.01)"
ok "P8: an average over a step of two reads is the summed change over the summed base change (0.0917, not 0.255)"
# P4-P7: the list
inlist() { pq "SELECT coalesce(string_agg(coalesce(e->>'kind', ''), ',') , 'absent') FROM jsonb_array_elements(pgvigil.mssql_counter_list($SY)) e
  WHERE lower(e->>'object') = lower('$1') AND lower(e->>'counter') = lower('$2') AND e->>'inst' = ''"; }
door() { pq "SELECT pgvigil.import_mssql_counter_config(now(), '$1'::jsonb)"; }
endrows() { for c in $(pq "SELECT config_id FROM pgvigil.mssql_counter_config WHERE ended_at IS NULL AND created_by = 'proof-p'"); do
  door "{\"op\":\"end\",\"ui_user\":\"proof-p\",\"config_id\":\"$c\"}" | grep -q '"done"' || fail "P: ending row $c"; done; }
door '{"op":"add","ui_user":"proof-p","scope":"tag","tag":"env:synx","object":"Plan Cache","counter":"Cache Pages","action":"remove"}' | grep -q '"done"' || fail "P4: the env:synx removal"
door '{"op":"add","ui_user":"proof-p","scope":"tag","tag":"env:syny","object":"Plan Cache","counter":"Cache Pages","action":"add"}' | grep -q '"done"' || fail "P4: the env:syny add"
L1=$(inlist 'Plan Cache' 'Cache Pages')
# review part 3's finding 2: the Admin page's 'in force' is the list's own rule - one winner, the newer row
W1=$(pq "SELECT count(*) FILTER (WHERE wins) || '|' || coalesce(string_agg(action, ',') FILTER (WHERE wins), '') FROM pgvigil.mssql_counter_layers_won($SY)
  WHERE lower(object) = 'plan cache' AND lower(counter) = 'cache pages' AND inst = '' AND level = 4")
[[ "$W1" == "1|add" ]] || fail "P4: the layers' winners at one level [$W1] (want 1|add)"
door '{"op":"add","ui_user":"proof-p","scope":"tag","tag":"env:synx","object":"Plan Cache","counter":"Cache Pages","action":"remove"}' | grep -q 'replaced' || fail "P4: the env:synx removal again"
L2=$(inlist 'Plan Cache' 'Cache Pages')
[[ "$L1" != absent && "$L2" == absent ]] || fail "P4: two tag rows at one level: after the newer add [$L1] (want in the list), after the newer removal [$L2] (want absent)"
ok "P4: two tag rows of the instance at one level: the newer wins, each way"
endrows
R1=$(door '{"op":"add","ui_user":"proof-p","scope":"fleet","object":"SQL Statistics","counter":"Forced Parameterizations/sec","action":"add"}')
R2=$(door '{"op":"add","ui_user":"proof-p","scope":"fleet","object":"sql statistics","counter":"forced parameterizations/sec","action":"add"}')
NLIVE=$(pq "SELECT count(*) FROM pgvigil.mssql_counter_config WHERE ended_at IS NULL AND lower(counter) = 'forced parameterizations/sec'")
grep -q '"done"' <<<"$R1" && grep -q 'replaced by row' <<<"$R2" && [[ "$NLIVE" == 1 ]] || fail "P5: the same counter in lower case: [$R2], $NLIVE live row(s) (want 'replaced by row', 1)"
ok "P5: a fleet row naming a live row's counter in another case replaces it (one live row)"
endrows
door '{"op":"add","ui_user":"proof-p","scope":"fleet","object":"Databases","counter":"Log Growths","action":"add"}' | grep -q '"done"' || fail "P6: the fleet add"
K6=$(inlist 'Databases' 'Log Growths')
[[ "$K6" == count ]] || fail "P6: an add with no kind over the default's count: the list's kind [$K6] (want count)"
ok "P6: an add with no kind keeps the default's kind (count)"
endrows
R7=$(door '{"op":"add","ui_user":"proof-p","scope":"fleet","object":"SYS.DM_OS_SCHEDULERS","counter":"yield_count","action":"add","kind":"gauge"}')
grep -q '"refused"' <<<"$R7" && grep -q 'is a DMV column' <<<"$R7" || { endrows; fail "P7: SYS.DM_OS_SCHEDULERS / yield_count with a kind: $R7"; }
ok "P7: Admin refuses a kind on a DMV column named in upper case"
endrows
pq "UPDATE pgvigil.instances SET is_active = false WHERE instance_id = $SY" >/dev/null
[[ $(pq "SELECT count(*) FROM pgvigil.mssql_counter_config WHERE ended_at IS NULL AND created_by = 'proof-p'") == 0 ]] || fail "P: a row of P left live"

echo "== I. F1: the CPU page's workload groups =="
col mssql_cpu mssql_counters
python3 - internal/repo/sql/0124_darling_cpu.sql "$TMPD/old_cpu.sql" <<'PY'
import sys
s = open(sys.argv[1]).read(); a = s.index('CREATE OR REPLACE FUNCTION pgvigil.mssql_cpu_newest('); b = s.index('$$;', a) + 3
open(sys.argv[2], 'w').write(s[a:b].replace('pgvigil.mssql_cpu_newest(', 'pg_temp.old_cpu_newest(', 1))
PY
OLD=$(psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -f "$TMPD/old_cpu.sql" -c "SELECT coalesce(rg_active_requests::text, 'NULL') FROM pg_temp.old_cpu_newest($SB, now() - interval '1 hour', now())" | tail -1)
NEW=$(pq "SELECT coalesce(rg_active_requests::text, 'NULL') FROM pgvigil.mssql_cpu_newest($SB, now() - interval '1 hour', now())")
[[ "$OLD" == NULL && "$NEW" != NULL ]] || fail "I: 0124's body $OLD, the join's $NEW"
ok "I: 0124's mssql_cpu_newest reads NULL workload groups once the counters left mssql_cpu (red); the join's reads $NEW (green)"

echo "== J. the API =="
NOW_LOG=$(pq "SELECT count(*) FROM pgvigil.mssql_counter_config_log")
PGVIGIL_PASSWORD=$UIPW "$TMPD/pgvigil" user add -config "$CFG" "$UIUSER" > /dev/null 2>&1 || fail "J: user add"
serve() { local p; for _ in 1 2 3; do p=$(freeport 29000 32499)
    "$TMPD/pgvigil" serve -config "$CFG" -listen "127.0.0.1:$p" "$@" > "$TMPD/serve-$p.log" 2>&1 & local pid=$!
    for _ in $(seq 1 60); do grep -q "url=http://127.0.0.1:$p/" "$TMPD/serve-$p.log" 2>/dev/null && { echo "$pid $p"; return 0; }; kill -0 $pid 2>/dev/null || break; sleep 0.5; done
    kill $pid 2>/dev/null || true; done; fail "J: serve never answered: $(tail -3 "$TMPD"/serve-*.log)"; }
# serve's own fail runs in a subshell: an empty answer is caught here (review part 4, finding 16)
read -r SRVPID SPORT <<<"$(serve)"; [[ "$SPORT" =~ ^[0-9]+$ ]] || fail "J: serve did not start"
read -r SRV2PID SPORT2 <<<"$(serve -no-login)"; [[ "$SPORT2" =~ ^[0-9]+$ ]] || fail "J: serve -no-login did not start"
U=http://127.0.0.1:$SPORT; U2=http://127.0.0.1:$SPORT2; JAR=$TMPD/jar
code() { curl -s -m 20 -o "$TMPD/body" -w '%{http_code}' "$@"; }
[[ $(code -X POST -H 'X-Pgvigil: 1' -d '{}' "$U/api/mssql/counteradmin") == 401 ]] || fail "J: a POST without a session: $(cat "$TMPD/body")"
# the password from a file, never curl's argv (review part 4, finding 9)
printf '{"username":"%s","password":"%s"}' "$UIUSER" "$UIPW" > "$TMPD/login.json"
[[ $(code -c "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login") == 200 ]] || fail "J: the UI login: $(cat "$TMPD/body")"
[[ $(code -b "$JAR" -X POST -d '{}' "$U/api/mssql/counteradmin") == 403 ]] || fail "J: a POST without the header"
for q in "" "?instance=$SB"; do
  [[ $(code -b "$JAR" "$U/api/mssql/counteradmin$q") == 200 ]] || fail "J: GET$q: $(cat "$TMPD/body")"
  python3 - "$TMPD/body" "$q" <<'PY' || fail "J: GET$q parts"
import json, sys
d = json.load(open(sys.argv[1])); want = ['config', 'defaults', 'log', 'catalog'] + (['layers', 'absent', 'histogram'] if sys.argv[2] else [])
miss = [p for p in want if not isinstance(d.get(p), dict)]
print(f"   GET{sys.argv[2]}: writable {d.get('writable')}, parts {sorted(k for k in d if isinstance(d[k], dict))}")
sys.exit(1 if miss or d.get('writable') is not True else 0)
PY
done
P1=$(code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"op\":\"add\",\"scope\":\"instance\",\"instance_id\":$SB,\"object\":\"General Statistics\",\"counter\":\"Mars Rollbacks/sec\",\"action\":\"add\"}" "$U/api/mssql/counteradmin")
CID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("config_id") or "")' "$TMPD/body")
P2=$(code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{"op":"add","scope":"fleet","object":"Locks","counter":"Lock Waits/sec","action":"remove"}' "$U/api/mssql/counteradmin")
grep -q 'read by' "$TMPD/body" || fail "J: the refusal's words: $(cat "$TMPD/body")"
# review part 3's finding 1: the page shows a refusal's reason from the body's error (api.ts post throws b.error)
python3 -c 'import json,sys; sys.exit(0 if "is read by" in (json.load(open(sys.argv[1])).get("error") or "") else 1)' "$TMPD/body" || fail "J: the refusal's error field: $(cat "$TMPD/body")"
P3=$(code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"op\":\"end\",\"config_id\":$CID}" "$U/api/mssql/counteradmin")
[[ "$P1 $P2 $P3" == "200 409 200" ]] || fail "J: POST add / refused / end: $P1 $P2 $P3"
[[ $(code "$U2/api/mssql/counteradmin") == 200 ]] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["writable"] is False and "-no-login" in d["reason"] else 1)' "$TMPD/body" \
  || fail "J: the -no-login serve's GET: $(cat "$TMPD/body")"
[[ $(code -X POST -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{"op":"add","scope":"fleet","object":"a","counter":"b","action":"add"}' "$U2/api/mssql/counteradmin") == 403 ]] || fail "J: the -no-login serve took a POST"
LOGS=$(pq "SELECT string_agg(outcome || '=' || n, ' ' ORDER BY outcome) FROM (SELECT outcome, count(*) n FROM pgvigil.mssql_counter_config_log WHERE ui_user = '$UIUSER' AND client = '127.0.0.1' GROUP BY 1) x")
[[ "$LOGS" == "done=2 refused=1" && $(pq "SELECT count(*) FROM pgvigil.mssql_counter_config_log") == $((NOW_LOG + 3)) ]] || fail "J: the log [$LOGS]"
ok "J: GET every part with and without an instance; POST 401 / 403 / add 200 / refused 409 ('read by') / end 200; a -no-login serve read only and refusing; the log holds done=2 refused=1 by the proof's user from 127.0.0.1"

echo "== K. the pages =="
setsid chromium --headless=new --remote-debugging-port=0 --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu about:blank > "$TMPD/chrome.log" 2>&1 & CHRPID=$!
CDP=; for _ in $(seq 1 60); do [ -s "$TMPD/chrome/DevToolsActivePort" ] && CDP=$(head -1 "$TMPD/chrome/DevToolsActivePort"); [ -n "$CDP" ] && curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
[[ "$CDP" =~ ^[0-9]+$ ]] || fail "K: Chromium never answered"
cat > "$TMPD/page.mjs" <<'PAGE'
const [port, base, sb, shots] = process.argv.slice(2);
setTimeout(() => { console.log('FAIL the page check did not end in 300 s'); process.exit(2); }, 300000).unref();
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map(); let thrown = [];
ws.addEventListener('message', m => { const d = JSON.parse(m.data);
  if (d.method === 'Runtime.exceptionThrown') thrown.push(d.params.exceptionDetails?.exception?.description ?? 'exception');
  if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => (await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true })).result?.result?.value;
const until = async (e, ms = 45000) => { const t = Date.now(); while (Date.now() - t < ms) { const v = await ev(e); if (v) return v; await sleep(300); } return null; };
let failed = 0; const check = (l, ok, w) => { if (!ok) failed++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${l}: ${w}`); };
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
const gridRows = h => `(() => { const h3 = [...document.querySelectorAll('main h3')].find(x => x.textContent.trim().startsWith(${JSON.stringify(h)})); if (!h3) return -2;
  let t = h3.nextElementSibling; while (t && !t.querySelector?.('table.grid') && !t.matches?.('table.grid') && !t.matches?.('p.empty') && t.tagName !== 'H3') t = t.nextElementSibling;
  const tb = t?.matches?.('table.grid') ? t : t?.querySelector?.('table.grid'); return tb ? Number(tb.dataset.rows) : t?.matches?.('p.empty') ? 0 : -1; })()`;
const api = async (q, part) => { const d = await (await fetch(`${base}/api/${q}`)).json(); return d[part]?.rows?.length ?? -1; };
// blank / fresh: every theme's page is a new document opened through about:blank, settled on its own hash (boxfix S2:
// a hash-only navigation and a reload let the reads see the page before the reload, as 404green1d's F harness did)
const blank = async () => { await cmd('Page.navigate', { url: 'about:blank' }); for (let i = 0; i < 50; i++) { if ((await ev('location.href')) === 'about:blank') return; await sleep(100); } throw new Error('about:blank never loaded'); };
const khash = `#/counters?i=${sb}&w=1h`;
const fresh = async () => { await blank(); await cmd('Page.navigate', { url: `${base}/${khash}` });
  return until(`location.hash === ${JSON.stringify(khash)} && document.readyState === 'complete' && !!document.querySelector('main')`); };
for (const theme of ['light', 'dark']) {
  await fresh(); await ev(`localStorage.setItem('pgvigil.theme', '${theme}')`); await fresh();
  check(`counters ${theme}`, (await until(`[...document.querySelectorAll('main h3')].some(h => h.textContent.startsWith('Listed but not read'))`)) !== null, "the 'Listed but not read' section");
  const nowRows = await api(`mssql/counters?instance=${sb}&part=now`, 'now');
  const g = await ev(gridRows('Performance counters'));
  check(`counters ${theme}`, g === nowRows && nowRows > 300, `grid ${g} rows, the API's now part ${nowRows}`);
  const heads = await ev(`[...document.querySelectorAll('main table.grid')].some(t => [...t.querySelectorAll('th')].some(th => th.textContent.trim() === 'figure') && [...t.querySelectorAll('th')].some(th => th.textContent.trim() === 'kind'))`);
  check(`counters ${theme}`, heads, 'a grid with the figure and kind columns');
  check(`counters ${theme}`, await ev(gridRows('Batch response times')) === 17, `Batch response times ${await ev(gridRows('Batch response times'))} rows`);
  check(`counters ${theme}`, await ev(`[...document.querySelectorAll('main h3')].some(h => h.textContent.trim() === 'Counters')`), "the 'Counters' family grid");
  check(`counters ${theme}`, !(await ev(`!!document.querySelector('main .error, main .errorbox, main [role=alert].error')`)), 'no error box');
  if (shots) { const s = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }); (await import('node:fs')).writeFileSync(`${shots}/counters-${theme}.png`, Buffer.from(s.result.data, 'base64')); }
  await cmd('Page.navigate', { url: `${base}/#/admin_counters?w=1h` });
  check(`admin ${theme}`, (await until(`[...document.querySelectorAll('main h3')].some(h => h.textContent.trim() === 'Log')`)) !== null, "Admin > Counters' 'Log'");
  const cfg = await api('mssql/counteradmin?part=config', 'config'), def = await api('mssql/counteradmin?part=defaults', 'defaults');
  check(`admin ${theme}`, await ev(gridRows('Rows made here')) === cfg, `Rows made here ${await ev(gridRows('Rows made here'))}, the API ${cfg}`);
  check(`admin ${theme}`, await ev(gridRows('The defaults')) === def, `The defaults ${await ev(gridRows('The defaults'))}, the API ${def}`);
  check(`admin ${theme}`, (await ev(gridRows('Counters the servers have'))) > 300, `Counters the servers have ${await ev(gridRows('Counters the servers have'))}`);
  // Save row: off with the -no-login reason beside it; each End: off, a space, the short 'off here: the line above says
  // why' beside it, the long reason in its title; the page's line names -no-login
  const offs = await ev(`[...document.querySelectorAll('main button')].filter(b => b.textContent.trim() === 'Save row' || b.textContent.trim() === 'End').map(b => {
    const n = document.getElementById(b.getAttribute('aria-describedby') || '')?.textContent || '';
    if (b.getAttribute('aria-disabled') !== 'true') return false;
    if (b.textContent.trim() === 'Save row') return n.includes('-no-login');
    return n === 'off here: the line above says why' && (b.title || '').includes('-no-login') && b.parentElement.textContent.startsWith('End off here'); })`);
  check(`admin ${theme}`, offs.length >= 1 && offs.every(Boolean), `${offs.length} Save / End control(s), each off with its reason beside it (End: a space, the short reason, -no-login in its title)`);
  check(`admin ${theme}`, await ev(`[...document.querySelectorAll('main p.meta')].some(p => p.textContent.startsWith('Edits are off here:') && p.textContent.includes('-no-login'))`), "the page's line 'Edits are off here: ... -no-login'");
  if (shots) { const s = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }); (await import('node:fs')).writeFileSync(`${shots}/admin-counters-${theme}.png`, Buffer.from(s.result.data, 'base64')); }
}
check('pages', thrown.length === 0, thrown.length ? thrown.slice(0, 3).join(' | ') : 'no exception');
process.exit(failed ? 1 : 0);
PAGE
timeout 320 node "$TMPD/page.mjs" "$CDP" "$U2" "$SB" "$SHOTS" || fail "K: a check of the pages failed"
ok "K: the Metrics page's counters (rows = the API's), the histogram, the absent list, the Counters family, Admin > Counters (rows = the API's) with its controls off and their reason, light and dark"

echo "== N. D6: the Performance summary, the CPU page's scheduler trend, the Memory page's clerk names =="
# The reads (review part 5 S1-S3): the page's scheduler trend has steps of 60 s over an hour and draws a line only from
# two steps ('a chart needs two': run proof8 read two reads in one step), so R1 lands in the minute after R0; every read
# of R0-R2 takes mssql_counters too (failed_to_create_worker is its series); R3, mssql_cpu alone in a later minute, makes
# a step with no counter read (its failed_to_create_worker NULL); R4, 30 s of nothing after R3, is the floor's window
# (under 1 batch a second: compilations per 100 batches 0; with 402's FL5 under 5: no ratio). Batch Requests/sec and
# SQL Compilations/sec are read by hand right after R0's mssql_cpu read (mssql_cpu runs last in R0) and right before
# R2's (first in R2): the summary over (R0, R2] is 100 x their change, the reads around the hand reads adding at most
# 10 batches and 10 compilations to either side.
# busymin, the wait into the next minute, kept busy: the summary judges the ratio only at its floor or more (1 batch a
# second, 5 with FL5) over the WHOLE window (R0, R2], and that window also holds nine collector runs and a 2 s sleep
# with next to no batch - one session of 0.15 s waits read 3.04, 2.96 and 3.28 batches a second there (box runs
# 401proof15-17), under FL5's 5. So four sessions side by side, each max(w, 20) x 30 batches: 2,400 batches or more,
# 8 a second even over a window of 300 s. A batch waits 0.03 s until the wait's own end and not at all after it, so a
# slow box cannot stretch the wait; a wait whose batches end early sleeps to its second (the next read must land in
# the next minute).
busymin() { local w=$(( 62 - 10#$(date -u +%S) )) n t0 end endz body p pids=()
  t0=$(date +%s); n=$(( (w > 20 ? w : 20) * 30 )); end=$(( t0 + w )); endz=$(date -u -d "@$end" +%Y-%m-%dT%H:%M:%S)
  body=$(for _ in $(seq 1 $n); do echo "IF SYSUTCDATETIME() < '$endz' WAITFOR DELAY '00:00:00.030';"; echo GO; done)
  for p in 1 2 3 4; do sq "$body" master 300 >/dev/null & pids+=($!); done
  for p in "${pids[@]}"; do wait "$p" || fail "N: a session of the busy wait to the minute failed"; done
  echo "   the busy wait: 4 sessions x $n batches in $(( $(date +%s) - t0 )) s (the wait to its second: $w s)"
  while (( $(date +%s) < end )); do sleep 0.2; done; }
handbc() { sq "SELECT CAST(SUM(CASE WHEN RTRIM(counter_name) = N'Batch Requests/sec' THEN cntr_value END) AS varchar(20)) + '|' + CAST(SUM(CASE WHEN RTRIM(counter_name) = N'SQL Compilations/sec' THEN cntr_value END) AS varchar(20))
  FROM sys.dm_os_performance_counters WHERE RTRIM(object_name) LIKE N'%:SQL Statistics' AND RTRIM(counter_name) IN (N'Batch Requests/sec', N'SQL Compilations/sec')"; }
[[ 10#$(date -u +%S) -gt 40 ]] && sleep $(( 61 - 10#$(date -u +%S) ))
col mssql_memory mssql_counters mssql_cpu; H0=$(handbc); NF0=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
busymin
col mssql_cpu mssql_memory mssql_counters
sq "$(for i in $(seq 1 20); do echo "SELECT COUNT(*) FROM sys.objects WHERE object_id > $i;"; echo GO; done)" >/dev/null
sleep 2; H1=$(handbc); col mssql_cpu mssql_memory mssql_counters; NT1=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
busymin; col mssql_cpu; NF3=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
sleep 30; col mssql_cpu; NT3=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
NF=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ); NT=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)
for q in "perfsummary?part=mssql&from=$NF&to=$NT" "mssql/cpu?instance=$SB&part=sched&from=$NF&to=$NT" "mssql/memory?instance=$SB&part=clerk_stats&from=$NF&to=$NT" \
         "perfsummary?part=mssql&from=$NF0&to=$NT1" "perfsummary?part=mssql&from=$NF3&to=$NT3"; do
  n=${q%%\?*}; n=${n//\//_}; [[ "$q" == *"from=$NF0"* ]] && n=perfsummary_hand; [[ "$q" == *"from=$NF3"* ]] && n=perfsummary_floor
  [[ $(code "$U2/api/$q") == 200 ]] || fail "N: GET $q: $(cat "$TMPD/body")"; cp "$TMPD/body" "$TMPD/n-$n.json"
done
python3 - "$PGDSN" "$SB" "$NF" "$NT" "$TMPD" "$H0" "$H1" <<'PY2' || fail "N: an API row of D6"
import json, subprocess, sys
dsn, sb, nf, nt, d, h0, h1 = sys.argv[1:8]
rows = lambda f, p: [dict(zip(t['columns'], r)) for t in [json.load(open(f'{d}/n-{f}.json'))[p]] for r in t['rows']]
q = lambda s: subprocess.run(['psql', dsn, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-F', '|', '-c', s], capture_output=True, text=True, check=True).stdout.strip()
bad = []
one = lambda f: ([r for r in rows(f, 'mssql') if r.get('instance') == 'ctrbox'] or [{}])[0]
# the summary over (R0, R2] against SQL Server's own counters read by hand (not the code's formula)
(b0, c0), (b1, c1) = [[int(x) for x in h.split('|')] for h in (h0, h1)]
db, dc = b1 - b0, c1 - c0
hs = one('perfsummary_hand')
got, bs = hs.get('compiles_per_100'), hs.get('batch_s')
lo = 100 * max(dc - 10, 0) / (db + 10); hi = 100 * (dc + 10) / max(db - 10, 1)
print(f'   perfsummary over (R0, R2]: batch_s {bs}, compiles_per_100 {got}; by hand +{db} batches, +{dc} compilations: {100 * dc / db:.1f} (with the reads around the hand reads {lo:.1f}-{hi:.1f})')
# 402's FL5 (q_perfsummary.go's floor) when the response carries compiles_floor: the summary's floor is 5, not 1
fl5 = 'compiles_floor' in hs
floor = 5 if fl5 else 1
fl5_words = '402s FL5 in this tree' if fl5 else 'no FL5 in this tree'
print(f'   the summary floor: {floor} batch/s ({fl5_words})')
if bs is None or float(bs) < floor: bad.append(f'the hand window read {bs} batches/s: under the {floor}/s floor, the ratio not tested')
if got is None or not (lo - 0.05 <= float(got) <= hi + 0.05): bad.append(f'compiles_per_100 {got} outside {lo:.1f}-{hi:.1f}')
# the floor's window (R3, R4]: 30 s with nothing of the proof running
fl = one('perfsummary_floor')
print(f"   perfsummary over (R3, R4]: batch_s {fl.get('batch_s')}, compiles_per_100 {fl.get('compiles_per_100')}")
if fl.get('batch_s') is not None and float(fl['batch_s']) < floor:
    if fl5:
        if fl.get('compiles_per_100') is not None or fl.get('compiles_under_floor') is not True or fl.get('compiles_floor') != 5:
            bad.append(f"under FL5's floor: compiles_per_100 {fl.get('compiles_per_100')} (want none), under_floor {fl.get('compiles_under_floor')} (want true), floor {fl.get('compiles_floor')} (want 5)")
    elif fl.get('compiles_per_100') is None or float(fl['compiles_per_100']) != 0: bad.append(f"under the floor compiles_per_100 {fl.get('compiles_per_100')}, want 0")
else:
    print(f"NOT PROVEN live: the floor (the idle window read {fl.get('batch_s')} batches/s: the server was not idle)")
# the hour the page shows: the cell the page check compares. With FL5 an hour under the floor holds no ratio and the
# page's cell says so in words ('NA' tells the page check to expect them); no ratio for any other reason stays a red
ps = one('perfsummary')
print(f"   perfsummary over the hour: batch_s {ps.get('batch_s')}, compiles_per_100 {ps.get('compiles_per_100')}, under the floor {ps.get('compiles_under_floor')}")
cell = '' if ps.get('compiles_per_100') is None else str(ps['compiles_per_100'])
if fl5 and ps.get('compiles_under_floor') is True:
    if ps.get('compiles_per_100') is not None or ps.get('compiles_floor') != 5:
        bad.append(f"the hour under FL5's floor: compiles_per_100 {ps.get('compiles_per_100')} (want none), floor {ps.get('compiles_floor')} (want 5)")
    cell = 'NA'
open(f'{d}/n-expect-cell', 'w').write(cell)
# the scheduler trend: a value exactly in a step that holds an instance counter read; two steps with a value; R3's step NULL
sr = rows('mssql_cpu', 'sched')
reads = q(f"SELECT string_agg(floor(extract(epoch FROM snapshot_at) / 60)::bigint::text, ',') FROM pgvigil.mssql_counter_read WHERE instance_id = {sb} AND scope = 'instance' AND snapshot_at > '{nf}' AND snapshot_at <= '{nt}'")
have = set(int(x) for x in reads.split(',') if x)
from datetime import datetime
ep = lambda t: int(datetime.fromisoformat(str(t).replace('Z', '+00:00')).timestamp()) // 60
fw = [(ep(r['snapshot_at']), r.get('failed_to_create_worker')) for r in sr]
withv = [v for _, v in fw if v is not None]
print(f'   sched steps {len(fw)}, failed_to_create_worker at {len(withv)} of them: {sorted(set(withv))}; steps without a counter read: {sum(1 for m, _ in fw if m not in have)}')
if len(withv) < 2: bad.append(f'{len(withv)} step(s) with failed_to_create_worker: the trend needs two')
if not any(float(v) == 0 for v in withv): bad.append('no step with failed_to_create_worker 0')
for m, v in fw:
    if (v is not None) != (m in have): bad.append(f'step {m * 60}: failed_to_create_worker {v}, a counter read in the step {m in have}')
if not fw or fw[-1][1] is not None: bad.append("R3's step (the last, mssql_cpu alone) is not NULL")
bp = [r for r in rows('mssql_memory', 'clerk_stats') if r.get('clerk_type') == 'MEMORYCLERK_SQLBUFFERPOOL']
print(f"   clerk_stats: MEMORYCLERK_SQLBUFFERPOOL named [{bp[0].get('clerk_name') if bp else 'no row'}]")
if not bp or bp[0].get('clerk_name') != 'Buffer Pool': bad.append('the buffer pool clerk not named Buffer Pool')
for x in bad: print('   FAIL ' + x)
sys.exit(1 if bad else 0)
PY2
cat > "$TMPD/d6.mjs" <<'PAGE'
const [port, base, sb, cellWant] = process.argv.slice(2);
setTimeout(() => { console.log('FAIL the D6 page check did not end in 120 s'); process.exit(2); }, 120000).unref();
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
let failed = 0; const check = (l, ok) => { if (!ok) failed++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${l}`); };
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: `${base}/#/perfsummary?w=1h` });
// ctrbox's cell under the column holds the API's figure for the same hour (review part 5 S1: a header alone passes with
// a wrong column key)
const cell = await until(`(() => { for (const t of document.querySelectorAll('main table')) {
  const i = [...t.querySelectorAll('th')].findIndex(th => th.textContent.trim().startsWith('compilations per 100 batches')); if (i < 0) continue;
  const tr = [...t.querySelectorAll('tbody tr')].find(r => r.textContent.includes('ctrbox')); if (!tr) return null;
  return tr.children[i]?.textContent.trim() ?? null; } return null; })()`);
const near = (a, b) => a !== '' && b !== '' && Math.abs(parseFloat(String(a).replace(/[^0-9.\-]/g, '')) - parseFloat(b)) <= 0.051;
// an hour under FL5's floor (the API's compiles_under_floor, 'NA' here): the cell says so in words with the floor,
// never a number
const cellOk = cell != null && (cellWant === 'NA' ? cell.startsWith('N/A: too few batch requests/s') && cell.includes('the floor 5/s') : near(cell, cellWant));
check(`N page: the Performance summary's 'compilations per 100 batches' cell for ctrbox reads ${cell} (the API ${cellWant === 'NA' ? 'no ratio: the hour is under the floor' : cellWant})`, cellOk);
await cmd('Page.navigate', { url: `${base}/#/mssqlcpu?i=${sb}&w=1h` });
check("N page: the CPU page's scheduler trend names 'schedulers that failed to create a worker'", !!await until(`document.querySelector('main')?.innerText.includes('schedulers that failed to create a worker')`));
await cmd('Page.navigate', { url: `${base}/#/mssqlmemory?i=${sb}&w=1h` });
check("N page: the Memory page's clerks grid has 'what it is' with Buffer Pool", !!await until(`[...document.querySelectorAll('main table.grid')].some(t => [...t.querySelectorAll('th')].some(th => th.textContent.trim().startsWith('what it is')) && [...t.querySelectorAll('td')].some(td => td.textContent.trim() === 'Buffer Pool'))`));
check('N pages: no exception', thrown.length === 0);
process.exit(failed ? 1 : 0);
PAGE
timeout 140 node "$TMPD/d6.mjs" "$CDP" "$U2" "$SB" "$(cat "$TMPD/n-expect-cell")" || fail "N: a D6 page check failed"
ok "N: compiles_per_100 on the Performance summary = SQL Server's own counters read by hand over (R0, R2], 0 under the floor; failed_to_create_worker on exactly the trend's steps with a counter read, NULL on R3's; Buffer Pool named on the Memory page's clerks; the pages show them (ctrbox's summary cell = the API's)"

echo "== M. the size =="
pq "SELECT scope, round(avg(rows_read)), count(*) FROM pgvigil.mssql_counter_read WHERE instance_id = $SB GROUP BY 1 ORDER BY 1" | sed 's/^/   reads: /'
M_BYTES1=$(pq "SELECT coalesce(sum(pg_total_relation_size(relid)), 0) FROM pg_partition_tree('pgvigil.mssql_counter_sample')"); M_ROWS1=$(pq "SELECT count(*) FROM pgvigil.mssql_counter_sample")
M_DBS=$(sq "SELECT CAST(COUNT(*) AS varchar(10)) FROM sys.databases" | tr -d '[:space:]')
python3 - "$PGDSN" "$SB" "$M_BYTES0" "$M_BYTES1" "$M_ROWS0" "$M_ROWS1" "$M_DBS" <<'PY' || fail "M: see above"
import subprocess, sys
q = lambda s: subprocess.run(['psql', sys.argv[1], '-XAtq', '-c', s], capture_output=True, text=True, check=True).stdout.strip()
sb = sys.argv[2]
b0, b1, r0, r1, dbs = (int(x) for x in sys.argv[3:8])
per, read, nread = {}, {}, {}
for sc in ('instance', 'database'):
    per[sc] = float(q(f"""SELECT coalesce(avg(n), 0) FROM (SELECT count(*) n FROM pgvigil.mssql_counter_sample s JOIN pgvigil.mssql_counter_read r ON r.instance_id = s.instance_id AND r.snapshot_at = s.snapshot_at
       WHERE s.instance_id = {sb} AND r.scope = '{sc}' GROUP BY s.snapshot_at) x"""))
    read[sc] = float(q(f"SELECT coalesce(avg(rows_read), 0) FROM pgvigil.mssql_counter_read WHERE instance_id = {sb} AND scope = '{sc}'"))
# the bytes the run's rows took, measured (table, its indexes and its toast), over the rows it stored
if r1 <= r0 or b1 <= b0:
    sys.exit(f"M: measured {b1 - b0} bytes for {r1 - r0} rows (the partitions' sizes not read)")
row = (b1 - b0) / (r1 - r0)
day = lambda i, d: i * 1440 + d * 288                 # one instance read a minute, one database read per 5 minutes
mb = lambda n: n * row / 1048576
pdb = per['database'] / max(1, dbs)                    # the database read stores each database's rows
print(f"   {dbs} databases on the box; rows read per read: instance {read['instance']:.0f}, database {read['database']:.0f}; "
      f"stored: instance {per['instance']:.0f} ({100 * per['instance'] / max(1, read['instance']):.0f} %: raw 0 goes to zero_series), "
      f"database {per['database']:.0f} ({100 * per['database'] / max(1, read['database']):.0f} %, about {pdb:.0f} per database)")
print(f"   measured: {b1 - b0:,} bytes for {r1 - r0:,} rows ({row:.0f} bytes a row with its indexes)")
print(f"   a day, this instance as read: {day(per['instance'], per['database']):,.0f} rows, {mb(day(per['instance'], per['database'])):.0f} MB; "
      f"each further database: {pdb * 288:,.0f} rows, {mb(pdb * 288):.1f} MB; "
      f"a busy server storing every row it reads: {day(read['instance'], read['database']):,.0f} rows, {mb(day(read['instance'], read['database'])):.0f} MB "
      f"(its database read grows with its databases: at 300 databases about {mb(day(read['instance'], 0) + read['database'] / max(1, dbs) * 300 * 288):,.0f} MB)")
PY

# the version run starts from the defaults: the Admin rows the proof left live are ended first (E's fleet row and its
# tag row on env:ctrproof, which the version run's instance carries too: run 5 read a list of 143 with it live)
for id in $(pq "SELECT config_id FROM pgvigil.mssql_counter_config WHERE ended_at IS NULL"); do
  door "{\"op\":\"end\",\"ui_user\":\"proof-l\",\"config_id\":\"$id\"}" | grep -q '"done"' || fail "L: ending the Admin row $id"
done
for img in "${IMAGES[@]:1}"; do
  echo "== L. the version run on $img =="
  OLDSQL=$SQL; start "$img"; docker rm -f -v "$OLDSQL" >/dev/null 2>&1 || true
  NAME=ctr${img%%-*}
  psql "$PGDSN" -Xqc "UPDATE pgvigil.instances SET is_active = false WHERE name = 'ctrbox'" >/dev/null
  sed -i "s/name: ctrbox/name: $NAME/" "$CFG"
  colv() { for c in "$@"; do timeout 180 "$TMPD/pgvigil" collect -config "$CFG" -instance "$NAME" -once "$c" > "$TMPD/col-$c.out" 2>&1 || { cat "$TMPD/col-$c.out" >&2; fail "L: collect $c"; }; done; }
  colv mssql_instance mssql_counters mssql_counters_db
  SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = '$NAME'")
  NL=$(pq "SELECT jsonb_array_length(pgvigil.import_mssql_counter_list($SB, '[]'))"); [[ "$NL" == "$NDEF" ]] || fail "L: $img's list $NL"
  col() { colv "$@"; }
  bracket "L $img" || fail "L: $img: a cumulative value outside its hand reads"
  sleep 2; colv mssql_counters
  arith "L $img" || fail "L: $img: a figure differs from its recomputation (arith $?: 1 a stored figure, 2 a ratio metric)"
  # the logins phase with a read of its own first and the proof's event session around it, as D's (the session is
  # dropped at the end of the image's run: nothing of it falls into the error and log growth windows below)
  lgs_start "L $img"; colv mssql_counters
  for _ in $(seq 1 40); do sq "SELECT 1" >/dev/null; done
  sleep 1; colv mssql_counters; DL=$(chg 'General Statistics' 'Logins/sec' '_Total')
  [[ "$DL" == "$LGW" ]] || fail "L: $img logins +$DL (want $LGW: 40 and the collector's own); $(lgs_rows)"
  sq "$(printf "RAISERROR('pgvigil proof user error', 16, 1);\n%.0s" $(seq 1 12))" >/dev/null 2>&1 || true
  sleep 1; colv mssql_counters; EU=$(chg 'SQL Errors' 'Errors/sec' 'User Errors')
  colv mssql_counters_db
  sq "DECLARE @i int = 0; WHILE @i < 500 BEGIN UPDATE dbo.t SET v = v + 1 WHERE id = @i % 2000 + 1; SET @i += 1; END" pgvctr >/dev/null
  sq "INSERT dbo.t (id, pad) SELECT TOP (30000) 100000 + ROW_NUMBER() OVER (ORDER BY (SELECT 1)), REPLICATE('g', 200) FROM sys.all_objects a CROSS JOIN sys.all_objects b" pgvctr >/dev/null
  colv mssql_counters_db; LG=$(chg 'Databases' 'Log Growths' 'pgvctr')
  [[ "$EU" == 12 && -n "$LG" && "$LG" -ge 1 ]] || fail "L: $img logins +$DL, user errors +$EU, pgvctr log growths +$LG"
  lgs_drop
  ok "L: $img ($(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))")): the list = every default, the bracket, C's arithmetic, Logins/sec +40 and the collector's own, User Errors +12, pgvctr Log Growths +$LG"
done

echo "NOT PROVEN HERE: SQL Server 2016 (no Linux image: dba-lab-win's queue), Managed Instance, RDS, Cloud SQL, a Windows host; DB Offline Errors moving (not provoked here); two memory nodes (one Buffer Node in a container)"
echo "PROOF OK: mssql counters (A B C D E F G H P I J K N M L)"
