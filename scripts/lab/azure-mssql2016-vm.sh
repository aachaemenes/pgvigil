#!/usr/bin/env bash
# A SQL Server 2016 lab server for scripts/proof-mssql-2016.sh: ONE Windows VM in an Azure resource group, made from
# Microsoft's own SQL Server 2016 SP3 image with the free Developer edition (no SQL Server licence is billed for
# Developer; the Windows licence is in the VM's hourly price), reachable on TCP 1433 from ONE address and from nothing
# else. SQL Server 2016 has no Linux image, so its proof needs a Windows host.
#
# Usage: scripts/lab/azure-mssql2016-vm.sh up | door | stop | start | status | down
#   up      makes what is listed below (a resource of the same name that exists is reused, never replaced), sets the
#           server up through `az vm run-command` (never a desktop session) and prints the endpoint and nothing secret.
#   door    sets the one address the network rule admits again (the machine that runs the proofs may come back from
#           a restart with another address).
#   stop    deallocates the VM (its compute is no longer billed; its disk and its address still are).
#   start   starts a deallocated VM again (the address is static: the endpoint stays).
#   status  the VM's power state, the endpoint, the address the rule admits and every resource this script finds.
#   down    deletes every resource this script finds (by its tag, or by its name prefix in the group), waits for each
#           delete, reads the listing back (exit 0 only when 0 are left) and removes the password files.
#
# Needs: az, signed in (a sign-in error is the operator's to fix: this script never signs in and never switches the
# account), od, and
#   PGVIGIL_AZ_GROUP     the resource group, which must exist (this script never creates or deletes a group, except
#                        Azure's own NetworkWatcherRG under the rule below)
#   PGVIGIL_AZ_LOCATION  its region
#   PGVIGIL_LAB_ALLOW    (up, door) the ONE public IPv4 address admitted to 1433, written a.b.c.d; a range, 0.0.0.0,
#                        a private, shared, loopback or link-local address is refused
# Settings:
#   PGVIGIL_AZ_SIZE      default Standard_B2als_v2 (2 vCPU, 4 GB: the smallest x64 size with the memory Windows and
#                        SQL Server need side by side; an ARM size cannot run the image)
#   PGVIGIL_AZ_IMAGE     default MicrosoftSQLServer:sql2016sp3-ws2019:sqldev:13.2.250114 (pinned: a Developer SKU is
#                        required, the script refuses any other SKU, so a licence-billed edition is never taken)
#   PGVIGIL_LAB_TAG      default pgvigil-proof=mssql2016-<prefix>, on every resource it makes; `down` finds by it
#   PGVIGIL_LAB_PREFIX   default pgv16 (2 to 11 lower-case letters and digits: the Windows computer name <prefix>-sql
#                        has 15 characters at most): the resources are <prefix>-nsg, -vnet, -ip, -nic, -vm, -osdisk
#   PGVIGIL_LAB_DIR      default .lab at the repository root: the password files, mode 600. Inside a git work tree
#                        the script refuses a folder git does not ignore (a password file must never be committed)
#
# What it makes, all tagged: a network security group whose only inbound rule admits TCP 1433 from PGVIGIL_LAB_ALLOW
# (Azure's default rules deny the rest of the internet: no RDP, no WinRM); a virtual network with one subnet behind
# that group; a static Standard public address; a network interface; the VM (Windows Server 2019, SQL Server 2016
# SP3 Developer, a StandardSSD OS disk deleted with the VM, automatic patching and updates off so that no restart
# comes in the middle of a proof). Where Microsoft.Compute or Microsoft.Network is not registered in the
# subscription, `up` registers it first (free, subscription-wide, needed for any VM) and says so; `down` leaves the
# registration (other resources may use it). Where Azure creates its Network Watcher for the region when this
# script's virtual network is made (resource group NetworkWatcherRG), `up` records that the group was not there
# before, and `down` deletes that group only then and only while it holds nothing but NetworkWatcher_<region>.
# On the server, through one run-command as the VM's local system account: mixed-mode authentication; TCP/IP on,
# port 1433 static; a Windows firewall rule for TCP 1433 (the network security group is what admits only one
# address); the login sa enabled with a password made here; max server memory 2560 MB (Windows keeps the rest of the
# 4 GB); SQL Server Agent set to start automatically and started. The engine is restarted twice for this (once in
# single-user mode, where the local administrators are sysadmin, to set sa; once back in multi-user mode).
#
# Passwords: one per resource, made here at run time from /dev/urandom (never a word a person chose): the VM's local
# administrator <dir>/<prefix>-admin.pw and the sa password <dir>/<prefix>-sa.pw, mode 600, read by az through its
# @file form and by the proof from the file; never on a command line, in the output or in a log. The run-command's
# script, which carries the sa password, is written to <dir> with mode 600 and removed right after the call (Azure
# keeps its own copy on the VM until the VM is deleted). <dir>/<prefix>.addr holds the endpoint (not secret).
#
# Expected (written before the first run):
#  up:     each make step prints its name; the run-command prints 'SETUP OK 13.0.<build> <edition>' with the edition
#          'Developer Edition (64-bit)' and 'sa can log in over TCP'; the last line is
#          'azure-mssql2016-vm: UP <address>:1433 (admits <allow> only; sa password in <dir>/<prefix>-sa.pw)', exit 0.
#          A refusal by the subscription (quota, the image, the size) prints Azure's own text and exits 1 with what it
#          made so far left for `down`.
#  door:   'azure-mssql2016-vm: DOOR 1433 admits <allow> only', exit 0.
#  status: the power state ('VM running' or 'VM deallocated'), the endpoint, the rule's source, every resource found.
#  down:   each resource's delete; then 'azure-mssql2016-vm: DOWN (0 resources left by tag <tag> or prefix <prefix>-)'
#          and exit 0; any resource left is listed by name and the exit code is 1.
set -euo pipefail
set +x   # a trace would print the passwords
cd "$(dirname "$0")/../.."
command -v az >/dev/null || { echo "FAIL: az is not on this machine" >&2; exit 1; }
command -v od >/dev/null || { echo "FAIL: od is not on this machine" >&2; exit 1; }
: "${PGVIGIL_AZ_GROUP:?the resource group (it must exist)}"
: "${PGVIGIL_AZ_LOCATION:?the region of the resource group}"
CMD=${1:-}
case $CMD in up|door|stop|start|status|down) ;; *) echo "usage: $0 up | door | stop | start | status | down" >&2; exit 2 ;; esac
G=$PGVIGIL_AZ_GROUP; LOC=$PGVIGIL_AZ_LOCATION
SIZE=${PGVIGIL_AZ_SIZE:-Standard_B2als_v2}
IMAGE=${PGVIGIL_AZ_IMAGE:-MicrosoftSQLServer:sql2016sp3-ws2019:sqldev:13.2.250114}
PFX=${PGVIGIL_LAB_PREFIX:-pgv16}
TAG=${PGVIGIL_LAB_TAG:-pgvigil-proof=mssql2016-$PFX}
LAB=${PGVIGIL_LAB_DIR:-.lab}
[[ $TAG =~ ^[A-Za-z0-9._-]+=[A-Za-z0-9._-]+$ ]] || { echo "FAIL: PGVIGIL_LAB_TAG is name=value (letters, digits, . _ -): $TAG" >&2; exit 1; }
[[ $PFX =~ ^[a-z][a-z0-9]{1,10}$ ]] || { echo "FAIL: PGVIGIL_LAB_PREFIX is 2 to 11 lower-case letters and digits, a letter first: $PFX" >&2; exit 1; }
TAGK=${TAG%%=*}; TAGV=${TAG#*=}
NSG=$PFX-nsg; VNET=$PFX-vnet; IP=$PFX-ip; NIC=$PFX-nic; VM=$PFX-vm; DISK=$PFX-osdisk; RULE=allow-1433-one
mkdir -p "$LAB"; chmod 700 "$LAB"
ADMIN_PW=$LAB/$PFX-admin.pw; SA_PW=$LAB/$PFX-sa.pw; ADDR_FILE=$LAB/$PFX.addr; NW_MARK=$LAB/$PFX.networkwatcher-made; SETUP=$LAB/$PFX-setup.ps1
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git check-ignore -q "$SA_PW" || { echo "FAIL: git does not ignore $LAB (add it to .gitignore or .git/info/exclude): a password file must never be committed" >&2; exit 1; }
fi
trap 'rm -f "$SETUP"' EXIT

# the one address admitted: a public IPv4 address, written as one
allow() {
  local a=${PGVIGIL_LAB_ALLOW:-} o1 o2
  [ -n "$a" ] || { echo "FAIL: PGVIGIL_LAB_ALLOW is not set (the one public IPv4 address admitted to 1433)" >&2; return 1; }
  local oct='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
  [[ $a =~ ^$oct\.$oct\.$oct\.$oct$ ]] || { echo "FAIL: PGVIGIL_LAB_ALLOW is one address a.b.c.d (no leading zeros), never a range or a name: $a" >&2; return 1; }
  o1=${BASH_REMATCH[1]}; o2=${BASH_REMATCH[2]}
  if [ "$o1" -eq 0 ] || [ "$o1" -eq 10 ] || [ "$o1" -eq 127 ] || [ "$o1" -ge 224 ] || { [ "$o1" -eq 169 ] && [ "$o2" -eq 254 ]; } \
     || { [ "$o1" -eq 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; } || { [ "$o1" -eq 192 ] && [ "$o2" -eq 168 ]; } \
     || { [ "$o1" -eq 100 ] && [ "$o2" -ge 64 ] && [ "$o2" -le 127 ]; }; then
    echo "FAIL: PGVIGIL_LAB_ALLOW is not a public address: $a" >&2; return 1
  fi
  printf '%s' "$a"
}
# the rule's source as one line, and the check that it is exactly the one address
rulesrc() { az network nsg rule show -g "$G" --nsg-name "$NSG" -n "$RULE" --query "join(',', [sourceAddressPrefix || '', join(',', sourceAddressPrefixes || \`[]\`)])" -o tsv; }
ruleis() { local got; got=$(rulesrc); case $got in "$1,"|",$1"|"$1") return 0 ;; esac; echo "FAIL: the rule reads source '$got' (want $1 only)" >&2; return 1; }
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
newpw() { [ -s "$1" ] && return 0; ( umask 077; pw > "$1" ); chmod 600 "$1"; }
exists() { az "$@" --query id -o tsv >/dev/null 2>&1; }
# every resource this script finds: by its tag, and by its name prefix (a resource made before a failed tag step)
found() {
  local out
  out=$(az resource list -g "$G" --query "[?tags.\"$TAGK\" == '$TAGV' || starts_with(name, '$PFX-')].[type,name,id]" -o tsv) \
    || { echo "FAIL: the resource listing of the group $G" >&2; return 1; }
  printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | sort -u
}

case $CMD in
up)
  ALLOW=$(allow)
  IFS=: read -r ipub _ isku _ <<<"$IMAGE"
  [ "${ipub,,}" = microsoftsqlserver ] && [ "${isku,,}" = sqldev ] || { echo "FAIL: PGVIGIL_AZ_IMAGE is not Microsoft's Developer SKU (a licence-billed edition is never taken): $IMAGE" >&2; exit 1; }
  [ "$(az group show -n "$G" --query location -o tsv)" = "$LOC" ] || { echo "FAIL: the group $G is not in $LOC (or does not exist; this script never creates one)" >&2; exit 1; }
  for ns in Microsoft.Network Microsoft.Compute; do
    if [ "$(az provider show -n "$ns" --query registrationState -o tsv)" != Registered ]; then
      echo "register: $ns (it was not registered in this subscription)"
      az provider register -n "$ns" --wait >/dev/null
      [ "$(az provider show -n "$ns" --query registrationState -o tsv)" = Registered ] || { echo "FAIL: $ns did not register" >&2; exit 1; }
    fi
  done
  rm -f "$NW_MARK.before-absent"
  if ! exists network vnet show -g "$G" -n "$VNET" && ! az group show -n NetworkWatcherRG >/dev/null 2>&1; then : > "$NW_MARK.before-absent"; fi
  newpw "$ADMIN_PW"; newpw "$SA_PW"
  if ! exists network nsg show -g "$G" -n "$NSG"; then
    echo "make: network security group $NSG"
    az network nsg create -g "$G" -n "$NSG" -l "$LOC" --tags "$TAGK=$TAGV" >/dev/null
  fi
  echo "set: rule $RULE (TCP 1433 from $ALLOW only)"
  az network nsg rule create -g "$G" --nsg-name "$NSG" -n "$RULE" --priority 100 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes "$ALLOW" --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 1433 >/dev/null
  ruleis "$ALLOW"
  if ! exists network vnet show -g "$G" -n "$VNET"; then
    echo "make: virtual network $VNET"
    az network vnet create -g "$G" -n "$VNET" -l "$LOC" --address-prefixes 10.16.0.0/24 --subnet-name default --subnet-prefixes 10.16.0.0/27 \
      --network-security-group "$NSG" --tags "$TAGK=$TAGV" >/dev/null
  fi
  if [ -f "$NW_MARK.before-absent" ]; then
    if az group show -n NetworkWatcherRG >/dev/null 2>&1; then : > "$NW_MARK"; echo "note: Azure made NetworkWatcherRG with the first virtual network; down deletes it"; fi
    rm -f "$NW_MARK.before-absent"
  fi
  if ! exists network public-ip show -g "$G" -n "$IP"; then
    echo "make: public address $IP"
    az network public-ip create -g "$G" -n "$IP" -l "$LOC" --sku Standard --allocation-method Static --version IPv4 --tags "$TAGK=$TAGV" >/dev/null
  fi
  if ! exists network nic show -g "$G" -n "$NIC"; then
    echo "make: network interface $NIC"
    az network nic create -g "$G" -n "$NIC" -l "$LOC" --vnet-name "$VNET" --subnet default --public-ip-address "$IP" --network-security-group "$NSG" \
      --tags "$TAGK=$TAGV" >/dev/null
  fi
  if ! exists vm show -g "$G" -n "$VM"; then
    echo "make: VM $VM ($SIZE, $IMAGE)"
    az vm create -g "$G" -n "$VM" -l "$LOC" --image "$IMAGE" --size "$SIZE" --nics "$NIC" --admin-username pgvadmin --admin-password "@$ADMIN_PW" \
      --os-disk-name "$DISK" --storage-sku StandardSSD_LRS --os-disk-delete-option Delete --enable-auto-update false --patch-mode Manual \
      --computer-name "$PFX-sql" --tags "$TAGK=$TAGV" -o none \
      || { echo "FAIL: the VM was not made (Azure's text above: a quota, the image or the size); what was made so far stays for down" >&2; exit 1; }
  fi
  az disk update -g "$G" -n "$DISK" --set "tags.$TAGK=$TAGV" -o none
  [ "$(az vm get-instance-view -g "$G" -n "$VM" --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" -o tsv)" = "VM running" ] \
    || { echo "start: VM $VM"; az vm start -g "$G" -n "$VM" -o none; }
  # the server's setup: a script with the sa password, mode 600 here, sent once and removed
  ( umask 077
    {
      printf '$sapw = '\''%s'\''\n' "$(cat "$SA_PW")"
      cat <<'PS1'
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw 'run-command started a 32-bit PowerShell: the registry reads below need 64-bit' }
$svc = $null
foreach ($try in 1..60) { $svc = Get-Service MSSQLSERVER -ErrorAction SilentlyContinue; if ($svc -and $svc.Status -eq 'Running') { break }; Start-Sleep -Seconds 10 }
if (-not $svc -or $svc.Status -ne 'Running') { throw 'the MSSQLSERVER service is not running 10 minutes after the setup started' }
$inst = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').MSSQLSERVER
$root = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$inst\MSSQLServer"
Set-ItemProperty -Path $root -Name LoginMode -Value 2 -Type DWord
Set-ItemProperty -Path "$root\SuperSocketNetLib\Tcp" -Name Enabled -Value 1 -Type DWord
Set-ItemProperty -Path "$root\SuperSocketNetLib\Tcp\IPAll" -Name TcpPort -Value '1433'
Set-ItemProperty -Path "$root\SuperSocketNetLib\Tcp\IPAll" -Name TcpDynamicPorts -Value ''
if (-not (Get-NetFirewallRule -DisplayName 'SQL Server 1433' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName 'SQL Server 1433' -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow | Out-Null
}
function Invoke-LabSql([string]$connStr, [string]$sql) {
  $conn = New-Object System.Data.SqlClient.SqlConnection $connStr
  $conn.Open()
  try { $cmd = $conn.CreateCommand(); $cmd.CommandTimeout = 120; $cmd.CommandText = $sql; return $cmd.ExecuteScalar() } finally { $conn.Close() }
}
Stop-Service SQLSERVERAGENT -Force -ErrorAction SilentlyContinue
Stop-Service MSSQLSERVER -Force
& net start MSSQLSERVER '/mSQLCMD' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "the engine did not start in single-user mode (net start exit $LASTEXITCODE)" }
$single = 'Server=.;Integrated Security=SSPI;Application Name=SQLCMD;Connect Timeout=30'
$set = $null
foreach ($try in 1..30) { try { $set = Invoke-LabSql $single ("ALTER LOGIN sa WITH PASSWORD = N'" + $sapw + "', CHECK_POLICY = OFF; ALTER LOGIN sa ENABLE; SELECT 1;"); break } catch { Start-Sleep -Seconds 2 } }
if ($set -ne 1) { throw 'sa could not be set in single-user mode' }
Stop-Service MSSQLSERVER -Force
Start-Service MSSQLSERVER
Set-Service SQLSERVERAGENT -StartupType Automatic
Start-Service SQLSERVERAGENT
$tcp = 'Server=tcp:127.0.0.1,1433;User ID=sa;Password=' + $sapw + ';Connect Timeout=30;Encrypt=True;TrustServerCertificate=True'
$ver = $null
foreach ($try in 1..30) { try { $ver = Invoke-LabSql $tcp "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'max server memory (MB)', 2560; RECONFIGURE; EXEC sp_configure 'show advanced options', 0; RECONFIGURE; SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(40)) + N' ' + CAST(SERVERPROPERTY('Edition') AS nvarchar(80));"; break } catch { Start-Sleep -Seconds 2 } }
if (-not $ver) { throw 'sa cannot log in over TCP 1433' }
"SETUP OK $ver"
'sa can log in over TCP'
PS1
    } > "$SETUP" )
  chmod 600 "$SETUP"
  echo "setup: the server, through run-command (a few minutes)"
  rc=0; out=$(az vm run-command invoke -g "$G" -n "$VM" --command-id RunPowerShellScript --scripts "@$SETUP" --query 'value[].message' -o tsv 2>&1) || rc=$?
  rm -f "$SETUP"
  pwv=$(cat "$SA_PW"); out=${out//"$pwv"/<hidden>}
  { printf '%s\n' "$out" | grep -v '^[[:space:]]*$' || true; } | sed 's/^/  /'
  [ $rc = 0 ] && printf '%s\n' "$out" | grep -q '^SETUP OK 13\.0\.' && printf '%s\n' "$out" | grep -q 'Developer Edition' \
    || { echo "FAIL: the server's setup (run-command exit $rc; its output above)" >&2; exit 1; }
  ADDR=$(az network public-ip show -g "$G" -n "$IP" --query ipAddress -o tsv)
  printf '%s:1433\n' "$ADDR" > "$ADDR_FILE"
  echo "azure-mssql2016-vm: UP $ADDR:1433 (admits $ALLOW only; sa password in $SA_PW)"
  ;;
door)
  ALLOW=$(allow)
  az network nsg rule update -g "$G" --nsg-name "$NSG" -n "$RULE" --source-address-prefixes "$ALLOW" -o none
  ruleis "$ALLOW"
  echo "azure-mssql2016-vm: DOOR 1433 admits $ALLOW only"
  ;;
