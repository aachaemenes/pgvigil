#!/usr/bin/env bash
# Proof of task 409 (B16, SQL Server configuration checks, with the linked servers and the Agent expectations):
# migration 0160, internal/mssql/dboptions.go (the collections mssql_confcheck and mssql_linkedserver_test), GET
# /api/mssql/config_checks, GET and POST /api/mssql/config_expect - against values the proof sets on a SQL Server of
# its own and reads back by hand, and against rows the proof writes into its own repository for what a Linux container
# cannot be made to show (a Windows service's start mode, a rename, a managed service, the properties another
# collection will read).
# Needs: docker (mcr.microsoft.com/mssql/server images), go, psql, curl, python3, the wiring patch applied to the tree
# first (the Info field and the runner's tag hand-off, web.go's three routes, the demo door's route, 0190's findings
# arms: without it the tree does not build), and
#   ADMIN_DSN        a superuser connection to a PostgreSQL in keyword form (default 'host=127.0.0.1 port=5432 user=postgres
#                    dbname=postgres'); the proof makes its own repository database and drops it.
#   PGVIGIL_IMAGES   the SQL Server images: the first the full run, the others the version run (default '2022-latest 2017-latest').
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment, never a command
# line. Only the collection a step names runs (pgvigil collect -once).
#
# Expected (written before the first run; red on the commit before 0160 at A: 'unknown collection mssql_confcheck',
# the API routes 404, 0160's relations missing):
#  A. the first image's container with its Agent on, on a docker network of its own; a monitor login with VIEW SERVER
#     STATE, VIEW ANY DEFINITION, a user in the proof database and db_datareader in msdb; migrate ok; mssql_instance,
#     mssql_services, mssql_traceflags, mssql_checks, mssql_jobs and mssql_confcheck each 'ok' as that login.
#  C0 the API: GET /api/mssql/config_checks gives exactly checks, databases, facts, linked, parts, runs, xe; GET
#     /api/mssql/config_expect exactly in_force, keys, tags; POST /api/mssql/config_expect 403 without the
#     X-Pgvigil header and 403 with it on a server without the UI login, nothing written.
#  C1 the defaults, on a container set to good practice (max server memory under the machine's memory, MAXDOP at the
#     advised value): the rules on by default are judged - the Agent's start mode, the server name, max server memory,
#     MAXDOP, scan for startup procs and the linked servers (none) ok; the engine's start mode 'not read' (SQL Server on
#     Linux lists no engine service); every rule whose source is a site's policy 'off' with 'set an expectation'; the
#     Browser rows and the Windows processor scheduling 'not applicable' on Linux: 6 ok, 1 not read, 20 off, 3 not
#     applicable, no finding. Every row names its source (Microsoft, dbatools formula or dbachecks policy). Then each
#     policy rule's expectation set at the instance to the container's own value: no warning, critical or info row, no
#     finding.
#  C2 each deviation made, read, then put back and the clear read:
#     Database Mail XPs 1 against 0 -> warning, a finding; recovery SIMPLE against FULL -> warning for the proof
#     database only (msdb, master, tempdb and model are left out by default); database-scoped MAXDOP 2 against 0 ->
#     warning; a database read-only, one RESTORING, one in STANDBY -> warning each; a database on the expected list
#     dropped -> critical; Query Store against the expected state -> warning (with the default list of databases
#     left out - master, tempdb, model - msdb, whose store is off, is judged; named among them it is not); event
#     sessions: one expected stopped
#     started, one expected running stopped, a running one off the allowed list, one expected to exist missing ->
#     warning each; trace flag 460 on for the server when not expected, an expected flag off -> warning each; MAXDOP
#     one above the advised value -> info, amber, NO finding row; 1 and the advised value -> ok; max server memory at
#     its 2147483647 default -> info on Linux ('the server may take all of it'); an expected operator dropped ->
#     warning, back under a name in another case -> ok; a job owned by a login on the list of owners not allowed ->
#     warning, and by one not on the list of owners allowed -> warning; an Agent expectation holding '@' refused,
#     nothing written; the fail-safe operator 'not read' (the monitor login may not run sp_MSgetalertinfo).
#     After one restart (errorlog.numerrorlogs 6 by mssql-conf, scan for startup procs 1, remote access 0): the error
#     log files kept read 6 by a login that is not sysadmin - a floor of 10 -> info, no finding, a floor of 6 -> ok;
#     scan for startup procs on with no startup procedure -> warning, with one -> ok and the procedure named, and
#     'not read' for a login without VIEW ANY DEFINITION; remote access in use 0 against an expectation of 1 ->
#     warning, of 0 -> ok; and while an expectation is set for remote access the day-one check's own finding for it
#     is not in pgvigil.findings, without one it is.
#  C3 rows written for instances of the proof's own: @@SERVERNAME differing from the server's name -> warning 'a rename
#     not finished' (NOT PROVEN live: SQL Server on Linux registers the host's name again at its start); a Windows
#     engine service Manual on a standalone instance -> warning, Automatic -> ok, Manual on a failover cluster instance
#     -> ok; an Agent service Manual -> warning; SQL Server Express -> the Agent's row 'not applicable'; max server
#     memory on Windows against the dbatools formula (16384 MB -> 11264, 32768 -> 25600, 2048 -> 1024), halved when a
#     second monitored instance shares the machine; the TCP port, the protocols and the processor scheduling once the
#     properties collection stores them (port 1434 against 1433 -> info, Tcp and Np against Tcp -> info, 38 against 24
#     -> info, each met -> ok) and 'not read' before; Amazon RDS, Azure SQL Managed Instance and Google Cloud SQL ->
#     'not applicable: <service> runs the host' for the start modes, the server name, the error log files, the startup
#     procedures, the protocols, the processor scheduling and the Browser, and on Managed Instance for the TCP port and
#     max server memory too; a mirror, an availability group secondary and a log shipping secondary that are RESTORING
#     or read-only -> no deviation; the fail-safe operator against its expected name in any case -> ok, another ->
#     warning.
#  C4 the scope order: an expectation at the root, then on a tag of the instance, then on the instance -
#     mssql_config_expect_in_force gives the value and 'root', 'tag:<tag>', 'instance' at each step and
#     mssql_config_expect_now agrees; inherit at the instance gives the tag's back, at the tag the root's. The API's
#     in_force part gives the instance's value too (an instance that is not a number: 400). A number outside its
#     key's range (scoped MAXDOP 3000000000, TCP port 70000, 5 error log files, a server option at -1) is refused,
#     nothing written; a stored value over the integer range is compared as a deviation, never an error.
#  C5 linked servers, a second container on the network as the remote: without the tag pgvigil:linkedserver-test the
#     collection is skipped and each linked server's row is 'off', 'set the tag'; with it at most 2 are tested a run,
#     each in its turn: a link to the live remote ok; one where only sa is mapped 'not read' ('the collector's login
#     has no mapping there', error 7416); one to a name that does not resolve -> warning with its error; a server of
#     another provider left out; the remote stopped -> the first link warning, 'failing since'; started again -> ok and
#     the finding gone. The list shows who is mapped at each, never a remote login's name. A failure whose last test
#     is five hours old (two servers are tested a run) is still a finding while the list is read. A mapped login the
#     remote server refuses (a wrong password: error 18456, whose text names the remote login) is grey, worded 'the
#     login mapped for the collector's login was refused at the remote server', and that login's name is in no stored
#     row, no rule's row and no API answer.
#  C6 the identity rule's lines (identity_warn_pct and identity_crit_pct under an instance's mssql_thresholds): a
#     tinyint identity at 153 of 255 (60 %) is 'ok' under the default lines (75 / 90), no finding; with 50 / 80 in the
#     instance's file it is a warning whose finding names 'warning at 50, critical at 80'; with 50 / 55 it is
#     critical; a warning line not under the critical one is refused when the file is read (the run does not start,
#     the stored verdict stays); without the two names the default lines judge it again.
#  C7 BLITZ-GAP (the lead 05:2x / 06:3x): sp_Blitz 55 as a configuration expectation - the key ('database', 'owner',
#     text, on by default, rule 'sp_Blitz 55'; RED ON THE BASE: no such key) and its rows over each user database's owner
#     (0090's options): with no scope, sa is expected - a database owned by another login is 'info' ('the owner is <x>;
#     the expected owner is sa (the default)'), sa's 'ok', and no finding row (info); the instance expecting <x>: the two
#     swap; 'OFF' (any case): every row off; inherit: back; a database left out: no row. The default grid (A and V) counts
#     the owner rows apart and asks them 'ok' (sa owns every user database there) once the key exists (review-24 B1). Until joined, scripts/blitzgap-join-draft-
#     config.sql gives the keys and the checks their lines. FOLD-55 (sp_Blitz 8.35 read, the lead 07:5x): master, model,
#     msdb and tempdb against the original sa always - msdb owned by <x> is 'info' even while the instance expects <x>
#     ('... (a system database: always the original sa)'), OFF and exclusions apply to them; a Managed Instance has no
#     owner row, read or not (sp_Blitz leaves 55 out there).
#  V. the version run: each further image repeats A, the default grid and the recovery, scoped MAXDOP and event
#     session deviations.
#  A met expected value for a server option leaves no day-one warning for it: not in the findings, not on the Checks
#  page's area (its count and its sentences), not in the findings that page lists ('default trace enabled' 0).
#  A login without the rights to see every linked server (ALTER ANY LINKED SERVER, ALTER ANY LOGIN, VIEW ANY
#  DEFINITION, setupadmin, sysadmin) does not see one whose default mapping was dropped; its list says it is short,
#  keeps a server it does not show, never marks an empty mapping read, and an empty short list is 'not read'.
#  A list's names are compared without case (System_Health, MSDB). The protocols take SQL Server's names only (TCP/IP
#  refused); on Linux a list without Tcp is info. A recovery model or Query Store state not read is 'not read' (tempdb's
#  SIMPLE is no deviation); a RESTORING database where the secondaries were not told apart is 'not read'; an Azure SQL
#  Database instance has no grid; a list rule carries its own collection's time; the linked test follows the tag in
#  the instance's configuration, not one set over it.
#  Each refusal is read with its reason. Before errorlog.numerrorlogs is set a floor reads 'not read', saying so; the
#  restart sets 12 (not SQL Server's default of 6). A database the login cannot enter (model) leaves the scoped MAXDOP
#  'not read', never ok. Every rule set at the instance in C1 reads ok. A job owner list takes a login name holding '@'
#  (an operator's never). The day-one finding for remote access is left out while any expectation is in force, met or
#  not, from the instance or the root.
#  NOT PROVEN here: SQL Server 2016 (no Linux image); a Windows server live (no write is made on the lab's Windows
#  VM: start modes, Named Pipes, the processor scheduling are proven on written rows); Managed Instance, RDS and Cloud
#  SQL live (rows written); the properties collection's own read of the port, the protocols and the scheduling; the
#  fail-safe operator read live; the editor's POST with a signed-in user.
set -uo pipefail
cd "$(dirname "$0")/.."
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
read -r -a IMAGES <<<"${PGVIGIL_IMAGES:-2022-latest 2017-latest}"
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
PGDB=pgv_cc_$SUF; MON=pgv_mon_$SUF; LOW=pgv_low_$SUF; OWN=pgv_own_$SUF; NET=pgv-cc-$SUF; REMOTE=pgv-ccr-$SUF
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SA_PW=$(pw); MON_PW=$(pw); LOW_PW=$(pw); FAILS=0; NP=0; SQL=; SRV_PID=
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\nMSSQL_AGENT_ENABLED=true\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null
  docker ps -aq --filter "label=pgv-cc-$SUF" | xargs -r docker rm -f -v >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
