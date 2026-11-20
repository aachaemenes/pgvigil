# proof-instance-win.ps1 - Windows PowerShell 5.1 or 7, elevated, on a throwaway lab VM ONLY (dba-lab-win through
# the WIN queue): 'pgvigil instance add | list | disable' against an installed Windows service (RELNOTES L170), and
# 'pgvigil check's 'secret files' judge reading a real access list (RELNOTES L169). It makes a throwaway PostgreSQL
# cluster on 127.0.0.1 from a PostgreSQL bin folder (the repository, and one page instance), installs the service
# pgvigil (NT SERVICE\pgvigil), adds two page instances from the command line with the dsn on stdin - the cluster (a
# password sign-in) and a SQL Server of this machine (a Windows sign-in) -, reads each credential file's access list,
# lets the service collect, lists, disables, and removes all of it. It writes nothing on SQL Server unless
# -GrantServiceLogin (OFF by default): then a login for NT SERVICE\pgvigil with VIEW SERVER STATE and VIEW ANY
# DEFINITION, dropped at the end and read back gone - on a NAMED instance only (-SqlServer host\NAME): the lab's
# default instance is DBA Dash's and is never written to, so the switch refuses an instance whose
# SERVERPROPERTY('InstanceName') reads NULL. Pass a named instance whenever the VM has one, even with the switch off
# (the service's refused sign-ins then land in that instance's error log, not DBA Dash's).
# -Exe must be a build with the L170 list fix (rel-relnotes-s3 2d7c12abd or later: migration 0480).
#   powershell.exe -NoProfile -File scripts\proof-instance-win.ps1 -Exe C:\proof\pgvigil.exe -PgBin 'C:\pgsql\bin'
#     [-BaseExe C:\proof\pgvigil-base.exe] [-SqlServer localhost | -SqlServer localhost\NAME -GrantServiceLogin]
#   a run cut before its end (a time limit, a dropped session): the same command with -Undo runs the undo alone
# Expected (written before its first run, 2026-11-19; the review's fold 2026-11-19 14:5x):
#  C  the cluster up; 'pgvigil install' exit 0, the service as NT SERVICE\pgvigil; migrate (its own configuration
#     in the work folder) exit 0; the agent and monitor logins made from 'pgvigil roles'; repo.dsn holds the agent
#     login (the documented repository login); with -GrantServiceLogin the login made with exactly its two grants
#  R0 (with -BaseExe, a build before L170) 'instance add' exit 2 (an unknown command), no credential file, no page row
#  A1 'instance add -engine postgres -dsn-stdin' (the monitor login's dsn on stdin) exit 0, its line names
#     NT SERVICE\pgvigil and never the password
#  F1 its credential file instances\win-pg-<hex>.dpapi: the folder's list protected (nothing inherited); the file's
#     readers exactly SYSTEM, the Administrators and the service's SID - not this administrator's own SID; the
#     password not in the file's bytes
#  K1 (L169) 'pgvigil check': its 'secret files' rows OK on the installed folder; BUILTIN\Users given read on F1's
#     file = a FAIL 'secret files' row naming that reader and its 'icacls ... /remove:g *S-1-5-32-545' line; the
#     grant removed and the row OK again (check changes nothing itself)
#  A2 'instance add -engine sqlserver -dsn-stdin' (sqlserver://<host>[/<NAME>]?database=master, a Windows sign-in:
#     its connection test runs as this administrator, read only) exit 0
#  F2 its credential file instances\win-sql-<hex>.dpapi: the same list
#  S1 the service started collects win-pg within 180 s (a collection_dates row with status ok), so its account opened
#     the credential through that list; with -GrantServiceLogin win-sql too
#  L1 'instance list' under the agent login exit 0: win-pg page enabled, 'last collection <age> ago'; win-sql page
#     enabled, an age with -GrantServiceLogin, else 'no successful run now' (no successful collection: the service's account has no
#     login there; its collection rows' statuses printed)
#  D1 'instance disable' of both exit 0; the store reads both disabled (admin_inventory(), as the superuser); the
#     list shows both disabled
#  Z  the undo, each step on its own and read back: the service stopped, this run's instances folder removed,
#     'pgvigil uninstall -purge' (always), no service, %ProgramData%\pgvigil and %ProgramFiles%\pgvigil\pgvigil.exe
#     gone, with -GrantServiceLogin the login gone, the cluster stopped, the work folder removed
# Exit 0 = every row as stated (R0 'NOT RUN' without -BaseExe is not a failure); 1 = a row differs; 2 = refused.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$PgBin,
    [string]$BaseExe = '',
    [string]$SqlServer = 'localhost',
    [switch]$GrantServiceLogin,
    [switch]$Undo,
    [string]$Work = 'C:\pgvigil-instance-proof',
    [int]$Port = 55434
)
$ErrorActionPreference = 'Stop'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'REFUSED: run elevated'; exit 2 }
$DataDir = Join-Path $env:ProgramData 'pgvigil'
$InstDir = Join-Path $DataDir 'instances'
$Cfg = Join-Path $DataDir 'pgvigil.yaml'
$RepoDsnFile = Join-Path $DataDir 'repo.dsn'
$BinFile = Join-Path $env:ProgramFiles 'pgvigil\pgvigil.exe'
$LoginMark = Join-Path $Work 'login.made'
$pgData = Join-Path $Work 'pgdata'
$SvcLogin = 'NT SERVICE\pgvigil'
$SqlCmd = $null

