# proof-config-export-win.ps1 - Windows PowerShell 5.1 or 7, on a lab VM (dba-lab-win through the WIN queue): the
# dpapi: half of 'pgvigil config export' / 'config import' (RELNOTES L155). It works in a folder of its own under
# %TEMP% and removes it at the end; no service, no account and nothing outside that folder is touched.
#   powershell.exe -NoProfile -File scripts\proof-config-export-win.ps1 -Exe C:\proof\pgvigil.exe
# Rows:
#   S1 'pgvigil secret seal' writes the instance's connection string as a machine-scope DPAPI blob in secrets\
#   E1 'config export -password-stdin' exits 0; the file starts with its header and holds neither the connection
#      string nor its password in clear; neither does the command's output
#   N1 an import with a wrong password is refused and writes nothing
#   I1 the folder emptied (a new host's state), 'config import -password-stdin' exits 0 and the blob is back at the
#      same path - sealed anew (other bytes) and opened by ProtectedData at LocalMachine scope to the same string
#   X1 'config export -no-secrets' marks the dpapi: reference not portable
#   Z  the proof's folder removed, read back
# Not proven here: a move between two machines (one VM: the import seals for the same machine key).
# Exit 0 = every row as stated; 1 = a row differs; 2 = refused to start.
param([Parameter(Mandatory = $true)][string]$Exe)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Exe)) { Write-Host "REFUSED: no $Exe"; exit 2 }
Add-Type -AssemblyName System.Security

function Invoke-Native([scriptblock]$cmd) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $cmd 2>&1 | ForEach-Object { "$_" }; return @{ Code = $LASTEXITCODE; Out = ($out -join "`n") } } finally { $ErrorActionPreference = $eap }
}
$failed = 0
function Row([string]$name, [bool]$ok, [string]$what) {
    if ($ok) { Write-Host "OK   $name $what" } else { Write-Host "FAIL $name $what"; $script:failed++ }
}
function Open-Blob([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Text.Encoding]::UTF8.GetString($plain).TrimEnd("`r", "`n")
}

$root = Join-Path $env:TEMP ('pgvproof-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$dir = Join-Path $root 'pgvigil'
$cfg = Join-Path $dir 'pgvigil.yaml'
$move = Join-Path $root 'move.pgvigil'
$pwSecret = 'Pv9!' + [Guid]::NewGuid().ToString('N')
$dsn = "host=pg1.example user=mon password=$pwSecret dbname=postgres"
$exportPw = 'Ex9!' + [Guid]::NewGuid().ToString('N')
try {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath $cfg -Value "repository:`n  dsn: env:PGVIGIL_PROOF_UNSET`ninstances: []`n" -Encoding Ascii

    # S1
    $res = Invoke-Native { $dsn | & $Exe secret seal -name pg1 -config $cfg }
    $blob = @(Get-ChildItem -LiteralPath (Join-Path $dir 'secrets') -File -ErrorAction SilentlyContinue)
    $ref = if ($res.Out -match '(dpapi:\S+)') { $Matches[1] } else { '' }
    $opened = if ($blob.Count -eq 1) { Open-Blob $blob[0].FullName } else { '' }
    Row 'S1' ($res.Code -eq 0 -and $blob.Count -eq 1 -and $ref -ne '' -and $opened -eq $dsn) "secret seal (exit $($res.Code)) wrote $($blob.Count) blob, printed '$ref', the blob opens to the string: $($opened -eq $dsn)"
    if ($ref) { Set-Content -LiteralPath $cfg -Value "repository:`n  dsn: env:PGVIGIL_PROOF_UNSET`ninstances:`n  - name: pg1`n    dsn: '$ref'`n" -Encoding Ascii }
    $before = if ($blob.Count -eq 1) { [IO.File]::ReadAllBytes($blob[0].FullName) } else { @() }

    # E1
    $res = Invoke-Native { $exportPw | & $Exe config export -config $cfg -password-stdin -out $move }
    $text = if (Test-Path -LiteralPath $move) { [IO.File]::ReadAllText($move, [Text.Encoding]::GetEncoding(28591)) } else { '' }
    Row 'E1' ($res.Code -eq 0 -and $text.StartsWith('PGVIGIL CONFIGURATION EXPORT') -and -not $text.Contains($pwSecret) -and -not $text.Contains('pg1.example') -and -not $res.Out.Contains($pwSecret)) "export (exit $($res.Code)): the header, no secret in the file or the output"

    # N1
    Remove-Item -LiteralPath $dir -Recurse -Force
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $res = Invoke-Native { 'a wrong one' | & $Exe config import -config $cfg -password-stdin $move }
    $left = @(Get-ChildItem -LiteralPath $dir -Recurse -Force).Count
    Row 'N1' ($res.Code -ne 0 -and $left -eq 0 -and $res.Out -match 'does not open') "a wrong password: exit $($res.Code), $left entries written"

    # I1
    $res = Invoke-Native { $exportPw | & $Exe config import -config $cfg -password-stdin $move }
    $back = if ($blob.Count -eq 1) { Join-Path $dir ('secrets\' + $blob[0].Name) } else { '' }
    $reopened = if ($back -and (Test-Path -LiteralPath $back)) { Open-Blob $back } else { '' }
    $after = if ($reopened) { [IO.File]::ReadAllBytes($back) } else { @() }
    $differs = ($after.Length -gt 0) -and (($after.Length -ne $before.Length) -or (@(Compare-Object $after $before -SyncWindow 0).Count -gt 0))
    Row 'I1' ($res.Code -eq 0 -and $reopened -eq $dsn -and $differs -and (Test-Path -LiteralPath $cfg)) "import (exit $($res.Code)): the blob back at its path, sealed anew $differs, opens to the string $($reopened -eq $dsn)"

    # X1
    $masked = Join-Path $root 'masked.yaml'
    $res = Invoke-Native { & $Exe config export -config $cfg -no-secrets -out $masked }
    $mtext = if (Test-Path -LiteralPath $masked) { Get-Content -LiteralPath $masked -Raw } else { '' }
    Row 'X1' ($res.Code -eq 0 -and $mtext -match 'not portable') "export -no-secrets (exit $($res.Code)) marks the dpapi: reference not portable"
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Row 'Z' (-not (Test-Path -LiteralPath $root)) "the proof's folder $root removed"
    $dsn = $null; $pwSecret = $null; $exportPw = $null
}
if ($failed -eq 0) { Write-Host 'PASS: every row'; exit 0 }
Write-Host "FAIL: $failed row(s)"; exit 1
