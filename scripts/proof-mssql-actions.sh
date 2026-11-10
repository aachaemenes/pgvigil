#!/usr/bin/env bash
# Proof of the SQL Server side of the actions door (migration 0067's actions_log columns, internal/mssql/actions.go,
# internal/web/actions_mssql.go): kill a session, start and stop an Agent job, THROUGH THE API of a running
# `pgvigil serve`, as a signed-in UI user, with every attempt read back from pgvigil.actions_log.
#
# Needs: docker with a SQL Server container (PGVIGIL_MSSQL_CONTAINER, default mssql-sandbox) with SQL Server Agent
# running, reachable from this machine on PGVIGIL_MSSQL_ADDR (default localhost:1433), its sa password in
# MSSQL_SA_PASSWORD, psql, curl, jq, and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form (host=... user=... dbname=...).
# The proof makes its own repository database, a UI user, six SQL Server logins (random suffix, random passwords:
# the read login, the actions login with ALTER ANY CONNECTION and SQLAgentOperatorRole in msdb and nothing else, two
# application logins, a login with no right at all, and a sysadmin login that exists only to be refused), msdb
# users for two of them and one Agent job, and drops them all at the end, on every exit path. It changes no server
# setting and kills only sessions of its own logins.
#
# Expected (written before the first run):
#  A. GET /api/mssql/actions/state: on the full instance kill, job_start and job_stop are on; on the instance whose
#     list is [job_start] kill is off with 'not on the instance's actions: list'; on the instance without an
#     actions_dsn every action is off with 'has no actions_dsn'.
#  B. the preview of the proof's own sleeping session (an application login, one open transaction): ok, with its
#     login, the program, open_transaction_count 1, the last statement holding the proof's marker and the statement
#     'KILL <id>'; no audit row for a preview.
#  C. refusals, each 409, each one audit row with outcome refused, and the session still connected after all of
#     them: a typed confirmation that is not the session id; the values of another login carried for that session id
#     ('now belongs to another session'); the instance whose list lacks kill; the instance without an actions_dsn;
#     a system session ('system session'); a session of the read login ('own read login'); a session of the actions
#     login ('actions login itself'); an actions_dsn that connects as the read login ('must be a login of its
#     own'); a sysadmin actions login ('sysadmin').
#     Without a UI session the POST is 401 and without the X-Pgvigil header 403: neither reaches the door and
#     neither is audited (there is no user to name).
#  D. the read login alone cannot kill: on the instance whose actions_dsn is a login without ALTER ANY CONNECTION the
#     attempt is 502 failed, the server's own error (Msg 6102, no permission to use KILL) is in the reply and in
#     the audit row, and the session is still connected.
#  E. the kill: 200 done; the session is gone on the server; one audit row with action kill, outcome done, the
#     statement 'KILL <id>', the session id, the application login, the UI user and the reason. The same request
#     again: 409 'not connected any more' (or, when the server gave the id to a new session, 'now belongs to another
#     session'); and when a new session of ANOTHER login really gets the killed session's id, the old values are
#     refused for it and it stays connected (reported as proven or as 'the id was not reused in this run').
#  F. the job the proof creates: preview shows its name, owner sa and state idle; job_start 200 done and the Agent
#     reports it running; preview then says running; a job_stop carrying another name is 409 ('now named'); job_stop
#     on the instance whose list lacks it is 409; job_stop 200 done and the Agent reports it stopped; the audit rows
#     carry 'EXEC msdb.dbo.sp_start_job @job_id = ...' and 'EXEC msdb.dbo.sp_stop_job @job_id = ...', the job's name
#     and no pid. A job_start through the login with no right: 502 failed with the server's own error.
#  G. the audit in total: the counts by instance and outcome are exactly those of the steps above; every row has
#     the UI user, a reason, a statement and engine sqlserver; PostgreSQL's rows still import through
#     import_actions_log as engine postgres (a cancel with its pid, an explain_analyze without one); a sqlserver
#     row with action 'terminate' and a kill without a session id are refused by the table.
#  NOT PROVEN HERE: a Windows login as the actions login, Azure SQL Managed Instance and RDS (no SQL Server Agent
#     rights of this shape were tried there), a session id reused inside the milliseconds between the check and KILL.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${MSSQL_SA_PASSWORD:?the sa password of the SQL Server sandbox}"
CT=${PGVIGIL_MSSQL_CONTAINER:-mssql-sandbox}; ADDR=${PGVIGIL_MSSQL_ADDR:-localhost:1433}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_mssqlactions_$SUF
MON=pgv_amon_$SUF; ACT=pgv_aact_$SUF; APP=pgv_aapp_$SUF; APP2=pgv_aapp2_$SUF; NOR=pgv_anor_$SUF; SYS=pgv_asys_$SUF
JOB=pgvproof_job_$SUF; USR=proofdba$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
PMON=$(pw); PACT=$(pw); PAPP=$(pw); PAPP2=$(pw); PNOR=$(pw); PSYS=$(pw); UPW=$(pw)
CFG=$(mktemp); TMPD=$(mktemp -d); LOG=$TMPD/serve.log; CJ=$TMPD/cookies; BODY=$TMPD/body
PORT=$((20000 + RANDOM % 20000)); U="http://127.0.0.1:$PORT"
fail() { echo "FAIL: $*" >&2; [ -s "$BODY" ] && { echo "  last reply: $(cat "$BODY")" >&2; }; exit 1; }
# the sa password reaches sqlcmd through the environment, by name: never on a command line another user can list
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
MADE_REPO=; MADE_JOB=; SRVPID=; BG=(); MADE_LOGINS=(); MADE_USERS=()
sqlcmd_() { docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -W -h -1 -s '|' "$@"; }
sq() { sqlcmd_ -U sa -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
# hold <login> <password> <batch>: a session that runs the batch and then sleeps, connected, for three minutes
hold() { ( { printf '%s\nGO\n' "$3"; sleep 180; } | SQLCMDPASSWORD="$2" docker exec -i -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -U "$1" -d master >/dev/null 2>&1 ) & BG+=($!); }
spids() { sq "SELECT ISNULL(STRING_AGG(CAST(session_id AS varchar(10)), ','), '') FROM sys.dm_exec_sessions WHERE login_name = '$1' AND program_name LIKE 'SQLCMD%'"; }
cleanup() {
  rc=$?
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null || true
  for p in "${BG[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  # only what THIS run created
  if [ -n "$MADE_JOB" ]; then sq "IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = '$JOB') BEGIN EXEC msdb.dbo.sp_stop_job @job_name = '$JOB'; END" >/dev/null 2>&1 || true
    sq "IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = '$JOB') EXEC msdb.dbo.sp_delete_job @job_name = '$JOB';" >/dev/null 2>&1 || echo "CLEANUP: job $JOB not deleted" >&2; fi
  for l in "${MADE_USERS[@]:-}"; do [ -n "$l" ] && { sq "IF USER_ID('$l') IS NOT NULL DROP USER [$l];" msdb >/dev/null 2>&1 || echo "CLEANUP: msdb user $l not dropped" >&2; }; done
  for l in "${MADE_LOGINS[@]:-}"; do
    [ -n "$l" ] || continue
    # a login with a live session cannot be dropped: its sessions (this proof's own) end first
    sq "DECLARE @k nvarchar(max) = N''; SELECT @k += N'KILL ' + CAST(session_id AS nvarchar(10)) + N';' FROM sys.dm_exec_sessions WHERE login_name = '$l'; EXEC (@k);
        IF SUSER_ID('$l') IS NOT NULL DROP LOGIN [$l];" >/dev/null 2>&1 || echo "CLEANUP: login $l not dropped" >&2
  done
  if [ -n "$MADE_REPO" ]; then psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; fi
  rm -rf "$CFG" "$TMPD"
  exit $rc
}
trap cleanup EXIT
command -v jq >/dev/null || fail "setup: jq is needed"
adm() { psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

[ "$(sq "SELECT ISNULL(SUSER_ID('$MON'), 0) + ISNULL(SUSER_ID('$ACT'), 0) + ISNULL(SUSER_ID('$APP'), 0) + ISNULL(SUSER_ID('$APP2'), 0) + ISNULL(SUSER_ID('$NOR'), 0) + ISNULL(SUSER_ID('$SYS'), 0) + (SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name = '$JOB')")" = 0 ] \
  || fail "setup: a name of this run exists already (suffix $SUF): run again"
mk() { sq "CREATE LOGIN [$1] WITH PASSWORD = '$2', CHECK_POLICY = OFF;"; MADE_LOGINS+=("$1"); }
mk "$MON" "$PMON"; mk "$ACT" "$PACT"; mk "$APP" "$PAPP"; mk "$APP2" "$PAPP2"; mk "$NOR" "$PNOR"; mk "$SYS" "$PSYS"
sq "GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON];"
sq "CREATE USER [$MON] FOR LOGIN [$MON]; ALTER ROLE db_datareader ADD MEMBER [$MON];" msdb; MADE_USERS+=("$MON")
# the actions login: these two things and nothing else
sq "GRANT ALTER ANY CONNECTION TO [$ACT];"
sq "CREATE USER [$ACT] FOR LOGIN [$ACT]; ALTER ROLE SQLAgentOperatorRole ADD MEMBER [$ACT];" msdb; MADE_USERS+=("$ACT")
sq "ALTER SERVER ROLE sysadmin ADD MEMBER [$SYS];"
sq "EXEC msdb.dbo.sp_add_job @job_name = '$JOB', @owner_login_name = 'sa', @description = 'made and dropped by proof-mssql-actions.sh';
    EXEC msdb.dbo.sp_add_jobstep @job_name = '$JOB', @step_name = 'wait', @subsystem = 'TSQL', @database_name = 'master', @command = 'WAITFOR DELAY ''00:02:00'';';
    EXEC msdb.dbo.sp_add_jobserver @job_name = '$JOB', @server_name = '(local)';"; MADE_JOB=1
JOBID=$(sq "SELECT CAST(job_id AS varchar(36)) FROM msdb.dbo.sysjobs WHERE name = '$JOB'")
[ -n "$JOBID" ] || fail "setup: the job was not created"

d() { echo "sqlserver://$1:$2@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"; }
export A_MON_DSN="$(d "$MON" "$PMON")" A_ACT_DSN="$(d "$ACT" "$PACT")" A_NOR_DSN="$(d "$NOR" "$PNOR")" A_SYS_DSN="$(d "$SYS" "$PSYS")"
export A_MON_AGAIN_DSN="$A_MON_DSN"
I1=proof-act-full-$SUF; I2=proof-act-jobstart-$SUF; I3=proof-act-nodsn-$SUF; I4=proof-act-noright-$SUF; I5=proof-act-sysadmin-$SUF; I6=proof-act-samelogin-$SUF
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $I1
    engine: sqlserver
    dsn: env:A_MON_DSN
    actions_dsn: env:A_ACT_DSN
    actions: [kill, job_start, job_stop]
  - name: $I2
    engine: sqlserver
    dsn: env:A_MON_DSN
    actions_dsn: env:A_ACT_DSN
    actions: [job_start]
  - name: $I3
    engine: sqlserver
    dsn: env:A_MON_DSN
  - name: $I4
    engine: sqlserver
    dsn: env:A_MON_DSN
    actions_dsn: env:A_NOR_DSN
    actions: [kill, job_start]
  - name: $I5
    engine: sqlserver
    dsn: env:A_MON_DSN
    actions_dsn: env:A_SYS_DSN
    actions: [kill]
  - name: $I6
    engine: sqlserver
    dsn: env:A_MON_DSN
    actions_dsn: env:A_MON_AGAIN_DSN
    actions: [kill]
EOF
"$BIN" migrate -config "$CFG" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "setup: migrate (a binary without the actions wiring refuses actions_dsn on a sqlserver instance)"; }
declare -A IID
for n in $I1 $I2 $I3 $I4 $I5 $I6; do IID[$n]=$(q "select pgvigil.ensure_instance('$n', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')"); done
PGVIGIL_PASSWORD="$UPW" "$BIN" user add -config "$CFG" "$USR" 2>/dev/null || fail "setup: user add"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" >"$LOG" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$LOG" >&2; fail "setup: serve exited"; }
[ "$(curl -s -o "$BODY" -w '%{http_code}' -c "$CJ" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "{\"username\":\"$USR\",\"password\":\"$UPW\"}" "$U/api/login")" = 200 ] || fail "setup: the UI login"
# post <path> <json>: the status code; the reply in $BODY
post() { curl -s -o "$BODY" -w '%{http_code}' -b "$CJ" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "$2" "$U/api/mssql/actions/$1"; }
jb() { jq -r "$1" "$BODY"; }
audit() { q "select count(*) from pgvigil.actions_log where instance_name like 'proof-act-%-$SUF'"; }
# kill_req <instance> <session> <login_time> <login> <confirm> [reason]
kill_req() { jq -cn --argjson i "${IID[$1]}" --argjson s "$2" --arg lt "$3" --arg l "$4" --arg c "$5" --arg r "${6:-the proof asks for it}" \
  '{instance_id: $i, action: "kill", session_id: $s, login_time: $lt, login: $l, confirm: $c, reason: $r}'; }
job_req() { jq -cn --argjson i "${IID[$1]}" --arg a "$2" --arg id "$JOBID" --arg n "$3" --arg c "$4" \
  '{instance_id: $i, action: $a, job_id: $id, job_name: $n, confirm: $c, reason: "the proof asks for it"}'; }
# refused <label> <text>: the last reply was a 409 refusal holding the text, and it added exactly one audit row
N=0
expect() { # expect <label> <got code> <want code> <outcome> <text in detail>
  [ "$2" = "$3" ] || fail "$1: HTTP $2, want $3"
  [ "$(jb .outcome)" = "$4" ] || fail "$1: outcome $(jb .outcome), want $4"
  case "$(jb .detail)" in *"$5"*) ;; *) fail "$1: the detail does not hold '$5'";; esac
  N=$((N + 1)); [ "$(audit)" = "$N" ] || fail "$1: the audit holds $(audit) rows, want $N"
  [ "$(q "select outcome from pgvigil.actions_log where instance_name like 'proof-act-%-$SUF' order by action_id desc limit 1")" = "$4" ] || fail "$1: the newest audit row's outcome"
  echo "  ok: $1 -> $2 $4: $(jb .detail | cut -c1-150)"
}

