#!/usr/bin/env bash
# Lab: one Azure SQL Managed Instance on Microsoft's free offer (General Purpose, Gen5, 4 vCores, 64 GB; one per
# subscription; no charge while inside the offer) for the live proof scripts/proof-mssql-mi.sh, made and removed from
# the machine that holds the Azure CLI sign-in.
#
#   scripts/lab/azure-mi.sh up              the network and the instance (it takes a long while), the stop schedule removed
#   scripts/lab/azure-mi.sh allow <ip>      the public endpoint (port 3342) admits this address only
#   scripts/lab/azure-mi.sh logins          the monitor login of docs/sqlserver-cloud.md's Managed Instance section and a
#                                           user database the proof reads (where 3342 reaches: this machine)
#   scripts/lab/azure-mi.sh status          what this lab holds now, read from Azure
#   scripts/lab/azure-mi.sh down            the instance, then - once its virtual cluster is gone - the network; read back
#
# Settings (environment):
#   PGVIGIL_LAB_PROOF            the proof's tag value: everything made carries pgvigil-proof=<value> (required)
#   PGVIGIL_LAB_AZ_SUBSCRIPTION  the subscription id (required)
#   PGVIGIL_LAB_AZ_GROUP         the resource group, which must exist (required)
#   PGVIGIL_LAB_AZ_REGION        the region (required for up)
#   PGVIGIL_LAB_DIR              the state folder, default .lab (up writes a .gitignore of '*' into it)
#   PGVIGIL_SQLCMD_IMAGE         the image whose sqlcmd 'logins' runs, default mcr.microsoft.com/mssql/server:2022-latest
#   AZ                           the Azure CLI, default az on the PATH
#
# What up makes, each named pgv-mi-<suf>* and tagged: a virtual network (10.0.0.0/16) with one subnet (10.0.0.0/24)
# delegated to Microsoft.Sql/managedInstances, a network security group and a route table on that subnet - both made
# EMPTY: Microsoft's service-aided subnet configuration adds the rules and routes the instance needs (its network
# intent policy); this script adds no inbound rule until 'allow' (port 3342 from one address) - and the instance
# (free offer, public data endpoint on, a system-assigned identity, TLS 1.2). Its stop / start schedule (on by
# default: 9 a.m. to 5 p.m. on weekdays) is deleted right after the create and read back gone, and a stopped instance
# is started. The admin's password and the monitor's are made here from /dev/urandom and written only to the mode-600
# state file <dir>/azure-mi.env; the admin's reaches az through a mode-600 file (az's @file form), removed right
# after, never a command line. down deletes the instance, waits for its virtual cluster to be removed (Microsoft: up to
# 1.5 hours after the last instance), deletes the VNet, the NSG and the route table, and reads back by name and tag; the
# state file goes only when nothing is left.
set -euo pipefail
cd "$(dirname "$0")/../.."
DIR=${PGVIGIL_LAB_DIR:-.lab}
STATE=$DIR/azure-mi.env
SQLCMD_IMAGE=${PGVIGIL_SQLCMD_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
AZ=${AZ:-az}
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
  . "$STATE"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git check-ignore -q "$STATE" || fail "$STATE is not git-ignored (it holds passwords)"; fi
  [ "$PGVIGIL_LAB_AZ_SUBSCRIPTION" = "${LAB_SUBSCRIPTION:-}" ] || fail "the state file was made with another subscription"
  [ "$PGVIGIL_LAB_AZ_GROUP" = "${LAB_GROUP:-}" ] || fail "the state file was made with group '${LAB_GROUP:-}'"
  [ "$PGVIGIL_LAB_PROOF" = "${LAB_PROOF:-}" ] || fail "the state file was made with tag '${LAB_PROOF:-}'"; }
ip_ok() { local oct='(0|[1-9][0-9]?|1[0-9]{2}|2[0-4][0-9]|25[0-5])'
  [[ $1 =~ ^$oct\.$oct\.$oct\.$oct$ ]] && [ "$1" != 0.0.0.0 ]; }
g() { echo "$PGVIGIL_LAB_AZ_GROUP"; }
TAG() { echo "pgvigil-proof=$PGVIGIL_LAB_PROOF"; }

