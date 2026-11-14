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
#   scripts/lab/azure-mi.sh vm              (M6) a VM with a system-assigned identity whose address 3342 admits too
#   scripts/lab/azure-mi.sh vmdoor <ip>     the VM admits ssh from this address only
#   scripts/lab/azure-mi.sh vmlogin         the VM's identity as a login of the instance (FROM EXTERNAL PROVIDER)
#   scripts/lab/azure-mi.sh vmdown          the VM's login, its 3342 rule, the VM and its pieces; read back
#   scripts/lab/azure-mi.sh down            the instance, then - once its virtual cluster is gone - the network; read back
#
# Settings (environment):
#   PGVIGIL_LAB_PROOF            the proof's tag value: everything made carries pgvigil-proof=<value> (required)
#   PGVIGIL_LAB_AZ_SUBSCRIPTION  the subscription id (required)
#   PGVIGIL_LAB_AZ_GROUP         the resource group, which must exist (required)
#   PGVIGIL_LAB_AZ_REGION        the region (required for up)
#   PGVIGIL_LAB_DIR              the state folder, default .lab (up writes a .gitignore of '*' into it)
#   PGVIGIL_SQLCMD_IMAGE         the image whose sqlcmd 'logins' runs, default mcr.microsoft.com/mssql/server:2022-latest
#   PGVIGIL_LAB_AZ_VM_SIZE       the VM's size (vm), default Standard_D2ls_v6
#   AZ                           the Azure CLI, default az on the PATH
#
# What up makes, each named pgv-mi-<suf>* and tagged: a virtual network (10.0.0.0/16) with one subnet (10.0.0.0/24)
# delegated to Microsoft.Sql/managedInstances, a network security group and a route table on that subnet - both made
# EMPTY: Microsoft's service-aided subnet configuration adds the rules and routes the instance needs (its network
# intent policy); this script adds no inbound rule until 'allow' (port 3342 from one address) - and the instance
# (free offer, public data endpoint on, a system-assigned identity, TLS 1.2). Its stop / start schedule (on by
# default: 9 a.m. to 5 p.m. on weekdays) is deleted right after the create and read back gone, and a stopped instance
# is started; with no schedule the instance spends the offer's 720 vCore-hours a month in about 7.5 days at 4 vCores,
# then stops itself ('Stopped - Insufficient credit', no charge) and is not started again: take it down the same day.
# The admin's password and the monitor's are made here from /dev/urandom and written only to the mode-600
# state file <dir>/azure-mi.env; the admin's reaches az through a mode-600 file (az's @file form), removed right
# after, never a command line. down deletes the instance, waits for its virtual cluster to be removed (Microsoft: up to
# 1.5 hours after the last instance), deletes the VNet, the NSG and the route table, and reads back by name and tag; the
# state file goes only when nothing is left.
# M6 (entra-identity on the instance) needs a host with an Azure identity: 'vm' makes one VM (Ubuntu 24.04, a
# system-assigned identity), its NIC and OS disk (deleted with it), a public address, a network security group with no
# inbound rule until 'vmdoor', and a virtual network of its own, each named <instance>-vm* and tagged, a mode-600 ssh
# key pair in the state folder, and a second 3342 rule on the instance's NSG for the VM's address. 'vmlogin' makes the
# VM's identity a login of the instance as its admin (a sysadmin SQL login may create Entra logins there once the
# instance has a Microsoft Entra admin - without one a real instance answered Msg 33134 'could not be resolved'; the
# instance resolves the name with its Directory Readers role; both are Entra steps outside this script) with VIEW SERVER
# STATE, VIEW ANY DEFINITION and a user in msdb - not CONNECT ANY DATABASE, so the user database the proof made refuses
# it (M6's E2); a login of the same name is dropped first (an earlier VM's identity has another SID), and a name the
# instance cannot resolve yet is tried again for about 4 minutes. The VM is billed by the minute: vmdown removes the
# login, the rule, the NIC, the VM and its pieces and reads them back; down refuses while the state file names a VM.
set -euo pipefail
cd "$(dirname "$0")/../.."
DIR=${PGVIGIL_LAB_DIR:-.lab}
STATE=$DIR/azure-mi.env
SQLCMD_IMAGE=${PGVIGIL_SQLCMD_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
AZ=${AZ:-az}
VM_SIZE=${PGVIGIL_LAB_AZ_VM_SIZE:-Standard_D2ls_v6}
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
# sqa <database>: one batch from stdin as the instance's admin (the password to docker by name, never on a command line)
sqa() { SQLCMDPASSWORD=$ADMIN_PW; export SQLCMDPASSWORD
  docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$SQLCMD_IMAGE" -S "tcp:$MI_PUBLIC,$MI_PORT" -U "$ADMIN_USER" -d "$1" -C -b -l 60 -h -1 -W -i /dev/stdin; }
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
  # a create that ends early goes from Provisioning to FailedToCreate (Microsoft's management-operations-cancel page):
  # both the state and the provisioning state are read, and any failed or cancelled word in either ends the wait
  st= pst=
  for _ in $(seq 1 360); do
    st= pst=
    read -r st pst < <(az_ sql mi show -g "$(g)" -n "$MI_NAME" --query '[[state, provisioningState]]' -o tsv 2>/dev/null) || true
    [ "$st" = Ready ] && break
    case "$st $pst" in *[Ff]ail*|*[Cc]ancel*) fail "the create of $MI_NAME ended '$st' / '$pst' (down removes what was made)" ;; esac
    sleep 60
  done
  [ "$st" = Ready ] || fail "$MI_NAME is not Ready after 6 h (state '${st:-none}', provisioning '${pst:-none}'); down removes it"
  read -r MI_FQDN MI_ZONE MI_PRINCIPAL < <(az_ sql mi show -g "$(g)" -n "$MI_NAME" --query '[[fullyQualifiedDomainName, dnsZone, identity.principalId]]' -o tsv) || true
  [ -n "${MI_FQDN:-}" ] && [ -n "${MI_ZONE:-}" ] || fail "the instance's host name was not read back"
  # the public endpoint's host: <name>.public.<dnszone>.database.windows.net, port 3342 (Microsoft's public-endpoint page)
  MI_PUBLIC=${MI_FQDN/.$MI_ZONE./.public.$MI_ZONE.}
  ( umask 077; printf 'MI_FQDN=%s\nMI_PUBLIC=%s\nMI_PRINCIPAL=%s\n' "$MI_FQDN" "$MI_PUBLIC" "${MI_PRINCIPAL:-}" >> "$STATE" )
  echo "made: managed instance $MI_NAME ($MI_FQDN; public endpoint $MI_PUBLIC,3342; system-assigned identity ${MI_PRINCIPAL:-none read}), tag $(TAG)"
  # the free offer's stop / start schedule (on by default, weekdays 9-5): deleted, read back, and a stopped instance started
  # the delete's own error is shown (the read-back decides); a list that answers 'not found' after it counts as none
  az_ sql mi start-stop-schedule delete --mi "$MI_NAME" -g "$(g)" --yes -o none || echo "note: the schedule's delete answered an error (above): the read-back decides"
  if OUT=$(az_ sql mi start-stop-schedule list --mi "$MI_NAME" -g "$(g)" --query 'length(@)' -o tsv 2>&1); then N=$OUT
  elif grep -qiE 'NotFound|was not found|could not be found' <<<"$OUT"; then N=0
  else fail "the stop schedule was not read back ($OUT)"; fi
  [ "$N" = 0 ] || fail "$MI_NAME keeps a stop schedule ($N): the proof could be cut by it"
  echo "removed: $MI_NAME's stop / start schedule (read back: none)"
  # an instance the schedule was stopping or starting is waited for; one stopped (by the schedule, or out of the free
  # offer's hours: 'Stopped - Insufficient credit') is started, and a refused start ends up with the reason
  st=
  for _ in $(seq 1 30); do
    st=$(az_ sql mi show -g "$(g)" -n "$MI_NAME" --query state -o tsv) || fail "the instance's state was not read"
    case $st in Stopping|Starting) sleep 60 ;; *) break ;; esac
  done
  case $st in
    Ready) ;;
    Stopped*) az_ sql mi start -g "$(g)" --mi "$MI_NAME" -o none || fail "$MI_NAME is '$st' and did not start (above): down removes it"
              echo "started: $MI_NAME (it was '$st')" ;;
    *) fail "$MI_NAME is '$st' after its schedule was removed: down removes it" ;;
  esac
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
GRANT CONNECT ANY DATABASE TO [$MON_USER];
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
vm)
  need_az; load
  [ -z "${VM_NAME:-}" ] || fail "the state file names a VM already ($VM_NAME): vmdown first"
  command -v ssh-keygen >/dev/null && command -v jq >/dev/null || fail "ssh-keygen and jq are needed (the VM's key, its create's answer)"
  # the size, its restrictions and the family's and region's free cores, read before anything is made
  [ "$(az_ vm list-skus -l "$LAB_REGION" --size "$VM_SIZE" --query "length([?name=='$VM_SIZE'])" -o tsv)" = 1 ] || fail "the region $LAB_REGION offers no $VM_SIZE"
  R=$(az_ vm list-skus -l "$LAB_REGION" --size "$VM_SIZE" --query "[?name=='$VM_SIZE'] | [0].restrictions[].reasonCode" -o tsv)
  [ -z "$R" ] || fail "the region $LAB_REGION restricts $VM_SIZE for this subscription: $R"
  read -r FAM NEED < <(az_ vm list-skus -l "$LAB_REGION" --size "$VM_SIZE" --query "[?name=='$VM_SIZE'] | [0].[[family, capabilities[?name=='vCPUs'].value | [0]]]" -o tsv) || true
  [ -n "${FAM:-}" ] && [[ ${NEED:-} =~ ^[0-9]+$ ]] || fail "the family and vCPUs of $VM_SIZE were not read"
  for q in "$FAM" cores; do
    USED= LIMIT=; read -r USED LIMIT < <(az_ vm list-usage -l "$LAB_REGION" --query "[?name.value=='$q'] | [0].[[currentValue, limit]]" -o tsv) || true
    [[ ${USED:-} =~ ^[0-9]+$ && ${LIMIT:-} =~ ^[0-9]+$ ]] || fail "the quota $q in $LAB_REGION was not read"
    [ $((LIMIT - USED)) -ge "$NEED" ] || fail "the quota $q in $LAB_REGION has $((LIMIT - USED)) of $LIMIT cores free, $VM_SIZE needs $NEED: nothing made"
  done
  VM_NAME=$MI_NAME-vm VM_ADMIN=pgv VM_KEY=$DIR/azure-mi-vm.key
  # the state file names the VM before it is made, so vmdown finds whatever a failed create left
  ( umask 077; printf 'VM_NAME=%s\nVM_ADMIN=%s\nVM_KEY=%s\n' "$VM_NAME" "$VM_ADMIN" "$VM_KEY" >> "$STATE" )
  rm -f "$VM_KEY" "$VM_KEY.pub"; ssh-keygen -q -t ed25519 -N '' -C pgv-mi-proof -f "$VM_KEY"; chmod 600 "$VM_KEY"
  VMJ=$(az_ vm create -g "$(g)" -n "$VM_NAME" -l "$LAB_REGION" --image Canonical:ubuntu-24_04-lts:server:latest --size "$VM_SIZE" \
    --admin-username "$VM_ADMIN" --ssh-key-values "$VM_KEY.pub" --assign-identity '[system]' --nsg "$VM_NAME-nsg" --nsg-rule NONE \
    --public-ip-address "$VM_NAME-ip" --public-ip-sku Standard --vnet-name "$VM_NAME-vnet" --vnet-address-prefix 10.1.0.0/16 --subnet-address-prefix 10.1.0.0/24 \
    --nic-delete-option Delete --os-disk-delete-option Delete --tags "$(TAG)" -o json) || fail "the VM was not made (above): vmdown removes what was"
  VM_IP=$(jq -r '.publicIpAddress // empty' <<<"$VMJ"); VM_PRINCIPAL=$(jq -r '.identity.systemAssignedIdentity // empty' <<<"$VMJ")
  ip_ok "${VM_IP:-x}" && [ -n "$VM_PRINCIPAL" ] || fail "the VM's address or identity was not read back: vmdown removes what was made"
  ( umask 077; printf 'VM_IP=%s\nVM_PRINCIPAL=%s\n' "$VM_IP" "$VM_PRINCIPAL" >> "$STATE" )
  echo "made: VM $VM_NAME ($VM_SIZE, Ubuntu 24.04, system-assigned identity $VM_PRINCIPAL) at $VM_IP, its NIC and OS disk (deleted with it), $VM_NAME-ip, $VM_NAME-nsg (no inbound rule), $VM_NAME-vnet (10.1.0.0/16); tag $(TAG) (undo: vmdown)"
  az_ network nsg rule create -g "$(g)" --nsg-name "$MI_NSG" -n pgv-vm-3342 --priority 1310 --direction Inbound --access Allow \
    --protocol Tcp --source-address-prefixes "$VM_IP/32" --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 3342 -o none
  GOT=$(az_ network nsg rule show -g "$(g)" --nsg-name "$MI_NSG" -n pgv-vm-3342 --query '[[sourceAddressPrefix, destinationPortRange, access, direction]]' -o tsv)
  [ "$GOT" = "$(printf '%s/32\t3342\tAllow\tInbound' "$VM_IP")" ] || fail "the VM's 3342 rule reads '$GOT', not $VM_IP/32 alone"
  echo "allowed: $MI_NAME's public endpoint (3342) admits the VM's $VM_IP/32 too (rule pgv-vm-3342; undo: vmdown)"
  echo "vm: next vmdoor <this machine's ip>, then vmlogin"
  ;;
