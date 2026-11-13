#!/usr/bin/env bash
# Proof of Azure SQL Managed Instance as a platform (CLOUDSQL C5) against a REAL instance: scripts/lab/azure-mi.sh
# (up; allow <this machine>; logins). It records what each read answers and never weakens a row to make it pass.
#
# Needs: docker (sqlcmd from PGVIGIL_SQLCMD_IMAGE, default mcr.microsoft.com/mssql/server:2022-latest), go, psql, and
#   PGVIGIL_ADMIN_DSN   a superuser connection to a PostgreSQL in KEYWORD form, no dbname (the store is made there)
#   PGVIGIL_LAB_STATE   the lab's state file, default .lab/azure-mi.env (the passwords reach sqlcmd and the collector
#                       through the environment by name; none is printed)
#
# What it makes, and removes on every exit path the shell can catch: a store database pgvigil_miproof_<n>; on the
# instance, the four Extended Events sessions of `pgvigil mssql-xe -print -form azuresqlmi -install-id m<n>` (dropped by
# the -drop script). The login and the user database are the lab's (logins), gone with the instance at down.
#
# Expected (written before the first run):
#  M0 `collect -once mssql_instance` as pgv_monitor: ok, platform azuresqlmi (EngineEdition 8).
#  M1 every mssql_ collection once as pgv_monitor: a row for each listed collection, each ok or skipped (a 'partial' or
#     an 'error' is a finding, listed); mssql_mirroring and mssql_logshipping skipped with C5's words ('Azure SQL Managed
#     Instance does not support database mirroring', '... has no log shipping ...'); the checks' alerts area not read
#     with C5's words ('... does not support SQL Server Agent alerts yet: only the operators are read').
#  M2 backups: msdb.dbo.backupset as the admin for the lab's database pgvproof and for master / model / msdb (counts by
#     type, RECORDED: whether the service's automatic backups have rows there); pgvigil's mssql_backup_judged: master,
#     model and msdb not judged with 0129's two reasons.
#  M3 the availability reads (mssql_ag) on General Purpose: the status and note RECORDED (no readable replica there).
#  M4 the error log (mssql_errorlog) as pgv_monitor: ok, or skipped / partial with its words, RECORDED.
#  M5 the -form azuresqlmi script run by the admin: four sessions made and started (sys.dm_xe_sessions: 4, ring buffers
#     only), mssql_xe as pgv_monitor ends ok with the four stored running; then dropped.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?a superuser connection in keyword form, no dbname}"
STATE=${PGVIGIL_LAB_STATE:-.lab/azure-mi.env}
SQLCMD_IMAGE=${PGVIGIL_SQLCMD_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
fail() { echo "FAIL: $*" >&2; exit 1; }
for t in docker go psql; do command -v "$t" >/dev/null || fail "$t is not on this machine"; done
[ -r "$STATE" ] || fail "no lab state file $STATE (scripts/lab/azure-mi.sh up, allow, logins)"
# shellcheck disable=SC1090
. "$STATE"
[ -n "${MI_PUBLIC:-}" ] || fail "$STATE has no public endpoint host (up did not finish)"
umask 077
WORK=$(mktemp -d); N=$RANDOM; STORE="pgvigil_miproof_$N"; XEID="m$N"; MADE_XE=
# sq <database> <login> <password var> [sqlcmd options]: one batch from stdin; the password reaches docker through the
# environment BY NAME (-e SQLCMDPASSWORD), never on a command line
sq() { local db=$1 login=$2; SQLCMDPASSWORD=${!3}; export SQLCMDPASSWORD; shift 3
  docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$SQLCMD_IMAGE" \
    -S "tcp:$MI_PUBLIC,$MI_PORT" -U "$login" -d "$db" -C -l 60 -h -1 -W -s '|' "$@" -i /dev/stdin; }
cleanup() {
  if [ -n "$MADE_XE" ]; then "$WORK/pgvigil" mssql-xe -print -drop -form azuresqlmi -install-id "$XEID" > "$WORK/xe-drop.sql" 2>/dev/null \
    && sq master "$ADMIN_USER" ADMIN_PW < "$WORK/xe-drop.sql" >/dev/null 2>&1 || echo "CLEANUP: the XE sessions of $XEID were not dropped" >&2; fi
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $STORE with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
VERDICT=PASS

echo "== M0, M1: the collector as $MON_USER (store $STORE)"
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $STORE" >/dev/null
go build -o "$WORK/pgvigil" ./cmd/pgvigil
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$STORE"
export MI_MON_DSN="sqlserver://$MON_USER:$MON_PW@$MI_PUBLIC:$MI_PORT?database=master&encrypt=true"
cat > "$WORK/cfg.yaml" <<'EOF'
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: mi-live
    engine: sqlserver
    dsn: env:MI_MON_DSN
EOF
"$WORK/pgvigil" migrate -config "$WORK/cfg.yaml" >/dev/null
q() { psql "$PGVIGIL_REPO_DSN" -XAt -F '|' -v ON_ERROR_STOP=1 -c "$1"; }
COLLS=$("$WORK/pgvigil" collect -config "$WORK/cfg.yaml" -once no_such_collection 2>&1 | grep -o 'known: \[[^]]*\]' | tr -d '[]' | tr ' ' '\n' | grep '^mssql_' || true)
[ "$(grep -c . <<<"$COLLS")" -ge 25 ] || fail "the SQL Server collections were not listed"
"$WORK/pgvigil" collect -config "$WORK/cfg.yaml" -once mssql_instance -instance mi-live > "$WORK/instance.out" 2>&1 || true
M0=$(q "select coalesce(d.status, 'none') || '|' || coalesce(i.platform, '') from pgvigil.instances i left join pgvigil.collection_dates d on d.instance_id = i.instance_id and d.collection = 'mssql_instance' where i.name = 'mi-live'")
[ "$M0" = "ok|azuresqlmi" ] && echo "ok   M0: mssql_instance ok, platform azuresqlmi" || { VERDICT=FAIL; echo "FAIL M0: status|platform = '$M0'"; tail -3 "$WORK/instance.out"; }
for c in $COLLS; do [ "$c" = mssql_instance ] || "$WORK/pgvigil" collect -config "$WORK/cfg.yaml" -once "$c" -instance mi-live >> "$WORK/d.out" 2>&1 || true; done
echo "   M1: every collection's outcome (collection | status | its note):"
q "select d.collection, d.status, left(coalesce(d.note, ''), 160) from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'mi-live' order by 1" | sed 's/^/     /'
NC=$(grep -c . <<<"$COLLS")
IFS='|' read -r NROWS NGOOD < <(q "select count(*), count(*) filter (where d.status in ('ok', 'skipped')) from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'mi-live' and d.collection like 'mssql\_%'")
[ "$NROWS|$NGOOD" = "$NC|$NC" ] && echo "ok   M1: $NC collections, each ok or skipped" || { VERDICT=FAIL; echo "FAIL M1: $NC collections listed, $NROWS rows stored, $NGOOD ok or skipped (above): each other one a finding"; }
for want in "mssql_mirroring|skipped|Azure SQL Managed Instance does not support database mirroring" "mssql_logshipping|skipped|Azure SQL Managed Instance has no log shipping"; do
  c=${want%%|*}; got=$(q "select d.status || '|' || coalesce(d.note, '') from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'mi-live' and d.collection = '$c'")
  [[ "$got" == "${want#*|}"* ]] && echo "ok   M1: $c skipped with C5's words" || { VERDICT=FAIL; echo "FAIL M1: $c = '$got'"; }
done
AL=$(q "select coalesce(a.note, '') from pgvigil.mssql_check_area a join pgvigil.instances i using (instance_id) where i.name = 'mi-live' and a.area = 'alerts'")
echo "   M1: the checks' alerts area: '$AL'"
[[ "$AL" == "Azure SQL Managed Instance does not support SQL Server Agent alerts yet"* ]] && echo "ok   M1: the alerts area not read, in C5's words" || { VERDICT=FAIL; echo "FAIL M1: the alerts area's note is not C5's"; }

echo "== M2: backups"
sq msdb "$ADMIN_USER" ADMIN_PW <<SQL | sed 's/^/   msdb as the admin: /'
SET NOCOUNT ON;
SELECT d.name + ' ' + ISNULL((SELECT STRING_AGG(CAST(b.type AS varchar(1)) + '=' + CAST(b.n AS varchar(10)), ' ')
         FROM (SELECT type, COUNT(*) AS n FROM msdb.dbo.backupset WHERE database_name = d.name GROUP BY type) b), 'no backupset row')
FROM sys.databases d WHERE d.name IN (N'master', N'model', N'msdb', N'$MI_DB') ORDER BY d.name;
SQL
q "select database_name || '|' || coalesce(not_judged, '(judged)') from pgvigil.mssql_backup_judged j join pgvigil.instances i using (instance_id) where i.name = 'mi-live' order by 1" | sed 's/^/   judged: /' > "$WORK/judged.txt"
cat "$WORK/judged.txt"
NJ=$(grep -cE '^   judged: (master\|Azure SQL Managed Instance does not back up the physical master|model\|Azure SQL Managed Instance backs up its system databases|msdb\|Azure SQL Managed Instance backs up its system databases)' "$WORK/judged.txt" || true)
[ "$NJ" = 3 ] && echo "ok   M2: master, model and msdb not judged with 0129's reasons" || { VERDICT=FAIL; echo "FAIL M2: $NJ of master / model / msdb carry 0129's reason"; }

echo "== M3, M4: recorded"
echo "   M3 mssql_ag: $(q "select d.status || ' ' || coalesce(d.note, '') from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'mi-live' and d.collection = 'mssql_ag'")"
echo "   M4 mssql_errorlog: $(q "select d.status || ' ' || coalesce(d.note, '') from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'mi-live' and d.collection = 'mssql_errorlog'")"

echo "== M5: the -form azuresqlmi sessions, made by the admin"
"$WORK/pgvigil" mssql-xe -print -form azuresqlmi -install-id "$XEID" > "$WORK/xe.sql"
MADE_XE=1
if sq master "$ADMIN_USER" ADMIN_PW -b < "$WORK/xe.sql" > "$WORK/xe.out" 2>&1; then echo "   the script ran"; else VERDICT=FAIL; echo "FAIL M5: the script was refused:"; tail -5 "$WORK/xe.out" | sed 's/^/     /'; fi
sq master "$ADMIN_USER" ADMIN_PW <<SQL > "$WORK/xe-running.txt" 2>&1 || true
SET NOCOUNT ON;
SELECT s.name FROM sys.dm_xe_sessions s WHERE s.name LIKE N'pgvigil[_]$XEID[_]%' ORDER BY s.name;
SQL
sed 's/^/   running: /' "$WORK/xe-running.txt"
NRUN=$(grep -c "^pgvigil_${XEID}_" "$WORK/xe-running.txt" || true)
[ "$NRUN" = 4 ] && echo "ok   M5: 4 sessions running" || { VERDICT=FAIL; echo "FAIL M5: $NRUN session(s) running, want 4"; }
"$WORK/pgvigil" collect -config "$WORK/cfg.yaml" -once mssql_xe -instance mi-live > "$WORK/xe-collect.out" 2>&1 || true
XST=$(q "select d.status || '|' || coalesce(d.note, '') from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'mi-live' and d.collection = 'mssql_xe'")
NST=$(q "select count(*) from pgvigil.mssql_xe_state s join pgvigil.instances i using (instance_id) where i.name = 'mi-live' and s.state = 'running' and s.session_name like 'pgvigil\_${XEID}\_%'")
echo "   mssql_xe: $XST"
[[ "$XST" == ok\|* && "$NST" = 4 ]] && echo "ok   M5: mssql_xe ok, the four sessions stored running" || { VERDICT=FAIL; echo "FAIL M5: mssql_xe '$XST', $NST of the four sessions stored running"; }
echo "proof-mssql-mi: $VERDICT (a real Azure SQL Managed Instance; each RECORDED line above is an answer for the docs)"
[ "$VERDICT" = PASS ]
