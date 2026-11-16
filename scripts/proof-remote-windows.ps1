# proof-remote-windows.ps1 - the remote collector on Windows (task 14, R14; client promise 1): install.ps1 -From <folder>
# -Remote as a service, its folders' ACL read back, a bundle from the instance the VM reaches (its own SQL Server), the
# install again over itself, uninstall -remote -purge refused while the outbox holds bundles, then with -force.
# Windows PowerShell 5.1, elevated, on the lab's Windows VM (setup/Cloud-Win.ps1 Run sends this one file); the folder
# C:\pgvigil-remote-proof\from is copied there before it runs and holds pgvigil_<v>_windows_amd64.exe, install.ps1 and
# SHA256SUMS (the build's exe and install.ps1), laid out and copied by the runner beforehand. The VM's own SQL Server (localhost, Windows
# authentication for this session's user) is the instance; a SQL login made here (a random password, never printed) is
# the collector's, as docs/sqlserver.md's least-privilege login, and dropped at the end.
# Expected (written before its first run):
#  P  elevated; the hub's binary %ProgramFiles%\pgvigil\pgvigil.exe read (absent, or its SHA-256 kept for B); the
#     VM's SQL Server answers on localhost within 180 s (a VM started for the run boots it late), its services named
#  L  an earlier run's leftovers removed (the service pgvigil-remote, its folders, the login): 'ok L'
#  Q  the instance takes SQL logins and answers on TCP 127.0.0.1:1433; the login pgvigil_remote_proof made with
#     docs/sqlserver.md's grants: 'ok Q'
#  C  pgvigil-remote.yaml and its dsn file written before the install (site lab14, collector win1, interval 1m)
#  I  install.ps1 -From -Remote: 'signature not verified here', '(plain build) checksum verified', 'installed and
#     running'; exit 0
#  S  the service pgvigil-remote Running, Auto, under NT SERVICE\pgvigil-remote, its path
#     "C:\Program Files\pgvigil-remote\pgvigil.exe" run -config C:\ProgramData\pgvigil-remote\pgvigil-remote.yaml;
#     C:\Program Files\pgvigil-remote on the machine PATH
#  B  the hub's binary path as it was: absent before and after, or the same SHA-256
#  A  ProgramData\pgvigil-remote, \outbox and \state: inheritance cut; ACEs for SYSTEM, Administrators and the service's
#     SID only (by SID); the service may read the config folder and not write it, and may write the outbox and state
#  W  within 240 s a finished bundle (manifest.json) under the outbox for instance SQLW: query_text hash, at least one
#     read 'ran'; 'pgvigil bundle inspect' says checks ok; the service log is state\pgvigil-remote.log and the config
#     folder holds nothing but the config, the dsn file, outbox and state
#  R  install.ps1 -From -Remote again over the running install: exit 0, the service Running again (eaf80b4f)
#  G  uninstall -remote -purge with bundles in the outbox: refused (exit not 0) naming the bundles, 'lost' and -force;
#     the service still there and Running
#  U  uninstall -remote -purge -force: the service gone, 'removed with -force: N' equal to the purge's count (no push
#     here; run 2 of 4491579d said 2 against 3: the count was read while the service still wrote), the outbox and the state folder gone,
#     Program Files\pgvigil-remote gone; ProgramData\pgvigil-remote KEPT holding only sqlw.dsn (the site's own file),
#     named in a 'folder kept' line; the hub's binary path as at P
#  X  the login dropped, the PATH entry removed; the last line 'proof-remote-windows: PASS' (or FAIL <letter> first)
param(
    [string]$From = 'C:\pgvigil-remote-proof\from',
    [int]$BundleWaitSec = 240
)
$ErrorActionPreference = 'Stop'
$script:failed = $false
function Fail([string]$letter, [string]$what) { Write-Host "FAIL $letter $what"; $script:failed = $true; throw "FAIL $letter" }
function Ok([string]$letter, [string]$what) { Write-Host "ok $letter $what" }
# a native command under 'Stop' throws on stderr in 5.1: run it with 'Continue' and judge its exit code
function Invoke-Native([scriptblock]$cmd) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $cmd 2>&1 | ForEach-Object { "$_" }; return @{ Code = $LASTEXITCODE; Out = ($out -join "`n") } } finally { $ErrorActionPreference = $eap }
}
function Invoke-SqlFile([string]$sqlText) {
    $sqlPath = Join-Path $env:TEMP ('prw-' + [Guid]::NewGuid().ToString('N') + '.sql')
    try {
        [IO.File]::WriteAllText($sqlPath, $sqlText, (New-Object Text.UTF8Encoding $false))
        return (Invoke-Native { sqlcmd -S localhost -E -b -I -i $sqlPath })
    } finally { Remove-Item -LiteralPath $sqlPath -Force -ErrorAction SilentlyContinue }
}
function Get-FileSha([string]$path) { if (Test-Path -LiteralPath $path) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash } else { return 'absent' } }

