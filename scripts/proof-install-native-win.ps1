# proof-install-native-win.ps1 - Windows PowerShell 5.1 (powershell.exe), any account; changes nothing on the machine.
# The row behind docs/install.ps1's Invoke-Native (L189, the fold of sqltoolsbuild-s2's finding): under
# $ErrorActionPreference = 'Stop', 5.1 turns a native program's stderr into a terminating error wherever that stderr is
# redirected - ISE does it for every native call, so do a remoting session and '2>&1 | Tee-Object' - and pgvigil writes
# its INFO lines to stderr, so a SUCCESSFUL 'pgvigil install' threw there. The stand-in program is cmd.exe writing one
# line to stderr and ending with a chosen code. Invoke-Native is read out of install.ps1 itself (its AST), never copied.
#   powershell.exe -NoProfile -File scripts\proof-install-native-win.ps1 [-Script docs\install.ps1]
# Rows: OLD (a bare call, as install.ps1 had it) THROWS on a successful program under redirection - the red; NEW
# (through Invoke-Native) does not throw, returns code 0 and the stderr line as output; NEW-FAIL returns code 3 and is
# judged by it. Exit 0 = all three rows as stated; 1 = a row differs.
param([string]$Script = (Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\install.ps1'))
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { Write-Host "NOT PROVEN: this row is Windows PowerShell 5.1's (this is $($PSVersionTable.PSVersion))"; exit 1 }

$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { Write-Host "FAIL: $Script does not parse: $($parseErrors[0].Message)"; exit 1 }
$defs = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Native' }, $true))
if ($defs.Count -ne 1) { Write-Host "FAIL: $Script holds $($defs.Count) definitions of Invoke-Native, want 1"; exit 1 }
Invoke-Expression $defs[0].Extent.Text

$failed = 0
$stderrLine = 'time=2026-11-18 level=INFO msg="service created"'

# OLD: the bare form under 'Stop', its stderr redirected as ISE redirects it
$oldThrew = $false
try {
    & { & cmd.exe /c "echo $stderrLine 1>&2 & exit 0" } 2>&1 | Out-Null
} catch {
    $oldThrew = $true
}
if ($oldThrew) { Write-Host 'OK   OLD: a bare call of a successful program throws under Stop with its stderr redirected (the red)' }
else { Write-Host 'FAIL OLD: the bare call did not throw - the red this fold answers did not show here'; $failed++ }

# NEW: through Invoke-Native, inside the same redirection
try {
    $result = & { Invoke-Native { & cmd.exe /c "echo $stderrLine 1>&2 & exit 0" } } 2>&1
    if ($result.Code -eq 0 -and "$($result.Out)" -match 'service created') { Write-Host 'OK   NEW: Invoke-Native returns code 0 and the stderr line as output, no throw' }
    else { Write-Host "FAIL NEW: code $($result.Code), output '$($result.Out)'"; $failed++ }
} catch {
    Write-Host "FAIL NEW: Invoke-Native threw: $_"; $failed++
}

# NEW-FAIL: a failing program is judged by its code, not by its stderr
try {
    $result = & { Invoke-Native { & cmd.exe /c "echo refused 1>&2 & exit 3" } } 2>&1
    if ($result.Code -eq 3) { Write-Host 'OK   NEW-FAIL: code 3 returned for the caller to judge' }
    else { Write-Host "FAIL NEW-FAIL: code $($result.Code), want 3"; $failed++ }
} catch {
    Write-Host "FAIL NEW-FAIL: Invoke-Native threw: $_"; $failed++
}

if ($ErrorActionPreference -ne 'Stop') { Write-Host "FAIL: Invoke-Native left ErrorActionPreference at $ErrorActionPreference"; $failed++ }
if ($failed -eq 0) { Write-Host 'PASS: 3 of 3 rows'; exit 0 }
Write-Host "FAIL: $failed row(s)"; exit 1
