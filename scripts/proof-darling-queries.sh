#!/usr/bin/env bash
# Proof of task 177 D10, DONE-1 (darling-open D10): migration 0126 (the Query Store's aborted and exception runs apart,
# the procedures' spills, the plan cache's handles), the compare of a window with an earlier one on the Query Store,
# Plan cache and Procedures grids (PerformanceMonitor's top-compare.js), and Regressed in PerformanceMonitor's tests
# (QueryStoreRegressionRules.cs) beside pgvigil's duration test - against hand reads of the same SQL Server.
# Needs: docker (pulls mcr.microsoft.com/mssql/server:2022-latest and postgres:13), go, psql, curl, python3, node, npm, chromium, and:
#   ADMIN_DSN       a superuser connection to a PostgreSQL sandbox in KEYWORD form (default 'host=127.0.0.1 port=5432
#                   user=postgres dbname=postgres'), with no password= in it (it rides on command lines: the password,
#                   if any, comes from ~/.pgpass or PGPASSWORD); the proof makes its own repository databases and drops them.
#   PGVIGIL_WIRING  1 (default) applies scripts/proof-darling-queries-wiring.patch (DONE-2's: router.ts, main.ts,
#                   mssql_plancache.ts, mssql_procs.ts, mssql_running.ts, mssql_waits.ts, q_mssql_running.go,
#                   docs/sqlserver-querystore.md: the lead's files) to this copy when the tree lacks it; 0 = the tree as
#                   it is.
#   PGVIGIL_SHOTS   where step I's page shots and click table go (default: a folder of the run, removed with it)
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment.
#
# Expected (written in the report before the first run):
#  A. a SQL Server 2022 container: database pgvq with Query Store on (1-minute intervals, capture ALL), dbo.t of 20,000
#     rows, procedures (one sorting under MAX_GRANT_PERCENT = 0, so it spills); a monitor login (VIEW SERVER STATE,
#     CONNECT ANY DATABASE, VIEW ANY DEFINITION).
#  B. 0126 under a running import (PostgreSQL only): a repository migrated by a binary without 0126; a session holding
#     ROW EXCLUSIVE on mssql_qs_runtime for 40 s makes the new binary's migrate fail in 20-25 s on the lock timeout
#     (0126 not recorded, no new column); a session shaped as the procedures import (its two parents locked, 8 s, then
#     mssql_proc_last written) makes migrate wait and succeed (6-20 s: the holder starts 1 s before it), and the holder
#     commits too (no deadlock: 0126 takes the parents before the last-read tables); then the six columns, the spills
#     columns, mssql_pc_handles and the two renamed imports exist.
#  C. old-shape payloads into the new imports (synthetic): procstats - an old-shape read (no spills key) then a new
#     one (spills 100) stores the interval's spills NULL and last.spills 100; the next read (130) stores 30; a plan new
#     in it (7) stores 7. querystore - a runtime row with failed 5 and no split keys stores the six NULL; with the keys
#     stores them; failed 0 with the keys sent stores NULL.
#  D. live Query Store, W1 then W2 (two minutes each, on minute bounds of the server's clock), every run in its own
#     sqlcmd session: per window and statement the runs in a hand read of sys.query_store_runtime_stats = the runs
#     sent (0 where none was sent); the stored split = the hand read by execution_type; q_tonew (a statement no plan
#     ends inside the client's 1 s, first sent in W2) 4 Aborted and no row before W2; Regressed (base=prev): q_cost
#     'cost', q_to 'timeouts', q_tonew 'timeouts' with no kept baseline, q_err 'errors' with Aborted 0, q_cheap not
#     'cost'; with q_err's baseline rows in the pre-0126 shape it is no longer raised by 'errors', reads 'not read
#     apart' and is counted by regressed_skipped; Regressed's default (7 days before): q_cost 'cost', q_tonew
#     'timeouts' with no kept baseline; stored rows (synthetic): a query with 4 Aborted runs in the window and none
#     before is raised by 'timeouts' alone, no kept baseline, HIGH, one at the same rate before is not listed;
#     compare=prev: q_new 'new' (compiled in W2), q_nk 'not kept before' (compiled in W0), q_gone 'not kept now',
#     q_cost avg duration over +25 %, no false NEW; the scenario keys' figures = the hand read over the same
#     intervals; the 400-query interval stores at most 250 plans while its interval row counts all.
#  E. procedures and plan cache over reads R0, R1 (after W1), R2 (after W2): the spilling procedure's interval spills =
#     the hand delta of total_spills (> 0); p_new 'new', p_gone 'gone'; mssql_pc_handles = sys.dm_exec_query_stats'
#     sql_handle and query_plan_hash for q_cost's statement; the plan-cache compare labels q_new 'new', and with R1
#     marked cut 'not kept before' and 1 cut read.
#  F. timing through the API, eight runs each (past the fifth: pgx prepares a statement once per connection, and from
#     its sixth run the server may keep a generic plan, which took 18-20 s here, s177j-spike4), every one under 10 s or
#     FAIL: the plan-cache compare (compare=week over a 7-day window, 14 days stored) at 761 and 3,000 rows a read; the
#     Query Store compare (compare=week, 7 days) and Regressed's default (a 1-hour window against PerformanceMonitor's 7
#     days) over 14 days of 1-minute intervals at 250 kept plans each (the collector's ceiling: 5 lists of 50); every
#     timed part returns rows, run 3's compare = run 8's, the box's load printed beside each timing list. PostgreSQL's
#     rule on the compare's SQL (PREPAREd in psql under PGOPTIONS): generic|custom 0|7 under force_custom_plan, a
#     generic plan under auto. The UI pool's own setting: go test's TestUIPoolConfig; through serve, plans = calls for
#     the plan cache's totals in pg_stat_statements where the box preloads it (else NOT PROVEN, said).
#  G. the pages in headless Chromium (light): the Query Store's Top with its compare grid (= the API's rows), Regressed
#     with q_to's and q_err's rows, Plan cache and Procedures with their compare and new columns; no error box.
#  H. DONE-2's reads (PostgreSQL only, on F's seed and synthetic rows): the heatmap's cells (duration, cpu, writes and
#     executions, 24 h, 10-minute bins, 23 samples on and just under the bucket lines) = a hand count of the stored
#     samples in integers (distinct (database, query) per cell, the most-executed
#     by executions summed, the newest 1,000, n_cells all), and equal on a PostgreSQL 13 repository (a throwaway
#     postgres:13 container, where date_bin is refused); the heatmap at 24 h and 7 days at 761 and 3,000 rows a read
#     under 10 s (eight runs each; at 3,000 / 7 days the median of the eight, a slower run printed); 8 days refused 400
#     with 'pick 7 days or less'; 6,048,001 stored samples (the ceiling and one) refused 400 with its own count, and
#     H2's 3,000 / 7 days window, anchored on its seed's newest read, holds exactly 6,048,000 and answers 200; the
#     1,000-cell cut by whole bins (every bucket of 7 days' bins but the newest bin's top one: 143 kept, exactly 1,000
#     cells, the rest counted, H1's 24 h whole); one query's and one procedure's history
#     sum their executions = a hand sum, about 120 steps, under 10 s over 7 days; the Query Store overhead lists the
#     QDS_* waits but PerformanceMonitor's sleep waits, per hour over the measured seconds; the memory clerk's captures,
#     samples, latest and max.
#  I. DONE-2's pages (headless Chromium, light and dark): the Queries page's ten sections in PerformanceMonitor's order,
#     each head = the first rows of its tab's own API read, row by row in order (Running, Plan cache, Query Store,
#     Regressed, Slow queries, Tuning), the heatmap's table and picture = the API's cells, no error box; the Query Store
#     strip re-reads its grid for a step and draws a query's line; the plan cache's History draws a chart; a procedure's
#     chart in PerformanceMonitor's four metrics and its line on the procedures strip; Running's strip steps the slider;
#     with two requests on two waits in the snapshot (a lock holder on WAITFOR, a reader on LCK_M_S) wait=WAITFOR shows
#     'Only requests waiting on WAITFOR.' and the API's WAITFOR rows alone, 'Show all active queries' shows them all; the
#     Waits page's 'requests' link lands there; a heatmap cell's 'Show Active Queries at This Time' lands on Running at
#     its bin's middle; the heatmap's size on the page (the refusal's words, the cut note with the picture starting at
#     drawn_from and its cells = the API's, no note where it fits); every walk bounded (900 s, 120 s; a CDP call 30 s;
#     each wait a bounded poll that names itself 'WAITED <what>'); with its read held past the UI
#     pool's real 15 s statement timeout (mssql_pc_sample renamed for the walk, a view of the same name that sleeps 20 s
#     once in its place: a lock cannot do it, the pool's lock_timeout of 2 s cancels a lock wait first) the heatmap
#     section says 'the heatmap's read took too long for this range: pick 24 hours or less' (no error box, no grid,
#     the serve log's cause the statement timeout), and after the table is put back the heatmap reads again; every link
#     and control of the Queries page clicked once (the click table); shots.
# NOT PROVEN HERE: SQL Server 2016 (no total_spills: the column check's unit test), Managed Instance, a readable
# secondary; PerformanceMonitor's own pages beside these (its shots are read by hand); accessibility (proof-a11y, run
# beside this one).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMG_SQL=mcr.microsoft.com/mssql/server:2022-latest
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvq-sql-$SUF; LBL=pgvigil-proof=d10
PGDB=pgv_q_$SUF; PGDB2=pgv_q0126_$SUF; MON=pgv_qmon_$SUF; USR=proofdba$SUF
PG13=pgv13-$SUF; IMG_PG13=postgres:13
fail() { echo "FAIL: $*" >&2; exit 1; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; CHRPID=; BG=()
SA_PW=$(pw); MON_PW=$(pw); UPW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -f "$TMPD/0126.sql" ]] && mv "$TMPD/0126.sql" internal/repo/sql/0126_darling_queries.sql   # the pre-0126 build's move, undone
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  if [[ -n "$CHRPID" ]]; then kill -- "-$CHRPID" 2>/dev/null || kill "$CHRPID" 2>/dev/null || true; wait "$CHRPID" 2>/dev/null || true; fi
  for p in "${BG[@]}"; do kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true; done
  for c in "$SQL" "$PG13"; do docker rm -f -v "$c" >/dev/null 2>&1 || { docker inspect "$c" >/dev/null 2>&1 && echo "CLEANUP: container $c not removed" >&2; }; done
  for d in "$PGDB" "$PGDB2"; do psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $d WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $d not dropped" >&2; done
  rm -rf "$TMPD"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