$svcName = 'pgvigil-remote'
$dataDir = Join-Path $env:ProgramData 'pgvigil-remote'
$outbox = Join-Path $dataDir 'outbox'
$stateDir = Join-Path $dataDir 'state'
$cfgPath = Join-Path $dataDir 'pgvigil-remote.yaml'
$dsnPath = Join-Path $dataDir 'sqlw.dsn'
$remoteBinDir = Join-Path $env:ProgramFiles 'pgvigil-remote'
$remoteExe = Join-Path $remoteBinDir 'pgvigil.exe'
$hubExe = Join-Path (Join-Path $env:ProgramFiles 'pgvigil') 'pgvigil.exe'
$login = 'pgvigil_remote_proof'
$fromExe = $null

function Remove-Leftovers {
    if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
        [void](Invoke-Native { sc.exe stop $svcName }); Start-Sleep -Seconds 3; [void](Invoke-Native { sc.exe delete $svcName }); Start-Sleep -Seconds 2
    }
    foreach ($dir in @($dataDir, $remoteBinDir)) { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $kept = @($machinePath -split ';' | Where-Object { $_ -and $_ -ne $remoteBinDir })
    if ($kept.Count -ne @($machinePath -split ';' | Where-Object { $_ }).Count) { [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'Machine') }
    $res = Invoke-SqlFile @"
USE msdb;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$login') DROP USER [$login];
USE master;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$login') DROP USER [$login];
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$login') DROP LOGIN [$login];
"@
    if ($res.Code -ne 0) { throw "the login $login could not be dropped: $($res.Out)" }
}

