# pgvigil installer for Windows (Windows PowerShell 5.1 or PowerShell 7, elevated): finds the release for
# this CPU, downloads pgvigil.exe and SHA256SUMS, verifies the checksum, then runs `pgvigil install` (the
# service pgvigil under its virtual account, automatic start; started once the config names an instance)
# and puts the install folder on the machine PATH. Re-run it to upgrade: the binary and the service are
# replaced, the config is kept.
#
#   irm https://pgvigil.com/install.ps1 | iex
#   $env:PGVIGIL_VERSION = 'v0.2.0'      a given tag (default: the latest release)
#   $env:PGVIGIL_BASE_URL = '<url>'      the folder that holds <version>/<asset> (default: the GitHub release downloads)
#   $env:PGVIGIL_NO_SERVICE = '1'        download and verify only; pgvigil.exe lands in the current folder
#
# Offline (no network: a local folder, a mounted USB drive or a UNC share holding the extracted offline bundle,
# pgvigil-offline-<version>-windows-amd64; docs/airgap.md), from an elevated PowerShell:
#   & <folder>\install.ps1 -From <folder> [-Fips | -Plain] [-TrustRoot <dir>] [-App] [-UpdateCheck]
#                           [-OwnerDsnFile <path>] [-Dump <file> | -NoDump] [-PgDump <path>]
# The binary and SHA256SUMS are copied into a new folder for SYSTEM and Administrators only, the copies verified and
# only the copies run (a share or a drive can change between a check and a use). A fresh install runs
# 'pgvigil install' and puts the folder on the machine PATH; where the service pgvigil exists it is an upgrade,
# 'pgvigil install -upgrade' (refusals first, then stop, dump, migrate, swap, start, the way back printed:
# docs/upgrade.md), and the installed build (FIPS or plain, as 'pgvigil version' says) is kept unless -Fips or -Plain
# names the other. -App also places the Windows app machine-wide beside that collector (pgvigil-app install -app-only:
# the app zip's own pgvigil.exe, the plain build, is never installed over it); its update check stays off unless
# -UpdateCheck. The checksum proves the files are those SHA256SUMS names (integrity, not origin); -TrustRoot <dir>, a
# folder with the site's OWN fulcio.pem, rekor.pub and ctfe.pub, also verifies the signature with cosign.exe (on the
# PATH); the trust files inside the bundle are never used for it. Not seen on Windows by this project's proofs yet.
param(
    [string]$From,
    [switch]$Fips,
    [switch]$Plain,
    [string]$TrustRoot,
    [switch]$App,
    [switch]$UpdateCheck,
    [string]$OwnerDsnFile,
    [string]$Dump,
    [switch]$NoDump,
    [string]$PgDump
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Add-MachinePath([string]$dir) {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($machinePath -split ';') -notcontains $dir) {
        [Environment]::SetEnvironmentVariable('Path', ($machinePath.TrimEnd(';') + ';' + $dir), 'Machine')
        Write-Host "$dir added to the machine PATH (new shells see it)"
    }
}

