# Proof of the offline install and upgrade on Windows (task 202), run INSIDE the Windows sandbox with its network
# adapter off, from an elevated Windows PowerShell 5.1. Everything it uses is on local disk before the adapter goes off
# (a share is network): the extracted offline bundle, the released v0.3.0 FIPS exe, and a PostgreSQL bin folder
# (initdb, pg_ctl, psql, pg_dump, pg_restore of one major version) for a throwaway cluster on 127.0.0.1 as the
# repository and the monitored server.
#   -Bundle  <folder>   the extracted pgvigil-offline-<v>-windows-amd64 (scripts/proof-offline.sh lays it out)
#   -OldExe  <file>     pgvigil_v0.3.0_windows_amd64_fips.exe, checked against its release SHA256SUMS beforehand
#   -PgBin   <folder>   PostgreSQL's bin folder
#   -Work    <folder>   a scratch folder on local disk (default C:\pgvigil-offline-proof; removed at the end)
# Expected (written before its first run; NOT run by this project yet: the sandbox was another lane's):
#  N   no network adapter is up (Get-NetAdapter shows none Up)
#  A   install.ps1 -From the bundle: 'signature not verified here', '(plain build) checksum verified'; the service
#      pgvigil exists (Stopped: no instance yet) under NT SERVICE\pgvigil; %ProgramFiles%\pgvigil\pgvigil.exe prints
#      the bundle's version and fips140 off; the machine PATH holds the folder; then 'pgvigil.exe uninstall -purge'
#      leaves no service
#  O   v0.3.0's FIPS exe installs the service; its migrate as the owner, the logins of 'pgvigil roles', a day of its
#      demo, the local cluster as an instance; the service runs and an activity sample arrives
#  U   install.ps1 -From the bundle -OwnerDsnFile <file> -PgDump <PgBin>\pg_dump.exe: steps 1 to 5 and the way back
#      printed; the service runs the bundle's version with fips140 on (the flavour kept); pgvigil.previous.exe is the
#      v0.3.0 FIPS exe byte for byte; the dump in %ProgramData%\pgvigil-backups, whose ACL names SYSTEM and
#      Administrators only; every table with an instance column holds, outside the live instance, the rows it held
#  APP install.ps1 -From the bundle -App -OwnerDsnFile <file> -PgDump ...: 'already this one', the app placed
#      machine-wide by pgvigil-app install -app-only, the collector's exe byte for byte as before (still FIPS), no
#      UpdateCheck policy written
#  X   everything the proof made removed (the app, the service, the folders, the cluster)
param(
    [Parameter(Mandatory)][string]$Bundle,
    [Parameter(Mandatory)][string]$OldExe,
    [Parameter(Mandatory)][string]$PgBin,
    [string]$Work = 'C:\pgvigil-offline-proof'
)
$ErrorActionPreference = 'Stop'
function Fail([string]$m) { Write-Host "FAIL: $m"; exit 1 }
function Ok([string]$m) { Write-Host "ok   $m" }
function Hash([string]$p) { (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLowerInvariant() }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Fail 'run it elevated' }
foreach ($f in 'initdb.exe', 'pg_ctl.exe', 'psql.exe', 'pg_dump.exe', 'pg_restore.exe') { if (-not (Test-Path (Join-Path $PgBin $f))) { Fail "no $f in $PgBin" } }
$up = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
if ($up.Count -gt 0) { Fail "a network adapter is up: $($up.Name -join ', ') (turn it off first)" }
Ok 'N no network adapter is up'
$sums = Get-Content (Join-Path $Bundle 'SHA256SUMS')
$v = ($sums | ForEach-Object { ($_ -split '\s+', 2)[1] } | Where-Object { $_ -match '^pgvigil_(v[^_]*)_windows_amd64\.exe$' } | Select-Object -First 1) -replace '^pgvigil_(v[^_]*)_windows_amd64\.exe$', '$1'
if (-not $v) { Fail 'the bundle names no version' }
$pf = Join-Path $env:ProgramFiles 'pgvigil'; $exe = Join-Path $pf 'pgvigil.exe'
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$pw = 'ow' + (Get-Random) + (Get-Random); $apw = 'ag' + (Get-Random); $mpw = 'mo' + (Get-Random)
$port = 55432
try {
    # the cluster: scram on loopback, the superuser's password in a file of this run
    $pwfile = Join-Path $Work 'su.pw'; Set-Content -LiteralPath $pwfile -Value $pw -NoNewline
    & (Join-Path $PgBin 'initdb.exe') -D (Join-Path $Work 'pgdata') -U postgres --auth=scram-sha-256 --pwfile=$pwfile -E UTF8 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'initdb' }
    & (Join-Path $PgBin 'pg_ctl.exe') -D (Join-Path $Work 'pgdata') -l (Join-Path $Work 'pg.log') -o "-p $port -c listen_addresses=127.0.0.1" -w start | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'pg_ctl start' }
    $env:PGPASSWORD = $pw
    function Q([string]$sql, [string]$db = 'pgvigil') { $o = & (Join-Path $PgBin 'psql.exe') -h 127.0.0.1 -p $port -U postgres -d $db -XAtq -v ON_ERROR_STOP=1 -c $sql; if ($LASTEXITCODE -ne 0) { Fail "psql: $sql" }; return $o }
    $pgmaj = [int](Q "select current_setting('server_version_num')::int / 10000" 'postgres')

    # A fresh install from the bundle
    $a = & (Join-Path $Bundle 'install.ps1') -From $Bundle *>&1 | Out-String
    foreach ($l in 'signature not verified here', "pgvigil $v (plain build) checksum verified") { if ($a -notmatch [regex]::Escape($l)) { Fail "A: no '$l' in: $a" } }
    $svc = Get-CimInstance Win32_Service -Filter "Name='pgvigil'"
    if (-not $svc -or $svc.StartName -ne 'NT SERVICE\pgvigil') { Fail "A: the service: $($svc | Out-String)" }
    $vv = & $exe version
    if ($vv -notmatch "^pgvigil $([regex]::Escape($v)) " -or $vv -notmatch 'fips140 off') { Fail "A: the installed exe: $vv" }
    if (([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';') -notcontains $pf) { Fail 'A: the machine PATH lacks the folder' }
    & $exe uninstall -purge | Out-Null
    if (Get-Service pgvigil -ErrorAction SilentlyContinue) { Fail 'A: the service is still there after uninstall -purge' }
    Ok "A fresh install from the bundle ($vv), then removed"

    # O the old store
    & $OldExe install | Out-Null; if ($LASTEXITCODE -ne 0) { Fail 'O: v0.3.0 install' }
    if ((& $exe version) -notmatch 'fips140 on') { Fail 'O: the old exe is not FIPS' }
    Q "CREATE ROLE pgvigil_owner LOGIN CREATEROLE PASSWORD '$pw'" 'postgres' | Out-Null
    Q 'CREATE DATABASE pgvigil OWNER pgvigil_owner' 'postgres' | Out-Null
    $owner = "host=127.0.0.1 port=$port user=pgvigil_owner password=$pw dbname=pgvigil sslmode=disable"
    $cfg = Join-Path $env:ProgramData 'pgvigil\pgvigil.yaml'
    $env:PGVIGIL_REPO_DSN = $owner
    & $exe migrate -config $cfg | Out-Null; if ($LASTEXITCODE -ne 0) { Fail 'O: migrate' }
    $roles = & $exe roles
    foreach ($r in @(@('agent', $apw), @('monitor', $mpw))) {
        $line = ($roles | Where-Object { $_ -match "^CREATE ROLE pgvigil_$($r[0]) LOGIN PASSWORD '<set-me>'" } | Select-Object -First 1) -replace '<set-me>', $r[1]
        Q $line | Out-Null
    }
    & $exe demo -config $cfg -days 1 | Out-Null; if ($LASTEXITCODE -ne 0) { Fail 'O: demo' }
    Remove-Item Env:PGVIGIL_REPO_DSN
    Set-Content -LiteralPath (Join-Path $env:ProgramData 'pgvigil\repo.dsn') -Value "host=127.0.0.1 port=$port user=pgvigil_agent password=$apw dbname=pgvigil sslmode=disable" -NoNewline
    $tdsn = Join-Path $env:ProgramData 'pgvigil\target.dsn'
    Set-Content -LiteralPath $tdsn -Value "host=127.0.0.1 port=$port user=pgvigil_monitor password=$mpw dbname=postgres sslmode=disable" -NoNewline
    (Get-Content $cfg -Raw) -replace 'instances: \[\]', "instances:`n  - name: win-target`n    dsn: file:$($tdsn -replace '\\','/')`n    tags: [proof]" | Set-Content $cfg
    Start-Service pgvigil
    $tid = $null; foreach ($i in 1..90) { $tid = Q "select i.instance_id from pgvigil.instances i where i.name = 'win-target' and exists (select 1 from pgvigil.activity_summary s where s.instance_id = i.instance_id)"; if ($tid) { break }; Start-Sleep 1 }
    if (-not $tid) { Fail 'O: no activity sample of win-target in 90 s' }
    Ok 'O v0.3.0 FIPS installed, migrated, its demo, the live instance sampled'

    # U the upgrade
    $counts = "select string_agg(t || '=' || n, ',' order by t) from (select c.relname t, (xpath('/row/n/text()', query_to_xml(format('select count(*) n from pgvigil.%I where instance_id is distinct from $tid', c.relname), false, true, '')))[1]::text n from pg_class c join pg_namespace s on s.oid = c.relnamespace where s.nspname = 'pgvigil' and c.relkind in ('r','p') and not c.relispartition and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'instance_id' and not a.attisdropped)) x"
    $before = Q $counts
    $oldHash = Hash $OldExe
    $odir = Join-Path $Work 'secret'; New-Item -ItemType Directory -Force -Path $odir | Out-Null
    & icacls.exe $odir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    $ofile = Join-Path $odir 'owner.dsn'; Set-Content -LiteralPath $ofile -Value $owner -NoNewline
    $u = & (Join-Path $Bundle 'install.ps1') -From $Bundle -OwnerDsnFile $ofile -PgDump (Join-Path $PgBin 'pg_dump.exe') *>&1 | Out-String
    foreach ($l in '1. stopped the service', '2. dumped the repository to', '3. migrated the repository:', 'pgvigil.previous.exe', '5. swapped the binary and started the service', 'The way back:') { if ($u -notmatch [regex]::Escape($l)) { Fail "U: no '$l' in: $u" } }
    $nv = & $exe version
    if ($nv -notmatch "^pgvigil $([regex]::Escape($v)) " -or $nv -notmatch 'fips140 on') { Fail "U: the installed exe: $nv (want $v, FIPS)" }
    if ((Hash (Join-Path $pf 'pgvigil.previous.exe')) -ne $oldHash) { Fail 'U: pgvigil.previous.exe is not the old exe' }
    if ((Get-Service pgvigil).Status -ne 'Running') { Fail 'U: the service is not running' }
    $acl = (& icacls.exe (Join-Path $env:ProgramData 'pgvigil-backups')) -join "`n"
    if ($acl -match 'Users' -or $acl -match 'Everyone') { Fail "U: the backup folder's ACL: $acl" }
    $after = Q $counts
    if ($after -ne $before) { Fail "U: rows changed: before $before after $after" }
    Ok "U upgraded to $nv in place, .previous.exe = v0.3.0, the backup folder for SYSTEM and Administrators only, every instance table's rows kept"

    # APP the app beside the collector
    $collectorHash = Hash $exe
    $p = & (Join-Path $Bundle 'install.ps1') -From $Bundle -App -OwnerDsnFile $ofile -PgDump (Join-Path $PgBin 'pg_dump.exe') *>&1 | Out-String
    # (pgvigil-app's own lines go to the console through Start-Process, not into $p: the hashes below are the check)
    if ($p -notmatch 'already this one') { Fail "APP: $p" }
    if (-not (Test-Path (Join-Path $pf 'pgvigil-app.exe'))) { Fail 'APP: no pgvigil-app.exe' }
    if ((Hash $exe) -ne $collectorHash) { Fail 'APP: the collector exe changed (the zip''s plain exe over the FIPS one?)' }
    if (Get-ItemProperty -Path 'HKLM:\Software\Policies\pgvigil\App' -Name UpdateCheck -ErrorAction SilentlyContinue) { Fail 'APP: an UpdateCheck policy was written without -UpdateCheck' }
    Ok 'APP the app placed machine-wide beside the FIPS collector, the collector unchanged, no update-check policy'
} finally {
    $appExe = Join-Path $pf 'pgvigil-app.exe'
    if (Test-Path $appExe) { Start-Process -FilePath $appExe -ArgumentList 'uninstall', '-purge' -Wait -NoNewWindow -ErrorAction SilentlyContinue }
    if (Test-Path $exe) { & $exe uninstall -purge 2>$null | Out-Null }
    & (Join-Path $PgBin 'pg_ctl.exe') -D (Join-Path $Work 'pgdata') -m fast stop 2>$null | Out-Null
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $env:ProgramData 'pgvigil-backups') -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'proof-offline-windows: OK'
