#!/usr/bin/env bash
# Proof of the plans (task 40): migration 0029, internal/plans, the EXPLAIN ANALYZE door (internal/actions/explain.go)
# and the Plan page's handlers (internal/web/q_plans.go).
#
#   ADMIN_DSN   a superuser connection to the sandbox server (default: PGVIGIL_REPO_DSN): the proof makes its own
#               repository database there (random suffix), a collector login and two repository instances, and drops
#               them at the end.
#   PLANS_PORT  the port of the monitored server (default 5497).
# The monitored server is a throwaway cluster this proof makes with initdb in a temporary directory (logging_collector
# on, so auto_explain's lines land in a file the proof reads; TCP on localhost only) and removes at the end. initdb
# and pg_ctl of the sandbox's major version must be on PATH, with the auto_explain module installed. Its database
# plansdb holds the seeded shapes of internal/plans/testdata/seed.sql. Nothing that exists before the run is touched.
# The capture from the log goes through internal/plans (FromLogMessage) by the Go test TestDumpRows; the log readers'
# kind 'plan' (task 34) feeding import_plans is the join's. pg_store_plans is not built here: its collector is
# unit-tested on a constructed answer (internal/collect/plans_test.go), not proven live.
#
# Expected (written before the first run):
#  A. auto_explain loaded in one superuser session (LOAD 'auto_explain', log_min_duration 0, log_analyze on) running
#     the filter shape "select * from t40 where v = 1 /* <tag>-text */" with log_format text, then "/* <tag>-json */"
#     with log_format json: the log holds two auto_explain messages with the tags; read through FromLogMessage and
#     imported as the collector login: 2 plans rows of source auto_explain, formats text and json, both analyzed, each
#     with duration_ms > 0, a query holding its tag, datname plansdb, and the one rule 'filter removes most rows'.
#  B. every shape of internal/plans/testdata/shapes.txt as EXPLAIN (ANALYZE) in plansdb (a rolled-back transaction),
#     in text and in JSON, imported (source explain_analyze): the rules of each form are exactly
#       aggspill: spill to disk | clean: (none) | cte: CTE scanned twice | estimate: estimate off by 10x, filter removes
#       most rows | filter: filter removes most rows | hashspill: spill to disk | heapfetch: index-only scan with heap
#       fetches | jit: JIT share, estimate off by 10x | lossy: lossy bitmap heap scan | nestloop: nested loop over a
#       large outer | sortspill: spill to disk | trigger: trigger time | workers: parallel workers not launched
#     (each of the ten rules hit by its shape, the clean plan silent; the text form agreeing with the JSON form);
#     plan_findings for the instance holds the ten rules, one row each, every column filled but suggested's.
#  C. TestPlansProof, the on-demand EXPLAIN (no execution) through a pg_monitor-only login: refused 409 naming
#     pg_read_all_data; after GRANT SELECT ON t40: 200, stored as source explain, not analyzed, no rule hit; a $1 $2
#     statement: 200 with the generic-plan note and $1 in the plan; EXPLAIN of "delete from t40": 200 and t40 keeps
#     its 200000 rows; "select 1; delete from t40": 409.
#     [first run 2026-11-09: the DELETE's EXPLAIN came 409 "permission denied for table t40" - the expectation missed
#      that EXPLAIN checks the statement's own privileges (DELETE), which the read login does not hold; graded since as
#      409 without the grant, then 200 with t40's 200000 rows unchanged after a GRANT DELETE given for that one call
#      and revoked]
#  D. TestPlansProof, EXPLAIN ANALYZE: gate off 409; instance without actions_dsn 409; confirmation "yes" 409; the
#     actions login (NOSUPERUSER, pg_signal_backend) without SELECT 502 naming the privileges; after GRANT SELECT: 200,
#     stored as explain_analyze, analyzed, rule 'filter removes most rows'; a data-modifying CTE 502 "tried to write"
#     with t40's rows unchanged; a DELETE 409; pg_sleep(3) under a 1 s gate timeout 502. actions_log then holds for
#     the door instance done 1 / failed 3 / refused 3 and for the other refused 1, every row action explain_analyze
#     with the statement, the datname, the UI user and a detail, pid NULL.
#     [review 1 fold, expected before the rerun: EXPLAIN ANALYZE runs through a login of its own (explain_dsn: the
#      proof's pgvigil_plexp_<suf>, LOGIN NOSUPERUSER, no role membership), since a read-only transaction does not
#      stop pg_terminate_backend through the cancel / terminate login. D becomes: gate off 409; the instance without
#      explain_dsn 409 "no explain_dsn"; the cancel / terminate login (pg_signal_backend) named as explain_dsn 409
#      "member of pg_signal_backend"; confirmation "yes" 409; the explain login without SELECT 502 naming the
#      privileges; after GRANT SELECT: 200 as before; "select pg_terminate_backend(pid) from pg_stat_activity where
#      pid = <a pg_sleep(20) session of the monitoring login>" 502 with that session still in pg_stat_activity and its
#      sleep running; the writing CTE 502, the DELETE 409, the timeout 502 as before. actions_log: door done 1 /
#      failed 4 / refused 4, nodoor refused 1, the same columns checked]
#  E. rights: pgvigil_collector may EXECUTE import_plans; pgvigil_reader may SELECT plans, plan_rule_hits and
#     plan_findings and EXECUTE plan_rules.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
ADMIN_DSN=${ADMIN_DSN:-$PGVIGIL_REPO_DSN}
PORT=${PLANS_PORT:-5497}
SUF=$RANDOM; TAG=pgvplans$SUF
REPO_DB=pgvigil_plansproof_$SUF; COL=pgvigil_plcol_$SUF; MON=pgvigil_plmon_$SUF; ACT=pgvigil_plact_$SUF; EXP=pgvigil_plexp_$SUF; PW=p$RANDOM$RANDOM
I1=proof-plans-$SUF; I2=proof-plans-nodoor-$SUF
HERE=$(cd "$(dirname "$0")/.." && pwd)
TD=$HERE/internal/plans/testdata
DIR=$(mktemp -d); CFG=$(mktemp)
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  pg_ctl -D "$DIR/data" stop -m fast -s >/dev/null 2>&1 || true
  rm -rf "$DIR" "$CFG"
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" -c "drop role if exists $COL" >/dev/null 2>&1 || true
}
trap cleanup EXIT
command -v initdb >/dev/null && command -v pg_ctl >/dev/null || fail "initdb and pg_ctl must be on PATH"