if ($From) {
    if ($Fips -and $Plain) { throw 'pgvigil install: -Fips and -Plain name opposite builds' }
    if ($NoDump -and ($Dump -or $PgDump)) { throw 'pgvigil install: -NoDump does not go with -Dump or -PgDump' }
    $noSvc = ($env:PGVIGIL_NO_SERVICE -eq '1')
    if (-not $noSvc) {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'pgvigil install: the offline install runs from an elevated PowerShell (Administrator)'
        }
    }
    if (-not (Test-Path -LiteralPath $From -PathType Container)) { throw "pgvigil install: -From $From is not a folder" }
    $sums = Join-Path $From 'SHA256SUMS'
    if (-not (Test-Path -LiteralPath $sums -PathType Leaf)) { throw "pgvigil install: no SHA256SUMS in $From (the folder is the extracted pgvigil-offline-<version>-windows-amd64)" }
    # a new folder for SYSTEM and Administrators only (SIDs: the group name is localised); the copies run from there
    $work = Join-Path $env:ProgramData ('pgvigil-install-' + [IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        & icacls.exe $work /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "pgvigil install: icacls on $work exited with $LASTEXITCODE" }
        Copy-Item -LiteralPath $sums -Destination (Join-Path $work 'SHA256SUMS')
        $lines = @(Get-Content -LiteralPath (Join-Path $work 'SHA256SUMS'))
        function Get-Sum([string]$name) {
            $hit = @($lines | Where-Object { ($_ -split '\s+', 2)[1] -replace '^\*', '' -ceq $name })
            if ($hit.Count -ne 1) { throw "pgvigil install: SHA256SUMS has no single line for $name" }
            return (($hit[0] -split '\s+')[0]).ToLowerInvariant()
        }
        function Get-Hash([string]$path) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() }
        # this script's own bytes against the list, when it runs from the folder (a changed installer is refused)
        if ($PSCommandPath -and ((Split-Path -Parent $PSCommandPath) -eq (Resolve-Path -LiteralPath $From).ProviderPath)) {
            if ((Get-Hash $PSCommandPath) -ne (Get-Sum 'install.ps1')) { throw 'pgvigil install: checksum mismatch for install.ps1 itself: this script is not the one SHA256SUMS names' }
        }
        $verLine = @($lines | ForEach-Object { ($_ -split '\s+', 2)[1] -replace '^\*', '' } | Where-Object { $_ -match '^pgvigil_(v[^_]*)_windows_amd64\.exe$' } | Select-Object -First 1)
        if ($verLine.Count -ne 1 -or $verLine[0] -notmatch '^pgvigil_(v[^_]*)_windows_amd64\.exe$') { throw 'pgvigil install: SHA256SUMS names no pgvigil_<version>_windows_amd64.exe' }
        $version = $Matches[1]
        if ($TrustRoot) {
            $cosign = Get-Command cosign.exe -ErrorAction SilentlyContinue
            if (-not $cosign) { throw 'pgvigil install: -TrustRoot needs cosign.exe on the PATH' }
            foreach ($f in 'fulcio.pem', 'rekor.pub', 'ctfe.pub') { if (-not (Test-Path -LiteralPath (Join-Path $TrustRoot $f))) { throw "pgvigil install: -TrustRoot ${TrustRoot}: no $f there" } }
            $bundle = Join-Path $From 'SHA256SUMS.bundle'
            if (-not (Test-Path -LiteralPath $bundle)) { throw "pgvigil install: $From has no SHA256SUMS.bundle (an unsigned bundle cannot be verified)" }
            Copy-Item -LiteralPath $bundle -Destination (Join-Path $work 'SHA256SUMS.bundle')
            $env:SIGSTORE_ROOT_FILE = Join-Path $TrustRoot 'fulcio.pem'; $env:SIGSTORE_REKOR_PUBLIC_KEY = Join-Path $TrustRoot 'rekor.pub'; $env:SIGSTORE_CT_LOG_PUBLIC_KEY_FILE = Join-Path $TrustRoot 'ctfe.pub'
            & $cosign.Source verify-blob --offline --bundle (Join-Path $work 'SHA256SUMS.bundle') `
                --certificate-identity "https://github.com/aachaemenes/pgvigil/.github/workflows/release.yml@refs/tags/$version" `
                --certificate-oidc-issuer https://token.actions.githubusercontent.com (Join-Path $work 'SHA256SUMS') 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "pgvigil install: the signature of SHA256SUMS does not verify against the trust root in $TrustRoot for ${version}: nothing was installed" }
            Write-Host "signature of SHA256SUMS verified (the release workflow of $version, with the trust root in $TrustRoot)"
        } else {
            Write-Host "signature not verified here: the checksums prove the files are the ones SHA256SUMS names, not where they came from; verify the signature on the connected side, or pass -TrustRoot <the site's own trust root> (docs/airgap.md)"
        }
        $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='pgvigil'" -ErrorAction SilentlyContinue
        $installed = $null
        if ($svc -and $svc.PathName -match '^\s*"([^"]+)"|^\s*(\S+)') { $installed = if ($Matches[1]) { $Matches[1] } else { $Matches[2] } }
        $was = $null
        if ($installed -and (Test-Path -LiteralPath $installed)) { $was = if ((& $installed version 2>$null) -match 'fips140 on') { 'fips' } else { 'plain' } }
        $flavour = if ($Fips) { 'fips' } elseif ($Plain) { 'plain' } elseif ($was) { $was } else { 'plain' }
        if ($was -and $was -ne $flavour) { Write-Host "the installed build is $was; -$flavour installs the $flavour build in its place" }
        $asset = if ($flavour -eq 'fips') { "pgvigil_${version}_windows_amd64_fips.exe" } else { "pgvigil_${version}_windows_amd64.exe" }
        if (-not (Test-Path -LiteralPath (Join-Path $From $asset))) { throw "pgvigil install: $From has no $asset" }
        $exe = Join-Path $work $asset
        Copy-Item -LiteralPath (Join-Path $From $asset) -Destination $exe
        if ((Get-Hash $exe) -ne (Get-Sum $asset)) { throw "pgvigil install: checksum mismatch for ${asset}: nothing was installed" }
        Write-Host "pgvigil $version ($flavour build) checksum verified"
        if ($noSvc) {
            Copy-Item -LiteralPath $exe -Destination (Join-Path (Get-Location) 'pgvigil.exe') -Force
            Write-Host ".\pgvigil.exe $version is ready (no service installed)"
            return
        }
        if ($svc) {
            Write-Host 'the service pgvigil is installed: upgrading it'
            $up = @('install', '-upgrade')
            if ($OwnerDsnFile) { $up += @('-owner-dsn-file', $OwnerDsnFile) }
            if ($Dump) { $up += @('-dump', $Dump) }
            if ($NoDump) { $up += '-no-dump' }
            if ($PgDump) { $up += @('-pg-dump', $PgDump) }
            & $exe @up
            if ($LASTEXITCODE -ne 0) { throw "pgvigil install -upgrade exited with $LASTEXITCODE" }
        } else {
            if ($OwnerDsnFile -or $Dump -or $NoDump -or $PgDump) { throw 'pgvigil install: -OwnerDsnFile, -Dump, -NoDump and -PgDump go with an upgrade; the service pgvigil is not installed' }
            & $exe install
            if ($LASTEXITCODE -ne 0) { throw "pgvigil install exited with $LASTEXITCODE" }
            Add-MachinePath (Join-Path $env:ProgramFiles 'pgvigil')
        }
        if ($App) {
            $appZip = "pgvigil-app_${version}_windows_amd64.zip"
            if (-not (Test-Path -LiteralPath (Join-Path $From $appZip))) { throw "pgvigil install: $From has no $appZip" }
            $zip = Join-Path $work $appZip
            Copy-Item -LiteralPath (Join-Path $From $appZip) -Destination $zip
            if ((Get-Hash $zip) -ne (Get-Sum $appZip)) { throw "pgvigil install: checksum mismatch for ${appZip}: the app was not installed" }
            $appDir = Join-Path $work 'app'
            Expand-Archive -LiteralPath $zip -DestinationPath $appDir
            $appArgs = @('install', '-app-only')
            if ($UpdateCheck) { $appArgs += '-update-check' }
            $p = Start-Process -FilePath (Join-Path $appDir 'pgvigil-app.exe') -ArgumentList $appArgs -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -ne 0) { throw "pgvigil-app install exited with $($p.ExitCode)" }
            Write-Host ('the Windows app is installed machine-wide beside the collector (update check: ' + $(if ($UpdateCheck) { 'on' } else { 'off' }) + ')')
        }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    return
}

