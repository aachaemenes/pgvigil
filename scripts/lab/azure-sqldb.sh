#!/usr/bin/env bash
# Lab: one Azure SQL Database (a logical server and one serverless database under the subscription's monthly free
# limit) for the cloud proof scripts/proof-mssql-azuresqldb.sh, made and removed from the machine that holds the
# Azure CLI sign-in.
#
#   scripts/lab/azure-sqldb.sh up                  make the server, the database and the state file
#   scripts/lab/azure-sqldb.sh allow <ip> [<ip>]   the server's firewall admits these addresses only
#   scripts/lab/azure-sqldb.sh logins              (where 1433 reaches) the collector's contained user and its right
#   scripts/lab/azure-sqldb.sh vmdoor <ip>         (tier pool) the VM's ssh door admits this address only
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
#                                STATE, so the proof's least-privilege user reads less there); pool: a Basic elastic
#                                pool of 50 eDTU with two Basic databases in it, the server's Entra admin set to the
#                                CLI's signed-in user, and one Standard_B2ats_v2 Ubuntu VM with a system-assigned
#                                managed identity (scripts/proof-mssql-pool.sh: the pool's figures and the
#                                entra-identity sign-in; Azure's retail prices, westus3, read 2026-11-13: the Basic
#                                50 eDTU pool USD 2.42 a day (its databases inside it), the VM USD 0.0094 / h, its
#                                Standard IPv4 USD 0.005 / h, its 30 GB Standard SSD OS disk (E4) USD 2.40 a month)
#   PGVIGIL_LAB_DIR              the state folder, default .lab (up writes a .gitignore of '*' into it)
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
# resource of the subscription that carries the tag) and removes the state file only when nothing is left.
# The pool tier also makes, each named from the server's name and tagged: the VM (its OS disk and NIC deleted with
# it), its public address, its network security group (NO inbound rule until 'vmdoor': nothing reaches it), its
# virtual network, and a mode-600 ssh key pair in the state folder; its 'logins' make two SQL logins in master
# (pgv_pool: ##MS_ServerStateReader##, a user in each pooled database; pgv_conn: ##MS_ServerStateReader## and
# ##MS_DatabaseConnector##, no user anywhere), the contained user of the free / basic tiers in the first database,
# and the VM's identity as a user of the first database only, made by SID = its client id, TYPE = E (Microsoft's
# CREATE USER: 'The Database Engine doesn't validate the specified ID in Microsoft Entra': no directory role is
# needed). down deletes the VM and its pieces first, then the server, and reads both back.
set -euo pipefail
cd "$(dirname "$0")/../.."
DIR=${PGVIGIL_LAB_DIR:-.lab}
STATE=$DIR/azure-sqldb.env
SQLCMD_IMAGE=${PGVIGIL_SQLCMD_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
AZ=${AZ:-az}
TIER=${PGVIGIL_LAB_AZ_TIER:-free}
VM_SIZE=Standard_B2ats_v2
CMD=${1:-}
fail() { echo "FAIL: $*" >&2; exit 1; }
need_az() {
  : "${PGVIGIL_LAB_PROOF:?the tag value (pgvigil-proof=<value>)}" "${PGVIGIL_LAB_AZ_SUBSCRIPTION:?the subscription id}" "${PGVIGIL_LAB_AZ_GROUP:?the resource group}"
  [[ $PGVIGIL_LAB_PROOF =~ ^[A-Za-z0-9-]{1,40}$ ]] || fail "PGVIGIL_LAB_PROOF is letters, digits and dashes"
  command -v "$AZ" >/dev/null || fail "the Azure CLI ($AZ) is not on this machine"
}
az_() { "$AZ" "$@" --subscription "$PGVIGIL_LAB_AZ_SUBSCRIPTION" --only-show-errors; }
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
# load: the state file, which names the scope up used; a call under another subscription, group or tag would read
# the wrong place and could say 0 left while the server runs, so it is refused
load() { [ -r "$STATE" ] || fail "no state file $STATE (run up first)"; # shellcheck disable=SC1090
  . "$STATE"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git check-ignore -q "$STATE" || fail "$STATE is not git-ignored (it holds passwords)"; fi
  [ -z "${PGVIGIL_LAB_AZ_SUBSCRIPTION:-}" ] || [ "$PGVIGIL_LAB_AZ_SUBSCRIPTION" = "${LAB_SUBSCRIPTION:-}" ] || fail "the state file was made with subscription '${LAB_SUBSCRIPTION:-}', not '$PGVIGIL_LAB_AZ_SUBSCRIPTION'"
  [ -z "${PGVIGIL_LAB_AZ_GROUP:-}" ] || [ "$PGVIGIL_LAB_AZ_GROUP" = "${LAB_GROUP:-}" ] || fail "the state file was made with group '${LAB_GROUP:-}', not '$PGVIGIL_LAB_AZ_GROUP'"
  [ -z "${PGVIGIL_LAB_PROOF:-}" ] || [ "$PGVIGIL_LAB_PROOF" = "${LAB_PROOF:-}" ] || fail "the state file was made with tag '${LAB_PROOF:-}', not '$PGVIGIL_LAB_PROOF'"; }
# one IPv4 address, no leading zeros (00.0.0.0 could be read as 0.0.0.0, every Azure service), never 0.0.0.0
ip_ok() { local oct='(0|[1-9][0-9]?|1[0-9]{2}|2[0-4][0-9]|25[0-5])'
  [[ $1 =~ ^$oct\.$oct\.$oct\.$oct$ ]] && [ "$1" != 0.0.0.0 ]; }
# fw_clear: delete every firewall rule of the server; the listing is an assignment, so a failed read stops the script
# instead of leaving old rules in place
fw_clear() { local rules r; rules=$(az_ sql server firewall-rule list -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" --query '[].name' -o tsv)
  for r in $rules; do az_ sql server firewall-rule delete -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" -n "$r"; echo "removed: firewall rule $r"; done; }

case $CMD in
up)
  need_az; : "${PGVIGIL_LAB_AZ_REGION:?the region}"
  case $TIER in free|basic|pool) ;; *) fail "PGVIGIL_LAB_AZ_TIER is free, basic or pool" ;; esac
  [ ! -e "$STATE" ] || fail "$STATE exists: this lab is up (status) or was not taken down (down)"
  # a region can refuse new SQL servers for a subscription (ProvisioningDisabled), and the server's create then fails
  # minutes after it was accepted: the region's capability is read first and a restricted region is refused here
  ED=$([ "$TIER" = free ] && echo GeneralPurpose || echo Basic)
  CAP=$(az_ sql db list-editions -l "$PGVIGIL_LAB_AZ_REGION" --edition "$ED" --query '[0].status' -o tsv)
  case $CAP in Available|Default) ;; *) fail "the region $PGVIGIL_LAB_AZ_REGION refuses $ED for this subscription ($CAP): $(az_ sql db list-editions -l "$PGVIGIL_LAB_AZ_REGION" --edition "$ED" --query '[0].reason' -o tsv)" ;; esac
  if [ "$TIER" = pool ]; then
    command -v ssh-keygen >/dev/null || fail "ssh-keygen is not on this machine (the VM's key)"
    [ "$(az_ vm list-skus -l "$PGVIGIL_LAB_AZ_REGION" --size "$VM_SIZE" --query "length([?name=='$VM_SIZE'])" -o tsv)" = 1 ] || fail "the region $PGVIGIL_LAB_AZ_REGION offers no $VM_SIZE"
    R=$(az_ vm list-skus -l "$PGVIGIL_LAB_AZ_REGION" --size "$VM_SIZE" --query "[?name=='$VM_SIZE'] | [0].restrictions[].reasonCode" -o tsv)
    [ -z "$R" ] || fail "the region $PGVIGIL_LAB_AZ_REGION restricts $VM_SIZE for this subscription: $R"
  fi
  mkdir -p "$DIR"; chmod 700 "$DIR"; printf '*\n' > "$DIR/.gitignore"   # the folder ignores itself on any clone
  SUF=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
  ( umask 077; cat > "$STATE" <<EOF
LAB_SUBSCRIPTION=$PGVIGIL_LAB_AZ_SUBSCRIPTION
LAB_GROUP=$PGVIGIL_LAB_AZ_GROUP
LAB_PROOF=$PGVIGIL_LAB_PROOF
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
  if [ "$TIER" = pool ]; then ( umask 077; cat >> "$STATE" <<EOF
AZ_DB=pgvpool1
AZ_DB2=pgvpool2
AZ_POOL=pgvpool
POOL_USER=pgv_pool
POOL_PW=$(pw)
CONN_USER=pgv_conn
CONN_PW=$(pw)
LAB_REGION=$PGVIGIL_LAB_AZ_REGION
VM_NAME=pgv-proof-$SUF-vm
VM_ADMIN=pgv
VM_KEY=$DIR/azure-vm.key
EOF
  ); fi
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
    [ "$st" = Ready ] && break
    # an accepted create that failed later is only in the activity log
    why=$(az_ monitor activity-log list -g "$PGVIGIL_LAB_AZ_GROUP" --offset 1h --query "[?ends_with(resourceId, '/servers/$AZ_SERVER') && status.value=='Failed'] | [0].properties.statusMessage" -o tsv 2>/dev/null || true)
    [ -z "$why" ] || fail "the create of $AZ_SERVER failed after it was accepted: $why"
    sleep 10
  done
  [ "${st:-}" = Ready ] || fail "the server $AZ_SERVER is not Ready after 10 min (state '${st:-none}'); down removes it"
  echo "made: logical server $AZ_SERVER in $PGVIGIL_LAB_AZ_GROUP ($PGVIGIL_LAB_AZ_REGION), tag pgvigil-proof=$PGVIGIL_LAB_PROOF, TLS 1.2+"
  # a server made through the API has no firewall rule; any rule found (another tool's default) is removed
  fw_clear
  if [ "$TIER" = pool ]; then
    read -r ME_ID ME_UPN < <("$AZ" ad signed-in-user show --query '[[id,userPrincipalName]]' -o tsv --only-show-errors)
    [ -n "${ME_ID:-}" ] && [ -n "${ME_UPN:-}" ] || fail "the CLI's signed-in user was not read (az ad signed-in-user show)"
    az_ sql server ad-admin create -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" --display-name "$ME_UPN" --object-id "$ME_ID" >/dev/null
    echo "made: the Entra admin of $AZ_SERVER = the CLI's signed-in user (undo: goes with the server)"
    az_ sql elastic-pool create -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" -n "$AZ_POOL" --edition Basic --capacity 50 \
      --db-max-capacity 5 --db-min-capacity 0 --tags "pgvigil-proof=$PGVIGIL_LAB_PROOF" --query '[[name,sku.tier,sku.capacity,state]]' -o tsv
    echo "made: elastic pool $AZ_POOL (Basic, 50 eDTU), tag pgvigil-proof=$PGVIGIL_LAB_PROOF"
    for d in "$AZ_DB" "$AZ_DB2"; do
      az_ sql db create -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" -n "$d" --elastic-pool "$AZ_POOL" --backup-storage-redundancy Local \
        --tags "pgvigil-proof=$PGVIGIL_LAB_PROOF" --query '[[name,currentServiceObjectiveName,elasticPoolName,status]]' -o tsv
      echo "made: database $d in $AZ_POOL, tag pgvigil-proof=$PGVIGIL_LAB_PROOF"
    done
    ssh-keygen -q -t ed25519 -N '' -C pgv-proof -f "$VM_KEY"; chmod 600 "$VM_KEY"
    VMJ=$(az_ vm create -g "$PGVIGIL_LAB_AZ_GROUP" -n "$VM_NAME" -l "$LAB_REGION" --image Canonical:ubuntu-24_04-lts:server:latest --size "$VM_SIZE" \
      --admin-username "$VM_ADMIN" --ssh-key-values "$VM_KEY.pub" --assign-identity '[system]' --nsg "$VM_NAME-nsg" --nsg-rule NONE \
      --public-ip-address "$VM_NAME-ip" --public-ip-sku Standard --vnet-name "$VM_NAME-vnet" --nic-delete-option Delete \
      --os-disk-delete-option Delete --storage-sku StandardSSD_LRS --os-disk-size-gb 30 --tags "pgvigil-proof=$PGVIGIL_LAB_PROOF" -o json)
    VM_IP=$(jq -r '.publicIpAddress // empty' <<<"$VMJ"); VM_PRINCIPAL=$(jq -r '.identity.systemAssignedIdentity // empty' <<<"$VMJ")
    [ -n "$VM_IP" ] && [ -n "$VM_PRINCIPAL" ] || fail "the VM's address or identity was not read back (down removes what was made, its NIC first)"
    VM_CLIENT=$("$AZ" ad sp show --id "$VM_PRINCIPAL" --query appId -o tsv --only-show-errors)
    [[ $VM_CLIENT =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "the VM identity's client id was not read"
    ( umask 077; printf 'VM_IP=%s\nVM_PRINCIPAL=%s\nVM_CLIENT=%s\n' "$VM_IP" "$VM_PRINCIPAL" "$VM_CLIENT" >> "$STATE" )
    echo "made: VM $VM_NAME ($VM_SIZE, Ubuntu 24.04, system-assigned identity) at $VM_IP, its NIC, OS disk, $VM_NAME-ip, $VM_NAME-nsg (no inbound rule), $VM_NAME-vnet; tag pgvigil-proof=$PGVIGIL_LAB_PROOF"
    echo "up: $AZ_HOST,1433 pool $AZ_POOL, databases $AZ_DB and $AZ_DB2; VM $VM_NAME at $VM_IP; no address admitted yet: allow <ip> [<ip>] (this machine, the VM), vmdoor <ip>, then logins"
    exit 0
  elif [ "$TIER" = free ]; then
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
  fw_clear >/dev/null
  n=0; for a in "$@"; do n=$((n + 1))
    az_ sql server firewall-rule create -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" -n "pgv-reader-$n" --start-ip-address "$a" --end-ip-address "$a" >/dev/null
  done
  # the door read back: exactly the addresses given, each a single address
  GOT=$(az_ sql server firewall-rule list -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" --query '[].[startIpAddress,endIpAddress]' -o tsv | awk '{ print ($1 == $2 ? $1 : "RANGE " $1 "-" $2) }' | sort -u)
  [ "$GOT" = "$(printf '%s\n' "$@" | sort -u)" ] || fail "the firewall reads '$(tr '\n' ' ' <<<"$GOT")', not the addresses given: run allow again or down"
  echo "allowed: $AZ_SERVER admits $(az_ sql server firewall-rule list -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" --query '[].[startIpAddress,endIpAddress]' -o tsv | awk '{ printf "%s%s", (NR > 1 ? " " : ""), ($1 == $2 ? $1 : $1 "-" $2) }') only"
  ;;
vmdoor)
  need_az; load; shift
  [ "${AZ_TIER:-}" = pool ] || fail "vmdoor is the pool tier's (no VM in this lab)"
  [ $# -eq 1 ] && ip_ok "$1" || fail "vmdoor <ip>: one IPv4 address"
  az_ network nsg rule delete -g "$PGVIGIL_LAB_AZ_GROUP" --nsg-name "$VM_NAME-nsg" -n pgv-ssh >/dev/null 2>&1 || true
  az_ network nsg rule create -g "$PGVIGIL_LAB_AZ_GROUP" --nsg-name "$VM_NAME-nsg" -n pgv-ssh --priority 1000 --direction Inbound \
    --access Allow --protocol Tcp --source-address-prefixes "$1/32" --destination-port-ranges 22 >/dev/null
  GOT=$(az_ network nsg rule list -g "$PGVIGIL_LAB_AZ_GROUP" --nsg-name "$VM_NAME-nsg" --query "[?direction=='Inbound' && access=='Allow'].[name,sourceAddressPrefix,destinationPortRange]" -o tsv)
  [ "$GOT" = "$(printf 'pgv-ssh\t%s/32\t22' "$1")" ] || fail "the VM's door reads '$GOT', not ssh from $1 alone"
  echo "door: $VM_NAME admits ssh from $1 only (undo: goes with the VM)"
  ;;
logins)
  # runs where 1433 reaches (the reading machine). The first connection may wake a paused database (error 40613
  # until it is online, about a minute): it is retried. The password goes to sqlcmd on stdin, never its command line.
  load
  command -v docker >/dev/null || fail "docker is not on this machine (sqlcmd runs from $SQLCMD_IMAGE)"
  export SQLCMDPASSWORD="$ADMIN_PW"
  ok=
  for _ in $(seq 1 12); do
    if docker run --rm -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$SQLCMD_IMAGE" -S "tcp:$AZ_HOST,$AZ_PORT" -U "$ADMIN_USER" -d "$AZ_DB" -C -b -l 60 -h -1 -W -Q "SET NOCOUNT ON; SELECT 1" >/dev/null 2>&1; then ok=1; break; fi
    sleep 15
  done
  [ -n "$ok" ] || fail "the database did not answer the admin login in 3 minutes (is this machine's address allowed?)"
  docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$SQLCMD_IMAGE" -S "tcp:$AZ_HOST,$AZ_PORT" -U "$ADMIN_USER" -d "$AZ_DB" -C -b -l 60 -h -1 -W -i /dev/stdin <<SQL
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
  if [ "${AZ_TIER:-}" = pool ]; then
    sq() { local d=$1; docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$SQLCMD_IMAGE" -S "tcp:$AZ_HOST,$AZ_PORT" -U "$ADMIN_USER" -d "$d" -C -b -l 60 -h -1 -W -i /dev/stdin; }
    sq master <<SQL
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'$POOL_USER') CREATE LOGIN [$POOL_USER] WITH PASSWORD = N'$POOL_PW';
ELSE ALTER LOGIN [$POOL_USER] WITH PASSWORD = N'$POOL_PW';
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'$CONN_USER') CREATE LOGIN [$CONN_USER] WITH PASSWORD = N'$CONN_PW';
ELSE ALTER LOGIN [$CONN_USER] WITH PASSWORD = N'$CONN_PW';
GO
ALTER SERVER ROLE ##MS_ServerStateReader## ADD MEMBER [$POOL_USER];
ALTER SERVER ROLE ##MS_ServerStateReader## ADD MEMBER [$CONN_USER];
ALTER SERVER ROLE ##MS_DatabaseConnector## ADD MEMBER [$CONN_USER];
GO
SELECT 'logins: ' + p.name + ' in ' + ISNULL((SELECT STRING_AGG(r.name, ', ') WITHIN GROUP (ORDER BY r.name) FROM sys.server_role_members m
          JOIN sys.server_principals r ON r.principal_id = m.role_principal_id WHERE m.member_principal_id = p.principal_id), 'no server role')
FROM sys.sql_logins p WHERE p.name IN (N'$POOL_USER', N'$CONN_USER') ORDER BY p.name;
SQL
    for d in "$AZ_DB" "$AZ_DB2"; do sq "$d" <<SQL
SET NOCOUNT ON;
IF USER_ID(N'$POOL_USER') IS NULL CREATE USER [$POOL_USER] FOR LOGIN [$POOL_USER];
GO
SELECT 'logins: ' + DB_NAME() + ' users ' + STRING_AGG((name + ' (' + authentication_type_desc + ')') COLLATE DATABASE_DEFAULT, ', ') WITHIN GROUP (ORDER BY name)
FROM sys.database_principals WHERE type IN ('S', 'E', 'X') AND principal_id > 4;
SQL
    done
    # the VM's identity: a user of the first database only, by SID = its client id (no lookup in Entra)
    sq "$AZ_DB" <<SQL
SET NOCOUNT ON;
IF USER_ID(N'$VM_NAME') IS NULL
BEGIN
  DECLARE @sql nvarchar(max) = N'CREATE USER [$VM_NAME] WITH SID = ' + CONVERT(nvarchar(64), CAST(CAST(N'$VM_CLIENT' AS uniqueidentifier) AS varbinary(16)), 1) + N', TYPE = E;';
  EXEC (@sql);
END
GRANT VIEW DATABASE STATE TO [$VM_NAME];
GO
SELECT 'logins: ' + name + ' (' + type_desc + ', ' + authentication_type_desc + ') in ' + DB_NAME() + ' holds ' +
  ISNULL((SELECT STRING_AGG(permission_name, ', ') FROM sys.database_permissions WHERE grantee_principal_id = principal_id AND state = 'G'), 'nothing')
FROM sys.database_principals WHERE name = N'$VM_NAME';
SQL
    echo "logins: Microsoft says a server role's membership may take up to 5 minutes to take effect"
  fi
  ;;
status)
  need_az
  echo "tag pgvigil-proof=$PGVIGIL_LAB_PROOF (the whole subscription):"
  az_ resource list --tag "pgvigil-proof=$PGVIGIL_LAB_PROOF" --query '[].[type,resourceGroup,name]' -o tsv | sed 's/^/  /'
  if [ -r "$STATE" ]; then load
    az_ sql db show -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" -n "$AZ_DB" --query '[name,status,currentServiceObjectiveName,useFreeLimit]' -o tsv 2>/dev/null | sed 's/^/  database: /' || true
    az_ sql server firewall-rule list -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" --query '[].[name,startIpAddress,endIpAddress]' -o tsv 2>/dev/null | sed 's/^/  firewall: /' || true
    if [ "${AZ_TIER:-}" = pool ]; then
      az_ sql db show -g "$PGVIGIL_LAB_AZ_GROUP" -s "$AZ_SERVER" -n "$AZ_DB2" --query '[name,status,currentServiceObjectiveName,elasticPoolName]' -o tsv 2>/dev/null | sed 's/^/  database: /' || true
      az_ vm show -g "$PGVIGIL_LAB_AZ_GROUP" -n "$VM_NAME" -d --query '[name,powerState,publicIps]' -o tsv 2>/dev/null | sed 's/^/  vm: /' || true
    fi
  fi
  ;;