echo "--- A. what is on, per instance"
state() { curl -s -b "$CJ" "$U/api/mssql/actions/state?instance=${IID[$1]}" | jq -r "$2"; }
[ "$(state "$I1" '[.actions.kill.enabled, .actions.job_start.enabled, .actions.job_stop.enabled] | join(",")')" = "true,true,true" ] || fail "A: the full instance"
[ "$(state "$I2" '[.actions.kill.enabled, .actions.job_start.enabled, .actions.job_stop.enabled] | join(",")')" = "false,true,false" ] || fail "A: the [job_start] instance"
case "$(state "$I2" .actions.kill.reason)" in *"not on the instance's actions: list"*) ;; *) fail "A: the reason on the [job_start] instance";; esac
case "$(state "$I3" .actions.kill.reason)" in *"has no actions_dsn"*) ;; *) fail "A: the reason without an actions_dsn";; esac
echo "A: OK"

echo "--- B. the preview of the proof's own sleeping session"
hold "$APP" "$PAPP" "BEGIN TRANSACTION; SELECT 'pgvproof-target-$SUF';"
for _ in $(seq 1 30); do T=$(spids "$APP"); [ -n "$T" ] && break; sleep 0.2; done
[ -n "$T" ] && [ "${T#*,}" = "$T" ] || fail "B: the application login's session (got '$T')"
sleep 1
[ "$(post preview "{\"instance_id\":${IID[$I1]},\"action\":\"kill\",\"session_id\":$T}")" = 200 ] || fail "B: the preview's status"
[ "$(jb '[.ok, .target.login, .target.open_transaction_count, .statement] | join("|")')" = "true|$APP|1|KILL $T" ] || fail "B: the preview: $(cat "$BODY")"
case "$(jb .target.statement)" in *"pgvproof-target-$SUF"*) ;; *) fail "B: the last statement";; esac
case "$(jb .target.program)" in SQLCMD*) ;; *) fail "B: the program: $(jb .target.program)";; esac
LT=$(jb .target.login_time)
[ "$(audit)" = 0 ] || fail "B: a preview wrote an audit row"
echo "  the session shown: id $T, login $APP, logged in $LT, open transactions 1, program $(jb .target.program)"
echo "B: OK"