# sq: T-SQL as sa (stdin; -I: QUOTED_IDENTIFIER ON); sqt: the same without -b and with a query timeout of $3 seconds
# (a run the client cancels is Query Store's Aborted; an error is its Exception); sqok: loud
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout "${3:-120}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
sqt() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout 300 docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -W -h -1 -l 60 -t "$1" -d "$0" -i /dev/stdin' "${2:-pgvq}" "${3:-0}" >/dev/null 2>&1 || true; }
sqok() { local out; out=$(sq "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
# sqtn <n> <statement> [db] [timeout s]: n runs of one statement, each in its own sqlcmd session (one docker exec);
# the hand read counts every run sent this way (s177j-8 / -9), while a session of several batches counted fewer
sqtn() { printf 'SET NOCOUNT ON;\n%s\n' "$2" | timeout 600 docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'q=$(cat); for _ in $(seq 1 "$1"); do
    printf "%s\n" "$q" | SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -W -h -1 -l 60 -t "$3" -d "$2" -i /dev/stdin >/dev/null 2>&1 || true; done' sqtn "$1" "${3:-pgvq}" "${4:-0}" >/dev/null 2>&1 || true; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
# objs <file> <part>: an API part ({columns, rows}) as a JSON array of objects
objs() { jq -c --arg p "$2" '.[$p] | .columns as $c | [(.rows // [])[] | [$c, .] | transpose | map({(.[0]): .[1]}) | add]' "$1"; }
# ld: the box's load, beside every timing (a slow run is read against it)
ld() { printf 'load %s on %s cpus' "$(cut -d' ' -f1-3 /proc/loadavg)" "$(nproc)"; }
# nonempty <file> <part>: the API part holds a row (a fast empty 200 is not a timing)
nonempty() { jq -e --arg p "$2" '(.[$p].rows // []) | length > 0' "$1" >/dev/null 2>&1; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
for t in docker go psql curl python3 node npm chromium setsid jq patch; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
# the wiring patch is applied to this job's copy and kept there (the copy goes with the job); a dry run first, so a tree
# that holds part of it already fails here with nothing applied, never half patched or stopped at a question
if [[ "${PGVIGIL_WIRING:-1}" == 1 ]] && ! grep -q "mssqlqueries: 'Queries'" web/src/router.ts; then
  patch -p1 --batch --forward --dry-run < scripts/proof-darling-queries-wiring.patch >"$TMPD/wiring-dry.out" 2>&1 \
    || { cat "$TMPD/wiring-dry.out" >&2; fail "the wiring patch does not apply whole to this copy (dry run, above; nothing applied)"; }
  patch -p1 --batch --forward < scripts/proof-darling-queries-wiring.patch >/dev/null || fail "the wiring patch"
  echo "wiring applied to this copy (router.ts, main.ts, mssql_plancache.ts, mssql_procs.ts, mssql_running.ts, mssql_waits.ts, q_mssql_running.go, docs)"
fi
dsnfor() { local d="$ADMIN_DSN"; d="${d/dbname=postgres/dbname=$1}"; [[ "$d" == *"dbname=$1"* ]] || d="$d dbname=$1"; printf '%s' "$d"; }

echo "== B. 0126 under a running import =="
# the binary without 0126 (the embed is the folder: the file leaves it for one build)
mv internal/repo/sql/0126_darling_queries.sql "$TMPD/0126.sql"
go build -o "$TMPD/pgvigil-pre" ./cmd/pgvigil || { mv "$TMPD/0126.sql" internal/repo/sql/0126_darling_queries.sql; fail "B: the build without 0126"; }
mv "$TMPD/0126.sql" internal/repo/sql/0126_darling_queries.sql
go build -o "$TMPD/pgvigil" ./cmd/pgvigil
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB2" >/dev/null
PGDSN=$(dsnfor "$PGDB2")
printf 'repository:\n  dsn: "%s"\ninstances: []\n' "$PGDSN" > "$TMPD/b.yaml"
"$TMPD/pgvigil-pre" migrate -config "$TMPD/b.yaml" >"$TMPD/b-migrate0.out" 2>&1 || { tail -5 "$TMPD/b-migrate0.out" >&2; fail "B: migrate without 0126"; }
[[ "$(pq "SELECT count(*) FROM pgvigil.schema_version WHERE version LIKE '0126%'")" == 0 ]] || fail "B: the binary without 0126 recorded it"
pq "SELECT pgvigil.ensure_month_partition('mssql_qs_runtime', now())" >/dev/null
hold() { setsid psql "$PGDSN" -XAtq -c "BEGIN; LOCK TABLE ONLY pgvigil.mssql_qs_runtime IN ROW EXCLUSIVE MODE; SELECT pg_sleep($1); COMMIT;" >/dev/null 2>&1 & BG+=($!); sleep 1; }
hold 40
t0=$(date +%s.%N)
if "$TMPD/pgvigil" migrate -config "$TMPD/b.yaml" >"$TMPD/b-migrate1.out" 2>&1; then fail "B: migrate went through a 40 s holder"; fi
t1=$(date +%s.%N); el1=$(python3 -c "print(round($t1 - $t0, 1))")
grep -qi 'lock timeout' "$TMPD/b-migrate1.out" || { tail -5 "$TMPD/b-migrate1.out" >&2; fail "B: migrate failed, not on the lock timeout"; }
python3 -c "import sys; sys.exit(0 if 19 <= $el1 <= 26 else 1)" || fail "B: the failed migrate took $el1 s (want 20-25)"
[[ "$(pq "SELECT count(*) FROM pgvigil.schema_version WHERE version LIKE '0126%'")/$(pq "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'pgvigil' AND table_name = 'mssql_qs_runtime' AND column_name = 'aborted_executions'")" == 0/0 ]] \
  || fail "B: 0126 left a trace after its lock timeout"
for p in "${BG[@]}"; do wait "$p" 2>/dev/null || true; done; BG=()
# the procedures import's own order: its parents, then mssql_proc_last (0084 / 0126's import_mssql_procstats)
( psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "BEGIN; LOCK TABLE ONLY pgvigil.mssql_proc_read, ONLY pgvigil.mssql_proc_sample IN ROW EXCLUSIVE MODE; SELECT pg_sleep(8);
    DELETE FROM pgvigil.mssql_proc_last WHERE instance_id = -1; COMMIT;" >"$TMPD/b-holder.out" 2>&1; echo "exit=$?" >>"$TMPD/b-holder.out" ) & BG+=($!)
sleep 1
t0=$(date +%s.%N)
"$TMPD/pgvigil" migrate -config "$TMPD/b.yaml" >"$TMPD/b-migrate2.out" 2>&1 || { tail -5 "$TMPD/b-migrate2.out" >&2; cat "$TMPD/b-holder.out" >&2; fail "B: migrate beside an import-shaped holder"; }
t1=$(date +%s.%N); el2=$(python3 -c "print(round($t1 - $t0, 1))")
for p in "${BG[@]}"; do wait "$p" 2>/dev/null || true; done; BG=()
grep -q 'exit=0' "$TMPD/b-holder.out" && ! grep -qi deadlock "$TMPD/b-holder.out" || { cat "$TMPD/b-holder.out" >&2; fail "B: the import-shaped holder did not commit"; }
python3 -c "import sys; sys.exit(0 if 6 <= $el2 <= 20 else 1)" || fail "B: migrate beside an 8 s import-shaped holder took $el2 s (want 6-20: it waited; the holder starts 1 s before it)"
got=$(pq "SELECT (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'pgvigil' AND ((table_name = 'mssql_qs_runtime' AND column_name ~ '^(aborted|exception)_(executions|cpu_us|duration_us)$')
                                                         OR (table_name IN ('mssql_proc_last', 'mssql_proc_sample') AND column_name = 'spills')))
              || '/' || (to_regclass('pgvigil.mssql_pc_handles') IS NOT NULL) || '/' || (to_regprocedure('pgvigil.import_mssql_querystore_0083(int, timestamptz, jsonb)') IS NOT NULL)
              || '/' || (to_regprocedure('pgvigil.import_mssql_plancache_0092(int, timestamptz, jsonb)') IS NOT NULL)
              || '/' || (SELECT count(*) FROM pgvigil.schema_version WHERE version LIKE '0126%')")
[[ "$got" == "8/true/true/true/1" ]] || fail "B: after the migrate: columns/handles/0083/0092/recorded = $got (want 8/true/true/true/1)"
echo "ok   B: behind a 40 s holder migrate failed on the lock timeout after $el1 s and left nothing; beside an import-shaped holder (parents, 8 s, then mssql_proc_last) it waited and went through in $el2 s and the holder committed (no deadlock); 8 columns, mssql_pc_handles, both renamed imports"

echo "== C. old-shape payloads into the new imports =="
IC=$(pq "SELECT pgvigil.ensure_instance('pgvq-synth', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
pr() {  # pr <server_utc> <plan rows json>: one procstats read
  pq "SELECT pgvigil.import_mssql_procstats($IC, '$1'::timestamptz, '[{\"kind\":\"state\",\"server_utc\":\"$1\",\"server_start\":\"2026-01-01T00:00:00Z\",\"server_local\":\"${1%Z}\",\"capped\":false}$2]'::jsonb)" >/dev/null; }
P1='{"kind":"proc","plan_handle":"0x01","cached_time":"2026-01-01T00:00:01","database_id":5,"object_id":11,"database_name":"d","schema_name":"dbo","object_name":"p1","type_desc":"SQL_STORED_PROCEDURE","worker_us":10,"elapsed_us":10,"logical_reads":1,"physical_reads":0,"logical_writes":0'
T0=$(date -u -d '-20 minutes' +%Y-%m-%dT%H:%M:%SZ); T1=$(date -u -d '-15 minutes' +%Y-%m-%dT%H:%M:%SZ); T2=$(date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ)
pr "$T0" ",$P1,\"execution_count\":1}"
pr "$T1" ",$P1,\"execution_count\":2,\"spills\":100}"
pr "$T2" ",$P1,\"execution_count\":3,\"spills\":130},{\"kind\":\"proc\",\"plan_handle\":\"0x02\",\"cached_time\":\"${T1%Z}\",\"database_id\":5,\"object_id\":12,\"database_name\":\"d\",\"schema_name\":\"dbo\",\"object_name\":\"p2\",\"type_desc\":\"SQL_STORED_PROCEDURE\",\"execution_count\":1,\"worker_us\":1,\"elapsed_us\":1,\"logical_reads\":0,\"physical_reads\":0,\"logical_writes\":0,\"spills\":7}"
got=$(pq "SELECT string_agg(object_id || ':' || coalesce(spills::text, 'null'), ',' ORDER BY snapshot_at, object_id) FROM pgvigil.mssql_proc_sample WHERE instance_id = $IC")
[[ "$got" == "11:null,11:30,12:7" ]] || fail "C: procstats spills per interval = $got (want 11:null at the read after the old one, 11:30, 12:7)"
[[ "$(pq "SELECT string_agg(spills::text, ',' ORDER BY object_id) FROM pgvigil.mssql_proc_last WHERE instance_id = $IC")" == "130,7" ]] || fail "C: mssql_proc_last.spills"
QBASE=$(( $(date +%s) / 60 * 60 - 1800 ))   # one interval for the three reads below
qsrow() {  # one Query Store read of one interval and one plan: $1 the read time, $2 failed, $3 the split keys (or '')
  local iv ive
  iv=$(date -u -d "@$QBASE" +%Y-%m-%dT%H:%M:%SZ); ive=$(date -u -d "@$((QBASE + 60))" +%Y-%m-%dT%H:%M:%SZ)
  pq "SELECT pgvigil.import_mssql_querystore($IC, '$1'::timestamptz, '[{\"kind\":\"store\",\"database_id\":5,\"database_name\":\"d\",\"database_state\":\"ONLINE\",\"database_read_only\":0,\"read\":1,\"actual_state\":\"READ_WRITE\"},
    {\"kind\":\"interval\",\"database_name\":\"d\",\"interval_id\":1,\"interval_start\":\"$iv\",\"interval_end\":\"$ive\",\"plans\":1,\"executions\":10},
    {\"kind\":\"runtime\",\"database_name\":\"d\",\"interval_start\":\"$iv\",\"plan_id\":1,\"executions\":10,\"failed\":$2,\"duration_us\":100,\"cpu_us\":50$3},
    {\"kind\":\"plan\",\"database_name\":\"d\",\"plan_id\":1,\"query_id\":1,\"query_hash_hex\":\"0x00000000000000AA\",\"plan_hash_n\":5},
    {\"kind\":\"forced_read\",\"kind_of\":\"plan\",\"database_name\":\"d\",\"statement\":\"kept\"}]'::jsonb)" >/dev/null
  pq "SELECT coalesce(aborted_executions::text, 'null') || '/' || coalesce(aborted_cpu_us::text, 'null') || '/' || coalesce(exception_executions::text, 'null') || '/' || coalesce(exception_duration_us::text, 'null')
        FROM pgvigil.mssql_qs_runtime WHERE instance_id = $IC AND plan_id = 1"; }
S1=$(qsrow "$(date -u -d '-9 minutes' +%Y-%m-%dT%H:%M:%SZ)" 5 '')
S2=$(qsrow "$(date -u -d '-8 minutes' +%Y-%m-%dT%H:%M:%SZ)" 5 ',"aborted_executions":3,"aborted_cpu_us":30,"aborted_duration_us":60,"exception_executions":2,"exception_cpu_us":4,"exception_duration_us":8')
S3=$(qsrow "$(date -u -d '-7 minutes' +%Y-%m-%dT%H:%M:%SZ)" 0 ',"aborted_executions":3,"aborted_cpu_us":30,"aborted_duration_us":60,"exception_executions":2,"exception_cpu_us":4,"exception_duration_us":8')
[[ "$S1|$S2|$S3" == "null/null/null/null|3/30/2/8|null/null/null/null" ]] || fail "C: the Query Store split: old shape $S1, new $S2, failed 0 $S3"
echo "ok   C: procstats spills after an old-shape read NULL (not 100), then 30, a new plan 7, last 130 / 7; the Query Store split NULL from an old payload, stored from a new one, NULL at failed 0 though the keys were sent"
psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB2 WITH (FORCE)" >/dev/null

echo "== A. the container =="
docker run -d --name "$SQL" --label "$LBL" --memory 6g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
up() { local r=; for _ in $(seq 1 150); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" master 15 2>/dev/null || true); [[ "$r" == 1 ]] && return 0; sleep 2; done
  docker logs --tail 40 "$SQL" >&2 2>&1 || true; fail "A: the SQL Server container did not come up in 300 s"; }
up
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
sqok "A: the database" "CREATE DATABASE pgvq; ALTER DATABASE pgvq SET RECOVERY SIMPLE;
  ALTER DATABASE pgvq SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, INTERVAL_LENGTH_MINUTES = 1, QUERY_CAPTURE_MODE = ALL, DATA_FLUSH_INTERVAL_SECONDS = 60, MAX_PLANS_PER_QUERY = 200);"
sqok "A: the table" "CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, v int NOT NULL, pad char(500) NOT NULL DEFAULT 'a');
  INSERT dbo.t (id, v, pad) SELECT TOP (20000) n, n % 977, REPLICATE(CHAR(65 + n % 26), 400) FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects a CROSS JOIN sys.all_objects b) x;" pgvq
sqok "A: the procedures" "EXEC (N'CREATE PROCEDURE dbo.p_spill AS SELECT TOP (20000) id, pad FROM dbo.t ORDER BY pad DESC, v OPTION (MAX_GRANT_PERCENT = 0)');
  EXEC (N'CREATE PROCEDURE dbo.p_new AS SELECT MAX(id) FROM dbo.t WHERE v = 3');
  EXEC (N'CREATE PROCEDURE dbo.p_gone AS SELECT MIN(id) FROM dbo.t WHERE v = 4');" pgvq
sqok "A: the monitor login" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON]; GRANT CONNECT ANY DATABASE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON];"
echo "ok   A: SQL Server $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))"), pgvq's Query Store $(sq "SELECT actual_state_desc + ' ' + CAST(interval_length_minutes AS varchar(5)) + ' min' FROM sys.database_query_store_options" pgvq)"

psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
# the join review d10b, b1 (ii): when the box's PostgreSQL preloads pg_stat_statements, the proof's database tracks
# planning (set before serve connects), so F reads whether serve's pool planned every run of a named part
PSS=$(psql "$ADMIN_DSN" -XAtqc "SHOW shared_preload_libraries")
if [[ ",${PSS// /}," == *",pg_stat_statements,"* ]]; then
  psql "$ADMIN_DSN" -Xqc "ALTER DATABASE $PGDB SET pg_stat_statements.track_planning = on" >/dev/null; PSS=on
else PSS=off; fi
PGDSN=$(dsnfor "$PGDB")
export PGV_Q_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
cat > "$TMPD/m.yaml" <<EOF
repository:
  dsn: "$PGDSN"
instances:
  - name: sqlbox
    engine: sqlserver
    dsn: env:PGV_Q_MON
EOF
"$TMPD/pgvigil" migrate -config "$TMPD/m.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "migrate"; }
col() { for c in "$@"; do timeout 300 "$TMPD/pgvigil" collect -config "$TMPD/m.yaml" -instance sqlbox -once "$c" >"$TMPD/col-$c.out" 2>&1 || { cat "$TMPD/col-$c.out" >&2; fail "collect $c"; }; done; }
now_utc() { sq "SELECT CONVERT(varchar(19), SYSUTCDATETIME(), 126) + 'Z'"; }
# to_bound: sleep until the server's clock is $1 seconds past the next whole minute; prints that minute (UTC)
to_bound() { local s m; s=$(sq "SELECT 60 - DATEPART(second, SYSUTCDATETIME())"); sleep $((s + $1)); m=$(sq "SELECT CONVERT(varchar(16), SYSUTCDATETIME(), 126) + ':00Z'"); printf '%s' "$m"; }
Q_COST="EXEC sp_executesql N'SELECT /*q_cost*/ COUNT_BIG(*) FROM dbo.t a CROSS JOIN (SELECT TOP (@n) v FROM dbo.t) b WHERE a.v + b.v = -1', N'@n int', @n ="
# q_to under LOOP JOIN: compiled at TOP 1 in W1, run at 20,000 in W2, a loop over 400 M pairs outlasts the client's 1 s
Q_TO="EXEC sp_executesql N'SELECT /*q_to*/ COUNT_BIG(*) FROM dbo.t a CROSS JOIN (SELECT TOP (@n) v FROM dbo.t) b WHERE a.v * 2 + b.v = -1 OPTION (LOOP JOIN)', N'@n int', @n ="
# each scenario statement has a shape of its own: a query hash leaves literals out, so two statements that differ in
# a literal only would be one key. q_tonew is new in W2 and no plan of it ends inside 1 s: the three sides join on
# the unique key (no grouping shrinks a side; s177j-8 / -9's TOP (@n) over b.v ended Regular), so any plan forms at
# least the 400 M pairs of two sides, on one thread
Q_TONEW="EXEC sp_executesql N'SELECT /*q_tonew*/ COUNT_BIG(*) FROM dbo.t a CROSS JOIN dbo.t b CROSS JOIN dbo.t c WHERE a.id + b.id + c.id = -1 OPTION (MAXDOP 1)';"
Q_ERR="EXEC sp_executesql N'SELECT /*q_err*/ COUNT_BIG(*) / @d FROM dbo.t WHERE v >= 0', N'@d int', @d ="
Q_CHEAP="EXEC sp_executesql N'SELECT /*q_cheap*/ COUNT_BIG(*) FROM dbo.t a CROSS JOIN (SELECT TOP (@n) v FROM dbo.t) b WHERE a.v - b.v = -1', N'@n int', @n ="
Q_GONE="EXEC sp_executesql N'SELECT /*q_gone*/ COUNT_BIG(*) FROM dbo.t WHERE v = @v', N'@v int', @v = 5;"
Q_NEW="EXEC sp_executesql N'SELECT /*q_new*/ MAX(v) FROM dbo.t WHERE id > @i', N'@i int', @i = 7;"
Q_NK="EXEC sp_executesql N'SELECT /*q_nk*/ MIN(v) FROM dbo.t WHERE id < @i', N'@i int', @i = 19000;"
# plus <minute UTC> <seconds>: that time; until_s <minute UTC> <seconds>: sleep until the server's clock is past it
plus() { date -u -d "@$(( $(date -u -d "$1" +%s) + $2 ))" +%Y-%m-%dT%H:%M:%SZ; }
until_s() { local ms; ms=$(sq "SELECT DATEDIFF(millisecond, SYSUTCDATETIME(), DATEADD(second, $2, CONVERT(datetime2, '${1%Z}')))"); (( ms > 0 )) && sleep "$(python3 -c "print($ms / 1000)")"; return 0; }

echo "== D. the Query Store, W0 / W1 / W2 =="
col mssql_instance mssql_procstats mssql_plancache   # R0: the counters' start
SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox'")
R0=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_pc_state WHERE instance_id = $SB")
sleep 25
M0=$(to_bound 2); sqt "$Q_NK" pgvq                                     # W0: q_nk compiled, before the earlier window
M1=$(plus "$M0" 60); until_s "$M1" 2; echo "  W1 from $M1"
sqtn 5 "$Q_COST 1;"; sqtn 5 "$Q_TO 1;"; sqtn 5 "$Q_ERR 1;"; sqtn 5 "$Q_GONE"; sqtn 10 "$Q_CHEAP 1;"; sqtn 3 'EXEC dbo.p_spill;'; sqtn 3 'EXEC dbo.p_gone;'
echo "  W1's runs sent by +$(sq "SELECT DATEDIFF(millisecond, CONVERT(datetime2, '${M1%Z}'), SYSUTCDATETIME()) / 1000.0") s"
until_s "$M1" 110                                                      # R1 at W1's end: R2 - R1 stays under R1 - R0
col mssql_procstats mssql_plancache                                     # R1
R1=$(pq "SELECT snapshot_at FROM pgvigil.mssql_pc_state WHERE instance_id = $SB")
SPILL1=$(sq "SELECT ISNULL(SUM(total_spills), 0) FROM sys.dm_exec_procedure_stats WHERE database_id = DB_ID('pgvq') AND object_id = OBJECT_ID('pgvq.dbo.p_spill')")
[[ $(sq "SELECT CASE WHEN SYSUTCDATETIME() < DATEADD(second, 119, CONVERT(datetime2, '${M1%Z}')) THEN 1 ELSE 0 END") == 1 ]] || fail "D: W1's runs and R1 overran W1"
M2=$(plus "$M1" 120); until_s "$M2" 2; echo "  W2 from $M2"
sqtn 5 "$Q_COST 1500;"; sqtn 5 "$Q_NEW"; sqtn 5 "$Q_NK"; sqtn 10 "$Q_CHEAP 20;"; sqtn 3 'EXEC dbo.p_spill;'; sqtn 3 'EXEC dbo.p_new;'
# the client gives up after 1 s: Aborted (s177j-7: of eight timing-out batches in one session, three ran)
sqtn 4 "$Q_TO 20000;" pgvq 1; sqtn 4 "$Q_TONEW" pgvq 1
sqtn 4 "$Q_ERR 0;"                                                      # divide by zero: Exception
echo "  W2's first minute sent by +$(sq "SELECT DATEDIFF(millisecond, CONVERT(datetime2, '${M2%Z}'), SYSUTCDATETIME()) / 1000.0") s"
[[ $(sq "SELECT CASE WHEN SYSUTCDATETIME() < DATEADD(second, 58, CONVERT(datetime2, '${M2%Z}')) THEN 1 ELSE 0 END") == 1 ]] || fail "D: W2's first minute overran"
M3=$(plus "$M2" 60); until_s "$M3" 2
sqt "SET NOCOUNT ON; DECLARE @i int = 0, @s nvarchar(10); WHILE @i < 400 BEGIN SET @s = CAST(@i AS nvarchar(10));
  EXEC (N'SELECT /*burst*/ COUNT_BIG(*) FROM dbo.t a WHERE a.v = ' + @s + N' AND EXISTS (SELECT 1 FROM dbo.t b WHERE b.id = a.id + ' + @s + N') OPTION (RECOMPILE)'); SET @i += 1; END" pgvq
# RECOMPILE: Query Store keeps each compile, the plan cache none (the cache stays under the collector's lists)
M4=$(plus "$M2" 120); until_s "$M4" 3; echo "  W2 to $M4"
col mssql_procstats mssql_plancache mssql_querystore                   # R2 and the store's read
R2=$(pq "SELECT snapshot_at FROM pgvigil.mssql_pc_state WHERE instance_id = $SB")
SPILL2=$(sq "SELECT ISNULL(SUM(total_spills), 0) FROM sys.dm_exec_procedure_stats WHERE database_id = DB_ID('pgvq') AND object_id = OBJECT_ID('pgvq.dbo.p_spill')")
python3 -c "
import datetime as d, sys
p = lambda s: d.datetime.fromisoformat(s.replace('Z', '+00:00').replace(' ', 'T'))
r0, r1, r2 = p('$R0'), p('$R1'), p('$R2')
sys.exit(0 if (r1 - r0) > (r2 - r1) else 1)" || fail "D: the reads' timeline (R1 - R0 must be longer than R2 - R1 for the plan cache's previous period): $R0 $R1 $R2"

# hand reads of the store, then the API
sq "SELECT p.plan_id, q.query_id, CONVERT(varchar(20), q.query_hash, 1), DATEDIFF_BIG(second, '1970-01-01', CONVERT(datetime2, SWITCHOFFSET(i.start_time, '+00:00'))),
     SUM(rs.count_executions), SUM(CASE WHEN rs.execution_type = 3 THEN rs.count_executions ELSE 0 END),
     CAST(SUM(CASE WHEN rs.execution_type = 3 THEN rs.avg_cpu_time * rs.count_executions ELSE 0 END) AS bigint),
     CAST(SUM(CASE WHEN rs.execution_type = 3 THEN rs.avg_duration * rs.count_executions ELSE 0 END) AS bigint),
     SUM(CASE WHEN rs.execution_type = 4 THEN rs.count_executions ELSE 0 END),
     CAST(SUM(CASE WHEN rs.execution_type = 4 THEN rs.avg_cpu_time * rs.count_executions ELSE 0 END) AS bigint),
     CAST(SUM(CASE WHEN rs.execution_type = 4 THEN rs.avg_duration * rs.count_executions ELSE 0 END) AS bigint),
     CAST(SUM(rs.avg_duration * rs.count_executions) AS bigint), CAST(SUM(rs.avg_cpu_time * rs.count_executions) AS bigint),
     ISNULL(LEFT(t.query_sql_text, 40), '')
   FROM sys.query_store_runtime_stats rs JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
   JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id JOIN sys.query_store_query q ON q.query_id = p.query_id JOIN sys.query_store_query_text t ON t.query_text_id = q.query_text_id
  WHERE i.end_time > DATEADD(minute, -1, CONVERT(datetimeoffset, '${M1%Z}'))
  GROUP BY p.plan_id, q.query_id, q.query_hash, i.start_time, t.query_sql_text" pgvq > "$TMPD/hand-qs.txt" || fail "D: the hand read of the store"
WORK="$TMPD"
PGVIGIL_PASSWORD="$UPW" "$TMPD/pgvigil" user add -config "$TMPD/m.yaml" "$USR" >/dev/null 2>&1 || fail "user add"
(cd web && npm ci --no-audit --no-fund >"$TMPD/web.log" 2>&1 && npm run build >>"$TMPD/web.log" 2>&1) || { tail -20 "$TMPD/web.log" >&2; fail "the web build"; }
go build -o "$TMPD/pgvigil" ./cmd/pgvigil
WPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$WPORT"
"$TMPD/pgvigil" serve -config "$TMPD/m.yaml" -listen "127.0.0.1:$WPORT" >"$TMPD/serve.out" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.out" >&2; fail "serve exited"; }
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$TMPD/login.json"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "the API login"
api() { curl -fs -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/$1" > "$TMPD/$2" || fail "GET /api/$1"; }
QW="instance=$SB&from=$M2&to=$M4&db=pgvq"
api "mssql/querystore?$QW&base=prev&part=regressed" reg.json
api "mssql/querystore?$QW&base=prev&part=regressed_skipped" regskip0.json
api "mssql/querystore?$QW&compare=prev&part=compare" cmp.json
api "mssql/querystore?$QW&compare=prev&part=compare_windows" cmpw.json
R1P=$(python3 -c "import datetime as d; print((d.datetime.fromisoformat('$R1'.replace(' ', 'T')) + d.timedelta(seconds=1)).astimezone(d.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
R2P=$(python3 -c "import datetime as d; print((d.datetime.fromisoformat('$R2'.replace(' ', 'T')) + d.timedelta(seconds=1)).astimezone(d.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
PW="instance=$SB&from=$R1P&to=$R2P"
api "mssql/procs?$PW&compare=prev&part=compare" pcmp.json
api "mssql/procs?$PW&part=procs" procs.json
api "mssql/plancache?$PW&compare=prev&part=compare" ccmp.json
api "mssql/plancache?$PW&compare=prev&part=compare_windows" ccmpw.json
api "mssql/plancache?$PW&part=top" ctop.json
TNQ=$(sq "SELECT COUNT(*) FROM sys.query_store_query_text WHERE query_sql_text LIKE N'%/*q[_]tonew*/%' AND query_sql_text NOT LIKE N'%query[_]store[_]query[_]text%'" pgvq) || TNQ='?'
python3 - "$TMPD" "$PGDSN" "$SB" "$M1" "$M2" "$M4" "$SPILL1" "$SPILL2" "$TNQ" <<'PYEND' || fail "D/E: see above"
import sys, json, subprocess, datetime as dt
d, dsn, sb, m1, m2, m4, s1, s2, tnq = sys.argv[1:]
def q(s): return [l.split('|') for l in subprocess.run(['psql', dsn, '-XAtq', '-c', s], check=True, capture_output=True, text=True).stdout.splitlines() if l]
def rows(f, part):
    # a part is {columns, rows: [[...]]}: one dict per row
    x = json.load(open(f"{d}/{f}")).get(part) or {}
    return [dict(zip(x.get('columns', []), r)) for r in x.get('rows') or []]
ep = lambda s: int(dt.datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp())
K = lambda h: '0x' + (h or '')[2:].upper()   # a hash as the collector stores it: 0x and upper-case hex
E1, E2, E4 = ep(m1), ep(m2), ep(m4)
bad = []
# the hand read: plan, query, hash, interval start (epoch), executions, aborted (n, cpu, dur), exception (n, cpu, dur), dur, cpu, text
hand = []
for l in open(f"{d}/hand-qs.txt"):
    f = l.rstrip('\n').split('|')
    if len(f) < 14: continue
    hand.append(dict(plan=int(f[0]), query=int(f[1]), hash=K(f[2]), at=int(f[3]), e=int(f[4]), an=int(f[5]), ac=int(f[6]), ad=int(f[7]),
                     xn=int(f[8]), xc=int(f[9]), xd=int(f[10]), dur=int(f[11]), cpu=int(f[12]), text=f[13]))
tag = lambda h, t: next((k for k in ['q_cost', 'q_tonew', 'q_to', 'q_err', 'q_cheap', 'q_gone', 'q_new', 'q_nk'] if f'/*{k}*/' in h['text']), None)
hashof = {}
for h in hand:
    k = tag(h, h['text'])
    if k: hashof[k] = h['hash']
for k in ['q_cost', 'q_to', 'q_tonew', 'q_err', 'q_cheap', 'q_gone', 'q_new', 'q_nk']:
    if k not in hashof: bad.append(f"D the store holds no runtime row of {k}" + (f" ({tnq} query text(s) of it kept: if 1 or more, the FINDING that Query Store keeps no runtime row of an aborted first run; the fallback is a compile in W0)" if k == 'q_tonew' else ''))
# q_tonew: 4 Aborted in W2 and no row before it, in the hand read and in pgvigil's store
tn = [h for h in hand if tag(h, h['text']) == 'q_tonew']
if tn:
    early = sorted({h['at'] for h in tn if h['at'] < E2})
    an = sum(h['an'] for h in tn if E2 <= h['at'] < E4)
    pre = q(f"SELECT count(*) FROM pgvigil.mssql_qs_runtime WHERE instance_id = {sb} AND upper(query_hash) = upper('{hashof['q_tonew']}') AND snapshot_at < '{m2}'")[0][0]
    if an != 4 or early or pre != '0': bad.append(f"D q_tonew: {an} Aborted in W2 (want 4); hand-read intervals before W2 {early}, stored rows before W2 {pre} (want none)")
    else: print(f"D q_tonew: 4 Aborted in W2, no row before W2 (hand read and store)")
# 1. the stored split = the hand read, per (plan, interval) with failures
st = {(int(r[0]), int(r[1])): r for r in q(f"""SELECT plan_id, extract(epoch FROM snapshot_at)::bigint, failed, aborted_executions, aborted_cpu_us, aborted_duration_us,
       exception_executions, exception_cpu_us, exception_duration_us FROM pgvigil.mssql_qs_runtime WHERE instance_id = {sb} AND database_name = 'pgvq'""")}
nsplit = 0
for h in hand:
    r = st.get((h['plan'], h['at']))
    if r is None or (h['an'] + h['xn']) == 0: continue
    nsplit += 1
    want = [h['an'] + h['xn'], h['an'], h['ac'], h['ad'], h['xn'], h['xc'], h['xd']]
    got = [int(x) if x != '' else None for x in r[2:]]
    if got[0] != want[0] or got[1] != want[1] or got[4] != want[4] or any(g is None or abs(g - w) > max(2, w * 1e-6) for g, w in zip(got[1:], want[1:])):
        bad.append(f"D split of plan {h['plan']} at {h['at']}: stored {got}, hand {want}")
nofail = q(f"SELECT count(*) FROM pgvigil.mssql_qs_runtime WHERE instance_id = {sb} AND coalesce(failed, 0) = 0 AND (aborted_executions IS NOT NULL OR exception_executions IS NOT NULL)")[0][0]
fails = sorted(f"{tag(h, h['text'])}:a{h['an']}/x{h['xn']}" for h in hand if h['an'] + h['xn'] > 0)
print(f"D failures in the hand read: {fails}")
# the runs sent, one sqlcmd session each (q_nk's W0 run is before W1)
SENT = {'W1': {'q_cost': 5, 'q_to': 5, 'q_err': 5, 'q_gone': 5, 'q_cheap': 10},
        'W2': {'q_cost': 5, 'q_new': 5, 'q_nk': 5, 'q_cheap': 10, 'q_to': 4, 'q_tonew': 4, 'q_err': 4}}
for lo, hi, nm in [(E1, E2, 'W1'), (E2, E4, 'W2')]:
    w = {}
    for h in hand:
        k = tag(h, h['text'])
        if k and lo <= h['at'] < hi: w[k] = w.get(k, 0) + h['e']
    print(f"D executions in {nm} by statement (hand read): {dict(sorted(w.items()))}")
    for k in sorted(set(SENT[nm]) | set(w)):
        if w.get(k, 0) != SENT[nm].get(k, 0): bad.append(f"D {nm} {k}: {w.get(k, 0)} run(s) in the hand read, {SENT[nm].get(k, 0)} sent (one session each)")
if nsplit < 3: bad.append(f"D only {nsplit} stored (plan, interval) rows with failures")
if nofail != '0': bad.append(f"D {nofail} rows without failures carry split values (want NULL)")
# 2. Regressed
reg = {K(r['query_hash']): r for r in rows('reg.json', 'regressed') if r.get('query_hash')}
def raised(k): return (reg.get(hashof.get(k, '?'), {}) or {}).get('raised_by') or ''
if 'cost' not in raised('q_cost'): bad.append(f"D Regressed q_cost raised_by '{raised('q_cost')}' (want cost)")
if 'timeouts' not in raised('q_to'): bad.append(f"D Regressed q_to raised_by '{raised('q_to')}' (want timeouts)")
r_tn = reg.get(hashof.get('q_tonew', '?'))
if not r_tn or 'timeouts' not in (r_tn.get('raised_by') or '') or r_tn.get('has_baseline') not in (False, 'false', 'f'): bad.append(f"D Regressed q_tonew {r_tn and {k: r_tn[k] for k in ('raised_by', 'has_baseline')}} (want timeouts, no kept baseline)")
num = lambda v: None if v is None or v == '' else float(v)   # a numeric may arrive as a JSON number or as text
r_er = reg.get(hashof.get('q_err', '?'))
if not r_er or 'errors' not in (r_er.get('raised_by') or '') or num(r_er.get('recent_aborted_execs')) != 0 or (num(r_er.get('recent_exception_execs')) or 0) < 3:
    bad.append(f"D Regressed q_err {r_er and {k: r_er.get(k) for k in ('raised_by', 'recent_aborted_execs', 'recent_exception_execs')}} (want errors, Aborted 0, Exception >= 3)")
r_ch = reg.get(hashof.get('q_cheap', '?'))
if not r_ch: bad.append("D Regressed lists no q_cheap (it should be there by pgvigil's duration test)")
else:
    added = (num(r_ch.get('recent_cpu_ms')) or 0) - (num(r_ch.get('base_cpu_ms')) or 0)
    added *= num(r_ch.get('recent_execs')) or 0
    if 'cost' in (r_ch.get('raised_by') or '') or (num(r_ch.get('cpu_regression_percent')) or 0) <= 25 or added >= 1000:
        bad.append(f"D q_cheap: raised_by '{r_ch.get('raised_by')}', CPU +% {r_ch.get('cpu_regression_percent')}, added {added:.1f} ms (want CPU over +25 %, under 1,000 ms added, no 'cost')")
    else: print(f"D q_cheap: CPU +{r_ch.get('cpu_regression_percent')} %, {added:.1f} ms added: not cost")
print(f"D Regressed: " + '; '.join(f"{k} [{raised(k)}]" for k in ['q_cost', 'q_to', 'q_tonew', 'q_err', 'q_cheap']))
# 3. the compare (W2 against W1) and the hand read of the same intervals (every plan of the scenario keys)
cmp = {K(r['query_hash']): r for r in rows('cmp.json', 'compare')}
w = rows('cmpw.json', 'compare_windows')[0]
st_of = lambda k: (cmp.get(hashof.get(k, '?')) or {}).get('status')
want = {'q_new': 'new', 'q_nk': 'not kept before', 'q_gone': 'not kept now', 'q_cost': ''}
for k, s in want.items():
    if st_of(k) != s: bad.append(f"D compare {k}: '{st_of(k)}' (want '{s}')")
c = cmp.get(hashof.get('q_cost', '?')) or {}
if not c.get('avg_duration_pct') or float(c['avg_duration_pct']) <= 25: bad.append(f"D compare q_cost avg duration +% {c.get('avg_duration_pct')} (want over 25)")
falsenew = [r for r in cmp.values() if r['status'] == 'new' and (not r.get('first_compile') or ep(r['first_compile'].replace(' ', 'T')) < E2)]
if falsenew: bad.append(f"D {len(falsenew)} false NEW(s): {[(r['query_hash'], r['first_compile']) for r in falsenew]}")
for k in ['q_cost', 'q_to', 'q_err', 'q_cheap', 'q_new', 'q_nk', 'q_gone']:
    hh = hashof.get(k); r = cmp.get(hh)
    if not r: continue
    for side, lo, hi, ek, dk, ck in [('now', E2, E4, 'executions', 'avg_duration_ms', 'avg_cpu_ms'), ('before', E1, E2, 'before_executions', 'before_avg_duration_ms', 'before_avg_cpu_ms')]:
        hs = [h for h in hand if h['hash'] == hh and lo <= h['at'] < hi]
        e = sum(h['e'] for h in hs)
        if int(float(r[ek])) != e: bad.append(f"D compare {k} {side} executions {r[ek]}, hand {e}")
        if e:
            for key, tot in [(dk, sum(h['dur'] for h in hs)), (ck, sum(h['cpu'] for h in hs))]:
                if r[key] is None or abs(float(r[key]) - tot / 1000.0 / e) > 0.002: bad.append(f"D compare {k} {side} {key} {r[key]}, hand {tot / 1000.0 / e:.3f}")
print(f"D compare: {len(cmp)} rows; " + ', '.join(f"{k} '{st_of(k)}'" for k in want) + f"; coverage {w['coverage']}, intervals now {w['now_intervals']} / before {w['before_intervals']}")
# 4. the 400-query interval: the kept plans and the interval's own count
cut = q(f"""SELECT i.plans, (SELECT count(*) FROM pgvigil.mssql_qs_runtime r WHERE r.instance_id = i.instance_id AND r.database_name = i.database_name AND r.snapshot_at = i.snapshot_at)
              FROM pgvigil.mssql_qs_interval i WHERE i.instance_id = {sb} AND i.database_name = 'pgvq' ORDER BY i.plans DESC NULLS LAST LIMIT 1""")[0]
if int(cut[0]) < 400 or not 1 <= int(cut[1]) <= 250 or int(cut[1]) >= int(cut[0]): bad.append(f"D the busiest interval: {cut[0]} plans ran, {cut[1]} kept (want >= 400 ran, 1-250 kept)")
print(f"D the busiest interval: {cut[0]} plans ran, {cut[1]} kept")
# E. procedures: spills = the hand delta; the compare
pr = {r['object_name']: r for r in rows('procs.json', 'procs')}
sp = pr.get('p_spill', {}).get('spills')
if int(s2) - int(s1) <= 0: bad.append(f"E p_spill did not spill (total_spills {s1} -> {s2})")
elif sp is None or int(sp) != int(s2) - int(s1): bad.append(f"E p_spill spills {sp}, hand delta {int(s2) - int(s1)}")
pc = {r['object_name']: r['status'] for r in rows('pcmp.json', 'compare')}
if pc.get('p_new') != 'new' or pc.get('p_gone') != 'gone' or pc.get('p_spill') != '': bad.append(f"E procedures compare {pc}")
print(f"E procedures: p_spill spills {sp} (hand {int(s2) - int(s1)}); compare {pc}")
# E. the plan cache compare and the handles
cw = rows('ccmpw.json', 'compare_windows')[0]
ncut = sum(int(float(cw.get(k) or 0)) for k in ('now_cut_reads', 'before_cut_reads', 'edge_cut_reads'))
if ncut: bad.append(f"E the live plan cache reads were cut ({ncut}): its NEW / GONE check cannot run")
cc = {K(r['query_key']): r['status'] for r in rows('ccmp.json', 'compare')}
if cc.get(hashof.get('q_new', '?')) != 'new' or cc.get(hashof.get('q_gone', '?')) != 'gone': bad.append(f"E plan cache compare q_new '{cc.get(hashof.get('q_new', '?'))}', q_gone '{cc.get(hashof.get('q_gone', '?'))}' (want new, gone)")
ct = {K(r['query_key']): r for r in rows('ctop.json', 'top')}
t = ct.get(hashof.get('q_cost', '?'), {})
if not t.get('plan_hash') or not t.get('sql_handle') or not t.get('plan_handle'): bad.append(f"E the plan cache grid's handles for q_cost: {t.get('plan_hash')}, {t.get('sql_handle')}, {t.get('plan_handle')}")
print(f"E plan cache: compare q_new '{cc.get(hashof.get('q_new', '?'))}', q_gone '{cc.get(hashof.get('q_gone', '?'))}'; q_cost plan hash {t.get('plan_hash')}")
json.dump(hashof, open(f"{d}/hashof.json", 'w'))
for b in bad: print('DIFF', b)
sys.exit(1 if bad else 0)
PYEND
echo "ok   D: the split = the hand read; Regressed raises q_cost (cost), q_to and q_tonew (timeouts, q_tonew without a kept baseline), q_err (errors, Aborted 0), not q_cheap by cost; the compare's labels and figures = the hand read; no false NEW; the 400-query interval cut to 250 or fewer"

# E. the handles = the DMV's; the plan cache's labels under a cut read
sq "SELECT CONVERT(varchar(200), qs.plan_handle, 1), qs.statement_start_offset, qs.statement_end_offset, CONVERT(varchar(200), qs.sql_handle, 1), CONVERT(varchar(20), qs.query_plan_hash, 1)
      FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t WHERE t.text LIKE N'%/*q[_]cost*/%' AND t.text NOT LIKE N'%dm_exec_query_stats%'" > "$TMPD/hand-pc.txt"
[[ -s "$TMPD/hand-pc.txt" ]] || fail "E: no cached statement of q_cost"
while IFS='|' read -r ph ss se sh qh; do
  got=$(pq "SELECT upper(sql_handle) || '|' || upper(plan_hash) FROM pgvigil.mssql_pc_handles WHERE instance_id = $SB AND upper(plan_handle) = upper('$ph') AND stmt_start = $ss AND stmt_end = $se")
  [[ "$got" == "${sh^^}|${qh^^}" ]] || fail "E: mssql_pc_handles for $ph:$ss holds '$got', the DMV '${sh^^}|${qh^^}'"
done < "$TMPD/hand-pc.txt"
pq "UPDATE pgvigil.mssql_pc_read SET capped = true WHERE instance_id = $SB AND snapshot_at = '$R1'" >/dev/null
api "mssql/plancache?$PW&compare=prev&part=compare" ccmp2.json
api "mssql/plancache?$PW&compare=prev&part=compare_windows" ccmpw2.json
QN=$(jq -r '.q_new' "$TMPD/hashof.json")
L2=$(objs "$TMPD/ccmp2.json" compare | jq -r --arg k "$QN" '.[] | select((.query_key | ascii_upcase) == ($k | ascii_upcase)) | .status')
CUT=$(objs "$TMPD/ccmpw2.json" compare_windows | jq -r '.[0].before_cut_reads')
[[ "$L2/$CUT" == "not kept before/1" ]] || fail "E: with R1 cut, q_new reads '$L2' with $CUT cut read(s) before (want 'not kept before' and 1)"
pq "UPDATE pgvigil.mssql_pc_read SET capped = false WHERE instance_id = $SB AND snapshot_at = '$R1'" >/dev/null
echo "ok   E: mssql_pc_handles = the DMV's sql_handle and query_plan_hash for every cached statement of q_cost; with R1 cut q_new reads 'not kept before' and the windows part 1 cut read"
# E. a restart read (the join review d10a, finding 2): the end state - after it the handles are exactly the read's
# statements (each carries a handle on 2022), none older. 0092's per-read delete alone gives that end state too, so the
# import's restart detection is read apart (the join review d10b, b6): mssql_pc_state.server_start must change
SS0=$(pq "SELECT coalesce(server_start::text, 'null') FROM pgvigil.mssql_pc_state WHERE instance_id = $SB")
OLDMAX=$(pq "SELECT max(creation_time) FROM pgvigil.mssql_pc_handles WHERE instance_id = $SB")
RB=$(pq "SELECT count(*) FROM pgvigil.mssql_pc_handles WHERE instance_id = $SB")
timeout 120 docker restart "$SQL" >/dev/null || { docker logs --tail 40 "$SQL" >&2 2>&1 || true; fail "E: docker restart of the SQL Server container (120 s)"; }
# a restarted container publishes 1433 on a new host port (-p 127.0.0.1::1433): the monitor DSN follows it
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
export PGV_Q_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
# waitdb <db>: until the database takes a login, 180 s at most (each try 10 s at most), the container's log on a failure
waitdb() { local end=$((SECONDS + 180)); until sq "SELECT 1" "$1" 10 >/dev/null 2>&1; do
    (( SECONDS < end )) || { docker logs --tail 40 "$SQL" >&2 2>&1 || true; fail "E: $1 not back 180 s after the restart"; }; sleep 1; done; }
waitdb master
# master answers before pgvq has run its recovery: wait for pgvq itself to take a login
waitdb pgvq
sqok "E: q_cost after the restart" "$Q_COST 1;" pgvq
col mssql_plancache
SS1=$(pq "SELECT coalesce(server_start::text, 'null') FROM pgvigil.mssql_pc_state WHERE instance_id = $SB")
[[ "$SS0" != null && "$SS1" != null && "$SS1" != "$SS0" ]] || fail "E: mssql_pc_state.server_start $SS0 before the restart, $SS1 after (want a change: the import saw no restart)"
read -r NL NH NORPH NOLD NMATCH <<<"$(pq "SELECT (SELECT count(*) FROM pgvigil.mssql_pc_last WHERE instance_id = $SB),
    (SELECT count(*) FROM pgvigil.mssql_pc_handles WHERE instance_id = $SB),
    (SELECT count(*) FROM pgvigil.mssql_pc_handles h WHERE h.instance_id = $SB AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_pc_last l
        WHERE l.instance_id = h.instance_id AND l.plan_handle = h.plan_handle AND l.stmt_start = h.stmt_start AND l.stmt_end = h.stmt_end AND l.creation_time = h.creation_time)),
    (SELECT count(*) FROM pgvigil.mssql_pc_handles WHERE instance_id = $SB AND creation_time <= '$OLDMAX'),
    (SELECT count(*) FROM pgvigil.mssql_pc_last l WHERE l.instance_id = $SB AND EXISTS (SELECT 1 FROM pgvigil.mssql_pc_handles h
        WHERE h.instance_id = l.instance_id AND h.plan_handle = l.plan_handle AND h.stmt_start = l.stmt_start AND h.stmt_end = l.stmt_end AND h.creation_time = l.creation_time))" | tr '|' ' ')"
[[ "$RB" -gt 0 && "$NL" -gt 0 && "$NH" == "$NL" && "$NMATCH" == "$NL" && "$NORPH" == 0 && "$NOLD" == 0 ]] \
  || fail "E: after the restart read mssql_pc_last holds $NL statements, mssql_pc_handles $NH ($NMATCH matched, $NORPH orphaned, $NOLD from before the restart; $RB before it)"
echo "ok   E: the import saw the restart (server_start $SS0 -> $SS1); after its read mssql_pc_handles holds exactly the read's $NL statements ($RB before the restart, none of them left, none orphaned)"

# D. q_err's baseline rows in the pre-0126 shape: the failure test is not applied, the cells say so
QE=$(jq -r '.q_err' "$TMPD/hashof.json")
SK0=$(objs "$TMPD/regskip0.json" regressed_skipped | jq -r '.[0].queries')
[[ "$SK0" == 0 ]] || fail "D: regressed_skipped before the pre-0126 rows: $SK0 (want 0)"
pq "CREATE TABLE pgvigil.proof_keep AS SELECT * FROM pgvigil.mssql_qs_runtime WHERE instance_id = $SB AND upper(query_hash) = upper('$QE') AND snapshot_at < '$M2'" >/dev/null
NU=$(pq "WITH u AS (UPDATE pgvigil.mssql_qs_runtime SET failed = 2, aborted_executions = NULL, aborted_cpu_us = NULL, aborted_duration_us = NULL, exception_executions = NULL, exception_cpu_us = NULL, exception_duration_us = NULL
     WHERE instance_id = $SB AND upper(query_hash) = upper('$QE') AND snapshot_at < '$M2' RETURNING 1) SELECT count(*) FROM u")
[[ "$NU" -ge 1 ]] || fail "D: no stored row of q_err before W2 to put in the pre-0126 shape"
api "mssql/querystore?$QW&base=prev&part=regressed" reg2.json
api "mssql/querystore?$QW&base=prev&part=regressed_skipped" regskip.json
RB=$(objs "$TMPD/reg2.json" regressed | jq -r --arg k "$QE" '[.[] | select((.query_hash | ascii_upcase) == ($k | ascii_upcase)) | (.raised_by + "|" + (.base_unsplit | tostring))] | join(",")')
SK=$(objs "$TMPD/regskip.json" regressed_skipped | jq -r '.[0].queries')
[[ "$RB" != *errors* && "$SK" -ge 1 ]] || fail "D: q_err with pre-0126 baseline rows: '$RB', skipped $SK (want no 'errors', skipped >= 1)"
pq "DELETE FROM pgvigil.mssql_qs_runtime WHERE instance_id = $SB AND upper(query_hash) = upper('$QE') AND snapshot_at < '$M2'; INSERT INTO pgvigil.mssql_qs_runtime SELECT * FROM pgvigil.proof_keep; DROP TABLE pgvigil.proof_keep" >/dev/null
echo "ok   D: q_err's $NU baseline row(s) in the pre-0126 shape: not raised by errors ('${RB:-not listed}'), regressed_skipped 0 before, $SK after"
# Regressed's default (PerformanceMonitor's 7 days before): q_cost is still raised by cost
api "mssql/querystore?$QW&part=regressed" reg7.json
QC=$(jq -r '.q_cost' "$TMPD/hashof.json")
R7=$(objs "$TMPD/reg7.json" regressed | jq -r --arg k "$QC" '[.[] | select((.query_hash | ascii_upcase) == ($k | ascii_upcase)) | .raised_by] | join(",")')
[[ "$R7" == *cost* ]] || fail "D: Regressed's default baseline: q_cost raised by '$R7' (want cost)"
QTN=$(jq -r '.q_tonew' "$TMPD/hashof.json")
TN7=$(objs "$TMPD/reg7.json" regressed | jq -r --arg k "$QTN" '[.[] | select((.query_hash | ascii_upcase) == ($k | ascii_upcase)) | (.raised_by + "|" + (.has_baseline | tostring))] | join(",")')
[[ "$TN7" == "timeouts|false" ]] || fail "D: Regressed's default baseline: q_tonew '$TN7' (want 'timeouts|false': raised by timeouts alone, no kept baseline)"
echo "ok   D: Regressed's default baseline (7 days before) raises q_cost by '$R7' and q_tonew by timeouts with no kept baseline"
# stored rows (the 0126 shape, synthetic): tn_new 4 Aborted runs in a 1-hour window and none before; tn_same (the
# control) 4 in the window and 4 in the hour before, the same rate; the database's first interval at that hour's start
TN=$(pq "SELECT pgvigil.ensure_instance('pgvq-tn', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
TW=$(( $(date +%s) / 60 * 60 - 7200 )); BW=$(( TW - 3600 ))
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
for at in "$BW" "$TW"; do pq "SELECT pgvigil.ensure_month_partition('mssql_qs_runtime', '$(iso "$at")'), pgvigil.ensure_month_partition('mssql_qs_interval', '$(iso "$at")')" >/dev/null; done
pq "INSERT INTO pgvigil.mssql_qs_interval (instance_id, snapshot_at, database_name, interval_id, interval_end, plans, executions, duration_us, cpu_us, logical_reads, wait_ms, read_at)
    VALUES ($TN, '$(iso "$BW")', 'synth', 1, '$(iso $((BW + 60)))', 1, 4, 4000000, 4000000, 40, 0, '$(iso $((BW + 120)))'),
           ($TN, '$(iso $((TW + 600)))', 'synth', 2, '$(iso $((TW + 660)))', 2, 8, 8000000, 8000000, 80, 0, '$(iso $((TW + 720)))')" >/dev/null
tnrow() {  # tnrow <interval start epoch> <plan = query> <hash>: 4 Aborted runs of 1 s
  printf "(%s, '%s', '%s', 'synth', %s, %s, '%s', %s, 4, 4, 4000000, 4000000, 40, 0, 0, 0, 1000000, 0, 0, 1, '%s', '%s', 0, 4, 4000000, 4000000, 0, 0, 0)" \
    "$TN" "$(iso "$1")" "$(iso $(($1 + 60)))" "$2" "$2" "$3" "$2" "$(iso $(($1 + 5)))" "$(iso $(($1 + 30)))"; }
pq "INSERT INTO pgvigil.mssql_qs_runtime (instance_id, snapshot_at, interval_end, database_name, plan_id, query_id, query_hash, plan_hash_n, executions, failed,
      duration_us, cpu_us, logical_reads, physical_reads, logical_writes, row_count, max_duration_us, memory_pages, max_memory_pages, max_dop,
      first_execution, last_execution, wait_ms, aborted_executions, aborted_cpu_us, aborted_duration_us, exception_executions, exception_cpu_us, exception_duration_us)
    VALUES $(tnrow "$BW" 1 0x00000000000000B1), $(tnrow $((TW + 600)) 1 0x00000000000000B1), $(tnrow $((TW + 600)) 2 0x00000000000000B2)" >/dev/null
TNW="instance=$TN&from=$(iso "$TW")&to=$(iso $((TW + 3600)))&db=synth"
api "mssql/querystore?$TNW&base=prev&part=regressed" tnp.json
api "mssql/querystore?$TNW&part=regressed" tn7.json
for f in tnp tn7; do
  got=$(objs "$TMPD/$f.json" regressed | jq -r '[.[] | (.query_hash + "|" + .raised_by + "|" + (.has_baseline | tostring) + "|" + .severity)] | sort | join(",")')
  [[ "$got" == "0x00000000000000B2|timeouts|false|HIGH" ]] || fail "D: stored rows, Regressed ($f): '$got' (want only tn_new 0x00000000000000B2|timeouts|false|HIGH)"
done
echo "ok   D: stored rows: 4 Aborted runs in the window and none before raised by timeouts alone, no kept baseline, HIGH (base=prev and the 7-day default); the same rate before not listed"

echo "== F. the plan-cache compare over 7 days =="
for spec in "761" "3000"; do
  IID=$(pq "SELECT pgvigil.ensure_instance('pgvq-t$spec', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
  for back in 15 8 0; do pq "SELECT pgvigil.ensure_month_partition('mssql_pc_sample', now() - interval '$back days'), pgvigil.ensure_month_partition('mssql_pc_read', now() - interval '$back days')" >/dev/null; done
  pq "INSERT INTO pgvigil.mssql_pc_read (instance_id, snapshot_at, interval_secs, statements, capped)
        SELECT $IID, t, 300, $spec, false FROM generate_series(now() - interval '14 days', now(), interval '5 minutes') t" >/dev/null
  pq "INSERT INTO pgvigil.mssql_pc_sample (instance_id, snapshot_at, database_id, query_key, database_name, executions, cpu_us, duration_us,
        logical_reads, physical_reads, logical_writes, row_count, spills, plans, interval_secs)
      SELECT $IID, t, 5 + (k % 3), '0x' || lpad(to_hex((k * 2654435761) % 4294967296), 16, '0'), 'db' || (k % 3), e, (d * 0.7)::bigint, d,
             e * 10, 0, 0, e, 0, 1, 300
        FROM (SELECT t, k, e, (e * exp(random() * ln(1e7)))::bigint AS d
                FROM (SELECT t, ((extract(epoch FROM t)::bigint / 300) * 7 + g) % ($spec * 2) AS k, 1 + (random() * 200)::bigint AS e
                        FROM generate_series(now() - interval '14 days', now(), interval '5 minutes') t, generate_series(1, $spec) g) a) b" >/dev/null
  eval "IID_$spec=$IID"
done
psql "$PGDSN" -Xqc "VACUUM (ANALYZE) pgvigil.mssql_pc_sample, pgvigil.mssql_pc_read" >/dev/null
TF=""; SLOW=""; EMPTY=""   # every part is timed; a part past the 10 s line or with no row fails F after the last of them
for spec in 761 3000; do
  eval "IID=\$IID_$spec"
  NOW=$(date -u +%s); F7=$(iso $((NOW - 604800))); T7=$(iso "$NOW")   # one clock read for both edges
  for run in 1 2 3 4 5 6 7 8; do
    tt=$(curl -s --max-time 30 -o "$TMPD/f-$spec-$run.json" -w '%{http_code} %{time_total}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/plancache?instance=$IID&from=$F7&to=$T7&compare=week&part=compare")
    [[ "${tt%% *}" == 200 ]] || fail "F: the compare at $spec rows a read answered ${tt%% *}: $(head -c 300 "$TMPD/f-$spec-$run.json")"
    python3 -c "import sys; sys.exit(0 if float('${tt##* }') < 10 else 1)" || SLOW+=" plancache/compare-$spec:${tt##* }"
    TF+=" ${spec}:${tt##* }"
  done
  n=$(jq '(.compare.rows // []) | length' "$TMPD/f-$spec-3.json")
  [[ "$n" -ge 100 ]] || fail "F: the compare at $spec returned $n rows on run 3 (100 or more wanted)"
  cmp -s <(jq -S .compare "$TMPD/f-$spec-3.json") <(jq -S .compare "$TMPD/f-$spec-8.json") || fail "F: run 3's compare differs from run 8's at $spec"
done
echo "ok   F: the plan-cache compare, a 7-day window against the 7 days before, through the API (s, eight runs each; run 3's rows = run 8's, $(ld)):$TF"
# the plan cache's other windowed parts at 3,000 rows a read over 7 days (the join review d10a, finding 1): named,
# cached statements, so the UI pool's plan_cache_mode = force_custom_plan (web.go) alone keeps them planned with their
# window's values; and the compare's windows part (finding 3)
TP=""
for what in "totals:part=totals" "top:part=top" "series:part=series" "cwin:compare=week&part=compare_windows"; do
  for run in 1 2 3 4 5 6 7 8; do
    tt=$(curl -s --max-time 30 -o "$TMPD/fp.json" -w '%{http_code} %{time_total}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/plancache?instance=$IID_3000&from=$F7&to=$T7&${what#*:}")
    [[ "${tt%% *}" == 200 ]] || fail "F: the plan cache ${what%%:*} at 3000 answered ${tt%% *}: $(head -c 300 "$TMPD/fp.json")"
    python3 -c "import sys; sys.exit(0 if float('${tt##* }') < 10 else 1)" || SLOW+=" plancache/${what%%:*}:${tt##* }"
    TP+=" ${what%%:*}:${tt##* }"
  done
  nonempty "$TMPD/fp.json" "${what##*part=}" || EMPTY+=" plancache/${what%%:*}"
done
echo "     F: the plan cache's totals, top, series and compare_windows at 3,000 rows a read over 7 days (s, eight runs each, $(ld)):$TP"
# the procedures at scale: 1,000 procedures a read, every five minutes, 14 days; every windowed part over 7 days
PRI=$(pq "SELECT pgvigil.ensure_instance('pgvq-tpr', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
for back in 15 8 0; do pq "SELECT pgvigil.ensure_month_partition('mssql_proc_sample', now() - interval '$back days'), pgvigil.ensure_month_partition('mssql_proc_read', now() - interval '$back days')" >/dev/null; done
pq "INSERT INTO pgvigil.mssql_proc_read (instance_id, snapshot_at, interval_secs, procs)
      SELECT $PRI, t, 300, 1000 FROM generate_series(now() - interval '14 days', now(), interval '5 minutes') t" >/dev/null
pq "INSERT INTO pgvigil.mssql_proc_sample (instance_id, snapshot_at, database_id, object_id, database_name, schema_name, object_name, type_desc,
      executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
    SELECT $PRI, t, 5 + (g % 3), 1000 + g, 'db' || (g % 3), 'dbo', 'p' || g, 'SQL_STORED_PROCEDURE', e, e * 700, e * 1000, e * 10, 0, 0, 300
      FROM (SELECT t, g, 1 + (random() * 100)::bigint AS e FROM generate_series(now() - interval '14 days', now(), interval '5 minutes') t, generate_series(1, 1000) g) a" >/dev/null
psql "$PGDSN" -Xqc "VACUUM (ANALYZE) pgvigil.mssql_proc_sample, pgvigil.mssql_proc_read" >/dev/null
NP=$(pq "SELECT count(*) FROM pgvigil.mssql_proc_sample WHERE instance_id = $PRI")
TR=""
for what in "totals:part=totals" "databases:part=databases" "procs:part=procs" "series:part=series" "intervals:db_id=6&object=1001&part=intervals" "compare:compare=week&part=compare" "cwin:compare=week&part=compare_windows"; do
  for run in 1 2 3 4 5 6 7 8; do
    tt=$(curl -s --max-time 30 -o "$TMPD/fr-$run.json" -w '%{http_code} %{time_total}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/procs?instance=$PRI&from=$F7&to=$T7&${what#*:}")
    [[ "${tt%% *}" == 200 ]] || fail "F: the procedures ${what%%:*} answered ${tt%% *}: $(head -c 300 "$TMPD/fr-$run.json")"
    python3 -c "import sys; sys.exit(0 if float('${tt##* }') < 10 else 1)" || SLOW+=" procs/${what%%:*}:${tt##* }"
    TR+=" ${what%%:*}:${tt##* }"
  done
  nonempty "$TMPD/fr-8.json" "${what##*part=}" || EMPTY+=" procs/${what%%:*}"
  if [[ "${what%%:*}" == compare ]]; then
    c3=$(jq '(.compare.rows // []) | length' "$TMPD/fr-3.json"); [[ "$c3" -ge 100 ]] || fail "F: the procedures compare returned $c3 rows on run 3 (100 or more wanted)"
    cmp -s <(jq -S .compare "$TMPD/fr-3.json") <(jq -S .compare "$TMPD/fr-8.json") || fail "F: run 3's procedures compare differs from run 8's"
  fi
done
echo "     F: the procedures over $NP stored rows (1,000 a read, 14 days), 7 days through the API (s, eight runs each, $(ld)):$TR"
# the Query Store at its ceiling: 1-minute intervals, 250 kept plans each (5 lists of 50), 14 days; 1 % of the rows
# with failures, split as 0126 stores them
QI=$(pq "SELECT pgvigil.ensure_instance('pgvq-tqs', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
for back in 15 8 0; do pq "SELECT pgvigil.ensure_month_partition('mssql_qs_runtime', now() - interval '$back days'), pgvigil.ensure_month_partition('mssql_qs_interval', now() - interval '$back days')" >/dev/null; done
pq "INSERT INTO pgvigil.mssql_qs_interval (instance_id, snapshot_at, database_name, interval_id, interval_end, plans, executions, duration_us, cpu_us, logical_reads, wait_ms, read_at)
    SELECT $QI, t, 'synth', n, t + interval '1 minute', 250, 25000, 1000000000, 500000000, 1000000, 0, t + interval '1 hour'
      FROM generate_series(date_trunc('minute', now()) - interval '14 days', date_trunc('minute', now()), interval '1 minute') WITH ORDINALITY g(t, n)" >/dev/null
pq "INSERT INTO pgvigil.mssql_qs_runtime (instance_id, snapshot_at, interval_end, database_name, plan_id, query_id, query_hash, plan_hash_n, executions, failed,
      duration_us, cpu_us, logical_reads, physical_reads, logical_writes, row_count, max_duration_us, memory_pages, max_memory_pages, max_dop,
      first_execution, last_execution, wait_ms, aborted_executions, aborted_cpu_us, aborted_duration_us, exception_executions, exception_cpu_us, exception_duration_us)
    SELECT $QI, t, t + interval '1 minute', 'synth', p, p, '0x' || upper(lpad(to_hex((p * 2654435761) % 4294967296), 16, '0')), p, e, f,
           d * e, d * e * 6 / 10, e * 10, 0, 0, e, d, 0, 0, 1, t, t + interval '30 seconds', 0,
           CASE WHEN f > 0 THEN f END, CASE WHEN f > 0 THEN f * 100 END, CASE WHEN f > 0 THEN f * 1000 END,
           CASE WHEN f > 0 THEN 0 END, CASE WHEN f > 0 THEN 0 END, CASE WHEN f > 0 THEN 0 END
      FROM (SELECT t, ((extract(epoch FROM t)::bigint / 60) * 7 + g) % 2000 + 1 AS p, e, least(e, CASE WHEN random() < 0.01 THEN 1 + (random() * 3)::bigint ELSE 0 END) AS f,
                   (exp(random() * ln(1e6)))::bigint AS d
              FROM (SELECT t, g, 1 + (random() * 50)::bigint AS e
                      FROM generate_series(date_trunc('minute', now()) - interval '14 days', date_trunc('minute', now()), interval '1 minute') t, generate_series(1, 250) g) a) x" >/dev/null
psql "$PGDSN" -Xqc "VACUUM (ANALYZE) pgvigil.mssql_qs_runtime, pgvigil.mssql_qs_interval" >/dev/null
NQ=$(pq "SELECT count(*) FROM pgvigil.mssql_qs_runtime WHERE instance_id = $QI")
TQ=""
NOW=$(date -u +%s); F7=$(iso $((NOW - 604800))); F1=$(iso $((NOW - 3600))); T7=$(iso "$NOW")   # one clock read for every edge
for what in "totals:from=$F7&to=$T7&part=totals" "compare:from=$F7&to=$T7&compare=week&part=compare" "regressed:from=$F1&to=$T7&part=regressed" "skipped:from=$F1&to=$T7&part=regressed_skipped" "cwin:from=$F7&to=$T7&compare=week&part=compare_windows"; do
  for run in 1 2 3 4 5 6 7 8; do
    tt=$(curl -s --max-time 30 -o "$TMPD/fq-$run.json" -w '%{http_code} %{time_total}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/querystore?instance=$QI&${what#*:}")
    [[ "${tt%% *}" == 200 ]] || fail "F: the Query Store ${what%%:*} answered ${tt%% *}: $(head -c 300 "$TMPD/fq-$run.json")"
    python3 -c "import sys; sys.exit(0 if float('${tt##* }') < 10 else 1)" || SLOW+=" querystore/${what%%:*}:${tt##* }"
    TQ+=" ${what%%:*}:${tt##* }"
  done
  nonempty "$TMPD/fq-8.json" "${what##*part=}" || EMPTY+=" querystore/${what%%:*}"
done
echo "     F: the Query Store over $NQ stored rows (14 days, 1-minute intervals, 250 kept plans each), through the API (s, eight runs each, $(ld)):$TQ"
[[ -z "$SLOW" ]] || fail "F: past the 10 s line:$SLOW (every timing above; $(ld))"
[[ -z "$EMPTY" ]] || fail "F: a timed part returned no row:$EMPTY"
echo "ok   F: every timed part under 10 s and each with rows (above)"
# PostgreSQL's rule on the compare's SQL (not the proof of the UI pool's setting: these sessions set plan_cache_mode
# themselves through PGOPTIONS, and the product sends the compare under planEach; the pool's own configuration is
# TestUIPoolConfig's (go test internal/web) and, where pg_stat_statements is preloaded, the plans = calls row below):
# one psql session PREPAREs the plan-cache compare's own SQL (read from the Go source; its highest parameter must be
# the six the PREPARE declares), EXECUTEs it six times over 7 days at 761 rows a read and once at 3,000, and reads
# pg_prepared_statements: no generic plan under force_custom_plan, one or more under auto (on a failure the generic and
# the custom plan's costs are printed); then the planning cost under force_custom_plan: EXPLAIN (SUMMARY) of the
# Findings page's own read of the 16-arm findings view, three times
python3 - "$TMPD" <<'PYEND' || fail "F: the SQL could not be read from the Go source"
import re, sys
d = sys.argv[1]
def lit(src, name):
    m = re.search(r'(?:const|var) ' + name + r' = ', src)
    i, out = m.end(), []
    while True:
        while src[i] in ' \t\n': i += 1
        if src[i] == '`':
            j = src.index('`', i + 1); out.append(src[i + 1:j]); i = j + 1
        else:
            ident = re.match(r'[A-Za-z_]\w*', src[i:]).group(0); i += len(ident)
            if src[i] in '.(': raise SystemExit(f'{name}: a call in the expression ({ident})')
            out.append(lit(src, ident))
        k = i
        while src[k] in ' \t': k += 1
        if src[k] == '+': i = k + 1; continue
        return ''.join(out)
pc = open('internal/web/q_mssql_plancache.go').read()
pcc = lit(pc, 'sqlMSSQLPCCompare')
mx = max(int(x) for x in re.findall(r'\$(\d+)', pcc))
if mx != 6: raise SystemExit(f'sqlMSSQLPCCompare: highest parameter ${mx}, the PREPARE declares 6')
open(f'{d}/pcc.sql', 'w').write(pcc)
open(f'{d}/totals.sql', 'w').write(lit(pc, 'sqlMSSQLPCTotals'))
open(f'{d}/findings.sql', 'w').write(lit(open('internal/web/queries.go').read(), 'sqlFindings'))
PYEND
for mode in force_custom_plan auto; do
  { echo "PREPARE pcc (int, timestamptz, timestamptz, int, boolean, float8) AS"; cat "$TMPD/pcc.sql"; echo ";"; echo '\o /dev/null'
    # s177j-10's order: dear custom plans first (7 days at 761 a read), then 7 days at 3,000; six cheap 1-hour runs
    # keep auto custom (s177j-18: 0|7), since the generic plan then looks dearer than their average
    for _ in 1 2 3 4 5 6; do echo "EXECUTE pcc($IID_761, now() - interval '7 days', now(), NULL, false, 604800);"; done
    echo "EXECUTE pcc($IID_3000, now() - interval '7 days', now(), NULL, false, 604800);"; echo '\o'
    echo "SELECT generic_plans || '|' || custom_plans FROM pg_prepared_statements WHERE name = 'pcc';"; } > "$TMPD/pcm-$mode.sql"
done
PCM_F=$(PGOPTIONS='-c plan_cache_mode=force_custom_plan -c jit=off' psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -f "$TMPD/pcm-force_custom_plan.sql") || fail "F: the PREPARE session under force_custom_plan"
PCM_A=$(PGOPTIONS='-c plan_cache_mode=auto -c jit=off' psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -f "$TMPD/pcm-auto.sql") || fail "F: the PREPARE session under auto"
[[ "$PCM_F" == "0|7" ]] || fail "F: under force_custom_plan pg_prepared_statements reads generic|custom $PCM_F (want 0|7)"
# pcost <mode>: the top node's cost of the compare at 7 days and 761 a read, planned under <mode>
pcost() { { echo "SET plan_cache_mode = $1;"; echo "PREPARE pcc (int, timestamptz, timestamptz, int, boolean, float8) AS"; cat "$TMPD/pcc.sql"; echo ";"
    echo "EXPLAIN EXECUTE pcc($IID_761, now() - interval '7 days', now(), NULL, false, 604800);"; } \
    | PGOPTIONS='-c jit=off' psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -f - 2>&1 | head -1 | grep -o 'cost=[0-9.]*\.\.[0-9.]*' || echo 'no cost read'; }
[[ "${PCM_A%%|*}" -ge 1 ]] || fail "F: under auto the compare stayed custom ($PCM_A generic|custom): the row cannot tell the setting does anything (generic plan $(pcost force_generic_plan), custom plan $(pcost force_custom_plan))"
{ echo "PREPARE pf (int) AS"; cat "$TMPD/findings.sql"; echo ";"; for _ in 1 2 3; do echo "EXPLAIN (SUMMARY ON) EXECUTE pf(NULL);"; done; } > "$TMPD/pf.sql"
PT=$(PGOPTIONS='-c plan_cache_mode=force_custom_plan -c jit=off' psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -f "$TMPD/pf.sql" | grep -o 'Planning Time: [0-9.]* ms' | sed 's/Planning Time: //' | tr '\n' ' ') \
  || fail "F: no Planning Time from EXPLAIN (SUMMARY) of the findings read"
[[ -n "$PT" ]] || fail "F: no Planning Time from EXPLAIN (SUMMARY) of the findings read"
echo "ok   F: PostgreSQL's rule on the compare's SQL: PREPAREd and run 6 x 7 days at 761 + 1 x 7 days at 3,000 it reads generic|custom $PCM_F under force_custom_plan and $PCM_A under auto; the Findings page's read plans in $PT under force_custom_plan (each read pays it)"
# the UI pool's own setting through serve (the join review d10b, b1 (ii)): F's eight totals runs at 3,000 (and every
# earlier totals read) were planned once each - plans = calls in pg_stat_statements for the totals' SQL as Go holds it.
# A pool on auto fails it only where a generic plan was kept (the configuration itself is TestUIPoolConfig's)
if [[ "$PSS" == on ]]; then
  psql "$PGDSN" -Xqc "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" >/dev/null
  # pg_stat_statements shows a statement's constants as $n placeholders numbered after its own parameters (0, 1000.0
  # and 1 in the totals' SQL), so both texts are compared with every $n and every number as one mark (s177j-24 read
  # 0|0 on the plain text)
  CP=$(psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -v sql="$(cat "$TMPD/totals.sql")" <<'PSQLEND'
CREATE TEMP VIEW pss_norm AS
SELECT calls, plans, query,
       btrim(regexp_replace(regexp_replace(regexp_replace(query, '\$\d+', '?', 'g'), '\y\d+(\.\d+)?\y', '?', 'g'), '\s+', ' ', 'g')) AS norm
  FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database());
SELECT coalesce(sum(calls), 0) || '|' || coalesce(sum(plans), 0) FROM pss_norm
 WHERE norm = btrim(regexp_replace(regexp_replace(regexp_replace(:'sql', '\$\d+', '?', 'g'), '\y\d+(\.\d+)?\y', '?', 'g'), '\s+', ' ', 'g'));
PSQLEND
) || fail "F: the pg_stat_statements read"
  if ! [[ "${CP%%|*}" -ge 8 && "${CP%%|*}" == "${CP##*|}" ]]; then
    psql "$PGDSN" -XAtq -c "SELECT 'pss: ' || count(*) || ' statements in this database; track ' || current_setting('pg_stat_statements.track') || ', track_planning ' || current_setting('pg_stat_statements.track_planning') || ', compute_query_id ' || current_setting('compute_query_id') FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())" >&2 || true
    psql "$PGDSN" -XAtq -c "SELECT 'pss: ' || calls || '|' || plans || ' ' || left(regexp_replace(query, '\s+', ' ', 'g'), 240) FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database()) AND query LIKE '%mssql_pc_sample%' ORDER BY calls DESC LIMIT 4" >&2 || true
    fail "F: serve's totals read calls|plans $CP in pg_stat_statements (want 8 or more calls, each planned; above: what it holds)"
  fi
  echo "ok   F: the UI pool through serve: the plan cache's totals ran $CP calls|plans (pg_stat_statements, track_planning on): every run planned"
else
  echo "     F: NOT PROVEN: plans = calls through serve's pool (pg_stat_statements is not in the box's shared_preload_libraries); the pool's configuration is TestUIPoolConfig's"
fi

echo "== H. DONE-2's reads: the heatmap, the histories, the Query Store overhead =="
# H1. the heatmap's cells = a hand count of the stored samples (F's seed at 761 rows a read, 24 hours: 10-minute bins),
# the four metrics, with samples ON each bucket line and one below it (a value of exactly 10^k goes to bucket k + 1):
# duration and cpu 1000 * E * 10^k us and 1 us less, writes E * 10^k and 1 less (E = 3); executions 10^k and 10^k - 1;
# each its own query, two hours back (H3 reads the last hour's most-executed query)
NOW=$(( $(date -u +%s) / 60 * 60 )); HF=$(iso $((NOW - 86400))); HT=$(iso "$NOW")   # one clock read, on the minute
pq "INSERT INTO pgvigil.mssql_pc_sample (instance_id, snapshot_at, database_id, query_key, database_name, executions, cpu_us, duration_us,
      logical_reads, physical_reads, logical_writes, row_count, spills, plans, interval_secs)
    SELECT $IID_761, to_timestamp($NOW - 7200 - row_number() OVER (ORDER BY v.e, v.d, v.w)), 5, '0xb' || lpad((row_number() OVER (ORDER BY v.e, v.d, v.w))::text, 15, '0'),
           'db5', v.e, v.d, v.d, 0, 0, v.w, v.e, 0, 1, 300
      FROM (SELECT 3::bigint AS e, 3000 * (10::bigint ^ k)::bigint + o AS d, 3 * (10::bigint ^ k)::bigint + o AS w
              FROM generate_series(0, 5) k, (VALUES (0), (-1)) x(o)
            UNION ALL
            SELECT (10::bigint ^ k)::bigint + o, 1000 * ((10::bigint ^ k)::bigint + o), (10::bigint ^ k)::bigint + o
              FROM generate_series(0, 5) k, (VALUES (0), (-1)) x(o) WHERE (10::bigint ^ k)::bigint + o > 0) v" >/dev/null
NL=$(pq "SELECT count(*) FROM pgvigil.mssql_pc_sample WHERE instance_id = $IID_761 AND query_key LIKE '0xb%' AND snapshot_at > '$HF' AND snapshot_at <= '$HT'")
[[ "$NL" == 23 ]] || fail "H: $NL samples on the bucket lines in H1's window (23 wanted)"
for metric in duration cpu writes executions; do
  api "mssql/plancache?instance=$IID_761&from=$HF&to=$HT&part=heatmap&metric=$metric" "h-$metric.json"
done
psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "COPY (SELECT floor(extract(epoch FROM snapshot_at))::bigint, database_id, query_key, executions, duration_us, cpu_us, logical_writes
    FROM pgvigil.mssql_pc_sample WHERE instance_id = $IID_761 AND snapshot_at > '$HF' AND snapshot_at <= '$HT' AND executions > 0) TO STDOUT WITH CSV" > "$TMPD/h.csv"
python3 - "$TMPD" <<'PYEND' || fail "H: the heatmap's cells differ from the hand count (above)"
import sys, csv, json
from datetime import datetime
d = sys.argv[1]
rows = [(int(a), int(b), c, int(e), int(u), int(p), int(w)) for a, b, c, e, u, p, w in csv.reader(open(f"{d}/h.csv"))]
def bucket(num, den):   # PerformanceMonitor's seven log10 buckets of num / den, in integers (no float edge)
    for k, lim in enumerate((1, 10, 100, 1000, 10000, 100000)):
        if num < lim * den: return k
    return 6
for metric in ('duration', 'cpu', 'writes', 'executions'):
    j = json.load(open(f"{d}/h-{metric}.json"))['heatmap']
    api = [dict(zip(j['columns'], r)) for r in j['rows']]
    if not api: print(f"DIFF {metric}: no cell"); sys.exit(1)
    binm = api[0]['bin_minutes']
    if binm != 10: print(f"DIFF {metric}: bin {binm} min, PerformanceMonitor's at 24 h is 10"); sys.exit(1)
    cells = {}
    for ts, db, key, e, dur, cpu, wr in rows:
        b = ts // 600 * 600
        k = {'duration': lambda: bucket(dur, 1000 * e), 'cpu': lambda: bucket(cpu, 1000 * e),
             'writes': lambda: bucket(wr, e), 'executions': lambda: bucket(e, 1)}[metric]()
        c = cells.setdefault((b, k), {})
        c[(db, key)] = c.get((db, key), 0) + e
    hand = {}
    for (b, k), qs in cells.items():
        top = sorted(qs.items(), key=lambda kv: (-kv[1], kv[0][0], kv[0][1]))[0]
        hand[(b, k)] = (len(qs), sum(qs.values()), top[0][0], top[0][1], top[1])
    keep, run = set(), 0   # bins newest first while their cells add up to 1,000 or fewer (whole bins)
    for b in sorted({x[0] for x in hand}, reverse=True):
        run += sum(1 for x in hand if x[0] == b)
        if run > 1000: break
        keep.add(b)
    want = [x for x in hand if x[0] in keep]
    got = {(int(datetime.fromisoformat(r['time_bin'].replace('Z', '+00:00')).timestamp()), r['bucket']):
           (r['queries'], r['executions'], r['database_id'], r['query_key'], r['top_executions']) for r in api}
    bad = [x for x in want if got.get(x) != hand[x]] + [x for x in got if x not in hand]
    n_cells = api[0]['n_cells']
    if bad or len(got) != len(want) or n_cells != len(hand) or api[0]['bins_cut'] != len({x[0] for x in hand}) - len(keep):
        print(f"DIFF {metric}: {len(bad)} cells differ, the API {len(got)} of {n_cells}, the hand {len(want)} of {len(hand)}; first {bad[:3]}",
              [(got.get(x), hand.get(x)) for x in bad[:3]]); sys.exit(1)
    print(f"H {metric}: {len(got)} cells of {n_cells} = the hand count over {len(rows)} stored samples (distinct queries {sum(v[0] for v in hand.values())})")
PYEND
echo "ok   H: the heatmap's cells (duration, cpu, writes and executions, 24 h, 10-minute bins, $NL samples on and just under the bucket lines) = a hand count of the stored samples: distinct (database, query) per cell, the most-executed by executions summed, whole bins newest first to 1,000 cells"
# H1 on a PostgreSQL 13 repository (the repository's floor; the join review d10b, a1): a throwaway postgres:13 container
# migrated by this binary, H1's samples copied in, served on its own port without the login: its heatmap cells = the
# box's (PostgreSQL 18), and date_bin (14+) is refused there, so the row would have caught the old binning
printf 'POSTGRES_PASSWORD=%s\n' "$(pw)" > "$TMPD/pg13.env"
P13PW=$(sed 's/^POSTGRES_PASSWORD=//' "$TMPD/pg13.env")
docker run -d --name "$PG13" --label "$LBL" --memory 1g --env-file "$TMPD/pg13.env" -p 127.0.0.1::5432 "$IMG_PG13" >/dev/null || fail "H: the PostgreSQL 13 container ($IMG_PG13)"
PORT13=$(docker port "$PG13" 5432/tcp | head -1 | sed 's/.*://')
DSN13="host=127.0.0.1 port=$PORT13 user=postgres dbname=postgres"
p13() { PGPASSWORD="$P13PW" psql "$DSN13" -XAtq -v ON_ERROR_STOP=1 "$@"; }
end=$((SECONDS + 120)); until p13 -c "SELECT 1" >/dev/null 2>&1; do
  (( SECONDS < end )) || { docker logs --tail 40 "$PG13" >&2 2>&1 || true; fail "H: PostgreSQL 13 did not take a login in 120 s"; }; sleep 1; done
V13=$(p13 -c "SHOW server_version_num")
[[ "$V13" -ge 130000 && "$V13" -lt 140000 ]] || fail "H: the PostgreSQL 13 container reports server_version_num $V13"
if p13 -c "SELECT date_bin('10 minutes', now(), TIMESTAMPTZ '1970-01-01 00:00:00+00')" >"$TMPD/db13.out" 2>&1; then fail "H: date_bin answered on PostgreSQL $V13"; fi
grep -q 'does not exist' "$TMPD/db13.out" || { cat "$TMPD/db13.out" >&2; fail "H: date_bin on PostgreSQL $V13 failed, not as missing"; }
printf 'repository:\n  dsn: "%s"\ninstances: []\n' "$DSN13" > "$TMPD/m13.yaml"
PGPASSWORD="$P13PW" "$TMPD/pgvigil" migrate -config "$TMPD/m13.yaml" >"$TMPD/migrate13.out" 2>&1 || { tail -20 "$TMPD/migrate13.out" >&2; fail "H: migrate on PostgreSQL $V13"; }
I13=$(p13 -c "SELECT pgvigil.ensure_instance('pgvq-t761', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
p13 -c "SELECT pgvigil.ensure_month_partition('mssql_pc_sample', '$HF'), pgvigil.ensure_month_partition('mssql_pc_sample', '$HT')" >/dev/null
PC_COLS="snapshot_at, database_id, query_key, database_name, executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, row_count, spills, plans, interval_secs"
psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "COPY (SELECT $I13, $PC_COLS FROM pgvigil.mssql_pc_sample WHERE instance_id = $IID_761 AND snapshot_at > '$HF' AND snapshot_at <= '$HT') TO STDOUT" \
  | p13 -c "COPY pgvigil.mssql_pc_sample (instance_id, $PC_COLS) FROM STDIN" || fail "H: H1's samples into PostgreSQL $V13"
N13=$(p13 -c "SELECT count(*) FROM pgvigil.mssql_pc_sample WHERE instance_id = $I13")
W13=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
PGPASSWORD="$P13PW" "$TMPD/pgvigil" serve -config "$TMPD/m13.yaml" -no-login -listen "127.0.0.1:$W13" >"$TMPD/serve13.out" 2>&1 & S13=$!; BG+=($S13)
for _ in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$W13/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$S13" 2>/dev/null || { cat "$TMPD/serve13.out" >&2; fail "H: serve on PostgreSQL $V13 exited"; }
for metric in duration cpu writes executions; do
  c=$(curl -s --max-time 30 -o "$TMPD/h13-$metric.json" -w '%{http_code}' -H 'X-Pgvigil: 1' "http://127.0.0.1:$W13/api/mssql/plancache?instance=$I13&from=$HF&to=$HT&part=heatmap&metric=$metric")
  [[ "$c" == 200 ]] || fail "H: the heatmap ($metric) on PostgreSQL $V13 answered $c: $(head -c 300 "$TMPD/h13-$metric.json")"
  nonempty "$TMPD/h13-$metric.json" heatmap || fail "H: the heatmap ($metric) on PostgreSQL $V13 has no cell"
  cmp -s <(jq -S .heatmap "$TMPD/h-$metric.json") <(jq -S .heatmap "$TMPD/h13-$metric.json") \
    || { diff <(jq -c '.heatmap.rows[]' "$TMPD/h-$metric.json") <(jq -c '.heatmap.rows[]' "$TMPD/h13-$metric.json") | head -6 >&2; fail "H: the heatmap ($metric) on PostgreSQL $V13 differs from PostgreSQL 18's (above)"; }
done
kill "$S13" 2>/dev/null || true; docker rm -f -v "$PG13" >/dev/null 2>&1 || true
echo "ok   H: on PostgreSQL $V13 (date_bin refused there) the heatmap's cells over the same $N13 samples = PostgreSQL 18's, duration, cpu, writes and executions ($(for m in duration cpu writes executions; do jq '.heatmap.rows | length' "$TMPD/h13-$m.json"; done | paste -sd/) cells)"
# H2. the heatmap timed at 24 h and 7 days at 761 and 3,000 rows a read (eight runs each: past the fifth, where a
# prepared statement may turn generic), the fail line 10 s a run; at the ceiling shape (3,000 rows a read, 7 days) the
# line is the MEDIAN of the eight: on a shared box one run there can cross 10 s on load alone, so every run is printed
# with the 1-minute load at its start and a single run over 10 s prints as a slow run; the median guards the form. A run
# curl cannot finish (its --max-time) fails with its line, as any answer but 200.
# hmedian: the median of the run times given; exit 1 when it is 10 s or more
hmedian() { python3 -c 'import sys, statistics; m = statistics.median(float(x) for x in sys.argv[1:]); print(f"{m:.3f}"); sys.exit(0 if m < 10 else 1)' "$@"; }
TH=""; HSLOW=""; HEMPTY=""; HMED=""; HNOTE=""   # a slow run, a slow median or an empty read fails H after the last timing
for spec in 761 3000; do
  eval "IID=\$IID_$spec"
  for span in 24h 7d; do
    # the window ends a second past the seed's newest read (F laid its reads every 5 minutes up to its own clock), so a
    # 7-day window holds exactly 2,016 reads however late it is read: at 3,000 a read that is the ceiling, 6,048,000
    HTS=$(pq "SELECT floor(extract(epoch FROM max(snapshot_at)))::bigint + 1 FROM pgvigil.mssql_pc_read WHERE instance_id = $IID")
    [[ "$HTS" =~ ^[0-9]+$ ]] || fail "H: no stored read of the $spec seed ('$HTS')"
    [[ $span == 24h ]] && HF=$(iso $((HTS - 86400))) || HF=$(iso $((HTS - 604800))); HT=$(iso "$HTS")
    if [[ "$spec/$span" == 3000/7d ]]; then
      N3=$(pq "SELECT coalesce(sum(statements), 0) FROM pgvigil.mssql_pc_read WHERE instance_id = $IID AND snapshot_at > '$HF' AND snapshot_at <= '$HT'")
      [[ "$N3" == 6048000 ]] || fail "H: H2's 3,000 / 7 days window $HF .. $HT holds $N3 stored samples, not the ceiling 6,048,000"
      H3F=$HF; H3T=$HT
    fi
    T8=()
    for run in 1 2 3 4 5 6 7 8; do
      l1=$(cut -d' ' -f1 /proc/loadavg)
      tt=$(curl -s --max-time 30 -o "$TMPD/hh.json" -w '%{http_code} %{time_total}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/plancache?instance=$IID&from=$HF&to=$HT&part=heatmap") || true
      [[ "${tt%% *}" == 200 ]] || fail "H: the heatmap at $spec rows a read over $span answered ${tt%% *} (run $run, ${tt##* } s): $(head -c 300 "$TMPD/hh.json" 2>/dev/null)"
      if [[ "$spec/$span" == 3000/7d ]]; then
        T8+=("${tt##* }")
        python3 -c "import sys; sys.exit(0 if float('${tt##* }') < 10 else 1)" || HNOTE+=" heatmap/$spec/$span run $run:${tt##* } (load $l1)"
        TH+=" $spec/$span:${tt##* }@$l1"
      else
        python3 -c "import sys; sys.exit(0 if float('${tt##* }') < 10 else 1)" || HSLOW+=" heatmap/$spec/$span:${tt##* }"
        TH+=" $spec/$span:${tt##* }"
      fi
    done
    if [[ "$spec/$span" == 3000/7d ]]; then
      HMED=$(hmedian "${T8[@]}") || HSLOW+=" heatmap/$spec/$span:median ${HMED}"
    fi
    nonempty "$TMPD/hh.json" heatmap || HEMPTY+=" heatmap/$spec/$span"
  done
done
echo "     H: the heatmap through the API (s, eight runs each, $(ld); at 3,000 / 7 days each run @ the 1-minute load at its start):$TH"
HMARGIN=$(python3 -c 'import sys; m = float(sys.argv[1]); print(f"{10 - m:.2f} s ({100 - 10 * m:.0f} %)")' "${HMED:-nan}" 2>/dev/null || true)
echo "     H: the heatmap at 3,000 rows a read over 7 days: the median of the eight runs $HMED s, $HMARGIN under the failing line there (10 s)"
[[ -z "$HNOTE" ]] || echo "     H: slow run(s) at 3,000 / 7 days, over 10 s (none fails alone: the median above is the line; for a2 in DONE-2):$HNOTE"
# a range past PerformanceMonitor's 168 h reach is refused with its words
c=$(curl -s -o "$TMPD/h8.json" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/plancache?instance=$IID_761&from=$(date -u -d '-8 days' +%Y-%m-%dT%H:%M:%SZ)&to=$(date -u +%Y-%m-%dT%H:%M:%SZ)&part=heatmap")
[[ "$c" == 400 ]] && grep -q 'pick 7 days or less' "$TMPD/h8.json" || fail "H: 8 days answered $c: $(head -c 200 "$TMPD/h8.json")"
echo "ok   H: 8 days answered 400 'the heatmap reaches 7 days: pick 7 days or less'"
# H4. the heatmap's size (a2): a window whose reads stored more samples than the proven ceiling (2,016 reads x 3,000) is
# refused before the read, with the window's own count; H2's timed row at 3,000 a read is the seed at the ceiling
IID_BIG=$(pq "SELECT pgvigil.ensure_instance('pgvq-big', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
# 2,016 reads in the window (BF, BT], the newest at BT itself: 2,015 of 3,000 and one of 3,001 = the ceiling and one
NOW=$(date -u +%s); BF=$(iso $((NOW - 604800))); BT=$(iso "$NOW")   # one clock read, whole seconds
pq "INSERT INTO pgvigil.mssql_pc_read (instance_id, snapshot_at, interval_secs, statements, capped)
      SELECT $IID_BIG, t, 300, CASE WHEN t = to_timestamp($NOW) THEN 3001 ELSE 3000 END, false
        FROM generate_series(to_timestamp($NOW) - interval '7 days' + interval '5 minutes', to_timestamp($NOW), interval '5 minutes') t" >/dev/null
NB=$(pq "SELECT coalesce(sum(statements), 0) FROM pgvigil.mssql_pc_read WHERE instance_id = $IID_BIG AND snapshot_at > '$BF' AND snapshot_at <= '$BT'")
[[ "$NB" == 6048001 ]] || fail "H: the refusal's seed holds $NB stored samples over $BF .. $BT (want 6,048,001: the ceiling and one)"
c=$(curl -s --max-time 30 -o "$TMPD/hbig.json" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/plancache?instance=$IID_BIG&from=$BF&to=$BT&part=heatmap") || true
WANT_BIG="this range holds about $(python3 -c 'import sys; print(f"{int(sys.argv[1]) / 1e6:.2f}")' "$NB") million stored plan-cache samples; the heatmap reads at most about 6 million: pick a shorter range"
[[ "$c" == 400 && "$(jq -r '.error // empty' "$TMPD/hbig.json" 2>/dev/null)" == "$WANT_BIG" ]] \
  || fail "H: $NB stored samples over 7 days answered $c '$(head -c 300 "$TMPD/hbig.json" 2>/dev/null)' (want 400 '$WANT_BIG')"
(( NB == 2016 * 3000 + 1 && N3 == 2016 * 3000 )) || fail "H: the seeds are not the ceiling and the ceiling and one (past it $NB, at it $N3)"
echo "ok   H: a2 - $NB stored samples over 7 days (the ceiling and one) answered 400 '$WANT_BIG'; H2's timed window at 3,000 a read ($H3F .. $H3T) holds exactly the ceiling, $N3, and answered 200 in each of its eight runs"
# H5. the 1,000-cell cut (a4 / b5): every bucket of every 70-minute bin of 7 days holds a query (a sample every 10
# minutes, one per bucket, and one just inside the window's start) but the top bucket of the newest bin: bins are kept
# newest first while their cells add up to 1,000 or fewer - 6 + 142 x 7 = exactly 1,000 in 143 whole bins (the edge
# itself), the oldest left out, counted and their end named; H1's 24 h fits (no bin cut)
IID_CUT=$(pq "SELECT pgvigil.ensure_instance('pgvq-cut', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
NOW=$(date -u +%s); CF=$(iso $((NOW - 604800))); CT=$(iso "$NOW")   # one clock read
pq "INSERT INTO pgvigil.mssql_pc_sample (instance_id, snapshot_at, database_id, query_key, database_name, executions, cpu_us, duration_us,
      logical_reads, physical_reads, logical_writes, row_count, spills, plans, interval_secs)
    SELECT $IID_CUT, t, 5, '0xc' || lpad(k::text, 15, '0'), 'db5', 1, 5 * 10 ^ (k + 2), 5 * 10 ^ (k + 2), 0, 0, 0, 1, 0, 1, 300
      FROM (SELECT to_timestamp($NOW - n * 600) AS t FROM generate_series(0, 1007) n UNION ALL SELECT to_timestamp($NOW - 604799)) x,
           generate_series(0, 6) k
     WHERE NOT (k = 6 AND floor(extract(epoch FROM t) / 4200) = $NOW / 4200)" >/dev/null
NBINS=$(pq "SELECT count(DISTINCT floor(extract(epoch FROM snapshot_at) / 4200)) FROM pgvigil.mssql_pc_sample WHERE instance_id = $IID_CUT AND snapshot_at > '$CF' AND snapshot_at <= '$CT'")
api "mssql/plancache?instance=$IID_CUT&from=$CF&to=$CT&part=heatmap&metric=duration" hcut.json
python3 - "$TMPD/hcut.json" "$TMPD/h-duration.json" "$NBINS" "$NOW" <<'PYCUT' || fail "H: the 1,000-cell cut (above)"
import sys, json
from datetime import datetime
j = json.load(open(sys.argv[1]))['heatmap']; rows = [dict(zip(j['columns'], r)) for r in j['rows']]
nbins, now = int(sys.argv[3]), int(sys.argv[4]); bad = []
bins = sorted({r['time_bin'] for r in rows})
per = {b: sum(1 for r in rows if r['time_bin'] == b) for b in bins}
keep = 143   # 6 + 142 x 7 = 1,000
if len(rows) != 1000 or len(bins) != keep or [per[b] for b in bins] != [7] * (keep - 1) + [6]:
    bad.append(f'{len(rows)} cells in {len(bins)} bins, per bin {sorted(set(per.values()))}, the newest {per[bins[-1]] if bins else None} (want 1,000 in {keep}, 7 each and 6 in the newest)')
r0 = rows[0] if rows else {}
if r0.get('n_cells') != 7 * nbins - 1 or r0.get('bins_cut') != nbins - keep or r0.get('drawn_from') != (bins[0] if bins else None):
    bad.append(f"n_cells {r0.get('n_cells')} bins_cut {r0.get('bins_cut')} drawn_from {r0.get('drawn_from')} (want {7 * nbins - 1}, {nbins - keep}, {bins[0] if bins else None})")
newest = max(int(datetime.fromisoformat(b.replace('Z', '+00:00')).timestamp()) for b in bins) if bins else 0
if newest != now // 4200 * 4200: bad.append(f'the newest bin kept {newest}, want {now // 4200 * 4200}')
f = json.load(open(sys.argv[2]))['heatmap']; fr = [dict(zip(f['columns'], r)) for r in f['rows']]
if not fr or fr[0]['bins_cut'] != 0 or fr[0]['n_cells'] != len(fr): bad.append(f"H1's 24 h: bins_cut {fr[0]['bins_cut'] if fr else None}, n_cells {fr[0]['n_cells'] if fr else None} of {len(fr)} rows (want 0, all)")
if bad: print('DIFF', bad); sys.exit(1)
print(f"H cut: {len(rows)} cells in {len(bins)} whole bins of {nbins}, n_cells {r0['n_cells']}, bins_cut {r0['bins_cut']}, drawn from {r0['drawn_from']}; H1's 24 h: {len(fr)} cells, none cut")
PYCUT
echo "ok   H: a4 / b5 - every bucket of all $NBINS bins of 7 days held a query but the newest bin's top one: 143 whole bins (exactly 1,000 cells, the newest first: the 1,000 edge kept), n_cells $((NBINS * 7 - 1)), $((NBINS - 143)) bins left out and counted, drawn_from the oldest kept; H1's 24 h fits whole (bins_cut 0)"
# H3. one query's history (plan cache) and one procedure's history: their executions = a hand sum; 7 days timed
NOW=$(date -u +%s); F7=$(iso $((NOW - 604800))); T7=$(iso "$NOW")   # one clock read
# (the procedures' seed is F's: 1,000 a read, 14 days)
TY=""
for spec in 761 3000; do
  eval "IID=\$IID_$spec"
  read -r KDB KEY <<<"$(pq "SELECT database_id, query_key FROM pgvigil.mssql_pc_sample WHERE instance_id = $IID AND snapshot_at > now() - interval '1 hour' ORDER BY executions DESC, query_key LIMIT 1" | tr '|' ' ')"
  for run in 1 2 3 4 5 6 7 8; do
    tt=$(curl -s --max-time 30 -o "$TMPD/y1.json" -w '%{http_code} %{time_total}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/plancache?instance=$IID&from=$F7&to=$T7&db_id=$KDB&key=$KEY&part=history")
    [[ "${tt%% *}" == 200 ]] || fail "H: the plan cache history at $spec answered ${tt%% *}: $(head -c 300 "$TMPD/y1.json")"
    python3 -c "import sys; sys.exit(0 if float('${tt##* }') < 10 else 1)" || HSLOW+=" history/query/$spec:${tt##* }"
    TY+=" query/$spec:${tt##* }"
  done
  hand=$(pq "SELECT coalesce(sum(executions), 0) FROM pgvigil.mssql_pc_sample WHERE instance_id = $IID AND database_id = $KDB AND query_key = '$KEY' AND snapshot_at > '$F7' AND snapshot_at <= '$T7'")
  got=$(jq '[.history.columns as $c | .history.rows[] | [$c, .] | transpose | map({(.[0]): .[1]}) | add | .executions] | add' "$TMPD/y1.json")
  [[ "$got" == "$hand" ]] || fail "H: the plan cache history of $KEY at $spec sums $got executions, the hand $hand"
  steps=$(jq '.history.rows | length' "$TMPD/y1.json"); [[ $steps -ge 100 && $steps -le 130 ]] || fail "H: the history has $steps steps (about 120 wanted)"
done
for run in 1 2 3 4 5 6 7 8; do
  tt=$(curl -s --max-time 30 -o "$TMPD/y2.json" -w '%{http_code} %{time_total}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/procs?instance=$PRI&from=$F7&to=$T7&db_id=6&object=1001&part=history")
  [[ "${tt%% *}" == 200 ]] || fail "H: the procedure history answered ${tt%% *}: $(head -c 300 "$TMPD/y2.json")"
  python3 -c "import sys; sys.exit(0 if float('${tt##* }') < 10 else 1)" || HSLOW+=" history/procedure:${tt##* }"
  TY+=" procedure:${tt##* }"
done
[[ -z "$HSLOW" ]] || fail "H: past the 10 s line:$HSLOW (every timing above; $(ld))"
[[ -z "$HEMPTY" ]] || fail "H: a timed heatmap read held no cell:$HEMPTY"
echo "ok   H: every heatmap and history timing under 10 s (at 3,000 rows a read over 7 days the median of the eight, $HMED s), each heatmap read with cells (above)"
hand=$(pq "SELECT sum(executions) FROM pgvigil.mssql_proc_sample WHERE instance_id = $PRI AND database_id = 6 AND object_id = 1001 AND snapshot_at > '$F7' AND snapshot_at <= '$T7'")
python3 - "$TMPD/y2.json" "$hand" <<'PYEND' || fail "H: the procedure history (above)"
import sys, json
j = json.load(open(sys.argv[1]))['history']; rows = [dict(zip(j['columns'], r)) for r in j['rows']]
got = sum(r['executions'] for r in rows)
if got != int(sys.argv[2]): print(f"DIFF executions {got}, the hand {sys.argv[2]}"); sys.exit(1)
# the seed's duration is 1 ms and its CPU 0.7 ms per execution: every step that ran says so, in each metric's terms
for r in rows:
    if r['executions'] and (float(r['avg_duration_ms']) != 1 or float(r['avg_cpu_ms']) != 0.7
                            or abs(float(r['duration_ms_s']) - float(r['executions_s'])) > 0.002):
        print('DIFF step', r); sys.exit(1)
print(f"H procedure history: {len(rows)} steps, {got} executions = the hand sum; Avg Duration 1 ms, Avg CPU 0.7 ms, Duration (ms/s) = Executions (per second) at 1 ms each")
PYEND
echo "ok   H: the histories' executions = the hand sums (one query at 761 and 3,000 rows a read, one procedure of 1,000 a read), 7 days through the API (s, eight runs each, $(ld)):$TY"
# H4. the Query Store overhead and memory clerk on synthetic reads: one an hour of one-minute wait reads, QDS_STMT
# 100 ms and 2 tasks in each, QDS_DB_DISK 50 ms in 30 of them, two of PerformanceMonitor's sleep waits and a
# PAGEIOLATCH_SH left out; three clerk reads, MEMORYCLERK_QUERYDISKSTORE 2 MB then 4 MB, then out of the top 25
OVI=$(pq "SELECT pgvigil.ensure_instance('pgvq-tov', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
pq "SELECT pgvigil.ensure_month_partition('mssql_wait_sample', now() - interval '2 hours'), pgvigil.ensure_month_partition('mssql_wait_sample', now()),
           pgvigil.ensure_month_partition('mssql_memory_clerk', now() - interval '2 hours'), pgvigil.ensure_month_partition('mssql_memory_clerk', now())" >/dev/null
pq "INSERT INTO pgvigil.mssql_wait_sample (instance_id, snapshot_at, wait_type, category, is_benign, waiting_tasks, wait_ms, signal_ms, interval_secs)
    SELECT $OVI, t, w, 'Other', w LIKE '%SLEEP' OR w = 'QDS_ASYNC_QUEUE', CASE w WHEN 'QDS_STMT' THEN 2 ELSE 1 END,
           CASE w WHEN 'QDS_STMT' THEN 100 WHEN 'QDS_DB_DISK' THEN 50 ELSE 60000 END, 0, 60
      FROM generate_series(date_trunc('minute', now()) - interval '59 minutes', date_trunc('minute', now()), interval '1 minute') WITH ORDINALITY g(t, n),
           unnest(ARRAY['QDS_STMT', 'QDS_DB_DISK', 'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', 'QDS_ASYNC_QUEUE', 'PAGEIOLATCH_SH']) w
     WHERE w <> 'QDS_DB_DISK' OR n % 2 = 0" >/dev/null
pq "INSERT INTO pgvigil.mssql_memory_clerk (instance_id, snapshot_at, clerk_type, pages_kb)
    VALUES ($OVI, date_trunc('minute', now()) - interval '50 minutes', 'MEMORYCLERK_QUERYDISKSTORE', 2048), ($OVI, date_trunc('minute', now()) - interval '50 minutes', 'MEMORYCLERK_SQLBUFFERPOOL', 900000),
           ($OVI, date_trunc('minute', now()) - interval '30 minutes', 'MEMORYCLERK_QUERYDISKSTORE', 4096), ($OVI, date_trunc('minute', now()) - interval '30 minutes', 'MEMORYCLERK_SQLBUFFERPOOL', 900000),
           ($OVI, date_trunc('minute', now()) - interval '10 minutes', 'MEMORYCLERK_SQLBUFFERPOOL', 900000)" >/dev/null
OF=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ); OT=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)
api "mssql/querystore?instance=$OVI&from=$OF&to=$OT&part=overhead" ov.json
api "mssql/querystore?instance=$OVI&from=$OF&to=$OT&part=qs_memory" om.json
python3 - "$TMPD" <<'PYEND' || fail "H: the Query Store overhead (above)"
import sys, json
d = sys.argv[1]
def objs(f, p):
    j = json.load(open(f"{d}/{f}"))[p]; return [dict(zip(j['columns'], r)) for r in j['rows']]
ov = {r['wait_type']: r for r in objs('ov.json', 'overhead')}
bad = []
if set(ov) != {'QDS_STMT', 'QDS_DB_DISK'}: bad.append(f"types {sorted(ov)}")
s = ov.get('QDS_STMT', {}); k = ov.get('QDS_DB_DISK', {})
if (s.get('wait_ms'), s.get('waiting_tasks'), s.get('rows'), float(s.get('measured_secs') or 0), float(s.get('wait_ms_per_hour') or 0)) != (6000, 120, 60, 3600.0, 6000.0): bad.append(f"QDS_STMT {s}")
if (k.get('wait_ms'), k.get('rows'), float(k.get('wait_ms_per_hour') or 0)) != (1500, 30, 1500.0): bad.append(f"QDS_DB_DISK {k}")
m = objs('om.json', 'qs_memory')[0]
if (m['captures'], m['clerk_samples'], float(m['latest_mb']), float(m['max_mb'])) != (3, 2, 4.0, 4.0) or m['latest_clerk_capture'] == m['latest_capture']: bad.append(f"clerk {m}")
for b in bad: print('DIFF', b)
sys.exit(1 if bad else 0)
PYEND
echo "ok   H: the overhead lists QDS_STMT (6,000 ms, 120 tasks, 60 rows, 3,600 measured s, 6,000 ms an hour) and QDS_DB_DISK (1,500 ms an hour over the same measured time), not the sleep waits nor PAGEIOLATCH_SH; the clerk: 3 captures, in 2, 4 MB latest and max, not in the newest capture"

echo "== G. the pages in headless Chromium =="
CDP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
setsid chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu --window-size=1600,1100 about:blank >"$TMPD/chrome.log" 2>&1 & CHRPID=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "G: chromium's CDP port never answered"
cat > "$TMPD/g.mjs" <<'JS'
// prints one JSON line per page; the shell grades them
const [port, U, sb, qf, qt, pf, pt] = process.argv.slice(2);
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise }); if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300)); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const settled = async () => { for (let i = 0; i < 150; i++) { const ok = await ev(`(() => { const m = document.querySelector('main'); return !!m && !!m.querySelector('h2') && ![...m.querySelectorAll('p')].some(p => p.textContent === 'Reading...'); })()`); if (ok) { await sleep(800); return true; } await sleep(200); } return false; };
// each page a full load (about:blank first): a hash change alone keeps the app as it loaded, signed out before the
// login below (proof-darling-cpu.sh does the same)
const go = async (hash) => { await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200); await cmd('Page.navigate', { url: U + hash }); await sleep(300); return settled(); };
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
const st = await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(process.env.G_USR)}, password: ${JSON.stringify(process.env.G_UPW)} }) }).then(r => r.status)`, true);
console.log(`login ${st}`);
await ev(`(() => { for (const k of ['querystore', 'plancache', 'procs']) sessionStorage.setItem('pgvigil.mssql.compare.' + k, 'prev'); localStorage.setItem('pgvigil.theme', 'light'); return 'ok'; })()`);
const qw = `i=${sb}&from=${encodeURIComponent(qf)}&to=${encodeURIComponent(qt)}`, pw = `i=${sb}&from=${encodeURIComponent(pf)}&to=${encodeURIComponent(pt)}`;
const pages = { top: `#/mssqlqs?${qw}&qdb=pgvq`, regressed: `#/mssqlqs?${qw}&qdb=pgvq&qs=regressed&qb=prev`, plancache: `#/mssqlplancache?${pw}`, procs: `#/mssqlprocs?${pw}` };
for (const [name, hash] of Object.entries(pages)) {
  if (!await go(hash) || await ev(`!!document.querySelector('form.login')`)) { console.log(`FAIL render ${name}`); continue; }
  await sleep(1500);   // the compare section reads by itself
  const s = await ev(`(() => { const m = document.querySelector('main');
    const sec = m.querySelector('section.compare');
    const grids = sec ? [...sec.querySelectorAll('table')].filter(t => !t.classList.contains('u-legend')) : [];
    const heads = [...m.querySelectorAll('th')].map(th => th.textContent.trim());
    return JSON.stringify({ errors: m.querySelectorAll('.error:not([role=status])').length, compare: !!sec, compareRows: grids.length ? grids[0].querySelectorAll('tbody tr').length : -1,
      compareText: sec ? sec.textContent.slice(0, 200) : '', heads: heads.filter(h => /[Ss]pilled|cached now|Timeouts|Errors|Why|Severity|new \\/ gone/.test(h)),
      rows: [...m.querySelectorAll('tbody tr')].length, title: m.querySelector('h2')?.textContent ?? '',
      regRows: (() => { const t = [...m.querySelectorAll('table')].find(x => [...x.querySelectorAll('th')].some(th => th.textContent.trim() === 'Severity')); return t ? t.querySelectorAll('tbody tr').length : -1; })() }); })()`);
  console.log(`page ${name} ${s}`);
}
ws.close(); process.exit(0);
JS
QF=$M2; QT=$M4
out=$(G_USR="$USR" G_UPW="$UPW" node "$TMPD/g.mjs" "$CDP" "$U/" "$SB" "$QF" "$QT" "$R1P" "$R2P") || fail "G: the Chromium walk stopped: $out"
echo "$out" | sed 's/^/  /'; printf '%s\n' "$out" > "$TMPD/g.out"
python3 - "$TMPD" <<'PYEND' || fail "G: see above"
import sys, json
d = sys.argv[1]
out = open(f"{d}/g.out").read()
def n(f, part):
    return len((json.load(open(f"{d}/{f}")).get(part) or {}).get('rows') or [])
want = {'top': ('cmp.json', None), 'plancache': ('ccmp.json', 'cached now'), 'procs': ('pcmp.json', 'spilled pages'), 'regressed': (None, 'Timeouts')}
bad = []
pages = {l.split(' ', 2)[1]: json.loads(l.split(' ', 2)[2]) for l in out.splitlines() if l.startswith('page ')}
if not out.startswith('login 200'): bad.append('G login')
for name, (f, head) in want.items():
    p = pages.get(name)
    if not p: bad.append(f"G {name} not drawn"); continue
    if p['errors']: bad.append(f"G {name}: {p['errors']} error box(es)")
    if f and p['compareRows'] != n(f, 'compare'): bad.append(f"G {name}: the compare grid {p['compareRows']} rows, the API {n(f, 'compare')}")
    if head and not any(head in h for h in p['heads']): bad.append(f"G {name}: no column '{head}' ({p['heads']})")
    if name == 'regressed' and p['regRows'] != n('reg.json', 'regressed'): bad.append(f"G regressed: the grid {p['regRows']} rows, the API {n('reg.json', 'regressed')}")
for b in bad: print('DIFF', b)
sys.exit(1 if bad else 0)
PYEND
echo "ok   G: Top's compare grid, Plan cache's and Procedures' compare grids = the API's rows; their new columns and Regressed's PerformanceMonitor columns drawn; no error box"
echo "== I. DONE-2's pages in headless Chromium: the Queries page, the strips, the histories, the wait filter; light and dark =="
SHOTS=${PGVIGIL_SHOTS:-$TMPD/shots}; mkdir -p "$SHOTS"
# two requests on two waits while two Running reads and two wait reads are taken (the strip's bars, the wait filter):
# one holds a row lock and waits on WAITFOR, one waits on that lock for a shared one (LCK_M_S); wait=WAITFOR must keep
# the first alone
sqok "I: the lock table" "IF OBJECT_ID('dbo.i_lock') IS NULL CREATE TABLE dbo.i_lock (id int NOT NULL PRIMARY KEY, v int NOT NULL); DELETE dbo.i_lock; INSERT dbo.i_lock VALUES (1, 0);" pgvq
( sq "BEGIN TRAN; UPDATE dbo.i_lock SET v = v + 1 WHERE id = 1; WAITFOR DELAY '00:00:45'; ROLLBACK;" pgvq 90 >/dev/null 2>&1 ) & BG+=($!)
sleep 1
( sq "SELECT v FROM dbo.i_lock WITH (READCOMMITTEDLOCK) WHERE id = 1;" pgvq 90 >/dev/null 2>&1 ) & BG+=($!)
# a short WAITFOR ends between the two wait reads, so the Waits page lists WAITFOR (a wait counts when it ends)
sleep 3; col mssql_requests mssql_waits; sqok "I: a short WAITFOR" "WAITFOR DELAY '00:00:02';" pgvq; col mssql_requests mssql_waits
# the page window starts a minute before this run's first plan-cache read, so the plan cache's charts and History hold
# every read the run took however long the earlier steps ran; a chart needs reads in two of its steps (5 minutes at
# least), and the run's earlier reads can all fall in one: one more read here, minutes after the first
col mssql_plancache
IF=$(pq "SELECT to_char((date_trunc('minute', min(snapshot_at)) - interval '1 minute') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:00\"Z\"') FROM pgvigil.mssql_pc_read WHERE instance_id = $SB")
IT=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:00Z)
[[ "$IF" =~ ^20[0-9-]+T[0-9:]+Z$ ]] || fail "I: no plan-cache read of this run to anchor the page window ('$IF')"
NPS=$(pq "SELECT count(DISTINCT floor(extract(epoch FROM snapshot_at) / 300)) FROM pgvigil.mssql_pc_read WHERE instance_id = $SB AND snapshot_at > '$IF' AND snapshot_at <= '$IT'")
[[ "$NPS" -ge 2 ]] || fail "I: the page window $IF .. $IT holds plan-cache reads in $NPS five-minute step(s); a chart needs two"
echo "     I: the page window $IF .. $IT: plan-cache reads in $NPS five-minute steps"
IW="instance=$SB&from=$IF&to=$IT"
api "mssql/running?$IW" i-run.json
api "mssql/plancache?$IW&part=top" i-top.json
api "mssql/querystore?$IW&view=top" i-qs.json
api "mssql/querystore?$IW&view=regressed&base=7d" i-reg.json
api "mssql/xe?$IW&part=slow_shapes" i-long.json
api "mssql/querystore?$IW&view=tuning" i-tun.json
api "mssql/plancache?$IW&part=heatmap&metric=duration" i-heat.json
WAITED=$(jq -r '.rows.columns as $c | [(.rows.rows // [])[] | [$c, .] | transpose | map({(.[0]): .[1]}) | add | .wait_type // empty] | map(select(. == "WAITFOR")) | length' "$TMPD/i-run.json")
NRUN=$(jq '(.rows.rows // []) | length' "$TMPD/i-run.json")
NLCK=$(jq -r '.rows.columns as $c | [(.rows.rows // [])[] | [$c, .] | transpose | map({(.[0]): .[1]}) | add | .wait_type // empty] | map(select(. == "LCK_M_S")) | length' "$TMPD/i-run.json")
[[ "$WAITED" -ge 1 && "$NLCK" -ge 1 && "$NRUN" -gt "$WAITED" ]] \
  || fail "I: the newest Running snapshot holds $NRUN request(s), $WAITED on WAITFOR, $NLCK on LCK_M_S (the wait filter's case needs both)"
echo "     I: the newest Running snapshot: $NRUN requests, $WAITED waiting on WAITFOR, $NLCK on LCK_M_S"
cat > "$TMPD/i.mjs" <<'JS'
const [port, U, sb, from, to, shots, mode, hf, ht, hi] = process.argv.slice(2);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
// cmd: one CDP call, 30 s at most (a native dialog or a hung renderer would hold it for good): past it the walk stops
// naming the method
const cmd = (method, params = {}) => new Promise((r, j) => { const i = ++id;
  const t = setTimeout(() => { wait.delete(i); j(new Error(`CDP ${method} did not answer within 30 s`)); }, 30000);
  wait.set(i, d => { clearTimeout(t); r(d); }); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise }); if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300)); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
// poll: a page expression read every 100 ms till true, `limit` ms at most; past it the line 'WAITED <what> <ms>' (the
// row that needed it then fails on its own check, the line names why)
const poll = async (what, expr, limit = 10000) => { const t0 = Date.now(); while (Date.now() - t0 < limit) { if (await ev(expr)) return true; await sleep(100); } console.log(`WAITED ${what} ${limit}`); return false; };
const settled = async () => { for (let i = 0; i < 150; i++) { const ok = await ev(`(() => { const m = document.querySelector('main'); return !!m && !!m.querySelector('h2') && ![...m.querySelectorAll('p')].some(p => /^Reading/.test(p.textContent) && !p.closest('.queries-part')); })()`); if (ok) { await sleep(800); return true; } await sleep(200); } return false; };
const go = async (hash) => { await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200); await cmd('Page.navigate', { url: U + hash }); await sleep(300); return settled(); };
// must: go(), a page that does not settle printed as a FAIL line (the grade fails on it)
const must = async (hash) => { const ok = await go(hash); if (!ok) console.log(`FAIL render ${hash.slice(0, 120)}`); return ok; };
const shot = async (name) => { const d = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }); fs.writeFileSync(`${shots}/${name}.png`, Buffer.from(d.result.data, 'base64')); };
// every section of the Queries page scrolled into view, then read till none says 'Reading' (40 s at most)
const allParts = async (limit = 40000) => {
  await ev(`(async () => { for (const s of document.querySelectorAll('.queries-part')) { s.scrollIntoView(); await new Promise(r => setTimeout(r, 150)); } window.scrollTo(0, 0); return 'ok'; })()`, true);
  let done = false;
  for (let t = 0; t < limit; t += 500) { const busy = await ev(`[...document.querySelectorAll('.queries-part')].some(s => /^Reading|comes into view/.test(s.querySelector('.queries-body')?.textContent ?? ''))`); if (!busy) { done = true; break; } await sleep(500); }
  if (!done) console.log(`WAITED allParts ${limit}`);
  await sleep(600);
};
// CELLS: the drawn heatmap cells under an element, as [bin start ms, bucket, queries]
const CELLS = `(h => [...h.querySelectorAll('.heatmap-cell[data-n]')].map(c => [Number(c.dataset.t), Number(c.dataset.b), Number(c.dataset.n)]))`;
// parts: each section's head rows by column label (a cell's button label, else its full text, else its words) and the
// heatmap's drawn cells
const parts = () => ev(`JSON.stringify([...document.querySelectorAll('.queries-part')].map(s => { const t = [...s.querySelectorAll('table')].filter(x => !x.classList.contains('u-legend'));
  const trs = t.length ? [...t[0].querySelectorAll('tbody tr')].filter(tr => !tr.querySelector('.empty')) : [];
  const heads = t.length ? [...t[0].querySelectorAll('thead th .th-label')].map(x => x.textContent.trim()) : [];
  const keys = trs.map(tr => Object.fromEntries([...tr.children].map((td, i) => [heads[i] ?? String(i),
    (td.querySelector('button[aria-label]')?.getAttribute('aria-label') ?? td.querySelector('[data-full]')?.getAttribute('data-full') ?? td.textContent ?? '').replace(/\\s+/g, ' ').trim().slice(0, 80)])));
  return { part: s.dataset.part, errors: s.querySelectorAll('.error:not([role=status])').length, rows: t.length ? trs.length : -1, keys,
    charts: s.querySelectorAll('.uplot').length, strips: s.querySelectorAll('.strip-band').length, cells: s.querySelectorAll('.heatmap-cell[data-n]').length, heat: ${CELLS}(s),
    text: (s.querySelector('.queries-body')?.textContent ?? '').slice(0, 160) }; }))`).then(JSON.parse);