echo "--- the monitored server: a throwaway cluster on port $PORT"
initdb -D "$DIR/data" -U postgres -A trust >/dev/null 2>&1 || fail "initdb"
cat >> "$DIR/data/postgresql.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = ''
logging_collector = on
log_directory = 'log'
log_line_prefix = '%m [%p] %q%u@%d '
max_worker_processes = 8
EOF
pg_ctl -D "$DIR/data" -l "$DIR/server.out" -w -s start >/dev/null 2>&1 || { tail -5 "$DIR/server.out" >&2; fail "the cluster did not start"; }
SU="host=localhost port=$PORT user=postgres dbname=postgres sslmode=disable"
SUDB="host=localhost port=$PORT user=postgres dbname=plansdb sslmode=disable"
psql "$SU" -XAtq -v ON_ERROR_STOP=1 -c "create database plansdb" \
  -c "create role $MON login password '$PW' in role pg_monitor" \
  -c "create role $ACT login password '$PW' nosuperuser in role pg_signal_backend" \
  -c "create role $EXP login password '$PW' nosuperuser"
psql "$SUDB" -XAtq -v ON_ERROR_STOP=1 -f "$TD/seed.sql" >/dev/null
echo "seeded plansdb: $(psql "$SUDB" -XAt -c "select count(*) from t40") rows in t40"

echo "--- the repository: $REPO_DB"
psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" >/dev/null
export PGVIGIL_REPO_DSN; PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"   # a later keyword wins, in libpq and in pgx
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null
[[ $(q "select count(*) from pgvigil.schema_version where version = '0029_plans.sql'") == 1 ]] || fail "0029 not applied"
HOST=$(q "select coalesce(host(inet_server_addr()),'localhost')"); DBPORT=$(q "select coalesce(inet_server_port()::text, current_setting('port'))")
psql "$ADMIN_DSN" -XAtq -c "create role $COL login password '$PW' in role pgvigil_collector" >/dev/null
COL_DSN="host=$HOST port=$DBPORT user=$COL password=$PW dbname=$REPO_DB sslmode=disable"
q "select pgvigil.ensure_instance('$I1', 'onprem', '18', 180000, false, '{}')" >/dev/null
q "select pgvigil.ensure_instance('$I2', 'onprem', '18', 180000, false, '{}')" >/dev/null
P=$(q "select instance_id from pgvigil.instances where name = '$I1'")
echo "ok: migrate applied 0029; instances $I1 ($P) and $I2"

