#!/usr/bin/env bash
# Proof of the SQL Server Agent alerts script (C13, B9d: internal/mssql/agentalerts_script.go, 'pgvigil mssql-agent-alerts'):
# the script as the CLI prints it, run by sqlcmd on a SQL Server container with SQL Server Agent on, its effect read
# back from msdb, and pgvigil's own checks read after it.
#
# Needs: docker with a SQL Server container (PGVIGIL_MSSQL_CONTAINER) with the Agent on, its sa password in
# MSSQL_SA_PASSWORD, PGVIGIL_MSSQL_ADDR (host:port of its 1433), PGVIGIL_BIN, psql and PGVIGIL_REPO_DSN (a superuser
# connection to a PostgreSQL sandbox in keyword form) for part G. What it makes carries this run's suffix or the
# '(pgvigil) ...' prefix and is dropped on every exit path: the alerts, two operators, one login, the repository database.
#
# Expected (written before its first run; the Linux stop is option (a) of an open question):
#  S. the script as printed, on this Linux container: 'pgvigil: STOPPED, nothing was created, changed or dropped: SQL
#     Server on Linux ...', and msdb holds no '(pgvigil) ...' alert after it. From here on the proof runs ITS OWN COPY
#     with that one WHEN line taken out (said in the output): as a login that is not sysadmin it stops with 'not a
#     member of sysadmin' and creates nothing.
#  A. seeded before run 1: the site alerts 'pgv site sev20 <suf>' (severity 20) and 'pgv site 823 <suf>' (error 823), each
#     enabled and notifying nobody, and the operator pgv_ops_<suf> with the address other-<suf>@example.com. Run 1
#     (-operator pgv_ops_<suf> -email pgv-<suf>@example.com -ag): 8 'created:' lines (severities 19, 21-25, errors 824,
#     825), 2 'covered:' lines naming the site alerts with 'it notifies nobody and starts no job', 'left out: the
#     Availability Group alerts' (Availability Groups off here), 'there: operator [pgv_ops_<suf>]', 8 'notifies:' lines.
#  B. run 2 of the same text: no 'created:' and no 'notifies:' line, 8 'there:' lines; msdb's sysalerts,
#     sysnotifications and sysoperators (row count and CHECKSUM_AGG of their columns) equal before and after it.
#  C. the guard: no '(pgvigil) Severity 20' and no '(pgvigil) Error 823'; the site alerts' rows equal before run 1 and
#     after run 2.
#  D. the reused operator: its row (name, enabled, email_address) equal before run 1 and after run 2 (read here only).
#  E. a second script with -operator pgv_new_<suf> -email new-<suf>@example.com: 'created: operator [pgv_new_<suf>]' and 8
#     'notifies:' lines; 16 notification rows on the 8 pgvigil alerts.
#  F. firing, measured: RAISERROR(N'pgvigil proof <suf>', 19, 1) WITH LOG; '(pgvigil) Severity 19''s occurrence_count
#     60 s later is printed - expected 0 (Microsoft lists Agent alerts as unsupported on Linux); a count above 0 is
#     printed as a measured fact, not a failure.
#  G. pgvigil's read after run 2 (collect -once mssql_instance and mssql_checks, sa as the read login): the stored rows
#     of pgvigil.mssql_agent_alert - the 8 '(pgvigil) ...' alerts enabled, notifies 2 (both operators after E),
#     include_event_description true; the two site alerts notifies 0 (amended by the build review: not the
#     findings, which B9a's Linux line turns 'not applicable' on this container; they are printed only).
#  Before A (amended): SQL Server Agent up - its 'SQLAgent - %' sessions seen within 120 s, then 10 s more
#  (sp_add_alert and sp_delete_alert are refused with 14258 while the Agent starts); never up = 'setup: the Agent is not
#  running'. F prints the Agent's session count beside its count.
#  H. the drop script (-print -drop, the proof's copy): 8 'dropped:' lines and pgvigil_alerts_left 0; the site alerts
#     and both operators stay.
#  NOT PROVEN HERE: firing on Windows, the Availability Group block on an AG, Managed Instance's 41914, RDS, Cloud SQL,
#  Azure SQL Database (their stop words only).
set -uo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${MSSQL_SA_PASSWORD:?}" "${PGVIGIL_MSSQL_CONTAINER:?}" "${PGVIGIL_MSSQL_ADDR:?}"
CT=$PGVIGIL_MSSQL_CONTAINER; ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM; OPS=pgv_ops_$SUF; NEW=pgv_new_$SUF; NOR=pgv_nosa_$SUF; REPO_DB=pgvigil_b9d_$SUF
PNOR="Pv9$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')a!"
W=$(mktemp -d); MADE_REPO=; MADE_ALERTS=
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
fail() { echo "FAIL: $*" >&2; exit 1; }
sq() { docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -U sa -d master -b -W -h -1 -Q "SET NOCOUNT ON; $1"; }
# runsql <file> [login password]: the file through sqlcmd as sa (or the login), its PRINTs and rows on stdout
runsql() {
  docker cp "$1" "$CT:/tmp/pgv_b9d_run.sql" >/dev/null || return 3
  if [ $# -ge 3 ]; then SQLCMDPASSWORD="$3" docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -U "$2" -d master -W -i /tmp/pgv_b9d_run.sql
  else docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -U sa -d master -W -i /tmp/pgv_b9d_run.sql; fi
}
cleanup() {
  local rc=$?
  # one batch per object kind, so one refusal leaves the rest to their own drops; the '(pgvigil) ...' alerts only when
  # this run made them (the guard below refuses a container that already holds some)
  local mine="name LIKE N'pgv site % $SUF'"; [ -n "$MADE_ALERTS" ] && mine="$mine OR name LIKE N'(pgvigil) %'"
  sq "DECLARE @a sysname; DECLARE c CURSOR LOCAL FOR SELECT name FROM msdb.dbo.sysalerts WHERE $mine;
      OPEN c; FETCH NEXT FROM c INTO @a; WHILE @@FETCH_STATUS = 0 BEGIN EXEC msdb.dbo.sp_delete_alert @name = @a; FETCH NEXT FROM c INTO @a; END; CLOSE c; DEALLOCATE c;" >/dev/null 2>&1 \
    || echo "CLEANUP: alerts of run $SUF may be left" >&2
  for o in "$OPS" "$NEW"; do sq "IF EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = N'$o') EXEC msdb.dbo.sp_delete_operator @name = N'$o';" >/dev/null 2>&1 || echo "CLEANUP: operator $o may be left" >&2; done
  sq "IF SUSER_ID(N'$NOR') IS NOT NULL DROP LOGIN [$NOR];" >/dev/null 2>&1 || echo "CLEANUP: login $NOR may be left" >&2
  [ -n "$MADE_REPO" ] && { psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; }
  rm -rf "$W"; exit $rc
}
trap cleanup EXIT
count() { grep -c "^$1" "$2" || true; }
msdb_state() { sq "SELECT CONCAT((SELECT COUNT(*) FROM msdb.dbo.sysalerts), ':', (SELECT CHECKSUM_AGG(CHECKSUM(name, message_id, severity, enabled, delay_between_responses, include_event_description, ISNULL(database_name, N''), ISNULL(event_description_keyword, N''))) FROM msdb.dbo.sysalerts),
  ' | ', (SELECT COUNT(*) FROM msdb.dbo.sysnotifications), ':', (SELECT STRING_AGG(CONCAT(a.name, N'>', o.name, N'#', n.notification_method), N',') WITHIN GROUP (ORDER BY a.name, o.name) FROM msdb.dbo.sysnotifications n JOIN msdb.dbo.sysalerts a ON a.id = n.alert_id JOIN msdb.dbo.sysoperators o ON o.id = n.operator_id),
  ' | ', (SELECT COUNT(*) FROM msdb.dbo.sysoperators), ':', (SELECT CHECKSUM_AGG(CHECKSUM(name, enabled, email_address)) FROM msdb.dbo.sysoperators))"; }
site_rows() { sq "SELECT name + '|' + CAST(enabled AS varchar(3)) + '|' + CAST(severity AS varchar(5)) + '|' + CAST(message_id AS varchar(10)) + '|' + CAST(delay_between_responses AS varchar(10)) FROM msdb.dbo.sysalerts WHERE name LIKE N'pgv site % $SUF' ORDER BY name"; }
op_row() { sq "SELECT name + '|' + CAST(enabled AS varchar(3)) + '|' + ISNULL(email_address, N'') FROM msdb.dbo.sysoperators WHERE name = N'$1'"; }
VER=$(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20)) + ' ' + LEFT(REPLACE(@@VERSION, CHAR(10), ' '), 60)")
[ -n "$VER" ] || fail "setup: SQL Server did not answer"
echo "SQL Server: $VER"
[ "$(sq "SELECT COUNT(*) FROM msdb.dbo.sysalerts WHERE name LIKE N'(pgvigil) %'")" = 0 ] || fail "setup: the container holds '(pgvigil) ...' alerts already"
MADE_ALERTS=1

