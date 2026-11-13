#!/usr/bin/env bash
# SIMULATED proof of Google Cloud SQL for SQL Server as a platform (CLOUDSQL C2) - a SQL Server 2022 container (on
# Linux, as Cloud SQL's are) that wears Cloud SQL's mark, the server role CustomerDbRootRole, NOT the service:
# the live half (a Cloud SQL instance) is not proven here.
#   A. a login with exactly the documented grants (VIEW SERVER STATE, VIEW ANY DEFINITION, db_datareader in msdb):
#      collect -once stores the instance with platform cloudsqlsqlserver;
#   B. the same grants without VIEW ANY DEFINITION: the role is invisible to the login (sys.server_principals shows
#      nothing), the instance is stored as sqlserver - the configuration's platform: cloudsql names it
#      then (C);
#   C. platform: cloudsql on B's login: cloudsqlsqlserver;
#   D. every collection on A's instance ends as it ends on the same server and login with platform: onprem (one
#      collection_dates status per collection, the two lists equal): the Cloud SQL kind's rules change no collection's
#      outcome on a server whose login is a SQL login.
# Needs docker (pulls mcr.microsoft.com/mssql/server:2022-latest), go, psql, a PostgreSQL superuser DSN without a
# dbname in PGVIGIL_ADMIN_DSN (default host=127.0.0.1 port=5432 user=postgres). The store is a database this run
# makes and drops.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${PGVIGIL_ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres}
ADMIN_DSN=$(sed -E 's/(^| )dbname=[^ ]*//' <<<"$ADMIN_DSN")
IMG_SQL=mcr.microsoft.com/mssql/server:2022-latest
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvgcs-sql-$SUF; REPO_DB=pgv_gcs_$SUF; L1=pgv_gcs1_$SUF; L0=pgv_gcs0_$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); MADE_DB=
SA_PW=$(pw); P1=$(pw); P0=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  docker rm -f -v "$SQL" >/dev/null 2>&1 || true
  [[ -n "$MADE_DB" ]] && { psql "$ADMIN_DSN dbname=postgres" -XAtqc "DROP DATABASE IF EXISTS $REPO_DB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: $REPO_DB not dropped" >&2; }
  rm -rf "$TMPD"
}
trap cleanup EXIT
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -W -h -1 -s "|" -d "$0" -i /dev/stdin' "${2:-master}"; }
docker run -d --name "$SQL" --label pgvigil-proof=c2 --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
up=0
for _ in $(seq 1 90); do
  [[ "$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" 2>/dev/null | tr -d '\r ' || true)" == 1 ]] && { up=1; break; }
  sleep 2
done
[[ $up == 1 ]] || fail "the SQL Server container did not come up"
PORT=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')

echo "== the simulation (sa): Cloud SQL's role on a SQL Server 2022 container on Linux"
sq "CREATE SERVER ROLE [CustomerDbRootRole];"
sq "CREATE LOGIN [$L1] WITH PASSWORD = '$P1', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1];
    CREATE LOGIN [$L0] WITH PASSWORD = '$P0', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$L0];"
sq "CREATE USER [$L1] FOR LOGIN [$L1]; ALTER ROLE db_datareader ADD MEMBER [$L1]; CREATE USER [$L0] FOR LOGIN [$L0]; ALTER ROLE db_datareader ADD MEMBER [$L0];" msdb
seen() { # whether a login sees the role
  printf 'SET NOCOUNT ON; SELECT count(*) FROM sys.server_principals WHERE name = N'"'"'CustomerDbRootRole'"'"' AND type = '"'"'R'"'"';\n' |
    docker exec -i -e "SQLCMDPASSWORD=$2" "$SQL" "$SQLCMD" -S localhost -U "$1" -C -b -W -h -1 -i /dev/stdin | tr -d '\r '
}
S1=$(seen "$L1" "$P1"); S0=$(seen "$L0" "$P0")
echo "   the role as each login sees it: with VIEW ANY DEFINITION $S1, without it $S0"
[[ "$S1" == "1" && "$S0" == "0" ]] || fail "the role's visibility: want 1 with VIEW ANY DEFINITION and 0 without, got $S1 and $S0"

