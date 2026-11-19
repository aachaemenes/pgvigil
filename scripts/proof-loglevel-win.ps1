# proof-loglevel-win.ps1 - Windows PowerShell 5.1 or 7, elevated, on a throwaway lab VM ONLY (dba-lab-win through
# the WIN queue): the Windows service's log file follows log_level (RELNOTES L172). It makes a throwaway PostgreSQL
# cluster on 127.0.0.1 from a PostgreSQL bin folder (the repository and the monitored server), installs the service
# pgvigil, runs it three times and reads the lines each run added to %ProgramData%\pgvigil\logs\pgvigil.log; then it
# removes all of it. It refuses to start where the service pgvigil already exists.
#   powershell.exe -NoProfile -File scripts\proof-loglevel-win.ps1 -Exe C:\proof\pgvigil.exe -PgBin 'C:\Program Files\PostgreSQL\17\bin'
# Expected (written before its first run, 2026-11-19):
#  C  the cluster up; 'pgvigil install' exit 0, the service as NT SERVICE\pgvigil; migrate exit 0; the agent and
#     monitor logins made from 'pgvigil roles'; the cluster named as the instance win-target in pgvigil.yaml
#  D1 log_level: debug - the run's lines hold level=DEBUG (the collector's msg=collected) and msg="service stopped"
#  W1 log_level: warn - the collector sampled during the run (activity_summary of win-target grew), and the run's
#     lines hold no level=DEBUG and no level=INFO but msg="service starting" (written before the configuration is
#     read: only PGVIGIL_LOG_LEVEL governs that one line)
#  E1 log_level: warn in the file, PGVIGIL_LOG_LEVEL=debug in the service's environment (its registry Environment
#     value): the run's lines hold level=DEBUG - the variable wins
#  Z  the undo, each read back: the Environment value gone, 'pgvigil uninstall -purge' leaves no service, the
#     cluster stopped, the work folder removed
# Exit 0 = every row as stated; 1 = a row differs; 2 = refused to start.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$PgBin,
    [string]$Work = 'C:\pgvigil-loglevel-proof',
    [int]$Port = 55433
)
$ErrorActionPreference = 'Stop'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'REFUSED: run elevated'; exit 2 }
if (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) { Write-Host 'REFUSED: the service pgvigil exists here - this proof runs on a machine without pgvigil'; exit 2 }
if (-not (Test-Path -LiteralPath $Exe)) { Write-Host "REFUSED: no $Exe"; exit 2 }
foreach ($tool in 'initdb.exe', 'pg_ctl.exe', 'psql.exe') { if (-not (Test-Path -LiteralPath (Join-Path $PgBin $tool))) { Write-Host "REFUSED: no $tool in $PgBin"; exit 2 } }
if (Test-Path -LiteralPath $Work) { Write-Host "REFUSED: $Work exists (a run of its own folder only)"; exit 2 }

function Invoke-Native([scriptblock]$cmd) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $cmd 2>&1 | ForEach-Object { "$_" }; return @{ Code = $LASTEXITCODE; Out = ($out -join "`n") } } finally { $ErrorActionPreference = $eap }
}
$failed = 0
function Row([string]$name, [bool]$ok, [string]$what) {
    if ($ok) { Write-Host "OK   $name $what" } else { Write-Host "FAIL $name $what"; $script:failed++ }
}
$Cfg = Join-Path $env:ProgramData 'pgvigil\pgvigil.yaml'
$LogPath = Join-Path $env:ProgramData 'pgvigil\logs\pgvigil.log'
$SvcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\pgvigil'
$suPw = 'su' + [Guid]::NewGuid().ToString('N'); $agentPw = 'ag' + [Guid]::NewGuid().ToString('N'); $monPw = 'mo' + [Guid]::NewGuid().ToString('N')
$pgData = Join-Path $Work 'pgdata'

