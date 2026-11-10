#!/usr/bin/env bash
# Proof of the SQL Server services read (migration 0070, internal/mssql/services.go): the collection mssql_services
# as a least-privilege login against what sa reads, and the three Summary cells judged from it (the view
# pgvigil.mssql_health_status).
#
# Needs: docker with a SQL Server container (PGVIGIL_MSSQL_CONTAINER, default mssql-sandbox) reachable from this
# machine on PGVIGIL_MSSQL_ADDR (default localhost:1433), its sa password in MSSQL_SA_PASSWORD, psql, and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form (host=... user=... dbname=...).
# The proof makes its own repository database, three SQL Server logins (random suffix, random passwords) and a user
# for one of them in msdb, and drops them at the end, on every exit path. Part B stops Database Mail's queue
# (msdb.dbo.sysmail_stop_sp) and starts it again, on every exit path; it runs only where Database Mail is switched
# on and started before the proof, and changes no configuration value.
#
# Expected (written before the first run):
#  A. as the login with VIEW SERVER STATE, VIEW ANY DEFINITION and db_datareader in msdb: `collect -once
#     mssql_services` prints no "partial"; mssql_service holds as many present rows as sa counts in
#     sys.dm_server_services; mssql_health says agent_expected = (sa's EngineEdition <> 4), agent_running = what sa
#     reads (the Agent service's status where the server lists the service, else Agent sessions open), agent_source
#     accordingly, dbmail_on = sa's 'Database Mail XPs' value in use, dbmail_status = what sa's
#     msdb.dbo.sysmail_help_status_sp answers when it is on (NULL when off), dumps_read true, dump_count = sa's
#     count, last_dump_at = sa's newest creation time of the year 2000 or later (NULL when none is); the three
#     cells are sampled; collection_dates says ok.
#  B. Database Mail stopped by sa: the next read stores STOPPED and the dbmail cell is a warning with the value
#     'stopped'; started again: STARTED, no warning. SKIPPED (said) where Database Mail is off or was already stopped.
#  C. a login WITHOUT VIEW SERVER STATE: the run prints "skipped" naming the right; no mssql_health row.
#  D. a login with VIEW SERVER STATE and nothing else (no msdb user): the run prints "partial" naming
#     msdb.sys.service_queues; the Agent and dump parts are stored as in A; dbmail_on is stored, dbmail_status is
#     NULL; with Database Mail on, the cell's value is 'not readable' and it is not flagged.
#  E. the cells' rules, on rows imported for synthetic SQL Server instances (no server needed):
#     - a listed Agent service 'Stopped' with start mode Automatic: agent critical 'stopped'; with start mode
#       Disabled: warning 'disabled'; 'Running': not flagged, 'running';
#     - no service row: 4 Agent sessions = running (source sessions); 0 sessions = critical 'stopped';
#     - engine edition 4 (Express) with 0 sessions: not flagged, 'none (Express)';
#     - Database Mail off: 'off', not flagged; on with the queue not receiving: warning 'stopped';
#     - the newest dump 1 hour old: dumps critical; 3 days: warning; 30 days: not flagged; a count of 2 with no
#       dated file: not flagged, '2 files'; no dump: 'none';
#     - a read without a dumps row after one with it keeps the stored count and time, dumps_read false, and the
#       cell is not sampled;
#     - an OLDER read imported after a newer one changes nothing;
#     - a service missing from a later read is kept and marked not present;
#     - a service row 'Other (start operation pending)': warning with that status as the value, not 'stopped';
#     - a disabled Agent, then a read WITHOUT the service list and 0 sessions: still warning 'disabled' (the start
#       mode is kept), not critical;
#     - a service list imported late (older than the newest list stored) changes no row: a service a newer read
#       found gone stays not present;
#     - the payload without an agent row is refused; so is a PostgreSQL instance.
#  F. roles: pgvigil_collector may execute import_mssql_services and may not select mssql_health; pgvigil_reader
#     may select mssql_health, mssql_service and mssql_health_status and may not execute the import.
#  G. NOT PROVEN HERE: a stopped or disabled Agent on a live server (the container's Agent cannot be stopped
#     without a restart of the server: part E covers the rule on imported rows), SQL Server on Windows (more
#     services listed, real dump files with dates), Express, Amazon RDS, Azure SQL Managed Instance (whether it
#     lists services at all), SQL Server 2016-2019 (the list without the instant file initialization column on a
#     build before 2016 SP1 is a unit test of the statement's text only), a login without any access to msdb (msdb
#     lets every login in as guest, so that branch of the collector never runs here), a dump file with a date
#     through the live path (the sandbox's one file is undated), mssql_service.last_startup_at against sa's read,
#     a login with the two narrower SQL Server 2022 rights and not VIEW SERVER STATE (it is skipped).
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${MSSQL_SA_PASSWORD:?the sa password of the SQL Server sandbox}"
CT=${PGVIGIL_MSSQL_CONTAINER:-mssql-sandbox}; ADDR=${PGVIGIL_MSSQL_ADDR:-localhost:1433}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_mssqlsvc_$SUF
L1=pgv_mon_$SUF; L2=pgv_bare_$SUF; L3=pgv_vss_$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
P1=$(pw); P2=$(pw); P3=$(pw)
CFG=$(mktemp); OUT=$(mktemp)
fail() { echo "FAIL: $*" >&2; exit 1; }
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
MADE_DB=; MADE_L1=; MADE_L2=; MADE_L3=; MADE_U1=; MAIL_STOPPED=
sq() { docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -W -h -1 -s '|' -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
cleanup() {
  rc=$?
  if [ -n "$MAIL_STOPPED" ]; then sq "EXEC msdb.dbo.sysmail_start_sp;" >/dev/null 2>&1 || echo "CLEANUP: Database Mail was NOT started again (EXEC msdb.dbo.sysmail_start_sp)" >&2; fi
  if [ -n "$MADE_U1" ]; then sq "IF USER_ID('$L1') IS NOT NULL DROP USER [$L1];" msdb >/dev/null 2>&1 || echo "CLEANUP: msdb user $L1 not dropped" >&2; fi
  if [ -n "$MADE_L1" ]; then sq "IF SUSER_ID('$L1') IS NOT NULL DROP LOGIN [$L1];" >/dev/null 2>&1 || echo "CLEANUP: login $L1 not dropped" >&2; fi
  if [ -n "$MADE_L2" ]; then sq "IF SUSER_ID('$L2') IS NOT NULL DROP LOGIN [$L2];" >/dev/null 2>&1 || echo "CLEANUP: login $L2 not dropped" >&2; fi
  if [ -n "$MADE_L3" ]; then sq "IF SUSER_ID('$L3') IS NOT NULL DROP LOGIN [$L3];" >/dev/null 2>&1 || echo "CLEANUP: login $L3 not dropped" >&2; fi
  if [ -n "$MADE_DB" ]; then psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; fi
  rm -f "$CFG" "$OUT"
  exit $rc
}
trap cleanup EXIT
adm() { psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"; MADE_DB=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
sq "CREATE LOGIN [$L1] WITH PASSWORD = '$P1', CHECK_POLICY = OFF;"; MADE_L1=1
sq "GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1];"
sq "CREATE LOGIN [$L2] WITH PASSWORD = '$P2', CHECK_POLICY = OFF;"; MADE_L2=1
sq "CREATE LOGIN [$L3] WITH PASSWORD = '$P3', CHECK_POLICY = OFF;"; MADE_L3=1
sq "GRANT VIEW SERVER STATE TO [$L3];"
sq "CREATE USER [$L1] FOR LOGIN [$L1];" msdb; MADE_U1=1
sq "ALTER ROLE db_datareader ADD MEMBER [$L1];" msdb
dsn() { echo "sqlserver://$1:$2@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"; }
export MSSQL_MON_DSN; MSSQL_MON_DSN=$(dsn "$L1" "$P1")
export MSSQL_BARE_DSN; MSSQL_BARE_DSN=$(dsn "$L2" "$P2")
export MSSQL_VSS_DSN; MSSQL_VSS_DSN=$(dsn "$L3" "$P3")
N1=proof-svc-$SUF; N2=proof-svc-bare-$SUF; N3=proof-svc-vss-$SUF
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $N1
    engine: sqlserver
    dsn: env:MSSQL_MON_DSN
  - name: $N2
    engine: sqlserver
    dsn: env:MSSQL_BARE_DSN
  - name: $N3
    engine: sqlserver
    dsn: env:MSSQL_VSS_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
collect() { "$BIN" collect -config "$CFG" -once mssql_services -instance "${1:-$N1}" | tee "$OUT"; }
cell() { q "select critical || '|' || warning || '|' || coalesce(value, '') || '|' || sampled from pgvigil.mssql_health_status where instance_id=$1 and key='$2'"; }

echo "--- A. mssql_services as the least-privilege login"
IFS='|' read -r NSVC EE AGSVC AGSTAT AGSESS XPS NDUMP LASTDUMP <<<"$(sq "SELECT (SELECT COUNT(*) FROM sys.dm_server_services), CAST(SERVERPROPERTY('EngineEdition') AS int), (SELECT COUNT(*) FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server Agent%'), ISNULL((SELECT TOP (1) status_desc FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server Agent%'), ''), (SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name LIKE 'SQLAgent - %'), (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'Database Mail XPs'), (SELECT COUNT(*) FROM sys.dm_server_memory_dumps), ISNULL((SELECT CONVERT(varchar(19), SWITCHOFFSET(MAX(creation_time), '+00:00'), 126) FROM sys.dm_server_memory_dumps WHERE creation_time >= '2000-01-01'), '')")"
MAILSA=
if [ "$XPS" = 1 ]; then MAILSA=$(sq "EXEC msdb.dbo.sysmail_help_status_sp;"); fi
echo "  sa reads: $NSVC service(s) | edition $EE | Agent service rows $AGSVC, status '$AGSTAT', sessions $AGSESS | Database Mail XPs $XPS, status '$MAILSA' | $NDUMP dump file(s), newest dated '$LASTDUMP'"
[ -n "$EE" ] || fail "A: sa's own read came back empty"
if [ "$AGSVC" -gt 0 ]; then WANT_RUN=$([ "$AGSTAT" = Running ] && echo true || echo false); WANT_SRC=service
else WANT_RUN=$([ "$AGSESS" -gt 0 ] && echo true || echo false); WANT_SRC=sessions; fi
WANT_EXP=$([ "$EE" = 4 ] && echo false || echo true)
WANT_ON=$([ "$XPS" = 1 ] && echo true || echo false)
collect
if grep -q "partial" "$OUT"; then fail "A: the run says partial"; fi
iid=$(q "select instance_id from pgvigil.instances where name='$N1'")
[ "$(q "select count(*) from pgvigil.mssql_service where instance_id=$iid and is_present")" = "$NSVC" ] || fail "A: service rows (want $NSVC)"
GOT=$(q "select agent_expected || '|' || agent_running || '|' || agent_source || '|' || dbmail_on || '|' || coalesce(dbmail_status, '') || '|' || dumps_read || '|' || dump_count || '|' || coalesce(to_char(last_dump_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS'), '') from pgvigil.mssql_health where instance_id=$iid")
[ "$GOT" = "$WANT_EXP|$WANT_RUN|$WANT_SRC|$WANT_ON|$MAILSA|true|$NDUMP|$LASTDUMP" ] || fail "A: mssql_health is '$GOT', want '$WANT_EXP|$WANT_RUN|$WANT_SRC|$WANT_ON|$MAILSA|true|$NDUMP|$LASTDUMP'"
[ "$(q "select string_agg(key || '=' || sampled, ',' order by key) from pgvigil.mssql_health_status where instance_id=$iid")" = "agent=true,dbmail=true,dumps=true" ] || fail "A: the cells are not all sampled"
[ "$(q "select status from pgvigil.collection_dates where instance_id=$iid and collection='mssql_services'")" = ok ] || fail "A: collection_dates"
echo "  cells: agent $(cell "$iid" agent) | dbmail $(cell "$iid" dbmail) | dumps $(cell "$iid" dumps)"
echo "A: OK"

echo "--- B. Database Mail stopped and started"
if [ "$XPS" = 1 ] && [ "$MAILSA" = STARTED ]; then
  MAIL_STOPPED=1; sq "EXEC msdb.dbo.sysmail_stop_sp;" >/dev/null
  collect >/dev/null
  [ "$(q "select dbmail_status from pgvigil.mssql_health where instance_id=$iid")" = STOPPED ] || fail "B: not STOPPED after sysmail_stop_sp"
  [ "$(cell "$iid" dbmail)" = "0|1|stopped|true" ] || fail "B: the cell while stopped: $(cell "$iid" dbmail)"
  sq "EXEC msdb.dbo.sysmail_start_sp;" >/dev/null; MAIL_STOPPED=
  collect >/dev/null
  [ "$(cell "$iid" dbmail)" = "0|0|started|true" ] || fail "B: the cell after the start: $(cell "$iid" dbmail)"
  echo "B: OK"
else
  echo "B: SKIPPED (Database Mail XPs $XPS, status '$MAILSA' before the proof: nothing to stop)"
fi

echo "--- C. a login without VIEW SERVER STATE"
collect "$N2"
grep -q "skipped: the login lacks VIEW SERVER STATE" "$OUT" || fail "C: not skipped with the missing right"
[ "$(q "select count(*) from pgvigil.mssql_health h join pgvigil.instances i using (instance_id) where i.name='$N2'")" = 0 ] || fail "C: a mssql_health row"
echo "C: OK"

echo "--- D. VIEW SERVER STATE and no msdb"
collect "$N3"
grep -q "partial" "$OUT" || fail "D: the run does not say partial"
vid=$(q "select instance_id from pgvigil.instances where name='$N3'")
[ "$(q "select note like '%msdb.sys.service_queues%' from pgvigil.collection_dates where instance_id=$vid and collection='mssql_services'")" = t ] || fail "D: the note does not name msdb.sys.service_queues: $(q "select note from pgvigil.collection_dates where instance_id=$vid and collection='mssql_services'")"
[ "$(q "select agent_running || '|' || agent_source || '|' || dbmail_on || '|' || (dbmail_status is null) || '|' || dumps_read || '|' || dump_count from pgvigil.mssql_health where instance_id=$vid")" = "$WANT_RUN|$WANT_SRC|$WANT_ON|true|true|$NDUMP" ] \
  || fail "D: mssql_health: $(q "select agent_running, agent_source, dbmail_on, dbmail_status, dumps_read, dump_count from pgvigil.mssql_health where instance_id=$vid")"
if [ "$XPS" = 1 ]; then [ "$(cell "$vid" dbmail)" = "0|0|not readable|true" ] || fail "D: the cell: $(cell "$vid" dbmail)"; fi
echo "D: OK"

echo "--- E. the cells' rules on imported rows"
# each call names its own instance (a counter would not survive the $(...) subshell)
synth() { q "select pgvigil.ensure_instance('proof-svc-synth-$SUF-$1', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')"; }
imp() { q "select pgvigil.import_mssql_services($1, $2, '$3'::jsonb)" >/dev/null; }
svc() { echo "{\"kind\":\"service\",\"service_name\":\"SQL Server Agent (MSSQLSERVER)\",\"startup_type\":\"$2\",\"status\":\"$1\",\"is_clustered\":\"N\"}"; }
ag() { echo "{\"kind\":\"agent\",\"sessions\":$1,\"engine_edition\":${2:-3}}"; }
want() { [ "$(cell "$1" "$2")" = "$3" ] || fail "E: $4: the $2 cell is '$(cell "$1" "$2")', want '$3'"; }
s=$(synth svc); imp "$s" "now()" "[$(ag 0),$(svc Stopped Automatic)]"; want "$s" agent "1|0|stopped|true" "a stopped Agent service"
imp "$s" "now() + interval '1 second'" "[$(ag 0),$(svc Stopped Disabled)]"; want "$s" agent "0|1|disabled|true" "a disabled Agent service"
imp "$s" "now() + interval '2 seconds'" "[$(ag 0),$(svc Running Automatic)]"; want "$s" agent "0|0|running|true" "a running Agent service (no session seen)"
s=$(synth sess); imp "$s" "now()" "[$(ag 4)]"; want "$s" agent "0|0|running|true" "sessions, no service row"
[ "$(q "select agent_source from pgvigil.mssql_health where instance_id=$s")" = sessions ] || fail "E: agent_source"
imp "$s" "now() + interval '1 second'" "[$(ag 0)]"; want "$s" agent "1|0|stopped|true" "no session, no service row"
s=$(synth express); imp "$s" "now()" "[$(ag 0 4)]"; want "$s" agent "0|0|none (Express)|true" "Express"
want "$s" dbmail "0|0||false" "no dbmail row"; want "$s" dumps "0|0||false" "no dumps row"
s=$(synth mail); imp "$s" "now()" "[$(ag 4),{\"kind\":\"dbmail\",\"xps_in_use\":0,\"queues_seen\":0,\"receive_enabled\":0}]"; want "$s" dbmail "0|0|off|true" "Database Mail off"
imp "$s" "now() + interval '1 second'" "[$(ag 4),{\"kind\":\"dbmail\",\"xps_in_use\":1,\"queues_seen\":1,\"receive_enabled\":0}]"; want "$s" dbmail "0|1|stopped|true" "Database Mail stopped"
dump() { echo "{\"kind\":\"dumps\",\"dump_count\":$1,\"last_dump_at_utc\":$2}"; }
ago() { q "select '\"' || to_char((now() - interval '$1') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS') || 'Z\"'"; }
s=$(synth dumps); imp "$s" "now()" "[$(ag 4),$(dump 3 "$(ago '1 hour')")]"; want "$s" dumps "1|0|3 files|true" "a dump 1 hour old"
imp "$s" "now() + interval '1 second'" "[$(ag 4),$(dump 3 "$(ago '3 days')")]"; want "$s" dumps "0|1|3 files|true" "a dump 3 days old"
imp "$s" "now() + interval '2 seconds'" "[$(ag 4),$(dump 1 "$(ago '30 days')")]"; want "$s" dumps "0|0|1 file|true" "a dump 30 days old"
imp "$s" "now() + interval '3 seconds'" "[$(ag 4),$(dump 2 null)]"; want "$s" dumps "0|0|2 files|true" "two undated files"
imp "$s" "now() + interval '4 seconds'" "[$(ag 4),$(dump 0 null)]"; want "$s" dumps "0|0|none|true" "no dump"
imp "$s" "now() + interval '5 seconds'" "[$(ag 4),$(dump 3 "$(ago '1 hour')")]"
imp "$s" "now() + interval '6 seconds'" "[$(ag 4)]"; want "$s" dumps "0|0||false" "a read without the dumps part"
[ "$(q "select dump_count || '|' || (last_dump_at is not null) || '|' || dumps_read from pgvigil.mssql_health where instance_id=$s")" = "3|true|false" ] || fail "E: the stored dumps were not kept"
imp "$s" "now() - interval '1 hour'" "[$(ag 0)]"; want "$s" agent "0|0|running|true" "an older read after a newer one"
s=$(synth gone); imp "$s" "now()" "[$(ag 4),$(svc Running Automatic),{\"kind\":\"service\",\"service_name\":\"SQL Full-text Filter Daemon Launcher (MSSQLSERVER)\",\"startup_type\":\"Manual\",\"status\":\"Running\",\"is_clustered\":\"N\"}]"
imp "$s" "now() + interval '1 second'" "[$(ag 4),$(svc Running Automatic)]"
[ "$(q "select string_agg(is_present::text, ',' order by service_name) from pgvigil.mssql_service where instance_id=$s")" = "false,true" ] || fail "E: a service gone from the list"
# a late, older list (the daemon launcher back in it) must change nothing
imp "$s" "now() + interval '500 milliseconds'" "[$(ag 4),$(svc Running Automatic),{\"kind\":\"service\",\"service_name\":\"SQL Full-text Filter Daemon Launcher (MSSQLSERVER)\",\"startup_type\":\"Manual\",\"status\":\"Running\",\"is_clustered\":\"N\"}]"
[ "$(q "select string_agg(is_present::text, ',' order by service_name) from pgvigil.mssql_service where instance_id=$s")" = "false,true" ] || fail "E: a late older list marked a gone service present"
t=$(synth pending); imp "$t" "now()" "[$(ag 0),$(svc 'Other (start operation pending)' Automatic)]"; want "$t" agent "0|1|other (start operation pending)|true" "a service between states"
t=$(synth kept); imp "$t" "now()" "[$(ag 0),$(svc Stopped Disabled)]"; imp "$t" "now() + interval '1 second'" "[$(ag 0)]"; want "$t" agent "0|1|disabled|true" "a disabled Agent after a read without the service list"
if q "select pgvigil.import_mssql_services($s, now() + interval '9 seconds', '[{\"kind\":\"dumps\",\"dump_count\":0}]'::jsonb)" >"$OUT" 2>&1; then fail "E: a payload without an agent row was accepted"; fi
grep -q "no agent row" "$OUT" || fail "E: the refusal's text: $(cat "$OUT")"
pgi=$(q "select pgvigil.ensure_instance('proof-svc-pg-$SUF', 'onprem', '17.0', 170000, false, '{}')")
if q "select pgvigil.import_mssql_services($pgi, now(), '[$(ag 1)]'::jsonb)" >"$OUT" 2>&1; then fail "E: a PostgreSQL instance was accepted"; fi
grep -q "not a SQL Server instance" "$OUT" || fail "E: the PostgreSQL refusal's text: $(cat "$OUT")"
echo "E: OK"

echo "--- F. roles"
[ "$(q "select has_function_privilege('pgvigil_collector', 'pgvigil.import_mssql_services(int, timestamptz, jsonb)', 'execute') || '|' || has_function_privilege('pgvigil_reader', 'pgvigil.import_mssql_services(int, timestamptz, jsonb)', 'execute') || '|' || has_table_privilege('pgvigil_collector', 'pgvigil.mssql_health', 'select') || '|' || has_table_privilege('pgvigil_reader', 'pgvigil.mssql_health', 'select') || '|' || has_table_privilege('pgvigil_reader', 'pgvigil.mssql_service', 'select') || '|' || has_table_privilege('pgvigil_reader', 'pgvigil.mssql_health_status', 'select')")" = "true|false|false|true|true|true" ] \
  || fail "F: the rights (collector execute | reader execute | collector select | reader select health | service | status)"
echo "F: OK"
echo "PROOF OK"