echo "--- C. the refusals, each audited"
expect "a typed confirmation that is not the session id" "$(post run "$(kill_req "$I1" "$T" "$LT" "$APP" "$((T + 1))")")" 409 refused "typed confirmation"
expect "the values of another login for this session id" "$(post run "$(kill_req "$I1" "$T" "$LT" "$APP2" "$T")")" 409 refused "now belongs to another session"
expect "another login time for this session id" "$(post run "$(kill_req "$I1" "$T" "2020-01-01T00:00:00Z" "$APP" "$T")")" 409 refused "now belongs to another session"
expect "kill is not on the instance's list" "$(post run "$(kill_req "$I2" "$T" "$LT" "$APP" "$T")")" 409 refused "not on the instance's actions: list"
expect "the instance has no actions_dsn" "$(post run "$(kill_req "$I3" "$T" "$LT" "$APP" "$T")")" 409 refused "has no actions_dsn"
IFS='|' read -r SSID SLT SLOGIN <<<"$(sq "SELECT TOP (1) CAST(session_id AS varchar(10)) + '|' + CONVERT(varchar(33), DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()), login_time), 126) + 'Z|' + login_name FROM sys.dm_exec_sessions WHERE is_user_process = 0 ORDER BY session_id")"
expect "a system session ($SSID)" "$(post run "$(kill_req "$I1" "$SSID" "$SLT" "$SLOGIN" "$SSID")")" 409 refused "system session"
hold "$MON" "$PMON" "SELECT 'pgvproof-reader-$SUF';"
hold "$ACT" "$PACT" "SELECT 'pgvproof-actor-$SUF';"
for _ in $(seq 1 30); do MS=$(spids "$MON"); AS=$(spids "$ACT"); [ -n "$MS" ] && [ -n "$AS" ] && break; sleep 0.2; done
[ -n "$MS" ] && [ -n "$AS" ] || fail "C: the read and actions logins' own sessions"
lt_of() { sq "SELECT CONVERT(varchar(33), DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()), login_time), 126) + 'Z' FROM sys.dm_exec_sessions WHERE session_id = $1"; }
expect "a session of the read login" "$(post run "$(kill_req "$I1" "$MS" "$(lt_of "$MS")" "$MON" "$MS")")" 409 refused "own read login"
expect "a session of the actions login" "$(post run "$(kill_req "$I1" "$AS" "$(lt_of "$AS")" "$ACT" "$AS")")" 409 refused "actions login itself"
expect "an actions_dsn that connects as the read login" "$(post run "$(kill_req "$I6" "$T" "$LT" "$APP" "$T")")" 409 refused "must be a login of its own"
expect "a sysadmin actions login" "$(post run "$(kill_req "$I5" "$T" "$LT" "$APP" "$T")")" 409 refused "sysadmin"
[ "$(curl -s -o "$BODY" -w '%{http_code}' -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "$(kill_req "$I1" "$T" "$LT" "$APP" "$T")" "$U/api/mssql/actions/run")" = 401 ] || fail "C: without a UI session the POST was not 401"
[ "$(curl -s -o "$BODY" -w '%{http_code}' -b "$CJ" -H 'Content-Type: application/json' --data "$(kill_req "$I1" "$T" "$LT" "$APP" "$T")" "$U/api/mssql/actions/run")" = 403 ] || fail "C: without the X-Pgvigil header the POST was not 403"
[ "$(audit)" = "$N" ] || fail "C: a request that never reached the door was audited"
echo "  ok: no UI session -> 401, no X-Pgvigil header -> 403, neither audited"
[ "$(spids "$APP")" = "$T" ] || fail "C: the session is gone after the refusals"
echo "C: OK ($N refusals, the session is still connected)"