vmdoor)
  need_az; load; shift
  [ -n "${VM_IP:-}" ] || fail "no VM in the state file (vm first)"
  [ $# -eq 1 ] && ip_ok "$1" || fail "vmdoor <ip>: one IPv4 address"
  az_ network nsg rule delete -g "$(g)" --nsg-name "$VM_NAME-nsg" -n pgv-ssh -o none 2>/dev/null || true
  az_ network nsg rule create -g "$(g)" --nsg-name "$VM_NAME-nsg" -n pgv-ssh --priority 1000 --direction Inbound --access Allow \
    --protocol Tcp --source-address-prefixes "$1/32" --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 22 -o none
  GOT=$(az_ network nsg rule list -g "$(g)" --nsg-name "$VM_NAME-nsg" --query "[?direction=='Inbound' && access=='Allow'].[name,sourceAddressPrefix,destinationPortRange]" -o tsv)
  [ "$GOT" = "$(printf 'pgv-ssh\t%s/32\t22' "$1")" ] || fail "the VM's door reads '$GOT', not ssh from $1 alone"
  echo "door: $VM_NAME admits ssh from $1 only (undo: goes with the VM)"
  ;;
vmlogin)
  need_az; load
  [ -n "${VM_PRINCIPAL:-}" ] || fail "no VM in the state file (vm first)"
  command -v docker >/dev/null || fail "docker is not on this machine (sqlcmd runs from $SQLCMD_IMAGE)"
  # the identity's login is its display name, the VM's name (a system-assigned identity is named as its resource)
  BATCH=$(cat <<SQL
SET NOCOUNT ON;
IF SUSER_ID(N'$VM_NAME') IS NOT NULL DROP LOGIN [$VM_NAME];
CREATE LOGIN [$VM_NAME] FROM EXTERNAL PROVIDER;
GRANT VIEW SERVER STATE TO [$VM_NAME];
GRANT VIEW ANY DEFINITION TO [$VM_NAME];
GO
USE msdb;
IF USER_ID(N'$VM_NAME') IS NOT NULL DROP USER [$VM_NAME];
CREATE USER [$VM_NAME] FOR LOGIN [$VM_NAME];
ALTER ROLE db_datareader ADD MEMBER [$VM_NAME];
GO
SELECT 'vmlogin: ' + p.name COLLATE DATABASE_DEFAULT + ' type ' + CAST(p.type_desc AS nvarchar(60)) COLLATE DATABASE_DEFAULT + ', holds ' + ISNULL((SELECT STRING_AGG(CAST(sp.permission_name AS nvarchar(128)) COLLATE DATABASE_DEFAULT, ', ')
         FROM sys.server_permissions sp WHERE sp.grantee_principal_id = p.principal_id AND sp.state = 'G'), 'nothing')
       + '; msdb user ' + CAST(ISNULL((SELECT 1 FROM msdb.sys.database_principals u WHERE u.sid = p.sid), 0) AS varchar(1))
       + '; a user in $MI_DB ' + CAST(ISNULL((SELECT 1 FROM [$MI_DB].sys.database_principals u WHERE u.sid = p.sid), 0) AS varchar(1))
FROM sys.server_principals p WHERE p.name = N'$VM_NAME';
SQL
)
  # a name the instance cannot resolve yet (an identity made minutes ago; a directory role granted minutes ago) is tried
  # again for about 4 minutes; any other refusal, or one that lasts, is printed as the instance's words
  for try in 1 2 3 4 5 6 7 8 9; do
    if OUT=$(sqa master <<<"$BATCH" 2>&1); then break; fi
    grep -qiE 'could not be (found|resolved)|cannot be resolved|not found in' <<<"$OUT" && [ "$try" -lt 9 ] || { echo "$OUT" >&2; fail "the instance refused the VM's login (above, try $try): a finding - the words are Microsoft's"; }
    echo "vmlogin: try $try - the instance cannot resolve $VM_NAME yet; again in 30 s"; sleep 30
  done
  echo "$OUT"
  grep -q "^vmlogin: $VM_NAME type EXTERNAL_LOGIN" <<<"$OUT" || fail "the VM's login was not read back as an external login (above)"
  ;;