const state = () => ev(`(() => { const m = document.querySelector('main');
  return JSON.stringify({ hash: location.hash, title: m.querySelector('h2')?.textContent ?? '', errors: m.querySelectorAll('.error:not([role=status])').length,
    links: [...m.querySelectorAll('a[href]')].map(a => ({ t: a.textContent.trim().slice(0, 60), h: a.getAttribute('href') })), controls: [...m.querySelectorAll('input, button, select')].length }); })()`).then(JSON.parse);
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
const st = await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(process.env.G_USR)}, password: ${JSON.stringify(process.env.G_UPW)} }) }).then(r => r.status)`, true);
console.log(`login ${st}`);
const w = `i=${sb}&from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`;
if (mode === 'heat') {
  // the heatmap section alone, settled: the refusal's words, the cut note, its drawn cells
  await ev(`localStorage.setItem('pgvigil.theme', 'light'); 'ok'`);
  await must(`#/mssqlqueries?i=${hi}&from=${encodeURIComponent(hf)}&to=${encodeURIComponent(ht)}`);
  await ev(`(() => { document.querySelector('[data-part=heatmap]').scrollIntoView(); return 'ok'; })()`);
  await poll('the heatmap section read', `!/Reading|comes into view/.test(document.querySelector('[data-part=heatmap] .queries-body')?.textContent ?? 'Reading')`, 60000);
  // first: the oldest column drawn (every cell, a 'no query' one too, carries its bin's start): a cut picture starts at drawn_from
  const hs = await ev(`(() => { const h = document.querySelector('[data-part=heatmap]'); const all = [...h.querySelectorAll('.heatmap-cell')].map(c => Number(c.dataset.t));
    return JSON.stringify({ many: h.querySelector('.heatmap-too-many')?.textContent ?? null,
    cut: h.querySelector('.heatmap-cut')?.textContent ?? null, errors: h.querySelectorAll('.error:not([role=status])').length, cells: h.querySelectorAll('.heatmap-cell[data-n]').length,
    first: all.length ? Math.min(...all) : null, drawn: ${CELLS}(h) }); })()`);
  await shot(`d10-heatmap-${hi}`);
  console.log(`heat ${hs}`);
  ws.close(); process.exit(0);
}
if (mode === 'slow') {
  // the heatmap's read held past the UI pool's 15 s statement timeout (the caller's view over mssql_pc_sample sleeps
  // 20 s): wait while the section has not started ('comes into view') or still reads, 60 s at most (the page's other
  // sections time out too and hold the pool's 8 connections up to 15 s each before the heatmap's read starts)
  await ev(`localStorage.setItem('pgvigil.theme', 'light'); 'ok'`);
  await must(`#/mssqlqueries?i=${hi}&from=${encodeURIComponent(hf)}&to=${encodeURIComponent(ht)}`);
  const t0 = Date.now();
  await ev(`(() => { document.querySelector('[data-part=heatmap]').scrollIntoView(); return 'ok'; })()`);
  let s = '';
  for (let t = 0; t < 60000; t += 500) { s = await ev(`(() => { const h = document.querySelector('[data-part=heatmap] .queries-body'); return h ? h.textContent : ''; })()`); if (!/Reading|comes into view/.test(s)) break; await sleep(500); }
  const ms = Date.now() - t0;
  const hs = await ev(`(() => { const h = document.querySelector('[data-part=heatmap]'); return JSON.stringify({ line: h.querySelector('.heatmap-too-long')?.textContent ?? null, errors: h.querySelectorAll('.error').length,
    tables: h.querySelectorAll('table').length, cells: h.querySelectorAll('.heatmap-cell').length, text: (h.querySelector('.queries-body')?.textContent ?? '').slice(0, 200) }); })()`);
  console.log(`slow ${JSON.stringify({ ...JSON.parse(hs), ms })}`);
  ws.close(); process.exit(0);
}
const pages = { queries: `#/mssqlqueries?${w}`, qs: `#/mssqlqs?${w}&qdb=pgvq`, plancache: `#/mssqlplancache?${w}`, procs: `#/mssqlprocs?${w}`, running: `#/mssql_running?${w}`, waits: `#/mssql_waits?${w}` };
for (const theme of ['light', 'dark']) {
  await go('#/about');
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  for (const [name, hash] of Object.entries(pages)) {
    if (!await go(hash) || await ev(`!!document.querySelector('form.login')`)) { console.log(`FAIL render ${name} ${theme}`); continue; }
    if (name === 'queries') { await allParts(); console.log(`parts ${theme} ${JSON.stringify(await parts())}`); }
    const s = await state();
    console.log(`page ${name} ${theme} ${JSON.stringify({ title: s.title, errors: s.errors, strips: await ev(`document.querySelectorAll('main .strip-band').length`) })}`);
    await shot(`d10-${name}-${theme}`);
  }
}
await ev(`localStorage.setItem('pgvigil.theme', 'light'); 'ok'`);
await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
const kbd = (sel, keys) => ev(`(async () => { const b = document.querySelector(${JSON.stringify(sel)}); if (!b) return 'no band'; b.focus();
  for (const k of ${JSON.stringify(keys)}) { b.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true })); await new Promise(r => setTimeout(r, 100)); } return 'ok'; })()`, true);