$repo = 'aachaemenes/pgvigil'
$base = if ($env:PGVIGIL_BASE_URL) { $env:PGVIGIL_BASE_URL.TrimEnd('/') } else { "https://github.com/$repo/releases/download" }
$version = $env:PGVIGIL_VERSION
$noService = ($env:PGVIGIL_NO_SERVICE -eq '1')

switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { $arch = 'amd64' }
    default { throw "pgvigil install: no Windows release for CPU '$($env:PROCESSOR_ARCHITECTURE)' (amd64 only)" }
}
if (-not $noService) {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'pgvigil install: run this from an elevated PowerShell (Administrator), or set $env:PGVIGIL_NO_SERVICE = ''1'' to only download the binary'
    }
}
if (-not $version) {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'pgvigil-install' }
    $version = $release.tag_name
    if (-not $version) { throw 'pgvigil install: the latest release has no tag; set $env:PGVIGIL_VERSION' }
}
$asset = "pgvigil_${version}_windows_${arch}.exe"
$work = Join-Path $env:TEMP ("pgvigil-install-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work | Out-Null
try {
    Write-Host "pgvigil $version for windows/$arch"
    Invoke-WebRequest -Uri "$base/$version/$asset" -OutFile (Join-Path $work $asset) -UseBasicParsing
    Invoke-WebRequest -Uri "$base/$version/SHA256SUMS" -OutFile (Join-Path $work 'SHA256SUMS') -UseBasicParsing
    $line = Get-Content (Join-Path $work 'SHA256SUMS') | Where-Object { $_ -match "\s$([regex]::Escape($asset))$" } | Select-Object -First 1
    if (-not $line) { throw "pgvigil install: SHA256SUMS has no line for $asset" }
    $expected = ($line -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 -Path (Join-Path $work $asset)).Hash.ToLowerInvariant()
    if ($expected -ne $actual) { throw "pgvigil install: checksum mismatch for $asset" }
    Write-Host 'checksum verified'
    if ($noService) {
        Copy-Item -Path (Join-Path $work $asset) -Destination (Join-Path (Get-Location) 'pgvigil.exe') -Force
        Write-Host ".\pgvigil.exe $version is ready (no service installed)"
        return
    }
    & (Join-Path $work $asset) install
    if ($LASTEXITCODE -ne 0) { throw "pgvigil install exited with $LASTEXITCODE" }
    $binDir = Join-Path $env:ProgramFiles 'pgvigil'
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($machinePath -split ';') -notcontains $binDir) {
        [Environment]::SetEnvironmentVariable('Path', ($machinePath.TrimEnd(';') + ';' + $binDir), 'Machine')
        Write-Host "$binDir added to the machine PATH (new shells see it)"
    }
} finally {
    Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
}