function Invoke-Native([scriptblock]$cmd) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $cmd 2>&1 | ForEach-Object { "$_" }; return @{ Code = $LASTEXITCODE; Out = ($out -join "`n") } } finally { $ErrorActionPreference = $eap }
}
$failed = 0
function Row([string]$name, [bool]$ok, [string]$what) {
    if ($ok) { Write-Host "OK   $name $what" } else { Write-Host "FAIL $name $what"; $script:failed++ }
}
function Find-SqlCmd {
    $found = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
    if ($found) { $script:SqlCmd = $found.Source }
}
# -C: trust the instance's own certificate (ODBC 18's sqlcmd refuses a self-signed one without it)
function Invoke-TSql([string]$query) {
    return Invoke-Native { & $SqlCmd -S $SqlServer -E -C -b -h -1 -W -Q "SET NOCOUNT ON; $query" }
}
function Get-LoginCount {
    $res = Invoke-TSql "SELECT COUNT(*) FROM sys.server_principals WHERE name = N'$SvcLogin';"
    if ($res.Code -ne 0) { return -1 }
    $text = "$($res.Out)".Trim()
    if ($text -notmatch '^\d+$') { return -1 }
    return [int]$text
}

# Z: the undo, every step on its own (one that throws never skips the next) and read back
function Invoke-Undo {
    try {
        if (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) {
            Stop-Service -Name pgvigil -ErrorAction SilentlyContinue
            (Get-Service -Name pgvigil).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
        }
    } catch { Row 'Z' $false "the service's stop: $($_.Exception.Message)" }
    try {
        if (Test-Path -LiteralPath $InstDir) { Remove-Item -LiteralPath $InstDir -Recurse -Force }
        Row 'Z' (-not (Test-Path -LiteralPath $InstDir)) "$InstDir (this run's) removed"
    } catch { Row 'Z' $false "$InstDir not removed: $($_.Exception.Message)" }
    try {
        if (Test-Path -LiteralPath $Exe) { $res = Invoke-Native { & $Exe uninstall -purge } } else { $res = @{ Code = -1; Out = "no $Exe" } }
        Row 'Z' (-not (Get-Service -Name pgvigil -ErrorAction SilentlyContinue)) "uninstall -purge exit $($res.Code): no service pgvigil left"
        Row 'Z' (-not (Test-Path -LiteralPath $DataDir)) "$DataDir gone (the configuration, repo.dsn with the agent's password, the logs)"
        Row 'Z' (-not (Test-Path -LiteralPath $BinFile)) "$BinFile gone"
    } catch { Row 'Z' $false "the uninstall: $($_.Exception.Message)" }
    try {
        if (Test-Path -LiteralPath $LoginMark) {
            $script:SqlServer = ([IO.File]::ReadAllText($LoginMark)).Trim()
            if (-not $SqlCmd) { Find-SqlCmd }
            $res = Invoke-TSql "IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$SvcLogin') DROP LOGIN [$SvcLogin];"
            $left = Get-LoginCount
            $why = ''
            if ($left -ne 0) { $why = "; by hand on ${SqlServer}: SELECT session_id FROM sys.dm_exec_sessions WHERE login_name = N'$SvcLogin' - KILL each - then DROP LOGIN [$SvcLogin] ($($res.Out))" }
            Row 'Z' ($left -eq 0) "the login $SvcLogin dropped on $SqlServer (exit $($res.Code), left $left)$why"
        }
    } catch { Row 'Z' $false "the login's drop: $($_.Exception.Message)" }
    try {
        if (Test-Path -LiteralPath (Join-Path $pgData 'postmaster.pid')) { $null = Invoke-Native { & (Join-Path $PgBin 'pg_ctl.exe') -D $pgData -m fast -w stop } }
        Row 'Z' (-not (Test-Path -LiteralPath (Join-Path $pgData 'postmaster.pid'))) 'the cluster stopped'
    } catch { Row 'Z' $false "the cluster's stop: $($_.Exception.Message)" }
    try {
        if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
        Row 'Z' (-not (Test-Path -LiteralPath $Work)) "$Work removed"
    } catch { Row 'Z' $false "$Work not removed: $($_.Exception.Message)" }
}