// the Query Store strip: Draw puts a query's line on it (clicked on the whole range's grid: the strip's first step can
// lie before the store's first interval, and its grid then holds no row and no Draw); Home + Enter then reads the grid
// again for the first step
await must(pages.qs);
const qs0 = await ev(`document.querySelector('main .strip-band') ? 'band' : 'none'`);
let drew = await ev(`(() => { const b = [...document.querySelectorAll('main button')].find(x => x.textContent === 'Draw'); if (!b) return 'no Draw'; b.click(); return 'clicked'; })()`);
if (drew === 'clicked') {
  await poll("Draw's line on the strip", `!!document.querySelector('main svg.strip-overlay polyline')`);
  drew = await ev(`JSON.stringify({ line: !!document.querySelector('main svg.strip-overlay polyline'), note: document.querySelector('main .strip-overlay-note')?.textContent ?? null })`);
}
const k1 = await kbd('main .strip-band', ['Home', 'Enter']);
await poll("the Query Store grid read again for the strip's first step", `[...document.querySelectorAll('main p[role=status]')].some(p => p.textContent.startsWith('The grid holds'))`);
const qs1 = await ev(`JSON.stringify({ said: [...document.querySelectorAll('main p[role=status]')].map(p => p.textContent).find(t => t.startsWith('The grid holds')) ?? null, stretchEmpty: (document.querySelector('main')?.textContent ?? '').includes("No query ran in the store's intervals of this stretch."), errors: document.querySelectorAll('main .error:not([role=status])').length })`);
console.log(`qsstrip ${qs0} ${k1} ${qs1} ${drew}`);
// the plan cache's History
await must(pages.plancache);
const ph = await ev(`(async () => { const b = [...document.querySelectorAll('main button')].find(x => x.textContent === 'History'); if (!b) return 'no History'; b.click();
  for (let i = 0; i < 40; i++) { await new Promise(r => setTimeout(r, 250)); const h = document.querySelector('main .pc-history'); if (h && !/Reading/.test(h.textContent)) break; }
  const h = document.querySelector('main .pc-history'); return JSON.stringify({ chart: !!h.querySelector('.uplot'), text: h.textContent.slice(0, 160), errors: h.querySelectorAll('.error').length }); })()`, true);
