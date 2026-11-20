# proof-loglevel-win.ps1 - Windows PowerShell 5.1 or 7, elevated, on a throwaway lab VM ONLY (dba-lab-win through
# the WIN queue): the Windows service's log file follows log_level. It makes a throwaway PostgreSQL cluster on
# 127.0.0.1 from a PostgreSQL bin folder (the repository and the monitored server), installs the service pgvigil,
# runs it four times and reads the lines each run added to %ProgramData%\pgvigil\logs\pgvigil.log; then it removes
# all of it, each step read back. It refuses to start where the service pgvigil, a pgvigil.yaml, repo.dsn or
# target.dsn under %ProgramData%\pgvigil, or a machine-wide PGVIGIL_LOG_LEVEL already exists (it removes what it
# makes, never what it found).
#   powershell.exe -NoProfile -File scripts\proof-loglevel-win.ps1 -Exe C:\proof\pgvigil.exe -PgBin 'C:\Program Files\PostgreSQL\17\bin'
#   a run cut before its end (a time limit, a dropped session): the same command with -Undo runs the undo alone
# -Exe must be a build where every command applies log_level and the service warns on an unknown PGVIGIL_LOG_LEVEL
# (rows E1's override line and E2 read both).
# Expected (written before its first run, 2026-11-19; rows E1's override line, E2 and the undo form added 2026-11-20):
#  C  the cluster up; 'pgvigil install' exit 0, the service as NT SERVICE\pgvigil; migrate (its own configuration
#     in the work folder) exit 0; the agent and monitor logins made from 'pgvigil roles'; the cluster named as the
#     instance win-target in pgvigil.yaml
#  D1 log_level: debug - the run's lines hold a collection's level=DEBUG msg=collected and msg="service stopped"
#  W1 log_level: warn - the collector sampled during the run (activity_summary of win-target grew), and the run's
#     lines hold no level=DEBUG, no level=INFO but msg="service starting" (written before the configuration is
#     read: only PGVIGIL_LOG_LEVEL governs that one line), and exactly one 'service starting' (no crash and restart)
#  E1 log_level: warn in the file, PGVIGIL_LOG_LEVEL=debug in the service's environment (its registry Environment
#     value): the run's lines hold level=DEBUG msg=collected - the variable wins - and one WARN line saying the
#     variable overrides the file's log_level, naming both
#  E2 PGVIGIL_LOG_LEVEL=loud in the service's environment, log_level: warn in the file: the collector sampled, the
#     run's lines hold exactly one WARN 'PGVIGIL_LOG_LEVEL is not a log level' with value=loud and no level=DEBUG
#  Z  the undo, each step on its own and read back: the service stopped, its Environment value gone, target.dsn
#     gone, 'pgvigil uninstall -purge' (always), no service, %ProgramData%\pgvigil and
#     %ProgramFiles%\pgvigil\pgvigil.exe gone, the cluster stopped, the work folder removed
# Exit 0 = every row as stated; 1 = a row differs; 2 = refused to start.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$PgBin,
    [switch]$Undo,
    [string]$Work = 'C:\pgvigil-loglevel-proof',
    [int]$Port = 55433
)
$ErrorActionPreference = 'Stop'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'REFUSED: run elevated'; exit 2 }
$DataDir = Join-Path $env:ProgramData 'pgvigil'
$Cfg = Join-Path $DataDir 'pgvigil.yaml'
$RepoDsnFile = Join-Path $DataDir 'repo.dsn'
$TargetDsn = Join-Path $DataDir 'target.dsn'
$LogPath = Join-Path $DataDir 'logs\pgvigil.log'
$BinFile = Join-Path $env:ProgramFiles 'pgvigil\pgvigil.exe'
$SvcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\pgvigil'
$pgData = Join-Path $Work 'pgdata'