case $CMD in
up)
  need_az; : "${PGVIGIL_LAB_AZ_REGION:?the region}"
  [ ! -e "$STATE" ] || fail "$STATE exists: this lab is up (status) or was not taken down (down)"
  # one free-offer instance per subscription (Microsoft): an existing one (any group) is refused here, not at the create
  FREE=$(az_ sql mi list --query "length([?pricingModel=='Freemium'])" -o tsv) || fail "the subscription's managed instances were not read"
  [ "$FREE" = 0 ] || fail "the subscription holds a free-offer managed instance already ($FREE): one per subscription"
  mkdir -p "$DIR"; chmod 700 "$DIR"; printf '*\n' > "$DIR/.gitignore"
  SUF=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
  ( umask 077; cat > "$STATE" <<EOF
LAB_SUBSCRIPTION=$PGVIGIL_LAB_AZ_SUBSCRIPTION
LAB_GROUP=$PGVIGIL_LAB_AZ_GROUP
LAB_PROOF=$PGVIGIL_LAB_PROOF
LAB_REGION=$PGVIGIL_LAB_AZ_REGION
MI_NAME=pgv-mi-$SUF
MI_VNET=pgv-mi-$SUF-vnet
MI_SUBNET=mi
MI_NSG=pgv-mi-$SUF-nsg
MI_RT=pgv-mi-$SUF-rt
MI_PORT=3342
MI_DB=pgvproof
ADMIN_USER=pgv_admin
ADMIN_PW=$(pw)
MON_USER=pgv_monitor
MON_PW=$(pw)
EOF
  )
  load
  az_ network vnet create -g "$(g)" -n "$MI_VNET" -l "$LAB_REGION" --address-prefixes 10.0.0.0/16 --tags "$(TAG)" -o none
  echo "made: virtual network $MI_VNET (10.0.0.0/16), tag $(TAG) (undo: down)"
  az_ network nsg create -g "$(g)" -n "$MI_NSG" -l "$LAB_REGION" --tags "$(TAG)" -o none
  echo "made: network security group $MI_NSG (no rule of this script's; the service adds its own)"
  az_ network route-table create -g "$(g)" -n "$MI_RT" -l "$LAB_REGION" --tags "$(TAG)" -o none
  echo "made: route table $MI_RT (empty; the service adds its routes)"
  az_ network vnet subnet create -g "$(g)" --vnet-name "$MI_VNET" -n "$MI_SUBNET" --address-prefixes 10.0.0.0/24 \
    --delegations Microsoft.Sql/managedInstances --network-security-group "$MI_NSG" --route-table "$MI_RT" -o none
  echo "made: subnet $MI_SUBNET (10.0.0.0/24) delegated to Microsoft.Sql/managedInstances, with $MI_NSG and $MI_RT"
  PWF=$(umask 077; mktemp "$DIR/mi-p.XXXXXX"); trap 'rm -f "$PWF"' EXIT
  printf '%s' "$ADMIN_PW" > "$PWF"
  az_ sql mi create -g "$(g)" -n "$MI_NAME" -l "$LAB_REGION" --vnet-name "$MI_VNET" --subnet "$MI_SUBNET" \
    --admin-user "$ADMIN_USER" --admin-password "@$PWF" --pricing-model Freemium --tier GeneralPurpose --family Gen5 \
    --capacity 4 --storage 64 --gpv2 true --public-data-endpoint-enabled true --assign-identity --minimal-tls-version 1.2 \
    --backup-storage-redundancy Local --tags "$(TAG)" --no-wait -o none
  rm -f "$PWF"
  echo "accepted: managed instance $MI_NAME (free offer, GP Gen5 4 vCores, 64 GB) - waiting until it is Ready (Microsoft: 'a while'; checked every minute, 6 h at most)"
  st=
  for _ in $(seq 1 360); do
    st=$(az_ sql mi show -g "$(g)" -n "$MI_NAME" --query state -o tsv 2>/dev/null || true)
    case $st in Ready) break ;; Failed|Canceled) fail "the create of $MI_NAME ended '$st' (down removes what was made)" ;; esac
    sleep 60
  done
  [ "$st" = Ready ] || fail "$MI_NAME is not Ready after 6 h (state '${st:-none}'); down removes it"
  read -r MI_FQDN MI_ZONE MI_PRINCIPAL < <(az_ sql mi show -g "$(g)" -n "$MI_NAME" --query '[[fullyQualifiedDomainName, dnsZone, identity.principalId]]' -o tsv)
  [ -n "${MI_FQDN:-}" ] && [ -n "${MI_ZONE:-}" ] || fail "the instance's host name was not read back"
  # the public endpoint's host: <name>.public.<dnszone>.database.windows.net, port 3342 (Microsoft's public-endpoint page)
  MI_PUBLIC=${MI_FQDN/.$MI_ZONE./.public.$MI_ZONE.}
  ( umask 077; printf 'MI_FQDN=%s\nMI_PUBLIC=%s\nMI_PRINCIPAL=%s\n' "$MI_FQDN" "$MI_PUBLIC" "${MI_PRINCIPAL:-}" >> "$STATE" )
  echo "made: managed instance $MI_NAME ($MI_FQDN; public endpoint $MI_PUBLIC,3342; system-assigned identity ${MI_PRINCIPAL:-none read}), tag $(TAG)"
  # the free offer's stop / start schedule (on by default, weekdays 9-5): deleted, read back, and a stopped instance started
  az_ sql mi start-stop-schedule delete --mi "$MI_NAME" -g "$(g)" --yes -o none 2>/dev/null || true
  N=$(az_ sql mi start-stop-schedule list --mi "$MI_NAME" -g "$(g)" --query 'length(@)' -o tsv) || fail "the stop schedule was not read back"
  [ "$N" = 0 ] || fail "$MI_NAME keeps a stop schedule ($N): the proof could be cut by it"
  echo "removed: $MI_NAME's stop / start schedule (read back: none)"
  if [ "$(az_ sql mi show -g "$(g)" -n "$MI_NAME" --query state -o tsv)" = Stopped ]; then
    az_ sql mi start -g "$(g)" --mi "$MI_NAME" -o none; echo "started: $MI_NAME (the schedule had stopped it)"
  fi
  echo "up: $MI_PUBLIC,3342 (the admin's and the monitor's passwords in $STATE, mode 600); no address admitted yet: allow <ip>, then logins"
  ;;