console.log(`pchistory ${ph}`);
// a procedure opened: its chart in PerformanceMonitor's metrics, the metric switched, its line on the strip
await must(pages.procs);
let pr = await ev(`(() => { const b = [...document.querySelectorAll('main button[title="This procedure read by read"]')][0]; if (!b) return 'no procedure'; b.click(); return 'clicked'; })()`);
if (pr === 'clicked') {
  const T = `(document.querySelector('main .proc-history')?.querySelector('h3, .chart-title, [class*=title]')?.textContent ?? '').slice(0, 80)`;
  await poll("the procedure's chart and its line on the strip", `!!document.querySelector('main .proc-history .uplot') && !!document.querySelector('main svg.strip-overlay polyline')`);
  const t1 = await ev(T);
  await ev(`(() => { const s = document.querySelector('main .proc-history select'); if (!s) return 'no select'; s.value = 'executions_s'; s.dispatchEvent(new Event('change', { bubbles: true })); return 'ok'; })()`);
  await poll("the procedure's chart drawn again for Executions (per second)", `${T}.includes('Executions (per second)')`);
  pr = await ev(`(() => { const h = document.querySelector('main .proc-history'); if (!h) return 'no chart'; const s = h.querySelector('select');
    return JSON.stringify({ metrics: [...s.options].map(o => o.textContent), before: ${JSON.stringify(t1)}, after: ${T},
      line: !!document.querySelector('main svg.strip-overlay polyline'), errors: document.querySelectorAll('main .error:not([role=status])').length }); })()`);
}
console.log(`prochistory ${pr}`);
// Running: the strip's Home + Enter steps the slider to the first snapshot; the wait filter and its way back
await must(pages.running);
const r0 = await ev(`document.getElementById('mssql-snap')?.value ?? 'none'`);
const k2 = await kbd('main .strip-band', ['Home', 'Enter']);
await poll('the Running slider at the first snapshot', `document.getElementById('mssql-snap')?.value === '0'`);
const r1 = await ev(`document.getElementById('mssql-snap')?.value ?? 'none'`);
console.log(`runstrip ${r0} ${k2} ${r1}`);
// RUNGRID: the grid under 'Sessions and requests': its rows and each row's 'waiting on' cell
const RUNGRID = `(() => { const h = [...document.querySelectorAll('main h3')].find(x => x.textContent.startsWith('Sessions and requests'));
  const t = h ? [...document.querySelectorAll('main table.grid')].find(x => h.compareDocumentPosition(x) & Node.DOCUMENT_POSITION_FOLLOWING) : null;
  if (!t) return { rows: -1, waits: [] };
  const i = [...t.querySelectorAll('thead th .th-label')].findIndex(x => x.textContent.trim() === 'waiting on');
  const trs = [...t.querySelectorAll('tbody tr')].filter(tr => !tr.querySelector('.empty'));
  return { rows: trs.length, waits: trs.map(tr => (i < 0 ? '?' : (tr.children[i]?.textContent ?? '')).replace(/\\s+/g, ' ').trim().slice(0, 40)) }; })()`;