vmdown)
  need_az; load
  [ -n "${VM_NAME:-}" ] || { echo "vmdown: no VM in the state file"; exit 0; }
  # the login first (the instance stays up for the proof's other rows), then the rule, the VM, its pieces
  if command -v docker >/dev/null; then
    if OUT=$(sqa master 2>&1 <<SQL
SET NOCOUNT ON;
USE msdb; IF USER_ID(N'$VM_NAME') IS NOT NULL DROP USER [$VM_NAME];
GO
IF SUSER_ID(N'$VM_NAME') IS NOT NULL DROP LOGIN [$VM_NAME];
SELECT 'logins named $VM_NAME: ' + CAST(COUNT(*) AS varchar(10)) FROM sys.server_principals WHERE name = N'$VM_NAME';
SQL
    ); then
      echo "$OUT" | grep '^logins named' | sed 's/^/read back: /'
      grep -q "^logins named $VM_NAME: 0" <<<"$OUT" && echo "dropped: login $VM_NAME and its msdb user" || echo "WARN: the login $VM_NAME is still on the instance (above; the instance's delete removes it)" >&2
    else
      echo "$OUT" >&2; echo "WARN: the login $VM_NAME was not dropped (the instance's words above; the instance's delete removes it)" >&2
    fi
  else
    echo "WARN: docker is not on this machine: the login $VM_NAME was not dropped (the instance's delete removes it)" >&2
  fi
  az_ network nsg rule delete -g "$(g)" --nsg-name "$MI_NSG" -n pgv-vm-3342 -o none || echo "WARN: the rule's delete answered an error (above); read back next" >&2
  RL=$(az_ network nsg rule list -g "$(g)" --nsg-name "$MI_NSG" --query "[?name=='pgv-vm-3342'].name" -o tsv) || fail "$MI_NSG's rules were not read back: the state file names the VM still"
  [ -z "$RL" ] || fail "the rule pgv-vm-3342 is still on $MI_NSG"
  echo "deleted: $MI_NSG's rule pgv-vm-3342"
  if az_ vm show -g "$(g)" -n "$VM_NAME" -o none 2>/dev/null; then
    az_ vm delete -g "$(g)" -n "$VM_NAME" --yes -o none || fail "the VM $VM_NAME was not deleted (above): the state file names it still"
    echo "deleted: VM $VM_NAME (its NIC and OS disk with it)"
  fi
  # the NIC first: a create that failed after its network pieces leaves it holding the public address (az's own NIC
  # name: <vm>VMNic), and the address cannot be deleted while it is in use
  for r in "nic ${VM_NAME}VMNic" "public-ip $VM_NAME-ip" "nsg $VM_NAME-nsg" "vnet $VM_NAME-vnet"; do
    set -- $r
    if az_ network "$1" show -g "$(g)" -n "$2" -o none 2>/dev/null; then
      ok=; for _ in 1 2 3 4 5; do if az_ network "$1" delete -g "$(g)" -n "$2" -o none; then ok=1; break; fi; sleep 30; done
      [ -n "$ok" ] || fail "$1 $2 was not deleted after 5 tries (above): the state file names the VM still; run vmdown again"
      echo "deleted: $1 $2"
    fi
  done
  NAMED=$(az_ resource list -g "$(g)" --query "length([?starts_with(name, '$VM_NAME')])" -o tsv) || fail "the read-back failed: the state file names the VM still"
  echo "read back: resources named $VM_NAME* in $(g) $NAMED"
  [ "$NAMED" = 0 ] || fail "something of the VM is left (above): the state file names it still"
  sed -i '/^VM_\(NAME\|ADMIN\|KEY\|IP\|PRINCIPAL\)=/d' "$STATE"; rm -f "$VM_KEY" "$VM_KEY.pub"
  echo "vmdown: 0 left of the VM"
  ;;