function Invoke-Native([scriptblock]$cmd) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $cmd 2>&1 | ForEach-Object { "$_" }; return @{ Code = $LASTEXITCODE; Out = ($out -join "`n") } } finally { $ErrorActionPreference = $eap }
}
$failed = 0
function Row([string]$name, [bool]$ok, [string]$what) {
    if ($ok) { Write-Host "OK   $name $what" } else { Write-Host "FAIL $name $what"; $script:failed++ }
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
        if (Test-Path -LiteralPath $SvcKey) { Remove-ItemProperty -Path $SvcKey -Name Environment -ErrorAction SilentlyContinue }
        Row 'Z' ($null -eq (Get-ItemProperty -Path $SvcKey -Name Environment -ErrorAction SilentlyContinue)) "the service's Environment value gone"
    } catch { Row 'Z' $false "the Environment value: $($_.Exception.Message)" }
    try {
        if (Test-Path -LiteralPath $TargetDsn) { Remove-Item -LiteralPath $TargetDsn -Force }
        Row 'Z' (-not (Test-Path -LiteralPath $TargetDsn)) "$TargetDsn (the monitor login's password) removed"
    } catch { Row 'Z' $false "$TargetDsn not removed: $($_.Exception.Message)" }
    try {
        if (Test-Path -LiteralPath $Exe) { $res = Invoke-Native { & $Exe uninstall -purge } } else { $res = @{ Code = -1; Out = "no $Exe" } }
        Row 'Z' (-not (Get-Service -Name pgvigil -ErrorAction SilentlyContinue)) "uninstall -purge exit $($res.Code): no service pgvigil left"
        Row 'Z' (-not (Test-Path -LiteralPath $DataDir)) "$DataDir gone (the configuration, repo.dsn with the agent's password, the logs)"
        Row 'Z' (-not (Test-Path -LiteralPath $BinFile)) "$BinFile gone"
    } catch { Row 'Z' $false "the uninstall: $($_.Exception.Message)" }
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
foreach ($tool in 'initdb.exe', 'pg_ctl.exe', 'psql.exe') { if (-not (Test-Path -LiteralPath (Join-Path $PgBin $tool))) { Write-Host "REFUSED: no $tool in $PgBin"; exit 2 } }
if (Test-Path -LiteralPath $Work) { Write-Host "REFUSED: $Work exists (a cut run's: this command with -Undo first)"; exit 2 }
foreach ($left in $Cfg, $RepoDsnFile, $TargetDsn) { if (Test-Path -LiteralPath $left) { Write-Host "REFUSED: $left exists (this proof removes what it makes, never what it found)"; exit 2 } }
$machineLevel = [Environment]::GetEnvironmentVariable('PGVIGIL_LOG_LEVEL', 'Machine')
if ($machineLevel) { Write-Host "REFUSED: the machine environment holds PGVIGIL_LOG_LEVEL=$machineLevel (every row reads the level the file or the service's own environment sets)"; exit 2 }
$undoLine = "powershell.exe -NoProfile -File $($MyInvocation.MyCommand.Path) -Exe $Exe -PgBin '$PgBin' -Work $Work -Undo"
Write-Host "a run cut before its end is undone by: $undoLine"

$suPw = 'su' + [Guid]::NewGuid().ToString('N'); $agentPw = 'ag' + [Guid]::NewGuid().ToString('N'); $monPw = 'mo' + [Guid]::NewGuid().ToString('N')