await must(`${pages.running}&wait=WAITFOR`);
const wf = await ev(`JSON.stringify({ line: document.querySelector('main .wait-only')?.textContent ?? null, back: document.querySelector('main .wait-only a')?.getAttribute('href') ?? null, grid: ${RUNGRID} })`);
console.log(`waitfilter ${wf}`);
const back = JSON.parse(wf).back; if (back) { await must(back); console.log(`waitback ${await ev(`JSON.stringify({ hash: location.hash, line: !!document.querySelector('main .wait-only'), grid: ${RUNGRID} })`)}`); }
await must(pages.waits);
const wl = await ev(`[...document.querySelectorAll('main a')].filter(a => a.textContent === 'requests').map(a => a.getAttribute('href')).find(h => h.includes('wait=WAITFOR')) ?? null`);
if (wl) { await must(wl); console.log(`waitlink ${wl} ${await ev(`document.querySelector('main .wait-only')?.textContent ?? 'none'`)}`); } else console.log('waitlink none');
// the heatmap: a cell picked, its 'Show Active Queries at This Time' followed
await must(pages.queries); await allParts();
const hc = JSON.parse(await ev(`(() => { const c = document.querySelector('.heatmap-cell[data-n]'); if (!c) return JSON.stringify({ href: 'no cell' }); c.click();
  const a = [...document.querySelectorAll('.heatmap-detail a')].find(x => x.textContent === 'Show Active Queries at This Time'); return JSON.stringify({ t: Number(c.dataset.t), href: a ? a.getAttribute('href') : 'no link' }); })()`));