psql "$ADMIN_DSN dbname=postgres" -XAtqc "CREATE DATABASE $REPO_DB" >/dev/null; MADE_DB=1
go build -o "$TMPD/pgvigil" ./cmd/pgvigil
enc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
export GCS_L1="sqlserver://$L1:$(enc "$P1")@127.0.0.1:$PORT?database=master&encrypt=true&TrustServerCertificate=true"
export GCS_L0="sqlserver://$L0:$(enc "$P0")@127.0.0.1:$PORT?database=master&encrypt=true&TrustServerCertificate=true"
cat > "$TMPD/cfg.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: gcs-a
    engine: sqlserver
    dsn: env:GCS_L1
  - name: gcs-b
    engine: sqlserver
    dsn: env:GCS_L0
  - name: gcs-c
    engine: sqlserver
    platform: cloudsql
    dsn: env:GCS_L0
  - name: gcs-onprem
    engine: sqlserver
    platform: onprem
    dsn: env:GCS_L1
EOF
"$TMPD/pgvigil" migrate -config "$TMPD/cfg.yaml" >/dev/null
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
# -once runs one collection: the SQL Server collections are the ones the binary names (its 'known:' list)
COLLS=$("$TMPD/pgvigil" collect -config "$TMPD/cfg.yaml" -once no_such_collection 2>&1 | grep -o 'known: \[[^]]*\]' | tr -d '[]' | tr ' ' '\n' | grep '^mssql_' || true)
[[ $(grep -c . <<<"$COLLS") -ge 25 ]] || fail "the SQL Server collections were not listed: $COLLS"
once() { "$TMPD/pgvigil" collect -config "$TMPD/cfg.yaml" -once "$2" -instance "$1" >> "$TMPD/$1.out" 2>&1 || true; }
for c in $COLLS; do once gcs-a "$c"; once gcs-onprem "$c"; done
once gcs-b mssql_instance; once gcs-c mssql_instance
plat() { q "SELECT platform FROM pgvigil.instances WHERE name = '$1'"; }
[[ "$(plat gcs-a)" == cloudsqlsqlserver ]] && echo "ok   A: the documented grants: stored as cloudsqlsqlserver" || fail "A: gcs-a stored as '$(plat gcs-a)'"
[[ "$(plat gcs-b)" == sqlserver ]] && echo "ok   B: without VIEW ANY DEFINITION the marks are invisible: stored as sqlserver" || fail "B: gcs-b stored as '$(plat gcs-b)'"
[[ "$(plat gcs-c)" == cloudsqlsqlserver ]] && echo "ok   C: platform: cloudsql names it on B's login: cloudsqlsqlserver" || fail "C: gcs-c stored as '$(plat gcs-c)'"
outcomes() { q "SELECT d.collection || ' ' || d.status FROM pgvigil.collection_dates d JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$1' ORDER BY 1"; }
outcomes gcs-a > "$TMPD/a.txt"; outcomes gcs-onprem > "$TMPD/o.txt"
NA=$(grep -c . "$TMPD/a.txt" || true)
[[ "$NA" -ge 25 ]] || fail "D: gcs-a has $NA collection outcomes (a whole run was expected)"
if diff "$TMPD/o.txt" "$TMPD/a.txt" > "$TMPD/d.txt"; then
  echo "ok   D: $NA collections, each ending as on the same server with platform: onprem ($(grep -c ' ok$' "$TMPD/a.txt" || true) ok, $(grep -c ' skipped$' "$TMPD/a.txt" || true) skipped, $(grep -c ' error$' "$TMPD/a.txt" || true) error)"
else
  cat "$TMPD/d.txt"; fail "D: the outcomes differ from platform: onprem's"
fi
grep ' error$' "$TMPD/a.txt" | sed 's/^/   error on both: /' || true
echo "proof-cloudsql-sim: OK (SIMULATED: Cloud SQL's role on a SQL Server 2022 container on Linux; a Cloud SQL instance NOT PROVEN)"
