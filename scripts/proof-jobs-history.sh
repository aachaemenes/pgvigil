#!/usr/bin/env bash
# Proof of the Jobs pages in DBA Dash's shape (task 110; migration 0072, internal/mssql/jobs.go, internal/collect/jobs.go,
# internal/web/q_jobs_history.go): the failed step's message on a run, the run history with its counts, and the
# versions of a job's definition with a field-level diff, on both engines.
#
# Needs: docker with the SQL Server sandbox (PGVIGIL_MSSQL_CONTAINER, default mssql-sandbox, on PGVIGIL_MSSQL_ADDR,
# default localhost:1433) with SQL Server Agent running, its sa password in MSSQL_SA_PASSWORD, psql, curl, python3, go
# at the repository root, and PGVIGIL_ADMIN_DSN, a superuser connection to the PostgreSQL sandbox in KEYWORD form
# WITHOUT a password (the password from ~/.pgpass: the DSN is on psql's command line).
#
# What it makes, and drops on every exit path (a flag per object; nothing it did not make is touched): its own
# repository database and a stand-in database for pgAgent; on SQL Server a monitoring login (VIEW SERVER STATE, a
# user in msdb with db_datareader) and one Agent job with its schedule. It changes no server setting.
#
# pg_cron is NOT installed on the PostgreSQL sandbox (it needs shared_preload_libraries and a restart): the pg_cron
# side is proven over imported rows in the collector's shape. pgAgent is not installed either: its SQL is proven over
# a stand-in pgagent schema with the columns the collector reads (pgAgent 4's pgagent.sql), read by the real
# collector.
#
# The route GET /api/jobs/history is the lead's line in web.go: where the tree lacks it the proof builds a scratch
# copy with exactly that line and says so.
#
# Expected (written before the first run):
#  A. SQL Server, first read. A job J with step 1 'one' (SELECT 1;), step 2 'two fails' (RAISERROR ... 16 ... whose
#     command also holds PASSWORD = 's3cret-<n>'), a daily schedule at 23:59: mssql_jobs holds J with schedule_text
#     'every day at 23:59'; job_versions holds one row for J, version 1, not dropped, changes NULL; its definition
#     has 2 steps, step 02's command has '<masked>' and not 's3cret'; step 01 'on success' = 'go to the next step'.
#  B. J run once (sp_start_job): after the next read its outcome row (step 0, run_status 0) carries failed_step_id 2,
#     failed_step_name 'two fails', failed_message with 'step two fails', failed_sql_message_id 50000,
#     failed_sql_severity 16, step_retries 0; still ONE version of J (the definition did not change).
#  C. The schedule moved to 23:30 and step 1's command set to 'SELECT 2;': the next read stores version 2 with exactly
#     two changed fields: 'schedules / <name #id> / runs' 'every day at 23:59' -> 'every day at 23:30' and
#     'steps / step 01 / command' 'SELECT 1;' -> 'SELECT 2;'. A read with nothing changed adds no version.
#  D. J deleted: the next read stores version 3, dropped, changes [{job: present -> dropped}]; mssql_jobs has no J.
#  E. PostgreSQL over imported rows (pg_cron and pgAgent payloads through import_jobs, T0 < T1 < T2 < T3):
#     T0 jobs 1 'nightly' (pg_cron '0 3 * * *', SELECT 1) and 2 'agent' (pgAgent, a definition with one step) ->
#     one version each; T1 job 1's schedule -> '30 3 * * *' and job 2's step command changed -> version 2 of each with
#     exactly the one field ('schedule'; 'steps / s1 #1 / command'); T2 job 2 not listed -> version 3 dropped; T3
#     job 2 listed again -> version 4 with 'job: dropped -> present'. A pgAgent failed run carries failed_step 's1'
#     and step_result 1. A payload older than the newest read changes nothing.
#  F. pgAgent's SQL over the stand-in schema, read by the collector (jobs -once): one job row whose definition has
#     its schedule (minutes '0', hours '3', weekdays 'any') and its step (kind SQL, on error fail) with the
#     connection string's password '<masked>'; the failed run's return_message is the failed step's output and
#     failed_step its name, step_result 1.
#  G. The API, /api/jobs/history: engine=mssql lists J dropped (dropped_at = version 3's time) with 1 run and 1
#     failure in the range and changes 2; with scheduler=sqlagent&job=<id>: 1 run (failed, step '2 two fails', the
#     message), counts succeeded 0 failed 1, 3 versions newest first. engine=pg: job 1 with changes 1; its runs over
#     seeded durations 10,10,10,10,50 s (succeeded) and one failed: counts succeeded 5, failed 1, running_long 1
#     (50 > 2 x median 10), median 10.0. engine=x answers 400; scheduler without job answers 400.
#     [review fold, written before the rerun] With 1,005 more succeeded runs of job 1 (10 s each, written straight into
#     job_runs): the runs part lists 1,000 rows, the counts cover every run: succeeded 1010, failed 1, running_long 1,
#     median 10.0; the grid's runs for job 1 = 1011 and its avg_s 10.0, max_s 50.0.
#  H. [review fold] the masking of every password form a job's text is known to carry (go test TestMaskJobText).
#
# Not proven here: a real pg_cron or pgAgent (neither installed on this sandbox); a SQL Server job with an operator
# notification (no operator is made); the pages in a browser (the shots are the slice's report).
set -euo pipefail
export PATH=$HOME/.local/share/mise/shims:$PATH
: "${PGVIGIL_ADMIN_DSN:?a superuser keyword DSN of the PostgreSQL sandbox}" "${MSSQL_SA_PASSWORD:?the sa password of the SQL Server sandbox}"
CT=${PGVIGIL_MSSQL_CONTAINER:-mssql-sandbox}; ADDR=${PGVIGIL_MSSQL_ADDR:-localhost:1433}
ADMIN_DSN=$PGVIGIL_ADMIN_DSN
BIN=${PGVIGIL_BIN:-bin/pgvigil}
SUF=$RANDOM
REPO_DB=pgvigil_jobhist_$SUF; AGENT_DB=pgvigil_jobhist_agent_$SUF
LM=pgvjh_mon_$SUF; J="pgvjh job $SUF"; SECRET="s3cret-$SUF"
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
PM=$(pw)
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; OUT=$WORK/out; LOG=$WORK/serve.log; SCRATCH=$WORK/scratch; mkdir -p "$SCRATCH"
fail() { echo "FAIL: $*" >&2; exit 1; }
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
sq() { docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -W -h -1 -s '|' -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
sqin() { docker exec -i -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -W -h -1 -d master -i /dev/stdin; }
MADE_REPO=; MADE_AGENT=; MADE_LM=; MADE_UM=; MADE_J=; SRVPID=
cleanup() {
  local rc=$?
  set +e   # every step of the cleanup runs, whatever failed before it
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null || true
  [ -n "$MADE_J" ] && { sq "IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'$J') EXEC msdb.dbo.sp_delete_job @job_name = N'$J', @delete_unused_schedule = 1;" >/dev/null 2>&1; [ "$(sq "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name = N'$J'" 2>/dev/null)" = 0 ] || echo "CLEANUP: job $J not deleted" >&2; }
  [ -n "$MADE_UM" ] && { sq "IF USER_ID('$LM') IS NOT NULL DROP USER [$LM];" msdb >/dev/null 2>&1 || echo "CLEANUP: msdb user $LM not dropped" >&2; }
  [ -n "$MADE_LM" ] && { sq "IF SUSER_ID('$LM') IS NOT NULL DROP LOGIN [$LM];" >/dev/null 2>&1 || echo "CLEANUP: login $LM not dropped" >&2; }
  [ -n "$MADE_AGENT" ] && { psql "$ADMIN_DSN" -XAtq -c "drop database if exists $AGENT_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $AGENT_DB not dropped" >&2; }
  [ -n "$MADE_REPO" ] && { psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; }
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
command -v go >/dev/null 2>&1 && [ -f go.mod ] || fail "run from the repository root with a go toolchain"
[[ "$ADMIN_DSN" != *password=* ]] || fail "PGVIGIL_ADMIN_DSN carries a password: keep it in ~/.pgpass (the DSN is on a command line)"

# ---- the binary: the given one where the tree is wired, else a scratch build with the lead's line
if grep -q '/api/jobs/history' internal/web/web.go; then
  [ -x "$BIN" ] || go build -o "$BIN" ./cmd/pgvigil
  WIRED="wired in this tree"
else
  tar --exclude=./web/node_modules --exclude=./bin --exclude=./.git -cf - . | tar -C "$SCRATCH" -xf -
  python3 - "$SCRATCH" <<'PY' || fail "the wiring's anchor line is gone from web.go"
import sys, io
p = sys.argv[1] + "/internal/web/web.go"
s = io.open(p, encoding="utf-8").read()
old = '\tapi.HandleFunc("GET /api/mssql/jobs", s.MSSQLJobs)\n'
if s.count(old) != 1:
    sys.exit("web.go: anchor found %d times" % s.count(old))
io.open(p, "w", encoding="utf-8").write(s.replace(old, old + '\tapi.HandleFunc("GET /api/jobs/history", s.JobsHistory)\n'))
PY
  (cd "$SCRATCH" && CGO_ENABLED=0 go build -o "$SCRATCH/pgvigil-wired" ./cmd/pgvigil) || fail "the scratch build with the wiring"
  BIN=$SCRATCH/pgvigil-wired
  WIRED="wired in a scratch build (the join applies the same line)"
fi
echo "binary: $WIRED"

adm() { psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"; MADE_REPO=1
adm -c "create database $AGENT_DB"; MADE_AGENT=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
export PG_AGENT_DSN="$ADMIN_DSN dbname=$AGENT_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

# ---- the SQL Server side: a monitoring login and the job
sqin <<<"CREATE LOGIN [$LM] WITH PASSWORD = '$PM', CHECK_POLICY = OFF;"; MADE_LM=1
sq "GRANT VIEW SERVER STATE TO [$LM]; GRANT VIEW ANY DEFINITION TO [$LM];"
sq "CREATE USER [$LM] FOR LOGIN [$LM]; ALTER ROLE db_datareader ADD MEMBER [$LM];" msdb; MADE_UM=1
sq "EXEC msdb.dbo.sp_add_job @job_name = N'$J', @enabled = 1, @owner_login_name = N'sa', @notify_level_eventlog = 2;" >/dev/null; MADE_J=1
sq "EXEC msdb.dbo.sp_add_jobstep @job_name = N'$J', @step_id = 1, @step_name = N'one', @subsystem = N'TSQL', @command = N'SELECT 1;', @on_success_action = 3;
EXEC msdb.dbo.sp_add_jobstep @job_name = N'$J', @step_id = 2, @step_name = N'two fails', @subsystem = N'TSQL', @database_name = N'master',
  @command = N'-- ALTER LOGIN x WITH PASSWORD = ''$SECRET''
RAISERROR(''pgvigil proof $SUF: step two fails'', 16, 1);';
EXEC msdb.dbo.sp_add_jobschedule @job_name = N'$J', @name = N'pgvjh nightly $SUF', @freq_type = 4, @freq_interval = 1, @active_start_time = 235900;
EXEC msdb.dbo.sp_add_jobserver @job_name = N'$J';" >/dev/null
export MSSQL_DSN="sqlserver://$LM:$PM@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
NS=proof-jobhist-ms-$SUF; NP=proof-jobhist-pgagent-$SUF
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $NS
    engine: sqlserver
    dsn: env:MSSQL_DSN
  - name: $NP
    dsn: env:PG_AGENT_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
[ "$(q "select count(*) from pg_tables where schemaname='pgvigil' and tablename='job_versions'")" = 1 ] || fail "migration 0072 did not make job_versions"
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$2" >"$OUT" 2>&1 || { cat "$OUT"; fail "collect $1 on $2"; }; if grep -q "partial\|skipped\|error" "$OUT"; then cat "$OUT"; fail "collect $1 on $2 was not a clean read"; fi; }

echo "--- A. SQL Server: the first read"
collect mssql_jobs "$NS"
IS=$(q "select instance_id from pgvigil.instances where name='$NS'")
JID=$(q "select job_id from pgvigil.mssql_jobs where instance_id=$IS and name='$J'")
[ -n "$JID" ] || fail "A: the job is not in mssql_jobs"
R=$(q "select schedule_text from pgvigil.mssql_jobs where instance_id=$IS and job_id='$JID'"); echo "  schedule: $R"
[ "$R" = "every day at 23:59" ] || fail "A: schedule_text"
vq="from pgvigil.job_versions where instance_id=$IS and scheduler='sqlagent' and job_id='$JID'"
R=$(q "select count(*) || '|' || max(version_no) || '|' || bool_or(dropped) || '|' || (max(changes::text) is null) $vq"); echo "  versions: $R"
[ "$R" = "1|1|false|true" ] || fail "A: one first version"
R=$(q "select (select count(*) from jsonb_object_keys(definition->'steps')) || '|' || (definition #>> '{steps,step 02,command}' like '%<masked>%') || '|' || (definition::text like '%$SECRET%') || '|' || (definition #>> '{steps,step 01,on success}') $vq")
echo "  definition: $R"
[ "$R" = "2|true|false|go to the next step" ] || fail "A: the definition (steps, masked command, step 1's action)"
[ "$(q "select count(*) from pgvigil.mssql_jobs where instance_id=$IS and steps::text like '%$SECRET%'")" = 0 ] || fail "A: the secret is in mssql_jobs.steps"
echo "A: OK"

echo "--- B. SQL Server: a run that fails at step 2"
sq "EXEC msdb.dbo.sp_start_job @job_name = N'$J';" >/dev/null
for _ in $(seq 1 60); do
  [ "$(sq "SELECT COUNT(*) FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name = N'$J' AND h.step_id = 0")" = 1 ] && break; sleep 1
done
[ "$(sq "SELECT COUNT(*) FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name = N'$J'")" = 3 ] || fail "B: the job did not write its three history rows (is SQL Server Agent running?)"
collect mssql_jobs "$NS"
R=$(q "select run_status || '|' || failed_step_id || '|' || failed_step_name || '|' || (failed_message like '%step two fails%') || '|' || failed_sql_message_id || '|' || failed_sql_severity || '|' || step_retries from pgvigil.mssql_job_runs where instance_id=$IS and job_id='$JID' and step_id=0")
echo "  outcome row: $R"
[ "$R" = "0|2|two fails|true|50000|16|0" ] || fail "B: the failed step on the outcome row"
[ "$(q "select count(*) $vq")" = 1 ] || fail "B: a version was added without a change"
echo "B: OK"

echo "--- C. SQL Server: a changed schedule and a changed step command"
SID=$(sq "SELECT s.schedule_id FROM msdb.dbo.sysschedules s WHERE s.name = N'pgvjh nightly $SUF'")
sq "EXEC msdb.dbo.sp_update_schedule @schedule_id = $SID, @active_start_time = 233000;
EXEC msdb.dbo.sp_update_jobstep @job_name = N'$J', @step_id = 1, @command = N'SELECT 2;';" >/dev/null
collect mssql_jobs "$NS"
R=$(q "select string_agg(c->>'field' || ': ' || coalesce(c->>'old', '-') || ' -> ' || coalesce(c->>'new', '-'), ' ; ' order by c->>'field') from pgvigil.job_versions v, jsonb_array_elements(v.changes) c where v.instance_id=$IS and v.scheduler='sqlagent' and v.job_id='$JID' and v.version_no=2")
echo "  version 2: $R"
[ "$R" = "schedules / pgvjh nightly $SUF #$SID / runs: every day at 23:59 -> every day at 23:30 ; steps / step 01 / command: SELECT 1; -> SELECT 2;" ] || fail "C: version 2's changes"
collect mssql_jobs "$NS"
[ "$(q "select count(*) $vq")" = 2 ] || fail "C: a read without a change added a version"
echo "C: OK"

echo "--- D. SQL Server: the job deleted"
sq "EXEC msdb.dbo.sp_delete_job @job_name = N'$J', @delete_unused_schedule = 1;" >/dev/null; MADE_J=
collect mssql_jobs "$NS"
R=$(q "select version_no || '|' || dropped || '|' || changes::text from pgvigil.job_versions where instance_id=$IS and scheduler='sqlagent' and job_id='$JID' order by valid_from desc limit 1")
echo "  newest version: $R"
[ "$R" = '3|true|[{"new": "dropped", "old": "present", "field": "job"}]' ] || fail "D: the dropped version"
[ "$(q "select count(*) from pgvigil.mssql_jobs where instance_id=$IS and job_id='$JID'")" = 0 ] || fail "D: the job is still in mssql_jobs"
echo "D: OK"

echo "--- E. PostgreSQL over imported rows (pg_cron and pgAgent are not installed on this sandbox)"
IP=$(q "select pgvigil.ensure_instance('proof-jobhist-pg-$SUF', 'onprem', 'x', 170000, false, '{}', 'postgres')")
NOW=$(date -u +%s); ts() { date -u -d "@$1" +%FT%TZ; }
T0=$(ts $((NOW - 4000))); T1=$(ts $((NOW - 3000))); T2=$(ts $((NOW - 2000))); T3=$(ts $((NOW - 1000)))
cron() { echo "{\"kind\":\"job\",\"scheduler\":\"pg_cron\",\"job_id\":1,\"job_name\":\"nightly\",\"schedule\":\"$1\",\"command\":\"SELECT 1\",\"datname\":\"app\",\"run_as\":\"postgres\",\"active\":true}"; }
agent() { echo "{\"kind\":\"job\",\"scheduler\":\"pgagent\",\"job_id\":2,\"job_name\":\"agent\",\"active\":true,\"definition\":{\"name\":\"agent\",\"enabled\":true,\"steps\":{\"s1 #1\":{\"kind\":\"SQL\",\"command\":\"$1\"}}}}"; }
imp() { q "select pgvigil.import_jobs($IP, '$1', \$j\$[$2]\$j\$::jsonb)" >/dev/null; }
# runs of job 1 (durations 10,10,10,10,50 s succeeded, one failed) and a failed pgAgent run
RUNS=""; RID=0
for d in 10 10 10 10 50; do RID=$((RID + 1)); st=$((NOW - 3600 + RID * 300)); RUNS+=",{\"kind\":\"run\",\"scheduler\":\"pg_cron\",\"job_id\":1,\"run_id\":$RID,\"status\":\"succeeded\",\"return_message\":\"SELECT 1\",\"start_time\":\"$(ts $st)\",\"end_time\":\"$(ts $((st + d)))\",\"duration_secs\":$d}"; done
RUNS+=",{\"kind\":\"run\",\"scheduler\":\"pg_cron\",\"job_id\":1,\"run_id\":9,\"status\":\"failed\",\"return_message\":\"ERROR:  relation \\\"x\\\" does not exist\",\"start_time\":\"$(ts $((NOW - 600)))\",\"end_time\":\"$(ts $((NOW - 599)))\",\"duration_secs\":1}"
RUNS+=",{\"kind\":\"run\",\"scheduler\":\"pgagent\",\"job_id\":2,\"run_id\":7,\"status\":\"failed\",\"return_message\":\"ERROR: boom\",\"failed_step\":\"s1\",\"step_result\":1,\"start_time\":\"$(ts $((NOW - 500)))\",\"end_time\":\"$(ts $((NOW - 498)))\",\"duration_secs\":2}"
imp "$T0" "$(cron '0 3 * * *'),$(agent 'SELECT a()')"
imp "$T1" "$(cron '30 3 * * *'),$(agent 'SELECT b()')"
imp "$T2" "$(cron '30 3 * * *')"
imp "$T3" "$(cron '30 3 * * *'),$(agent 'SELECT b()')$RUNS"
imp "$T0" "$(cron '15 3 * * *')"   # older than the newest read: no version
pv() { q "select string_agg(v.version_no || ':' || v.dropped || ':' || coalesce((select string_agg(c->>'field' || '=' || coalesce(c->>'old', '-') || '>' || coalesce(c->>'new', '-'), ',') from jsonb_array_elements(v.changes) c), 'first'), ' ' order by v.valid_from) from pgvigil.job_versions v where v.instance_id=$IP and v.scheduler='$1' and v.job_id='$2'"; }
R1=$(pv pg_cron 1); R2=$(pv pgagent 2); echo "  pg_cron 1: $R1"; echo "  pgagent 2: $R2"
[ "$R1" = "1:false:first 2:false:schedule=0 3 * * *>30 3 * * *" ] || fail "E: pg_cron's versions"
[ "$R2" = "1:false:first 2:false:steps / s1 #1 / command=SELECT a()>SELECT b() 3:true:job=present>dropped 4:false:job=dropped>present" ] || fail "E: pgAgent's versions"
[ "$(q "select failed_step || '|' || step_result from pgvigil.job_runs where instance_id=$IP and scheduler='pgagent' and run_id=7")" = "s1|1" ] || fail "E: the pgAgent run's failed step"
echo "E: OK"

echo "--- F. pgAgent's SQL over a stand-in schema, read by the collector"
psql "$PG_AGENT_DSN" -XAtq -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA pgagent;
CREATE TABLE pgagent.pga_job (jobid serial PRIMARY KEY, jobjclid int NOT NULL DEFAULT 1, jobname text NOT NULL, jobdesc text NOT NULL DEFAULT '',
  jobhostagent text NOT NULL DEFAULT '', jobenabled bool NOT NULL DEFAULT true, jobcreated timestamptz NOT NULL DEFAULT now(),
  jobchanged timestamptz NOT NULL DEFAULT now(), jobagentid int, jobnextrun timestamptz, joblastrun timestamptz);
CREATE TABLE pgagent.pga_schedule (jscid serial PRIMARY KEY, jscjobid int NOT NULL, jscname text NOT NULL, jscdesc text NOT NULL DEFAULT '',
  jscenabled bool NOT NULL DEFAULT true, jscstart timestamptz NOT NULL DEFAULT now(), jscend timestamptz,
  jscminutes bool[60] NOT NULL, jschours bool[24] NOT NULL, jscweekdays bool[7] NOT NULL, jscmonthdays bool[32] NOT NULL, jscmonths bool[12] NOT NULL);
CREATE TABLE pgagent.pga_jobstep (jstid serial PRIMARY KEY, jstjobid int NOT NULL, jstname text NOT NULL, jstdesc text NOT NULL DEFAULT '',
  jstenabled bool NOT NULL DEFAULT true, jstkind char NOT NULL, jstcode text NOT NULL, jstconnstr text NOT NULL DEFAULT '',
  jstdbname name NOT NULL DEFAULT '', jstonerror char NOT NULL DEFAULT 'f', jscnextrun timestamptz);
CREATE TABLE pgagent.pga_joblog (jlgid serial PRIMARY KEY, jlgjobid int NOT NULL, jlgstatus char NOT NULL DEFAULT 'r',
  jlgstart timestamptz NOT NULL DEFAULT now(), jlgduration interval);
CREATE TABLE pgagent.pga_jobsteplog (jslid serial PRIMARY KEY, jsljlgid int NOT NULL, jsljstid int NOT NULL, jslstatus char NOT NULL DEFAULT 'r',
  jslresult int, jslstart timestamptz NOT NULL DEFAULT now(), jslduration interval, jsloutput text);
INSERT INTO pgagent.pga_job (jobname) VALUES ('nightly-agg');
INSERT INTO pgagent.pga_schedule (jscjobid, jscname, jscminutes, jschours, jscweekdays, jscmonthdays, jscmonths)
SELECT 1, 'at three', array_fill(false, ARRAY[60]) , array_fill(false, ARRAY[24]), array_fill(false, ARRAY[7]), array_fill(false, ARRAY[32]), array_fill(false, ARRAY[12]);
UPDATE pgagent.pga_schedule SET jscminutes[1] = true, jschours[4] = true;
INSERT INTO pgagent.pga_jobstep (jstjobid, jstname, jstkind, jstcode, jstconnstr) VALUES (1, 'aggregate', 's', 'CALL agg.run()', 'host=db1 user=agg password=topsecret dbname=app');
INSERT INTO pgagent.pga_joblog (jlgjobid, jlgstatus, jlgstart, jlgduration) VALUES (1, 'f', now() - interval '10 minutes', interval '3 seconds');
INSERT INTO pgagent.pga_jobsteplog (jsljlgid, jsljstid, jslstatus, jslresult, jslstart, jslduration, jsloutput)
VALUES (1, 1, 'f', 1, now() - interval '10 minutes', interval '3 seconds', 'ERROR:  division by zero');
SQL
collect jobs "$NP"
IA=$(q "select instance_id from pgvigil.instances where name='$NP'")
R=$(q "select definition #>> '{schedules,at three #1,minutes}' || '|' || (definition #>> '{schedules,at three #1,hours}') || '|' || (definition #>> '{schedules,at three #1,weekdays}') || '|' || (definition #>> '{steps,aggregate #1,kind}') || '|' || (definition #>> '{steps,aggregate #1,on error}') || '|' || (definition::text like '%topsecret%') || '|' || (definition #>> '{steps,aggregate #1,connection}' like '%<masked>%') from pgvigil.job_versions where instance_id=$IA and scheduler='pgagent' and job_id='1'")
echo "  definition: $R"
[ "$R" = "0|3|any|SQL|fail|false|true" ] || fail "F: pgAgent's definition"
R=$(q "select status || '|' || return_message || '|' || failed_step || '|' || step_result from pgvigil.job_runs where instance_id=$IA and scheduler='pgagent'")
echo "  run: $R"
[ "$R" = "failed|ERROR:  division by zero|aggregate|1" ] || fail "F: pgAgent's failed run"
echo "F: OK"

echo "--- G. the API"
PORT=$((20000 + RANDOM % 10000)); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$PORT" -no-login >"$LOG" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "$U/api/health" >/dev/null 2>&1 && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || fail "serve exited: $(cat "$LOG")"
api() { local code; code=$(curl -s -o "$LOG.body" -w '%{http_code}' "$U/api/$1"); [ "$code" = "${2:-200}" ] || fail "/api/$1 answered $code: $(cat "$LOG.body")"; cat "$LOG.body"; }
FROM=$(date -u -d '-6 hours' +%Y-%m-%dT%H:%M:%SZ); TO=$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)
py() { python3 -c "import json, sys
d = json.load(sys.stdin)
def rows(k):
    t = d.get(k) or {'columns': [], 'rows': []}
    return [dict(zip(t['columns'], r)) for r in t['rows']]
$1"; }
R=$(api "jobs/history?engine=mssql&instance=$IS&from=$FROM&to=$TO" | py "
j = [r for r in rows('jobs') if r['job_id'] == '$JID'][0]
print('%s|%s|%s|%s' % (j['dropped_at'] is not None, j['runs'], j['failures'], j['changes']))")
echo "  mssql grid: $R"; [ "$R" = "True|1|1|2" ] || fail "G: the SQL Server grid row"
R=$(api "jobs/history?engine=mssql&instance=$IS&from=$FROM&to=$TO&scheduler=sqlagent&job=$JID" | py "
r = rows('runs'); c = rows('counts')[0]; v = rows('changes')
print('%d|%s|%s|%s|%s|%s|%s' % (len(r), r[0]['outcome'], r[0]['failed_step'], 'step two fails' in r[0]['message'], c['succeeded'], c['failed'], ','.join(str(x['version_no']) for x in v)))")
echo "  mssql job: $R"; [ "$R" = "1|failed|2 two fails|True|0|1|3,2,1" ] || fail "G: the SQL Server job's history"
R=$(api "jobs/history?engine=pg&instance=$IP&from=$FROM&to=$TO&scheduler=pg_cron&job=1" | py "
j = [x for x in rows('jobs') if x['job_id'] == '1'][0]; c = rows('counts')[0]
print('%s|%s|%s|%s|%s' % (j['changes'], c['succeeded'], c['failed'], c['running_long'], c['median_s']))")
echo "  pg job: $R"; [ "$R" = "1|5|1|1|10.0" ] || fail "G: the PostgreSQL job's counts"
q "insert into pgvigil.job_runs (instance_id, scheduler, job_id, run_id, status, return_message, start_time, end_time, duration_secs, snapshot_at)
   select $IP, 'pg_cron', 1, 1000 + g, 'succeeded', 'SELECT 1', now() - interval '5 hours' + g * interval '10 seconds',
          now() - interval '5 hours' + g * interval '10 seconds' + interval '10 seconds', 10, now() from generate_series(1, 1005) g" >/dev/null
R=$(api "jobs/history?engine=pg&instance=$IP&from=$FROM&to=$TO&scheduler=pg_cron&job=1" | py "
j = [x for x in rows('jobs') if x['job_id'] == '1'][0]; c = rows('counts')[0]
print('%d|%s|%s|%s|%s|%s|%s|%s' % (len(rows('runs')), c['succeeded'], c['failed'], c['running_long'], c['median_s'], j['runs'], j['avg_s'], j['max_s']))")
echo "  pg job with 1,011 runs: $R"; [ "$R" = "1000|1010|1|1|10.0|1011|10.0|50.0" ] || fail "G: the counts over more runs than the grid lists"
api "jobs/history?engine=x&instance=$IP" 400 >/dev/null
api "jobs/history?engine=pg&instance=$IP&scheduler=pg_cron" 400 >/dev/null
echo "G: OK"

echo "--- H. the masking"
go test ./internal/collect -run 'TestMaskJobText|TestMaskTree' -count=1 >"$OUT" 2>&1 || { cat "$OUT"; fail "H: the masking tests"; }
echo "H: OK"
echo "PROOF OK"