"$BIN" mssql-agent-alerts -print -operator "$OPS" -email "pgv-$SUF@example.com" -ag > "$W/create.sql" || fail "setup: the CLI's -print"
"$BIN" mssql-agent-alerts -print -drop > "$W/drop.sql" || fail "setup: the CLI's -print -drop"
"$BIN" mssql-agent-alerts -print -operator "$NEW" -email "new-$SUF@example.com" > "$W/create2.sql" || fail "setup: the second -print"

echo "--- S. the script as printed, on this container"
runsql "$W/create.sql" > "$W/s.out" 2>&1
cat "$W/s.out" | head -3
grep -q "pgvigil: STOPPED, nothing was created, changed or dropped: SQL Server on Linux" "$W/s.out" || fail "S: the script did not stop on Linux: $(head -5 "$W/s.out")"
[ "$(sq "SELECT COUNT(*) FROM msdb.dbo.sysalerts WHERE name LIKE N'(pgvigil) %'")" = 0 ] || fail "S: the stopped script created an alert"
for f in create create2 drop; do grep -v "@@VERSION LIKE N'% on Linux %'" "$W/$f.sql" > "$W/$f-copy.sql"; done
[ "$(grep -c "on Linux %'" "$W/create-copy.sql")" = 0 ] && [ "$(($(wc -l < "$W/create.sql") - $(wc -l < "$W/create-copy.sql")))" = 1 ] || fail "S: the copy is not the script less one line"
echo "  from here: the proof's own copy of each script, the one 'on Linux' WHEN line taken out"
sq "CREATE LOGIN [$NOR] WITH PASSWORD = '$PNOR', CHECK_POLICY = OFF;" >/dev/null || fail "S: the login that is not sysadmin"
runsql "$W/create-copy.sql" "$NOR" "$PNOR" > "$W/s2.out" 2>&1
grep -q "not a member of sysadmin" "$W/s2.out" || fail "S: as a login that is not sysadmin: $(head -5 "$W/s2.out")"
[ "$(sq "SELECT COUNT(*) FROM msdb.dbo.sysalerts WHERE name LIKE N'(pgvigil) %'")" = 0 ] || fail "S: the script run as a login that is not sysadmin created an alert"
echo "S: OK"

echo "--- the Agent up before A (14258 while it starts)"
AG=0; for _ in $(seq 1 60); do AG=$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name LIKE N'SQLAgent - %'"); [ "${AG:-0}" -gt 0 ] 2>/dev/null && break; sleep 2; done
[ "${AG:-0}" -gt 0 ] 2>/dev/null || fail "setup: the Agent is not running (no 'SQLAgent - %' session in 120 s)"
sleep 10; echo "  the Agent's sessions: $AG"
echo "--- A. run 1"
sq "EXEC msdb.dbo.sp_add_alert @name = N'pgv site sev20 $SUF', @severity = 20, @enabled = 1;
    EXEC msdb.dbo.sp_add_alert @name = N'pgv site 823 $SUF', @message_id = 823, @severity = 0, @enabled = 1;
    EXEC msdb.dbo.sp_add_operator @name = N'$OPS', @enabled = 1, @email_address = N'other-$SUF@example.com';" >/dev/null || fail "A: the seeds"
SITE0=$(site_rows); OP0=$(op_row "$OPS")
runsql "$W/create-copy.sql" > "$W/a.out" 2>&1
grep -E '^(created|covered|there|left out|notifies|not created|not added|no operator|note|pgvigil)' "$W/a.out" | cut -c1-220
[ "$(count 'created: ' "$W/a.out")" = 8 ] || fail "A: 'created:' lines $(count 'created: ' "$W/a.out"), want 8"
for n in 19 21 22 23 24 25; do grep -q "^created: (pgvigil) Severity $n\$" "$W/a.out" || fail "A: severity $n not created"; done
for e in 824 825; do grep -q "^created: (pgvigil) Error $e\$" "$W/a.out" || fail "A: error $e not created"; done
[ "$(grep -c "^covered: .*\[pgv site .* $SUF\].*it notifies nobody and starts no job" "$W/a.out")" = 2 ] || fail "A: the two 'covered:' lines"
grep -q "^left out: the Availability Group alerts" "$W/a.out" || fail "A: the AG block was not left out"
grep -q "^there: operator \[$OPS\]" "$W/a.out" || fail "A: the operator line"
[ "$(count 'notifies: ' "$W/a.out")" = 8 ] || fail "A: 'notifies:' lines $(count 'notifies: ' "$W/a.out"), want 8"
grep -qiE "^Msg [0-9]+" "$W/a.out" && fail "A: a server error in run 1: $(grep -iE '^Msg' "$W/a.out" | head -2)"
echo "A: OK"

echo "--- B. run 2: nothing new, msdb unchanged"
M1=$(msdb_state); runsql "$W/create-copy.sql" > "$W/b.out" 2>&1; M2=$(msdb_state)
[ "$(count 'created: ' "$W/b.out")" = 0 ] && [ "$(count 'notifies: ' "$W/b.out")" = 0 ] || fail "B: run 2 created or added something"
[ "$(grep -c '^there: (pgvigil) ' "$W/b.out")" = 8 ] || fail "B: 'there:' lines $(grep -c '^there: (pgvigil) ' "$W/b.out"), want 8"
[ "$M1" = "$M2" ] || fail "B: msdb changed in run 2: '$M1' -> '$M2'"
echo "  msdb before and after run 2: $M2"
echo "B: OK"

echo "--- C. the guard"
[ "$(sq "SELECT COUNT(*) FROM msdb.dbo.sysalerts WHERE name IN (N'(pgvigil) Severity 20', N'(pgvigil) Error 823')")" = 0 ] || fail "C: a pgvigil alert on a covered condition"
[ "$(site_rows)" = "$SITE0" ] || fail "C: the site alerts changed: '$SITE0' -> '$(site_rows)'"
echo "C: OK"
echo "--- D. the reused operator"
[ "$(op_row "$OPS")" = "$OP0" ] || fail "D: the operator changed: '$OP0' -> '$(op_row "$OPS")'"
echo "  $OP0 (as before run 1)"
echo "D: OK"

echo "--- E. a second operator, named in a later run"
runsql "$W/create2-copy.sql" > "$W/e.out" 2>&1
grep -q "^created: operator \[$NEW\]" "$W/e.out" || fail "E: the operator was not created: $(grep -E '^(created|not created): operator' "$W/e.out")"
[ "$(count 'notifies: ' "$W/e.out")" = 8 ] || fail "E: 'notifies:' lines $(count 'notifies: ' "$W/e.out"), want 8"
[ "$(sq "SELECT COUNT(*) FROM msdb.dbo.sysnotifications n JOIN msdb.dbo.sysalerts a ON a.id = n.alert_id WHERE a.name LIKE N'(pgvigil) %'")" = 16 ] || fail "E: the notification rows"
echo "E: OK"

echo "--- F. firing, measured"
sq "RAISERROR(N'pgvigil proof $SUF', 19, 1) WITH LOG;" >/dev/null 2>&1 || true
sleep 60
FIRED=$(sq "SELECT occurrence_count FROM msdb.dbo.sysalerts WHERE name = N'(pgvigil) Severity 19'")
[[ "$FIRED" =~ ^[0-9]+$ ]] || fail "F: occurrence_count not read: '$FIRED'"
AGF=$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name LIKE N'SQLAgent - %'")
echo "  '(pgvigil) Severity 19' occurrence_count 60 s after a severity 19 error WITH LOG: $FIRED (the Agent's sessions now: $AGF)"
if [ "$FIRED" = 0 ]; then echo "F: OK (as Microsoft's page says: no alert fires on Linux)"; else echo "F: MEASURED: the alert fired on Linux ($FIRED), unlike Microsoft's list says"; fi

echo "--- G. pgvigil's own read"
psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" >/dev/null || fail "G: the repository"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB" B9D_SA="sqlserver://sa:$(printf %s "$MSSQL_SA_PASSWORD" | jq -sRr @uri)@$PGVIGIL_MSSQL_ADDR?database=master&encrypt=true&TrustServerCertificate=true"
N=b9d-alerts-$SUF
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: %s\n    engine: sqlserver\n    dsn: env:B9D_SA\n' "$N" > "$W/cfg.yaml"
"$BIN" migrate -config "$W/cfg.yaml" > "$W/g.out" 2>&1 || { tail -5 "$W/g.out"; fail "G: migrate"; }
for c in mssql_instance mssql_checks; do "$BIN" collect -config "$W/cfg.yaml" -once "$c" -instance "$N" >> "$W/g.out" 2>&1 || { tail -5 "$W/g.out"; fail "G: collect $c"; }; done
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
F=$(q "select string_agg(check_name || ' / ' || object, '; ' order by check_name, object) from pgvigil.mssql_checks_findings f join pgvigil.instances i using (instance_id) where i.name = '$N' and f.area = 'alerts'")
echo "  the alerts area's findings (printed only): $F"
GR=$(q "select count(*) filter (where a.name like '(pgvigil) %' and a.enabled and a.notifies = 2 and a.include_event_description) || '|' ||
               count(*) filter (where a.name like '(pgvigil) %') || '|' ||
               count(*) filter (where a.name in ('pgv site sev20 $SUF', 'pgv site 823 $SUF') and a.notifies = 0)
          from pgvigil.mssql_agent_alert a join pgvigil.instances i using (instance_id) where i.name = '$N'")
echo "  stored rows: (pgvigil) enabled, notifying 2, with the error text | (pgvigil) rows | site alerts notifying 0 = $GR"
[ "$GR" = "8|8|2" ] || fail "G: the stored alerts '$GR', want 8|8|2"
echo "G: OK"

echo "--- H. the drop"
runsql "$W/drop-copy.sql" > "$W/h.out" 2>&1
[ "$(count 'dropped: ' "$W/h.out")" = 8 ] || fail "H: 'dropped:' lines $(count 'dropped: ' "$W/h.out"), want 8: $(head -5 "$W/h.out")"
[ "$(sq "SELECT COUNT(*) FROM msdb.dbo.sysalerts WHERE name LIKE N'(pgvigil) %'")" = 0 ] || fail "H: a pgvigil alert is left"
[ "$(site_rows)" = "$SITE0" ] || fail "H: the site alerts changed"
[ "$(sq "SELECT COUNT(*) FROM msdb.dbo.sysoperators WHERE name IN (N'$OPS', N'$NEW')")" = 2 ] || fail "H: an operator went with the drop"
echo "H: OK"
echo "NOT PROVEN: firing on Windows, the Availability Group block on an AG, Managed Instance's 41914, RDS, Cloud SQL, Azure SQL Database (their stop words only)"
echo "proof-mssql-agent-alerts: PASS (S, A-E, F measured, G, H)"