allow)
  need_az; load; shift
  [ $# -eq 1 ] && ip_ok "$1" || fail "allow <ip>: one IPv4 address"
  az_ network nsg rule delete -g "$(g)" --nsg-name "$MI_NSG" -n pgv-public-3342 -o none 2>/dev/null || true
  az_ network nsg rule create -g "$(g)" --nsg-name "$MI_NSG" -n pgv-public-3342 --priority 1300 --direction Inbound --access Allow \
    --protocol Tcp --source-address-prefixes "$1/32" --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 3342 -o none
  GOT=$(az_ network nsg rule show -g "$(g)" --nsg-name "$MI_NSG" -n pgv-public-3342 --query '[[sourceAddressPrefix, destinationPortRange, access, direction]]' -o tsv)
  [ "$GOT" = "$(printf '%s/32\t3342\tAllow\tInbound' "$1")" ] || fail "the 3342 rule reads '$GOT', not $1/32 alone"
  echo "allowed: $MI_NAME's public endpoint (3342) admits $1/32 only (undo: goes with the NSG)"
  ;;
logins)
  load
  command -v docker >/dev/null || fail "docker is not on this machine (sqlcmd runs from $SQLCMD_IMAGE)"
  export SQLCMDPASSWORD="$ADMIN_PW"
  sq() { docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$SQLCMD_IMAGE" -S "tcp:$MI_PUBLIC,$MI_PORT" -U "$ADMIN_USER" -d "$1" -C -b -l 60 -h -1 -W -i /dev/stdin; }
  ok=; for _ in $(seq 1 12); do if echo "SELECT 1" | sq master >/dev/null 2>&1; then ok=1; break; fi; sleep 15; done
  [ -n "$ok" ] || fail "the instance did not answer the admin login on 3342 in 3 minutes (is this machine's address allowed?)"
  # the login of docs/sqlserver-cloud.md's Managed Instance section, and a user database for the backups row (M2)
  sq master <<SQL
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'$MON_USER') CREATE LOGIN [$MON_USER] WITH PASSWORD = N'$MON_PW';
ELSE ALTER LOGIN [$MON_USER] WITH PASSWORD = N'$MON_PW';
GRANT VIEW SERVER STATE TO [$MON_USER];
GRANT VIEW ANY DEFINITION TO [$MON_USER];
IF DB_ID(N'$MI_DB') IS NULL CREATE DATABASE [$MI_DB];
GO
USE msdb;
IF USER_ID(N'$MON_USER') IS NULL CREATE USER [$MON_USER] FOR LOGIN [$MON_USER];
ALTER ROLE db_datareader ADD MEMBER [$MON_USER];
GO
SELECT 'logins: ' + p.name + ' holds ' + ISNULL((SELECT STRING_AGG(CAST(sp.permission_name AS nvarchar(128)) COLLATE DATABASE_DEFAULT, ', ')
         FROM sys.server_permissions sp WHERE sp.grantee_principal_id = p.principal_id AND sp.state = 'G'), 'nothing')
       + '; msdb db_datareader ' + CAST(ISNULL((SELECT 1 FROM msdb.sys.database_role_members m JOIN msdb.sys.database_principals u ON u.principal_id = m.member_principal_id
         JOIN msdb.sys.database_principals r ON r.principal_id = m.role_principal_id WHERE u.name = p.name AND r.name = N'db_datareader'), 0) AS varchar(1))
       + '; database $MI_DB ' + ISNULL((SELECT CAST(state_desc AS nvarchar(60)) COLLATE DATABASE_DEFAULT FROM sys.databases WHERE name = N'$MI_DB'), 'missing')