down)
  need_az; load
  if [ "${AZ_TIER:-}" = pool ]; then
    if az_ vm show -g "$PGVIGIL_LAB_AZ_GROUP" -n "$VM_NAME" >/dev/null 2>&1; then
      az_ vm delete -g "$PGVIGIL_LAB_AZ_GROUP" -n "$VM_NAME" --yes; echo "deleted: VM $VM_NAME (its OS disk and NIC with it)"
    fi
    # the NIC first: a failed az vm create leaves it holding the public address, and the address cannot be deleted
    # while it is in use (az's own NIC name: <vm>VMNic)
    for r in "nic ${VM_NAME}VMNic" "public-ip $VM_NAME-ip" "nsg $VM_NAME-nsg" "vnet $VM_NAME-vnet"; do
      set -- $r
      if az_ network "$1" show -g "$PGVIGIL_LAB_AZ_GROUP" -n "$2" >/dev/null 2>&1; then az_ network "$1" delete -g "$PGVIGIL_LAB_AZ_GROUP" -n "$2"; echo "deleted: $1 $2"; fi
    done
    LEFT_VM=
    for _ in $(seq 1 12); do
      LEFT_VM=$(az_ resource list -g "$PGVIGIL_LAB_AZ_GROUP" --query "length([?starts_with(name, '$VM_NAME')])" -o tsv)
      [ "$LEFT_VM" = 0 ] && break; sleep 10
    done
    echo "read back: resources named $VM_NAME* in $PGVIGIL_LAB_AZ_GROUP $LEFT_VM"
    [ "$LEFT_VM" = 0 ] || fail "the VM's pieces are not all gone (above): the state file $STATE stays"
    rm -f "$VM_KEY" "$VM_KEY.pub"
  fi
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
