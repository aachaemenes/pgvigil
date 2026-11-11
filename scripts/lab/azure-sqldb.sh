#!/usr/bin/env bash
# Lab: one Azure SQL Database (a logical server and one serverless database under the subscription's monthly free
# limit) for the cloud proof scripts/proof-mssql-azuresqldb.sh, made and removed from the machine that holds the
# Azure CLI sign-in.
#
#   scripts/lab/azure-sqldb.sh up                  make the server, the database and the state file
#   scripts/lab/azure-sqldb.sh allow <ip> [<ip>]   the server's firewall admits these addresses only
#   scripts/lab/azure-sqldb.sh logins              (where 1433 reaches) the collector's contained user and its right
#   scripts/lab/azure-sqldb.sh status              what this lab holds now, read from Azure
#   scripts/lab/azure-sqldb.sh down                delete everything it made and read the listing back
#
# Settings (environment):
#   PGVIGIL_LAB_PROOF            the proof's tag value: the server and the database carry pgvigil-proof=<value> (required)
#   PGVIGIL_LAB_AZ_SUBSCRIPTION  the subscription id (required for up, allow, status, down)
#   PGVIGIL_LAB_AZ_GROUP         the resource group, which must exist (required for up, allow, status, down)
#   PGVIGIL_LAB_AZ_REGION        the region (required for up)
#   PGVIGIL_LAB_AZ_TIER          free (default): General Purpose serverless Gen5, 1 vCore at most, under the monthly
#                                free limit with AutoPause when it is used up (nothing is billed); basic: the Basic
#                                tier (billed per day; its server-state DMVs need the server admin, not VIEW DATABASE
#                                STATE, so the proof's least-privilege user reads less there)
#   PGVIGIL_LAB_DIR              the state folder, default .lab (git-ignored: add it to .git/info/exclude)
#   PGVIGIL_SQLCMD_IMAGE         the image whose sqlcmd 'logins' runs, default mcr.microsoft.com/mssql/server:2022-latest
#   AZ                           the Azure CLI, default az on the PATH
#
# What up makes, each tagged where Azure tags it: one logical server (TLS 1.2 at least, public network access on,
# NO firewall rule until 'allow', so nothing reaches it) and one database. The firewall is the only door: 'allow'
# deletes every rule the server has and makes one rule per address given (start = end); a range or 0.0.0.0 (which
# would admit every Azure service) is refused. The server admin's password and the collector's are made here from
# /dev/urandom and written only to the mode-600 state file <dir>/azure-sqldb.env; the server goes in through a
# mode-600 request body that is removed right after the call, never on a command line, in the output or a log.
# down deletes the server (its database and firewall rules with it), reads the listing back (the server, and every
# resource of the group that carries the tag) and removes the state file only when nothing is left.
set -euo pipefail
cd "$(dirname "$0")/../.."
DIR=${PGVIGIL_LAB_DIR:-.lab}
STATE=$DIR/azure-sqldb.env
SQLCMD_IMAGE=${PGVIGIL_SQLCMD_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
AZ=${AZ:-az}
TIER=${PGVIGIL_LAB_AZ_TIER:-free}
CMD=${1:-}
fail() { echo "FAIL: $*" >&2; exit 1; }
need_az() {
  : "${PGVIGIL_LAB_PROOF:?the tag value (pgvigil-proof=<value>)}" "${PGVIGIL_LAB_AZ_SUBSCRIPTION:?the subscription id}" "${PGVIGIL_LAB_AZ_GROUP:?the resource group}"
  [[ $PGVIGIL_LAB_PROOF =~ ^[A-Za-z0-9-]{1,40}$ ]] || fail "PGVIGIL_LAB_PROOF is letters, digits and dashes"
  command -v "$AZ" >/dev/null || fail "the Azure CLI ($AZ) is not on this machine"
}
az_() { "$AZ" "$@" --subscription "$PGVIGIL_LAB_AZ_SUBSCRIPTION" --only-show-errors; }
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
load() { [ -r "$STATE" ] || fail "no state file $STATE (run up first)"; # shellcheck disable=SC1090
  . "$STATE"; }
ip_ok() { [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o; for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done
  [ "$1" != 0.0.0.0 ]; }

case $CMD in
up)
  need_az; : "${PGVIGIL_LAB_AZ_REGION:?the region}"
  case $TIER in free|basic) ;; *) fail "PGVIGIL_LAB_AZ_TIER is free or basic" ;; esac
  [ ! -e "$STATE" ] || fail "$STATE exists: this lab is up (status) or was not taken down (down)"
  mkdir -p "$DIR"; chmod 700 "$DIR"
  SUF=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
  ( umask 077; cat > "$STATE" <<EOF
AZ_SERVER=pgv-proof-$SUF
AZ_HOST=pgv-proof-$SUF.database.windows.net
AZ_PORT=1433
AZ_DB=pgvproof
AZ_TIER=$TIER
ADMIN_USER=pgv_admin
ADMIN_PW=$(pw)
MON_USER=pgv_monitor
MON_PW=$(pw)
EOF
  )
  load
  BODY=$(umask 077; mktemp "$DIR/azsrv.XXXXXX.json")
  trap 'rm -f "$BODY"' EXIT
  python3 - "$BODY" <<PY