down)
  need_az; load
  [ -z "${VM_NAME:-}" ] || fail "the state file names the VM $VM_NAME: vmdown first (the VM goes before the instance)"
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
    # every virtual cluster of the subscription (its group is the service's choice), matched by the subnet's VNet
    # without case (an id may come back as /virtualnetworks/)
    VC=$(az_ sql virtual-cluster list --query '[].subnetId' -o tsv) || fail "the virtual clusters were not read: the state file stays"
    VC=$(grep -ci "/virtualnetworks/$MI_VNET/" <<<"$VC" || true)
    [ "$VC" = 0 ] && break; sleep 60
  done
  [ "$VC" = 0 ] || fail "the virtual cluster on $MI_VNET is still there after 3 h: run down again later (the state file stays)"
  echo "read back: virtual clusters on $MI_VNET 0"
  # the subnet's network intent policy ends once no virtual cluster is in it AND its delegation is removed (Microsoft's
  # subnet-service-aided-configuration page): the delegation first, then each piece with spaced tries
  if az_ network vnet show -g "$(g)" -n "$MI_VNET" -o none 2>/dev/null; then
    D=$(az_ network vnet subnet show -g "$(g)" --vnet-name "$MI_VNET" -n "$MI_SUBNET" --query 'length(delegations)' -o tsv 2>/dev/null || echo 0)
    if [ "${D:-0}" != 0 ]; then
      az_ network vnet subnet update -g "$(g)" --vnet-name "$MI_VNET" -n "$MI_SUBNET" --remove delegations 0 -o none \
        || fail "$MI_SUBNET's delegation was not removed (above): the state file stays; run down again later"
      echo "removed: $MI_SUBNET's delegation"
    fi
  fi
  for r in "vnet $MI_VNET" "nsg $MI_NSG" "route-table $MI_RT"; do
    set -- $r
    if az_ network "$1" show -g "$(g)" -n "$2" -o none 2>/dev/null; then
      ok=
      for _ in 1 2 3 4 5; do
        if az_ network "$1" delete -g "$(g)" -n "$2" -o none; then ok=1; break; fi
        sleep 120
      done
      [ -n "$ok" ] || fail "$1 $2 was not deleted after 5 tries 2 min apart (above): the state file stays; run down again later"
      echo "deleted: $1 $2"
    fi
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