if ($Undo) {
    if (-not (Test-Path -LiteralPath $Work)) { Write-Host "REFUSED: -Undo: no $Work - nothing of this proof's run is here"; exit 2 }
    Invoke-Undo
    if ($failed -eq 0) { Write-Host 'UNDONE: every step read back'; exit 0 }
    Write-Host "UNDO FAIL: $failed step(s)"; exit 1
}

if (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) { Write-Host 'REFUSED: the service pgvigil exists here - this proof runs on a machine without pgvigil'; exit 2 }
if (-not (Test-Path -LiteralPath $Exe)) { Write-Host "REFUSED: no $Exe"; exit 2 }
if ($BaseExe -and -not (Test-Path -LiteralPath $BaseExe)) { Write-Host "REFUSED: no $BaseExe"; exit 2 }
foreach ($tool in 'initdb.exe', 'pg_ctl.exe', 'psql.exe') { if (-not (Test-Path -LiteralPath (Join-Path $PgBin $tool))) { Write-Host "REFUSED: no $tool in $PgBin"; exit 2 } }
if (Test-Path -LiteralPath $Work) { Write-Host "REFUSED: $Work exists (a cut run's: this command with -Undo first)"; exit 2 }
foreach ($left in $InstDir, $Cfg, $RepoDsnFile) { if (Test-Path -LiteralPath $left) { Write-Host "REFUSED: $left exists (this proof removes what it makes, never what it found)"; exit 2 } }
if ($GrantServiceLogin) {
    Find-SqlCmd
    if (-not $SqlCmd) { Write-Host 'REFUSED: -GrantServiceLogin needs sqlcmd.exe on PATH'; exit 2 }
    $res = Invoke-TSql "SELECT ISNULL(CONVERT(nvarchar(128), SERVERPROPERTY('InstanceName')), N'<default>') + N' as ' + SUSER_SNAME();"
    $probe = "$($res.Out)".Trim()
    $instName = ($probe -split ' as ', 2)[0]
    if ($res.Code -ne 0 -or $instName -eq '' -or $instName -eq '<default>') { Write-Host "REFUSED: -GrantServiceLogin takes a NAMED instance (-SqlServer host\NAME); $SqlServer answers '$probe' (exit $($res.Code)) - the default instance is DBA Dash's and is never written to"; exit 2 }
    $had = Get-LoginCount
    if ($had -ne 0) { Write-Host "REFUSED: -GrantServiceLogin: the login $SvcLogin reads $had on $SqlServer (-1 = not readable) - this proof drops only a login it made"; exit 2 }
    Write-Host "the named instance: $probe"
}
$undoLine = "powershell.exe -NoProfile -File $($MyInvocation.MyCommand.Path) -Exe $Exe -PgBin '$PgBin' -Work $Work -Undo"
Write-Host "a run cut before its end is undone by: $undoLine"