# dump FILE KIND [SOURCE KEY]: the import_plans payload of FILE through internal/plans (TestDumpRows)
dump() {
  PLANS_DUMP_IN=$1 PLANS_DUMP_OUT=$DIR/payload.json PLANS_DUMP_KIND=$2 PLANS_DUMP_SOURCE=${3:-} PLANS_DUMP_KEY=${4:-} \
    PLANS_DUMP_DB=plansdb PLANS_DUMP_USER=postgres go test -count=1 -run 'TestDumpRows$' "$HERE/internal/plans/" >/dev/null \
    || fail "TestDumpRows on $1"
  echo "select pgvigil.import_plans($P, now(), :'payload'::jsonb);" \
    | psql "$COL_DSN" -XAtq -v ON_ERROR_STOP=1 -v "payload=$(cat "$DIR/payload.json")" >/dev/null || fail "import_plans as the collector login"
}

echo "--- A. auto_explain in a session, the plan captured from the log"
psql "$SUDB" -XAtq -v ON_ERROR_STOP=1 >/dev/null <<EOF
load 'auto_explain';
set auto_explain.log_min_duration = 0;
set auto_explain.log_analyze = on;
set max_parallel_workers_per_gather = 0;
set auto_explain.log_format = text;
select count(*) from (select * from t40 where v = 1 /* $TAG-text */) x;
set auto_explain.log_format = json;
select count(*) from (select * from t40 where v = 1 /* $TAG-json */) x;
EOF
sleep 1
# each auto_explain message: the LOG line's message and its tab-led continuation lines, the two tagged ones kept
awk -v tag="$TAG" '
  function flush() { if (msg != "" && index(msg, tag)) printf "%s\n--8<--\n", msg; msg = "" }
  /LOG:  duration: [0-9.]+ ms  plan:/ { flush(); msg = substr($0, index($0, "LOG:  ") + 6); inm = 1; next }
  inm && /^\t/ { msg = msg "\n" $0; next }
  { flush(); inm = 0 }
  END { flush() }' "$DIR"/data/log/*.log > "$DIR/autoexplain.txt"
