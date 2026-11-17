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
#   PGVIGIL_PROOF_OUT    a folder for the logs (default: removed with the work folder)
# Needs docker, psql, curl, node 22+ and chromium. The sa password and the users' passwords go through environment
# variables and an env file, never a command line. The last line is crview-check.mjs's 'crview-check: <n> FAIL'.
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
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" -c "drop role if exists $MON" >/dev/null 2>&1
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
  CR_PG_NAME="cr-pg-$SUF" CR_MS_NAME="cr-ms-$SUF" node scripts/crview-check.mjs 2>&1 | tee "$WORK/check.log"
exit "${PIPESTATUS[0]}"
