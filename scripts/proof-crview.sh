#!/usr/bin/env bash
# proof-crview.sh - the proof of parity set 3 (the custom report view, three grid rows, three PM rows): a throwaway
# repository with the demo's fleet seeded for the pages, two REAL instances for the runs (the box's PostgreSQL and a
# SQL Server 2022 container of the run's own), an admin and an operator of the UI, and `pgvigil serve` WITH the login;
# then scripts/crview-check.mjs drives it in headless Chromium. Every case's expected is in crview-check.mjs's header.
#
#   PGVIGIL_ADMIN_DSN    keyword-form connection to a cluster as a superuser (no dbname; the proof makes its database
#                        and two logins with a random suffix and drops them at the end)
#   PGVIGIL_BIN          the build to prove (its web bundle built in); default bin/pgvigil
#   PGVIGIL_CRVIEW_ONLY  the cases to run, by name prefix (crview-check.mjs)
#   PGVIGIL_OLD_SRC      a source tree from before 0372: its build migrates the store first and saves a report (CR-upgrade)
#   PGVIGIL_PROOF_OUT    a folder for the logs (default: removed with the work folder)
# Needs docker, psql, curl, node 22+ and chromium. The sa password (an env file) and the UI users' passwords (the
# environment) never reach a command line; the run's own throwaway logins (the container's crmon, the store's pg_monitor
# role) are made by statements whose text holds their password, as proof-mssql-actions.sh's are. The last line is
# crview-check.mjs's 'crview-check: <n> FAIL'.
set -uo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
BIN=$(realpath "${PGVIGIL_BIN:-bin/pgvigil}")
SUF=$RANDOM; DB=pgvigil_crview_$SUF; MON=pgv_cr_mon_$SUF
WORK=$(mktemp -d); CT=crview-mssql-$SUF; SRV=""
pw() { printf 'Pv9%s' "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
PPW=$(pw); UPW=$(pw); OPW=$(pw); MSPW=$(pw)
die() { echo "FAIL setup: $*"; echo "crview-check: setup FAIL"; exit 1; }
cleanup() {
  [[ -n "${PGVIGIL_PROOF_OUT:-}" ]] && mkdir -p "$PGVIGIL_PROOF_OUT" && cp "$WORK"/*.log "$PGVIGIL_PROOF_OUT"/ 2>/dev/null
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null
  docker rm -fv "$CT" >/dev/null 2>&1
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" -c "drop role if exists $MON" -c "drop function if exists public.cr_notice()" -c "drop schema if exists pgvigil_tools cascade" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in docker psql curl node chromium; do command -v $t >/dev/null || die "$t is not on this machine"; done

# ---- the SQL Server container: a monitoring login that runs the SQL Server report
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%sAa1!\n' "$(pw)" > "$WORK/sa.env"
docker run -d --name "$CT" --env-file "$WORK/sa.env" -p 127.0.0.1::1433 mcr.microsoft.com/mssql/server:2022-latest >/dev/null || die "the SQL Server container did not start"
MSPORT=$(docker port "$CT" 1433/tcp | head -1 | sed 's/.*://')
sq() { docker exec --env-file "$WORK/sa.env" "$CT" bash -c '/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -W -h -1 -Q "SET NOCOUNT ON; '"$1"'"'; }
for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
sq "SELECT 1" >/dev/null 2>&1 || die "the SQL Server container did not answer in 180 s"
sq "CREATE LOGIN crmon WITH PASSWORD = '$MSPW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO crmon;" >/dev/null || die "the SQL Server login"

# ---- the repository, the demo's fleet, the two real instances, the users, serve with the login
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $DB" -c "create role $MON login password '$PPW' in role pg_monitor" >/dev/null || die "the database and the role"
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
HOST=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select coalesce(host(inet_server_addr()), '127.0.0.1')"); PORT5=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select current_setting('port')")
export CR_PG="host=$HOST port=$PORT5 user=$MON password=$PPW dbname=postgres sslmode=disable"
export CR_MS="sqlserver://crmon:$MSPW@127.0.0.1:$MSPORT?database=master&encrypt=true&TrustServerCertificate=true"
cat > "$WORK/pgvigil.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - {name: cr-pg-$SUF, dsn: "env:CR_PG"}
  - {name: cr-ms-$SUF, engine: sqlserver, dsn: "env:CR_MS"}
EOF
# CR-tools' tool: pgvigil_tools.cr_echo(n) on the PostgreSQL instance (the schema is a DBA's opt-in; dropped at the end)
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create schema if not exists pgvigil_tools" -c "create or replace function pgvigil_tools.cr_echo(n int) returns table (echo int) language sql as \$f\$ select n \$f\$" -c "grant usage on schema pgvigil_tools to $MON" >/dev/null || die "cr_echo"
# CR-timer's PostgreSQL report raises a NOTICE through a function of the run's own (dropped at the end)
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create or replace function public.cr_notice() returns int language plpgsql as \$f\$ begin raise notice 'step two of three'; return 1; end \$f\$" >/dev/null || die "cr_notice"
# CR-upgrade (0372's named check, the lead 11-17 03:15): with PGVIGIL_OLD_SRC (a source tree from before 0372) the store is
# first migrated by that build and a report saved through its own import_custom_report (no view column then); this
# build's migrate below runs 0372 over it, and the report must draw as it did (crview-check's CR-upgrade). Without it
# the case says NOT PROVEN.
UPG=""
if [ -n "${PGVIGIL_OLD_SRC:-}" ]; then
  [ -e "$PGVIGIL_OLD_SRC/internal/repo/sql/0372_custom_report_view.sql" ] && die "PGVIGIL_OLD_SRC already holds 0372: give a tree from before it"
  ( cd "$PGVIGIL_OLD_SRC" && CGO_ENABLED=0 go build -o "$WORK/pgvigil-old" ./cmd/pgvigil ) > "$WORK/old-build.log" 2>&1 || die "the older build: $(tail -3 "$WORK/old-build.log")"
  "$WORK/pgvigil-old" migrate -config "$WORK/pgvigil.yaml" > "$WORK/migrate-old.log" 2>&1 || die "the older build's migrate: $(tail -3 "$WORK/migrate-old.log")"
  UPG=$(psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 -c "select pgvigil.import_custom_report(now(), '{\"op\":\"add\",\"ui_user\":\"cradmin\",\"client\":\"proof\",\"folder\":\"\",\"name\":\"cr-upgrade-$SUF\",\"description\":\"saved before 0372\",\"engine\":\"store\",\"kind\":\"sql\",\"body\":\"SELECT 41 + 1 AS answer\",\"params\":[],\"columns\":[{\"set\":0,\"column\":\"answer\",\"label\":\"The answer\"}],\"rules\":[],\"timeout_secs\":30,\"max_rows\":5000}'::jsonb)::jsonb->>'report_id'") || die "a report saved by the older build"
  [ -n "$UPG" ] || die "the older build's import_custom_report gave no report_id"
  echo "the older build ($PGVIGIL_OLD_SRC) migrated the store and saved report $UPG"
fi
"$BIN" migrate -config "$WORK/pgvigil.yaml" > "$WORK/migrate.log" 2>&1 || die "migrate: $(tail -3 "$WORK/migrate.log")"
"$BIN" demo -config "$WORK/pgvigil.yaml" -days 1 > "$WORK/seed.log" 2>&1 || die "the demo seed: $(tail -3 "$WORK/seed.log")"
for n in "cr-pg-$SUF postgres" "cr-ms-$SUF sqlserver"; do set -- $n
  psql "$PGVIGIL_REPO_DSN" -XAtq -c "select pgvigil.ensure_instance('$1', 'onprem', '16.0', 160000, false, '{}', '$2')" >/dev/null || die "instance $1"
done
PGVIGIL_PASSWORD=$UPW "$BIN" user add -config "$WORK/pgvigil.yaml" cradmin > /dev/null 2>&1 || die "user add (the first: admin)"
PGVIGIL_PASSWORD=$OPW "$BIN" user add -config "$WORK/pgvigil.yaml" -role operator crop > /dev/null 2>&1 || die "user add (operator)"
PORT=$((20000 + RANDOM % 20000)); U="http://127.0.0.1:$PORT/"
"$BIN" serve -config "$WORK/pgvigil.yaml" -listen "127.0.0.1:$PORT" > "$WORK/serve.log" 2>&1 & SRV=$!
for _ in $(seq 1 60); do curl -sf -o /dev/null "$U" && break; kill -0 $SRV 2>/dev/null || die "serve died: $(tail -3 "$WORK/serve.log")"; sleep 0.5; done

# ---- the check
PGVIGIL_CRVIEW_URL=$U PGVIGIL_CRVIEW_DB=$DB PGVIGIL_CRVIEW_ADMIN="cradmin:$UPW" PGVIGIL_CRVIEW_OPERATOR="crop:$OPW" \
  CR_PG_NAME="cr-pg-$SUF" CR_MS_NAME="cr-ms-$SUF" CR_MS_CT="$CT" CR_MS_ENV="$WORK/sa.env" CR_UPGRADE_ID="$UPG" node scripts/crview-check.mjs 2>&1 | tee "$WORK/check.log"
exit "${PIPESTATUS[0]}"