np() { echo "NOT PROVEN $*"; NP=$((NP + 1)); }
fail() { echo "FAIL $*"; exit 1; }
# sq: a statement as sa in the container $SQL (database $2, default master); sqr: the same in the remote container
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout "${SQ_TIMEOUT:-300}" docker exec -i --env-file "$TMPD/sa.env" "${SQC:-$SQL}" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -W -h -1 -s "|" -d "$0" -i /dev/stdin' "${2:-master}"; }
sqv() { local out; out=$(sq "$2" "${3:-master}" 2>&1) || bad "$1: $(tr '\n' ' ' <<<"$out" | head -c 300)"; }  # $1 label $2 statement [$3 db]
sqr() { SQC=$REMOTE sq "$@"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
eqv() { if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else bad "$1: got [$2] want [$3]"; fi; }
check() { local got; got=$(pq "$2" 2>&1); eqv "$1" "$got" "$3"; }
collect() { "$BIN" collect -config "${CFG:-$TMPD/m.yaml}" -once "$1" -instance "${2:-sqlbox}" > "$TMPD/collect.out" 2>&1 || { tail -5 "$TMPD/collect.out"; return 1; }; }
col() { local c; for c in "$@"; do collect "$c" || true; done; }
lastrun() { pq "SELECT d.status || coalesce(': ' || d.note, '') FROM pgvigil.collection_dates d JOIN pgvigil.instances i ON i.instance_id = d.instance_id WHERE d.collection = '$1' AND i.name = '${2:-sqlbox}'"; }
# ex: one attempt of the Expected values editor through its function, $1 the payload's fields; prints the outcome.
# exi / exn: set / inherit at the instance $IID. st: a rule's rows as 'object status' (the rule's own row: its status).
ex() { pq "SELECT pgvigil.import_mssql_config_expect(now(), '{\"ui_user\":\"proof\",$1}'::jsonb)->>'outcome'" 2>&1 | tr '\n' ' ' | sed 's/ *$//' | cut -c1-200; }
exi() { ex "\"op\":\"set\",\"level\":\"instance\",\"instance_id\":${2:-$IID},$1"; }
# exr: a set at the instance that must be refused - prints 'refused: <the function's reason>' (any other outcome as it is)
exr() { pq "SELECT r->>'outcome' || coalesce(': ' || (r->>'detail'), '') FROM (SELECT pgvigil.import_mssql_config_expect(now(), '{\"ui_user\":\"proof\",\"op\":\"set\",\"level\":\"instance\",\"instance_id\":${2:-$IID},$1}'::jsonb) r) s" 2>&1 | tr '\n' ' ' | sed 's/ *$//' | cut -c1-200; }
exn() { ex "\"op\":\"inherit\",\"level\":\"instance\",\"instance_id\":${2:-$IID},$1"; }
st() { pq "SELECT coalesce(string_agg(CASE WHEN object = '' THEN status ELSE object || ' ' || status END, ', ' ORDER BY object), 'no row') FROM pgvigil.mssql_config_checks_of(${3:-$IID}) WHERE check_name = '$1'${2:+ AND object = '$2'}"; }
det() { pq "SELECT coalesce(string_agg(detail, ' | ' ORDER BY object), 'no row') FROM pgvigil.mssql_config_checks_of(${3:-$IID}) WHERE check_name = '$1'${2:+ AND object = '$2'}"; }
rule() { eqv "$1" "$(st "$2" "${4:-}" "${5:-}")" "$3"; }   # $1 label $2 check_name $3 want [$4 object] [$5 instance]
finding() { pq "SELECT count(*) FROM pgvigil.mssql_config_check_findings WHERE instance_id = ${3:-$IID} AND check_name = '$1'${2:+ AND object = '$2'}"; }

for t in docker go psql curl python3; do command -v $t >/dev/null || fail "$t is not on this machine"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
BIN=$TMPD/pgvigil
go build -o "$BIN" ./cmd/pgvigil || fail "build"
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null || fail "repository database"
PGDSN="${ADMIN_DSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
docker network create "$NET" >/dev/null || fail "docker network"

# ---- a container, its logins, the repository ----------------------------------------------------------------------
wait_up() {  # $1 container (default $SQL)
  local r=""
  for _ in $(seq 1 150); do r=$(SQC=${1:-$SQL} sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb','Status')='ONLINE' THEN 1 ELSE 0 END" 2>/dev/null); [[ "$r" == 1 ]] && return 0; sleep 2; done
  return 1
}
# set_dsn: the logins' DSNs on the container's host port, read again after every restart (a port published as
# 127.0.0.1::1433 gets a new host port when the container restarts)
set_dsn() {
  PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
  export PGV_CC_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
  export PGV_CC_LOW="sqlserver://$LOW:$(urlq "$LOW_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
}
start_server() {  # $1 image tag
  SQL=pgv-cc-$SUF-${1%%-*}
  docker run -d --name "$SQL" --label "pgv-cc-$SUF" --network "$NET" --memory 6g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "mcr.microsoft.com/mssql/server:$1" >/dev/null || fail "docker run $1"
  SQLCMD=/opt/mssql-tools18/bin/sqlcmd
  for _ in $(seq 1 30); do docker exec "$SQL" test -e /opt >/dev/null 2>&1 && break; sleep 1; done
  docker exec "$SQL" test -x "$SQLCMD" || SQLCMD=/opt/mssql-tools/bin/sqlcmd
  wait_up || { docker logs --tail 15 "$SQL" 2>&1 | sed 's/^/     container: /'; fail "$1 did not come up (sqlcmd $SQLCMD)"; }
  MAJOR=$(sq "SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS int)")
  sq "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON];
CREATE LOGIN [$LOW] WITH PASSWORD = '$LOW_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$LOW];
CREATE LOGIN [$OWN] WITH PASSWORD = '$LOW_PW', CHECK_POLICY = OFF;" >/dev/null || fail "the logins"
  sq "CREATE USER [$MON] FOR LOGIN [$MON]; ALTER ROLE db_datareader ADD MEMBER [$MON];" msdb >/dev/null || fail "the monitor login's msdb user"
  sq "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;" >/dev/null
  mkdb pgvcc
  set_dsn
  cat > "$TMPD/m.yaml" <<YAML
repository:
  dsn: "$PGDSN"
instances:
  - name: sqlbox
    engine: sqlserver
    dsn: env:PGV_CC_MON
    tags: ["env:proof$SUF"]
YAML
  sed 's/tags: \["env:proof'"$SUF"'"\]/tags: ["env:proof'"$SUF"'", "pgvigil:linkedserver-test"]/' "$TMPD/m.yaml" > "$TMPD/m-tag.yaml"
  cat > "$TMPD/m-low.yaml" <<YAML
repository:
  dsn: "$PGDSN"
instances:
  - name: sqlbox_low
    engine: sqlserver
    dsn: env:PGV_CC_LOW
YAML
}
mkdb() {  # $1 name [$2 extra CREATE DATABASE text]: a database with the monitor login's user
  sq "CREATE DATABASE [$1] ${2:-}; " >/dev/null && sq "CREATE USER [$MON] FOR LOGIN [$MON];" "$1" >/dev/null
}
BASE="mssql_instance mssql_services mssql_traceflags mssql_checks mssql_jobs mssql_confcheck"
# (sp_Blitz 55's 'database owner' rows, one per user database, are counted apart: owners() - review-24 B1)
grid() { pq "SELECT string_agg(status || ' ' || n, ', ' ORDER BY status) FROM (SELECT status, count(*) AS n FROM pgvigil.mssql_config_checks_of(${1:-$IID}) WHERE check_name <> 'database owner' GROUP BY status) s"; }
owners() { pq "SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pgvigil.mssql_config_expect_keys() WHERE kind = 'database' AND key = 'owner') THEN 'no key'
  ELSE coalesce((SELECT string_agg(DISTINCT status || ' ' || source, ', ') FROM pgvigil.mssql_config_checks_of(${1:-$IID}) WHERE check_name = 'database owner'), 'no row') END"; }
# good_practice: max server memory under the machine's memory and MAXDOP at the advised value (read from the first
# mssql_confcheck run), so the rules on by default have nothing to say
good_practice() {
  ADV=$(pq "SELECT value #>> '{}' FROM pgvigil.mssql_confcheck_fact WHERE instance_id = $IID AND key = 'advised_maxdop'")
  CPUS=$(pq "SELECT value #>> '{}' FROM pgvigil.mssql_confcheck_fact WHERE instance_id = $IID AND key = 'cpu_count'")
  [[ $ADV =~ ^[0-9]+$ ]] || { bad "the advised MAXDOP was not read (got [$ADV])"; ADV=1; }
  sqv "setup: max server memory 2048, MAXDOP $ADV" "EXEC sp_configure 'max server memory (MB)', 2048; EXEC sp_configure 'max degree of parallelism', $ADV; RECONFIGURE;"
  col mssql_instance
}
default_grid() {  # $1 label
  rule "$1 the Agent's start mode (Automatic on a standalone instance)" "SQL Server Agent start mode" ok
  rule "$1 the engine's start mode: SQL Server on Linux lists no engine service" "engine start mode" "not read"
  rule "$1 the server name" "server name" ok
  rule "$1 max server memory under the machine's memory" "max server memory" ok
  rule "$1 MAXDOP at the advised value ($ADV of $CPUS CPUs)" "max degree of parallelism" ok
  rule "$1 scan for startup procs off" "scan for startup procs" ok
  rule "$1 no linked server" "linked server connection test" ok
  eqv "$1 the default grid: every policy rule off, the Linux-only rows not applicable" "$(grid)" "not applicable 3, not read 1, off 20, ok 6"
  check "$1 ... the not applicable and not read rows by name" "SELECT string_agg(status || ': ' || check_name, '; ' ORDER BY status, check_name) FROM pgvigil.mssql_config_checks_of($IID) WHERE status IN ('not applicable', 'not read') AND check_name <> 'database owner'" "not applicable: SQL Server Browser start mode; not applicable: SQL Server Browser state; not applicable: Windows processor scheduling (Win32PrioritySeparation); not read: engine start mode"
  check "$1 every off row says 'set an expectation' and every row names its source" "SELECT bool_and(status <> 'off' OR detail = 'set an expectation') AND bool_and(source IN ('Microsoft', 'dbatools formula', 'dbachecks policy') OR check_name = 'database owner') FROM pgvigil.mssql_config_checks_of($IID)" t
  check "$1 no finding" "SELECT count(*) FROM pgvigil.mssql_config_check_findings WHERE instance_id = $IID" 0
  # sp_Blitz 55 (BLITZ-GAP): every user database here is sa's - ok where the key is there (the join draft or the joined lines)
  case "$(owners)" in "no key"|"ok sp_Blitz") ok "$1 the database owner rows ($(owners))" ;; *) bad "$1 the database owner rows: $(owners)" ;; esac
}
db_devs() {  # $1 label: the recovery, scoped MAXDOP and event session deviations (every image)
  eqv "$1 setup: FULL, scoped MAXDOP 0 expected" "$(exi '"kind":"database","key":"recovery_model","value":"FULL"') $(exi '"kind":"database","key":"scoped_maxdop","value":0')" "done done"
  col mssql_confcheck
  rule "$1 recovery FULL as expected (master, tempdb, model and msdb left out by default)" "recovery model" ok
  # the monitor login has no user in model (its guest is off): a database left unread is never 'met'
  eqv "$1 scoped MAXDOP with a database the login cannot enter (model): not read, never ok" "$(st 'database-scoped MAXDOP') / $(det 'database-scoped MAXDOP' | grep -o '^met where read; not read in [0-9]* database(s)')" "not read / met where read; not read in 1 database(s)"
  eqv "$1 setup: model left out" "$(exi '"kind":"database","key":"scoped_maxdop","value":0,"exclusions":["model"]')" done
  rule "$1 database-scoped MAXDOP 0 in every database read, model left out" "database-scoped MAXDOP" ok
  eqv "$1 ... 'met; left out: model'" "$(det 'database-scoped MAXDOP')" "met; left out: model"
  sqv "$1 setup: SIMPLE, scoped MAXDOP 2" "ALTER DATABASE pgvcc SET RECOVERY SIMPLE; ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 2;" pgvcc
  col mssql_confcheck
  rule "$1 recovery SIMPLE: a warning for the proof database alone" "recovery model" "pgvcc warning"
  rule "$1 database-scoped MAXDOP 2" "database-scoped MAXDOP" "pgvcc warning"
  eqv "$1 both are findings" "$(finding 'recovery model' pgvcc) $(finding 'database-scoped MAXDOP' pgvcc)" "1 1"
  sqv "$1 setup: back" "ALTER DATABASE pgvcc SET RECOVERY FULL; ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 0;" pgvcc
  col mssql_confcheck
  eqv "$1 put back: both clear" "$(st 'recovery model') $(st 'database-scoped MAXDOP') $(finding 'recovery model') $(finding 'database-scoped MAXDOP')" "ok ok 0 0"
  # event sessions: x1 expected stopped, x2 expected running, x3 off the allowed list, x4 expected to exist
  sqv "$1 setup: the event sessions" "CREATE EVENT SESSION pgv_x1 ON SERVER ADD EVENT sqlserver.error_reported; CREATE EVENT SESSION pgv_x2 ON SERVER ADD EVENT sqlserver.error_reported;
CREATE EVENT SESSION pgv_x3 ON SERVER ADD EVENT sqlserver.error_reported; ALTER EVENT SESSION pgv_x2 ON SERVER STATE = START;"
  local running; running=$(sq "SELECT STRING_AGG('\"' + name + '\"', ',') FROM sys.dm_xe_sessions")
  eqv "$1 setup: the four lists" "$(exi '"kind":"xe","key":"stopped","value":["pgv_x1"]') $(exi '"kind":"xe","key":"running","value":["System_Health","pgv_x2"]') $(exi "\"kind\":\"xe\",\"key\":\"allowed\",\"value\":[$running]") $(exi '"kind":"xe","key":"exists","value":["pgv_x1","system_health"]')" "done done done done"
  col mssql_confcheck
  eqv "$1 the event sessions as expected" "$(st 'event sessions expected stopped') $(st 'event sessions expected running') $(st 'event sessions allowed to run') $(st 'event sessions expected to exist')" "ok ok ok ok"
  sqv "$1 setup: x1 started, x2 stopped, x3 started" "ALTER EVENT SESSION pgv_x1 ON SERVER STATE = START; ALTER EVENT SESSION pgv_x2 ON SERVER STATE = STOP; ALTER EVENT SESSION pgv_x3 ON SERVER STATE = START;"
  eqv "$1 setup: one more on the list of sessions expected to exist" "$(exi '"kind":"xe","key":"exists","value":["pgv_x1","system_health","pgv_x4"]')" done
  col mssql_confcheck
  rule "$1 a session expected stopped runs" "event sessions expected stopped" "pgv_x1 warning"
  rule "$1 a session expected running is stopped" "event sessions expected running" "pgv_x2 warning"
  rule "$1 running sessions off the allowed list" "event sessions allowed to run" "pgv_x1 warning, pgv_x3 warning"
  rule "$1 a session expected to exist is missing" "event sessions expected to exist" "pgv_x4 warning"
  sqv "$1 setup: back" "ALTER EVENT SESSION pgv_x1 ON SERVER STATE = STOP; ALTER EVENT SESSION pgv_x2 ON SERVER STATE = START; DROP EVENT SESSION pgv_x3 ON SERVER; CREATE EVENT SESSION pgv_x4 ON SERVER ADD EVENT sqlserver.error_reported;"
  col mssql_confcheck
  eqv "$1 put back: the four clear" "$(st 'event sessions expected stopped') $(st 'event sessions expected running') $(st 'event sessions allowed to run') $(st 'event sessions expected to exist')" "ok ok ok ok"
}