$suPw = 'su' + [Guid]::NewGuid().ToString('N'); $agentPw = 'ag' + [Guid]::NewGuid().ToString('N'); $monPw = 'mo' + [Guid]::NewGuid().ToString('N')
$pgDsn = "host=127.0.0.1 port=$Port user=pgvigil_monitor password=$monPw dbname=postgres sslmode=disable"
# go-mssqldb's URL names an instance as its path (sqlserver://host/NAME), never host\NAME
$sqlHost = $SqlServer; $sqlPath = ''
if ($SqlServer -match '^([^\\]+)\\(.+)$') { $sqlHost = $Matches[1]; $sqlPath = '/' + $Matches[2] }
$sqlDsn = "sqlserver://$sqlHost$sqlPath`?database=master&encrypt=true&trustservercertificate=true"
$sidSystem = 'S-1-5-18'; $sidAdmins = 'S-1-5-32-544'; $sidUsers = 'S-1-5-32-545'
$sidMe = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$sidSvc = ''

# a statement goes to psql on stdin, never its command line (the passwords stay out of the process list)
function Invoke-Sql([string]$sql, [string]$db) {
    $env:PGPASSWORD = $suPw
    try { return Invoke-Native { $sql | & (Join-Path $PgBin 'psql.exe') -h 127.0.0.1 -p $Port -U postgres -d $db -XAtq -v ON_ERROR_STOP=1 -f - } } finally { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
}
function Get-Number([string]$sql) {
    $res = Invoke-Sql $sql 'pgvigil'
    if ($res.Code -ne 0) { return -1 }
    $text = "$($res.Out)".Trim()
    if ($text -notmatch '^\d+$') { return -1 }
    return [int]$text
}
# pg_ctl start with its output in files: a server started under a captured pipe keeps the pipe open and the capture
# never ends (the review's B1); the handle is held so ExitCode reads after WaitForExit
function Start-Cluster {
    $outFile = Join-Path $Work 'pg_ctl.out'; $errFile = Join-Path $Work 'pg_ctl.err'
    $argLine = "-D `"$pgData`" -l `"$(Join-Path $Work 'pg.log')`" -o `"-p $Port -c listen_addresses=127.0.0.1 -c log_min_error_statement=panic`" -w -t 120 start"
    $proc = Start-Process -FilePath (Join-Path $PgBin 'pg_ctl.exe') -ArgumentList $argLine -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $null = $proc.Handle
    if (-not $proc.WaitForExit(180000)) { throw 'pg_ctl start did not return in 180 s' }
    $status = Invoke-Native { & (Join-Path $PgBin 'pg_ctl.exe') -D $pgData status }
    if ($proc.ExitCode -ne 0 -or $status.Code -ne 0) {
        throw "pg_ctl start exit $($proc.ExitCode), status exit $($status.Code): $((Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue) -join ' ')"
    }
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
    $all = @((Get-Acl -LiteralPath $file).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $sids = @($all | Where-Object { $_.AccessControlType -eq 'Allow' } | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    $want = @($sidSystem, $sidAdmins, $sidSvc | Sort-Object -Unique)
    $exact = ($sids.Count -eq $want.Count) -and (@($sids | Where-Object { $want -notcontains $_ }).Count -eq 0)
    $denies = @($all | Where-Object { $_.AccessControlType -eq 'Deny' }).Count
    $inClear = $false
    if ($secret) { $inClear = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($file)).Contains($secret) }
    $meIn = $sids -contains $sidMe
    Row $rowName ($protected -and $exact -and -not $meIn -and -not $inClear) "$($files[0].Name): the folder's list protected $protected; readers $($sids -join ', ') (want SYSTEM, Administrators and the service's $sidSvc; deny entries $denies); this administrator's SID $sidMe in it $meIn; the secret in the file in clear $inClear"
}
# 'pgvigil check's 'secret files' rows: level and words
function Get-SecretFileRows {
    $res = Invoke-Native { & $Exe check -config $Cfg }
    $found = @()
    foreach ($line in ("$($res.Out)" -split "`n")) {
        if ($line -match '^(OK|WARN|FAIL)\s+secret files: (.*)$') { $found += , @($Matches[1], $Matches[2]) }
    }
    return $found
}
# 'pgvigil instance list' as a map name -> its line
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
    Start-Cluster
    $null = Invoke-Sql "CREATE ROLE pgvigil_owner LOGIN CREATEROLE PASSWORD '$suPw'" 'postgres'
    $null = Invoke-Sql 'CREATE DATABASE pgvigil OWNER pgvigil_owner' 'postgres'
    $inst = Invoke-Native { & $Exe install }
    $startName = (Get-CimInstance Win32_Service -Filter "Name='pgvigil'").StartName
    $sidSvc = (New-Object Security.Principal.NTAccount($SvcLogin)).Translate([Security.Principal.SecurityIdentifier]).Value
    # migrate on its own configuration in the work folder: the installed one names repo.dsn, empty until below, and
    # nothing in pgvigil reads PGVIGIL_REPO_DSN unless a configuration names it (the review's B2)
    $migCfg = Join-Path $Work 'migrate.yaml'
    [IO.File]::WriteAllText($migCfg, "repository:`n  dsn: env:PGVIGIL_REPO_DSN`ninstances: []`n")
    $env:PGVIGIL_REPO_DSN = "host=127.0.0.1 port=$Port user=pgvigil_owner password=$suPw dbname=pgvigil sslmode=disable"
    try { $mig = Invoke-Native { & $Exe migrate -config $migCfg } } finally { Remove-Item Env:PGVIGIL_REPO_DSN -ErrorAction SilentlyContinue }
    $roles = (Invoke-Native { & $Exe roles }).Out -split "`n"
    $made = 0
    foreach ($pair in @(@('agent', $agentPw), @('monitor', $monPw))) {
        $line = $roles | Where-Object { $_ -match "^CREATE ROLE pgvigil_$($pair[0]) LOGIN PASSWORD '<set-me>'" } | Select-Object -First 1
        if ($line) { if ((Invoke-Sql ($line -replace '<set-me>', $pair[1]) 'pgvigil').Code -eq 0) { $made++ } }
    }
    [IO.File]::WriteAllText($RepoDsnFile, "host=127.0.0.1 port=$Port user=pgvigil_agent password=$agentPw dbname=pgvigil sslmode=disable")
    $migLast = ''
    if ($mig.Code -ne 0) { $migLast = ': ' + ((("$($mig.Out)" -split "`n") | Select-Object -Last 1)) }
    Row 'C' ($inst.Code -eq 0 -and $startName -eq $SvcLogin -and $sidSvc -like 'S-1-5-80-*' -and $mig.Code -eq 0 -and $made -eq 2) "install exit $($inst.Code) as '$startName' (SID $sidSvc), migrate exit $($mig.Code)$migLast, logins made $made of 2, repo.dsn = the agent login"
    if ($GrantServiceLogin) {
        $res = Invoke-TSql "CREATE LOGIN [$SvcLogin] FROM WINDOWS; GRANT VIEW SERVER STATE TO [$SvcLogin]; GRANT VIEW ANY DEFINITION TO [$SvcLogin];"
        if ((Get-LoginCount) -eq 1) { [IO.File]::WriteAllText($LoginMark, $SqlServer) }
        $grants = Invoke-TSql "SELECT COUNT(*) FROM sys.server_permissions p JOIN sys.server_principals s ON s.principal_id = p.grantee_principal_id WHERE s.name = N'$SvcLogin' AND p.state = 'G' AND p.permission_name IN ('VIEW SERVER STATE', 'VIEW ANY DEFINITION');"
        Row 'C' ((Test-Path -LiteralPath $LoginMark) -and "$($grants.Out)".Trim() -eq '2') "-GrantServiceLogin: the login $SvcLogin on $SqlServer made $(Test-Path -LiteralPath $LoginMark), its grants $("$($grants.Out)".Trim()) of 2 (exit $($res.Code)$(if ($res.Code -ne 0) { ': ' + $res.Out }))"
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

    # K1 (L169): check's secret files judge on a real access list
    $before = @(Get-SecretFileRows)
    $okBefore = ($before.Count -ge 1) -and (@($before | Where-Object { $_[0] -ne 'OK' }).Count -eq 0)
    $pgFiles = Get-CredFiles 'win-pg'
    if ($pgFiles.Count -eq 1) {
        $target = $pgFiles[0].FullName
        $null = Invoke-Native { & icacls.exe $target /grant "*${sidUsers}:(R)" }
        $during = @(Get-SecretFileRows)
        $hit = @($during | Where-Object { $_[0] -eq 'FAIL' -and $_[1].Contains($target) -and $_[1].Contains("/remove:g *$sidUsers") })
        $null = Invoke-Native { & icacls.exe $target /remove:g "*$sidUsers" }
        $after = @(Get-SecretFileRows)
        $okAfter = ($after.Count -ge 1) -and (@($after | Where-Object { $_[0] -ne 'OK' }).Count -eq 0)
        $usersLeft = @((Get-Acl -LiteralPath $target).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq $sidUsers }).Count
        Row 'K1' ($okBefore -and $hit.Count -eq 1 -and $okAfter -and $usersLeft -eq 0) "check's secret files: before $(($before | ForEach-Object { $_[0] }) -join '/'), with Users' read $(($during | ForEach-Object { $_[0] }) -join '/') (the FAIL naming the file and its icacls line $($hit.Count)$(if ($hit.Count) { ': ' + $hit[0][1] })), after $(($after | ForEach-Object { $_[0] }) -join '/'); Users' entries left $usersLeft"
    } else {
        Row 'K1' $false "no single win-pg credential file to judge ($($pgFiles.Count))"
    }

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
    $sqlOk = $sqlLine -match '^win-sql\s+page\s+sqlserver\s+enabled\s+last collection no successful run now$'
    if ($GrantServiceLogin) { $sqlOk = $sqlLine -match '^win-sql\s+page\s+sqlserver\s+enabled\s+last collection \S+ ago$' }
    Row 'L1' ($list.Code -eq 0 -and $pgOk -and $sqlOk) "instance list (the agent login) exit $($list.Code): '$pgLine' / '$sqlLine'; win-sql's collection rows: $(Get-CollectionStatuses 'win-sql')$(if ($list.Code -ne 0) { '; said: ' + $list.Out })"

    # D1
    $d1 = Invoke-Native { & $Exe instance disable -config $Cfg -name win-pg }
    $d2 = Invoke-Native { & $Exe instance disable -config $Cfg -name win-sql }
    $offInStore = Get-Number "select count(*) from pgvigil.admin_inventory() where name in ('win-pg', 'win-sql') and disabled"
    $list = Get-ListLines
    $pgOff = "$($list.Lines['win-pg'])" -match '^win-pg\s+page\s+postgres\s+disabled\s'
    $sqlOff = "$($list.Lines['win-sql'])" -match '^win-sql\s+page\s+sqlserver\s+disabled\s'
    Row 'D1' ($d1.Code -eq 0 -and $d2.Code -eq 0 -and $offInStore -eq 2) "disable exit $($d1.Code) / $($d2.Code); the store reads $offInStore of 2 disabled"
    Row 'D1' ($list.Code -eq 0 -and $pgOff -and $sqlOff) "list exit $($list.Code): '$($list.Lines['win-pg'])' / '$($list.Lines['win-sql'])'"
} catch {
    Row 'X' $false "the proof stopped: $($_.Exception.Message)"
} finally {
    Invoke-Undo
    $suPw = $null; $agentPw = $null; $monPw = $null; $pgDsn = $null
}
if ($failed -eq 0) { Write-Host 'PASS: every row'; exit 0 }
Write-Host "FAIL: $failed row(s)"; exit 1