try {
    # P
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Fail 'P' 'this session is not elevated' }
    $fromExe = @(Get-ChildItem -LiteralPath $From -Filter 'pgvigil_*_windows_amd64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($fromExe.Count -ne 1) { Fail 'P' "no pgvigil_<v>_windows_amd64.exe in $From" }
    $fromExe = $fromExe[0].FullName
    $hubBefore = Get-FileSha $hubExe
    # a VM started for this run boots its SQL Server after the tunnel answers: wait for localhost to answer
    $sqlServices = @(Get-Service -Name 'MSSQL*' -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)=$($_.Status)" })
    $sqlDeadline = (Get-Date).AddSeconds(180); $sqlUp = $false
    while ((Get-Date) -lt $sqlDeadline) {
        $res = Invoke-SqlFile 'SET NOCOUNT ON; SELECT @@SERVERNAME;'
        if ($res.Code -eq 0) { $sqlUp = $true; break }
        Start-Sleep -Seconds 10
    }
    if (-not $sqlUp) { Fail 'P' "SQL Server on localhost did not answer within 180 s (services: $($sqlServices -join ', ')): $($res.Out)" }
    Ok 'P' "elevated; the hub's binary $hubExe $hubBefore; the build $fromExe; SQL Server answers ($($sqlServices -join ', '))"

    # L
    Remove-Leftovers
    Ok 'L' 'no earlier service, folder, PATH entry or login left'

    # Q
    $res = Invoke-SqlFile "SET NOCOUNT ON; SELECT 'integrated_only=' + CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS varchar(2));"
    if ($res.Code -ne 0) { Fail 'Q' "sqlcmd -S localhost -E: $($res.Out)" }
    if ($res.Out -match 'integrated_only=1') { Fail 'Q' 'the instance takes Windows logins only: a SQL login cannot sign in (NOT PROVEN on this VM)' }
    $probe = New-Object Net.Sockets.TcpClient
    try { $probe.Connect('127.0.0.1', 1433) } catch { Fail 'Q' "nothing answers on TCP 127.0.0.1:1433 ($($_.Exception.Message)): the collector's dsn cannot reach the instance (NOT PROVEN on this VM)" } finally { $probe.Close() }
    $pw = [Guid]::NewGuid().ToString('N') + 'Aa1!' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $res = Invoke-SqlFile @"
CREATE LOGIN [$login] WITH PASSWORD = N'$pw', CHECK_POLICY = OFF;
GRANT VIEW SERVER STATE TO [$login];
GRANT VIEW ANY DEFINITION TO [$login];
GRANT CONNECT ANY DATABASE TO [$login];
GRANT ALTER TRACE TO [$login];
USE msdb;
CREATE USER [$login] FOR LOGIN [$login];
ALTER ROLE db_datareader ADD MEMBER [$login];
USE master;
CREATE USER [$login] FOR LOGIN [$login];
GRANT EXECUTE ON master.sys.xp_readerrorlog TO [$login];
"@
    if ($res.Code -ne 0) { Fail 'Q' "the login was not made: $($res.Out)" }
    Ok 'Q' "the login $login with docs/sqlserver.md's grants"

    # C
    [void](New-Item -ItemType Directory -Path $dataDir -Force)
    $yaml = @"
remote:
  site: lab14
  collector: win1
  interval: 1m
  outbox: '$outbox'
  state_dir: '$stateDir'
  keep_days: 7
  max_mb: 2048
  sign: false
query_text: hash
instances:
  - name: SQLW
    engine: sqlserver
    dsn: 'file:$dsnPath'
"@
    [IO.File]::WriteAllText($cfgPath, $yaml, (New-Object Text.UTF8Encoding $false))
    $dsn = 'sqlserver://' + $login + ':' + $pw + '@' + 'localhost:1433?database=master&encrypt=true&TrustServerCertificate=true'
    [IO.File]::WriteAllText($dsnPath, $dsn, (New-Object Text.UTF8Encoding $false))
    Ok 'C' "$cfgPath and its dsn file written"

    # I
    $res = Invoke-Native { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $From 'install.ps1') -From $From -Remote }
    Write-Host $res.Out
    if ($res.Code -ne 0) { Fail 'I' "install.ps1 -From -Remote exited $($res.Code)" }
    foreach ($want in @('signature not verified here', '(plain build) checksum verified', 'installed and running')) {
        if ($res.Out -notlike "*$want*") { Fail 'I' "install.ps1's output lacks '$want'" }
    }
    Ok 'I' 'install.ps1 -From -Remote: verified, installed and running'

    # S
    $wmi = Get-CimInstance -ClassName Win32_Service -Filter "Name='$svcName'"
    if (-not $wmi) { Fail 'S' "no service $svcName" }
    if ($wmi.State -ne 'Running' -or $wmi.StartMode -ne 'Auto') { Fail 'S' "$svcName is $($wmi.State) / $($wmi.StartMode)" }
    if ($wmi.StartName -ne "NT SERVICE\$svcName") { Fail 'S' "$svcName runs as $($wmi.StartName)" }
    if ($wmi.PathName -notlike "`"$remoteExe`" run -config*$cfgPath*") { Fail 'S' "its path is $($wmi.PathName)" }
    if (([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';') -notcontains $remoteBinDir) { Fail 'S' "$remoteBinDir is not on the machine PATH" }
    Ok 'S' "$svcName Running, Auto, as $($wmi.StartName), $($wmi.PathName); $remoteBinDir on the PATH"

    # B
    $hubAfter = Get-FileSha $hubExe
    if ($hubAfter -ne $hubBefore) { Fail 'B' "the hub's binary changed: $hubBefore -> $hubAfter" }
    Ok 'B' "the hub's binary path as it was ($hubAfter)"

    # A
    $svcSid = (New-Object Security.Principal.NTAccount("NT SERVICE\$svcName")).Translate([Security.Principal.SecurityIdentifier]).Value
    $allowed = @('S-1-5-18', 'S-1-5-32-544', $svcSid)
    foreach ($dir in @($dataDir, $outbox, $stateDir)) {
        $acl = Get-Acl -LiteralPath $dir
        if (-not $acl.AreAccessRulesProtected) { Fail 'A' "$dir inherits its parent's ACL" }
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $sids = @($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
        foreach ($sid in $sids) { if ($allowed -notcontains $sid) { Fail 'A' "$dir grants $sid" } }
        $svcRights = [Security.AccessControl.FileSystemRights]0
        foreach ($rule in $rules) { if ($rule.IdentityReference.Value -eq $svcSid -and $rule.AccessControlType -eq 'Allow') { $svcRights = $svcRights -bor $rule.FileSystemRights } }
        $canWrite = ($svcRights -band [Security.AccessControl.FileSystemRights]::WriteData) -ne 0
        $canRead = ($svcRights -band [Security.AccessControl.FileSystemRights]::ReadData) -ne 0
        if (-not $canRead) { Fail 'A' "the service cannot read $dir" }
        if ($dir -eq $dataDir -and $canWrite) { Fail 'A' "the service may write the config folder $dir" }
        if ($dir -ne $dataDir -and -not $canWrite) { Fail 'A' "the service cannot write $dir" }
        Write-Host "   $dir : $($sids -join ', ') ; service: $svcRights"
    }
    Ok 'A' 'the three folders: inheritance cut, SYSTEM, Administrators and the service only; config read-only to it, outbox and state writable'

    # W
    $deadline = (Get-Date).AddSeconds($BundleWaitSec); $manifests = @()
    while ((Get-Date) -lt $deadline) {
        $manifests = @(Get-ChildItem -LiteralPath $outbox -Recurse -Filter 'manifest.json' -ErrorAction SilentlyContinue | Where-Object { $_.DirectoryName -notlike '*.part' })
        if ($manifests.Count -gt 0) { break }
        Start-Sleep -Seconds 10
    }
    if ($manifests.Count -eq 0) {
        $log = Join-Path $stateDir 'pgvigil-remote.log'
        if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 30 | ForEach-Object { Write-Host "   log: $_" } }
        Fail 'W' "no finished bundle under $outbox within $BundleWaitSec s"
    }
    $bundleDir = $manifests[0].DirectoryName
    $man = Get-Content -LiteralPath $manifests[0].FullName -Raw | ConvertFrom-Json
    if ($man.instance.name -ne 'SQLW' -or $man.query_text -ne 'hash') { Fail 'W' "the manifest names $($man.instance.name), query_text $($man.query_text)" }
    $ran = @($man.reads | Where-Object { $_.status -eq 'ran' })
    if ($ran.Count -lt 1) { Fail 'W' "no read ran: $(($man.reads | ForEach-Object { "$($_.collection)=$($_.status)" }) -join ', ')" }
    $res = Invoke-Native { & $remoteExe bundle inspect $bundleDir }
    if ($res.Code -ne 0 -or $res.Out -notmatch '"checks":\s*"ok"') { Fail 'W' "bundle inspect: exit $($res.Code): $(($res.Out -split "`n" | Select-Object -First 5) -join ' ')" }
    if (-not (Test-Path -LiteralPath (Join-Path $stateDir 'pgvigil-remote.log'))) { Fail 'W' 'no service log in the state folder' }
    $extra = @(Get-ChildItem -LiteralPath $dataDir -Force | Where-Object { @('pgvigil-remote.yaml', 'sqlw.dsn', 'outbox', 'state') -notcontains $_.Name } | ForEach-Object { $_.Name })
    if ($extra.Count) { Fail 'W' "the config folder holds $($extra -join ', ')" }
    Ok 'W' "a bundle $bundleDir : SQLW, hash, $($ran.Count) read(s) ran ($((($ran | Select-Object -First 5) | ForEach-Object { $_.collection }) -join ', ')...), inspect checks ok; the log in the state folder"

    # R
    $res = Invoke-Native { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $From 'install.ps1') -From $From -Remote }
    if ($res.Code -ne 0) { Write-Host $res.Out; Fail 'R' "install.ps1 -From -Remote again exited $($res.Code)" }
    if ((Get-Service -Name $svcName).Status -ne 'Running') { Fail 'R' "$svcName is not Running after the second install" }
    Ok 'R' 'install.ps1 -From -Remote again over itself: exit 0, Running'

    # G
    $res = Invoke-Native { & $fromExe uninstall -remote -purge }
    if ($res.Code -eq 0) { Fail 'G' "uninstall -remote -purge with bundles in the outbox was not refused: $($res.Out)" }
    foreach ($want in @('bundle(s) not pushed', 'lost', '-force')) { if ($res.Out -notlike "*$want*") { Fail 'G' "the refusal lacks '$want': $($res.Out)" } }
    if ((Get-Service -Name $svcName -ErrorAction SilentlyContinue).Status -ne 'Running') { Fail 'G' "$svcName is not Running after the refusal" }
    Ok 'G' "refused: $((($res.Out -split "`n") | Where-Object { $_ -like '*not pushed*' } | Select-Object -First 1))"

    # U
    $res = Invoke-Native { & $fromExe uninstall -remote -purge -force }
    Write-Host $res.Out
    if ($res.Code -ne 0) { Fail 'U' "uninstall -remote -purge -force exited $($res.Code)" }
    if ($res.Out -notmatch 'removed with -force: (\d+) bundle') { Fail 'U' "the output does not name the bundles removed with -force" }
    $forced = [int]$Matches[1]
    if ($res.Out -notmatch 'outbox purged.*bundles=(\d+)') { Fail 'U' "the output does not count the bundles purged" }
    if ([int]$Matches[1] -ne $forced) { Fail 'U' "'removed with -force' says $forced bundle(s), the purge removed $($Matches[1]) (no push here: the two counts are equal)" }
    if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) { Fail 'U' "$svcName is still there" }
    foreach ($dir in @($outbox, $stateDir, $remoteBinDir)) { if (Test-Path -LiteralPath $dir) { Fail 'U' "$dir is still there: $((Get-ChildItem -LiteralPath $dir -Recurse -Force | ForEach-Object { $_.FullName }) -join ', ')" } }
    $left = @(Get-ChildItem -LiteralPath $dataDir -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    if (($left -join ',') -ne 'sqlw.dsn') { Fail 'U' "$dataDir should hold only sqlw.dsn, holds: $($left -join ', ')" }
    if ($res.Out -notlike '*folder kept*' -or $res.Out -notlike '*sqlw.dsn*') { Fail 'U' "the kept config folder and its sqlw.dsn are not named" }
    if ((Get-FileSha $hubExe) -ne $hubBefore) { Fail 'U' "the hub's binary changed" }
    Ok 'U' 'uninstall -remote -purge -force: the service, the outbox, the state folder and Program Files\pgvigil-remote gone; the config folder kept with only the site''s sqlw.dsn, named; the hub path as it was'
}
catch {
    if (-not $script:failed) { Write-Host "FAIL ? $($_.Exception.Message)"; $script:failed = $true }
}
finally {
    # X
    try { Remove-Leftovers; Write-Host 'ok X the login dropped, the PATH entry, the service and its folders removed' }
    catch { Write-Host "FAIL X cleanup: $($_.Exception.Message)"; $script:failed = $true }
}
if ($script:failed) { Write-Host 'proof-remote-windows: FAIL'; exit 1 }
Write-Host 'proof-remote-windows: PASS'
exit 0
