# Guest side of the Windows installer proof (scripts/proof-install-windows.sh drives it over SSH; Windows
# PowerShell 5.1, elevated). Phase install: `irm | iex` from the mock release server, the service exists
# stopped (repo.dsn still empty), the binary prints the version, the data folder's ACL names the service account;
# then the repository DSN and one instance are written and the installer runs again (the upgrade path):
# the service is Running and its log says the scheduler started. Phase uninstall: `pgvigil uninstall -purge`
# removes the service and the data folder; the install folder and the PATH entry are cleaned here.
param(
    [Parameter(Mandatory = $true)][ValidateSet('install', 'uninstall')][string]$Phase,
    [string]$AssetsHost = '',
    [string]$RepoHost = '',
    [string]$Tag = '',
    [string]$RepoPassword = ''
)
$ErrorActionPreference = 'Stop'
function Fail([string]$Text) { Write-Output "FAIL: $Text"; exit 1 }
$proofBinDir = Join-Path $env:ProgramFiles 'pgvigil'
$proofExe = Join-Path $proofBinDir 'pgvigil.exe'
$proofDataDir = Join-Path $env:ProgramData 'pgvigil'
$proofCfg = Join-Path $proofDataDir 'pgvigil.yaml'

if ($Phase -eq 'install') {
    $env:PGVIGIL_VERSION = $Tag
    $env:PGVIGIL_BASE_URL = "http://${AssetsHost}:8000"
    $installerText = Invoke-RestMethod -Uri "http://${AssetsHost}:8000/install.ps1" -UseBasicParsing
    & ([scriptblock]::Create($installerText))
    $proofSvc = Get-Service -Name pgvigil -ErrorAction SilentlyContinue
    if (-not $proofSvc) { Fail 'no service pgvigil after install' }
    if ($proofSvc.Status -ne 'Stopped') { Fail "service state after the first install: $($proofSvc.Status) (expected Stopped: repo.dsn is empty yet)" }
    if ($proofSvc.StartType -ne 'Automatic') { Fail "start type $($proofSvc.StartType)" }
    $proofVersionOut = & $proofExe version
    if ("$proofVersionOut" -ne "pgvigil $Tag") { Fail "installed binary says '$proofVersionOut'" }
    if (-not (Test-Path $proofCfg)) { Fail 'no pgvigil.yaml' }
    if (-not (Test-Path (Join-Path $proofDataDir 'repo.dsn'))) { Fail 'no repo.dsn' }
    $proofAcl = (icacls $proofDataDir) -join ' '
    if ($proofAcl -notmatch 'NT SERVICE\\pgvigil') { Fail "the data folder ACL does not name the service account: $proofAcl" }
    if ($proofAcl -match 'BUILTIN\\Users') { Fail "the data folder ACL still grants Users: $proofAcl" }
    $proofAccount = (Get-CimInstance Win32_Service -Filter "Name='pgvigil'").StartName
    if ($proofAccount -ne 'NT SERVICE\pgvigil') { Fail "service account is '$proofAccount'" }
    Write-Output "ok   service pgvigil Stopped/Automatic under $proofAccount, binary $Tag, data folder restricted"

    # the repository and one instance (the same server as the target), then the upgrade path starts the service
    $proofDsn = "postgres://postgres:${RepoPassword}@${RepoHost}:5432/postgres?sslmode=disable"
    Set-Content -Path (Join-Path $proofDataDir 'repo.dsn') -Value $proofDsn -Encoding Ascii -NoNewline
    Set-Content -Path (Join-Path $proofDataDir 'target.dsn') -Value "host=$RepoHost port=5432 user=postgres password=$RepoPassword dbname=postgres sslmode=disable" -Encoding Ascii -NoNewline
    # a native command's stderr (slog writes INFO there) under ErrorActionPreference Stop with 2>&1 becomes a
    # terminating error in 5.1: judge native calls by their exit code instead
    $ErrorActionPreference = 'Continue'
    & $proofExe migrate -config $proofCfg 2>$null | Out-Null
    $migrateExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($migrateExit -ne 0) { Fail 'migrate as the owner failed' }
    $proofYaml = Get-Content -Path $proofCfg -Raw
    $proofYaml = $proofYaml -replace 'instances: \[\]', ("instances:`n  - name: win-proof-target`n    dsn: file:" + (Join-Path $proofDataDir 'target.dsn') + "`n    tags: [proof]")
    Set-Content -Path $proofCfg -Value $proofYaml -Encoding Ascii
    & ([scriptblock]::Create($installerText))
    $proofSvc = Get-Service -Name pgvigil
    if ($proofSvc.Status -ne 'Running') { Fail "service state after the second install: $($proofSvc.Status)" }
    if ((Get-Content -Path $proofCfg -Raw) -notmatch 'win-proof-target') { Fail 'the upgrade overwrote the edited config' }
    $proofLog = Join-Path (Join-Path $proofDataDir 'logs') 'pgvigil.log'
    $proofSeen = $false
    for ($i = 0; $i -lt 30; $i++) { if ((Test-Path $proofLog) -and ((Get-Content $proofLog -Raw) -match 'scheduler started')) { $proofSeen = $true; break }; Start-Sleep -Seconds 1 }
    if (-not $proofSeen) { Fail "pgvigil.log does not say 'scheduler started' within 30 s: $(if (Test-Path $proofLog) { Get-Content $proofLog -Raw } else { 'no log file' })" }
    Write-Output 'ok   upgrade path kept the config; service Running; the log says scheduler started'
    # an operator rotates by deleting the log: the service must be able to make it again
    Stop-Service -Name pgvigil
    Remove-Item -Path $proofLog -Force
    Start-Service -Name pgvigil
    $proofAgain = $false
    for ($i = 0; $i -lt 20; $i++) { if (Test-Path $proofLog) { $proofAgain = $true; break }; Start-Sleep -Seconds 1 }
    if (-not $proofAgain) { Fail 'the service did not recreate its deleted log within 20 s' }
    Write-Output 'ok   a deleted log is made again by the running service'
    exit 0
}

# uninstall: -purge removes the installer's own files and the folder only when nothing else is left, so the
# proof's own target.dsn goes first (an operator's file would be kept, and the folder with it)
Remove-Item -Path (Join-Path $proofDataDir 'target.dsn') -Force -ErrorAction SilentlyContinue
$ErrorActionPreference = 'Continue'
& $proofExe uninstall -purge 2>$null | Out-Null
$ErrorActionPreference = 'Stop'
Start-Sleep -Seconds 2
if (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) { Fail 'the service still exists after uninstall -purge' }
if (Test-Path $proofDataDir) { Fail 'the data folder survived -purge' }
Remove-Item -Path $proofBinDir -Recurse -Force -ErrorAction SilentlyContinue
$proofMachinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$proofKept = ($proofMachinePath -split ';') | Where-Object { $_ -and $_ -ne $proofBinDir }
[Environment]::SetEnvironmentVariable('Path', ($proofKept -join ';'), 'Machine')
Write-Output 'ok   uninstall -purge removed the service and the data folder; install folder and PATH entry cleaned'
exit 0
