# run-step6.ps1 -Workflow <msi.yml> -Case absent|empty|dll - msi.yml step 6 ('the package holds no custom-action
# DLL ...') run from its OWN TEXT as GitHub runs a pwsh step (a file holding "$ErrorActionPreference = 'stop'", the
# step's text and the LASTEXITCODE line, started as pwsh -command ". '<file>'"), with the Windows Installer COM object
# replaced by a stand-in whose answers follow Windows Installer's: a view on a table the package does not have is
# refused with 'OpenView,Sql'; Execute returns nothing. Cases: absent (no Binary table - the package as built),
# empty (a Binary table with no row), dll (a Binary table holding one row). Each query the step asks is printed.
param([string]$Workflow, [ValidateSet('absent', 'empty', 'dll')][string]$Case)
$ErrorActionPreference = 'Stop'
$lines = @(Get-Content -LiteralPath $Workflow)
$hit = $lines | Select-String -Pattern '^\s*- name: the package holds no custom-action DLL' | Select-Object -First 1
if (-not $hit) { Write-Host 'STAND-IN: step 6 not found by its name'; exit 3 }
$i = $hit.LineNumber   # the line after the name (LineNumber is 1-based)
while ($i -lt $lines.Count -and $lines[$i] -notmatch '^\s*run: \|\s*$') { $i++ }
if ($i -ge $lines.Count) { Write-Host 'STAND-IN: no run block under step 6'; exit 3 }
$runIndent = ($lines[$i] -replace '^(\s*).*', '$1').Length
$body = @(); $i++
while ($i -lt $lines.Count -and ($lines[$i] -match '^\s*$' -or ($lines[$i] -replace '^(\s*).*', '$1').Length -gt $runIndent)) { $body += $lines[$i]; $i++ }
$cut = ($body | Where-Object { $_ -notmatch '^\s*$' } | ForEach-Object { ($_ -replace '^(\s*).*', '$1').Length } | Measure-Object -Minimum).Minimum
$text = ($body | ForEach-Object { if ($_.Length -ge $cut) { $_.Substring($cut) } else { '' } }) -join "`n"
$com = 'New-Object -ComObject WindowsInstaller.Installer'
if (-not $text.Contains($com)) { Write-Host 'STAND-IN: the step creates no WindowsInstaller.Installer'; exit 3 }
$text = $text.Replace($com, 'New-Object SIInstaller')

$cs = @'
using System; using System.Collections.Generic;
public class SIRecord { string v; public SIRecord(string v) { this.v = v; }
  [System.Runtime.CompilerServices.IndexerName("StringData")] public string this[int i] { get { return v; } } }
public class SIView { Queue<string> rows; public SIView(IEnumerable<string> r) { rows = new Queue<string>(r); }
  public void Execute() { } public object Fetch() { return rows.Count > 0 ? new SIRecord(rows.Dequeue()) : null; } }
public class SIDb { public static string Case = "absent";
  public object OpenView(string sql) {
    Console.WriteLine("ASKED: " + sql);
    var tables = new List<string> { "Component", "Directory", "Feature", "File", "Media", "Property", "CustomAction", "InstallExecuteSequence" };
    if (Case != "absent") tables.Add("Binary");
    if (sql.Contains("FROM `_Tables` WHERE `Name` = 'Binary'")) return new SIView(tables.Contains("Binary") ? new[] { "Binary" } : new string[0]);
    if (sql.Contains("FROM `_Tables`")) return new SIView(tables);
    if (sql.Contains("FROM `Binary`")) {
      if (!tables.Contains("Binary")) throw new Exception("OpenView,Sql");
      return new SIView(Case == "dll" ? new[] { "CustomActionDll" } : new string[0]);
    }
    throw new Exception("OpenView,Sql");
  } }
public class SIInstaller { public object OpenDatabase(string path, int mode) { return new SIDb(); } }
'@

$dir = Join-Path ([IO.Path]::GetTempPath()) ('step6-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $dir 'out/msi-0.0.2') | Out-Null
Set-Content -LiteralPath (Join-Path $dir 'out/msi-0.0.2/pgvigil-0.0.2-x64.msi') -Value 'stand-in'
$f = Join-Path $dir 'step6.ps1'
$prelude = "Add-Type -TypeDefinition @'`n" + $cs + "`n'@`n[SIDb]::Case = '" + $Case + "'`n"
$file = $prelude + "`$ErrorActionPreference = 'stop'`n" + $text + "`nif ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit `$LASTEXITCODE }`n"
Set-Content -LiteralPath $f -Value $file
Push-Location $dir
$ErrorActionPreference = 'Continue'
& pwsh -NoProfile -NonInteractive -Command ". '$f'" 2>&1 | ForEach-Object { "  step: $_" }
$code = $LASTEXITCODE
Pop-Location
Remove-Item -LiteralPath $dir -Recurse -Force
Write-Host "STEP 6 ($Case) exit $code"
exit $code