# a statement goes to psql on stdin, never its command line (the passwords stay out of the process list)
function Invoke-Sql([string]$sql, [string]$db) {
    $env:PGPASSWORD = $suPw
    try { return Invoke-Native { $sql | & (Join-Path $PgBin 'psql.exe') -h 127.0.0.1 -p $Port -U postgres -d $db -XAtq -v ON_ERROR_STOP=1 -f - } } finally { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
}
# pg_ctl start with its output in files: a server started under a captured pipe keeps the pipe open and the capture
# never ends (rn-l170win-rerun's B1, the same line here); the handle is held so ExitCode reads after WaitForExit
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
$hasDebug = { param($from) @(Read-LogSince $from | Where-Object { $_ -match 'level=DEBUG' }).Count -gt 0 }

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
    # nothing in pgvigil reads PGVIGIL_REPO_DSN unless a configuration names it (rn-l170win-rerun's B2, the same here)
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
    [IO.File]::WriteAllText((Join-Path $env:ProgramData 'pgvigil\repo.dsn'), "host=127.0.0.1 port=$Port user=pgvigil_agent password=$agentPw dbname=pgvigil sslmode=disable")
    $tdsn = Join-Path $env:ProgramData 'pgvigil\target.dsn'
    [IO.File]::WriteAllText($tdsn, "host=127.0.0.1 port=$Port user=pgvigil_monitor password=$monPw dbname=postgres sslmode=disable")
    $cfgText = [IO.File]::ReadAllText($Cfg)
    $named = $cfgText -match 'instances: \[\]'
    [IO.File]::WriteAllText($Cfg, ($cfgText -replace 'instances: \[\]', "instances:`n  - name: win-target`n    dsn: file:$($tdsn -replace '\\', '/')"))
    Row 'C' ($inst.Code -eq 0 -and $startName -eq 'NT SERVICE\pgvigil' -and $mig.Code -eq 0 -and $made -eq 2 -and $named) "install exit $($inst.Code) as '$startName', migrate exit $($mig.Code), logins made $made of 2, the instance named in the file $named"

    # D1
    Set-LogLevel 'debug'
    $run = Invoke-ServiceRun $hasDebug
    $debugN = @($run.Lines | Where-Object { $_ -match 'level=DEBUG' }).Count
    $stopped = @($run.Lines | Where-Object { $_ -match 'msg="service stopped"' }).Count
    Row 'D1' ($debugN -gt 0 -and $stopped -eq 1) "log_level: debug - the run's lines $($run.Lines.Count), level=DEBUG $debugN, 'service stopped' $stopped (last: $($run.Tail))"

    # W1
    Set-LogLevel 'warn'
    $before = Get-SampleCount
    $run = Invoke-ServiceRun { param($from) (Get-SampleCount) -gt $before }
    $after = Get-SampleCount
    $debugN = @($run.Lines | Where-Object { $_ -match 'level=DEBUG' }).Count
    $infoOther = @($run.Lines | Where-Object { $_ -match 'level=INFO' -and $_ -notmatch 'msg="service starting"' })
    Row 'W1' ($before -ge 0 -and $after -gt $before -and $debugN -eq 0 -and $infoOther.Count -eq 0) "log_level: warn - samples $before -> $after, the run's lines $($run.Lines.Count), level=DEBUG $debugN, level=INFO but 'service starting' $($infoOther.Count)$(if ($infoOther.Count) { ': ' + (($infoOther | Select-Object -First 3) -join ' | ') })"

    # E1
    Set-ItemProperty -Path $SvcKey -Name Environment -Type MultiString -Value @('PGVIGIL_LOG_LEVEL=debug')
    $run = Invoke-ServiceRun $hasDebug
    $debugN = @($run.Lines | Where-Object { $_ -match 'level=DEBUG' }).Count
    Row 'E1' ($debugN -gt 0) "log_level: warn in the file, PGVIGIL_LOG_LEVEL=debug in the service's environment - level=DEBUG $debugN (last: $($run.Tail))"
} catch {
    Row 'X' $false "the proof stopped: $($_.Exception.Message)"
} finally {
    # Z: the undo, each step read back
    if (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) {
        Stop-Service -Name pgvigil -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $SvcKey -Name Environment -ErrorAction SilentlyContinue
        Row 'Z' ($null -eq (Get-ItemProperty -Path $SvcKey -Name Environment -ErrorAction SilentlyContinue)) "the service's Environment value removed"
        $null = Invoke-Native { & $Exe uninstall -purge }
    }
    Row 'Z' (-not (Get-Service -Name pgvigil -ErrorAction SilentlyContinue)) 'no service pgvigil left'
    if (Test-Path -LiteralPath (Join-Path $pgData 'postmaster.pid')) { $null = Invoke-Native { & (Join-Path $PgBin 'pg_ctl.exe') -D $pgData -m fast -w stop } }
    Row 'Z' (-not (Test-Path -LiteralPath (Join-Path $pgData 'postmaster.pid'))) 'the cluster stopped'
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    Row 'Z' (-not (Test-Path -LiteralPath $Work)) "$Work removed"
    $suPw = $null; $agentPw = $null; $monPw = $null
}
if ($failed -eq 0) { Write-Host 'PASS: every row'; exit 0 }
Write-Host "FAIL: $failed row(s)"; exit 1