if (hc.href.startsWith('#')) { await must(hc.href); console.log(`heatcell ${JSON.stringify({ ...hc, landed: JSON.parse(await ev(`JSON.stringify({ hash: location.hash, title: document.querySelector('main h2')?.textContent ?? '' })`)) })}`); } else console.log(`heatcell ${JSON.stringify(hc)}`);
// the click table: every link and every control of the Queries page, each clicked once, with its landing
await must(pages.queries); await allParts();
const links = (await state()).links; const seen = new Set();
for (const l of links) {
  if (seen.has(l.h)) continue; seen.add(l.h);
  if (!l.h.startsWith('#')) { console.log(`click link queries ${JSON.stringify(l.t)} ${l.h} -> not a page link (not followed)`); continue; }
  const ok = await go(l.h); const r = await state();
  console.log(`click link queries ${JSON.stringify(l.t)} ${l.h} -> ${r.hash.split('&')[0]} title=${JSON.stringify(r.title)} errors=${r.errors} rendered=${ok}`);
}
await must(pages.queries); await allParts();
const n = (await state()).controls;
for (let i = 0; i < n; i++) {
  const what = await ev(`(() => { const c = [...document.querySelector('main').querySelectorAll('input, button, select')][${i}]; if (!c) return null;
    const lab = (c.closest('label')?.textContent || c.getAttribute('aria-label') || c.textContent || c.title || c.id || c.tagName).trim().slice(0, 60);
    const t = c.tagName === 'INPUT' ? c.type : c.tagName.toLowerCase();
    if (t === 'select') { c.selectedIndex = Math.min(c.options.length - 1, 1); c.dispatchEvent(new Event('change', { bubbles: true })); } else { c.click(); }
    return JSON.stringify({ t, lab }); })()`);
  if (!what) { console.log(`click control queries ${i} gone`); continue; }
  await sleep(150);   // the click's own work starts (a hash change renders the next page), then a bounded poll
  await poll(`control ${i} settled`, `!!document.querySelector('main h2') && ![...document.querySelectorAll('main [role=status]')].some(p => /^Reading/.test(p.textContent))`, 5000);
  const dlg = await ev(`(() => { const d = document.querySelector('dialog[open]'); if (d) { d.close(); return true; } return false; })()`);
  const r = await state(); const wv = JSON.parse(what);
  console.log(`click control queries ${i} ${wv.t} ${JSON.stringify(wv.lab)} -> ${r.hash.split('?')[0]} dialog=${dlg} errors=${r.errors}`);
  if (r.hash.split('?')[0] !== pages.queries.split('?')[0]) { await go(pages.queries); await allParts(); }
}
ws.close(); process.exit(0);
JS
out=$(G_USR="$USR" G_UPW="$UPW" timeout 900 node "$TMPD/i.mjs" "$CDP" "$U/" "$SB" "$IF" "$IT" "$SHOTS") || fail "I: the Chromium walk stopped (exit 124 = past its 900 s): $out"
# the heatmap's size on the page: the refusal's words in the heatmap's place (a2), the cut note naming the columns left
# out (a4 / b5), and no note where the cells fit (H1's 24 h at 761 a read)
NOW=$(date -u +%s); FF=$(iso $((NOW - 86400))); FT=$(iso "$NOW")
HPB=$(G_USR="$USR" G_UPW="$UPW" timeout 120 node "$TMPD/i.mjs" "$CDP" "$U/" "$SB" "$IF" "$IT" "$SHOTS" heat "$BF" "$BT" "$IID_BIG") || fail "I: the heatmap walk (a2) stopped: $HPB"
HPC=$(G_USR="$USR" G_UPW="$UPW" timeout 120 node "$TMPD/i.mjs" "$CDP" "$U/" "$SB" "$IF" "$IT" "$SHOTS" heat "$CF" "$CT" "$IID_CUT") || fail "I: the heatmap walk (a4 / b5) stopped: $HPC"
HPF=$(G_USR="$USR" G_UPW="$UPW" timeout 120 node "$TMPD/i.mjs" "$CDP" "$U/" "$SB" "$IF" "$IT" "$SHOTS" heat "$FF" "$FT" "$IID_761") || fail "I: the heatmap walk (fits) stopped: $HPF"
python3 - "$(printf '%s\n' "$HPB" | sed -n 's/^heat //p')" "$(printf '%s\n' "$HPC" | sed -n 's/^heat //p')" "$(printf '%s\n' "$HPF" | sed -n 's/^heat //p')" "$WANT_BIG" "$NBINS" "$TMPD/hcut.json" <<'PYPAGE' || fail "I: the heatmap's size on the page (above)"
import sys, json
from datetime import datetime
b, c, f = (json.loads(x or '{}') for x in sys.argv[1:4]); want, nbins = sys.argv[4], int(sys.argv[5]); bad = []
j = json.load(open(sys.argv[6]))['heatmap']; api = [dict(zip(j['columns'], r)) for r in j['rows']]
ms = lambda t: int(datetime.fromisoformat(str(t).replace('Z', '+00:00')).timestamp() * 1000)
if b.get('many') != want[0].upper() + want[1:] + '.' or b.get('cells') or b.get('errors'): bad.append(f"past the ceiling: { {k: v for k, v in b.items() if k != 'drawn'} }")
cut, left = c.get('cut') or '', nbins - 143
if not cut.startswith(f"The oldest {left} {'column' if left == 1 else 'columns'}, before ") or f'{7 * nbins - 1:,} cells in all, 1,000 at most' not in cut or c.get('cells') != 1000 or c.get('errors'):
    bad.append(f"the cut: { {k: v for k, v in c.items() if k != 'drawn'} }")
