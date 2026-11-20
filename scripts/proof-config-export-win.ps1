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
#      same path - sealed anew (other bytes), its blob's flags holding CRYPTPROTECT_LOCAL_MACHINE (0x4; the flags word
#      read at offset 40, after the blob's version, provider GUID, master key version and master key GUID - the
#      layout [inferred] from the documented blob format: a FAIL here prints the word read), and opened to the same
#      string (Unprotect does not check the scope it is given, so the flag is the scope's proof); neither the export's
#      nor the import's output holds the export's password
#   X1 'config export -no-secrets' marks the dpapi: reference not portable
#   I2 (with -WithService, elevated, on a VM without pgvigil) a page credential sealed in instances\ moves too: with the
#      service pgvigil installed, an import into a fresh folder gives instances\ a protected list holding SYSTEM, the
#      Administrators and NT SERVICE\pgvigil with full control (the service's account writes there after a move), the
#      blob's own list holds no other reader (it takes the folder's list: written there, renamed there), and the blob
#      opens; then 'pgvigil uninstall -purge', no service left - read back
#   Z  the proof's folder removed, read back; with -WithService also %ProgramFiles%\pgvigil (the exe 'install -no-start'
#      placed: uninstall leaves it) removed and read back
# Not proven here: a move between two machines (one VM: the import seals for the same machine key).
# Exit 0 = every row as stated; 1 = a row differs; 2 = refused to start.
param([Parameter(Mandatory = $true)][string]$Exe, [switch]$WithService)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Exe)) { Write-Host "REFUSED: no $Exe"; exit 2 }
if ($WithService) {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'REFUSED: -WithService runs elevated'; exit 2 }
    if (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) { Write-Host 'REFUSED: -WithService: the service pgvigil exists here'; exit 2 }
    foreach ($left in (Join-Path $env:ProgramData 'pgvigil'), (Join-Path $env:ProgramFiles 'pgvigil')) {
        if (Test-Path -LiteralPath $left) { Write-Host "REFUSED: -WithService: $left exists (this proof removes what it makes, never what it found)"; exit 2 }
    }
}
Add-Type -AssemblyName System.Security

