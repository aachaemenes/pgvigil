#!/usr/bin/env bash
# Proof of SQL Server database mirroring on a REAL pair (task 381; migration 0143, internal/mssql/mirroring.go): the
# lab of scripts/lab/win-mirroring.ps1 (three named SQL Server 2022 instances on one Windows host - a principal, a
# mirror, a witness - and the mirrored database pgvmirror in high-safety mode with the witness), read by pgvigil's own
# collector from another machine through the lab's one firewall rule.
#
# Needs: docker (the SQL Server image below holds the sqlcmd this proof runs as sa, in one helper container on the
# host's network), psql, python3, a go toolchain at the repository root, and
#   PGVIGIL_REPO_DSN       a superuser connection to a PostgreSQL sandbox in KEYWORD form
#   PGVIGIL_MIRROR_HOST    the lab host's address (the rule admits this machine only)
#   PGVIGIL_MIRROR_SA_FILE the lab's sa password file (win-mirroring.ps1's secret\sa.pw, copied here, mode 600)
# Optional: PGVIGIL_MIRROR_PORTS (default 14331,14332,14333: principal, mirror, witness as the lab made them),
# PGVIGIL_MSSQL_IMAGE (default mcr.microsoft.com/mssql/server:2022-CU27-GDR2-ubuntu-22.04, for its sqlcmd only).
#
# What it makes, and removes on every exit path: the helper container (pgvmirp<8 hex>), a monitoring login on each of
# the three instances (VIEW SERVER STATE, VIEW ANY DEFINITION, a user in msdb with db_datareader), its repository
# database, and rows of its own in pgvmirror's table lab_rows. Every fault it makes it undoes, and the pair is left
# SYNCHRONIZED with the witness CONNECTED and PGVPRINCIPAL the principal (read back), as the lab handed it over.
# It never touches the host's other instances.
#
# Expected (written before the first run):
#  M1. the three instances answer as sa; pgvmirror on the principal: PRINCIPAL, SYNCHRONIZED, safety FULL, witness
#      CONNECTED; on the mirror: MIRROR, SYNCHRONIZED; the witness lists pgvmirror.
#  M2. the existing read, proven: one read of mssql_mirroring on each partner as the monitoring login, none partial or
#      skipped; the principal's stored row equals sa's sys.database_mirroring (role, state, state code, safety, partner
#      instance, witness, witness state, role sequence), values_hidden false. The mirror's: sys.database_mirroring shows
#      a mirror database's values to sysadmin only (Microsoft), so the login's row is the mirror by its Database
#      Mirroring counter instance: role MIRROR (sa reads MIRROR), values_hidden true, state / partner / witness empty,
#      the redo queue a number (rewritten after run mir3, whose M2 found the mirror unread: the read's defect, fixed).
#      The endpoint stored STARTED with its port (5023 / 5024); the database state ONLINE on the principal, RESTORING
#      on the mirror. The counter types of 'Log Bytes Sent/sec', 'Redo
#      Bytes/sec', 'Transaction Delay', 'Mirrored Write Transactions/sec' printed (the question a cumulative type
#      answers). The witness's read stores nothing (sys.database_mirroring lists no mirrored database there). Under a
#      write load, a second read gives the principal a send rate above 0 KB/s and a transaction delay per write as a
#      number. No mirroring finding at rest. TestHADRS3StatementsLive passes on the three instances.
#  M3. witness lost (its endpoint STOPPED: the T-SQL form of 'stop the witness'): within 90 s the principal stores witness
#      DISCONNECTED and raise 'the mirroring witness is disconnected' (warning; DBA Dash's state); STARTED again:
#      gone within 120 s.
#  M4. a manual role swap (SET PARTNER FAILOVER on the principal): within 90 s both instances store a row in
#      mssql_mirroring_role_changes (the principal's PRINCIPAL -> MIRROR, the mirror's MIRROR -> PRINCIPAL; the role
#      sequence is stored only on a side that is the principal: the login cannot see a mirror's) and raise 'the principal of a mirrored database changed' (critical), the pair SYNCHRONIZED
#      again; swapped back the same way.
#  M5. a witness failover (the principal's endpoint STOPPED: the mirror and the witness keep quorum and fail over):
#      the mirror becomes PRINCIPAL within 90 s; its read stores the role change MIRROR -> PRINCIPAL and raises the
#      critical role-swap finding for it (one finding per change in the hour, as a group's failover; the pair is read
#      after each hand-back, so the stored roles are the handed-back ones) - the case 0066 left silent (it ends
#      SYNCHRONIZED). (Rewritten after run mir4, whose M5 compared all of the hour's swap findings to one.) The old
#      principal, read after the hand-back: a change PRINCIPAL -> PRINCIPAL by a higher role sequence (there and back
#      between two reads) and its finding. The stopped endpoint stands for an isolated principal that still runs, not a
#      crashed one. The old principal's endpoint STARTED: it rejoins as
#      the mirror; swapped back by a manual failover once SYNCHRONIZED.
#  M6. suspended: SET PARTNER SUSPEND, rows written: 'mirroring is disconnected or suspended' (critical) on the
#      principal; with log_send_queue_kb 1 for the principal from the configuration, 'the mirroring send queue is over
#      its threshold' (warning) not at the first read and not before 240 s, by 420 s (the reads of 5 minutes); RESUME,
#      the threshold still 1 KB: within 180 s no mirroring state finding (the queue drained).
#  M7. disconnected: the mirror's endpoint STOPPED: the principal's read stores DISCONNECTED and raises 'mirroring is
#      disconnected or suspended' (critical); STARTED: gone within 120 s.
#  M8. log shipping's mirror exclusion (task 384): with the mirror's logship_restore_age at 0.5 / 1 minute and
#      new_database_hours 0 (its log restore is hours old), mssql_logshipping on the mirror stores pgvmirror as a restore
#      row with is_mirrored true and raises no log shipping finding.
#  In M3, M6, M7 'gone' = no mirroring state finding; a role-swap finding stays its hour by design (M4, M5).
#  M9. the pair handed back: PGVPRINCIPAL principal, SYNCHRONIZED, witness CONNECTED (read back); the logins dropped.
#  NOT PROVEN HERE: a network split between the partners (all three on one host); PENDING_FAILOVER and UNSYNCHRONIZED
#  (transient: their rule is proven over stub rows); the redo-queue tier on a real mirror for 5 minutes (the mirror's
#  redo queue is read and printed under load; the rule is the availability groups' own, proven over samples); an RDS
#  instance (the gate is proven over stub rows); the witness's own view (sys.database_mirroring_witnesses: not read);
#  the isolated old principal's own read while it is cut off (M5 reads it after the hand-back); 'the mirroring
#  endpoint is not started' on a real partner (proven over stub rows, proof-mssql-hadr.sh part T).
#  Runs from M1 on: a pair found otherwise at M1 is never written to; a login or helper left by a killed run fails M1.
set -euo pipefail
: "${PGVIGIL_REPO_DSN:?a superuser keyword DSN of the PostgreSQL sandbox}" "${PGVIGIL_MIRROR_HOST:?the lab host}" "${PGVIGIL_MIRROR_SA_FILE:?the lab sa password file}"
IMAGE=${PGVIGIL_MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-CU27-GDR2-ubuntu-22.04}
IFS=, read -r PPORT MPORT WPORT <<<"${PGVIGIL_MIRROR_PORTS:-14331,14332,14333}"
H=$PGVIGIL_MIRROR_HOST
[ -r "$PGVIGIL_MIRROR_SA_FILE" ] || { echo "FAIL: cannot read $PGVIGIL_MIRROR_SA_FILE" >&2; exit 1; }
SAPW=$(tr -d '\r\n' < "$PGVIGIL_MIRROR_SA_FILE")   # handed to S / Sin only, never exported
ADMIN_DSN=$PGVIGIL_REPO_DSN
TAG=pgvmirp$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
REPO_DB=pgvigil_mirproof_${TAG#pgvmirp}
LM=pgvmir_mon_${TAG#pgvmirp}
PM="Pv9$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; OUT=$WORK/out
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok $*"; }
HELPER=; MADE_REPO=; MADE_LOGIN=; FAULTED=
declare -A PORT=([p]=$PPORT [m]=$MPORT [w]=$WPORT) NAME=([p]=PGVPRINCIPAL [m]=PGVMIRROR [w]=PGVWITNESS)
S() { SQLCMDPASSWORD=$SAPW docker exec -e SQLCMDPASSWORD "$TAG" /opt/mssql-tools18/bin/sqlcmd -C -S "tcp:$H,${PORT[$1]}" -U sa -b -I -W -h -1 -s '|' -d "${3:-master}" -Q "SET NOCOUNT ON; $2"; }
Sin() { SQLCMDPASSWORD=$SAPW docker exec -i -e SQLCMDPASSWORD "$TAG" /opt/mssql-tools18/bin/sqlcmd -C -S "tcp:$H,${PORT[$1]}" -U sa -b -I -W -h -1 -d master -i /dev/stdin; }
# Sq: a statement whose result is not needed - quiet when it works, its sqlcmd message and a FAIL line when it does not
# (set -e alone would end the proof with no word: run mir2). Never for a statement that carries a password (Sin).
Sq() { S "$@" >"$WORK/sq" 2>&1 || { cat "$WORK/sq" >&2; fail "sqlcmd on ${NAME[$1]}: ${2:0:70}"; }; }
# handback: the pair as the lab made it - PGVPRINCIPAL the principal, every endpoint started, resumed, SYNCHRONIZED
handback() {
  local x
  for x in p m w; do S "$x" "IF EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints WHERE name = 'pgv_mirroring' AND state_desc <> 'STARTED') ALTER ENDPOINT pgv_mirroring STATE = STARTED;" >/dev/null 2>&1; done
  for x in p m; do S "$x" "IF EXISTS (SELECT 1 FROM sys.database_mirroring WHERE database_id = DB_ID('pgvmirror') AND mirroring_role = 1 AND mirroring_state = 0) ALTER DATABASE pgvmirror SET PARTNER RESUME;" >/dev/null 2>&1; done
  for _ in $(seq 1 40); do
    [ "$(S p "SELECT CONCAT(mirroring_role_desc COLLATE DATABASE_DEFAULT, '|', mirroring_state_desc COLLATE DATABASE_DEFAULT, '|', mirroring_witness_state_desc COLLATE DATABASE_DEFAULT) FROM sys.database_mirroring WHERE database_id = DB_ID('pgvmirror')" 2>/dev/null)" = "PRINCIPAL|SYNCHRONIZED|CONNECTED" ] && return 0
    if [ "$(S m "SELECT CONCAT(mirroring_role_desc COLLATE DATABASE_DEFAULT, '|', mirroring_state_desc COLLATE DATABASE_DEFAULT) FROM sys.database_mirroring WHERE database_id = DB_ID('pgvmirror')" 2>/dev/null)" = "PRINCIPAL|SYNCHRONIZED" ]; then
      S m "ALTER DATABASE pgvmirror SET PARTNER FAILOVER;" >/dev/null 2>&1; fi
    sleep 3
  done
  return 1
}
cleanup() {
  rc=$?
  set +e
  if [ -n "$HELPER" ]; then
    # only a pair this run faulted is handed back: a pair found otherwise at M1 is never written to
    if [ -n "$FAULTED" ]; then handback || { echo "CLEANUP: the pair is NOT back to PGVPRINCIPAL principal, SYNCHRONIZED, witness CONNECTED" >&2; [ $rc = 0 ] && rc=1; }; fi
    S p "DELETE FROM dbo.lab_rows WHERE filler = 'pgvmirp';" pgvmirror >/dev/null 2>&1
    if [ -n "$MADE_LOGIN" ]; then
      for x in p m w; do
        S "$x" "IF USER_ID('$LM') IS NOT NULL DROP USER [$LM];" msdb >/dev/null 2>&1
        S "$x" "IF SUSER_ID('$LM') IS NOT NULL DROP LOGIN [$LM];" >/dev/null 2>&1
        [ "$(S "$x" "SELECT COUNT(*) FROM sys.server_principals WHERE name = '$LM'" 2>/dev/null)" = 0 ] || { echo "CLEANUP: login $LM left on ${NAME[$x]}" >&2; [ $rc = 0 ] && rc=1; }
      done
    fi
    docker rm -f "$TAG" >/dev/null 2>&1
  fi
  [ -n "$MADE_REPO" ] && { psql "$ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; }
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
command -v go >/dev/null 2>&1 && [ -f go.mod ] || fail "run from the repository root with a go toolchain"
BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil || fail "the build"; BIN=$WORK/pgvigil; fi
docker run -d --name "$TAG" --network host --label "pgvmirp=$TAG" --entrypoint sleep "$IMAGE" infinity >/dev/null; HELPER=1

echo "--- M1. the pair as sa"
for x in p m w; do
  v=$(S "$x" "SELECT CONCAT(@@SERVERNAME, '|', CAST(SERVERPROPERTY('ProductVersion') AS varchar(20)))") || fail "M1: ${NAME[$x]} on $H:${PORT[$x]} does not answer"
  echo "    ${NAME[$x]}: $v"
done
# the catalog's names carry the server's collation and its _desc columns another (Msg 451 in one CONCAT): each to one
MSQL="SELECT CONCAT(mirroring_role_desc COLLATE DATABASE_DEFAULT, '|', mirroring_state_desc COLLATE DATABASE_DEFAULT, '|', mirroring_state, '|', mirroring_safety_level_desc COLLATE DATABASE_DEFAULT, '|', mirroring_partner_instance COLLATE DATABASE_DEFAULT, '|', NULLIF(mirroring_witness_name, '') COLLATE DATABASE_DEFAULT, '|', mirroring_witness_state_desc COLLATE DATABASE_DEFAULT, '|', mirroring_role_sequence) FROM sys.database_mirroring WHERE database_id = DB_ID('pgvmirror')"
SP=$(S p "$MSQL"); SM=$(S m "$MSQL")
[[ "$SP" == PRINCIPAL\|SYNCHRONIZED\|*\|FULL\|*\|*\|CONNECTED\|* ]] || fail "M1: the principal reads '$SP'"
[[ "$SM" == MIRROR\|SYNCHRONIZED\|* ]] || fail "M1: the mirror reads '$SM'"
[ "$(S w "SELECT COUNT(*) FROM sys.database_mirroring_witnesses WHERE database_name = 'pgvmirror'")" = 1 ] || fail "M1: the witness does not list pgvmirror"
ok "M1: principal '$SP'; mirror '$SM'; the witness lists pgvmirror"
# a run killed before its trap (a box preemption, kill -9) leaves its login and helper: named, never taken
for x in p m w; do left=$(S "$x" "SELECT ISNULL(STRING_AGG(name, ','), '') FROM sys.server_principals WHERE name LIKE 'pgvmir[_]mon[_]%'")
  [ -z "$left" ] || fail "M1: ${NAME[$x]} has a monitoring login of an earlier run: $left (drop it by hand)"; done
left=$(docker ps -a --filter label=pgvmirp --format '{{.Names}}' | grep -vx "$TAG" | tr '\n' ' ')
[ -z "$left" ] || fail "M1: helper containers of an earlier run: $left (docker rm -f them)"

for x in p m w; do
  Sin "$x" <<<"CREATE LOGIN [$LM] WITH PASSWORD = '$PM', CHECK_POLICY = OFF;" >"$WORK/sin" 2>&1 || { cat "$WORK/sin"; fail "the monitoring login on ${NAME[$x]}"; }; MADE_LOGIN=1
  Sq "$x" "GRANT VIEW SERVER STATE TO [$LM]; GRANT VIEW ANY DEFINITION TO [$LM];"
  Sq "$x" "CREATE USER [$LM] FOR LOGIN [$LM]; ALTER ROLE db_datareader ADD MEMBER [$LM];" msdb
  export "MSSQL_MIR_${x^^}_DSN=sqlserver://$LM:$PM@$H:${PORT[$x]}?database=master&encrypt=true&TrustServerCertificate=true"
done
psql "$ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
declare -A N=([p]=mirproof-principal [m]=mirproof-mirror [w]=mirproof-witness) I
config() {   # config <the principal's mssql_thresholds block>
  { echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
    for x in p m w; do echo "  - name: ${N[$x]}"; echo "    engine: sqlserver"; echo "    dsn: env:MSSQL_MIR_${x^^}_DSN"; if [ "$x" = p ] && [ -n "$1" ]; then echo "$1"; fi; if [ "$x" = m ] && [ -n "${2:-}" ]; then echo "$2"; fi; done; } > "$CFG"
}
config ""
"$BIN" migrate -config "$CFG" >"$OUT" 2>&1 || { cat "$OUT"; fail "the migrate of $REPO_DB"; }
rd() { "$BIN" collect -config "$CFG" -once "${2:-mssql_mirroring}" -instance "${N[$1]}" >"$OUT" 2>&1 || { sed "s/$PM/<password>/g" "$OUT"; fail "the ${2:-mssql_mirroring} read of ${NAME[$1]}"; }
  if grep -q 'partial\|skipped' "$OUT"; then cat "$OUT"; fail "the read of ${NAME[$1]} is partial or skipped"; fi; }
rdpm() { rd p; rd m; }
fnd() { q "select coalesce(string_agg(severity, ',' order by severity), '') from pgvigil.mssql_hadr_findings where instance_id = ${I[$1]} and check_name = '$2' and object = '${3:-pgvmirror}'"; }
# mirfind [a check left out]: the mirroring findings of the two partners
mirfind() { q "select coalesce(string_agg(check_name || '=' || severity, '; ' order by check_name), 'none') from pgvigil.mssql_hadr_findings where instance_id in (${I[p]}, ${I[m]}) and check_name like '%mirror%' and check_name <> '${1:-}'"; }
await() { local limit=$1; shift; local t0=$SECONDS; while :; do rdpm; if "$@"; then echo "    after $((SECONDS - t0)) s"; return 0; fi; [ $((SECONDS - t0)) -ge "$limit" ] && return 1; sleep 5; done; }
load() { Sq p "INSERT dbo.lab_rows (filler) SELECT TOP (${1:-20000}) 'pgvmirp' FROM sys.all_objects a CROSS JOIN sys.all_objects b;" pgvmirror; }

echo "--- M2. the existing read, proven"
rd p; rd m; rd w
for x in p m w; do I[$x]=$(q "select instance_id from pgvigil.instances where name = '${N[$x]}'"); done
STO="select role || '|' || state || '|' || state_code || '|' || safety_level || '|' || coalesce(partner_instance, '') || '|' || coalesce(witness, '') || '|' || coalesce(witness_state, '') || '|' || role_sequence from pgvigil.mssql_mirroring_state where database_name = 'pgvmirror' and instance_id ="
SP=$(S p "$MSQL"); SM=$(S m "$MSQL")
[ "$(q "$STO ${I[p]}")" = "$SP" ] || fail "M2: the principal stored '$(q "$STO ${I[p]}")', sa reads '$SP'"
[ "$(q "select values_hidden::text from pgvigil.mssql_mirroring_state where database_name = 'pgvmirror' and instance_id = ${I[p]}")" = false ] || fail "M2: the principal's values_hidden is not false"
# the mirror as the login reads it: role MIRROR by its counter instance, the values sysadmin alone sees left empty
SMR=$(q "select role || '|' || coalesce(state, '') || '|' || coalesce(partner_instance, '') || '|' || coalesce(witness, '') || '|' || coalesce(values_hidden::text, 'null') || '|' || coalesce(redo_queue_kb::text, 'null') from pgvigil.mssql_mirroring_state where database_name = 'pgvmirror' and instance_id = ${I[m]}")
[[ "$SM" == MIRROR\|* && "$SMR" =~ ^MIRROR\|\|\|\|true\|[0-9]+$ ]] || fail "M2: the mirror stored '$SMR' (role|state|partner|witness|hidden|redo queue KB), sa reads '$SM'"
echo "    the mirror as the login reads it: $SMR"
[ "$(q "select (endpoint->>'endpoint_state') || '|' || (endpoint->>'endpoint_port') || '|' || database_state from pgvigil.mssql_mirroring_state where instance_id = ${I[p]}")" = "STARTED|5023|ONLINE" ] || fail "M2: the principal's endpoint / state"
[ "$(q "select (endpoint->>'endpoint_state') || '|' || (endpoint->>'endpoint_port') || '|' || database_state from pgvigil.mssql_mirroring_state where instance_id = ${I[m]}")" = "STARTED|5024|RESTORING" ] || fail "M2: the mirror's endpoint / state"
[ "$(q "select count(*) from pgvigil.mssql_mirroring_state where instance_id = ${I[w]}")" = 0 ] || fail "M2: the witness stored mirroring rows"
echo "    counter types on the principal: $(S p "SELECT STRING_AGG(CONCAT(RTRIM(counter_name), '=', cntr_type), ', ') FROM sys.dm_os_performance_counters WHERE object_name LIKE '%:Database Mirroring%' AND RTRIM(instance_name) = 'pgvmirror' AND RTRIM(counter_name) IN ('Log Bytes Sent/sec', 'Redo Bytes/sec', 'Transaction Delay', 'Mirrored Write Transactions/sec')")"
load 20000; rdpm; sleep 10; load 20000; rdpm
RATE=$(q "select coalesce(send_rate_kb_s::text, 'null') || '|' || coalesce(txn_delay_ms::text, 'null') from pgvigil.mssql_mirroring_state where instance_id = ${I[p]}")
echo "    the principal's send rate KB/s | delay ms per write: $RATE; the mirror's redo queue KB: $(q "select coalesce(redo_queue_kb::text, 'null') from pgvigil.mssql_mirroring_state where instance_id = ${I[m]}"), redo rate KB/s: $(q "select coalesce(redo_rate_kb_s::text, 'null') from pgvigil.mssql_mirroring_state where instance_id = ${I[m]}")"
python3 -c "import sys; a, b = '$RATE'.split('|'); sys.exit(0 if a != 'null' and float(a) > 0 and b != 'null' else 1)" || fail "M2: no send rate or delay under load: $RATE"
[ "$(q "select coalesce(redo_rate_kb_s::text, 'null') from pgvigil.mssql_mirroring_state where instance_id = ${I[m]}")" != null ] || fail "M2: no redo rate on the mirror under load"
[ "$(mirfind)" = none ] || fail "M2: mirroring findings at rest: $(mirfind)"
for x in p m w; do v="MSSQL_MIR_${x^^}_DSN"
  PGVIGIL_MSSQL_TEST_DSN="${!v}" go test -count=1 -run 'TestHADRS3StatementsLive' ./internal/mssql/ > "$OUT" 2>&1 || { sed "s/$PM/<password>/g" "$OUT"; fail "M2: TestHADRS3StatementsLive on ${NAME[$x]}"; }
done
ok "M2: the principal stored as sa reads it, the mirror as the least-privilege login reads it; endpoints, states, rates; no finding at rest; the statements live on the three"

echo "--- M3. the witness lost"
FAULTED=1
Sq w "ALTER ENDPOINT pgv_mirroring STATE = STOPPED;"
wset() { [ "$(fnd p 'the mirroring witness is disconnected')" = warning ]; }
await 90 wset || fail "M3: no witness warning (stored $(q "$STO ${I[p]}"))"
Sq w "ALTER ENDPOINT pgv_mirroring STATE = STARTED;"
wclear() { [ "$(mirfind 'the principal of a mirrored database changed')" = none ]; }   # a swap's finding stays its hour
await 120 wclear || fail "M3: still '$(mirfind)' after the witness came back"
ok "M3: the witness lost -> warning; back -> gone"

echo "--- M4. a manual role swap"
Sq p "ALTER DATABASE pgvmirror SET PARTNER FAILOVER;"
swapped() { [ "$(fnd p 'the principal of a mirrored database changed')" = critical ] && [ "$(fnd m 'the principal of a mirrored database changed')" = critical ]; }
await 90 swapped || fail "M4: the role-swap finding (stored changes: $(q "select coalesce(string_agg(instance_id || ':' || old_role || '->' || new_role, ' '), 'none') from pgvigil.mssql_mirroring_role_changes"))"
CH=$(q "select string_agg(case instance_id when ${I[p]} then 'principal' else 'mirror' end || ':' || old_role || '->' || new_role || ' seq ' || coalesce(old_sequence::text, '?') || '->' || coalesce(new_sequence::text, '?'), '; ' order by instance_id) from pgvigil.mssql_mirroring_role_changes")
echo "    stored: $CH"
[[ "$CH" == *"principal:PRINCIPAL->MIRROR"* && "$CH" == *"mirror:MIRROR->PRINCIPAL"* ]] || fail "M4: the role changes stored: $CH"
handback || fail "M4: the swap back"
rdpm   # the roles as handed back, stored (in service the next minute's read does this)
ok "M4: one swap -> a change on each side and the critical finding; swapped back"

echo "--- M5. a witness failover"
before=$(q "select count(*) from pgvigil.mssql_mirroring_role_changes where instance_id = ${I[m]}")
Sq p "ALTER ENDPOINT pgv_mirroring STATE = STOPPED;"
for _ in $(seq 1 30); do [ "$(S m "SELECT mirroring_role_desc FROM sys.database_mirroring WHERE database_id = DB_ID('pgvmirror')")" = PRINCIPAL ] && break; sleep 3; done
[ "$(S m "SELECT mirroring_role_desc FROM sys.database_mirroring WHERE database_id = DB_ID('pgvmirror')")" = PRINCIPAL ] || { S p "ALTER ENDPOINT pgv_mirroring STATE = STARTED;" >/dev/null 2>&1 || true; fail "M5: the mirror did not take over in 90 s"; }
rd m
NEW=$(q "select old_role || '->' || new_role || ' at ' || at from pgvigil.mssql_mirroring_role_changes where instance_id = ${I[m]} order by at desc limit 1")
[ "$(q "select count(*) from pgvigil.mssql_mirroring_role_changes where instance_id = ${I[m]}")" -gt "$before" ] && [[ "$NEW" == "MIRROR->PRINCIPAL at "* ]] || fail "M5: the mirror's newest role change is '$NEW' ($before before)"
echo "    stored: $NEW"
[ "$(q "select count(*) from pgvigil.mssql_hadr_findings where instance_id = ${I[m]} and check_name = 'the principal of a mirrored database changed' and severity = 'critical' and at = (select max(at) from pgvigil.mssql_mirroring_role_changes where instance_id = ${I[m]})")" = 1 ] || fail "M5: no critical role-swap finding for that change (the new principal's: '$(fnd m 'the principal of a mirrored database changed')')"
Sq p "ALTER ENDPOINT pgv_mirroring STATE = STARTED;"
handback || fail "M5: the pair did not come back to PGVPRINCIPAL"
rdpm
# the old principal, read again after it was the mirror and principal again: the role the same, the sequence higher
PCH=$(q "select old_role || '->' || new_role || ' seq ' || coalesce(old_sequence::text, '?') || '->' || coalesce(new_sequence::text, '?') from pgvigil.mssql_mirroring_role_changes where instance_id = ${I[p]} order by at desc limit 1")
echo "    the old principal after the hand-back: $PCH"
[[ "$PCH" =~ ^PRINCIPAL-\>PRINCIPAL\ seq\ ([0-9]+)-\>([0-9]+)$ ]] && [ "${BASH_REMATCH[2]}" -gt "${BASH_REMATCH[1]}" ] || fail "M5: the old principal's change after the hand-back: '$PCH' (expected PRINCIPAL->PRINCIPAL by a higher sequence)"
[ "$(q "select count(*) from pgvigil.mssql_hadr_findings where instance_id = ${I[p]} and check_name = 'the principal of a mirrored database changed' and at = (select max(at) from pgvigil.mssql_mirroring_role_changes where instance_id = ${I[p]})")" = 1 ] || fail "M5: no finding for the old principal's change"
ok "M5: the witness failed the pair over; the change stored and raised; handed back"

echo "--- M6. suspended, and the send queue"
config "    mssql_thresholds:
      log_send_queue_kb: 1"
Sq p "ALTER DATABASE pgvmirror SET PARTNER SUSPEND;"
t0=$SECONDS; FIRST=1; WAT=
while [ $((SECONDS - t0)) -lt 420 ]; do load 5000; rd p
  if [ "$(fnd p 'the mirroring send queue is over its threshold')" = warning ]; then
    [ -z "$FIRST" ] || fail "M6: the send-queue warning at the first read after SUSPEND: the 5 minutes of reads did not hold"
    WAT=$((SECONDS - t0)); break; fi
  FIRST=; sleep 15; done
[ -n "$WAT" ] && [ "$WAT" -ge 240 ] || fail "M6: the send-queue warning at '${WAT:-never}' s (it needs the reads of 5 minutes: not before 240 s, by 420 s)"
[ "$(fnd p 'mirroring is disconnected or suspended')" = critical ] || fail "M6: no suspended finding"
echo "    the send-queue warning after $((SECONDS - t0)) s"
Sq p "ALTER DATABASE pgvmirror SET PARTNER RESUME;"
await 180 wclear || fail "M6: still '$(mirfind)' 180 s after RESUME"   # the 1 KB threshold still set: the queue drained
config ""
ok "M6: suspended -> critical; the queue over 1 KB for 5 minutes -> warning; resumed -> gone"

echo "--- M7. disconnected"
Sq m "ALTER ENDPOINT pgv_mirroring STATE = STOPPED;"
dset() { [ "$(fnd p 'mirroring is disconnected or suspended')" = critical ] && [ "$(q "select state from pgvigil.mssql_mirroring_state where instance_id = ${I[p]}")" = DISCONNECTED ]; }
await 90 dset || { S m "ALTER ENDPOINT pgv_mirroring STATE = STARTED;" >/dev/null 2>&1 || true; fail "M7: no DISCONNECTED finding (stored $(q "$STO ${I[p]}"))"; }
Sq m "ALTER ENDPOINT pgv_mirroring STATE = STARTED;"
await 120 wclear || fail "M7: still '$(mirfind)' after the mirror came back"
ok "M7: disconnected -> critical; back -> gone"

echo "--- M8. log shipping leaves the mirror out"
# the mirror's log restore is hours old: with these tiers it would be 'log restores are behind' if it were not mirrored
config "" "    mssql_thresholds:
      new_database_hours: 0"
q "insert into pgvigil.pg_thresholds (key, level, instance_id, warn, crit, created_by, created_at) values ('logship_restore_age', 'instance', ${I[m]}, 0.5, 1, 'proof', now())" >/dev/null
rd m mssql_logshipping
[ "$(q "select coalesce(string_agg(database_name || ' mirrored=' || is_mirrored, ' '), 'none') from pgvigil.mssql_logrestore_state where instance_id = ${I[m]} and database_name = 'pgvmirror'")" = "pgvmirror mirrored=true" ] || fail "M8: the mirror's row: $(q "select coalesce(string_agg(database_name || ' mirrored=' || is_mirrored, ' '), 'none') from pgvigil.mssql_logrestore_state where instance_id = ${I[m]}")"
[ "$(q "select count(*) from pgvigil.mssql_hadr_findings where instance_id = ${I[m]} and check_name in ('log restores are behind', 'a database has been restoring for days', 'a log shipping copy is missing')")" = 0 ] || fail "M8: a log shipping finding on the mirror"
config ""
ok "M8: pgvmirror stored as mirrored and, with the age tiers at 0.5 / 1 minute and no new-database exemption, not judged as log shipping"

echo "--- M9. the pair handed back"
handback || fail "M9: the pair is not back"
[ "$(S p "SELECT CONCAT(mirroring_role_desc COLLATE DATABASE_DEFAULT, '|', mirroring_state_desc COLLATE DATABASE_DEFAULT, '|', mirroring_witness_state_desc COLLATE DATABASE_DEFAULT) FROM sys.database_mirroring WHERE database_id = DB_ID('pgvmirror')")" = "PRINCIPAL|SYNCHRONIZED|CONNECTED" ] || fail "M9: the principal reads otherwise"
ok "M9: PGVPRINCIPAL principal, SYNCHRONIZED, witness CONNECTED"
echo "PROOF OK (M1-M9)"
