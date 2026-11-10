#!/usr/bin/env bash
# Proof of the DBADash door (task 55): a real DBADash repository, built by DBADash's own service from its release zip,
# read by internal/dbadash with a read-only login, the rows compared with the repository's own procedure output.
#
# Needs: docker with the SQL Server sandbox container (PGVIGIL_MSSQL_CONTAINER, default mssql-sandbox; this machine
# reaches it on localhost:1433, the Windows guest as mssql-sandbox,1433), its sa password in MSSQL_SA_PASSWORD, the
# Windows sandbox over `ssh winsandbox` with its own SQL Server (the monitored instance; Windows authentication for the
# SSH user) and the share PGVIGIL_WIN_SHARE (default ~/winsandbox/shared = \\host.lan\Data in the guest), go, psql, and
# python3. ADMIN_DSN is a superuser connection to the sandbox PostgreSQL (default postgres://postgres@localhost:5432/
# postgres): the proof makes its own pgvigil repository database there (random suffix) and drops it at the end.
#   PGVIGIL_DBADASH_ZIP   the DBADash release zip (default: DBADash_4.24.1.zip from the trimble-oss/dba-dash release,
#                         fetched with gh into the share once)
#   PGVIGIL_DBADASH_KEEP  1 keeps the DBADash repository database and the login (default: both dropped at the end)
# Nothing that exists before the run is touched: the DBADash database, the login and the pgvigil database are this run's
# own (random suffix); in the guest the DBADash folder C:\pgv-dbadash is the proof's (kept for re-runs, its service config
# removed) and its service runs as a console process for SVC_SECS seconds, never installed as a Windows service; only a
# process started from that folder is ever stopped (another DBADash install in the guest is left alone).
#
# Expected (written before the first run):
#  A. the guest: DBADashConfig SetDestination and Add print "Complete"; after the console run, on every path (a finally, and
#     this script's own trap over ssh when the guest step was cut), the service config (with sa's password) is removed and
#     no file under C:\pgv-dbadash holds that password; the console service creates DBADash_pgv<suf> and
#     collects WINSANDBOX: dbo.Instances holds 1 active row (Instance = the guest's @@SERVERNAME), dbo.DBVersionHistory
#     a version starting 4.24.
#  B. the login pgv_ddro_<suf> gets SELECT on dbo.Instances, dbo.Summary, dbo.CollectionDates and dbo.DBVersionHistory
#     only; as that login an INSERT into dbo.Settings and EXEC dbo.Summary_Upd are both refused (permission errors);
#     dbo.Summary_Get @ForceRefresh = 1 run as sa fills DBADash's cache (1 row).
#  C. one read (go test -run TestLive) of three repositories: sandbox -> ok, instances=1, statuses 25 or 26 (AlertStatus
#     is NULL on an instance without SQL Agent alert history); refused (the login with a wrong password) -> not read,
#     reason holding "Login failed"; unreachable (port 1) -> not read, reason holding "connection refused".
#  D. the comparison: every one of the 26 status columns of dbo.Summary_Get's output (as sa, the cache refreshed in B)
#     equals the stored code in pgvigil.dbadash_summary for the instance, the RefreshDate equals refreshed_at, and
#     dbadash_statuses() returns 26 rows whose word matches DBADash's enum (1 Critical ... 4 OK); dbadash_fleet()'s
#     critical count equals the count of 1s in the procedure's row.
#  E. a status change: as sa, dbo.Summary's DriveStatus set to 1 (Critical) on the sandbox's own cache; a second read;
#     dbadash_changes() over the last 10 minutes returns exactly one row: Drive Space, was OK, now Critical; the history
#     holds 2 rows for the instance (the first read and the change). A third read with nothing changed adds none (F).
#  F. the folder: dbadash_repositories() stores sandbox ok, refused and unreachable 'not read' with their reasons ('Login
#     failed', 'connection refused'); a read with a configuration that drops 'unreachable' leaves 2 rows (it leaves the tree)
#     and, nothing having changed, the history still holds 2 rows; a read with NO dbadash: list leaves dbadash_repositories()
#     empty and dbadash_instance() of the sandbox instance empty (the last repository leaves the tree).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/share/mise/shims:$PATH"
CT="${PGVIGIL_MSSQL_CONTAINER:-mssql-sandbox}"; SHARE="${PGVIGIL_WIN_SHARE:-$HOME/winsandbox/shared}"
ADMIN_DSN="${ADMIN_DSN:-postgres://postgres@localhost:5432/postgres}"
SUF="$(date +%s | tail -c 6)$RANDOM"; DDB="DBADash_pgv$SUF"; RO="pgv_ddro_$SUF"; PGDB="pgv_dd_$SUF"
SVC_SECS="${SVC_SECS:-150}"
RO_PW="Ro$RANDOM$RANDOM#x$RANDOM"
WORK=$(mktemp -d); GUEST="$SHARE/pgv-dbadash"; mkdir -p "$GUEST"
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -n "${MSSQL_SA_PASSWORD:-}" ]] || fail "MSSQL_SA_PASSWORD is not set (the SQL Server sandbox's sa password)"
sq() { docker exec -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -W -h -1 -s $'\t' -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
sqh() { docker exec -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -W -s $'\t' -d "$2" -Q "SET NOCOUNT ON; $1"; }
sqro() { docker exec -e SQLCMDPASSWORD="$RO_PW" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -U "$RO" -C -W -h -1 -d "$DDB" -Q "SET NOCOUNT ON; $1" 2>&1 || true; }
pq() { psql "$(dsn_db "$PGDB")" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
dsn_db() { python3 -c 'import sys,urllib.parse as u; p=u.urlsplit(sys.argv[1]); print(u.urlunsplit(p._replace(path="/"+sys.argv[2])))' "$ADMIN_DSN" "$1"; }
urlq() { python3 -c 'import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe=""))' "$1"; }
cleanup() {
  if [[ -f "$GUEST/proof-dbadash.ps1" ]]; then
    # the guest's Finish on every path (an ssh drop mid-run would otherwise leave the process and sa's password there)
    printf '%s' "$MSSQL_SA_PASSWORD" > "$GUEST/sa.txt"
    fin=$(timeout 120 ssh -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 winsandbox "powershell -NoProfile -ExecutionPolicy Bypass -File \\\\host.lan\\Data\\pgv-dbadash\\proof-dbadash.ps1 -Cleanup" 2>/dev/null | tr -d '\r' | grep -E '^(ok|FAIL|note)' || true)
    echo "$fin"
    echo "$fin" | grep -qE '^(ok   the service config removed|note)' || echo "WARN: the guest's cleanup did not confirm the config's removal: check C:\\pgv-dbadash for ServiceConfig*.json by hand" >&2
  fi
  rm -f "$GUEST/sa.txt" "$GUEST/proof-dbadash.ps1"; rm -rf "$WORK"
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || true
  if [[ "${PGVIGIL_DBADASH_KEEP:-}" != 1 ]]; then
    sq "IF DB_ID('$DDB') IS NOT NULL BEGIN ALTER DATABASE [$DDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DDB]; END; IF SUSER_ID('$RO') IS NOT NULL DROP LOGIN [$RO];" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
ssh -o ConnectTimeout=10 winsandbox 'echo up' >/dev/null 2>&1 || fail "the Windows sandbox does not answer on ssh winsandbox (winsandbox on)"
sq "SELECT 1" >/dev/null || fail "the SQL Server sandbox ($CT) does not answer as sa"

echo "== A. DBADash builds its repository $DDB on the SQL Server sandbox, monitoring the guest's own SQL Server =="
ZIP="${PGVIGIL_DBADASH_ZIP:-$GUEST/DBADash_4.24.1.zip}"
if [[ ! -f "$ZIP" ]]; then gh release download 4.24.1 -R trimble-oss/dba-dash -p 'DBADash_4.24.1.zip' -D "$GUEST" --clobber; ZIP="$GUEST/DBADash_4.24.1.zip"; fi
[[ "$(dirname "$ZIP")" == "$GUEST" ]] || cp "$ZIP" "$GUEST/"
ZIPNAME=$(basename "$ZIP")
printf '%s' "$MSSQL_SA_PASSWORD" > "$GUEST/sa.txt"; chmod 600 "$GUEST/sa.txt"
cat > "$GUEST/proof-dbadash.ps1" <<'PS1'
param([string]$Db, [string]$Zip, [int]$RunSeconds, [switch]$Cleanup)
$ErrorActionPreference = 'Stop'
$share = '\\host.lan\Data\pgv-dbadash'
$dst = 'C:\pgv-dbadash'
$pw = if (Test-Path "$share\sa.txt") { (Get-Content "$share\sa.txt" -Raw).Trim() } else { '' }
# Finish runs on every path (the finally below, and -Cleanup from the proof's own trap): the proof's console process
# stopped, the service config and its backups (sa's password) removed, and no file under the folder holding the password.
# Its verdict is $script:finishOk (a function's text output is its return value, so a caller that tested the call would
# swallow the ok / FAIL lines)
$script:finishOk = $true
function Finish {
  try {
    Get-Process DBADashService -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq "$dst\DBADashService.exe" } | Stop-Process -Force
    if (-not (Test-Path $dst)) { return }
    Get-ChildItem $dst -Recurse -File -Filter '*ServiceConfig*' -ErrorAction SilentlyContinue | Remove-Item -Force
    if (-not $pw) { 'note no sa.txt on the share: the password check was skipped'; return }
    $left = @(Get-ChildItem $dst -Recurse -File -Include *.json, *.out, *.err, *.txt, *.log, *.bak -ErrorAction SilentlyContinue | Select-String -SimpleMatch -Pattern $pw -List)
    if ($left.Count) { "FAIL the sa password is still in $($left[0].Path)"; $script:finishOk = $false; return }
    'ok   the service config removed; no file under the folder holds the sa password'
  } catch {
    "FAIL Finish: $($_.Exception.Message)"
    $script:finishOk = $false
  }
}
if ($Cleanup) { Finish; if ($script:finishOk) { exit 0 } else { exit 1 } }
if (-not $pw) { 'FAIL no sa.txt on the share'; exit 1 }
$code = 0
try {
  if (-not (Test-Path "$dst\DBADashService.exe")) { Expand-Archive "$share\$Zip" $dst -Force; 'ok   unzipped' }
  Set-Location $dst
  Get-Process DBADashService -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq "$dst\DBADashService.exe" } | Stop-Process -Force
  $a = & .\DBADashConfig.exe -a SetDestination -c "Data Source=mssql-sandbox,1433;Initial Catalog=$Db;User ID=sa;Password=$pw;Encrypt=True;Trust Server Certificate=True" 2>&1 | Out-String
  if ($a -notmatch 'Complete') { throw "SetDestination: $a" }
  $b = & .\DBADashConfig.exe -a Add -c 'Data Source=localhost;Integrated Security=True;Encrypt=True;Trust Server Certificate=True' --Replace 2>&1 | Out-String
  if ($b -notmatch 'Complete') { throw "Add: $b" }
  'ok   DBADashConfig SetDestination and Add: Complete'
  $p = Start-Process -FilePath "$dst\DBADashService.exe" -WorkingDirectory $dst -PassThru -WindowStyle Hidden -RedirectStandardOutput "$dst\svc.out" -RedirectStandardError "$dst\svc.err"
  Start-Sleep -Seconds $RunSeconds
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  "ok   the DBADash service ran $RunSeconds s as a console process"
  $errs = @(Select-String -Path "$dst\svc.out" -Pattern '\[ERR\]|\[FTL\]' | Select-Object -First 5)
  foreach ($e in $errs) { "note $($e.Line)" }
} catch {
  "FAIL $($_.Exception.Message)"
  $code = 1
} finally {
  Finish
  if (-not $script:finishOk) { $code = 1 }
}
exit $code
PS1
out=$(ssh winsandbox "powershell -NoProfile -ExecutionPolicy Bypass -File \\\\host.lan\\Data\\pgv-dbadash\\proof-dbadash.ps1 -Db $DDB -Zip $ZIPNAME -RunSeconds $SVC_SECS" 2>&1 | tr -d '\r' | grep -E '^(ok|FAIL|note)' || true)
echo "$out"
echo "$out" | grep -q '^FAIL' && fail "the guest step failed"
echo "$out" | grep -q '^ok   the service config removed' || fail "the guest step did not confirm the config's removal"
rm -f "$GUEST/sa.txt"   # the trap writes it again for its own -Cleanup call
n=$(sq "SELECT COUNT(*) FROM dbo.Instances WHERE IsActive = 1 AND ISNULL(EngineEdition, 0) <> 5" "$DDB")
ver=$(sq "SELECT TOP (1) Version FROM dbo.DBVersionHistory ORDER BY DeployDate DESC" "$DDB")
inst=$(sq "SELECT TOP (1) Instance FROM dbo.Instances WHERE IsActive = 1" "$DDB")
[[ "$n" == 1 && "$ver" == 4.24* ]] || fail "repository $DDB: $n active instance(s), version '$ver' (want 1 and 4.24*)"
echo "ok   A: $DDB built by DBADash $ver; 1 active instance ($inst)"

echo "== B. the read-only login and DBADash's own Summary refresh =="
sq "CREATE LOGIN [$RO] WITH PASSWORD = '$RO_PW', CHECK_POLICY = OFF; USE [$DDB]; CREATE USER [$RO] FOR LOGIN [$RO];
    GRANT SELECT ON dbo.Instances TO [$RO]; GRANT SELECT ON dbo.Summary TO [$RO]; GRANT SELECT ON dbo.CollectionDates TO [$RO]; GRANT SELECT ON dbo.DBVersionHistory TO [$RO];" >/dev/null
w1=$(sqro "INSERT INTO dbo.Settings (SettingName, SettingValue) VALUES ('pgvigil_proof', 1)")
w2=$(sqro "EXEC dbo.Summary_Upd")
echo "$w1" | grep -qi 'permission was denied' || fail "the read-only login could INSERT into dbo.Settings: $w1"
echo "$w2" | grep -qi 'permission was denied' || fail "the read-only login could EXEC dbo.Summary_Upd: $w2"
sq "EXEC dbo.Summary_Get @ForceRefresh = 1" "$DDB" >/dev/null
# this run's own repository: the cache is kept a day, so D's un-forced dbo.Summary_Get returns the same cache, never a refresh
sq "UPDATE dbo.Settings SET SettingValue = '86400' WHERE SettingName = 'SummaryCacheDurationSec'" "$DDB" >/dev/null
ns=$(sq "SELECT COUNT(*) FROM dbo.Summary" "$DDB")
[[ "$ns" == 1 ]] || fail "dbo.Summary holds $ns row(s) after the refresh (want 1)"
echo "ok   B: $RO reads only (INSERT and EXEC dbo.Summary_Upd refused); dbo.Summary_Get @ForceRefresh = 1 as sa: 1 row"

echo "== C. one read of three repositories into a fresh pgvigil repository $PGDB =="
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
cat > "$WORK/pgvigil.yaml" <<EOF
repository:
  dsn: $(dsn_db "$PGDB")
dbadash:
  - name: sandbox
    dsn: env:PGV_DD_OK
  - name: refused
    dsn: env:PGV_DD_BAD
  - name: unreachable
    dsn: "sqlserver://$RO@127.0.0.1:1?database=$DDB&dial+timeout=3"
EOF
export PGV_DD_OK="sqlserver://$RO:$(urlq "$RO_PW")@localhost:1433?database=$DDB&encrypt=true&TrustServerCertificate=true"
export PGV_DD_BAD="sqlserver://$RO:wrong$RANDOM@localhost:1433?database=$DDB&encrypt=true&TrustServerCertificate=true"
go run ./cmd/pgvigil migrate -config "$WORK/pgvigil.yaml" >/dev/null 2>&1 || fail "migrate"
live() { PGVIGIL_DBADASH_CONFIG="$1" PGVIGIL_DBADASH_DUMP="$WORK/dump.json" go test -count=1 -run '^TestLive$' -v ./internal/dbadash 2>/dev/null | grep '^dbadash ' || true; }
res=$(live "$WORK/pgvigil.yaml"); echo "$res"
echo "$res" | grep -qE '^dbadash sandbox ok instances=1 statuses=2[56] ' || fail "sandbox not read as expected"
echo "$res" | grep -qE '^dbadash refused not read .*Login failed' || fail "refused: no 'Login failed' reason"
echo "$res" | grep -qE '^dbadash unreachable not read .*connection refused' || fail "unreachable: no 'connection refused' reason"
echo "ok   C: sandbox read; refused and unreachable stored as 'not read' with the reason"

echo "== D. the stored statuses against dbo.Summary_Get's own output =="
sqh "EXEC dbo.Summary_Get" "$DDB" > "$WORK/proc.tsv"
pq "SELECT instance_id, statuses::text, to_char(refreshed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS') FROM pgvigil.dbadash_summary WHERE repository = 'sandbox'" > "$WORK/stored.txt"
pq "SELECT status_key || '=' || coalesce(code::text, '') || '=' || coalesce(word, '') FROM pgvigil.dbadash_statuses('sandbox', (SELECT min(instance_id) FROM pgvigil.dbadash_summary WHERE repository = 'sandbox'))" > "$WORK/words.txt"
crit=$(pq "SELECT critical FROM pgvigil.dbadash_fleet('sandbox')")
python3 - "$WORK/proc.tsv" "$WORK/stored.txt" "$WORK/words.txt" "$crit" <<'PY'
import json, sys
keys = ["MemoryDumpStatus","CorruptionStatus","LastGoodCheckDBStatus","AlertStatus","FullBackupStatus","DiffBackupStatus","LogBackupStatus",
        "DriveStatus","JobStatus","IsAgentRunningStatus","LogShippingStatus","MirroringStatus","AGStatus","LogFreeSpaceStatus","FileFreeSpaceStatus",
        "PctMaxSizeStatus","ElasticPoolStorageStatus","QueryStoreStatus","CustomCheckStatus","CollectionErrorStatus","SnapshotAgeStatus","DBMailStatus",
        "IdentityStatus","DatabaseStateStatus","ServiceBrokerStatus","UptimeStatus"]
lines = [l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
h = next(i for i, l in enumerate(lines) if l.startswith("InstanceID\t"))   # past the procedure's PRINT lines
head = lines[h].split("\t"); rows = [dict(zip(head, l.split("\t"))) for l in lines[h + 2:] if "\t" in l]
rows = [r for r in rows if r.get("InstanceID") not in (None, "NULL") and r.get("IsAzure") == "0"]
stored = {}
for l in open(sys.argv[2]).read().splitlines():
    i, st, ref = l.split("|")
    stored[i] = (json.loads(st), ref)
words = {"1":"Critical","2":"Warning","3":"N/A","4":"OK","5":"Acknowledged","6":"Warning (low)","7":"Information","8":"Disabled"}
bad = []
if not rows: bad.append("no SQL Server row in dbo.Summary_Get's output")
if set(r["InstanceID"] for r in rows) != set(stored): bad.append(f"instances: procedure {sorted(r['InstanceID'] for r in rows)}, stored {sorted(stored)}")
for r in rows:
    i = r["InstanceID"]
    if i not in stored: bad.append(f"instance {i}: no stored row"); continue
    st, ref = stored[i]
    for k in keys:
        want = None if r.get(k, "NULL") == "NULL" else int(r[k])
        if st.get(k) != want: bad.append(f"instance {i} {k}: procedure {want}, stored {st.get(k)}")
    if not r["RefreshDate"].startswith(ref[:19]): bad.append(f"instance {i} RefreshDate {r['RefreshDate']} vs {ref}")
    ncrit = sum(1 for k in keys if r.get(k) == "1")
    if str(ncrit) != sys.argv[4]: bad.append(f"critical count: procedure {ncrit}, dbadash_fleet {sys.argv[4]}")
w = [l.split("=") for l in open(sys.argv[3]).read().splitlines()]
if len(w) != 26: bad.append(f"dbadash_statuses: {len(w)} rows")
for k, c, word in w:
    if c and words[c] != word: bad.append(f"{k}: code {c} word {word}")
if bad: print("\n".join(bad)); sys.exit(1)
print(f"ok   D: {len(rows)} instance(s) x 26 statuses equal to dbo.Summary_Get's output; RefreshDate equal; 26 words; critical count {sys.argv[4]}")
PY

echo "== E. a status change on DBADash's side reaches the history =="
sq "UPDATE dbo.Summary SET DriveStatus = 1" "$DDB" >/dev/null
live "$WORK/pgvigil.yaml" >/dev/null
chg=$(pq "SELECT label || '|' || coalesce(old_word, '') || '|' || coalesce(new_word, '') FROM pgvigil.dbadash_changes('sandbox', (SELECT min(instance_id) FROM pgvigil.dbadash_summary WHERE repository = 'sandbox'), now() - interval '10 minutes', now())")
nh=$(pq "SELECT count(*) FROM pgvigil.dbadash_summary_history WHERE repository = 'sandbox'")
[[ "$chg" == "Drive Space|OK|Critical" && "$nh" == 2 ]] || fail "changes '$chg', history rows $nh (want 'Drive Space|OK|Critical' and 2)"
echo "ok   E: dbadash_changes: Drive Space was OK, now Critical; 2 history rows"

echo "== F. the folders: 'not read' with the reason; a repository dropped from the configuration leaves the tree =="
st=$(pq "SELECT repository || ' | ' || status || ' | ' || coalesce(reason, '') FROM pgvigil.dbadash_repositories()"); echo "$st"
echo "$st" | grep -qE '^refused \| not read \| .*Login failed' || fail "the stored reason of 'refused' lacks 'Login failed'"
echo "$st" | grep -qE '^unreachable \| not read \| .*connection refused' || fail "the stored reason of 'unreachable' lacks 'connection refused'"
echo "$st" | grep -qE '^sandbox \| ok \| $' || fail "sandbox is not stored ok"
head -n 7 "$WORK/pgvigil.yaml" > "$WORK/two.yaml"
live "$WORK/two.yaml" >/dev/null
nr=$(pq "SELECT string_agg(repository || ':' || status, ',' ORDER BY repository) FROM pgvigil.dbadash_repositories()")
[[ "$nr" == "refused:not read,sandbox:ok" ]] || fail "after dropping 'unreachable': $nr"
nh=$(pq "SELECT count(*) FROM pgvigil.dbadash_summary_history WHERE repository = 'sandbox'")
[[ "$nh" == 2 ]] || fail "an unchanged read added history: $nh rows (want 2)"
head -n 2 "$WORK/pgvigil.yaml" > "$WORK/none.yaml"
live "$WORK/none.yaml" | grep -q '^dbadash (none) configured=0' || fail "the empty-list read did not run"
n0=$(pq "SELECT count(*) FROM pgvigil.dbadash_repositories()")
ni=$(pq "SELECT count(*) FROM pgvigil.dbadash_instance('sandbox', (SELECT min(instance_id) FROM pgvigil.dbadash_summary WHERE repository = 'sandbox'))")
[[ "$n0" == 0 && "$ni" == 0 ]] || fail "after an emptied dbadash: list: $n0 repository row(s), $ni instance row(s) (want 0 and 0)"
echo "ok   F: stored reasons checked; after the configuration dropped 'unreachable': $nr; an unchanged read added no history; an emptied list leaves 0 repositories and no instance page"

echo "Not proven here: the 5-minute loop (dbadash.Run) under 'pgvigil run' and the tree and page in a browser (both are wired"
echo "into the lead's files at the wave's join; the join must call dbadash.Run unconditionally, an empty list included, or an emptied"
echo "dbadash: list never takes the last repository out of the tree); Azure SQL Database rows of a DBADash repository (IsAzure = 1: left out by the"
echo "reader, none in the sandbox); a DBADash version other than $ver."
echo "proof-dbadash: OK (DBADash $ver built $DDB from its release zip; read-only login; statuses equal to dbo.Summary_Get; history; not read with reasons)"