stop)
  az vm deallocate -g "$G" -n "$VM" -o none
  echo "azure-mssql2016-vm: STOPPED ($(az vm get-instance-view -g "$G" -n "$VM" --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" -o tsv))"
  ;;
start)
  az vm start -g "$G" -n "$VM" -o none
  echo "azure-mssql2016-vm: STARTED ($(az vm get-instance-view -g "$G" -n "$VM" --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" -o tsv))"
  ;;
status)
  if exists vm show -g "$G" -n "$VM"; then
    echo "power: $(az vm get-instance-view -g "$G" -n "$VM" --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" -o tsv)"
  else echo "power: no VM $VM"; fi
  exists network public-ip show -g "$G" -n "$IP" && echo "endpoint: $(az network public-ip show -g "$G" -n "$IP" --query ipAddress -o tsv):1433"
  exists network nsg show -g "$G" -n "$NSG" && echo "admits: $(rulesrc 2>/dev/null || echo 'no rule')"
  echo "resources (tag $TAGK=$TAGV or prefix $PFX-):"; found | awk -F'\t' '{ print "  " $1 " " $2 }'
  ;;
down)
  # dependency order: the VM (its OS disk goes with it), then its interface, then the disk if one is left, the
  # address, the network and the security group
  for type in Microsoft.Compute/virtualMachines Microsoft.Network/networkInterfaces Microsoft.Compute/disks Microsoft.Network/publicIPAddresses \
              Microsoft.Network/virtualNetworks Microsoft.Network/networkSecurityGroups; do
    found | awk -F'\t' -v t="$type" 'tolower($1) == tolower(t) { print $2 "\t" $3 }' | while IFS=$'\t' read -r name id; do
      echo "delete: $type $name"
      az resource delete --ids "$id" -o none </dev/null || echo "  the delete of $name failed (listed below if it is still there)" >&2
    done
  done
  # anything else this script finds (a type not in the list above), after the known ones
  found | awk -F'\t' '{ print $2 "\t" $3 }' | while IFS=$'\t' read -r name id; do
    echo "delete: $name"; az resource delete --ids "$id" -o none </dev/null || echo "  the delete of $name failed" >&2
  done
  if [ -f "$NW_MARK" ]; then
    nw=$(az resource list -g NetworkWatcherRG --query "[].name" -o tsv 2>/dev/null || true)
    if [ -z "$nw" ] || [ "$nw" = "NetworkWatcher_$LOC" ]; then
      echo "delete: resource group NetworkWatcherRG (Azure made it with this script's virtual network; it holds ${nw:-nothing})"
      az group delete -n NetworkWatcherRG --yes -o none && rm -f "$NW_MARK" || echo "  the delete of NetworkWatcherRG failed" >&2
    else
      echo "kept: resource group NetworkWatcherRG holds more than this region's watcher now ($(printf '%s' "$nw" | tr '\n' ' ')): not deleted" >&2
    fi
  fi
  left=$(found) || { echo "azure-mssql2016-vm: DOWN NOT READ BACK (the listing failed)" >&2; exit 1; }
  if [ -n "$left" ]; then
    printf '%s\n' "$left" | awk -F'\t' '{ print "LEFT: " $1 " " $2 }'
    echo "azure-mssql2016-vm: DOWN FAILED ($(printf '%s\n' "$left" | wc -l) resources left by tag $TAGK=$TAGV or prefix $PFX-)"
    exit 1
  fi
  rm -f "$ADMIN_PW" "$SA_PW" "$ADDR_FILE" "$SETUP"
  echo "azure-mssql2016-vm: DOWN (0 resources left by tag $TAGK=$TAGV or prefix $PFX-)"
  ;;
esac