# a statement goes to psql on stdin, never its command line (the passwords stay out of the process list)
function Invoke-Sql([string]$sql, [string]$db) {
    $env:PGPASSWORD = $suPw
    try { return Invoke-Native { $sql | & (Join-Path $PgBin 'psql.exe') -h 127.0.0.1 -p $Port -U postgres -d $db -XAtq -v ON_ERROR_STOP=1 -f - } } finally { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
}
# pg_ctl start with its output in files: a server started under a captured pipe keeps the pipe open and the capture
# never ends; the handle is held so ExitCode reads after WaitForExit
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
function Get-LogLength { if (Test-Path -LiteralPath $LogPath) { return (Get-Item -LiteralPath $LogPath).Length } else { return 0 } }
function Read-LogSince([long]$from) {
    if (-not (Test-Path -LiteralPath $LogPath)) { return @() }
    $fs = [IO.File]::Open($LogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { [void]$fs.Seek($from, [IO.SeekOrigin]::Begin); $text = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    return @($text -split "`r?`n" | Where-Object { $_ })
}
function Set-LogLevel([string]$level) {
    $text = [IO.File]::ReadAllText($Cfg)
    $text = [regex]::Replace($text, '(?m)^log_level:.*\r?\n', '')
    [IO.File]::WriteAllText($Cfg, "log_level: $level`n" + $text)
}
function Get-SampleCount {
    $res = Invoke-Sql "select count(*) from pgvigil.activity_summary s join pgvigil.instances i on i.instance_id = s.instance_id where i.name = 'win-target'" 'pgvigil'
    if ($res.Code -ne 0) { return -1 }
    return [int]("$($res.Out)".Trim())
}
# one run: start the service, wait (120 s at most) until $until says the run did its work, stop it, and return the
# lines the run added to the log
function Invoke-ServiceRun([scriptblock]$until) {
    $from = Get-LogLength
    Start-Service -Name pgvigil
    $done = $false
    foreach ($tick in 1..120) {
        Start-Sleep -Seconds 1
        if (& $until $from) { $done = $true; break }
        if ((Get-Service -Name pgvigil).Status -ne 'Running') { break }
    }
    Stop-Service -Name pgvigil -ErrorAction SilentlyContinue
    (Get-Service -Name pgvigil).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
    $lines = Read-LogSince $from
    return @{ Done = $done; Lines = $lines; Tail = (($lines | Select-Object -Last 4) -join ' | ') }
}
function Get-Count([object[]]$lines, [string]$pattern) { return @($lines | Where-Object { $_ -match $pattern }).Count }
# a collection's own debug line (the scheduler's 'collection off by config' is DEBUG at every start, so a bare
# level=DEBUG proves no collection)
$collectedDebug = 'level=DEBUG msg=collected '
$hasCollected = { param($from) (Get-Count (Read-LogSince $from) $collectedDebug) -gt 0 }

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
    # migrate on its own configuration in the work folder: the installed one names repo.dsn, empty until below, and
    # nothing in pgvigil reads PGVIGIL_REPO_DSN unless a configuration names it
    $migCfg = Join-Path $Work 'migrate.yaml'
    [IO.File]::WriteAllText($migCfg, "repository:`n  dsn: env:PGVIGIL_REPO_DSN`ninstances: []`n")
    $env:PGVIGIL_REPO_DSN = "host=127.0.0.1 port=$Port user=pgvigil_owner password=$suPw dbname=pgvigil sslmode=disable"
    try { $mig = Invoke-Native { & $Exe migrate -config $migCfg } } finally { Remove-Item Env:PGVIGIL_REPO_DSN -ErrorAction SilentlyContinue }
    $migLast = ''
    if ($mig.Code -ne 0) { $migLast = "; migrate's last line: " + (("$($mig.Out)" -split "`n" | Where-Object { $_ } | Select-Object -Last 1)) }
    $roles = (Invoke-Native { & $Exe roles }).Out -split "`n"
    $made = 0
    foreach ($pair in @(@('agent', $agentPw), @('monitor', $monPw))) {
        $line = $roles | Where-Object { $_ -match "^CREATE ROLE pgvigil_$($pair[0]) LOGIN PASSWORD '<set-me>'" } | Select-Object -First 1
        if ($line) { if ((Invoke-Sql ($line -replace '<set-me>', $pair[1]) 'pgvigil').Code -eq 0) { $made++ } }
    }
    [IO.File]::WriteAllText($RepoDsnFile, "host=127.0.0.1 port=$Port user=pgvigil_agent password=$agentPw dbname=pgvigil sslmode=disable")
    [IO.File]::WriteAllText($TargetDsn, "host=127.0.0.1 port=$Port user=pgvigil_monitor password=$monPw dbname=postgres sslmode=disable")
    $cfgText = [IO.File]::ReadAllText($Cfg)
    $named = $cfgText -match 'instances: \[\]'
    [IO.File]::WriteAllText($Cfg, ($cfgText -replace 'instances: \[\]', "instances:`n  - name: win-target`n    dsn: file:$($TargetDsn -replace '\\', '/')"))
    Row 'C' ($inst.Code -eq 0 -and $startName -eq 'NT SERVICE\pgvigil' -and $mig.Code -eq 0 -and $made -eq 2 -and $named) "install exit $($inst.Code) as '$startName', migrate exit $($mig.Code)$migLast, logins made $made of 2, the instance named in the file $named"

    # D1
    Set-LogLevel 'debug'
    $run = Invoke-ServiceRun $hasCollected
    $collectedN = Get-Count $run.Lines $collectedDebug
    $stopped = Get-Count $run.Lines 'msg="service stopped"'
    Row 'D1' ($collectedN -gt 0 -and $stopped -eq 1) "log_level: debug - the run's lines $($run.Lines.Count), level=DEBUG msg=collected $collectedN, 'service stopped' $stopped (last: $($run.Tail))"

    # W1
    Set-LogLevel 'warn'
    $before = Get-SampleCount
    $run = Invoke-ServiceRun { param($from) (Get-SampleCount) -gt $before }
    $after = Get-SampleCount
    $debugN = Get-Count $run.Lines 'level=DEBUG'
    $starting = Get-Count $run.Lines 'msg="service starting"'
    $infoOther = @($run.Lines | Where-Object { $_ -match 'level=INFO' -and $_ -notmatch 'msg="service starting"' })
    Row 'W1' ($before -ge 0 -and $after -gt $before -and $debugN -eq 0 -and $infoOther.Count -eq 0 -and $starting -eq 1) "log_level: warn - samples $before -> $after, the run's lines $($run.Lines.Count), level=DEBUG $debugN, 'service starting' $starting, level=INFO but 'service starting' $($infoOther.Count)$(if ($infoOther.Count) { ': ' + (($infoOther | Select-Object -First 3) -join ' | ') })"

    # E1
    Set-ItemProperty -Path $SvcKey -Name Environment -Type MultiString -Value @('PGVIGIL_LOG_LEVEL=debug')
    $run = Invoke-ServiceRun $hasCollected
    $collectedN = Get-Count $run.Lines $collectedDebug
    $override = @($run.Lines | Where-Object { $_ -match 'level=WARN msg="PGVIGIL_LOG_LEVEL overrides the configuration''s log_level"' })
    $overrideOk = $override.Count -eq 1 -and "$($override[0])" -match 'PGVIGIL_LOG_LEVEL=debug' -and "$($override[0])" -match 'log_level=warn'
    Row 'E1' ($collectedN -gt 0 -and $overrideOk) "log_level: warn in the file, PGVIGIL_LOG_LEVEL=debug in the service's environment - level=DEBUG msg=collected $collectedN, the override line $($override.Count)$(if ($override.Count) { ': ' + $override[0] })"

    # E2
    Set-ItemProperty -Path $SvcKey -Name Environment -Type MultiString -Value @('PGVIGIL_LOG_LEVEL=loud')
    $before = Get-SampleCount
    $run = Invoke-ServiceRun { param($from) (Get-SampleCount) -gt $before }
    $after = Get-SampleCount
    $badWord = @($run.Lines | Where-Object { $_ -match 'level=WARN msg="PGVIGIL_LOG_LEVEL is not a log level' -and $_ -match 'value=loud' })
    $debugN = Get-Count $run.Lines 'level=DEBUG'
    Row 'E2' ($after -gt $before -and $badWord.Count -eq 1 -and $debugN -eq 0) "PGVIGIL_LOG_LEVEL=loud over log_level: warn - samples $before -> $after, the unknown-word line $($badWord.Count), level=DEBUG $debugN (last: $($run.Tail))"
} catch {
    Row 'X' $false "the proof stopped: $($_.Exception.Message)"
} finally {
    Invoke-Undo
    $suPw = $null; $agentPw = $null; $monPw = $null
}
if ($failed -eq 0) { Write-Host 'PASS: every row'; exit 0 }
Write-Host "FAIL: $failed row(s)"; exit 1