# no column of a cut bin drawn, not even empty: the picture's oldest column is drawn_from; its cells = the API's
if not api or c.get('first') != ms(api[0]['drawn_from']): bad.append(f"the cut picture starts at {c.get('first')}, drawn_from {api[0]['drawn_from'] if api else None} = {ms(api[0]['drawn_from']) if api else None}")
want_cells = sorted((ms(r['time_bin']), int(r['bucket']), int(r['queries'])) for r in api)
got_cells = sorted(tuple(int(v) for v in x) for x in (c.get('drawn') or []))
if got_cells != want_cells: bad.append(f'the cut picture: {len(got_cells)} cells, the API {len(want_cells)}; first differing {[x for x in got_cells if x not in set(want_cells)][:2]} / {[x for x in want_cells if x not in set(got_cells)][:2]}')
if f.get('cut') is not None or f.get('many') is not None or not f.get('cells') or f.get('errors'): bad.append(f"fits: { {k: v for k, v in f.items() if k != 'drawn'} }")
if bad: print('DIFF', bad); sys.exit(1)
print(f"I heatmap size: past the ceiling '{b['many']}'; the cut '{cut}', {c['cells']} cells drawn = the API's (time, bucket, queries), the picture from drawn_from {api[0]['drawn_from']}; fits: {f['cells']} cells, no note")
PYPAGE
echo "ok   I: the heatmap's size on the page: the refusal's words in the heatmap's place (no cell, no error box), the cut note naming the $((NBINS - 143)) oldest column(s) and where the drawn part starts, 1,000 cells drawn = the API's cell by cell, no column of a cut bin drawn (not even empty), no note where the cells fit"
printf '%s\n' "$out" > "$TMPD/i.out"; printf '%s\n' "$out" | grep '^click ' > "$SHOTS/d10-click-table.txt" || true
echo "$out" | grep -v '^click ' | sed 's/^/  /'
# the heatmap's read past the UI pool's real 15 s statement timeout: the plain line, no error box, no grid. A lock on
# mssql_pc_sample cannot provoke it (the pool's lock_timeout, 2 s, cancels the lock wait first and the page shows an
# error box), so for this walk only the table is renamed and a view of its name sleeps 20 s once (an InitPlan) before
# it returns the rows; the serve's statements resolve the name at each run (plan_cache_mode, planEach). Put back after.
HF=$(date -u -d '-24 hours' +%Y-%m-%dT%H:%M:00Z); HT=$(date -u +%Y-%m-%dT%H:%M:00Z)
api "mssql/plancache?instance=$IID_761&from=$HF&to=$HT&part=heatmap&metric=duration" i-heat-before.json
HN0=$(jq '.heatmap.rows | length' "$TMPD/i-heat-before.json")
pq "ALTER TABLE pgvigil.mssql_pc_sample RENAME TO mssql_pc_sample_i; CREATE VIEW pgvigil.mssql_pc_sample AS SELECT * FROM pgvigil.mssql_pc_sample_i WHERE (SELECT true FROM pg_sleep(20));" || fail "I: the slow view"
SL0=$(grep -c . "$TMPD/serve.out" || true)
lk=$(G_USR="$USR" G_UPW="$UPW" timeout 120 node "$TMPD/i.mjs" "$CDP" "$U/" "$SB" "$IF" "$IT" "$SHOTS" slow "$HF" "$HT" "$IID_761") || { pq "DROP VIEW IF EXISTS pgvigil.mssql_pc_sample; ALTER TABLE IF EXISTS pgvigil.mssql_pc_sample_i RENAME TO mssql_pc_sample;" || true; fail "I: the slow walk stopped: $lk"; }
pq "DROP VIEW pgvigil.mssql_pc_sample; ALTER TABLE pgvigil.mssql_pc_sample_i RENAME TO mssql_pc_sample;" || fail "I: the table put back"
# the serve's own log names the cause of the heatmap's failed read: the statement timeout, not a lock timeout
HCAUSE=$(tail -n +"$((SL0 + 1))" "$TMPD/serve.out" | grep -E 'api query failed.*mssql/plancache' | grep -oE 'heatmap: ERROR: canceling statement due to [a-z ]+' | sed 's/ *$//' | sort -u | tr '\n' ';' || true)
api "mssql/plancache?instance=$IID_761&from=$HF&to=$HT&part=heatmap&metric=duration" i-heat-back.json
HN1=$(jq '.heatmap.rows | length' "$TMPD/i-heat-back.json")
lk="$lk
slowcause $HCAUSE
slowback $HN0 $HN1"
echo "$lk" | sed 's/^/  /'; printf '%s\n' "$lk" >> "$TMPD/i.out"
python3 - "$TMPD" <<'PYEND' || fail "I: see above"
import sys, json
d = sys.argv[1]
out = open(f"{d}/i.out").read().splitlines()
def n(f, p):
    return len((json.load(open(f"{d}/{f}")).get(p) or {}).get('rows') or [])
bad = []
if 'login 200' not in out: bad.append('I login')
bad += [l for l in out if l.startswith('FAIL')]
want = {'active': min(10, n('i-run.json', 'rows')), 'top': min(10, n('i-top.json', 'top')), 'qs': min(10, n('i-qs.json', 'top')),
        'regressed': min(10, n('i-reg.json', 'regressed')), 'long': min(10, n('i-long.json', 'slow_shapes')), 'tuning': min(10, n('i-tun.json', 'tuning'))}
heat = n('i-heat.json', 'heatmap')
def api_rows(f, p):
    t = json.load(open(f"{d}/{f}")).get(p) or {}
    return [dict(zip(t.get('columns') or [], r)) for r in (t.get('rows') or [])]
def txt(v):
    return '' if v is None else ' '.join(str(v).split())
from datetime import datetime
ms = lambda t: int(datetime.fromisoformat(str(t).replace('Z', '+00:00')).timestamp() * 1000)
# each head row by row: the page's key column against the API's first 10 in order
KEY = {'active': ('i-run.json', 'rows', 'session', lambda r: txt(r['session_id'])),
       'top': ('i-top.json', 'top', 'history', lambda r: f"History of {txt(r['query_key'])}"),
       'qs': ('i-qs.json', 'top', 'query', lambda r: txt(r['query_id'])),
       'regressed': ('i-reg.json', 'regressed', 'Query ID', lambda r: txt(r['query_id'])),
       'long': ('i-long.json', 'slow_shapes', 'statement shape', lambda r: (txt(r['shape']) or '(no statement text stored)')[:80]),
       'tuning': ('i-tun.json', 'tuning', 'query', lambda r: txt(r['query_id']))}
hcells = sorted((ms(r['time_bin']), int(r['bucket']), int(r['queries'])) for r in api_rows('i-heat.json', 'heatmap'))
for theme in ('light', 'dark'):
    line = next((l for l in out if l.startswith(f'parts {theme} ')), None)
    if not line: bad.append(f'no parts line {theme}'); continue
    ps = {p['part']: p for p in json.loads(line.split(' ', 2)[2])}
    order = list(ps)
    if order != ['active', 'duration', 'execs', 'top', 'qs', 'regressed', 'overhead', 'heatmap', 'long', 'tuning']: bad.append(f'{theme} section order {order}')
    for k, v in ps.items():
        if v['errors']: bad.append(f'{theme} {k}: {v["errors"]} error box(es) {v["text"][:100]}')
    for k, wv in want.items():
        got = ps.get(k, {}).get('rows', -9)
        if got != wv and not (wv == 0 and got in (-1, 0)): bad.append(f'{theme} {k}: {got} rows, the API head {wv}')
    for k, (f, p, col, key) in KEY.items():
        want_k = [key(r) for r in api_rows(f, p)[:10]]
        got_k = [r.get(col, '?') for r in ps.get(k, {}).get('keys', [])]
        if got_k != want_k: bad.append(f'{theme} {k} head by rows: the page {got_k[:4]}..., the API {want_k[:4]}...')
    if ps.get('heatmap', {}).get('rows') != heat: bad.append(f"{theme} heatmap: {ps.get('heatmap', {}).get('rows')} table rows, the API {heat} cells")
    if sorted(tuple(int(v) for v in x) for x in ps.get('heatmap', {}).get('heat', [])) != hcells: bad.append(f"{theme} heatmap picture: {len(ps.get('heatmap', {}).get('heat', []))} cells differ from the API's {len(hcells)} (time, bucket, queries)")
    if ps.get('active', {}).get('strips') != 1 or ps.get('qs', {}).get('strips') != 1: bad.append(f'{theme} strips: active {ps.get("active", {}).get("strips")}, qs {ps.get("qs", {}).get("strips")}')
    if ps.get('duration', {}).get('charts', 0) < 1 or ps.get('execs', {}).get('charts', 0) < 1: bad.append(f'{theme} the duration / executions charts')
    for pg in ('qs', 'plancache', 'procs', 'running', 'waits'):
        l = next((x for x in out if x.startswith(f'page {pg} {theme} ')), None)
        if not l or json.loads(l.split(' ', 3)[3])['errors']: bad.append(f'{theme} page {pg}: {l}')
def one(prefix):
    return next((l for l in out if l.startswith(prefix + ' ')), '')
q = one('qsstrip')
if 'band ok' not in q or '"said":"The grid holds' not in q or '"line":true' not in q: bad.append(f'qs strip: {q}')
p = one('pchistory')
if '"chart":true' not in p or '"errors":0' not in p: bad.append(f'plan cache history: {p}')
r = one('prochistory')
if '"Avg Duration (ms)","Avg CPU (ms)","Duration (ms/s)","Executions (per second)"' not in r or '"line":true' not in r or '"errors":0' not in r: bad.append(f'procedure history: {r}')
rs = one('runstrip').split()
if len(rs) != 4 or rs[2] != 'ok' or rs[3] != '0' or rs[1] == '0': bad.append(f'running strip: {rs}')
# the wait filter by what it shows: unfiltered = the API's rows (two waits at least), filtered = its WAITFOR rows alone
run = api_rows('i-run.json', 'rows'); n_all = len(run); n_wf = sum(1 for r in run if r.get('wait_type') == 'WAITFOR')
wf = one('waitfilter'); wfj = json.loads(wf.split(' ', 1)[1]) if wf else {}
if wfj.get('line') != 'Only requests waiting on WAITFOR. Show all active queries': bad.append(f'wait filter: {wf}')
g = wfj.get('grid') or {}
if g.get('rows') != n_wf or not 1 <= n_wf < n_all or any('WAITFOR' not in w for w in g.get('waits') or ['?']): bad.append(f"wait filter rows: {g} (want the API's {n_wf} WAITFOR rows of {n_all}, each on WAITFOR)")
wb = one('waitback'); wbj = json.loads(wb.split(' ', 1)[1]) if wb else {}
if wbj.get('line') is not False or 'wait=' in wbj.get('hash', 'wait='): bad.append(f'wait filter back: {wb}')
g = wbj.get('grid') or {}
if g.get('rows') != n_all or n_all < 2 or all('WAITFOR' in w for w in g.get('waits') or []): bad.append(f"unfiltered rows: {g} (want the API's {n_all}, another wait among them)")
wl = one('waitlink')
if 'Only requests waiting on WAITFOR' not in wl: bad.append(f'the Waits page link: {wl}')
# the cell's link: Running at its bin's middle (PerformanceMonitor's heatmapDrillMs), landed there
hc = one('heatcell'); hcj = json.loads(hc.split(' ', 1)[1]) if hc else {}
import urllib.parse
bin_min = (api_rows('i-heat.json', 'heatmap') or [{}])[0].get('bin_minutes')
at = urllib.parse.parse_qs((hcj.get('href') or '').split('?', 1)[-1]).get('at', [''])[0]
if not str(hcj.get('href', '')).startswith('#/mssql_running') or not str((hcj.get('landed') or {}).get('hash', '')).startswith('#/mssql_running') \
        or not at or not bin_min or ms(at) != hcj.get('t', 0) + int(bin_min) * 30000:
    bad.append(f"heatmap cell: {hc} (want at = the bin's start + half a bin of {bin_min} minutes)")
lk = one('slow')
if lk:
    j = json.loads(lk.split(' ', 1)[1])
    # ms only shows the walk waited (the heatmap's read starts at render, before t0): the cause is the serve log's line below
    if j['line'] != "the heatmap's read took too long for this range: pick 24 hours or less" or j['errors'] or j['tables'] or j['cells'] or j['ms'] < 10000: bad.append(f'slow: {j}')
else: bad.append('no slow line')
sc = one('slowcause')
if sc != 'slowcause heatmap: ERROR: canceling statement due to statement timeout;': bad.append(f'the heatmap read\'s cause in the serve log: {sc!r}')
sb = one('slowback').split()
if len(sb) != 3 or sb[1] != sb[2] or sb[1] in ('0', 'null'): bad.append(f'the heatmap after the table was put back (cells before, after): {sb}')
clicks = [l for l in out if l.startswith('click ')]
cbad = [l for l in clicks if ('errors=0' not in l and 'not followed' not in l and not l.endswith(' gone')) or 'rendered=false' in l]
if not clicks: bad.append('no click table')
bad += [f'click: {l}' for l in cbad]
for w in (l for l in out if l.startswith('WAITED ')): print('NOTE', w)
for b in bad: print('DIFF', b)
print(f"I: {len(clicks)} clicks in the click table; heads by rows: " + ', '.join(f"{k} {min(10, len(api_rows(f, p)))}" for k, (f, p, _, _) in KEY.items())
      + f"; the heatmap {len(hcells)} cells; the wait filter {n_wf} of {n_all}")
sys.exit(1 if bad else 0)
PYEND
echo "ok   I: the Queries page in PerformanceMonitor's section order, each head = its tab's API head row by row in order (Running, Plan cache, Query Store, Regressed; Slow queries and Tuning by the counts printed above, empty when 0), the heatmap's table and picture = the API's cells (time, bucket, queries), light and dark, no error box; the Query Store strip re-reads its grid and draws a query's line; the plan cache's History and a procedure's chart in PerformanceMonitor's four metrics with its line on the strip; Running's strip steps the slider; wait=WAITFOR shows the API's WAITFOR rows alone of the snapshot's requests on two waits, and its way back shows them all; the Waits page's link; a heatmap cell opens Running at its bin's middle; a heatmap read held past the pool's 15 s statement timeout says the plain line (no error box, no grid; the serve log's cause the statement timeout) and reads again once the table is back; $(grep -c . "$SHOTS/d10-click-table.txt") clicks in the click table; shots in $SHOTS"
echo "PROOF OK: D10 DONE-1 and DONE-2"
