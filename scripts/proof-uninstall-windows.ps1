# Proof of pgvigil uninstall -all on Windows (task 203, docs/uninstall.md), run INSIDE the Windows sandbox with its
# network adapter off, from an elevated Windows PowerShell 5.1. Everything it uses is on local disk before the adapter
# goes off: the extracted offline bundle (scripts/proof-offline.sh lays it out) and a PostgreSQL bin folder (initdb,
# pg_ctl, psql, pg_dump of one major version) for a throwaway cluster on 127.0.0.1 as the repository and the monitored
# server.
#   -Bundle  <folder>   the extracted pgvigil-offline-<v>-windows-amd64
#   -PgBin   <folder>   PostgreSQL's bin folder, 16 or newer (the role rules uninstall -drop-repository checks)
#   -Work    <folder>   a scratch folder on local disk (default C:\pgvigil-uninstall-proof; removed at the end)
# Expected (written before its first run; NOT run by this project yet: the sandbox was another lane's):
#  N   no network adapter is up
#  S   install.ps1 -From the bundle -App -UpdateCheck: the service pgvigil, the app machine-wide, the HKLM Run value,
#      the Programs and Features entry, the policy key, the machine PATH entry; pgvigil-app install -user: this user's
#      app; the repository migrated by its owner, the agent login in repo.dsn, the service collecting the local cluster
#  C   refused with nothing changed: no terminal and no -confirm-database; a wrong -confirm-database
#  P   the dry run names every item 'remove' (the app, this user's app, Run HKLM and HKCU, Programs and Features, the
#      policy keys, the PATH entry, the service, the binary, the configuration folder, the database, the agent and the
#      groups) and 'dry run: nothing was changed'; the service still runs
#  U   with this user's app running (started from %LOCALAPPDATA%\pgvigil), uninstall -all -drop-repository
#      -confirm-database pgvigil (run from a copy of pgvigil.exe in -Work, so the installed one is not in use): 'ended
#      this user's running app'; read back: no service, no %ProgramFiles%\pgvigil, no %ProgramData%\pgvigil, no
#      %LOCALAPPDATA%\pgvigil, no Run value, Programs and Features entry, policy key or HKCU settings, the PATH without
#      the folder, no role pgvigil_% but the monitor and the owner, no database pgvigil, the dump in
#      %ProgramData%\pgvigil-backups
#  R   a second run: 'nothing of pgvigil is left to remove', exit 0
#  X   the cluster, -Work and the dumps removed
param(
    [Parameter(Mandatory)][string]$Bundle,
    [Parameter(Mandatory)][string]$PgBin,
    [string]$Work = 'C:\pgvigil-uninstall-proof'
)
$ErrorActionPreference = 'Stop'
function Fail([string]$m) { Write-Host "FAIL: $m"; exit 1 }
function Ok([string]$m) { Write-Host "ok   $m" }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Fail 'run it elevated' }
foreach ($f in 'initdb.exe', 'pg_ctl.exe', 'psql.exe', 'pg_dump.exe') { if (-not (Test-Path (Join-Path $PgBin $f))) { Fail "no $f in $PgBin" } }
$up = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
if ($up.Count -gt 0) { Fail "a network adapter is up: $($up.Name -join ', ') (turn it off first)" }
Ok 'N no network adapter is up'
$pf = Join-Path $env:ProgramFiles 'pgvigil'; $exe = Join-Path $pf 'pgvigil.exe'; $pd = Join-Path $env:ProgramData 'pgvigil'
$mine = Join-Path $env:LOCALAPPDATA 'pgvigil'
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$pw = 'ow' + (Get-Random) + (Get-Random); $apw = 'ag' + (Get-Random); $mpw = 'mo' + (Get-Random)
$port = 55433
function State {
    $s = @()
    foreach ($p in $exe, $pd, $mine, (Join-Path $pf 'pgvigil-app.exe')) { $s += "$p $(Test-Path $p)" }
    $s += "service $((Get-Service pgvigil -ErrorAction SilentlyContinue).Status)"
    $s += "run-hklm $([bool](Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name pgvigil -ErrorAction SilentlyContinue))"
    $s += "run-hkcu $([bool](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name pgvigil -ErrorAction SilentlyContinue))"
    foreach ($k in 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\pgvigil', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\pgvigil', 'HKLM:\Software\Policies\pgvigil', 'HKCU:\Software\pgvigil') { $s += "$k $(Test-Path $k)" }
    $s += "path $(([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';') -contains $pf)"
    $s += "roles $(Q "select string_agg(rolname, ',' order by rolname) from pg_roles where rolname like 'pgvigil%'" 'postgres')"
    $s += "databases $(Q "select string_agg(datname, ',' order by datname) from pg_database" 'postgres')"
    return ($s -join "`n")
}
try {
    $pwfile = Join-Path $Work 'su.pw'; Set-Content -LiteralPath $pwfile -Value $pw -NoNewline
    & (Join-Path $PgBin 'initdb.exe') -D (Join-Path $Work 'pgdata') -U postgres --auth=scram-sha-256 --pwfile=$pwfile -E UTF8 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'initdb' }
    & (Join-Path $PgBin 'pg_ctl.exe') -D (Join-Path $Work 'pgdata') -l (Join-Path $Work 'pg.log') -o "-p $port -c listen_addresses=127.0.0.1" -w start | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'pg_ctl start' }
    $env:PGPASSWORD = $pw
    function Q([string]$sql, [string]$db = 'pgvigil', [string]$as = 'postgres') { $o = & (Join-Path $PgBin 'psql.exe') -h 127.0.0.1 -p $port -U $as -d $db -XAtq -v ON_ERROR_STOP=1 -c $sql; if ($LASTEXITCODE -ne 0) { Fail "psql: $sql" }; return $o }
    if ([int](Q "select current_setting('server_version_num')::int / 10000" 'postgres') -lt 16) { Fail '-PgBin is older than PostgreSQL 16' }

    # S the install: the collector, the app machine-wide and this user's, the repository, the service collecting
    $s = & (Join-Path $Bundle 'install.ps1') -From $Bundle -App -UpdateCheck *>&1 | Out-String
    if (-not (Get-Service pgvigil -ErrorAction SilentlyContinue)) { Fail "S: no service after install.ps1: $s" }
    $app = Join-Path $pf 'pgvigil-app.exe'
    Start-Process -FilePath $app -ArgumentList 'install', '-user' -Wait -NoNewWindow
    if (-not (Test-Path (Join-Path $mine 'pgvigil-app.exe'))) { Fail 'S: no per-user app' }
    Q "CREATE ROLE pgvigil_owner LOGIN CREATEROLE PASSWORD '$pw'" 'postgres' | Out-Null
    Q 'CREATE DATABASE pgvigil OWNER pgvigil_owner' 'postgres' | Out-Null
    $owner = "host=127.0.0.1 port=$port user=pgvigil_owner password=$pw dbname=pgvigil sslmode=disable"
    $cfg = Join-Path $pd 'pgvigil.yaml'
    $env:PGVIGIL_REPO_DSN = $owner
    & $exe migrate -config $cfg | Out-Null; if ($LASTEXITCODE -ne 0) { Fail 'S: migrate' }
    Remove-Item Env:PGVIGIL_REPO_DSN
    $roles = & $exe roles
    foreach ($r in @(@('agent', $apw), @('monitor', $mpw))) {
        $line = ($roles | Where-Object { $_ -match "^CREATE ROLE pgvigil_$($r[0]) LOGIN PASSWORD '<set-me>'" } | Select-Object -First 1) -replace '<set-me>', $r[1]
        if ($r[0] -eq 'monitor') { Q $line 'postgres' | Out-Null } else { Q $line 'pgvigil' 'pgvigil_owner' | Out-Null }   # the agent made by the owner (a CREATEROLE login), as the Linux proof
    }
    Set-Content -LiteralPath (Join-Path $pd 'repo.dsn') -Value "host=127.0.0.1 port=$port user=pgvigil_agent password=$apw dbname=pgvigil sslmode=disable" -NoNewline
    $tdsn = Join-Path $Work 'target.dsn'   # outside the configuration folder: a file there that is not the installer's keeps the folder
    Set-Content -LiteralPath $tdsn -Value "host=127.0.0.1 port=$port user=pgvigil_monitor password=$mpw dbname=postgres sslmode=disable" -NoNewline
    (Get-Content $cfg -Raw) -replace 'instances: \[\]', "instances:`n  - name: win-target`n    dsn: file:$($tdsn -replace '\\','/')`n    tags: [proof]" | Set-Content $cfg
    Start-Service pgvigil
    $n = 0; foreach ($i in 1..90) { $n = [int](Q "select count(*) from pgvigil.collection_dates"); if ($n -gt 0) { break }; Start-Sleep 1 }
    if ($n -eq 0) { Fail 'S: no collection_dates row in 90 s' }
    $ofile = Join-Path $Work 'owner.dsn'; Set-Content -LiteralPath $ofile -Value $owner -NoNewline
    $copy = Join-Path $Work 'pgvigil.exe'; Copy-Item -LiteralPath $exe -Destination $copy
    Ok "S the collector, the app machine-wide and this user's, the repository, the service collecting ($n rows)"

    # C refusals
    $before = State
    $c1 = '' | & $copy uninstall -all -drop-repository -owner-dsn-file $ofile -pg-dump (Join-Path $PgBin 'pg_dump.exe') 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $c1 -notmatch 'or pass -confirm-database pgvigil') { Fail "C: no terminal and no -confirm-database: $c1" }
    $c2 = & $copy uninstall -all -drop-repository -confirm-database pgvigil_x -owner-dsn-file $ofile -pg-dump (Join-Path $PgBin 'pg_dump.exe') 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $c2 -notmatch 'is not the repository database') { Fail "C: a wrong name: $c2" }
    if ((State) -ne $before) { Fail "C: the host changed:`n$before`n---`n$(State)" }
    Ok 'C refused with nothing changed: no terminal and no -confirm-database; a wrong -confirm-database'

    # P the dry run
    $p = & $copy uninstall -all -dry-run -drop-repository -owner-dsn-file $ofile -pg-dump (Join-Path $PgBin 'pg_dump.exe') 2>&1 | Out-String
    foreach ($l in 'remove   the app, machine-wide', "remove   this user's app", 'remove   start at login (HKLM', 'remove   start at login (HKCU', 'remove   the Programs and Features entry (HKLM',
        'remove   the policy keys', 'remove   the machine PATH entry', 'remove   the service pgvigil', "remove   the binary $exe", 'remove   the configuration folder', 'remove   the database pgvigil',
        'remove   the login role pgvigil_agent', 'remove   the group role pgvigil_collector', 'dry run: nothing was changed') {
        if ($p -notmatch [regex]::Escape($l)) { Fail "P: no '$l' in: $p" }
    }
    if ((State) -ne $before) { Fail "P: the dry run changed the host:`n$before`n---`n$(State)" }
    Ok 'P the dry run names every item and changes nothing'

    # U the run, with this user's app running (start at login is the default; its WebView2 data locks the folder)
    Start-Process -FilePath (Join-Path $mine 'pgvigil-app.exe')
    Start-Sleep 5
    $u = & $copy uninstall -all -drop-repository -confirm-database pgvigil -owner-dsn-file $ofile -pg-dump (Join-Path $PgBin 'pg_dump.exe') 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "U: $u" }
    if ($u -notmatch "ended this user's running app") { Fail "U: this user's running app was not ended: $u" }
    $after = State
    if (Get-Service pgvigil -ErrorAction SilentlyContinue) { Fail "U: the service pgvigil is still there:`n$u" }
    foreach ($l in "$exe False", "$pd False", "$mine False", 'run-hklm False', 'run-hkcu False', 'Uninstall\pgvigil False', 'Policies\pgvigil False', 'HKCU:\Software\pgvigil False', 'path False', 'roles pgvigil_monitor,pgvigil_owner') {
        if ($after -notmatch [regex]::Escape($l)) { Fail "U: '$l' not in the state after:`n$after`n$u" }
    }
    if ($after -match '(^|,)pgvigil(,|$)') { Fail "U: the database pgvigil is still there:`n$after" }
    if (Test-Path $pf) { Fail "U: $pf is still there: $(Get-ChildItem $pf | Out-String)" }
    $dump = @(Get-ChildItem (Join-Path $env:ProgramData 'pgvigil-backups') -Filter 'pgvigil-before-uninstall-*.dump')
    if ($dump.Count -ne 1) { Fail 'U: no dump in pgvigil-backups' }
    Ok "U everything removed and read back; the roles left: the monitor and the owner; the dump $($dump[0].Name)"

    # R the second run
    $r = & $copy uninstall -all -drop-repository -confirm-database pgvigil -owner-dsn-file $ofile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $r -notmatch 'nothing of pgvigil is left to remove') { Fail "R: $r" }
    Ok "R a second run: 'nothing of pgvigil is left to remove'"
} finally {
    & (Join-Path $PgBin 'pg_ctl.exe') -D (Join-Path $Work 'pgdata') -m fast stop 2>$null | Out-Null
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $env:ProgramData 'pgvigil-backups') -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'proof-uninstall-windows: OK'