[[ $(grep -c -- '--8<--' "$DIR/autoexplain.txt") == 2 ]] || { cat "$DIR"/data/log/*.log | tail -40 >&2; fail "A: the log does not hold the two tagged auto_explain messages"; }
dump "$DIR/autoexplain.txt" log
got=$(q "select string_agg(format || ':' || analyzed || ':' || (duration_ms > 0) || ':' || datname || ':' ||
                        (query like '%$TAG-' || format || '%') || ':' ||
                        coalesce((select string_agg(r.rule, ',') from pgvigil.plan_rules(plan) r), '-'), ' ' order by format)
           from pgvigil.plans where instance_id = $P and source = 'auto_explain'")
[[ "$got" == "json:true:true:plansdb:true:filter removes most rows text:true:true:plansdb:true:filter removes most rows" ]] || fail "A: $got"
echo "ok: A. two auto_explain plans from the log (text and json), analyzed, timed, tagged, rule 'filter removes most rows'"

echo "--- B. each rule hit by its seeded shape, silent on the clean plan, text and JSON alike"
declare -A want=(
  [aggspill]="spill to disk" [clean]="-" [cte]="CTE scanned twice" [estimate]="estimate off by 10x,filter removes most rows"
  [filter]="filter removes most rows" [hashspill]="spill to disk" [heapfetch]="index-only scan with heap fetches"
  [jit]="JIT share,estimate off by 10x" [lossy]="lossy bitmap heap scan" [nestloop]="nested loop over a large outer"
  [sortspill]="spill to disk" [trigger]="trigger time" [workers]="parallel workers not launched")
while IFS='|' read -r name sets stmt; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  for fmt in text json; do
    printf 'begin;\n%s;\nexplain (analyze, format %s) %s;\nrollback;\n' "$sets" "$fmt" "$stmt" \
      | psql "$SUDB" -XAtq -v ON_ERROR_STOP=1 > "$DIR/$name.$fmt" || fail "B: explain $name $fmt"
    dump "$DIR/$name.$fmt" "$fmt" explain_analyze "proof:$name:$fmt"
    got=$(q "select coalesce(string_agg(r.rule, ',' order by r.rule), '-') from pgvigil.plans p cross join lateral pgvigil.plan_rules(p.plan) r
              where p.instance_id = $P and p.plan_key = 'proof:$name:$fmt'")
    [[ "$got" == "${want[$name]}" ]] || fail "B: $name ($fmt): '$got', expected '${want[$name]}'"
  done
  echo "ok: $name: ${want[$name]} (text and json)"
done < "$TD/shapes.txt"
got=$(q "select count(*) || ':' || count(distinct setting) || ':' || count(*) filter (where severity is null or value is null or detail is null or at is null or platforms is null or source is null)
           from pgvigil.plan_findings where instance_id = $P")
[[ "$got" == "10:10:0" ]] || fail "B: plan_findings $got, expected 10:10:0"
echo "ok: plan_findings holds the ten rules for the instance, one row each, the columns filled"

echo "--- C and D. the on-demand EXPLAIN and EXPLAIN ANALYZE through the handlers (TestPlansProof)"
export PGVIGIL_PLANS_PROOF=1 PLANS_AUDIT_DSN="$COL_DSN" PLANS_SU_DSN="$SU" PLANS_DB=plansdb \
  PLANS_MONITOR_DSN="host=localhost port=$PORT user=$MON password=$PW dbname=postgres sslmode=disable" \
  PLANS_ACTIONS_DSN="host=localhost port=$PORT user=$ACT password=$PW dbname=postgres sslmode=disable" \
  PLANS_EXPLAIN_DSN="host=localhost port=$PORT user=$EXP password=$PW dbname=postgres sslmode=disable" \
  PLANS_MONITOR_ROLE=$MON PLANS_EXPLAIN_ROLE=$EXP PLANS_INSTANCE=$I1 PLANS_INSTANCE_NODOOR=$I2
GOOUT=$(go test -count=1 -run 'TestPlansProof$' -v "$HERE/internal/web/" 2>&1) || { echo "$GOOUT" >&2; fail "TestPlansProof failed"; }
grep -q -- '--- PASS: TestPlansProof' <<<"$GOOUT" || { echo "$GOOUT" >&2; fail "TestPlansProof did not run (skipped?)"; }
grep -E 'q_plans_test.go:[0-9]+: ok:' <<<"$GOOUT" | sed 's/^ *q_plans_test.go:[0-9]*: //'
got=$(q "select string_agg(n || ':' || outcome || '=' || c, ' ' order by n, outcome) from (
           select case instance_name when '$I1' then 'door' else 'nodoor' end n, outcome, count(*) c
             from pgvigil.actions_log where instance_name in ('$I1','$I2') group by 1, 2) x")
[[ "$got" == "door:done=1 door:failed=4 door:refused=4 nodoor:refused=1" ]] || fail "D: actions_log '$got'"
bad=$(q "select count(*) from pgvigil.actions_log where instance_name in ('$I1','$I2')
          and (action <> 'explain_analyze' or pid is not null or statement is null or datname is distinct from 'plansdb' or ui_user = '' or detail is null)")
[[ "$bad" == 0 ]] || fail "D: $bad audit rows miss the statement, the datname, the user or the detail"
echo "ok: D. actions_log holds every EXPLAIN ANALYZE attempt ($got)"

echo "--- E. rights"
got=$(q "select has_function_privilege('pgvigil_collector', 'pgvigil.import_plans(int, timestamptz, jsonb)', 'EXECUTE')
             || ':' || has_table_privilege('pgvigil_reader', 'pgvigil.plans', 'SELECT')
             || ':' || has_table_privilege('pgvigil_reader', 'pgvigil.plan_rule_hits', 'SELECT')
             || ':' || has_table_privilege('pgvigil_reader', 'pgvigil.plan_findings', 'SELECT')
             || ':' || has_function_privilege('pgvigil_reader', 'pgvigil.plan_rules(jsonb)', 'EXECUTE')")
[[ "$got" == "true:true:true:true:true" ]] || fail "E: $got"
echo "ok: E. the collector imports plans, the reader reads them"
echo "PASS: proof-plans"
