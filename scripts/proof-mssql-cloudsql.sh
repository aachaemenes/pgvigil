#!/usr/bin/env bash
# Proof of Google Cloud SQL for SQL Server as a platform (CLOUDSQL C2) against a REAL instance: scripts/lab/gcp-cloudsql.sh
# (up; allow <this machine>). It settles what docs/sqlserver-cloud.md's Cloud SQL section leaves 'not settled until a
# real instance answers' and records each answer; it never weakens a row to make it pass.
#
# Needs: docker (sqlcmd from PGVIGIL_SQLCMD_IMAGE, default mcr.microsoft.com/mssql/server:2022-latest), go, psql, and
#   PGVIGIL_ADMIN_DSN   a superuser connection to a PostgreSQL in KEYWORD form, no dbname (the store is made there)
#   PGVIGIL_LAB_STATE   the lab's state file, default .lab/gcp-cloudsql.env (the sqlserver user's password and the
#                       monitor login's reach sqlcmd and the collector through the environment by name; none printed)
#
# What it makes, and removes on every exit path the shell can catch: a store database pgvigil_gcsproof_<n>; on the
# instance, the monitor login pgv_monitor (and its msdb user) and the four Extended Events sessions of
# `pgvigil mssql-xe -print -form cloudsql -install-id g<n>` (dropped by the -drop script; the login stays until the
# lab's down deletes the instance).
#
# Expected (written before the first run):
#  R  the sqlserver user's own rights, RECORDED ONLY (not graded: each an answer for the docs): CustomerDbRootRole
#     membership, the host platform, its server permission count.
#  L  the documented login, each statement run alone as the sqlserver user and its answer recorded (ok, or the
#     message): CREATE LOGIN, GRANT VIEW SERVER STATE and VIEW ANY DEFINITION AS [CustomerDbRootRole], in msdb CREATE USER and
#     db_datareader (Google protects msdb from users made in T-SQL: a refusal there is the expected kind of answer).
#  A  `collect -once mssql_instance` as pgv_monitor: platform cloudsqlsqlserver when VIEW ANY DEFINITION was granted
#     (else sqlserver, and the docs say the platform: cloudsql word is then needed).
#  D  every mssql_ collection once as pgv_monitor: each outcome (ok / skipped with its reason / error with its
#     message) listed; no 'error' expected - each one is a finding for the docs or the code.
#  J  mssql_jobs: ok when msdb let the login in (L), else skipped with Google's reason.
#  X  the -form cloudsql script run by the sqlserver user: the four sessions made and started (sys.dm_xe_sessions: 4),
#     the slow capture's file under /var/opt/mssql/xevents/ (a running session's filename there); mssql_xe as
#     pgv_monitor ends ok with the four sessions' states stored running (mssql_xe_state); then dropped.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?a superuser connection in keyword form, no dbname}"
STATE=${PGVIGIL_LAB_STATE:-.lab/gcp-cloudsql.env}
SQLCMD_IMAGE=${PGVIGIL_SQLCMD_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
fail() { echo "FAIL: $*" >&2; exit 1; }
for t in docker go psql; do command -v "$t" >/dev/null || fail "$t is not on this machine"; done
[ -r "$STATE" ] || fail "no lab state file $STATE (scripts/lab/gcp-cloudsql.sh up, allow)"
# shellcheck disable=SC1090
. "$STATE"
[ -n "${GCS_IP:-}" ] || fail "$STATE has no address (up did not finish)"
umask 077
WORK=$(mktemp -d); N=$RANDOM; STORE="pgvigil_gcsproof_$N"; XEID="g$N"; MADE_XE=
# sq <database> <login> <password var> [sqlcmd options]: one batch from stdin; the password reaches docker through the
# environment BY NAME (-e SQLCMDPASSWORD), never on a command line
sq() { local db=$1 login=$2; SQLCMDPASSWORD=${!3}; export SQLCMDPASSWORD; shift 3
  docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$SQLCMD_IMAGE" \
    -S "tcp:$GCS_IP,$GCS_PORT" -U "$login" -d "$db" -C -l 60 -h -1 -W -s '|' "$@" -i /dev/stdin; }
cleanup() {
  if [ -n "$MADE_XE" ]; then "$WORK/pgvigil" mssql-xe -print -drop -form cloudsql -install-id "$XEID" > "$WORK/xe-drop.sql" 2>/dev/null \
    && sq master "$ROOT_USER" ROOT_PW < "$WORK/xe-drop.sql" >/dev/null 2>&1 || echo "CLEANUP: the XE sessions of $XEID were not dropped" >&2; fi
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $STORE with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
VERDICT=PASS

echo "== R: the sqlserver user's own rights"
sq master "$ROOT_USER" ROOT_PW <<'SQL' | sed 's/^/   /'
SET NOCOUNT ON;
SELECT 'CustomerDbRootRole member ' + CAST(ISNULL(IS_SRVROLEMEMBER(N'CustomerDbRootRole'), -1) AS varchar(4))
     + '; host ' + (SELECT host_platform + ' ' + host_distribution FROM sys.dm_os_host_info)
     + '; server permissions ' + CAST((SELECT COUNT(*) FROM fn_my_permissions(NULL, 'SERVER')) AS varchar(10))
     + '; ' + CAST(SERVERPROPERTY('Edition') AS varchar(60)) + ' ' + CAST(SERVERPROPERTY('ProductVersion') AS varchar(30));
SQL

echo "== L: the documented login, one statement at a time as the sqlserver user"
L_OK=()
step() { local db=$1 what=$2 sql=$3 out
  if out=$(printf 'SET NOCOUNT ON;\n%s\n' "$sql" | sq "$db" "$ROOT_USER" ROOT_PW -b 2>&1); then echo "   ok      $what"; L_OK+=("$what")
  else echo "   refused $what: $(tr -s '\r\n' ' ' <<<"$out" | cut -c1-220)"; fi; }
step master 'CREATE LOGIN' "IF SUSER_ID(N'$MON_USER') IS NULL CREATE LOGIN [$MON_USER] WITH PASSWORD = N'$MON_PW';"
# the sqlserver user holds these WITH GRANT OPTION through its role only (CustomerDbRootRole): Cloud SQL refuses a
# plain GRANT (Msg 4613, Grantor does not have GRANT permission); the grant names the role
step master 'VIEW SERVER STATE' "GRANT VIEW SERVER STATE TO [$MON_USER] AS [CustomerDbRootRole];"
step master 'VIEW ANY DEFINITION' "GRANT VIEW ANY DEFINITION TO [$MON_USER] AS [CustomerDbRootRole];"
step msdb 'msdb user' "IF USER_ID(N'$MON_USER') IS NULL CREATE USER [$MON_USER] FOR LOGIN [$MON_USER];"
step msdb 'msdb db_datareader' "ALTER ROLE db_datareader ADD MEMBER [$MON_USER];"
printf '%s\n' "${L_OK[@]}" | grep -qx 'CREATE LOGIN' || fail "L: the monitor login could not be made: nothing else can run"

echo "== A, D, J: the collector as $MON_USER (store $STORE)"
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $STORE" >/dev/null
go build -o "$WORK/pgvigil" ./cmd/pgvigil
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$STORE"
export GCS_MON_DSN="sqlserver://$MON_USER:$MON_PW@$GCS_IP:$GCS_PORT?database=master&encrypt=true&TrustServerCertificate=true"
cat > "$WORK/cfg.yaml" <<'EOF'
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: gcs-live
    engine: sqlserver
    dsn: env:GCS_MON_DSN
EOF
"$WORK/pgvigil" migrate -config "$WORK/cfg.yaml" >/dev/null
q() { psql "$PGVIGIL_REPO_DSN" -XAt -F '|' -v ON_ERROR_STOP=1 -c "$1"; }
COLLS=$("$WORK/pgvigil" collect -config "$WORK/cfg.yaml" -once no_such_collection 2>&1 | grep -o 'known: \[[^]]*\]' | tr -d '[]' | tr ' ' '\n' | grep '^mssql_' || true)
[ "$(grep -c . <<<"$COLLS")" -ge 25 ] || fail "the SQL Server collections were not listed"
"$WORK/pgvigil" collect -config "$WORK/cfg.yaml" -once mssql_instance -instance gcs-live > "$WORK/instance.out" 2>&1 || true
PLAT=$(q "select platform from pgvigil.instances where name = 'gcs-live'")
ST_I=$(q "select d.status from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'gcs-live' and d.collection = 'mssql_instance'")
if [ "$ST_I" != ok ]; then VERDICT=FAIL; echo "FAIL A: mssql_instance ended '${ST_I:-with no row}'"; tail -3 "$WORK/instance.out"
elif printf '%s\n' "${L_OK[@]}" | grep -qx 'VIEW ANY DEFINITION'; then
  [ "$PLAT" = cloudsqlsqlserver ] && echo "ok   A: stored as cloudsqlsqlserver" || { VERDICT=FAIL; echo "FAIL A: stored as '$PLAT' with VIEW ANY DEFINITION granted"; tail -3 "$WORK/instance.out"; }
else
  # without VIEW ANY DEFINITION Google's marks are invisible: the server reads as plain SQL Server (the docs' platform: cloudsql then names it)
  [ "$PLAT" = sqlserver ] && echo "ok   A: VIEW ANY DEFINITION was refused: stored as sqlserver" || { VERDICT=FAIL; echo "FAIL A: VIEW ANY DEFINITION refused, stored as '$PLAT', not sqlserver"; }
fi
for c in $COLLS; do [ "$c" = mssql_instance ] || "$WORK/pgvigil" collect -config "$WORK/cfg.yaml" -once "$c" -instance gcs-live >> "$WORK/d.out" 2>&1 || true; done
echo "   D: every collection's outcome (collection | status | its note):"
q "select d.collection, d.status, left(coalesce(d.note, ''), 160) from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'gcs-live' order by 1" | sed 's/^/     /'
# every listed collection has its row (a run that ends before log_collection - a failed Detect or engine check -
# writes none) and each row ended ok or skipped
NC=$(grep -c . <<<"$COLLS")
IFS='|' read -r NROWS NGOOD < <(q "select count(*), count(*) filter (where d.status in ('ok', 'skipped')) from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'gcs-live' and d.collection like 'mssql\_%'")
[ "$NROWS|$NGOOD" = "$NC|$NC" ] && echo "ok   D: $NC collections, each ended ok or skipped" || { VERDICT=FAIL; echo "FAIL D: $NC collections listed, $NROWS rows stored, $NGOOD ok or skipped (above): each missing or failed one a finding"; }
JST=$(q "select d.status || '|' || coalesce(d.note, '') from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'gcs-live' and d.collection = 'mssql_jobs'")
echo "   J: mssql_jobs = $JST"
if printf '%s\n' "${L_OK[@]}" | grep -qx 'msdb db_datareader'; then
  [[ "$JST" == ok\|* ]] && echo "ok   J: msdb let the login in: mssql_jobs ok" || { VERDICT=FAIL; echo "FAIL J: msdb let the login in, mssql_jobs '$JST'"; }
else
  [[ "$JST" == skipped\|* && "${JST,,}" == *msdb* ]] && echo "ok   J: msdb refused the login: mssql_jobs skipped with msdb named" || { VERDICT=FAIL; echo "FAIL J: msdb refused the login, mssql_jobs '$JST' (want skipped, naming msdb)"; }
fi

echo "== X: the -form cloudsql sessions, made by the sqlserver user"
"$WORK/pgvigil" mssql-xe -print -form cloudsql -install-id "$XEID" > "$WORK/xe.sql"
MADE_XE=1
if sq master "$ROOT_USER" ROOT_PW -b < "$WORK/xe.sql" > "$WORK/xe.out" 2>&1; then echo "   the script ran"; else VERDICT=FAIL; echo "FAIL X: the script was refused:"; tail -5 "$WORK/xe.out" | sed 's/^/     /'; fi
sq master "$ROOT_USER" ROOT_PW <<SQL > "$WORK/xe-running.txt" 2>&1 || true
SET NOCOUNT ON;
SELECT s.name + ' ' + ISNULL((SELECT TOP (1) CAST(f.value AS nvarchar(200)) FROM sys.server_event_session_fields f
         JOIN sys.server_event_sessions es ON es.event_session_id = f.event_session_id WHERE es.name = s.name AND f.name = N'filename'), '(ring buffer)')
FROM sys.dm_xe_sessions s WHERE s.name LIKE N'pgvigil[_]$XEID[_]%' ORDER BY s.name;
SQL
sed 's/^/   running: /' "$WORK/xe-running.txt"
NRUN=$(grep -c "^pgvigil_${XEID}_" "$WORK/xe-running.txt" || true)
[ "$NRUN" = 4 ] && echo "ok   X: 4 sessions running" || { VERDICT=FAIL; echo "FAIL X: $NRUN session(s) running, want 4"; }
grep -q '/var/opt/mssql/xevents/' "$WORK/xe-running.txt" && echo "ok   X: a capture file under /var/opt/mssql/xevents/" || { VERDICT=FAIL; echo "FAIL X: no running session writes under /var/opt/mssql/xevents/"; }
"$WORK/pgvigil" collect -config "$WORK/cfg.yaml" -once mssql_xe -instance gcs-live > "$WORK/xe-collect.out" 2>&1 || true
XST=$(q "select d.status || '|' || coalesce(d.note, '') from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'gcs-live' and d.collection = 'mssql_xe'")
echo "   mssql_xe: $XST"
q "select s.capture || '|' || s.state || '|' || coalesce(s.session_name, '') from pgvigil.mssql_xe_state s join pgvigil.instances i using (instance_id) where i.name = 'gcs-live' order by 1" | sed 's/^/     state: /'
NST=$(q "select count(*) from pgvigil.mssql_xe_state s join pgvigil.instances i using (instance_id) where i.name = 'gcs-live' and s.state = 'running' and s.session_name like 'pgvigil\_${XEID}\_%'")
[[ "$XST" == ok\|* && "$NST" = 4 ]] && echo "ok   X: mssql_xe ok, the four sessions stored running" || { VERDICT=FAIL; echo "FAIL X: mssql_xe '$XST', $NST of the four sessions stored running"; }
echo "proof-mssql-cloudsql: $VERDICT (a real Cloud SQL for SQL Server instance; each 'refused' and 'note' line above is an answer for the docs)"
[ "$VERDICT" = PASS ]
