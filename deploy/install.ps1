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
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

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