import json, sys
json.dump({"location": "$PGVIGIL_LAB_AZ_REGION", "tags": {"pgvigil-proof": "$PGVIGIL_LAB_PROOF"},
  "properties": {"administratorLogin": "$ADMIN_USER", "administratorLoginPassword": "$ADMIN_PW", "version": "12.0",
                 "minimalTlsVersion": "1.2", "publicNetworkAccess": "Enabled", "restrictOutboundNetworkAccess": "Disabled"}},
  open(sys.argv[1], "w"))
PY
  URI="https://management.azure.com/subscriptions/$PGVIGIL_LAB_AZ_SUBSCRIPTION/resourceGroups/$PGVIGIL_LAB_AZ_GROUP/providers/Microsoft.Sql/servers/$AZ_SERVER?api-version=2023-08-01"
  "$AZ" rest --method put --uri "$URI" --body "@$BODY" --only-show-errors >/dev/null
  rm -f "$BODY"
  for _ in $(seq 1 60); do
    st=$(az_ sql server show -g "$PGVIGIL_LAB_AZ_GROUP" -n "$AZ_SERVER" --query state -o tsv 2>/dev/null || true)
    [ "$st" = Ready ] && break; sleep 10
  done
  [ "${st:-}" = Ready ] || fail "the server $AZ_SERVER is not Ready after 10 min (state '${st:-none}'); down removes it"
  echo "made: logical server $AZ_SERVER in $PGVIGIL_LAB_AZ_GROUP ($PGVIGIL_LAB_AZ_REGION), tag pgvigil-proof=$PGVIGIL_LAB_PROOF, TLS 1.2+"
  # a server made through the API has no firewall rule; any rule found (another tool's default) is removed
  for r in $(az_ sql server firewall-rule list -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" --query '[].name' -o tsv); do
    az_ sql server firewall-rule delete -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" -n "$r"; echo "removed: firewall rule $r"
  done
  if [ "$TIER" = free ]; then
    az_ sql db create -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" -n "$AZ_DB" -e GeneralPurpose -f Gen5 -c 1 \
      --compute-model Serverless --min-capacity 0.5 --auto-pause-delay 60 --use-free-limit true \
      --free-limit-exhaustion-behavior AutoPause --tags "pgvigil-proof=$PGVIGIL_LAB_PROOF" --query '[name,currentServiceObjectiveName,status]' -o tsv
  else
    az_ sql db create -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" -n "$AZ_DB" --service-objective Basic \
      --backup-storage-redundancy Local --tags "pgvigil-proof=$PGVIGIL_LAB_PROOF" --query '[name,currentServiceObjectiveName,status]' -o tsv
  fi
  echo "made: database $AZ_DB ($TIER), tag pgvigil-proof=$PGVIGIL_LAB_PROOF"
  echo "up: $AZ_HOST,1433 database $AZ_DB (admin and passwords in $STATE, mode 600); no address admitted yet: allow <ip>, then logins"
  ;;
allow)
  need_az; load; shift
  [ $# -ge 1 ] || fail "allow <ip> [<ip> ...]: one address at least"
  for a in "$@"; do ip_ok "$a" || fail "not one IPv4 address: $a (a range or 0.0.0.0 is never admitted)"; done
  for r in $(az_ sql server firewall-rule list -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" --query '[].name' -o tsv); do
    az_ sql server firewall-rule delete -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" -n "$r"
  done
  n=0; for a in "$@"; do n=$((n + 1))
    az_ sql server firewall-rule create -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" -n "pgv-reader-$n" --start-ip-address "$a" --end-ip-address "$a" >/dev/null
  done
  echo "allowed: $AZ_SERVER admits $(az_ sql server firewall-rule list -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" --query '[].[startIpAddress,endIpAddress]' -o tsv | awk '{ printf "%s%s", (NR > 1 ? " " : ""), ($1 == $2 ? $1 : $1 "-" $2) }') only"
  ;;
logins)
  # runs where 1433 reaches (the reading machine). The first connection may wake a paused database (error 40613
  # until it is online, about a minute): it is retried. The password goes to sqlcmd on stdin, never its command line.
  load
  command -v docker >/dev/null || fail "docker is not on this machine (sqlcmd runs from $SQLCMD_IMAGE)"
  export SQLCMDPASSWORD="$ADMIN_PW"
  ok=
  for _ in $(seq 1 12); do
    if docker run --rm -e SQLCMDPASSWORD "$SQLCMD_IMAGE" /opt/mssql-tools18/bin/sqlcmd -S "tcp:$AZ_HOST,$AZ_PORT" -U "$ADMIN_USER" -d "$AZ_DB" -C -b -l 60 -h -1 -W -Q "SET NOCOUNT ON; SELECT 1" >/dev/null 2>&1; then ok=1; break; fi
    sleep 15
  done
  [ -n "$ok" ] || fail "the database did not answer the admin login in 3 minutes (is this machine's address allowed?)"
  docker run --rm -i -e SQLCMDPASSWORD "$SQLCMD_IMAGE" /opt/mssql-tools18/bin/sqlcmd -S "tcp:$AZ_HOST,$AZ_PORT" -U "$ADMIN_USER" -d "$AZ_DB" -C -b -l 60 -h -1 -W -i /dev/stdin <<SQL
