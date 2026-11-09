#!/usr/bin/env bash
# Proof of the job report (task 38): the pg_cron schedule parser (internal/collect/cronnext.go), migration 0027
# (job_report, job_report_checks, job_report_findings, import_jobs with prior_due and schedule_note) and the
# JobsReport handler with its overview check.
#
#   PGVIGIL_ADMIN_DSN  a superuser connection to the sandbox server (default: PGVIGIL_REPO_DSN). The proof makes its
#                      own repository database with a random suffix and drops it at the end; nothing else is touched.
#   Run from the repository root; it builds bin/pgvigil when PGVIGIL_BIN is not set, and needs go on the PATH.
#
# Why seeded: pg_cron needs shared_preload_libraries and a restart, which the sandbox does not offer, so the jobs and
# runs come as import_jobs payloads in the collector's shape, with next_run and prior_due as the parser gives them.
#
# Expected (written before the first run):
#  A. the parser, against these cases (schedule | after | next run, UTC), all equal:
CASES='* * * * *        | 2026-11-09T14:59:59Z | 2026-11-09T15:00:00Z
*/7 * * * *               | 2026-11-09T14:56:00Z | 2026-11-09T15:00:00Z
59 * * * *                | 2026-11-09T14:59:00Z | 2026-11-09T15:59:00Z
0 * * * *                 | 2026-11-09T23:00:00Z | 2026-11-10T00:00:00Z
45 23 * * *               | 2026-11-09T23:45:00Z | 2026-11-10T23:45:00Z
0 0 * * *                 | 2026-11-30T23:59:00Z | 2026-12-01T00:00:00Z
0 0 31 * *                | 2026-12-31T00:00:00Z | 2027-01-31T00:00:00Z
0 0 $ * *                 | 2026-04-30T00:00:00Z | 2026-05-31T00:00:00Z
0 0 1 */3 *               | 2026-11-09T00:00:00Z | 2027-01-01T00:00:00Z
30 2 * dec *              | 2026-12-31T02:30:00Z | 2027-12-01T02:30:00Z
@hourly                   | 2026-11-09T14:00:00Z | 2026-11-09T15:00:00Z
@annually                 | 2026-12-31T23:59:00Z | 2027-01-01T00:00:00Z
0 8 * * sat,sun           | 2026-11-09T09:00:00Z | 2026-11-14T08:00:00Z
15 seconds                | 2026-11-09T14:00:00Z | 2026-11-09T14:00:15Z'
#  B. a fresh repository migrates 0001..0039 with 0027 in its place; jobs gains prior_due and schedule_note.
#  C. one scratch instance, the jobs collection's payload at T0 = now - 2 h (the jobs only: first_seen) and at
#     now (the jobs and their runs); M10 = now floored to 10 min, M5 = to 5 min, H = to the hour:
#     1 fails-3     pg_cron '*/10 * * * *': ok at M10-60/-50/-40 (5 s), failed at M10-30/-20/-10 (1 s);
#                   prior_due M10-10  -> fail_streak 3, runs_7d 6, failures_7d 3, last_ok M10-40, not missed
#     2 slow        pg_cron '0 * * * *': ok at H-5h..H-1h (60 s each), ok at H (150 s); prior_due H-1h
#                   -> base_runs 5, base_avg 60.0, last 150.0, over_average, avg_30d 75.0, max_30d 150.0
#     3 missed      pg_cron '*/5 * * * *': one run at M5-60 (2 s); prior_due M5-5 -> missed
#     4 healthy     pg_cron '*/5 * * * *': ok at M5-10, M5-5, M5 (2 s) and now-10 days (20 s); prior_due M5-5
#                   -> runs_7d 3, runs_30d 4, max_7d 2.0, max_30d 20.0, nothing flagged
#     5 at-boot     pg_cron '@reboot', schedule_note set, no runs -> not missed
#     6 agent-down  pgagent, next_run now-20 min, no runs -> missed (pgAgent's own next run is past)
#     7 disabled    pg_cron '*/10 * * * *', active false, 3 failures -> fail_streak 3 but no check
#     job_report_checks for the instance, exactly:
#        critical | job failing repeatedly          | pg_cron fails-3
#        critical | job schedule missed             | pg_cron missed
#        critical | job schedule missed             | pgagent agent-down
#        warning  | job run over twice its average  | pg_cron slow
#     job_report_findings: the same 4 rows, setting = check_name, value = object, the ten columns in order
#  D. the handler (go test TestJobsReportProof against this repository): the instance report has 7 jobs, 4 checks,
#     trend rows over the window, the 4 problem jobs first; an empty window has no trend rows; the fleet has 4
#     problem jobs and counts jobs 6, failing 1, missed 2, over_average 1, instances 1; the overview has 4
#     'jobs report' rows and no "check could not run".
#  E. a second import at now + 1 min whose fails-3 run at M10 succeeded -> fail_streak 0, the failing check gone.
set -euo pipefail
export PATH=$HOME/.local/share/mise/shims:$PATH
: "${PGVIGIL_REPO_DSN:?}"
ADMIN_DSN=${PGVIGIL_ADMIN_DSN:-$PGVIGIL_REPO_DSN}
BIN=${PGVIGIL_BIN:-}
SUF=$RANDOM
REPO_DB=pgvigil_jobsrep_$SUF
CFG=$(mktemp)
cleanup() {
  rm -f "$CFG"
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "--- A. the parser"
PGVIGIL_CRON_CASES="$CASES" go test ./internal/collect -run 'TestCronProofCases$' -count=1 -v > "$CFG.a" 2>&1 \
  || { cat "$CFG.a"; fail "parser cases"; }
grep -q -- '--- PASS: TestCronProofCases' "$CFG.a" || { cat "$CFG.a"; fail "the parser cases did not run"; }
grep -o '[0-9]* proof cases checked' "$CFG.a"
rm -f "$CFG.a"

echo "--- B. a fresh repository"
if [[ -z "$BIN" ]]; then go build -o bin/pgvigil ./cmd/pgvigil; BIN=bin/pgvigil; fi
psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" >/dev/null
export PGVIGIL_REPO_DSN; PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"   # a later keyword wins, in libpq and in pgx
q() { psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null
[[ $(q "select count(*) from pg_views where schemaname = 'pgvigil' and viewname in ('job_report', 'job_report_checks', 'job_report_findings')") == 3 ]] \
  || fail "0027's views are missing"
[[ $(q "select count(*) from information_schema.columns where table_schema='pgvigil' and table_name='jobs' and column_name in ('prior_due','schedule_note')") == 2 ]] \
  || fail "jobs has no prior_due / schedule_note"
echo "migrated: $(q "select count(*) from pgvigil.schema_version") migrations"

echo "--- C. seeded jobs and runs"
IID=$(q "insert into pgvigil.instances (name, platform) values ('proof-jobsreport-$SUF', 'onprem') returning instance_id")
NOW=$(date -u +%s)
M10=$(( NOW / 600 * 600 )); M5=$(( NOW / 300 * 300 )); H=$(( NOW / 3600 * 3600 ))
ts() { date -u -d "@$1" +%FT%TZ; }
job() { # id name scheduler schedule active [next_run] [prior_due] [note]
  local x="{\"kind\":\"job\",\"scheduler\":\"$3\",\"job_id\":$1,\"job_name\":\"$2\",\"schedule\":\"$4\",\"command\":\"SELECT 1\",\"datname\":\"app\",\"run_as\":\"postgres\",\"active\":$5"
  [[ -n "${6:-}" ]] && x+=",\"next_run\":\"$(ts "$6")\""
  [[ -n "${7:-}" ]] && x+=",\"prior_due\":\"$(ts "$7")\""
  [[ -n "${8:-}" ]] && x+=",\"schedule_note\":\"$8\""
  echo "$x}"
}
RUN=0; RUNS=()
run() { # job_id start_epoch secs status: appends one run to RUNS (no subshell: the run_id counter must persist)
  RUN=$((RUN + 1))
  RUNS+=("{\"kind\":\"run\",\"scheduler\":\"pg_cron\",\"job_id\":$1,\"run_id\":$RUN,\"status\":\"$4\",\"return_message\":\"$([[ $4 == failed ]] && echo 'ERROR: relation x does not exist' || echo 'SELECT 1')\",\"start_time\":\"$(ts "$2")\",\"end_time\":\"$(ts $(( $2 + ${3%.*} )))\",\"duration_secs\":$3}")
}
JOBS=(
  "$(job 1 fails-3 pg_cron '*/10 * * * *' true $((M10 + 600)) $((M10 - 600)))"
  "$(job 2 slow pg_cron '0 * * * *' true $((H + 3600)) $((H - 3600)))"
  "$(job 3 missed pg_cron '*/5 * * * *' true $((M5 + 300)) $((M5 - 300)))"
  "$(job 4 healthy pg_cron '*/5 * * * *' true $((M5 + 300)) $((M5 - 300)))"
  "$(job 5 at-boot pg_cron '@reboot' true '' '' '@reboot: runs at server start only')"
  "$(job 6 agent-down pgagent '' true $((NOW - 1200)))"
  "$(job 7 disabled pg_cron '*/10 * * * *' false $((M10 + 600)) $((M10 - 600)))"
)
for m in 60 50 40; do run 1 $((M10 - m * 60)) 5 succeeded; done
for m in 30 20 10; do run 1 $((M10 - m * 60)) 1 failed; done
for h in 5 4 3 2 1; do run 2 $((H - h * 3600)) 60 succeeded; done
run 2 $H 150 succeeded
run 3 $((M5 - 3600)) 2 succeeded
for m in 10 5 0; do run 4 $((M5 - m * 60)) 2 succeeded; done
run 4 $((NOW - 10 * 86400)) 20 succeeded
for m in 30 20 10; do run 7 $((M10 - m * 60)) 1 failed; done
join() { local IFS=,; echo "[$*]"; }
q "select pgvigil.import_jobs($IID, to_timestamp($NOW - 7200), '$(join "${JOBS[@]}")'::jsonb)" >/dev/null
q "select pgvigil.import_jobs($IID, to_timestamp($NOW), '$(join "${JOBS[@]}" "${RUNS[@]}")'::jsonb)" >/dev/null

echo "job_report:"
q "select job_name, fail_streak, runs_7d, failures_7d, runs_30d, avg_30d_secs, max_7d_secs, max_30d_secs, base_runs, base_avg_secs,
          last_duration_secs, over_average, missed, to_char(last_ok at time zone 'UTC', 'HH24:MI') as last_ok
     from pgvigil.job_report where instance_id = $IID order by job_id" | sed 's/^/  /'
row() { q "select $2 from pgvigil.job_report where instance_id = $IID and job_name = '$1'"; }
want() { local got; got=$(row "$1" "$2"); [[ "$got" == "$3" ]] || fail "$1 $2 = '$got', want '$3'"; }
want fails-3 "fail_streak || '/' || runs_7d || '/' || failures_7d || '/' || missed" "3/6/3/false"
want fails-3 "last_ok = to_timestamp($M10 - 2400)" "t"
want slow "base_runs || '/' || base_avg_secs || '/' || last_duration_secs || '/' || over_average || '/' || avg_30d_secs || '/' || max_30d_secs || '/' || missed" "5/60.0/150.0/true/75.0/150.0/false"
want missed "missed || '/' || over_average || '/' || fail_streak" "true/false/0"
want healthy "runs_7d || '/' || runs_30d || '/' || max_7d_secs || '/' || max_30d_secs || '/' || missed || '/' || over_average || '/' || fail_streak" "3/4/2.0/20.0/false/false/0"
want at-boot "missed || '/' || runs_30d" "false/0"
want agent-down "missed" "t"
want disabled "fail_streak || '/' || missed" "3/false"

echo "job_report_checks:"
CHECKS=$(q "select severity || ' | ' || check_name || ' | ' || object from pgvigil.job_report_checks where instance_id = $IID order by severity, check_name, object")
echo "$CHECKS" | sed 's/^/  /'
EXPECT='critical | job failing repeatedly | pg_cron fails-3
critical | job schedule missed | pg_cron missed
critical | job schedule missed | pgagent agent-down
warning | job run over twice its average | pg_cron slow'
[[ "$CHECKS" == "$EXPECT" ]] || fail "the checks differ from the header"
FCOLS=$(q "select string_agg(attname, ',' order by attnum) from pg_attribute where attrelid = 'pgvigil.job_report_findings'::regclass and attnum > 0")
[[ "$FCOLS" == "instance_id,severity,setting,value,is_set,suggested,platforms,detail,source,at" ]] || fail "findings columns: $FCOLS"
[[ $(q "select count(*) from pgvigil.job_report_findings f join pgvigil.job_report_checks c on c.instance_id = f.instance_id
         and c.check_name = f.setting and c.object = f.value where f.instance_id = $IID") == 4 ]] || fail "findings do not match the checks"
q "select setting || ': ' || detail from pgvigil.job_report_findings where instance_id = $IID order by 1" | sed 's/^/  /'

echo "--- D. the handler"
PGVIGIL_JOBS_PROOF_DSN="$PGVIGIL_REPO_DSN" PGVIGIL_JOBS_PROOF_INSTANCE=$IID PGVIGIL_JOBS_PROOF_FROM=$(ts $((NOW - 11 * 86400))) \
  go test ./internal/web -run 'TestJobsReportProof$' -count=1 -v > "$CFG.d" 2>&1 || { cat "$CFG.d"; fail "handler"; }
grep -q -- '--- PASS: TestJobsReportProof' "$CFG.d" || { cat "$CFG.d"; fail "the handler test did not run"; }
grep -E 'instance:|fleet:|overview:' "$CFG.d" | sed 's/^ */  /'
rm -f "$CFG.d"

echo "--- E. the failing job succeeds"
RUNS=()
run 1 $((M10 + 1)) 5 succeeded
q "select pgvigil.import_jobs($IID, to_timestamp($NOW + 60), '$(join "${JOBS[@]}" "${RUNS[@]}")'::jsonb)" >/dev/null
want fails-3 "fail_streak" "0"
[[ $(q "select count(*) from pgvigil.job_report_checks where instance_id = $IID and check_name = 'job failing repeatedly'") == 0 ]] \
  || fail "the failing check stayed after a success"

echo "proof-jobs-report: OK (14 parser cases; 7 seeded jobs: 4 checks and 4 findings as the header says; handler, fleet and overview; a success ends the streak)"