function Invoke-Native([scriptblock]$cmd) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $cmd 2>&1 | ForEach-Object { "$_" }; return @{ Code = $LASTEXITCODE; Out = ($out -join "`n") } } finally { $ErrorActionPreference = $eap }
}
$failed = 0
function Row([string]$name, [bool]$ok, [string]$what) {
    if ($ok) { Write-Host "OK   $name $what" } else { Write-Host "FAIL $name $what"; $script:failed++ }
}
# the DPAPI blob's flags word: dwVersion, guidProvider, dwMasterKeyVersion, guidMasterKey, then dwFlags (offset 40)
function Get-BlobFlags([byte[]]$bytes) {
    if ($bytes.Length -lt 44) { return -1 }
    return [BitConverter]::ToUInt32($bytes, 40)
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
    Row 'E1' ($res.Code -eq 0 -and $text.StartsWith('PGVIGIL CONFIGURATION EXPORT') -and -not $text.Contains($pwSecret) -and -not $text.Contains('pg1.example') -and -not $res.Out.Contains($pwSecret) -and -not $res.Out.Contains($exportPw) -and -not $text.Contains($exportPw)) "export (exit $($res.Code)): the header, no secret in the file or the output"

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
    $flags = if ($after.Length) { Get-BlobFlags $after } else { -1 }
    $machine = ($flags -ge 0) -and (($flags -band 4) -ne 0)
    Row 'I1' ($res.Code -eq 0 -and $reopened -eq $dsn -and $differs -and $machine -and -not $res.Out.Contains($exportPw) -and (Test-Path -LiteralPath $cfg)) "import (exit $($res.Code)): the blob's flags 0x$('{0:X}' -f $flags) (machine scope $machine), back at its path, sealed anew $differs, opens to the string $($reopened -eq $dsn)"

    # X1
    $masked = Join-Path $root 'masked.yaml'
    $res = Invoke-Native { & $Exe config export -config $cfg -no-secrets -out $masked }
    $mtext = if (Test-Path -LiteralPath $masked) { Get-Content -LiteralPath $masked -Raw } else { '' }
    Row 'X1' ($res.Code -eq 0 -and $mtext -match 'not portable') "export -no-secrets (exit $($res.Code)) marks the dpapi: reference not portable"

    # I2
    if ($WithService) {
        $pagePlain = "host=pg7.example user=mon password=$pwSecret dbname=postgres"
        New-Item -ItemType Directory -Path (Join-Path $dir 'instances') -Force | Out-Null
        $pageBlob = Join-Path $dir 'instances\pg7-ab12.dpapi'
        [IO.File]::WriteAllBytes($pageBlob, [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($pagePlain), $null, [Security.Cryptography.DataProtectionScope]::LocalMachine))
        $move2 = Join-Path $root 'move2.pgvigil'
        $res = Invoke-Native { $exportPw | & $Exe config export -config $cfg -password-stdin -out $move2 }
        $inst = Invoke-Native { & $Exe install -no-start }
        $dir2 = Join-Path (Join-Path $root 'new') 'pgvigil'
        New-Item -ItemType Directory -Path $dir2 -Force | Out-Null
        $imp = Invoke-Native { $exportPw | & $Exe config import -config (Join-Path $dir2 'pgvigil.yaml') -password-stdin $move2 }
        $folder = Join-Path $dir2 'instances'
        $acl = if (Test-Path -LiteralPath $folder) { Get-Acl -LiteralPath $folder } else { $null }
        $svcFull = $acl -and @($acl.Access | Where-Object { "$($_.IdentityReference)" -eq 'NT SERVICE\pgvigil' -and "$($_.FileSystemRights)" -match 'FullControl' -and "$($_.AccessControlType)" -eq 'Allow' }).Count -gt 0
        $others = if ($acl) { @($acl.Access | Where-Object { "$($_.IdentityReference)" -notmatch '^(NT AUTHORITY\\SYSTEM|BUILTIN\\Administrators|NT SERVICE\\pgvigil)$' }) } else { @() }
        $blob2 = Join-Path $folder 'pg7-ab12.dpapi'
        $opens = (Test-Path -LiteralPath $blob2) -and ((Open-Blob $blob2) -eq $pagePlain)
        $bacl = if (Test-Path -LiteralPath $blob2) { Get-Acl -LiteralPath $blob2 } else { $null }
        $bothers = if ($bacl) { @($bacl.Access | Where-Object { "$($_.AccessControlType)" -eq 'Allow' -and "$($_.IdentityReference)" -notmatch '^(NT AUTHORITY\\SYSTEM|BUILTIN\\Administrators|NT SERVICE\\pgvigil)$' }) } else { @() }
        Row 'I2' ($res.Code -eq 0 -and $inst.Code -eq 0 -and $imp.Code -eq 0 -and $acl -and $acl.AreAccessRulesProtected -and $svcFull -and $others.Count -eq 0 -and $bacl -and $bothers.Count -eq 0 -and $opens) "export $($res.Code), install $($inst.Code), import $($imp.Code): instances\ protected $(if ($acl) { $acl.AreAccessRulesProtected }), NT SERVICE\pgvigil full control $svcFull, other readers $($others.Count)$(if ($others.Count) { ' (' + (($others | ForEach-Object { "$($_.IdentityReference)" }) -join ', ') + ')' }); the blob's own list $(if ($bacl) { 'read' } else { 'UNREAD' }), other readers $($bothers.Count)$(if ($bothers.Count) { ' (' + (($bothers | ForEach-Object { "$($_.IdentityReference)" }) -join ', ') + ')' }); the blob opens $opens"
        $pagePlain = $null
    }
} finally {
    if ($WithService) {
        try {
            if (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) { $null = Invoke-Native { & $Exe uninstall -purge } }
            Row 'Z' (-not (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath (Join-Path $env:ProgramData 'pgvigil'))) "uninstall -purge: no service pgvigil, no $env:ProgramData\pgvigil"
        } catch { Row 'Z' $false "the uninstall: $($_.Exception.Message)" }
        try {
            # the exe 'install -no-start' placed (the start refused where the folder was): uninstall leaves it
            $progDir = Join-Path $env:ProgramFiles 'pgvigil'
            if (Test-Path -LiteralPath $progDir) { Remove-Item -LiteralPath $progDir -Recurse -Force }
            Row 'Z' (-not (Test-Path -LiteralPath $progDir)) "$progDir removed"
        } catch { Row 'Z' $false "$env:ProgramFiles\pgvigil not removed: $($_.Exception.Message)" }
    }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Row 'Z' (-not (Test-Path -LiteralPath $root)) "the proof's folder $root removed"
    $dsn = $null; $pwSecret = $null; $exportPw = $null
}
if ($failed -eq 0) { Write-Host 'PASS: every row'; exit 0 }
Write-Host "FAIL: $failed row(s)"; exit 1