SET NOCOUNT ON;
IF USER_ID(N'$MON_USER') IS NULL CREATE USER [$MON_USER] WITH PASSWORD = N'$MON_PW';
ELSE ALTER USER [$MON_USER] WITH PASSWORD = N'$MON_PW';
GRANT VIEW DATABASE STATE TO [$MON_USER];
GO
SELECT 'logins: ' + N'$MON_USER' + ' (contained, ' + authentication_type_desc + ') holds ' +
  ISNULL((SELECT STRING_AGG(permission_name, ', ') WITHIN GROUP (ORDER BY permission_name) FROM sys.database_permissions
          WHERE grantee_principal_id = DATABASE_PRINCIPAL_ID(N'$MON_USER') AND state = 'G'), 'nothing') +
  '; roles: ' + ISNULL((SELECT STRING_AGG(USER_NAME(role_principal_id), ', ') FROM sys.database_role_members
          WHERE member_principal_id = DATABASE_PRINCIPAL_ID(N'$MON_USER')), 'none')
FROM sys.database_principals WHERE name = N'$MON_USER';
SQL
  ;;
status)
  need_az
  echo "tag pgvigil-proof=$PGVIGIL_LAB_PROOF (the whole subscription):"
  az_ resource list --tag "pgvigil-proof=$PGVIGIL_LAB_PROOF" --query '[].[type,name]' -o tsv | sed 's/^/  /'
  if [ -r "$STATE" ]; then load
    az_ sql db show -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" -n "$AZ_DB" --query '[name,status,currentServiceObjectiveName,useFreeLimit]' -o tsv 2>/dev/null | sed 's/^/  database: /' || true
    az_ sql server firewall-rule list -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" --query '[].[name,startIpAddress,endIpAddress]' -o tsv 2>/dev/null | sed 's/^/  firewall: /' || true
  fi
  ;;
down)
  need_az; load
  if az_ sql server show -g "$PGVIGIL_LAB_AZ_GROUP" -n "$AZ_SERVER" >/dev/null 2>&1; then
    az_ sql server delete -g "$PGVIGIL_LAB_AZ_GROUP" -n "$AZ_SERVER" --yes
    echo "deleted: logical server $AZ_SERVER (its database and firewall rules with it)"
  fi
  LEFT_SRV=$(az_ sql server list -g "$PGVIGIL_LAB_AZ_GROUP" --query "length([?name=='$AZ_SERVER'])" -o tsv)
  LEFT_TAG=
  for _ in $(seq 1 12); do
    LEFT_TAG=$(az_ resource list --tag "pgvigil-proof=$PGVIGIL_LAB_PROOF" --query 'length(@)' -o tsv)
    [ "$LEFT_TAG" = 0 ] && break; sleep 10
  done
  echo "read back: servers named $AZ_SERVER $LEFT_SRV, resources tagged pgvigil-proof=$PGVIGIL_LAB_PROOF in the subscription $LEFT_TAG"
  [ "$LEFT_SRV|$LEFT_TAG" = "0|0" ] || fail "something is left (above): the state file $STATE stays"
  rm -f "$STATE"
  echo "down: 0 left"
  ;;
*) sed -n '2,13p' "$0"; exit 2 ;;
esac
