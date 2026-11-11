#!/usr/bin/env bash
# Proof of job scripts and configuration history in DBA Dash's shape (task 154; migration 0094, internal/mssql/jobs.go,
# internal/mssql/traceflags.go, internal/collect/jobs.go, internal/web/q_config_history.go).
#
# Needs: docker (it starts its own SQL Server container, SQL Server Agent on, a throwaway sa password made here and
# never printed; PGVIGIL_MSSQL_IMAGE, default mcr.microsoft.com/mssql/server:2022-latest), psql, curl, python3, go at
# the repository root, and PGVIGIL_ADMIN_DSN, a superuser keyword DSN of a PostgreSQL WITHOUT a password and dbname.
# What it makes and removes on every exit path: the container, its repository database pgvigil_jobddl_<n>, a stand-in
# database for pgAgent pgvigil_jobddl_agent_<n>. Nothing else is touched.
#
# Expected (written before the first run):
#  A. a SQL Server Agent job read, changed (step 1's command), read, changed (the schedule's time), read: job_versions
#     holds 3 versions, each with a script; the script of v1 holds "EXEC msdb.dbo.sp_add_job", "sp_add_jobstep",
#     "sp_add_jobschedule" and "@command = N'SELECT 1;'"; v2's script differs from v1's in exactly the @command
#     line (one line removed, one added), v3's from v2's in exactly the @active_start_time line [run 1, graded: and
#     the schedule's comment line in words above it, '-- schedule: every day at 23:59' -> '23:30'; the expectation
#     had left it out, and the proof's diff filter dropped a removed '-- ' line as a header; run 2: the two are
#     separate hunks, the comment pair first]; a password in a
#     step is <masked> in every script. A read with nothing changed adds no version.
#  B. 'cost threshold for parallelism' set 5 -> 50 -> 55 with a read after each: config_change_log holds two rows for
#     it, 5 -> 50 and 50 -> 55, the second's valid_from = the first's valid_to.
#  C. the pivot: a second SQL Server instance imported with cost threshold 5 and a third with 5: the first's 55 is
#     is_odd, the others are not, common_in_use 5.
#  D. trace flag 3226 switched on (DBCC TRACEON(3226, -1)) between two reads, then off before a third: history holds
#     3226 added, then 3226 removed.
#  E. PostgreSQL: a pgAgent job over a stand-in schema read by the collector twice with its step's code changed in
#     between: 2 versions whose scripts are pgAdmin's DO block and differ in the code line; a pg_cron job imported
#     with a script holds it. A setting changed twice (instance_setting_history) shows two change-log rows.
#  F. the API: /api/jobs/history's changes carry script; /api/config/changes, /api/mssql/config/fleet,
#     /api/mssql/traceflags answer with the rows of B, C and D; /api/jobs/thresholds answers levels and status
#     (POST on a -no-login server is 403: thresholds need the UI login).
#  G. go test of the packages it changed, go vet, tsc.
set -euo pipefail
export PATH=$HOME/.local/share/mise/shims:$PATH
: "${PGVIGIL_ADMIN_DSN:?a superuser keyword DSN of the PostgreSQL, no password, no dbname}"
for t in docker psql curl python3 go; do command -v $t >/dev/null || { echo "FAIL: $t missing" >&2; exit 1; }; done
[ -f go.mod ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
SUF=$RANDOM; CT=pgvjd-$SUF; REPO_DB=pgvigil_jobddl_$SUF; AGENT_DB=pgvigil_jobddl_agent_$SUF
IMAGE=${PGVIGIL_MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
MSSQL_SA_PASSWORD="Pv9$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; export MSSQL_SA_PASSWORD SQLCMDPASSWORD=$MSSQL_SA_PASSWORD
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; OUT=$WORK/out; BIN=$WORK/pgvigil; SRVPID=
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() { local rc=$?; set +e
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null
  docker rm -f -v "$CT" >/dev/null 2>&1
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtqc "drop database if exists $REPO_DB with (force)" -c "drop database if exists $AGENT_DB with (force)" >/dev/null 2>&1
  rm -rf "$WORK"; exit $rc; }
trap cleanup EXIT INT TERM
PORT=$((21000 + RANDOM % 9000))
echo "load: $(cut -d' ' -f1-3 /proc/loadavg) (shared box)"
docker run -d --name "$CT" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -e MSSQL_AGENT_ENABLED=true -p 127.0.0.1:$PORT:1433 "$IMAGE" >/dev/null
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
sq() { docker exec -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -U sa -C -b -I -W -h -1 -s '|' -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
sq "SELECT 1" >/dev/null || fail "SQL Server did not come up"
for _ in $(seq 1 60); do [ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name LIKE 'SQLAgent%'")" -gt 0 ] 2>/dev/null && break; sleep 2; done
# the routes are the lead's (web.go, q_jobs_history.go, q_config_history.go): where the tree lacks them, a scratch copy
# takes PGVIGIL_JOBDDL_WIRING (the slice's wiring patch) and the proof says so
if grep -q '/api/config/changes' internal/web/web.go; then go build -o "$BIN" ./cmd/pgvigil; echo "binary: wired in this tree"
else
  : "${PGVIGIL_JOBDDL_WIRING:?the tree lacks the routes: name the wiring patch in PGVIGIL_JOBDDL_WIRING}"
  mkdir -p "$WORK/src"; tar --exclude=./web/node_modules --exclude=./.git -cf - . | tar -C "$WORK/src" -xf -
  (cd "$WORK/src" && git apply "$PGVIGIL_JOBDDL_WIRING" && go build -o "$BIN" ./cmd/pgvigil) || fail "the scratch build with the wiring"
  echo "binary: wired in a scratch build (the join applies the same patch)"
fi
adm() { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB" -c "create database $AGENT_DB"
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB" PG_AGENT_DSN="$PGVIGIL_ADMIN_DSN dbname=$AGENT_DB"
export MSSQL_DSN="sqlserver://sa:$MSSQL_SA_PASSWORD@127.0.0.1:$PORT?database=master&encrypt=true&TrustServerCertificate=true"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
NS=jobddl-ms-$SUF; NP=jobddl-pga-$SUF
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
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$2" >"$OUT" 2>&1 || { cat "$OUT"; fail "collect $1 on $2"; }; }
# a diff of two texts as '-line' / '+line', the changed lines only
pdiff() { python3 -c "
import difflib, sys
a, b = open(sys.argv[1]).read().splitlines(), open(sys.argv[2]).read().splitlines()
d = list(difflib.unified_diff(a, b, lineterm='', n=0))[2:]   # the two header lines; a removed '-- comment' line starts '---' too
print('\n'.join(l for l in d if l[:1] in '+-'))" "$1" "$2"; }

echo "--- A. a SQL Server job changed twice"
J="pgvjd job $SUF"
sq "EXEC msdb.dbo.sp_add_job @job_name = N'$J', @owner_login_name = N'sa';
EXEC msdb.dbo.sp_add_jobstep @job_name = N'$J', @step_id = 1, @step_name = N'one', @subsystem = N'TSQL', @command = N'SELECT 1;', @on_success_action = 3;
EXEC msdb.dbo.sp_add_jobstep @job_name = N'$J', @step_id = 2, @step_name = N'two', @subsystem = N'TSQL', @command = N'ALTER LOGIN x WITH PASSWORD = ''topsecret$SUF''';
EXEC msdb.dbo.sp_add_jobschedule @job_name = N'$J', @name = N'nightly $SUF', @freq_type = 4, @freq_interval = 1, @active_start_time = 235900;
EXEC msdb.dbo.sp_add_jobserver @job_name = N'$J';" >/dev/null
collect mssql_jobs "$NS"
IS=$(q "select instance_id from pgvigil.instances where name='$NS'")
JID=$(q "select job_id from pgvigil.mssql_jobs where instance_id=$IS and name='$J'"); [ -n "$JID" ] || fail "A: job not read"
sq "EXEC msdb.dbo.sp_update_jobstep @job_name = N'$J', @step_id = 1, @command = N'SELECT 2;';" >/dev/null
collect mssql_jobs "$NS"; collect mssql_jobs "$NS"
SID=$(sq "SELECT schedule_id FROM msdb.dbo.sysschedules WHERE name = N'nightly $SUF'")
sq "EXEC msdb.dbo.sp_update_schedule @schedule_id = $SID, @active_start_time = 233000;" >/dev/null
collect mssql_jobs "$NS"
vq="from pgvigil.job_versions where instance_id=$IS and scheduler='sqlagent' and job_id='$JID'"
R=$(q "select count(*) || '|' || count(script) || '|' || bool_or(script like '%topsecret%') $vq"); echo "  versions|scripts|secret: $R"
[ "$R" = "3|3|false" ] || fail "A: three versions with scripts, no secret"
for n in 1 2 3; do q "select script $vq and version_no=$n" > "$WORK/v$n.sql"; done
for k in "EXEC msdb.dbo.sp_add_job" "sp_add_jobstep" "sp_add_jobschedule" "@command = N'SELECT 1;'" "<masked>"; do grep -qF "$k" "$WORK/v1.sql" || fail "A: v1's script lacks $k"; done
D12=$(pdiff "$WORK/v1.sql" "$WORK/v2.sql"); D23=$(pdiff "$WORK/v2.sql" "$WORK/v3.sql")
echo "  v1->v2: $D12"; echo "  v2->v3: $D23"
[ "$D12" = "$(printf -- "-    @command = N'SELECT 1;',\n+    @command = N'SELECT 2;',")" ] || fail "A: the v1->v2 diff"
[ "$D23" = "$(printf -- "--- schedule: every day at 23:59\n+-- schedule: every day at 23:30\n-    @active_start_time = 235900,\n+    @active_start_time = 233000,")" ] || fail "A: the v2->v3 diff"
echo "A: OK"

echo "--- B. a setting changed twice"
cfg() { sq "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'cost threshold for parallelism', $1; RECONFIGURE;" >/dev/null; collect mssql_instance "$NS"; }
cfg 5; cfg 50; cfg 55
R=$(q "select string_agg(value_in_use || '>' || new_value_in_use || ' ' || (valid_from is not null), ',' order by valid_to) from pgvigil.config_change_log($IS) where name='cost threshold for parallelism'")
echo "  log: $R"; [ "$R" = "5>50 true,50>55 true" ] || fail "B: two rows"
[ "$(q "select count(*) from pgvigil.config_change_log($IS) a join pgvigil.config_change_log($IS) b on a.name=b.name and a.valid_to=b.valid_from where a.name='cost threshold for parallelism'")" = 1 ] || fail "B: valid_to of the first = valid_from of the second"
echo "B: OK"

echo "--- C. the pivot"
for n in b c; do I=$(q "select pgvigil.ensure_instance('jobddl-$n-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
  q "select pgvigil.import_mssql_instance($I, now(), '[{\"kind\":\"server\",\"server_name\":\"$n\"},{\"kind\":\"config\",\"name\":\"cost threshold for parallelism\",\"value\":5,\"value_in_use\":5}]')" >/dev/null; done
R=$(q "select string_agg(instance || '=' || value_in_use || ':' || is_odd || ':' || common_in_use, ',' order by instance) from pgvigil.mssql_config_pivot() where name='cost threshold for parallelism' and instance like 'jobddl-%'")
echo "  pivot: $R"; [ "$R" = "jobddl-b-$SUF=5:false:5,jobddl-c-$SUF=5:false:5,jobddl-ms-$SUF=55:true:5" ] || fail "C: the odd value"
echo "C: OK"

echo "--- D. trace flag history"
collect mssql_traceflags "$NS"; sq "DBCC TRACEON(3226, -1);" >/dev/null; collect mssql_traceflags "$NS"; sq "DBCC TRACEOFF(3226, -1);" >/dev/null; collect mssql_traceflags "$NS"
R=$(q "select string_agg(trace_flag || ' ' || change, ',' order by changed_at) from pgvigil.mssql_trace_flag_history where instance_id=$IS and trace_flag=3226")
echo "  history: $R"; [ "$R" = "3226 added,3226 removed" ] || fail "D: added then removed"
echo "D: OK"

echo "--- E. PostgreSQL: pgAgent over a stand-in schema, pg_cron imported, settings"
psql "$PG_AGENT_DSN" -XAtq -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA pgagent;
CREATE TABLE pgagent.pga_job (jobid serial PRIMARY KEY, jobjclid int NOT NULL DEFAULT 1, jobname text NOT NULL, jobdesc text NOT NULL DEFAULT '', jobhostagent text NOT NULL DEFAULT '', jobenabled bool NOT NULL DEFAULT true, jobcreated timestamptz NOT NULL DEFAULT now(), jobchanged timestamptz NOT NULL DEFAULT now(), jobagentid int, jobnextrun timestamptz, joblastrun timestamptz);
CREATE TABLE pgagent.pga_schedule (jscid serial PRIMARY KEY, jscjobid int NOT NULL, jscname text NOT NULL, jscdesc text NOT NULL DEFAULT '', jscenabled bool NOT NULL DEFAULT true, jscstart timestamptz NOT NULL DEFAULT '2026-01-01', jscend timestamptz, jscminutes bool[60] NOT NULL, jschours bool[24] NOT NULL, jscweekdays bool[7] NOT NULL, jscmonthdays bool[32] NOT NULL, jscmonths bool[12] NOT NULL);
CREATE TABLE pgagent.pga_jobstep (jstid serial PRIMARY KEY, jstjobid int NOT NULL, jstname text NOT NULL, jstdesc text NOT NULL DEFAULT '', jstenabled bool NOT NULL DEFAULT true, jstkind char NOT NULL, jstcode text NOT NULL, jstconnstr text NOT NULL DEFAULT '', jstdbname name NOT NULL DEFAULT '', jstonerror char NOT NULL DEFAULT 'f', jscnextrun timestamptz);
CREATE TABLE pgagent.pga_joblog (jlgid serial PRIMARY KEY, jlgjobid int NOT NULL, jlgstatus char NOT NULL DEFAULT 'r', jlgstart timestamptz NOT NULL DEFAULT now(), jlgduration interval);
CREATE TABLE pgagent.pga_jobsteplog (jslid serial PRIMARY KEY, jsljlgid int NOT NULL, jsljstid int NOT NULL, jslstatus char NOT NULL DEFAULT 'r', jslresult int, jslstart timestamptz NOT NULL DEFAULT now(), jslduration interval, jsloutput text);
INSERT INTO pgagent.pga_job (jobname) VALUES ('agg');
INSERT INTO pgagent.pga_schedule (jscjobid, jscname, jscminutes, jschours, jscweekdays, jscmonthdays, jscmonths) SELECT 1, 'at three', array_fill(false, ARRAY[60]), array_fill(false, ARRAY[24]), array_fill(false, ARRAY[7]), array_fill(false, ARRAY[32]), array_fill(false, ARRAY[12]);
UPDATE pgagent.pga_schedule SET jscminutes[1] = true, jschours[4] = true;
INSERT INTO pgagent.pga_jobstep (jstjobid, jstname, jstkind, jstcode) VALUES (1, 'run', 's', 'CALL agg.run(1)');
SQL
collect jobs "$NP"; psql "$PG_AGENT_DSN" -XAtqc "UPDATE pgagent.pga_jobstep SET jstcode = 'CALL agg.run(2)'"; collect jobs "$NP"
IA=$(q "select instance_id from pgvigil.instances where name='$NP'")
for n in 1 2; do q "select script from pgvigil.job_versions where instance_id=$IA and scheduler='pgagent' and version_no=$n" > "$WORK/a$n.sql"; done
grep -qF 'DO $pgagent$' "$WORK/a1.sql" && grep -qF "'{t,f,f" "$WORK/a1.sql" || fail "E: pgAgent's script shape"
D=$(pdiff "$WORK/a1.sql" "$WORK/a2.sql"); echo "  pgAgent v1->v2: $D"
[ "$D" = "$(printf -- '-    $code$CALL agg.run(1)$code$);\n+    $code$CALL agg.run(2)$code$);')" ] || fail "E: the pgAgent diff"
IP=$(q "select pgvigil.ensure_instance('jobddl-pg-$SUF', 'onprem', 'x', 170000, false, '{}', 'postgres')")
q "select pgvigil.import_jobs($IP, now(), '[{\"kind\":\"job\",\"scheduler\":\"pg_cron\",\"job_id\":1,\"job_name\":\"n\",\"schedule\":\"0 3 * * *\",\"command\":\"SELECT 1\",\"script\":\"SELECT cron.schedule_in_database(...)\"}]')" >/dev/null
[ "$(q "select script from pgvigil.job_versions where instance_id=$IP")" = "SELECT cron.schedule_in_database(...)" ] || fail "E: pg_cron's script kept"
q "insert into pgvigil.instance_setting_history values ($IP, now() - interval '2 hours', 'work_mem', '4MB', '8MB'), ($IP, now() - interval '1 hour', 'work_mem', '8MB', '16MB')" >/dev/null
[ "$(q "select count(*) from pgvigil.config_change_log($IP) where name='work_mem'")" = 2 ] || fail "E: two PostgreSQL change-log rows"
echo "E: OK"

echo "--- F. the API"
AP=$((20000 + RANDOM % 900)); U="http://127.0.0.1:$AP"
"$BIN" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$AP" -no-login >"$WORK/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "$U/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
js() { curl -fsS "$U/api/$1" | python3 -c "import json,sys
d=json.load(sys.stdin)
def rows(k):
    t=d.get(k) or {'columns':[],'rows':[]}; return [dict(zip(t['columns'],r)) for r in t['rows']]
$2"; }
R=$(js "jobs/history?engine=mssql&instance=$IS&scheduler=sqlagent&job=$JID" "print(sum(1 for v in rows('changes') if v.get('script')))"); [ "$R" = 3 ] || fail "F: scripts on the history ($R)"
R=$(js "config/changes?instance=$IS" "print(sum(1 for r in rows('changes') if r['name']=='cost threshold for parallelism'))"); [ "$R" = 2 ] || fail "F: change log ($R)"
R=$(js "mssql/config/fleet" "print(sum(1 for r in rows('pivot') if r['is_odd'] and r['name']=='cost threshold for parallelism'))"); [ "$R" = 1 ] || fail "F: pivot ($R)"
R=$(js "mssql/traceflags?instance=$IS" "print(len(rows('history')))"); [ "$R" = 2 ] || fail "F: trace flags ($R)"
R=$(js "jobs/thresholds?instance=$IS" "print(d['writable'], len(rows('status')))"); [ "$R" = "False 1" ] || fail "F: thresholds ($R)"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-Pgvigil: 1' -d '{}' "$U/api/jobs/thresholds")" = 403 ] || fail "F: a write without the UI login"
echo "F: OK"

echo "--- G. tests, vet, tsc"
go vet ./internal/mssql ./internal/collect ./internal/web >"$OUT" 2>&1 || { cat "$OUT"; fail "G: vet"; }
go test ./internal/mssql ./internal/collect ./internal/web -count=1 >"$OUT" 2>&1 || { tail -30 "$OUT"; fail "G: tests"; }
if [ -x web/node_modules/.bin/tsc ]; then (cd web && node_modules/.bin/tsc --noEmit) || fail "G: tsc"; else echo "  tsc: not checked (no web/node_modules)"; fi
echo "G: OK"
echo "PROOF OK"