FROM sys.server_principals p WHERE p.name = N'$MON_USER';
SQL
  ;;
status)
  need_az
  echo "tag $(TAG) (the whole subscription):"
  az_ resource list --tag "$(TAG)" --query '[].[type,resourceGroup,name]' -o tsv | sed 's/^/  /'
  if [ -r "$STATE" ]; then load
    az_ sql mi show -g "$(g)" -n "$MI_NAME" --query '[[name,state,pricingModel,publicDataEndpointEnabled]]' -o tsv 2>/dev/null | sed 's/^/  instance: /' || true
    az_ sql virtual-cluster list -g "$(g)" --query '[].name' -o tsv | sed 's/^/  virtual cluster: /'
  fi
  ;;
down)
  need_az; load
  # only 'not found' means absent: any other failed read stops with nothing deleted and the state file kept
  if OUT=$(az_ sql mi show -g "$(g)" -n "$MI_NAME" --query name -o tsv 2>&1); then
    echo "deleting: managed instance $MI_NAME (Microsoft: a long operation)"
    az_ sql mi delete -g "$(g)" -n "$MI_NAME" --yes -o none
    echo "deleted: managed instance $MI_NAME"
  elif ! grep -qiE 'ResourceNotFound|was not found|could not be found' <<<"$OUT"; then
    fail "the instance $MI_NAME was not read ($OUT): nothing deleted, the state file $STATE stays"
  fi
  L=$(az_ sql mi list -g "$(g)" --query "length([?name=='$MI_NAME'])" -o tsv) || fail "the instance read-back failed: the state file stays"
  [ "$L" = 0 ] || fail "the instance $MI_NAME is still listed: the state file stays"
  echo "read back: managed instances named $MI_NAME 0"
  # the virtual cluster goes by itself once its last instance is deleted (Microsoft: up to 1.5 hours); the subnet, and
  # with it the VNet, can be deleted only then - waited for here, 3 h at most
  VC=
  for _ in $(seq 1 180); do
    VC=$(az_ sql virtual-cluster list -g "$(g)" --query "length([?contains(to_string(subnetId), '/virtualNetworks/$MI_VNET/')])" -o tsv) || fail "the virtual clusters were not read: the state file stays"
    [ "$VC" = 0 ] && break; sleep 60
  done
  [ "$VC" = 0 ] || fail "the virtual cluster on $MI_VNET is still there after 3 h: run down again later (the state file stays)"
  echo "read back: virtual clusters on $MI_VNET 0"
  for r in "vnet $MI_VNET" "nsg $MI_NSG" "route-table $MI_RT"; do
    set -- $r
    if az_ network "$1" show -g "$(g)" -n "$2" -o none 2>/dev/null; then az_ network "$1" delete -g "$(g)" -n "$2" -o none; echo "deleted: $1 $2"; fi
  done
  LEFT=
  for _ in $(seq 1 12); do
    LEFT=$(az_ resource list --tag "$(TAG)" --query 'length(@)' -o tsv) || fail "the tag read-back failed: the state file stays"
    [ "$LEFT" = 0 ] && break; sleep 10
  done
  NAMED=$(az_ resource list -g "$(g)" --query "length([?starts_with(name, '$MI_NAME')])" -o tsv) || fail "the name read-back failed: the state file stays"
  echo "read back: resources tagged $(TAG) $LEFT, named $MI_NAME* in $(g) $NAMED"
  [ "$LEFT|$NAMED" = "0|0" ] || fail "something is left (above): the state file $STATE stays"
  rm -f "$STATE"
  echo "down: 0 left"
  ;;
*) sed -n '2,13p' "$0"; exit 2 ;;
esac
