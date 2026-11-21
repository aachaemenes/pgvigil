# msi-step6-standin.ps1 -Source step6 -File <msi.yml> -Case absent|empty|dll
# msi-step6-standin.ps1 -Source m1 -File <proof-msi-win.ps1> -Case absent|empty|dll
# Runs a Windows Installer reader from its OWN TEXT with the Windows Installer object replaced by a stand-in:
#   step6 - msi.yml's step 'the package holds no custom-action DLL' (its 'shell: pwsh' required), as GitHub runs a pwsh
#           step: a file holding "$ErrorActionPreference = 'stop'", the step's text and the LASTEXITCODE line, started
#           as pwsh -command ". '<file>'";
#   m1    - the M1 child of scripts/proof-msi-win.ps1 (the $m1Script here-string), run as a child script.
# The stand-in answers as Windows Installer does where the readers lean on it: the two queries each reader asks, matched
# EXACTLY ('OpenView,Sql' for any other text, as for a view on a table the package does not have); Execute and Close
# return nothing; Fetch returns null after the last row; StringData answers field 1 only. Cases: absent (no Binary
# table - the package as built), empty (a Binary table with no row), dll (a Binary table holding one row). Each query is
# printed as it is asked.
param([ValidateSet('step6', 'm1')][string]$Source, [string]$File, [ValidateSet('absent', 'empty', 'dll')][string]$Case)
$ErrorActionPreference = 'Stop'
$lines = @(Get-Content -LiteralPath $File)
if ($Source -eq 'step6') {
    $hit = $lines | Select-String -Pattern '^\s*- name: the package holds no custom-action DLL' | Select-Object -First 1
    if (-not $hit) { Write-Host 'STAND-IN: step 6 not found by its name'; exit 3 }
    $i = $hit.LineNumber   # the line after the name (LineNumber is 1-based)
    $shell = $false
    while ($i -lt $lines.Count -and $lines[$i] -notmatch '^\s*run: \|\s*$') {
        if ($lines[$i] -match '^\s*- name:') { Write-Host 'STAND-IN: step 6 has no run block before the next step'; exit 3 }
        if ($lines[$i] -match '^\s*shell: pwsh\s*$') { $shell = $true }
        $i++
    }
    if ($i -ge $lines.Count) { Write-Host 'STAND-IN: no run block under step 6'; exit 3 }
    if (-not $shell) { Write-Host "STAND-IN: step 6 does not say 'shell: pwsh' before its run block"; exit 3 }
    $runIndent = ($lines[$i] -replace '^(\s*).*', '$1').Length
    $body = @(); $i++
    while ($i -lt $lines.Count -and ($lines[$i] -match '^\s*$' -or ($lines[$i] -replace '^(\s*).*', '$1').Length -gt $runIndent)) { $body += $lines[$i]; $i++ }
    $cut = ($body | Where-Object { $_ -notmatch '^\s*$' } | ForEach-Object { ($_ -replace '^(\s*).*', '$1').Length } | Measure-Object -Minimum).Minimum
    $text = ($body | ForEach-Object { if ($_.Length -ge $cut) { $_.Substring($cut) } else { '' } }) -join "`n"
    $queries = @("SELECT ``Name`` FROM ``_Tables`` WHERE ``Name`` = 'Binary'", 'SELECT `Name` FROM `Binary`')
} else {
    $start = [array]::IndexOf($lines, ($lines | Where-Object { $_ -match '^\s*\$m1Script = @''\s*$' } | Select-Object -First 1))
    if ($start -lt 0) { Write-Host 'STAND-IN: the M1 child ($m1Script = @'') not found'; exit 3 }
    $end = $start + 1; while ($end -lt $lines.Count -and $lines[$end] -ne "'@") { $end++ }
    if ($end -ge $lines.Count) { Write-Host 'STAND-IN: the M1 child has no end'; exit 3 }
    $text = ($lines[($start + 1)..($end - 1)]) -join "`n"
    $text = $text.Replace('PGV_MSI_PATH', 'stand-in.msi')
    # a stand-in is no COM object: Marshal's release of it is a no-op here
    $text = $text.Replace('[Runtime.InteropServices.Marshal]::ReleaseComObject(', '[SIRelease]::Release(')
    $queries = @('SELECT `Name` FROM `_Tables`', 'SELECT `Name` FROM `Binary`')
}
$com = 'New-Object -ComObject WindowsInstaller.Installer'
if (-not $text.Contains($com)) { Write-Host 'STAND-IN: the text creates no WindowsInstaller.Installer'; exit 3 }
$text = $text.Replace($com, 'New-Object SIInstaller')

$cs = @'
using System; using System.Collections.Generic;
public class SIRelease { public static int Release(object o) { return 0; } }
public class SIRecord { string v; public SIRecord(string v) { this.v = v; }
  [System.Runtime.CompilerServices.IndexerName("StringData")] public string this[int i] { get { if (i != 1) throw new Exception("StringData,Field"); return v; } } }
public class SIView { Queue<string> rows; public SIView(IEnumerable<string> r) { rows = new Queue<string>(r); }
  public void Execute() { } public void Close() { } public object Fetch() { return rows.Count > 0 ? new SIRecord(rows.Dequeue()) : null; } }
public class SIDb { public static string Case = "absent"; public static string[] Queries = new string[0];
  public object OpenView(string sql) {
    Console.WriteLine("ASKED: " + sql);
    var tables = new List<string> { "Component", "Directory", "Feature", "File", "Media", "Property", "CustomAction", "InstallExecuteSequence" };
    if (Case != "absent") tables.Add("Binary");
    if (Array.IndexOf(Queries, sql) < 0) throw new Exception("OpenView,Sql");
    if (sql.EndsWith("WHERE `Name` = 'Binary'")) return new SIView(tables.Contains("Binary") ? new[] { "Binary" } : new string[0]);
    if (sql == "SELECT `Name` FROM `_Tables`") return new SIView(tables);
    if (!tables.Contains("Binary")) throw new Exception("OpenView,Sql");
    return new SIView(Case == "dll" ? new[] { "CustomActionDll" } : new string[0]);
  } }
public class SIInstaller { public object OpenDatabase(string path, int mode) { return new SIDb(); } }
'@

$dir = Join-Path ([IO.Path]::GetTempPath()) ('step6-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $dir 'out/msi-0.0.2') | Out-Null
Set-Content -LiteralPath (Join-Path $dir 'out/msi-0.0.2/pgvigil-0.0.2-x64.msi') -Value 'stand-in'
$f = Join-Path $dir 'reader.ps1'
$q = ($queries | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ', '
$prelude = "Add-Type -TypeDefinition @'`n" + $cs + "`n'@`n[SIDb]::Case = '" + $Case + "'`n[SIDb]::Queries = @(" + $q + ")`n"
if ($Source -eq 'step6') {
    $file = $prelude + "`$ErrorActionPreference = 'stop'`n" + $text + "`nif ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit `$LASTEXITCODE }`n"
} else {
    $file = $prelude + $text + "`n"
}
Set-Content -LiteralPath $f -Value $file
Push-Location $dir
$ErrorActionPreference = 'Continue'
if ($Source -eq 'step6') { & pwsh -NoProfile -NonInteractive -Command ". '$f'" 2>&1 | ForEach-Object { "  step: $_" } }
else { & pwsh -NoProfile -NonInteractive -File $f 2>&1 | ForEach-Object { "  step: $_" } }
$code = $LASTEXITCODE
Pop-Location
Remove-Item -LiteralPath $dir -Recurse -Force
Write-Host "READER $Source ($Case) exit $code"
exit $code