echo "== A: ${IMAGES[0]}"
start_server "${IMAGES[0]}"
ok "SQL Server $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))")"
"$BIN" migrate -config "$TMPD/m.yaml" > "$TMPD/migrate.out" 2>&1 && ok "migrate" || { tail -20 "$TMPD/migrate.out"; fail "migrate"; }
for c in $BASE; do
  collect "$c" || true
  eqv "A: $c runs as the monitor login" "$(lastrun "$c")" "ok"
done
[[ $(lastrun mssql_confcheck) == ok ]] || fail "A: mssql_confcheck did not run: nothing below can be read"
IID=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox'")
PORT=$((20000 + RANDOM % 20000)); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$TMPD/m.yaml" -listen "127.0.0.1:$PORT" -no-login > "$TMPD/serve.out" 2>&1 & SRV_PID=$!
for _ in $(seq 1 30); do curl -fs "$U/api/instances" >/dev/null 2>&1 && break; sleep 1; done

echo "== C0: the API"
parts() { curl -s "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(",".join(sorted(d.keys())) if isinstance(d, dict) else "not an object")' 2>&1 | head -c 200; }
eqv "C0 GET /api/mssql/config_checks: its parts" "$(parts "$U/api/mssql/config_checks?instance=$IID")" "checks,databases,facts,linked,parts,runs,xe"
eqv "C0 GET /api/mssql/config_expect: its parts" "$(parts "$U/api/mssql/config_expect?instance=$IID")" "in_force,keys,tags"
eqv "C0 the API's checks = the function's rows" "$(curl -s "$U/api/mssql/config_checks?instance=$IID&part=checks" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["checks"]["rows"]))' 2>&1 | head -c 100)" "$(pq "SELECT count(*) FROM pgvigil.mssql_config_checks_of($IID)")"
BODY="{\"op\":\"set\",\"level\":\"instance\",\"instance_id\":$IID,\"kind\":\"database\",\"key\":\"recovery_model\",\"value\":\"FULL\"}"
eqv "C0 POST without the X-Pgvigil header, and with it on a server without the UI login" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "$BODY" "$U/api/mssql/config_expect") $(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-Pgvigil: 1' -d "$BODY" "$U/api/mssql/config_expect")" "403 403"
check "C0 ... and neither wrote a row" "SELECT count(*) FROM pgvigil.mssql_config_expect" 0

echo "== C1: the defaults"
good_practice
default_grid "C1"
# each policy rule's expectation at the container's own value
sqv "C1 setup: an operator, a job owned by sa" "EXEC msdb.dbo.sp_add_operator @name = N'pgvOpA', @enabled = 1; EXEC msdb.dbo.sp_add_job @job_name = N'pgv_job1', @owner_login_name = N'sa';"
QS=$(sq "SELECT CASE is_query_store_on WHEN 1 THEN 'on' ELSE 'off' END FROM sys.databases WHERE name = 'pgvcc'")
RUNNING=$(sq "SELECT STRING_AGG('\"' + name + '\"', ',') FROM sys.dm_xe_sessions")
RA=$(sq "SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'remote access'")
col mssql_checks mssql_jobs mssql_confcheck
n=0
for p in '"kind":"config","key":"Database Mail XPs","value":0' "\"kind\":\"config\",\"key\":\"remote access\",\"value\":$RA" \
         '"kind":"database","key":"recovery_model","value":"FULL"' '"kind":"database","key":"scoped_maxdop","value":0,"exclusions":["model"]' '"kind":"database","key":"state","value":"on"' \
         '"kind":"database","key":"expected","value":["pgvcc","master"]' "\"kind\":\"database\",\"key\":\"query_store\",\"value\":\"$QS\",\"exclusions\":[\"master\",\"tempdb\",\"model\",\"msdb\"]" \
         '"kind":"xe","key":"stopped","value":["AlwaysOn_health"]' '"kind":"xe","key":"running","value":["system_health"]' "\"kind\":\"xe\",\"key\":\"allowed\",\"value\":[$RUNNING]" \
         '"kind":"xe","key":"exists","value":["system_health"]' '"kind":"traceflag","key":"not_expected","value":[460]' '"kind":"network","key":"protocols","value":["Tcp"]' \
         '"kind":"agent","key":"operators","value":["pgvOpA"]' '"kind":"agent","key":"job_owner_allow","value":["sa"]' "\"kind\":\"agent\",\"key\":\"job_owner_deny\",\"value\":[\"$OWN\"]"; do
  got=$(exi "$p"); [[ $got == done ]] && n=$((n + 1)) || bad "C1 an expectation was not set ($got): $p"
done
eqv "C1 sixteen expectations set at the instance" "$n" 16
check "C1 at the container's own values: no warning, critical or info row" "SELECT coalesce(string_agg(check_name || ' ' || object || ' ' || status, '; '), 'none') FROM pgvigil.mssql_config_checks_of($IID) WHERE status IN ('warning', 'critical', 'info')" none
check "C1 ... and no finding" "SELECT count(*) FROM pgvigil.mssql_config_check_findings WHERE instance_id = $IID" 0
check "C1 ... and every rule set at the instance reads ok (never off or not read)" "SELECT coalesce(string_agg(check_name || ' ' || object || ' ' || status, '; ' ORDER BY check_name, object), 'none') FROM pgvigil.mssql_config_checks_of($IID) WHERE set_at = 'instance' AND status <> 'ok'" none
check "C1 ... each such row says where it is set" "SELECT bool_and(set_at = 'instance') FROM pgvigil.mssql_config_checks_of($IID) WHERE check_name IN ('recovery model', 'server option', 'expected databases', 'Query Store', 'trace flags not expected', 'Agent operators expected')" t
rule "C1 the protocols on Linux" "network protocols enabled" ok
eqv "C1 ... 'met: Linux serves TCP only'" "$(det 'network protocols enabled')" "met: Linux serves TCP only"
rule "C1 the fail-safe operator stays off without an expectation" "Agent fail-safe operator" off

echo "== C2: the deviations"
sqv "C2 setup: Database Mail XPs 1" "EXEC sp_configure 'Database Mail XPs', 1; RECONFIGURE;"
col mssql_instance
rule "C2 Database Mail XPs 1 against 0" "server option" "Database Mail XPs warning" "Database Mail XPs"
eqv "C2 ... a finding" "$(finding 'server option' 'Database Mail XPs')" 1
sqv "C2 setup: Database Mail XPs 0" "EXEC sp_configure 'Database Mail XPs', 0; RECONFIGURE;"
col mssql_instance
eqv "C2 put back: clear" "$(st 'server option' 'Database Mail XPs') $(finding 'server option' 'Database Mail XPs')" "Database Mail XPs ok 0"
# a met expected value leaves no day-one warning anywhere: the findings, the Checks page's area (its counts and
# sentences) and the findings it lists (dbachecks' DefaultTrace: 'default trace enabled' 0 is a day-one warning)
sqv "C2 setup: the default trace off" "EXEC sp_configure 'default trace enabled', 0; RECONFIGURE;"
col mssql_instance mssql_checks   # mssql_instance stores sys.configurations for the 0160 rule; mssql_checks raises the day-one finding
area() { pq "SELECT warning || ' ' || coalesce((SELECT count(*) FROM unnest(s.detail) d WHERE d ILIKE '%default trace%'), 0) FROM pgvigil.mssql_checks_status s WHERE s.instance_id = $IID AND s.key = 'config'"; }
dtf() { pq "SELECT count(*) FROM pgvigil.mssql_checks_findings WHERE instance_id = $IID AND check_name = 'server option' AND object = 'default trace enabled'"; }
W1=$(area); W1=${W1%% *}
eqv "C2 the default trace off: a day-one warning, on the Checks page's area and in its findings" "$(dtf) $(area | cut -d' ' -f2)" "1 1"
eqv "C2 setup: 0 expected for it" "$(exi '"kind":"config","key":"default trace enabled","value":0')" done
eqv "C2 ... met: the area counts one warning fewer and names it in no sentence, its findings list leaves it out" "$(area) $(dtf)" "$((W1 - 1)) 0 0"
check "C2 ... and the configuration rule says it is met" "SELECT status FROM pgvigil.mssql_config_checks_of($IID) WHERE check_name = 'server option' AND object = 'default trace enabled'" ok
eqv "C2 setup: back (the trace on, the expectation taken away)" "$(exn '"kind":"config","key":"default trace enabled"')" done
sqv "C2 setup: the default trace on" "EXEC sp_configure 'default trace enabled', 1; RECONFIGURE;"
col mssql_instance mssql_checks
db_devs "C2"
eqv "C2 the protocols as SQL Server names them: 'TCP/IP' refused, saying why" "$(exr '"kind":"network","key":"protocols","value":["TCP/IP"]')" "refused: the value must be a list of the protocols as SQL Server names them: Tcp, Np, Sm"
eqv "C2 setup: Named Pipes alone expected" "$(exi '"kind":"network","key":"protocols","value":["np"]')" done
eqv "C2 SQL Server on Linux against a list without Tcp: info, saying so" "$(st 'network protocols enabled') / $(det 'network protocols enabled')" "info / Linux serves TCP only; Np is expected (set at instance)"
eqv "C2 setup: Tcp again" "$(exi '"kind":"network","key":"protocols","value":["Tcp"]')" done
# R-d: a list rule's time is its own collection's
# a database read-only, one RESTORING, one in STANDBY
mkdb pgvro; mkdb pgvrs; mkdb pgvsb
sqv "C2 setup: read-only, RESTORING, STANDBY" "ALTER DATABASE pgvro SET READ_ONLY WITH ROLLBACK IMMEDIATE;
BACKUP DATABASE pgvrs TO DISK = N'/var/opt/mssql/data/pgvrs.bak' WITH INIT; RESTORE DATABASE pgvrs FROM DISK = N'/var/opt/mssql/data/pgvrs.bak' WITH NORECOVERY, REPLACE;
BACKUP DATABASE pgvsb TO DISK = N'/var/opt/mssql/data/pgvsb.bak' WITH INIT; RESTORE DATABASE pgvsb FROM DISK = N'/var/opt/mssql/data/pgvsb.bak' WITH STANDBY = N'/var/opt/mssql/data/pgvsb.undo', REPLACE;"
col mssql_confcheck
rule "C2 a database read-only, one RESTORING, one in STANDBY" "databases restoring, read-only or in standby" "pgvro warning, pgvrs warning, pgvsb warning"
check "C2 ... each value names its state" "SELECT string_agg(object || '=' || value, ' ' ORDER BY object) FROM pgvigil.mssql_config_checks_of($IID) WHERE check_name = 'databases restoring, read-only or in standby'" "pgvro=read-only pgvrs=RESTORING pgvsb=read-only, standby"
sqv "C2 setup: the three dropped" "ALTER DATABASE pgvro SET READ_WRITE WITH ROLLBACK IMMEDIATE; DROP DATABASE pgvro; DROP DATABASE pgvrs; DROP DATABASE pgvsb;"
col mssql_confcheck
rule "C2 dropped: clear" "databases restoring, read-only or in standby" ok
# a database on the expected list dropped
mkdb pgvgone
eqv "C2 setup: pgvgone expected" "$(exi '"kind":"database","key":"expected","value":["pgvcc","pgvgone"]')" done
col mssql_confcheck
rule "C2 every expected database is there" "expected databases" ok
sqv "C2 setup: pgvgone dropped" "DROP DATABASE pgvgone;"
col mssql_confcheck
rule "C2 an expected database dropped" "expected databases" "pgvgone critical"
eqv "C2 ... a critical finding" "$(pq "SELECT severity FROM pgvigil.mssql_config_check_findings WHERE instance_id = $IID AND check_name = 'expected databases'")" critical
mkdb pgvgone; col mssql_confcheck
rule "C2 made again: clear" "expected databases" ok
# Query Store against the expected state. The default list of databases left out is master, tempdb and model: msdb,
# whose store is off on a fresh server, is judged with it
if [[ $QS == on ]]; then
  eqv "C2 setup: Query Store expected on, the default list of databases left out" "$(exi '"kind":"database","key":"query_store","value":"on"')" done
  rule "C2 the default list leaves out master, tempdb and model, not msdb (its store is off)" "Query Store" "msdb warning"
  eqv "C2 setup: msdb left out too, written MSDB" "$(exi '"kind":"database","key":"query_store","value":"on","exclusions":["master","tempdb","model","MSDB"]')" done
  rule "C2 ... with msdb named among the databases left out (in another case): met" "Query Store" ok
else
  np "C2 Query Store's default list of databases left out (msdb judged): the proof database's store is off on this image, as msdb's"
fi
[[ $QS == on ]] && FLIP=OFF || FLIP=ON
sqv "C2 setup: Query Store $FLIP" "ALTER DATABASE pgvcc SET QUERY_STORE = $FLIP;"
col mssql_confcheck
rule "C2 Query Store $FLIP against $QS" "Query Store" "pgvcc warning"
sqv "C2 setup: Query Store back" "ALTER DATABASE pgvcc SET QUERY_STORE = $([[ $QS == on ]] && echo ON || echo OFF);"
col mssql_confcheck
rule "C2 put back: clear" "Query Store" ok
# trace flags
eqv "C2 setup: 3226 expected" "$(exi '"kind":"traceflag","key":"expected","value":[3226]')" done
sqv "C2 setup: 460 and 3226 on for the server" "DBCC TRACEON (460, -1) WITH NO_INFOMSGS; DBCC TRACEON (3226, -1) WITH NO_INFOMSGS;"
col mssql_traceflags
eqv "C2 trace flag 460 on when not expected; 3226 on as expected" "$(st 'trace flags not expected') / $(st 'trace flags expected')" "460 warning / ok"
check "C2 ... the row's time is the trace flags' read, not the configuration read's" "SELECT c.at = (SELECT d.snapshot_at FROM pgvigil.collection_dates d WHERE d.instance_id = $IID AND d.collection = 'mssql_traceflags') FROM pgvigil.mssql_config_checks_of($IID) c WHERE c.check_name = 'trace flags not expected' AND c.object = '460'" t
sqv "C2 setup: both off" "DBCC TRACEOFF (460, -1) WITH NO_INFOMSGS; DBCC TRACEOFF (3226, -1) WITH NO_INFOMSGS;"
col mssql_traceflags
eqv "C2 460 off: clear; the expected 3226 off: a warning" "$(st 'trace flags not expected') / $(st 'trace flags expected')" "ok / 3226 warning"
eqv "C2 setup: 3226 no longer expected" "$(exn '"kind":"traceflag","key":"expected"')" done
# MAXDOP and max server memory (info: amber, no finding)
if [[ $CPUS =~ ^[0-9]+$ ]] && (( CPUS > ADV )); then
  sqv "C2 setup: MAXDOP $((ADV + 1))" "EXEC sp_configure 'max degree of parallelism', $((ADV + 1)); RECONFIGURE;"; col mssql_instance
  eqv "C2 MAXDOP one above the advised $ADV: info, no finding" "$(st 'max degree of parallelism') $(finding 'max degree of parallelism')" "info 0"
  sqv "C2 setup: MAXDOP 0" "EXEC sp_configure 'max degree of parallelism', 0; RECONFIGURE;"; col mssql_instance
  rule "C2 MAXDOP 0 on $CPUS CPUs (all of them, above the advised $ADV)" "max degree of parallelism" info
else
  np "C2 MAXDOP above the advised value: the box gives the container $CPUS CPUs, the advised value is $ADV (nothing above it can be set)"
fi
sqv "C2 setup: MAXDOP 1" "EXEC sp_configure 'max degree of parallelism', 1; RECONFIGURE;"; col mssql_instance
rule "C2 MAXDOP 1 (from 1 up to the advised value is in order)" "max degree of parallelism" ok
sqv "C2 setup: MAXDOP $ADV, max server memory at its default" "EXEC sp_configure 'max degree of parallelism', $ADV; EXEC sp_configure 'max server memory (MB)', 2147483647; RECONFIGURE;"; col mssql_instance
eqv "C2 max server memory 2147483647 on Linux: info, no finding" "$(st 'max server memory') $(finding 'max server memory')" "info 0"
check "C2 ... 'the server may take all of it'" "SELECT detail LIKE '%the server may take all of it%' FROM pgvigil.mssql_config_checks_of($IID) WHERE check_name = 'max server memory'" t
sqv "C2 setup: max server memory 2048" "EXEC sp_configure 'max server memory (MB)', 2048; RECONFIGURE;"; col mssql_instance
rule "C2 put back: clear" "max server memory" ok
# the Agent: operators, job owners, the fail-safe operator
sqv "C2 setup: the operator dropped" "EXEC msdb.dbo.sp_delete_operator @name = N'pgvOpA';"; col mssql_checks
rule "C2 an expected operator is gone" "Agent operators expected" "pgvOpA warning"
sqv "C2 setup: the operator back, in another case" "EXEC msdb.dbo.sp_add_operator @name = N'PGVOPA', @enabled = 1;"; col mssql_checks
rule "C2 back under a name in another case: clear" "Agent operators expected" ok
sqv "C2 setup: a job owned by $OWN" "EXEC msdb.dbo.sp_add_job @job_name = N'pgv_job2', @owner_login_name = N'$OWN';"; col mssql_jobs
eqv "C2 a job owned by a login not allowed, and not on the list of owners allowed" "$(st 'job owners not allowed') / $(st 'job owners allowed')" "pgv_job2 warning / pgv_job2 warning"
sqv "C2 setup: the job dropped" "EXEC msdb.dbo.sp_delete_job @job_name = N'pgv_job2';"; col mssql_jobs
eqv "C2 dropped: both clear" "$(st 'job owners not allowed') / $(st 'job owners allowed')" "ok / ok"
BEFORE=$(pq "SELECT count(*) FROM pgvigil.mssql_config_expect")
eqv "C2 an operator expectation holding '@' is refused" "$(exr '"kind":"agent","key":"operators","value":["dba@example.invalid"]') / $(exr '"kind":"agent","key":"failsafe_operator","value":"dba@example.invalid"')" "refused: an e-mail address is never stored: name the operator, not its address / refused: an e-mail address is never stored: name the operator, not its address"
check "C2 ... and nothing was written" "SELECT count(*) FROM pgvigil.mssql_config_expect" "$BEFORE"
# a login's name may hold '@' (an Entra ID login on Managed Instance): the job owner lists take it
eqv "C2 setup: a job owner allowed whose login name holds '@'" "$(exi '"kind":"agent","key":"job_owner_allow","value":["sa","pgv@example.invalid"]')" done
rule "C2 ... taken and judged" "job owners allowed" ok
eqv "C2 setup: back" "$(exi '"kind":"agent","key":"job_owner_allow","value":["sa"]')" done
eqv "C2 setup: a fail-safe operator expected" "$(exi '"kind":"agent","key":"failsafe_operator","value":"pgvOpA"')" done
rule "C2 the fail-safe operator: the monitor login may not run sp_MSgetalertinfo" "Agent fail-safe operator" "not read"
eqv "C2 ... the row says why" "$(det 'Agent fail-safe operator')" "the fail-safe operator was not read: the login may not run master.dbo.sp_MSgetalertinfo"
eqv "C2 setup: the fail-safe expectation taken away" "$(exn '"kind":"agent","key":"failsafe_operator"')" done

eqv "C2 setup: a floor of error log files before errorlog.numerrorlogs is set" "$(exi '"kind":"instance","key":"errorlog_files","value":10')" done
eqv "C2 SQL Server on Linux without errorlog.numerrorlogs: not read, saying so" "$(st 'error log files kept') / $(det 'error log files kept')" "not read / not read: errorlog.numerrorlogs is not set in mssql.conf, and SQL Server on Linux shows no count without it"
eqv "C2 setup: the floor taken away" "$(exn '"kind":"instance","key":"errorlog_files"')" done

echo "== C2r: after one restart (the error log files kept, scan for startup procs, remote access)"
docker exec -u 0 "$SQL" /opt/mssql/bin/mssql-conf set errorlog.numerrorlogs 12 >/dev/null 2>&1 || bad "C2r mssql-conf set errorlog.numerrorlogs"
sqv "C2r setup: scan for startup procs 1, remote access 0" "EXEC sp_configure 'scan for startup procs', 1; EXEC sp_configure 'remote access', 0; RECONFIGURE;"
docker restart "$SQL" >/dev/null && wait_up || fail "restart"
set_dsn
col mssql_instance mssql_confcheck mssql_checks
eqv "C2r the error log files kept, read by hand as the server's own registry value" "$(sq "DECLARE @v int; EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\\Microsoft\\MSSQLServer\\MSSQLServer', N'NumErrorLogs', @v OUTPUT; SELECT @v;")" 12
check "C2r ... and by the monitor login (not sysadmin)" "SELECT value #>> '{}' FROM pgvigil.mssql_confcheck_fact WHERE instance_id = $IID AND key = 'num_errorlogs'" 12
eqv "C2r setup: a floor of 15" "$(exi '"kind":"instance","key":"errorlog_files","value":15')" done
eqv "C2r 12 kept against a floor of 15: info, no finding" "$(st 'error log files kept') $(finding 'error log files kept')" "info 0"
eqv "C2r setup: a floor of 12" "$(exi '"kind":"instance","key":"errorlog_files","value":12')" done
rule "C2r 12 kept against a floor of 12" "error log files kept" ok
eqv "C2r scan for startup procs in use 1 with no startup procedure: a warning, a finding" "$(st 'scan for startup procs') $(finding 'scan for startup procs')" "warning 1"
sqv "C2r setup: a startup procedure" "EXEC (N'CREATE PROCEDURE dbo.pgv_start AS SELECT 1;'); EXEC sp_procoption N'dbo.pgv_start', 'startup', 'on';"
col mssql_confcheck
rule "C2r with a startup procedure" "scan for startup procs" ok
eqv "C2r ... the procedure named" "$(det 'scan for startup procs')" "the server runs at its start: pgv_start"
CFG=$TMPD/m-low.yaml collect mssql_instance sqlbox_low || true
CFG=$TMPD/m-low.yaml collect mssql_confcheck sqlbox_low || true
LID=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox_low'")
rule "C2r a login without VIEW ANY DEFINITION" "scan for startup procs" "not read" "" "$LID"
check "C2r ... the row says which right" "SELECT detail LIKE '%VIEW ANY DEFINITION%' FROM pgvigil.mssql_config_checks_of($LID) WHERE check_name = 'scan for startup procs'" t
# remote access: in use 0 now; the expectation of C1 was its old value
rule "C2r remote access in use 0 against the expected $RA" "server option" "remote access $([[ $RA == 0 ]] && echo ok || echo warning)" "remote access"
check "C2r ... met or not, the day-one check's finding for it is left out while an expectation is set" "SELECT count(*) FROM pgvigil.findings WHERE instance_id = $IID AND source = 'mssql_checks' AND lower(setting) = 'server option' AND lower(value) = 'remote access'" 0
eqv "C2r setup: 0 expected" "$(exi '"kind":"config","key":"remote access","value":0')" done
rule "C2r ... against 0" "server option" "remote access ok" "remote access"
DAYONE="SELECT count(*) FROM pgvigil.findings WHERE instance_id = $IID AND source = 'mssql_checks' AND lower(setting) = 'server option' AND lower(value) = 'remote access'"
check "C2r while an expectation is set, the day-one check's finding for remote access is not in pgvigil.findings" "$DAYONE" 0
eqv "C2r setup: the expectation taken away" "$(exn '"kind":"config","key":"remote access"')" done
check "C2r ... without one it is" "$DAYONE" 1
eqv "C2r setup: 0 expected at the root" "$(ex '"op":"set","level":"root","kind":"config","key":"remote access","value":0')" done
check "C2r ... an expectation from the root leaves it out too" "$DAYONE" 0
eqv "C2r setup: the root's taken away" "$(ex '"op":"inherit","level":"root","kind":"config","key":"remote access"')" done
check "C2r ... and it is back" "$DAYONE" 1
rule "C2r ... and the rule is off again" "server option" "remote access off" "remote access"

echo "== C3: rows written"
mkinst() { pq "SELECT pgvigil.ensure_instance('$1', '$2', '16.0', 160000, false, '{}', 'sqlserver')"; }   # $1 name $2 platform
facts() { pq "SELECT pgvigil.import_mssql_confcheck($1, clock_timestamp(), '$2'::jsonb)" >/dev/null || bad "C3 the written facts of instance $1"; }
PARTS='{"kind":"part","part":"names","read":1},{"kind":"part","part":"machine","read":1},{"kind":"part","part":"xe","read":1},{"kind":"part","part":"errorlog","read":1},{"kind":"part","part":"startup","read":1},{"kind":"part","part":"databases","read":1},{"kind":"part","part":"linked","read":1}'
WIN=$(mkinst "win$SUF" sqlserver)
facts "$WIN" "[$PARTS,{\"kind\":\"fact\",\"key\":\"server_name\",\"value\":\"OLDNAME\"},{\"kind\":\"fact\",\"key\":\"property_server_name\",\"value\":\"newname\"},{\"kind\":\"fact\",\"key\":\"netbios\",\"value\":\"HOST$SUF\"},{\"kind\":\"fact\",\"key\":\"host_platform\",\"value\":\"Windows\"},{\"kind\":\"fact\",\"key\":\"num_errorlogs\",\"value\":6},{\"kind\":\"fact\",\"key\":\"startup_procs\",\"value\":[]},{\"kind\":\"fact\",\"key\":\"advised_maxdop\",\"value\":8},{\"kind\":\"fact\",\"key\":\"cpu_count\",\"value\":16},
 {\"kind\":\"database\",\"database_name\":\"m1\",\"state\":\"RESTORING\",\"read_only\":0,\"in_standby\":0,\"recovery_model\":\"FULL\",\"query_store\":0,\"secondary_role\":\"mirror\"},
 {\"kind\":\"database\",\"database_name\":\"ag1\",\"state\":\"ONLINE\",\"read_only\":1,\"in_standby\":0,\"recovery_model\":\"FULL\",\"query_store\":0,\"secondary_role\":\"availability group secondary\"},
 {\"kind\":\"database\",\"database_name\":\"ls1\",\"state\":\"ONLINE\",\"read_only\":1,\"in_standby\":1,\"recovery_model\":\"FULL\",\"query_store\":0,\"secondary_role\":\"log shipping secondary\"},
 {\"kind\":\"database\",\"database_name\":\"plain1\",\"state\":\"RESTORING\",\"read_only\":0,\"in_standby\":0,\"recovery_model\":\"FULL\",\"query_store\":0}]"
rule "C3 @@SERVERNAME differing from the server's name" "server name" warning "" "$WIN"
check "C3 ... 'a rename not finished'" "SELECT detail LIKE 'a rename not finished: @@SERVERNAME is OLDNAME and the server''s name is newname%' FROM pgvigil.mssql_config_checks_of($WIN) WHERE check_name = 'server name'" t
np "C3 a rename not finished, live: SQL Server on Linux registers the host's name again at its start (sp_dropserver and sp_addserver leave @@SERVERNAME as it was after a restart)"
eqv "C3 setup: the states judged" "$(exi '"kind":"database","key":"state","value":"on"' "$WIN")" done
rule "C3 a mirror, an availability group secondary and a log shipping secondary are left out; a plain RESTORING database is not" "databases restoring, read-only or in standby" "plain1 warning" "" "$WIN"
# a recovery model or a Query Store state the server gave none of is not read, never a deviation; tempdb is not judged
# by the recovery model
NUL=$(mkinst "nul$SUF" sqlserver)
facts "$NUL" "[{\"kind\":\"part\",\"part\":\"databases\",\"read\":1},{\"kind\":\"database\",\"database_name\":\"tempdb\",\"state\":\"ONLINE\",\"read_only\":0,\"in_standby\":0,\"recovery_model\":\"SIMPLE\",\"query_store\":0,\"scoped_maxdop\":0},{\"kind\":\"database\",\"database_name\":\"d1\",\"state\":\"ONLINE\",\"read_only\":0,\"in_standby\":0,\"scoped_maxdop\":0}]"
eqv "C3 setup: FULL and Query Store on expected, nothing left out but tempdb's Query Store" "$(exi '"kind":"database","key":"recovery_model","value":"FULL","exclusions":[]' "$NUL") $(exi '"kind":"database","key":"query_store","value":"on","exclusions":["tempdb"]' "$NUL")" "done done"
eqv "C3 a recovery model and a Query Store state not read: not read, naming the database; tempdb's SIMPLE no deviation" "$(st 'recovery model' '' "$NUL") / $(det 'recovery model' '' "$NUL") / $(st 'Query Store' '' "$NUL")" "not read / met where read; not read in 1 database(s): d1 / not read"
# where the secondaries could not be told apart, a RESTORING database is not read, never a warning
facts "$NUL" "[{\"kind\":\"part\",\"part\":\"databases\",\"read\":1},{\"kind\":\"fact\",\"key\":\"secondary_roles_unread\",\"value\":\"log shipping secondaries are not told apart: the login has no access to msdb\"},{\"kind\":\"database\",\"database_name\":\"r1\",\"state\":\"RESTORING\",\"read_only\":0,\"in_standby\":0,\"recovery_model\":\"FULL\",\"query_store\":0}]"
eqv "C3 setup: the states judged" "$(exi '"kind":"database","key":"state","value":"on"' "$NUL")" done
eqv "C3 a RESTORING database where the log shipping secondaries were not told apart: not read, saying why" "$(st 'databases restoring, read-only or in standby' '' "$NUL") / $(finding 'databases restoring, read-only or in standby' '' "$NUL")" "r1 not read / 0"
check "C3 ... the row names what was not read" "SELECT detail LIKE 'the database is RESTORING; whether it is a secondary was not read (log shipping secondaries are not told apart%' FROM pgvigil.mssql_config_checks_of($NUL) WHERE check_name = 'databases restoring, read-only or in standby'" t
pq "DELETE FROM pgvigil.instances WHERE instance_id = $NUL" >/dev/null
# Azure SQL Database: one database is the instance and mssql_confcheck does not run there - no grid at all
AZ=$(mkinst "az$SUF" azuresqldb)
check "C3 an Azure SQL Database instance has no configuration grid (no row that would never be read)" "SELECT count(*) FROM pgvigil.mssql_config_checks_of($AZ)" 0
pq "DELETE FROM pgvigil.instances WHERE instance_id = $AZ" >/dev/null
# the services: a Windows engine and Agent
svc() { pq "INSERT INTO pgvigil.mssql_service (instance_id, service_name, startup_type, status, is_clustered, snapshot_at) VALUES ($1, '$2', '$3', 'Running', $4, now())
  ON CONFLICT (instance_id, service_name) DO UPDATE SET startup_type = EXCLUDED.startup_type, is_clustered = EXCLUDED.is_clustered, snapshot_at = now()"; }
svc "$WIN" 'SQL Server (MSSQLSERVER)' Manual false; svc "$WIN" 'SQL Server Agent (MSSQLSERVER)' Manual false
eqv "C3 a Windows engine and Agent service Manual on a standalone instance" "$(st 'engine start mode' '' "$WIN") / $(st 'SQL Server Agent start mode' '' "$WIN")" "warning / warning"
svc "$WIN" 'SQL Server (MSSQLSERVER)' Automatic false
rule "C3 ... Automatic" "engine start mode" ok "" "$WIN"
svc "$WIN" 'SQL Server (MSSQLSERVER)' Manual true
rule "C3 ... Manual on a failover cluster instance (the cluster starts it)" "engine start mode" ok "" "$WIN"
svc "$WIN" 'SQL Server (MSSQLSERVER)' Automatic true
rule "C3 ... Automatic on a failover cluster instance" "engine start mode" warning "" "$WIN"
eqv "C3 setup: the Agent's start mode expected Manual at the instance" "$(exi '"kind":"service","key":"agent_start_mode","value":"Manual"' "$WIN")" done
rule "C3 ... the Agent's Manual is then as expected" "SQL Server Agent start mode" ok "" "$WIN"
# max server memory on Windows against the dbatools formula
check "C3 the dbatools formula: 16384 -> 11264, 32768 -> 25600, 2048 -> 1024 MB" "SELECT pgvigil.mssql_recommended_max_memory_mb(16384) || ' ' || pgvigil.mssql_recommended_max_memory_mb(32768) || ' ' || pgvigil.mssql_recommended_max_memory_mb(2048)" "11264 25600 1024"
mem() { pq "INSERT INTO pgvigil.mssql_instance (instance_id, snapshot_at, physical_memory_mb, cpu_count, engine_edition, is_clustered, sysinfo_read) VALUES ($1, now(), 16384, 16, ${3:-3}, false, true)
  ON CONFLICT (instance_id) DO UPDATE SET physical_memory_mb = 16384, engine_edition = EXCLUDED.engine_edition;
  INSERT INTO pgvigil.mssql_config (instance_id, name, value, value_in_use, snapshot_at) VALUES ($1, 'max server memory (MB)', $2, $2, now())
  ON CONFLICT (instance_id, name) DO UPDATE SET value = EXCLUDED.value, value_in_use = EXCLUDED.value_in_use, snapshot_at = now()"; }
mem "$WIN" 12000
rule "C3 max server memory 12000 MB of 16384 on Windows (11264 recommended)" "max server memory" info "" "$WIN"
mem "$WIN" 11264
rule "C3 ... 11264 MB" "max server memory" ok "" "$WIN"
WIN2=$(mkinst "win2$SUF" sqlserver)
facts "$WIN2" "[{\"kind\":\"part\",\"part\":\"names\",\"read\":1},{\"kind\":\"fact\",\"key\":\"netbios\",\"value\":\"host$SUF\"}]"
rule "C3 ... with a second monitored instance on the machine (5632 MB each)" "max server memory" info "" "$WIN"
check "C3 ... the row says so" "SELECT expected || ' ' || (detail LIKE '%for each of the 2 monitored instance(s)%') FROM pgvigil.mssql_config_checks_of($WIN) WHERE check_name = 'max server memory'" "5632 true"
mem "$WIN" 11264 4
rule "C3 SQL Server Express has no Agent" "SQL Server Agent start mode" "not applicable" "" "$WIN"
# the network and the host, once the properties collection stores them
eqv "C3 setup: port 1433, Tcp alone and scheduling 24 expected" "$(exi '"kind":"network","key":"tcp_port","value":1433' "$WIN") $(exi '"kind":"network","key":"protocols","value":["Tcp"]' "$WIN") $(exi '"kind":"network","key":"cpu_priority","value":24' "$WIN")" "done done done"
eqv "C3 before the properties collection stores them: not read" "$(st 'TCP port' '' "$WIN") / $(st 'network protocols enabled' '' "$WIN") / $(st 'Windows processor scheduling (Win32PrioritySeparation)' '' "$WIN")" "not read / not read / not read"
prop() { pq "INSERT INTO pgvigil.mssql_property (instance_id, name, grp, label, value, snapshot_at, since, seen_at) VALUES ($WIN, '$1', 'Server', '$1', '$2', now(), now(), now())
  ON CONFLICT (instance_id, name) DO UPDATE SET value = EXCLUDED.value, snapshot_at = now()"; }
prop tcp_port 1434; prop protocols_enabled 'Tcp, Np'; prop win32_priority_separation 38
eqv "C3 port 1434, Tcp and Np, scheduling 38: info each, no finding" "$(st 'TCP port' '' "$WIN") / $(st 'network protocols enabled' '' "$WIN") / $(st 'Windows processor scheduling (Win32PrioritySeparation)' '' "$WIN") / $(pq "SELECT count(*) FROM pgvigil.mssql_config_check_findings WHERE instance_id = $WIN AND check_name IN ('TCP port', 'network protocols enabled')")" "info / info / info / 0"
prop tcp_port 1433; prop protocols_enabled 'Tcp'; prop win32_priority_separation 24
eqv "C3 each as expected" "$(st 'TCP port' '' "$WIN") / $(st 'network protocols enabled' '' "$WIN") / $(st 'Windows processor scheduling (Win32PrioritySeparation)' '' "$WIN")" "ok / ok / ok"
rule "C3 the Browser on Windows: no host door" "SQL Server Browser state" "not read" "" "$WIN"
# the fail-safe operator
pq "INSERT INTO pgvigil.mssql_agent_alerting (instance_id, failsafe_read, failsafe_operator, snapshot_at) VALUES ($WIN, true, 'dba', now())" >/dev/null
eqv "C3 setup: the fail-safe operator DBA expected" "$(exi '"kind":"agent","key":"failsafe_operator","value":"DBA"' "$WIN")" done
rule "C3 the fail-safe operator in another case" "Agent fail-safe operator" ok "" "$WIN"
pq "UPDATE pgvigil.mssql_agent_alerting SET failsafe_operator = 'other' WHERE instance_id = $WIN" >/dev/null
rule "C3 ... another operator" "Agent fail-safe operator" warning "" "$WIN"
# the managed services
HOSTED="'engine start mode', 'SQL Server Agent start mode', 'server name', 'error log files kept', 'scan for startup procs', 'network protocols enabled', 'Windows processor scheduling (Win32PrioritySeparation)', 'SQL Server Browser state', 'SQL Server Browser start mode'"
for pl in "rdssqlserver|Amazon RDS" "azuresqlmi|Azure SQL Managed Instance" "cloudsqlsqlserver|Google Cloud SQL"; do
  HID=$(mkinst "${pl%%|*}$SUF" "${pl%%|*}")
  check "C3 ${pl##*|}: the host's rules are 'not applicable: ${pl##*|} runs the host'" "SELECT count(*) || ' ' || bool_and(status = 'not applicable' AND detail = '${pl##*|} runs the host') FROM pgvigil.mssql_config_checks_of($HID) WHERE check_name IN ($HOSTED)" "9 true"
done
MI=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'azuresqlmi$SUF'"); RDS=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'rdssqlserver$SUF'")
eqv "C3 Managed Instance: the TCP port and max server memory too; RDS: both judged (off, not read)" "$(st 'TCP port' '' "$MI") / $(st 'max server memory' '' "$MI") / $(st 'TCP port' '' "$RDS") / $(st 'max server memory' '' "$RDS")" "not applicable / not applicable / off / not read"

echo "== C4: the scope order"
TAG="env:proof$SUF"
inforce() { pq "SELECT coalesce((SELECT (value #>> '{}') || ' ' || set_at FROM pgvigil.mssql_config_expect_in_force($IID) WHERE kind = 'database' AND key = 'recovery_model'), 'none')"; }
eqv "C4 setup: the instance's own expectation taken away" "$(exn '"kind":"database","key":"recovery_model"')" done
eqv "C4 nothing set" "$(inforce)" none
eqv "C4 setup: SIMPLE at the root" "$(ex '"op":"set","level":"root","kind":"database","key":"recovery_model","value":"SIMPLE"')" done
eqv "C4 the root's" "$(inforce)" "SIMPLE root"
eqv "C4 setup: BULK_LOGGED on the tag" "$(ex "\"op\":\"set\",\"level\":\"tag\",\"tag\":\"$TAG\",\"kind\":\"database\",\"key\":\"recovery_model\",\"value\":\"BULK_LOGGED\"")" done
eqv "C4 the tag's" "$(inforce)" "BULK_LOGGED tag:$TAG"
eqv "C4 setup: FULL at the instance" "$(exi '"kind":"database","key":"recovery_model","value":"FULL"')" done
eqv "C4 the instance's" "$(inforce)" "FULL instance"
apiforce() { curl -s "$U/api/mssql/config_expect?instance=$1&part=in_force" | python3 -c 'import json,sys
t=json.load(sys.stdin)["in_force"]; rows=[dict(zip(t["columns"], r)) for r in t["rows"]]
print(", ".join(str(r["value"]) + " " + r["set_at"] for r in rows if r["kind"] == "database" and r["key"] == "recovery_model") or "no row")' 2>&1 | head -c 200; }
eqv "C4 the API's in_force part gives the instance's value too" "$(apiforce "$IID")" "FULL instance"
eqv "C4 ... and an instance that is not a number is refused" "$(curl -s -o /dev/null -w '%{http_code}' "$U/api/mssql/config_expect?instance=abc&part=in_force")" 400
check "C4 mssql_config_expect_now agrees" "SELECT (value #>> '{}') || ' ' || set_at FROM pgvigil.mssql_config_expect_now WHERE instance_id = $IID AND kind = 'database' AND key = 'recovery_model'" "FULL instance"
check "C4 the grid's row says where it is set" "SELECT string_agg(DISTINCT set_at, ',') FROM pgvigil.mssql_config_checks_of($IID) WHERE check_name = 'recovery model'" instance
eqv "C4 inherit at the instance: the tag's" "$(exn '"kind":"database","key":"recovery_model"') $(inforce)" "done BULK_LOGGED tag:$TAG"
eqv "C4 inherit at the tag: the root's" "$(ex "\"op\":\"inherit\",\"level\":\"tag\",\"tag\":\"$TAG\",\"kind\":\"database\",\"key\":\"recovery_model\"") $(inforce)" "done SIMPLE root"
eqv "C4 inherit where nothing is set: refused" "$(exn '"kind":"database","key":"recovery_model"')" refused
eqv "C4 a key that does not exist, a value off the key's list: refused, saying why" "$(exr '"kind":"database","key":"nokey","value":1') / $(exr '"kind":"database","key":"recovery_model","value":"SOMETIMES"')" "refused: no expectation can be set for this kind and key / refused: the value must be one of: FULL, SIMPLE, BULK_LOGGED"
eqv "C4 setup: the root's taken away, FULL at the instance again" "$(ex '"op":"inherit","level":"root","kind":"database","key":"recovery_model"') $(exi '"kind":"database","key":"recovery_model","value":"FULL"')" "done done"
# a number has its key's range: outside it nothing is written (attempts at an instance of the proof's own)
BEFORE=$(pq "SELECT count(*) FROM pgvigil.mssql_config_expect")
eqv "C4 a number outside its key's range is refused: scoped MAXDOP 3000000000, TCP port 70000, 5 error log files, a server option at -1" "$(exr '"kind":"database","key":"scoped_maxdop","value":3000000000' "$WIN2") / $(exr '"kind":"network","key":"tcp_port","value":70000' "$WIN2") / $(exr '"kind":"instance","key":"errorlog_files","value":5' "$WIN2") / $(exr '"kind":"config","key":"remote access","value":-1' "$WIN2")" "refused: the value must be a whole number from 0 to 32767 / refused: the value must be a whole number from 1 to 65535 / refused: the value must be a whole number from 6 to 99 / refused: the value must be a whole number from 0 to 2147483647"
check "C4 ... and nothing was written" "SELECT count(*) FROM pgvigil.mssql_config_expect" "$BEFORE"
pq "DELETE FROM pgvigil.mssql_config_expect WHERE instance_id = $WIN2" >/dev/null
# ... and a stored value over the integer range (a row written past the function) is compared, never an error
BIG=$(mkinst "big$SUF" sqlserver)
facts "$BIG" "[{\"kind\":\"part\",\"part\":\"databases\",\"read\":1},{\"kind\":\"database\",\"database_name\":\"d1\",\"state\":\"ONLINE\",\"read_only\":0,\"in_standby\":0,\"recovery_model\":\"FULL\",\"query_store\":0,\"scoped_maxdop\":2}]"
pq "INSERT INTO pgvigil.mssql_config_expect (level, instance_id, kind, key, value, exclusions, created_by, created_at) VALUES ('instance', $BIG, 'database', 'scoped_maxdop', '3000000000', '[]', 'proof', now())" >/dev/null
check "C4 a stored expectation over the integer range reads as a deviation, not as an error" "SELECT string_agg(object || ' ' || status, ', ') FROM pgvigil.mssql_config_checks_of($BIG) WHERE check_name = 'database-scoped MAXDOP'" "d1 warning"
pq "DELETE FROM pgvigil.instances WHERE instance_id = $BIG" >/dev/null
check "C4 the history stays: every ended row names who ended it" "SELECT count(*) > 0 AND bool_and(ended_by = 'proof') FROM pgvigil.mssql_config_expect WHERE ended_at IS NOT NULL" t

echo "== C5: linked servers"
docker run -d --name "$REMOTE" --label "pgv-cc-$SUF" --network "$NET" --memory 3g --env-file "$TMPD/sa.env" "mcr.microsoft.com/mssql/server:${IMAGES[0]}" >/dev/null || fail "the remote container"
wait_up "$REMOTE" || fail "the remote did not come up"
sqv "C5 setup: the linked servers" "EXEC sp_addlinkedserver @server = N'PGV_A_OK', @srvproduct = N'', @provider = N'MSOLEDBSQL', @datasrc = N'$REMOTE';
EXEC sp_addlinkedsrvlogin @rmtsrvname = N'PGV_A_OK', @useself = N'False', @locallogin = NULL, @rmtuser = N'sa', @rmtpassword = N'$SA_PW';
EXEC sp_addlinkedserver @server = N'PGV_B_UNMAPPED', @srvproduct = N'', @provider = N'MSOLEDBSQL', @datasrc = N'$REMOTE';
EXEC sp_droplinkedsrvlogin @rmtsrvname = N'PGV_B_UNMAPPED', @locallogin = NULL;
EXEC sp_addlinkedsrvlogin @rmtsrvname = N'PGV_B_UNMAPPED', @useself = N'False', @locallogin = N'sa', @rmtuser = N'sa', @rmtpassword = N'$SA_PW';
EXEC sp_addlinkedserver @server = N'PGV_C_BAD', @srvproduct = N'', @provider = N'MSOLEDBSQL', @datasrc = N'pgv-no-such-host-$SUF';"
OTHER=0
sq "EXEC sp_addlinkedserver @server = N'PGV_D_OTHER', @srvproduct = N'Oracle', @provider = N'OraOLEDB.Oracle', @datasrc = N'x';" >/dev/null 2>&1 && OTHER=1
col mssql_confcheck
check "C5 the list: the three linked servers$([[ $OTHER == 1 ]] && echo ' and the one of another provider')" "SELECT string_agg(name, ' ' ORDER BY name) FROM pgvigil.mssql_linked_server WHERE instance_id = $IID" "PGV_A_OK PGV_B_UNMAPPED PGV_C_BAD$([[ $OTHER == 1 ]] && echo ' PGV_D_OTHER')"
check "C5 who is mapped: every login with a remote login at A, sa alone at B; no remote login's name is stored" "SELECT string_agg(name || ':' || (SELECT string_agg((l->>'local') || CASE WHEN (l->>'remote')::boolean THEN ' remote' ELSE ' self' END, '+' ORDER BY l->>'local') FROM jsonb_array_elements(logins) l), ' ' ORDER BY name) || ' ' || bool_and(logins::text NOT LIKE '%rmtuser%' AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(logins) l WHERE l ? 'remote_name')) FROM pgvigil.mssql_linked_server WHERE instance_id = $IID AND name IN ('PGV_A_OK', 'PGV_B_UNMAPPED')" "PGV_A_OK:every login remote PGV_B_UNMAPPED:sa remote true"
# a login that may not see every linked server: sys.servers hides one whose default mapping was dropped (B)
CFG=$TMPD/m-low.yaml collect mssql_confcheck sqlbox_low || true
check "C5 a login without the rights to see every linked server: B (no default mapping) hidden, and the list says it is short" "SELECT coalesce((SELECT string_agg(name, ' ' ORDER BY name) FROM pgvigil.mssql_linked_server WHERE instance_id = $LID), 'none') || ' / ' || coalesce((SELECT value #>> '{}' FROM pgvigil.mssql_confcheck_fact WHERE instance_id = $LID AND key = 'linked_list_complete'), 'no fact') || ' / ' || coalesce((SELECT value #>> '{}' FROM pgvigil.mssql_confcheck_fact WHERE instance_id = $IID AND key = 'linked_list_complete'), 'no fact')" "PGV_A_OK PGV_C_BAD$([[ $OTHER == 1 ]] && echo ' PGV_D_OTHER') / 0 / 1"
check "C5 ... a linked server with no mapping visible to it is never marked read (an empty read of the mappings)" "SELECT bool_and(logins_read = (jsonb_array_length(logins) > 0)) FROM pgvigil.mssql_linked_server WHERE instance_id = $LID" t
pq "INSERT INTO pgvigil.mssql_linked_server (instance_id, name, logins, logins_read, snapshot_at) VALUES ($LID, 'PGV_Z_HIDDEN', '[]', false, now() - interval '1 day')" >/dev/null
CFG=$TMPD/m-low.yaml collect mssql_confcheck sqlbox_low || true
check "C5 ... a server its short list does not show is not taken as gone" "SELECT count(*) FROM pgvigil.mssql_linked_server WHERE instance_id = $LID AND name = 'PGV_Z_HIDDEN'" 1
pq "DELETE FROM pgvigil.mssql_linked_server WHERE instance_id = $LID AND name = 'PGV_Z_HIDDEN'" >/dev/null
# no linked server visible to a login that may not see them all: not read, never 'no linked server'
SHORT=$(mkinst "short$SUF" sqlserver)
facts "$SHORT" "[{\"kind\":\"part\",\"part\":\"linked\",\"read\":1,\"note\":\"only the linked servers that keep their default login mapping or map this login are visible\"},{\"kind\":\"fact\",\"key\":\"linked_list_complete\",\"value\":0}]"
check "C5 ... and an empty short list reads not read, never 'the instance has no linked server'" "SELECT status || ': ' || left(detail, 74) FROM pgvigil.mssql_config_checks_of($SHORT) WHERE check_name = 'linked server connection test'" "not read: no linked server is visible to the collector's login: only the linked serv"
pq "DELETE FROM pgvigil.instances WHERE instance_id = $SHORT" >/dev/null
collect mssql_linkedserver_test || true
eqv "C5 without the tag the collection is skipped, saying so" "$(lastrun mssql_linkedserver_test | grep -o '^skipped.*the instance does not carry the tag pgvigil:linkedserver-test' | cut -c1-7)" "skipped"
check "C5 ... and every linked server's row is off, 'set the tag'" "SELECT count(*) || ' ' || bool_and(status = 'off' AND detail LIKE 'not tested: set the tag pgvigil:linkedserver-test%') FROM pgvigil.mssql_config_checks_of($IID) WHERE check_name = 'linked server connection test'" "$((3 + OTHER)) true"
lt() { CFG=$TMPD/m-tag.yaml collect mssql_linkedserver_test || true; }   # the instance's file with the tag
ltst() { pq "SELECT coalesce(string_agg(name || ' ' || outcome || coalesce(' ' || error_number, ''), ', ' ORDER BY name), 'none') FROM pgvigil.mssql_linked_server_test WHERE instance_id = $IID"; }
lt
eqv "C5 with the tag: the run is ok" "$(lastrun mssql_linkedserver_test)" ok
# the runner reads the tag from the instance's configuration: a key hidden with 'pgvigil tag' does not switch the grid off
pq "INSERT INTO pgvigil.instance_tag_overrides (instance_id, key, vals) VALUES ($IID, 'pgvigil', NULL)" >/dev/null
check "C5 the tag hidden over the configuration: the grid follows the configuration the runner reads (not off)" "SELECT count(*) FILTER (WHERE status = 'off') FROM pgvigil.mssql_config_checks_of($IID) WHERE check_name = 'linked server connection test'" 0
pq "DELETE FROM pgvigil.instance_tag_overrides WHERE instance_id = $IID AND key = 'pgvigil'" >/dev/null
eqv "C5 the first run tests two, in name order: A ok, B has no mapping for the monitor login (7416); C waits$([[ $OTHER == 1 ]] && echo '; D is left out')" "$(ltst)" "PGV_A_OK ok, PGV_B_UNMAPPED unmapped 7416, PGV_C_BAD not tested$([[ $OTHER == 1 ]] && echo ', PGV_D_OTHER not tested')"
eqv "C5 ... the rows: A ok, B grey, C not tested yet" "$(st 'linked server connection test' PGV_A_OK) / $(st 'linked server connection test' PGV_B_UNMAPPED) / $(st 'linked server connection test' PGV_C_BAD)" "PGV_A_OK ok / PGV_B_UNMAPPED not read / PGV_C_BAD not read"
check "C5 ... B says 'the collector's login has no mapping there'" "SELECT detail FROM pgvigil.mssql_config_checks_of($IID) WHERE check_name = 'linked server connection test' AND object = 'PGV_B_UNMAPPED'" "not tested: the collector's login has no mapping there (error 7416)"
[[ $OTHER == 1 ]] && check "C5 ... D says its provider is left out" "SELECT status || ': ' || detail FROM pgvigil.mssql_config_checks_of($IID) WHERE check_name = 'linked server connection test' AND object = 'PGV_D_OTHER'" "not read: not tested: the provider OraOLEDB.Oracle is not one of SQL Server's own: left out"
[[ $OTHER == 1 ]] || np "C5 a linked server of another provider: SQL Server on Linux refused to make one (the provider filter is the Go test's)"
TA=$(pq "SELECT tested_at FROM pgvigil.mssql_linked_server_test WHERE instance_id = $IID AND name = 'PGV_A_OK'")
lt
check "C5 ... A's test is a new one" "SELECT tested_at > '$TA'::timestamptz FROM pgvigil.mssql_linked_server_test WHERE instance_id = $IID AND name = 'PGV_A_OK'" t
eqv "C5 the second run goes on at C: a name that does not resolve fails; A is tested again" "$(ltst | sed 's/PGV_C_BAD failed [0-9]*/PGV_C_BAD failed N/')" "PGV_A_OK ok, PGV_B_UNMAPPED unmapped 7416, PGV_C_BAD failed N$([[ $OTHER == 1 ]] && echo ', PGV_D_OTHER not tested')"
eqv "C5 ... C is a warning and a finding" "$(st 'linked server connection test' PGV_C_BAD) $(finding 'linked server connection test' PGV_C_BAD)" "PGV_C_BAD warning 1"
check "C5 ... its detail names the error and since when" "SELECT detail LIKE 'the connection from the monitored server failed after % s, failing since %UTC: error %' FROM pgvigil.mssql_config_checks_of($IID) WHERE check_name = 'linked server connection test' AND object = 'PGV_C_BAD'" t
# a failure whose turn has not come again: two servers are tested a run, so a server's last test can be hours old
pq "UPDATE pgvigil.mssql_linked_server_test SET tested_at = now() - interval '5 hours' WHERE instance_id = $IID AND name = 'PGV_C_BAD'" >/dev/null
eqv "C5 a failure last tested five hours ago is still a finding while the list is read" "$(finding 'linked server connection test' PGV_C_BAD)" 1
# a mapped login the remote server refuses: the server's error text names the remote login, which is stored nowhere
RMT=pgv_rmt_$SUF
sqr "CREATE LOGIN [$RMT] WITH PASSWORD = '$LOW_PW', CHECK_POLICY = OFF;" >/dev/null || bad "C5 setup: the remote server's login"
sqv "C5 setup: a linked server whose mapped remote login has a wrong password" "EXEC sp_addlinkedserver @server = N'PGV_E_BADPW', @srvproduct = N'', @provider = N'MSOLEDBSQL', @datasrc = N'$REMOTE';
EXEC sp_addlinkedsrvlogin @rmtsrvname = N'PGV_E_BADPW', @useself = N'False', @locallogin = NULL, @rmtuser = N'$RMT', @rmtpassword = N'Wrong-$SUF-pw1!';"
CFG=$TMPD/m-tag.yaml collect mssql_confcheck || true
for _ in 1 2 3; do lt; [[ $(pq "SELECT outcome FROM pgvigil.mssql_linked_server_test WHERE instance_id = $IID AND name = 'PGV_E_BADPW'") =~ ^(unmapped|failed)$ ]] && break; done
check "C5 a mapped login the remote refuses: error 18456, grey, worded as a refused login" "SELECT t.outcome || ' ' || t.error_number || ' / ' || c.status || ': ' || c.detail FROM pgvigil.mssql_linked_server_test t JOIN pgvigil.mssql_config_checks_of($IID) c ON c.check_name = 'linked server connection test' AND c.object = t.name WHERE t.instance_id = $IID AND t.name = 'PGV_E_BADPW'" "unmapped 18456 / not read: not tested: the login mapped for the collector's login was refused at the remote server (error 18456)"
check "C5 ... the remote login's name is stored nowhere (the test, the list, the rule's rows)" "SELECT (SELECT count(*) FROM pgvigil.mssql_linked_server_test t WHERE t.instance_id = $IID AND t::text LIKE '%$RMT%') + (SELECT count(*) FROM pgvigil.mssql_linked_server l WHERE l.instance_id = $IID AND l::text LIKE '%$RMT%') + (SELECT count(*) FROM pgvigil.mssql_config_checks_of($IID) c WHERE c::text LIKE '%$RMT%')" 0
eqv "C5 ... and the API sends it nowhere" "$(curl -s "$U/api/mssql/config_checks?instance=$IID" | grep -c "$RMT")" 0
check "C5 ... while B, with no mapping at all, keeps its own words" "SELECT detail FROM pgvigil.mssql_config_checks_of($IID) WHERE check_name = 'linked server connection test' AND object = 'PGV_B_UNMAPPED'" "not tested: the collector's login has no mapping there (error 7416)"
docker stop "$REMOTE" >/dev/null
for _ in 1 2 3; do lt; [[ $(pq "SELECT outcome FROM pgvigil.mssql_linked_server_test WHERE instance_id = $IID AND name = 'PGV_A_OK'") == failed ]] && break; done
eqv "C5 the remote stopped: A fails, a warning" "$(st 'linked server connection test' PGV_A_OK) $(finding 'linked server connection test' PGV_A_OK)" "PGV_A_OK warning 1"
SINCE=$(pq "SELECT first_failed_at FROM pgvigil.mssql_linked_server_test WHERE instance_id = $IID AND name = 'PGV_A_OK'")
eqv "C5 ... 'failing since' is set while it fails" "$([[ -n $SINCE ]] && echo set || echo empty)" set
docker start "$REMOTE" >/dev/null && wait_up "$REMOTE" || bad "C5 the remote did not come back"
for _ in 1 2 3; do lt; [[ $(pq "SELECT outcome FROM pgvigil.mssql_linked_server_test WHERE instance_id = $IID AND name = 'PGV_A_OK'") == ok ]] && break; done
eqv "C5 started again: A ok, the finding gone, 'failing since' cleared (it was $SINCE)" "$(st 'linked server connection test' PGV_A_OK) $(finding 'linked server connection test' PGV_A_OK) [$(pq "SELECT first_failed_at FROM pgvigil.mssql_linked_server_test WHERE instance_id = $IID AND name = 'PGV_A_OK'")]" "PGV_A_OK ok 0 []"
sqv "C5 setup: C dropped" "EXEC sp_dropserver @server = N'PGV_C_BAD', @droplogins = 'droplogins';"
CFG=$TMPD/m-tag.yaml collect mssql_confcheck || true
check "C5 a linked server dropped takes its row and its test with it" "SELECT (SELECT count(*) FROM pgvigil.mssql_linked_server WHERE instance_id = $IID AND name = 'PGV_C_BAD') + (SELECT count(*) FROM pgvigil.mssql_linked_server_test WHERE instance_id = $IID AND name = 'PGV_C_BAD')" 0
docker rm -f -v "$REMOTE" >/dev/null 2>&1

echo "== C6: the identity rule's lines"
sqv "C6 setup: a tinyint identity at 153 of 255" "CREATE TABLE dbo.pgv_tiny (id tinyint IDENTITY(1, 1) NOT NULL PRIMARY KEY, x char(1) NULL);
INSERT dbo.pgv_tiny (x) SELECT TOP (153) 'x' FROM sys.all_objects;" pgvcc
# idc: the column's stored verdict and share, then its finding's severity and the lines the finding names
idc() { pq "SELECT coalesce((SELECT status || ' ' || round(pct_used) FROM pgvigil.mssql_identity_column WHERE instance_id = $IID AND database_name = 'pgvcc' AND table_name = 'pgv_tiny'), 'no row')
  || ' / ' || coalesce((SELECT severity || ', ' || substring(detail from 'warning at [0-9.]+, critical at [0-9.]+') FROM pgvigil.mssql_check_finding WHERE instance_id = $IID AND area = 'identity' AND object = 'pgvcc.dbo.pgv_tiny.id'), 'no finding')"; }
# idcfg: the instance's file with the two lines under mssql_thresholds (the instance is the file's last block)
idcfg() { { cat "$TMPD/m.yaml"; printf '    mssql_thresholds:\n      identity_warn_pct: %s\n      identity_crit_pct: %s\n' "$1" "$2"; } > "$TMPD/m-id.yaml"; }
collect mssql_identity || true
eqv "C6 mssql_identity runs as the monitor login" "$(lastrun mssql_identity)" ok
eqv "C6 60 % under the default lines (75 / 90): ok, no finding" "$(idc)" "ok 60 / no finding"
idcfg 50 80; CFG=$TMPD/m-id.yaml collect mssql_identity || true
eqv "C6 with identity_warn_pct 50 and identity_crit_pct 80 in the instance's file: a warning, its finding naming the lines" "$(idc)" "warn 60 / warning, warning at 50, critical at 80"
idcfg 50 55; CFG=$TMPD/m-id.yaml collect mssql_identity || true
eqv "C6 with 50 and 55: critical" "$(idc)" "crit 60 / critical, warning at 50, critical at 55"
idcfg 80 80
"$BIN" collect -config "$TMPD/m-id.yaml" -once mssql_identity -instance sqlbox > "$TMPD/id.out" 2>&1; RC=$?
eqv "C6 a warning line not under the critical one is refused when the file is read" "$([[ $RC != 0 ]] && echo refused || echo ran), $(grep -q 'identity_warn_pct 80 is not under identity_crit_pct 80' "$TMPD/id.out" && echo named || echo "not named: $(tail -1 "$TMPD/id.out" | cut -c1-160)")" "refused, named"
eqv "C6 ... and the stored verdict is as it was" "$(idc)" "crit 60 / critical, warning at 50, critical at 55"
collect mssql_identity || true
eqv "C6 without the two names: the default lines judge it again" "$(idc)" "ok 60 / no finding"

echo "== C7: sp_Blitz 55 - each user database's owner against an expected owner (BLITZ-GAP; scripts/blitzgap-join-draft-config.sql until lines 2 / 3 are joined)"
C7ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ $(pq "SELECT count(*) FROM pgvigil.mssql_config_expect_keys() WHERE kind = 'database' AND key = 'owner'") != 1 && -f $C7ROOT/scripts/blitzgap-join-draft-config.sql ]]; then
  psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -f "$C7ROOT/scripts/blitzgap-join-draft-config.sql" >/dev/null && echo "  the join draft applied (scripts/blitzgap-join-draft-config.sql: lines 2 / 3 are not joined yet)" || bad "C7: the join draft did not apply"
fi
eqv "C7 the key 'database owner' (sp_Blitz 55) is in the expected values' list" "$(pq "SELECT kind || ' ' || key || ' ' || vtype || ' ' || default_on || ' ' || rule FROM pgvigil.mssql_config_expect_keys() WHERE kind = 'database' AND key = 'owner'")" "database owner text true sp_Blitz 55"
sqv "C7 setup: a database owned by sa and one owned by $OWN" "CREATE DATABASE pgv_own_sa; CREATE DATABASE pgv_own_x; ALTER AUTHORIZATION ON DATABASE::pgv_own_x TO [$OWN];"
# msdb's owner can change (master, model, tempdb and distribution refuse: 15109 - Proof-Box probe 11-16 07:59)
sqv "C7 setup: msdb owned by $OWN" "ALTER AUTHORIZATION ON DATABASE::msdb TO [$OWN];"
collect mssql_checks || bad "C7: collect mssql_checks"
eqv "C7 the default (sa): the database owned by $OWN is info, sa's ok" "$(st 'database owner' pgv_own_sa), $(st 'database owner' pgv_own_x)" "pgv_own_sa ok, pgv_own_x info"
eqv "C7 its words" "$(det 'database owner' pgv_own_x)" "the owner is $OWN; the expected owner is sa (the default)"
# sp_Blitz 8.35 (20261114) L3831: master, model, msdb and tempdb against the original sa always (FOLD-55 b2)
eqv "C7 the system databases against the original sa: master ok, msdb owned by $OWN info" "$(st 'database owner' master), $(st 'database owner' msdb)" "master ok, msdb info"
eqv "C7 ... msdb's words" "$(det 'database owner' msdb)" "the owner is $OWN; the expected owner is sa (a system database: always the original sa)"
eqv "C7 info makes no finding row" "$(pq "SELECT count(*) FROM pgvigil.mssql_config_check_findings WHERE instance_id = $IID AND check_name = 'database owner'")" 0
eqv "C7 the expected owner set to $OWN on the instance" "$(exi "\"kind\":\"database\",\"key\":\"owner\",\"value\":\"$OWN\"")" done
eqv "C7 ... then sa's database is info and $OWN's ok" "$(st 'database owner' pgv_own_sa), $(st 'database owner' pgv_own_x)" "pgv_own_sa info, pgv_own_x ok"
eqv "C7 ... a system database stays against sa: msdb info, master ok" "$(st 'database owner' msdb), $(st 'database owner' master)" "msdb info, master ok"
eqv "C7 set OFF (any case): every row off" "$(exi '"kind":"database","key":"owner","value":"OFF"') $(st 'database owner' pgv_own_sa), $(st 'database owner' pgv_own_x)" "done pgv_own_sa off, pgv_own_x off"
eqv "C7 ... the system databases' rows too" "$(st 'database owner' msdb), $(st 'database owner' master)" "msdb off, master off"
eqv "C7 back to the default" "$(exn '"kind":"database","key":"owner"') $(st 'database owner' pgv_own_x)" "done pgv_own_x info"
eqv "C7 a database left out" "$(exi '"kind":"database","key":"owner","value":"sa","exclusions":["pgv_own_x"]') $(st 'database owner' pgv_own_x)" "done no row"
eqv "C7 a system database left out, the others kept" "$(exi '"kind":"database","key":"owner","value":"sa","exclusions":["msdb"]') $(st 'database owner' msdb) / $(st 'database owner' master)" "done no row / master ok"
exn '"kind":"database","key":"owner"' >/dev/null
# sp_Blitz 8.35 L870 leaves 55 out on Managed Instance (EngineEdition 8; kit issue #1919: sa is disabled there and the
# admin is named when the instance is created) - no row at all, read or not (FOLD-55 b1; written rows)
MI55=$(mkinst "mi55$SUF" azuresqlmi)
eqv "C7 Managed Instance: no row before its databases are read" "$(st 'database owner' '' "$MI55")" "no row"
pq "INSERT INTO pgvigil.mssql_database_option (instance_id, database_name, database_id, state, is_system, options, snapshot_at) VALUES ($MI55, 'pgv_mi_db', 5, 'ONLINE', false, '{\"owner\": \"pgv_mi_admin\"}', now()), ($MI55, 'msdb', 4, 'ONLINE', true, '{\"owner\": \"pgv_mi_admin\"}', now())" >/dev/null || bad "C7: the Managed Instance's written database rows"
eqv "C7 ... nor with a user and a system database owned by its admin" "$(st 'database owner' '' "$MI55")" "no row"
pq "DELETE FROM pgvigil.instances WHERE instance_id = $MI55" >/dev/null
sqv "C7 undo: msdb back to sa" "ALTER AUTHORIZATION ON DATABASE::msdb TO sa;"
sqv "C7 undo" "DROP DATABASE pgv_own_sa; DROP DATABASE pgv_own_x;"

# ---- V: the version run ---------------------------------------------------------------------------------------------
for img in "${IMAGES[@]:1}"; do
  echo "== V: $img"
  kill "$SRV_PID" 2>/dev/null; SRV_PID=
  docker rm -f -v "$SQL" >/dev/null 2>&1
  pq "DELETE FROM pgvigil.mssql_config_expect; DELETE FROM pgvigil.instances WHERE name IN ('sqlbox', 'sqlbox_low')" >/dev/null
  start_server "$img"
  ok "SQL Server $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))")"
  for c in $BASE; do
    collect "$c" || true
    eqv "$img A: $c runs as the monitor login" "$(lastrun "$c")" "ok"
  done
  IID=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox'")
  good_practice
  default_grid "$img"
  db_devs "$img"
done
np "SQL Server 2016: no Linux image"
np "a Windows server live: no write is made on the lab's Windows VM (the start modes, Named Pipes and the processor scheduling are proven on written rows)"
np "the fail-safe operator read live: the monitor login may not run sp_MSgetalertinfo, and on Linux sp_MSsetalertinfo leaves it unset (ok and warning are proven on written rows)"
np "the editor's POST with a signed-in user: every write here goes through the function; the two 403s are proven"

echo "PROOF $( [[ $FAILS == 0 ]] && echo OK || echo FAILED ): mssql config checks ($FAILS failed, $NP not proven)"
exit $FAILS
