# proof-instance-win.ps1 - Windows PowerShell 5.1 or 7, elevated, on a throwaway lab VM ONLY (dba-lab-win through
# the WIN queue): 'pgvigil instance add | list | disable' against an installed Windows service (RELNOTES L170). It
# makes a throwaway PostgreSQL cluster on 127.0.0.1 from a PostgreSQL bin folder (the repository, and one page
# instance), installs the service pgvigil (NT SERVICE\pgvigil), adds two page instances from the command line with
# the dsn on stdin - the cluster (a password sign-in) and this machine's SQL Server (a Windows sign-in) -, reads each
# credential file's access list, lets the service collect, lists, disables, and removes all of it. It writes nothing
# on SQL Server unless -GrantServiceLogin (OFF by default): then a login for NT SERVICE\pgvigil with VIEW SERVER STATE
# and VIEW ANY DEFINITION, dropped at the end and read back gone. It refuses to start where the service pgvigil, its
# instances folder or (with -GrantServiceLogin) that login already exists.
#   powershell.exe -NoProfile -File scripts\proof-instance-win.ps1 -Exe C:\proof\pgvigil.exe -PgBin 'C:\pgsql\bin'
#     [-BaseExe C:\proof\pgvigil-base.exe] [-SqlServer localhost] [-GrantServiceLogin]
# Expected (written before its first run, 2026-11-19):
#  C  the cluster up; 'pgvigil install' exit 0, the service as NT SERVICE\pgvigil; migrate exit 0; the agent and
#     monitor logins made from 'pgvigil roles'; repo.dsn holds the agent login (the documented repository login)
#  R0 (with -BaseExe, a build before L170) 'instance add' exit 2 (an unknown command), no credential file, no page row
#  A1 'instance add -engine postgres -dsn-stdin' (the monitor login's dsn on stdin) exit 0, its line names
#     NT SERVICE\pgvigil and never the password
#  F1 its credential file instances\win-pg-<hex>.dpapi: the folder's list protected (nothing inherited); the file's
#     readers exactly SYSTEM, the Administrators and the service's SID - not this administrator's own SID; the
#     password not in the file's bytes
#  A2 'instance add -engine sqlserver -dsn-stdin' (sqlserver://<SqlServer>?database=master, a Windows sign-in: its
#     connection test runs as this administrator, read only) exit 0
#  F2 its credential file instances\win-sql-<hex>.dpapi: the same list
#  S1 the service started collects win-pg within 180 s (a collection_dates row with status ok), so its account opened
#     the credential through that list; with -GrantServiceLogin win-sql too
#  L1 'instance list' under the agent login exit 0: win-pg page enabled, 'last collection <age> ago'; win-sql page
#     enabled with its age as the store has it (its collection rows' statuses printed: without -GrantServiceLogin the
#     service's account has no login on SQL Server)
#  D1 'instance disable' of both exit 0; 'instance list' shows both disabled
#  Z  the undo, each read back: the service stopped, 'pgvigil uninstall -purge' leaves no service, the instances
#     folder removed, with -GrantServiceLogin the login gone, the cluster stopped, the work folder removed
# Exit 0 = every row as stated (R0 'NOT RUN' without -BaseExe is not a failure); 1 = a row differs; 2 = refused.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$PgBin,
    [string]$BaseExe = '',
    [string]$SqlServer = 'localhost',
    [switch]$GrantServiceLogin,
    [string]$Work = 'C:\pgvigil-instance-proof',
    [int]$Port = 55434
)
$ErrorActionPreference = 'Stop'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'REFUSED: run elevated'; exit 2 }
if (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) { Write-Host 'REFUSED: the service pgvigil exists here - this proof runs on a machine without pgvigil'; exit 2 }
if (-not (Test-Path -LiteralPath $Exe)) { Write-Host "REFUSED: no $Exe"; exit 2 }
if ($BaseExe -and -not (Test-Path -LiteralPath $BaseExe)) { Write-Host "REFUSED: no $BaseExe"; exit 2 }
foreach ($tool in 'initdb.exe', 'pg_ctl.exe', 'psql.exe') { if (-not (Test-Path -LiteralPath (Join-Path $PgBin $tool))) { Write-Host "REFUSED: no $tool in $PgBin"; exit 2 } }
if (Test-Path -LiteralPath $Work) { Write-Host "REFUSED: $Work exists (a run of its own folder only)"; exit 2 }
$InstDir = Join-Path $env:ProgramData 'pgvigil\instances'
if (Test-Path -LiteralPath $InstDir) { Write-Host "REFUSED: $InstDir exists (this proof removes the folder it makes, never one it found)"; exit 2 }