echo "--- D. a login without ALTER ANY CONNECTION cannot kill: the server's own error"
expect "the actions login has no right" "$(post run "$(kill_req "$I4" "$T" "$LT" "$APP" "$T")")" 502 failed "the server refused KILL $T"
case "$(jb .server_message)" in *"Msg 6102"*) ;; *) fail "D: the server's message: $(jb .server_message)";; esac
[ "$(q "select server_message like 'Msg 6102%' from pgvigil.actions_log where instance_name = '$I4' order by action_id desc limit 1")" = t ] || fail "D: the audit row's server message"
echo "  the server said: $(jb .server_message)"
[ "$(spids "$APP")" = "$T" ] || fail "D: the session is gone"
echo "D: OK"

echo "--- E. the kill"
expect "the kill" "$(post run "$(kill_req "$I1" "$T" "$LT" "$APP" "$T" "blocks the nightly load, proof $SUF")")" 200 done "KILL $T sent"
for _ in $(seq 1 25); do [ -z "$(spids "$APP")" ] && break; sleep 0.2; done
[ -z "$(spids "$APP")" ] || fail "E: the session is still connected"
[ "$(q "select action || '|' || outcome || '|' || statement || '|' || pid || '|' || target_user || '|' || ui_user || '|' || reason || '|' || engine || '|' || (backend_start = '$LT'::timestamptz) from pgvigil.actions_log where instance_name = '$I1' order by action_id desc limit 1")" \
  = "kill|done|KILL $T|$T|$APP|$USR|blocks the nightly load, proof $SUF|sqlserver|true" ] || fail "E: the audit row: $(q "select * from pgvigil.actions_log where instance_name = '$I1' order by action_id desc limit 1")"
