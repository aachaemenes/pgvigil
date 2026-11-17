#!/usr/bin/env bash
# Proof of Pool history (P25 task 9b: mssql_pool_limits, migration 0395) against a live elastic pool: the lab of
# scripts/lab/azure-sqldb.sh with PGVIGIL_LAB_AZ_TIER=pool (up; allow <this machine>; logins). Runs on the machine
# that holds the lab's state file and the Azure CLI's sign-in: every Azure call and every connection is made from here.
#
# Needs: psql, docker (sqlcmd from the lab's image, as the lab's 'logins' runs it), jq, the Azure CLI, and
#   PGVIGIL_ADMIN_DSN   a superuser connection to a PostgreSQL in KEYWORD form, no dbname (the store is made there)
#   PGVIGIL_LAB_STATE   the lab's state file, default .lab/azure-sqldb.env (its passwords reach sqlcmd on its
#                       environment and pgvigil through the environment by name; none is printed)
#   PGVIGIL_BIN         a pgvigil binary of this tree (default: built here with go)
#   PGVIGIL_LAB_AZ_SUBSCRIPTION, PGVIGIL_LAB_AZ_GROUP   the lab's (the pool's rescale and its read back)
#
# What it makes, and takes away on every exit path the shell can catch: a store database pgvigil_plproof_<n>; in the
# logical server's master, a user for the login pgv_pool, its dbmanager membership, and for one reading its
# ##MS_DatabaseManager## membership - each removed and read back before the script ends (the lab's 'down' then deletes
# the server). It rescales the lab's pool from 50 to 100 eDTU once (Basic; the lab's down deletes it).
#
# Expected (written before the first run):
#  L0 pgv_pool as the lab makes it (a login in master with ##MS_ServerStateReader##, a user in each pooled database, no
#     user in master, no ##MS_DatabaseConnector##): `collect -once mssql_pool_limits` on the first pooled database ends
#     skipped, its note "could not sign in to the logical server's master" (Microsoft's server-roles page: a login needs
#     ##MS_DatabaseConnector## or a user in a database, master too) [inferred]
#  L1 a user for pgv_pool in master, no dbmanager: skipped, "not a member of dbmanager"
#  L2 dbmanager given (read back in sys.database_role_members): as pgv_pool in master IS_ROLEMEMBER('dbmanager') = 1
#     within 6 minutes (Microsoft: a role change can take 5 minutes); the run ends ok, mssql_pool_limit_read state
#     read, at least one period of the pool stored, the newest with DTU limit 50 and storage limit 5120 MB (a Basic
#     50 eDTU pool's default maximum data size, 5 GB) [inferred]
#  L3 the pool rescaled to 100 eDTU (az read back: capacity 100); master's view shows elastic_pool_dtu_limit 100 within
#     20 minutes; the run then stores the change: the pool's newest two periods 50 then 100, one change 50 -> 100
#  L4 the second reading (the lead's Q1): dbmanager taken away, ##MS_DatabaseManager## given - whether pgv_pool's own
#     SELECT on the view reads it or is refused (the error's number) is recorded within 6 minutes; either answer is a
#     reading, not a FAIL; the server role taken away again and read back
#  L5 the grant removed: no user for pgv_pool in master, in no master role, its server roles ##MS_ServerStateReader##
#     alone (read back); the store database dropped
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?a superuser connection in keyword form, no dbname}"
: "${PGVIGIL_LAB_AZ_SUBSCRIPTION:?the lab's subscription}"; : "${PGVIGIL_LAB_AZ_GROUP:?the lab's resource group}"
STATE=${PGVIGIL_LAB_STATE:-.lab/azure-sqldb.env}
SQLCMD_IMAGE=${PGVIGIL_SQLCMD_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
AZ=${AZ:-az}
fail() { echo "FAIL: $*" >&2; exit 1; }
for t in psql docker jq "$AZ"; do command -v "$t" >/dev/null || fail "$t is not on this machine"; done
[ -r "$STATE" ] || fail "no lab state file $STATE (scripts/lab/azure-sqldb.sh up with PGVIGIL_LAB_AZ_TIER=pool)"
# shellcheck disable=SC1090
. "$STATE"
[ "${AZ_TIER:-}" = pool ] || fail "$STATE is not the pool tier's"
umask 077
WORK=$(mktemp -d); N=$RANDOM; STORE="pgvigil_plproof_$N"
# sqlcmd as a login, its password on its environment (never the command line): sqa <user> <password> <database>
sqa() { SQLCMDPASSWORD=$2 docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$SQLCMD_IMAGE" \
  -S "tcp:$AZ_HOST,$AZ_PORT" -U "$1" -d "$3" -C -b -l 60 -h -1 -W -i /dev/stdin; }
adm() { sqa "$ADMIN_USER" "$ADMIN_PW" master; }
# the grant's removal, read back: run at the end and on every exit (a statement whose object is gone does nothing)
ungrant() {
  adm <<SQL
SET NOCOUNT ON;
IF IS_ROLEMEMBER(N'dbmanager', N'$POOL_USER') = 1 ALTER ROLE dbmanager DROP MEMBER [$POOL_USER];
IF EXISTS (SELECT 1 FROM sys.server_role_members m JOIN sys.server_principals r ON r.principal_id = m.role_principal_id
            JOIN sys.server_principals p ON p.principal_id = m.member_principal_id
           WHERE r.name = N'##MS_DatabaseManager##' AND p.name = N'$POOL_USER') ALTER SERVER ROLE ##MS_DatabaseManager## DROP MEMBER [$POOL_USER];
IF USER_ID(N'$POOL_USER') IS NOT NULL DROP USER [$POOL_USER];
GO
SELECT 'read back: user in master ' + CASE WHEN USER_ID(N'$POOL_USER') IS NULL THEN 'none' ELSE 'PRESENT' END
  + '; server roles ' + ISNULL((SELECT STRING_AGG(r.name, ', ') WITHIN GROUP (ORDER BY r.name) FROM sys.server_role_members m
      JOIN sys.server_principals r ON r.principal_id = m.role_principal_id JOIN sys.server_principals p ON p.principal_id = m.member_principal_id
     WHERE p.name = N'$POOL_USER'), 'none');
SQL
}
cleanup() {
  ungrant > "$WORK/ungrant.out" 2>&1 || true
  echo "cleanup: $(grep 'read back' "$WORK/ungrant.out" || echo 'the removal did not answer: read master by hand')"
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $STORE with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
VERDICT=PASS
ok() { echo "ok   $1"; }
bad() { VERDICT=FAIL; echo "FAIL $1"; }

if [ -n "${PGVIGIL_BIN:-}" ]; then BIN=$PGVIGIL_BIN; else CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil; BIN=$WORK/pgvigil; fi
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $STORE" >/dev/null
export PGV_PL1_DSN; PGV_PL1_DSN=$(printf 'sqlserver://%s:%s@%s:%s?database=%s&encrypt=true' "$POOL_USER" "$POOL_PW" "$AZ_HOST" "$AZ_PORT" "$AZ_DB")
cat > "$WORK/pgvigil.yaml" <<EOF
repository:
  dsn: "$PGVIGIL_ADMIN_DSN dbname=$STORE"
instances:
  - name: pl1
    engine: sqlserver
    dsn: env:PGV_PL1_DSN
    tags: [pool:$AZ_POOL]
EOF
"$BIN" migrate -config "$WORK/pgvigil.yaml" 2>&1 | tail -1
q() { psql "$PGVIGIL_ADMIN_DSN dbname=$STORE" -XAtq -F '|' -c "$1"; }
run() { "$BIN" collect -config "$WORK/pgvigil.yaml" -once mssql_pool_limits -instance pl1 > "$WORK/run.out" 2>&1 || true
  q "select c.status, c.note from pgvigil.collection_dates c join pgvigil.instances i using (instance_id) where i.name = 'pl1' and c.collection = 'mssql_pool_limits'"; }
periods() { q "select h.valid_from, h.valid_to, h.dtu_limit, h.storage_limit_mb from pgvigil.mssql_pool_limit_history h join pgvigil.instances i using (instance_id)
                where i.name = 'pl1' and h.pool = '$AZ_POOL' order by h.valid_from"; }
# the right as pgv_pool sees it in master, on a new connection each time, until want or the minutes run out
right_is() { local want=$1 mins=$2 got=; for _ in $(seq 1 $((mins * 2))); do
    got=$(printf "SET NOCOUNT ON; SELECT CAST(ISNULL(IS_ROLEMEMBER('dbmanager'), 0) AS int);\n" | sqa "$POOL_USER" "$POOL_PW" master 2>/dev/null | tr -d '[:space:]') || got=
    [ "$got" = "$want" ] && { echo "$got"; return 0; }; sleep 30; done; echo "${got:-no answer}"; return 1; }

"$BIN" collect -config "$WORK/pgvigil.yaml" -once mssql_instance -instance pl1 > "$WORK/inst.out" 2>&1 || true
echo "== L0: pgv_pool as the lab makes it"
L0=$(run); echo "   $L0"
[[ "$L0" == "skipped|"*"could not sign in to the logical server's master"* ]] && ok L0 || bad "L0 (expected the no-master skip)"

echo "== L1: a user for pgv_pool in master, no dbmanager"
printf "SET NOCOUNT ON;\nIF USER_ID(N'%s') IS NULL CREATE USER [%s] FROM LOGIN [%s];\n" "$POOL_USER" "$POOL_USER" "$POOL_USER" | adm
L1=$(run); echo "   $L1"
[[ "$L1" == "skipped|"*"not a member of dbmanager"* ]] && ok L1 || bad "L1 (expected the no-dbmanager skip)"

echo "== L2: dbmanager given"
printf "SET NOCOUNT ON;\nALTER ROLE dbmanager ADD MEMBER [%s];\nSELECT 'read back: ' + CAST(IS_ROLEMEMBER(N'dbmanager', N'%s') AS varchar(2));\n" "$POOL_USER" "$POOL_USER" | adm
echo "   as pgv_pool in master: IS_ROLEMEMBER('dbmanager') = $(right_is 1 6 || true)"
L2=$(run); echo "   $L2"; P2=$(periods); echo "$P2" | sed 's/^/   period /'
R2=$(q "select r.state from pgvigil.mssql_pool_limit_read r join pgvigil.instances i using (instance_id) where i.name = 'pl1'")
[[ "$L2" == "ok|"* ]] && [ "$R2" = read ] && [[ "$(echo "$P2" | tail -1)" == *"|50|5120" ]] && ok L2 || bad "L2 (expected ok, state read, the newest period 50 DTU / 5120 MB)"

echo "== L3: the pool rescaled to 100 eDTU"
"$AZ" sql elastic-pool update --subscription "$PGVIGIL_LAB_AZ_SUBSCRIPTION" -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" -n "$AZ_POOL" --capacity 100 -o none
CAP=$("$AZ" sql elastic-pool show --subscription "$PGVIGIL_LAB_AZ_SUBSCRIPTION" -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" -n "$AZ_POOL" --query capacity -o tsv)
echo "   az read back: capacity $CAP"
seen=; for _ in $(seq 1 40); do
  seen=$(printf "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.elastic_pool_resource_stats WHERE elastic_pool_name = N'%s' AND elastic_pool_dtu_limit = 100;\n" "$AZ_POOL" | adm | tr -d '[:space:]')
  [ "${seen:-0}" -gt 0 ] && break; sleep 30; done
echo "   master's rows at 100 DTU: ${seen:-none}"
L3=$(run); echo "   $L3"; P3=$(periods); echo "$P3" | sed 's/^/   period /'
[ "$CAP" = 100 ] && [[ "$L3" == "ok|"* ]] && [[ "$(echo "$P3" | tail -2 | cut -d'|' -f3 | tr '\n' ' ')" == "50 100 " ]] && ok L3 || bad "L3 (expected the newest two periods 50 then 100)"

echo "== L4: the second reading - ##MS_DatabaseManager## in place of dbmanager"
printf "SET NOCOUNT ON;\nALTER ROLE dbmanager DROP MEMBER [%s];\nALTER SERVER ROLE ##MS_DatabaseManager## ADD MEMBER [%s];\n" "$POOL_USER" "$POOL_USER" | adm
right_is 0 6 >/dev/null || true
L4=; for _ in $(seq 1 12); do
  L4=$(printf "SET NOCOUNT ON; SELECT 'reads: ' + CAST(COUNT(*) AS varchar(12)) FROM sys.elastic_pool_resource_stats WHERE elastic_pool_name = N'%s';\n" "$AZ_POOL" \
       | sqa "$POOL_USER" "$POOL_PW" master 2>&1 | tr '\n' ' ' | cut -c1-240) || true
  [[ "$L4" == "reads: "* ]] && break; sleep 30; done
echo "   READING L4 (##MS_DatabaseManager## alone): ${L4:-no answer}"
printf "SET NOCOUNT ON;\nALTER SERVER ROLE ##MS_DatabaseManager## DROP MEMBER [%s];\n" "$POOL_USER" | adm

echo "== L5: the grant removed"
ungrant | tee "$WORK/l5.out" | sed 's/^/   /'
grep -q "read back: user in master none; server roles ##MS_ServerStateReader##$" "$WORK/l5.out" && ok L5 || bad "L5 (expected no user in master and ##MS_ServerStateReader## alone)"
echo "VERDICT: $VERDICT"
[ "$VERDICT" = PASS ]