function Invoke-Native([scriptblock]$cmd) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $cmd 2>&1 | ForEach-Object { "$_" }; return @{ Code = $LASTEXITCODE; Out = ($out -join "`n") } } finally { $ErrorActionPreference = $eap }
}
$SvcLogin = 'NT SERVICE\pgvigil'
$SqlCmd = $null
function Invoke-TSql([string]$query) {
    return Invoke-Native { & $SqlCmd -S $SqlServer -E -b -h -1 -W -Q "SET NOCOUNT ON; $query" }
}
function Get-LoginCount {
    $res = Invoke-TSql "SELECT COUNT(*) FROM sys.server_principals WHERE name = N'$SvcLogin';"
    if ($res.Code -ne 0) { return -1 }
    return [int]("$($res.Out)".Trim())
}
if ($GrantServiceLogin) {
    $found = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
    if (-not $found) { Write-Host 'REFUSED: -GrantServiceLogin needs sqlcmd.exe on PATH'; exit 2 }
    $SqlCmd = $found.Source
    $had = Get-LoginCount
    if ($had -ne 0) { Write-Host "REFUSED: -GrantServiceLogin: the login $SvcLogin reads $had on $SqlServer (-1 = not readable) - this proof drops only a login it made"; exit 2 }
}

$failed = 0
function Row([string]$name, [bool]$ok, [string]$what) {
    if ($ok) { Write-Host "OK   $name $what" } else { Write-Host "FAIL $name $what"; $script:failed++ }
}
$Cfg = Join-Path $env:ProgramData 'pgvigil\pgvigil.yaml'
$suPw = 'su' + [Guid]::NewGuid().ToString('N'); $agentPw = 'ag' + [Guid]::NewGuid().ToString('N'); $monPw = 'mo' + [Guid]::NewGuid().ToString('N')
$pgData = Join-Path $Work 'pgdata'
$pgDsn = "host=127.0.0.1 port=$Port user=pgvigil_monitor password=$monPw dbname=postgres sslmode=disable"
$sqlDsn = "sqlserver://$SqlServer`?database=master&encrypt=true&trustservercertificate=true"
$sidSystem = 'S-1-5-18'; $sidAdmins = 'S-1-5-32-544'
$sidMe = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$sidSvc = ''
$loginMade = $false