echo "  gone on the server; the audit row: $(q "select at, ui_user, action, outcome, statement, target_user, target_app, reason from pgvigil.actions_log where instance_name = '$I1' order by action_id desc limit 1")"
# the id may now be given to a new session: start one of ANOTHER login and try the old values on it
hold "$APP2" "$PAPP2" "SELECT 'pgvproof-other-$SUF';"
for _ in $(seq 1 30); do T2=$(spids "$APP2"); [ -n "$T2" ] && break; sleep 0.2; done
[ -n "$T2" ] || fail "E: the second application login's session"
if [ "$T2" = "$T" ]; then
  expect "the killed session's values on its reused id" "$(post run "$(kill_req "$I1" "$T" "$LT" "$APP" "$T")")" 409 refused "now belongs to another session"
  [ "$(spids "$APP2")" = "$T" ] || fail "E: the session that reused the id was killed"
  echo "  PROVEN: the server gave id $T to a session of $APP2, the old values were refused for it and it stays connected"
else
  code=$(post run "$(kill_req "$I1" "$T" "$LT" "$APP" "$T")")
  case "$(jb .detail)" in *"not connected any more"*|*"now belongs to another session"*) ;; *) fail "E: the same request again: $(jb .detail)";; esac
  expect "the same request again" "$code" 409 refused ""
  echo "  the id was not reused in this run (the new session got $T2): the real reuse is covered by part C's carried values only"