function Invoke-Sql([string]$sql, [string]$db) {
    $env:PGPASSWORD = $suPw
    try { return Invoke-Native { & (Join-Path $PgBin 'psql.exe') -h 127.0.0.1 -p $Port -U postgres -d $db -XAtq -v ON_ERROR_STOP=1 -c $sql } } finally { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
}
function Get-Number([string]$sql) {
    $res = Invoke-Sql $sql 'pgvigil'
    if ($res.Code -ne 0) { return -1 }
    return [int]("$($res.Out)".Trim())
}
# one page instance's credential files, newest first
function Get-CredFiles([string]$name) {
    if (-not (Test-Path -LiteralPath $InstDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $InstDir -File | Where-Object { $_.Name -like "$name-*.dpapi" } | Sort-Object LastWriteTime -Descending)
}
# the access list of one credential file: the folder protected, the file's allowed SIDs exactly SYSTEM, the
# Administrators and the service's; this administrator's own SID absent; the secret not in the file's bytes
function Test-CredFile([string]$rowName, [string]$name, [string]$secret) {
    $files = Get-CredFiles $name
    if ($files.Count -ne 1) { Row $rowName $false "$($files.Count) credential file(s) for $name in $InstDir, want 1"; return }
    $file = $files[0].FullName
    $protected = (Get-Acl -LiteralPath $InstDir).AreAccessRulesProtected
    $rules = @((Get-Acl -LiteralPath $file).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' })
    $sids = @($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    $want = @($sidSystem, $sidAdmins, $sidSvc | Sort-Object -Unique)
    $exact = ($sids.Count -eq $want.Count) -and (@($sids | Where-Object { $want -notcontains $_ }).Count -eq 0)
    $denies = @((Get-Acl -LiteralPath $file).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Deny' }).Count
    $inClear = $false
    if ($secret) { $inClear = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($file)).Contains($secret) }
    $meIn = $sids -contains $sidMe
    Row $rowName ($protected -and $exact -and -not $meIn -and -not $inClear) "$($files[0].Name): the folder's list protected $protected; readers $($sids -join ', ') (want SYSTEM, Administrators and the service's $sidSvc; deny entries $denies); this administrator's SID $sidMe in it $meIn; the secret in the file in clear $inClear"
}
# 'pgvigil instance list' as a map name -> its line's words
function Get-ListLines {
    $res = Invoke-Native { & $Exe instance list -config $Cfg }
    $map = @{}
    foreach ($line in ("$($res.Out)" -split "`n")) {
        $parts = $line.Trim() -split '\s+', 5
        if ($parts.Count -eq 5) { $map[$parts[0]] = $line.Trim() }
    }
    return @{ Code = $res.Code; Out = $res.Out; Lines = $map }
}
function Get-CollectionStatuses([string]$name) {
    $res = Invoke-Sql "select coalesce(string_agg(c.status || ' ' || c.collection, ', ' order by c.collection), 'none') from pgvigil.collection_dates c join pgvigil.instances i using (instance_id) where i.name = '$name'" 'pgvigil'
    if ($res.Code -ne 0) { return "unread ($($res.Out))" }
    return "$($res.Out)".Trim()
}

New-Item -ItemType Directory -Path $Work | Out-Null
try {
    # C
    $pwFile = Join-Path $Work 'su.pw'; [IO.File]::WriteAllText($pwFile, $suPw)
    $res = Invoke-Native { & (Join-Path $PgBin 'initdb.exe') -D $pgData -U postgres --auth=scram-sha-256 --pwfile=$pwFile -E UTF8 }
    Remove-Item -LiteralPath $pwFile -Force
    if ($res.Code -ne 0) { throw "initdb exit $($res.Code): $($res.Out)" }
    $res = Invoke-Native { & (Join-Path $PgBin 'pg_ctl.exe') -D $pgData -l (Join-Path $Work 'pg.log') -o "-p $Port -c listen_addresses=127.0.0.1" -w start }
    if ($res.Code -ne 0) { throw "pg_ctl start exit $($res.Code): $($res.Out)" }
    $null = Invoke-Sql "CREATE ROLE pgvigil_owner LOGIN CREATEROLE PASSWORD '$suPw'" 'postgres'
    $null = Invoke-Sql 'CREATE DATABASE pgvigil OWNER pgvigil_owner' 'postgres'
    $inst = Invoke-Native { & $Exe install }
    $startName = (Get-CimInstance Win32_Service -Filter "Name='pgvigil'").StartName
    $sidSvc = (New-Object Security.Principal.NTAccount($SvcLogin)).Translate([Security.Principal.SecurityIdentifier]).Value
    $env:PGVIGIL_REPO_DSN = "host=127.0.0.1 port=$Port user=pgvigil_owner password=$suPw dbname=pgvigil sslmode=disable"
    $mig = Invoke-Native { & $Exe migrate -config $Cfg }
    Remove-Item Env:PGVIGIL_REPO_DSN
    $roles = (Invoke-Native { & $Exe roles }).Out -split "`n"
    $made = 0
    foreach ($pair in @(@('agent', $agentPw), @('monitor', $monPw))) {
        $line = $roles | Where-Object { $_ -match "^CREATE ROLE pgvigil_$($pair[0]) LOGIN PASSWORD '<set-me>'" } | Select-Object -First 1
        if ($line) { if ((Invoke-Sql ($line -replace '<set-me>', $pair[1]) 'pgvigil').Code -eq 0) { $made++ } }
    }
    [IO.File]::WriteAllText((Join-Path $env:ProgramData 'pgvigil\repo.dsn'), "host=127.0.0.1 port=$Port user=pgvigil_agent password=$agentPw dbname=pgvigil sslmode=disable")
    Row 'C' ($inst.Code -eq 0 -and $startName -eq $SvcLogin -and $sidSvc -like 'S-1-5-80-*' -and $mig.Code -eq 0 -and $made -eq 2) "install exit $($inst.Code) as '$startName' (SID $sidSvc), migrate exit $($mig.Code), logins made $made of 2, repo.dsn = the agent login"
    if ($GrantServiceLogin) {
        $res = Invoke-TSql "CREATE LOGIN [$SvcLogin] FROM WINDOWS; GRANT VIEW SERVER STATE TO [$SvcLogin]; GRANT VIEW ANY DEFINITION TO [$SvcLogin];"
        $loginMade = ($res.Code -eq 0)
        Row 'C' ($loginMade -and (Get-LoginCount) -eq 1) "-GrantServiceLogin: the login $SvcLogin made on $SqlServer (exit $($res.Code)$(if ($res.Code -ne 0) { ': ' + $res.Out }))"
    }

    # R0
    if ($BaseExe) {
        $res = Invoke-Native { $pgDsn | & $BaseExe instance add -config $Cfg -name win-pg -engine postgres -dsn-stdin }
        $files = (Get-CredFiles 'win-pg').Count
        $rowsIn = Get-Number "select count(*) from pgvigil.admin_inventory() where name = 'win-pg'"
        Row 'R0' ($res.Code -eq 2 -and $files -eq 0 -and $rowsIn -eq 0) "the base build's 'instance add' exit $($res.Code) (want 2, an unknown command), credential files $files, page rows $rowsIn"
    } else {
        Write-Host 'NOT RUN R0 (no -BaseExe: the red of this proof is the base build refusing the command)'
    }

    # A1 / F1
    $res = Invoke-Native { $pgDsn | & $Exe instance add -config $Cfg -name win-pg -engine postgres -dsn-stdin }
    $saysSvc = "$($res.Out)".Contains($SvcLogin)
    $leaks = "$($res.Out)".Contains($monPw)
    Row 'A1' ($res.Code -eq 0 -and $saysSvc -and -not $leaks) "instance add win-pg exit $($res.Code); names $SvcLogin $saysSvc; the password in the output $leaks; said: $((("$($res.Out)" -split "`n") | Select-Object -Last 1))"
    Test-CredFile 'F1' 'win-pg' $monPw

    # A2 / F2
    $res = Invoke-Native { $sqlDsn | & $Exe instance add -config $Cfg -name win-sql -engine sqlserver -dsn-stdin }
    Row 'A2' ($res.Code -eq 0 -and "$($res.Out)".Contains($SvcLogin)) "instance add win-sql exit $($res.Code) (a Windows sign-in to $SqlServer; the test as this administrator); said: $((("$($res.Out)" -split "`n") | Select-Object -Last 1))"
    Test-CredFile 'F2' 'win-sql' ''

    # S1
    Start-Service -Name pgvigil
    $okPg = 0; $okSql = 0
    foreach ($tick in 1..90) {
        Start-Sleep -Seconds 2
        $okPg = Get-Number "select count(*) from pgvigil.collection_dates c join pgvigil.instances i using (instance_id) where i.name = 'win-pg' and c.status = 'ok'"
        $okSql = Get-Number "select count(*) from pgvigil.collection_dates c join pgvigil.instances i using (instance_id) where i.name = 'win-sql' and c.status = 'ok'"
        if ($okPg -gt 0 -and (-not $GrantServiceLogin -or $okSql -gt 0)) { break }
        if ((Get-Service -Name pgvigil).Status -ne 'Running') { break }
    }
    $svcState = (Get-Service -Name pgvigil).Status
    Row 'S1' ($okPg -gt 0 -and (-not $GrantServiceLogin -or $okSql -gt 0)) "the service $svcState; win-pg collections ok $okPg; win-sql collections ok $okSql$(if (-not $GrantServiceLogin) { ' (not asked: no login for the service on SQL Server)' })"

    # L1
    $list = Get-ListLines
    $pgLine = "$($list.Lines['win-pg'])"; $sqlLine = "$($list.Lines['win-sql'])"
    $pgOk = $pgLine -match '^win-pg\s+page\s+postgres\s+enabled\s+last collection \S+ ago$'
    $sqlOk = $sqlLine -match '^win-sql\s+page\s+sqlserver\s+enabled\s+last collection '
    if ($GrantServiceLogin) { $sqlOk = $sqlLine -match '^win-sql\s+page\s+sqlserver\s+enabled\s+last collection \S+ ago$' }
    Row 'L1' ($list.Code -eq 0 -and $pgOk -and $sqlOk) "instance list (the agent login) exit $($list.Code): '$pgLine' / '$sqlLine'; win-sql's collection rows: $(Get-CollectionStatuses 'win-sql')$(if ($list.Code -ne 0) { '; said: ' + $list.Out })"

    # D1
    $d1 = Invoke-Native { & $Exe instance disable -config $Cfg -name win-pg }
    $d2 = Invoke-Native { & $Exe instance disable -config $Cfg -name win-sql }
    $list = Get-ListLines
    $pgOff = "$($list.Lines['win-pg'])" -match '^win-pg\s+page\s+postgres\s+disabled\s'
    $sqlOff = "$($list.Lines['win-sql'])" -match '^win-sql\s+page\s+sqlserver\s+disabled\s'
    Row 'D1' ($d1.Code -eq 0 -and $d2.Code -eq 0 -and $list.Code -eq 0 -and $pgOff -and $sqlOff) "disable exit $($d1.Code) / $($d2.Code); list exit $($list.Code): '$($list.Lines['win-pg'])' / '$($list.Lines['win-sql'])'"
} catch {
    Row 'X' $false "the proof stopped: $($_.Exception.Message)"
} finally {
    # Z: the undo, each step read back
    if (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) {
        Stop-Service -Name pgvigil -ErrorAction SilentlyContinue
        $null = Invoke-Native { & $Exe uninstall -purge }
    }
    Row 'Z' (-not (Get-Service -Name pgvigil -ErrorAction SilentlyContinue)) 'no service pgvigil left'
    if (Test-Path -LiteralPath $InstDir) { Remove-Item -LiteralPath $InstDir -Recurse -Force -ErrorAction SilentlyContinue }
    Row 'Z' (-not (Test-Path -LiteralPath $InstDir)) "$InstDir removed"
    if ($loginMade) {
        $res = Invoke-TSql "IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$SvcLogin') DROP LOGIN [$SvcLogin];"
        Row 'Z' ((Get-LoginCount) -eq 0) "the login $SvcLogin dropped on $SqlServer (exit $($res.Code)$(if ($res.Code -ne 0) { ': ' + $res.Out }))"
    }
    if (Test-Path -LiteralPath (Join-Path $pgData 'postmaster.pid')) { $null = Invoke-Native { & (Join-Path $PgBin 'pg_ctl.exe') -D $pgData -m fast -w stop } }
    Row 'Z' (-not (Test-Path -LiteralPath (Join-Path $pgData 'postmaster.pid'))) 'the cluster stopped'
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    Row 'Z' (-not (Test-Path -LiteralPath $Work)) "$Work removed"
    $suPw = $null; $agentPw = $null; $monPw = $null; $pgDsn = $null
}
if ($failed -eq 0) { Write-Host 'PASS: every row'; exit 0 }
Write-Host "FAIL: $failed row(s)"; exit 1