fi
echo "E: OK"

echo "--- F. the job: start and stop"
jstate() { sq "SELECT CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity ja WHERE ja.job_id = '$JOBID' AND ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL) THEN 'running' ELSE 'idle' END"; }
[ "$(post preview "{\"instance_id\":${IID[$I1]},\"action\":\"job_start\",\"job_id\":\"$JOBID\"}")" = 200 ] || fail "F: the preview's status"
[ "$(jb '[.ok, .target.job_name, .target.job_owner, .target.job_state] | join("|")')" = "true|$JOB|sa|idle" ] || fail "F: the preview: $(cat "$BODY")"
echo "  the job shown: $(jq -c .target "$BODY"), statement: $(jb .statement)"
expect "job_start through a login with no right" "$(post run "$(job_req "$I4" job_start "$JOB" "$JOB")")" 502 failed "the server refused EXEC msdb.dbo.sp_start_job"
echo "  the server said: $(jb .server_message)"
[ "$(jstate)" = idle ] || fail "F: the job runs after a failed start"
expect "job_start" "$(post run "$(job_req "$I1" job_start "$JOB" "$JOB")")" 200 done "sp_start_job"
for _ in $(seq 1 50); do [ "$(jstate)" = running ] && break; sleep 0.2; done
[ "$(jstate)" = running ] || fail "F: the Agent does not report the job running"
[ "$(post preview "{\"instance_id\":${IID[$I1]},\"action\":\"job_stop\",\"job_id\":\"$JOBID\"}")" = 200 ] && [ "$(jb .target.job_state)" = running ] || fail "F: the preview of the running job: $(cat "$BODY")"
expect "job_stop carrying another name" "$(post run "$(job_req "$I1" job_stop "some other job" "some other job")")" 409 refused "is now named"
expect "job_stop is not on the instance's list" "$(post run "$(job_req "$I2" job_stop "$JOB" "$JOB")")" 409 refused "not on the instance's actions: list"
expect "a typed confirmation that is not the job's name" "$(post run "$(job_req "$I1" job_stop "$JOB" "nope")")" 409 refused "typed confirmation"
[ "$(jstate)" = running ] || fail "F: the job stopped on a refusal"
expect "job_stop" "$(post run "$(job_req "$I1" job_stop "$JOB" "$JOB")")" 200 done "sp_stop_job"
for _ in $(seq 1 100); do [ "$(jstate)" = idle ] && break; sleep 0.2; done
[ "$(jstate)" = idle ] || fail "F: the Agent still reports the job running"
UJ=$(echo "$JOBID" | tr 'a-f' 'A-F')
[ "$(q "select string_agg(action || '|' || statement || '|' || target || '|' || target_id || '|' || coalesce(pid::text, 'no pid') || '|' || target_user, ' ; ' order by action_id) from pgvigil.actions_log where instance_name = '$I1' and outcome = 'done' and action like 'job_%'")" \
  = "job_start|EXEC msdb.dbo.sp_start_job @job_id = '$UJ'|$JOB|$JOBID|no pid|sa ; job_stop|EXEC msdb.dbo.sp_stop_job @job_id = '$UJ'|$JOB|$JOBID|no pid|sa" ] \
  || fail "F: the audit rows: $(q "select action, statement, target, target_id, pid, target_user from pgvigil.actions_log where instance_name = '$I1' and action like 'job_%'")"
echo "F: OK"

echo "--- G. the audit in total"
GOT=$(q "select string_agg(n || ':' || outcome || '=' || c, ' ' order by n, outcome) from (select split_part(instance_name, '-', 3) n, outcome, count(*) c from pgvigil.actions_log where instance_name like 'proof-act-%-$SUF' group by 1, 2) x")
echo "  $GOT ($N attempts)"
WANT="full:done=3 full:refused=9 jobstart:refused=2 nodsn:refused=1 noright:failed=2 samelogin:refused=1 sysadmin:refused=1"
[ "$GOT" = "$WANT" ] || fail "G: the audit holds '$GOT', want '$WANT'"
[ "$(q "select count(*) from pgvigil.actions_log where instance_name like 'proof-act-%-$SUF' and (ui_user <> '$USR' or reason = '' or statement is null or engine <> 'sqlserver' or detail is null)")" = 0 ] || fail "G: a row misses the user, the reason, the statement or the engine"
pgi=$(q "select pgvigil.ensure_instance('proof-act-pg-$SUF', 'onprem', '18', 180000, false, '{}')")
q "select pgvigil.import_actions_log($pgi, now(), '[{\"instance_name\":\"proof-act-pg-$SUF\",\"ui_user\":\"u\",\"action\":\"cancel\",\"pid\":7,\"reason\":\"a postgres row\",\"outcome\":\"done\"}]'::jsonb)" >/dev/null
q "select pgvigil.import_actions_log($pgi, now(), '[{\"instance_name\":\"proof-act-pg-$SUF\",\"ui_user\":\"u\",\"action\":\"explain_analyze\",\"reason\":\"a postgres row without a pid\",\"outcome\":\"done\"}]'::jsonb)" >/dev/null
[ "$(q "select string_agg(engine || '|' || action || '|' || coalesce(pid::text, 'no pid'), ' ; ' order by action_id) from pgvigil.actions_log where instance_name = 'proof-act-pg-$SUF'")" = "postgres|cancel|7 ; postgres|explain_analyze|no pid" ] \
  || fail "G: the PostgreSQL-shaped rows: $(q "select engine, action, pid from pgvigil.actions_log where instance_name = 'proof-act-pg-$SUF'")"
if q "select pgvigil.import_mssql_actions_log(${IID[$I1]}, now(), '[{\"instance_name\":\"$I1\",\"ui_user\":\"u\",\"action\":\"kill\",\"reason\":\"a kill without a session id\",\"outcome\":\"done\"}]'::jsonb)" >"$TMPD/bad.out" 2>&1; then fail "G: a kill without a pid was stored"; fi
grep -q "actions_log_pid_check" "$TMPD/bad.out" || { cat "$TMPD/bad.out" >&2; fail "G: the pid refusal's text"; }
if q "select pgvigil.import_mssql_actions_log(${IID[$I1]}, now(), '[{\"instance_name\":\"$I1\",\"ui_user\":\"u\",\"action\":\"terminate\",\"pid\":7,\"reason\":\"not an action of this engine\",\"outcome\":\"done\"}]'::jsonb)" >"$TMPD/bad.out" 2>&1; then fail "G: a sqlserver row with action terminate was stored"; fi
grep -q "actions_log_action_check" "$TMPD/bad.out" || { cat "$TMPD/bad.out" >&2; fail "G: the refusal's text"; }
: > "$BODY"
echo "G: OK"

echo "NOT PROVEN: a Windows login as the actions login, Managed Instance and RDS, a session id reused between the check and KILL"
echo "proof-mssql-actions: PASS (A-G)"
