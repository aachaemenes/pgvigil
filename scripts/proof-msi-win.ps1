# proof-msi-win.ps1 - Windows PowerShell 5.1 or 7, elevated, on a throwaway lab VM ONLY (dba-lab-win through the WIN
# queue): pgvigil's MSI (packaging/msi, WiX 5.0.2 pinned in pgvigil.wixproj), the rows .github/workflows/msi.yml
# proves on a GitHub runner, here on a lab VM before any push. It builds two packages from two windows/amd64 binaries
# of one tree (0.0.1 and 0.0.2, each stamped with its own version) with the .NET SDK given in -Dotnet (WixToolset.Sdk
# comes from NuGet at the build), installs 0.0.1, configures a repository that never answers, upgrades to 0.0.2,
# tries a downgrade, asks install.ps1 to install over it, uninstalls; with -ConfigTest it also runs the Windows test
# binary of internal/config for L9's sealed secret access. It refuses to start where pgvigil is installed in any form
# (the service, %ProgramFiles%\pgvigil, %ProgramData%\pgvigil, an installed product named pgvigil), and removes all it
# made, each step read back.
#   powershell.exe -NoProfile -File scripts\proof-msi-win.ps1 -Bin1 C:\kit\bin-0.0.1\pgvigil.exe
#       -Bin2 C:\kit\bin-0.0.2\pgvigil.exe -MsiDir C:\kit\packaging\msi -Dotnet C:\kit\dotnet\dotnet.exe
#       -InstallScript C:\kit\docs\install.ps1 [-ConfigTest C:\kit\config.test.exe] [-LogDir C:\kit-run]
#       [-NugetConfig C:\kit\nuget.config]
#   -LogDir: msiexec's logs (and the undo's) are copied there as msi-<name>.log before the work folder goes, so a FAIL
#   comes back with its 'Return value 3' lines; -NugetConfig: the build's restore reads that file alone
#   (-p:RestoreConfigFile), so no NuGet.Config is made in the running account's profile
#   a run cut before its end (a time limit, a dropped session): the same command with -Undo runs the undo alone
# Expected (written before its first run, 2026-11-20):
#  B  'dotnet build packaging\msi\pgvigil.wixproj' exit 0 for 0.0.1 and for 0.0.2, each in its own intermediate folder
#     (obj\<version>\) and each .msi made, the build's seconds printed (a build of a second or two linked nothing); a failed
#     build prints every line of its output that names an error and its last target lines
#  C0 (the reads the rows below lean on, shown in this run's own log first): a function that returns @(one object)
#     hands its caller the bare object, and a [pscustomobject]'s Count under this PowerShell ('COUNT OF ONE RETURNED
#     [<n>]'; empty under Windows PowerShell 5.1), against @(<call>)'s Count ('[1]'); T0 each Windows Installer query
#     the M1 read uses, run alone on the 0.0.2 package ('QUERY <sql> ok <rows>' or 'QUERY <sql> refused: <words> |
#     <Windows Installer's own error record>', the child's exit code beside it), and a read with no SQL: Expected (this
#     package has no Binary table - its custom actions name a file and a folder, no binary): the _Tables read with its
#     WHERE either answers 'ok 0 row(s)' or is refused (the question this row settles); the _Tables read whole 'ok <n>
#     row(s)', n over 10; the Binary read 'refused' (no such table: M1's own 'absent' case, not a fault); and
#     'TABLEPERSISTENT Binary 2' (MSICONDITION_NONE: no such table)
#  M1 the 0.0.2 package's Binary table is absent or empty (no custom-action DLL ships) - read in a child powershell.exe,
#     so no COM object of the read holds the package open when the undo removes it
#  I1 'msiexec /i' of 0.0.1 exit 0: %ProgramFiles%\pgvigil\pgvigil.exe there, the service pgvigil made, the exe
#     says 0.0.1
#  U1 repo.dsn names a host that never answers (the new service stops at once); 'msiexec /i' of 0.0.2 exit 0: one
#     installed product pgvigil, version 0.0.2, the exe says 0.0.2, the service there and running the MSI's exe
#  D1 'msiexec /i' of 0.0.1 over it refused (exit not 0, its log says 'A newer pgvigil is installed' and not the
#     service launch condition's 'A pgvigil service is already installed'); 0.0.2 alone
#  S1 install.ps1 run over it refuses, naming msiexec
#  X1 'msiexec /x' exit 0: no service, no pgvigil.exe; pgvigil.yaml and repo.dsn kept under %ProgramData%\pgvigil
#  L9 (with -ConfigTest) 'config.test.exe -test.run TestSealAccessIsProtectedL9' prints its PASS line
#  Z  the undo, each step on its own and read back: any installed product pgvigil removed (by its product code), the
#     service gone, %ProgramFiles%\pgvigil gone, %ProgramData%\pgvigil (this run's) removed, the work folder removed -
#     KEPT when an earlier undo step failed, so the printed -Undo line still finds this run's marker
# Exit 0 = every row as stated; 1 = a row differs; 2 = refused to start.
param(
    [Parameter(Mandatory = $true)][string]$Bin1,
    [Parameter(Mandatory = $true)][string]$Bin2,
    [Parameter(Mandatory = $true)][string]$MsiDir,
    [Parameter(Mandatory = $true)][string]$Dotnet,
    [Parameter(Mandatory = $true)][string]$InstallScript,
    [string]$ConfigTest = '',
    [string]$LogDir = '',
    [string]$NugetConfig = '',
    [switch]$Undo,
    [string]$Work = 'C:\pgvigil-msi-proof'
)
$ErrorActionPreference = 'Stop'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'REFUSED: run elevated'; exit 2 }
$ProgDir = Join-Path $env:ProgramFiles 'pgvigil'
$Exe = Join-Path $ProgDir 'pgvigil.exe'
$DataDir = Join-Path $env:ProgramData 'pgvigil'
$Uninstall = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'

function Invoke-Native([scriptblock]$cmd) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $cmd 2>&1 | ForEach-Object { "$_" }; return @{ Code = $LASTEXITCODE; Out = ($out -join "`n") } } finally { $ErrorActionPreference = $eap }
}
$failed = 0
function Row([string]$name, [bool]$ok, [string]$what) {
    if ($ok) { Write-Host "OK   $name $what" } else { Write-Host "FAIL $name $what"; $script:failed++ }
}
# an installed MSI product pgvigil: its key is the product code (the app's own Uninstall\pgvigil entry is not one)
function Get-Installed { return @(Get-ItemProperty $Uninstall -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'pgvigil' -and $_.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$' }) }
# msiexec waited for, its log in the work folder; each path quoted
function Invoke-Msi([string]$verb, [string]$package, [string]$logName) {
    $log = Join-Path $Work $logName
    $proc = Start-Process msiexec.exe -ArgumentList $verb, ('"{0}"' -f $package), '/qn', '/norestart', '/l*v', ('"{0}"' -f $log) -Wait -PassThru
    return @{ Code = $proc.ExitCode; Log = $log }
}
function Get-LogTail([string]$log) { if (Test-Path -LiteralPath $log) { return ((Get-Content -LiteralPath $log -Tail 8) -join ' | ') } else { return 'no log' } }

# Z: the undo, every step on its own (one that throws never skips the next) and read back
function Invoke-Undo {
    $failedBefore = $script:failed
    try {
        $n = 0
        foreach ($product in Get-Installed) {
            $code = $product.PSChildName
            $n++
            $res = Invoke-Msi '/x' $code "undo-x-$n.log"
            Write-Host "     msiexec /x $code exit $($res.Code)"
        }
        Row 'Z' ((Get-Installed).Count -eq 0) 'no installed product pgvigil left'
    } catch { Row 'Z' $false "the product's removal: $($_.Exception.Message)" }
    try {
        if (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) {
            if (Test-Path -LiteralPath $Exe) { $null = Invoke-Native { & $Exe uninstall } } else { $null = Invoke-Native { & sc.exe delete pgvigil } }
        }
        Row 'Z' (-not (Get-Service -Name pgvigil -ErrorAction SilentlyContinue)) 'no service pgvigil left'
    } catch { Row 'Z' $false "the service's removal: $($_.Exception.Message)" }
    try {
        if (Test-Path -LiteralPath $ProgDir) { Remove-Item -LiteralPath $ProgDir -Recurse -Force }
        Row 'Z' (-not (Test-Path -LiteralPath $ProgDir)) "$ProgDir gone"
    } catch { Row 'Z' $false "$ProgDir not removed: $($_.Exception.Message)" }
    try {
        # this run's: the start refuses where it existed before
        if (Test-Path -LiteralPath $DataDir) { Remove-Item -LiteralPath $DataDir -Recurse -Force }
        Row 'Z' (-not (Test-Path -LiteralPath $DataDir)) "$DataDir (this run's configuration and repo.dsn) removed"
    } catch { Row 'Z' $false "$DataDir not removed: $($_.Exception.Message)" }
    if ($LogDir -and (Test-Path -LiteralPath $Work)) {
        foreach ($log in @(Get-ChildItem -LiteralPath $Work -Filter '*.log' -File -ErrorAction SilentlyContinue)) {
            Copy-Item -LiteralPath $log.FullName -Destination (Join-Path $LogDir ('msi-' + $log.Name)) -Force -ErrorAction SilentlyContinue
        }
        Write-Host "     the msiexec logs copied to $LogDir as msi-*.log"
    }
    if ($script:failed -gt $failedBefore) {
        Write-Host "KEPT ${Work}: an undo step above failed - the -Undo line runs the undo again"
        return
    }
    try {
        if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
        Row 'Z' (-not (Test-Path -LiteralPath $Work)) "$Work removed"
    } catch { Row 'Z' $false "$Work not removed: $($_.Exception.Message)" }
}

if ($Undo) {
    if (-not (Test-Path -LiteralPath $Work)) { Write-Host "REFUSED: -Undo: no $Work - nothing of this proof's run is here"; exit 2 }
    Invoke-Undo
    if ($failed -eq 0) { Write-Host 'UNDONE: every step read back'; exit 0 }
    Write-Host "UNDO FAIL: $failed step(s)"; exit 1
}

if (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) { Write-Host 'REFUSED: the service pgvigil exists here - this proof runs on a machine without pgvigil'; exit 2 }
foreach ($left in $ProgDir, $DataDir) { if (Test-Path -LiteralPath $left) { Write-Host "REFUSED: $left exists (this proof removes what it makes, never what it found)"; exit 2 } }
if (@(Get-Installed).Count) { Write-Host 'REFUSED: a product named pgvigil is installed here'; exit 2 }
if (Test-Path -LiteralPath $Work) { Write-Host "REFUSED: $Work exists (a cut run's: this command with -Undo first)"; exit 2 }
foreach ($need in $Bin1, $Bin2, (Join-Path $MsiDir 'pgvigil.wixproj'), $Dotnet, $InstallScript) { if (-not (Test-Path -LiteralPath $need)) { Write-Host "REFUSED: no $need"; exit 2 } }
if ($ConfigTest -and -not (Test-Path -LiteralPath $ConfigTest)) { Write-Host "REFUSED: no $ConfigTest"; exit 2 }
if ($NugetConfig -and -not (Test-Path -LiteralPath $NugetConfig)) { Write-Host "REFUSED: no $NugetConfig"; exit 2 }
if ($LogDir -and -not (Test-Path -LiteralPath $LogDir)) { Write-Host "REFUSED: no $LogDir"; exit 2 }
$undoLine = "powershell.exe -NoProfile -File $($MyInvocation.MyCommand.Path) -Bin1 $Bin1 -Bin2 $Bin2 -MsiDir $MsiDir -Dotnet $Dotnet -InstallScript $InstallScript -Work $Work$(if ($LogDir) { ' -LogDir ' + $LogDir }) -Undo"
Write-Host "a run cut before its end is undone by: $undoLine"

New-Item -ItemType Directory -Path $Work | Out-Null
try {
    # B: the two packages, each from its own binary (an upgrade that did not replace the file shows in U1)
    $msi = @{}
    foreach ($pair in @(@('0.0.1', $Bin1), @('0.0.2', $Bin2))) {
        $ver = $pair[0]; $outDir = Join-Path $Work "msi-$ver"
        $restore = @()
        if ($NugetConfig) { $restore = @("-p:RestoreConfigFile=$NugetConfig") }
        # each version its own intermediate folder and no incremental build: a second build in the project's one
        # obj\Release found the first version's outputs up to date, linked no package and failed its copy (MSB3030 after a
        # second); --no-incremental relinks even if the folder property were not honoured (the first package is already
        # copied out to its own -o folder)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $build = Invoke-Native { & $Dotnet build (Join-Path $MsiDir 'pgvigil.wixproj') -c Release --no-incremental -v:n "-p:PgvVersion=$ver" "-p:PgvBinary=$($pair[1])" "-p:IntermediateOutputPath=obj\$ver\" @restore -o $outDir }
        $sw.Stop()
        $made = Join-Path $outDir "pgvigil-$ver-x64.msi"
        $msi[$ver] = $made
        $lastLines = (("$($build.Out)" -split "`n" | Where-Object { $_ } | Select-Object -Last 3) -join ' | ')
        Row 'B' ($build.Code -eq 0 -and (Test-Path -LiteralPath $made)) "dotnet build of $ver exit $($build.Code) in $([int]$sw.Elapsed.TotalSeconds) s, $made $(if (Test-Path -LiteralPath $made) { (Get-Item -LiteralPath $made).Length } else { 'MISSING' }) bytes; last: $lastLines"
        # a failed build's own words: every line that names an error (the last three lines say only how many)
        if ($build.Code -ne 0) {
            @("$($build.Out)" -split "`n" | Where-Object { $_ -match '(?i)\berror\b' -and $_ -notmatch '^\s*\d+ Error\(s\)' } | Select-Object -First 20) | ForEach-Object { Write-Host "     build $ver error: $($_.Trim())" }
            # and which targets ran or were skipped as up to date before it failed (normal verbosity's target lines)
            @("$($build.Out)" -split "`n" | Where-Object { $_ -match '(?i)^\s*skipping target|^\s*target "|^[A-Za-z_][A-Za-z0-9_]*:\s*$' } | Select-Object -Last 40) | ForEach-Object { Write-Host "     build $ver target: $($_.Trim())" }
        }
    }
    if (-not ((Test-Path -LiteralPath $msi['0.0.1']) -and (Test-Path -LiteralPath $msi['0.0.2']))) { throw 'no package to install: the rows after B need both' }

    # C0: a function's @(one object) as its caller gets it, under this PowerShell - the read U1 and D1 lean on
    function Get-OneWrapped { return @([pscustomobject]@{ DisplayVersion = '0.0.2' }) }
    $one = Get-OneWrapped
    Write-Host "C0 COUNT OF ONE RETURNED [$($one.Count)] AS @(...) [$(@(Get-OneWrapped).Count)] under $($PSVersionTable.PSVersion)"
    # T0: each query of the M1 read run alone on the 0.0.2 package, in its own child (its COM objects end with it)
    foreach ($q in @("SELECT ``Name`` FROM ``_Tables`` WHERE ``Name`` = 'Binary'", 'SELECT `Name` FROM `_Tables`', 'SELECT `Name` FROM `Binary`')) {
        $qScript = @'
$installer = New-Object -ComObject WindowsInstaller.Installer
$db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @('PGV_MSI_PATH', 0))
try {
    $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @('PGV_SQL'))
    $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
    $n = 0; while ($view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)) { $n++ }
    'ok ' + $n + ' row(s)'
} catch {
    $words = $_.Exception.InnerException.Message
    try { $er = $installer.GetType().InvokeMember('LastErrorRecord', 'InvokeMethod', $null, $installer, $null); if ($er) { $words += ' | ' + $er.GetType().InvokeMember('FormatText', 'InvokeMethod', $null, $er, $null) } } catch { }
    'refused: ' + $words
}
'@
        $qScript = $qScript.Replace('PGV_MSI_PATH', $msi['0.0.2'].Replace("'", "''")).Replace('PGV_SQL', $q.Replace("'", "''"))
        $qr = Invoke-Native { & powershell.exe -NoProfile -NonInteractive -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($qScript))) }
        $qLine = (("$($qr.Out)" -split "`n") | Where-Object { $_ -match '^(ok|refused)' } | Select-Object -First 1)
        Write-Host "T0 QUERY $q $(if ($qLine) { $qLine } else { 'no answer: ' + $qr.Out }) (child exit $($qr.Code))"
    }
    # and with no SQL at all: Database.TablePersistent('Binary') - 0 temporary, 1 persistent, 2 no such table, 3 error
    $tpScript = @'
$installer = New-Object -ComObject WindowsInstaller.Installer
$db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @('PGV_MSI_PATH', 0))
try { 'TABLEPERSISTENT Binary ' + $db.GetType().InvokeMember('TablePersistent', 'GetProperty', $null, $db, @('Binary')) } catch { 'TABLEPERSISTENT unread: ' + $_.Exception.InnerException.Message }
'@
    $tpScript = $tpScript.Replace('PGV_MSI_PATH', $msi['0.0.2'].Replace("'", "''"))
    $tp = Invoke-Native { & powershell.exe -NoProfile -NonInteractive -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($tpScript))) }
    $tpLine = (("$($tp.Out)" -split "`n") | Where-Object { $_ -match '^TABLEPERSISTENT ' } | Select-Object -First 1)
    Write-Host "T0 $(if ($tpLine) { $tpLine } else { 'TABLEPERSISTENT no answer: ' + $tp.Out }) (child exit $($tp.Code))"

    # M1: in a child powershell.exe - its COM objects (the installer, the database, the views, the records) end with it,
    # so none holds the package open for the undo; it prints one line: 'BINARY absent', 'BINARY empty' or 'BINARY holds <names>'
    $m1Script = @'
$ErrorActionPreference = 'Stop'
$installer = New-Object -ComObject WindowsInstaller.Installer
$db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @('PGV_MSI_PATH', 0))
function Read-Column([string]$sql) {
    try { $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @($sql)) }
    catch {
        # Write-Host: the function's output is captured by its caller, and exit ends the child before that is printed
        $words = $_.Exception.InnerException.Message
        try { $er = $installer.GetType().InvokeMember('LastErrorRecord', 'InvokeMethod', $null, $installer, $null); if ($er) { $words += ' | ' + $er.GetType().InvokeMember('FormatText', 'InvokeMethod', $null, $er, $null) } } catch { }
        Write-Host ('BINARY unread: Windows Installer refused the query ' + $sql + ' - ' + $words); exit 1
    }
    $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
    $vals = @()
    while ($true) {
        $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if (-not $rec) { break }
        $vals += $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1)
        $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($rec)
    }
    $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
    $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($view)
    return , $vals
}
$all = Read-Column 'SELECT `Name` FROM `_Tables`'
$tables = @($all | Where-Object { $_ -eq 'Binary' })
$names = @()
if ($tables.Count) { $names = Read-Column 'SELECT `Name` FROM `Binary`' }
if (-not $tables.Count) { 'BINARY absent' } elseif ($names.Count) { 'BINARY holds ' + ($names -join ', ') } else { 'BINARY empty' }
'@
    $m1Script = $m1Script.Replace('PGV_MSI_PATH', $msi['0.0.2'].Replace("'", "''"))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($m1Script))
    $m1 = Invoke-Native { & powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded }
    $m1Line = (("$($m1.Out)" -split "`n") | Where-Object { $_ -match '^BINARY ' } | Select-Object -First 1)
    Row 'M1' ($m1.Code -eq 0 -and ($m1Line -eq 'BINARY absent' -or $m1Line -eq 'BINARY empty')) "the Binary table (a child powershell.exe, exit $($m1.Code)): $(if ($m1Line) { $m1Line } else { 'no answer: ' + $m1.Out })"

    # I1
    $res = Invoke-Msi '/i' $msi['0.0.1'] 'install-1.log'
    $said = if (Test-Path -LiteralPath $Exe) { "$((Invoke-Native { & $Exe version }).Out)" } else { 'no exe' }
    Row 'I1' ($res.Code -eq 0 -and (Test-Path -LiteralPath $Exe) -and [bool](Get-Service -Name pgvigil -ErrorAction SilentlyContinue) -and $said -match '\b0\.0\.1\b') "install of 0.0.1 exit $($res.Code); the exe says '$said'$(if ($res.Code -ne 0) { '; log: ' + (Get-LogTail $res.Log) })"

    # U1: the host configured with a repository that never answers, then the upgrade
    [IO.File]::WriteAllText((Join-Path $DataDir 'repo.dsn'), "host=pgvigil-none.invalid dbname=x user=x connect_timeout=2`r`n")
    $res = Invoke-Msi '/i' $msi['0.0.2'] 'install-2.log'
    $inst = @(Get-Installed)   # @(): one product comes back from the function as a bare object (C0)
    $said = if (Test-Path -LiteralPath $Exe) { "$((Invoke-Native { & $Exe version }).Out)" } else { 'no exe' }
    $svc = Get-CimInstance Win32_Service -Filter "Name='pgvigil'"
    $runsMsiExe = $svc -and ($svc.PathName -like "*$Exe*")
    Row 'U1' ($res.Code -eq 0 -and $inst.Count -eq 1 -and $inst[0].DisplayVersion -eq '0.0.2' -and $said -match '\b0\.0\.2\b' -and $runsMsiExe) "upgrade to 0.0.2 exit $($res.Code); installed $($inst.Count): $(($inst | ForEach-Object { $_.DisplayVersion }) -join ', '); the exe says '$said'; the service $(if ($svc) { $svc.State + ' ' + $svc.PathName } else { 'GONE' })$(if ($res.Code -ne 0) { '; log: ' + (Get-LogTail $res.Log) })"

    # D1
    $res = Invoke-Msi '/i' $msi['0.0.1'] 'downgrade.log'
    $refusal = (Test-Path -LiteralPath $res.Log) -and (Select-String -LiteralPath $res.Log -SimpleMatch 'A newer pgvigil is installed' -Quiet)
    $wrongWords = (Test-Path -LiteralPath $res.Log) -and (Select-String -LiteralPath $res.Log -SimpleMatch 'A pgvigil service is already installed' -Quiet)
    $inst = @(Get-Installed)
    $d1ok = $res.Code -ne 0 -and $refusal -and -not $wrongWords -and $inst.Count -eq 1 -and $inst[0].DisplayVersion -eq '0.0.2'
    Row 'D1' $d1ok "the downgrade exit $($res.Code), the refusal in its log $refusal, the service condition's words $wrongWords; installed $($inst.Count): $(($inst | ForEach-Object { $_.DisplayVersion }) -join ', ')$(if (-not $d1ok) { '; log: ' + (Get-LogTail $res.Log) })"

    # S1: install.ps1 over an MSI machine, in a process of its own
    $ps = Invoke-Native { & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "`$env:PGVIGIL_NO_SERVICE = ''; try { & '$InstallScript'; 'NOT REFUSED' } catch { 'REFUSED: ' + `$_ }" }
    Row 'S1' ($ps.Out -match 'REFUSED: ' -and $ps.Out -match 'msiexec') "install.ps1 over the MSI's install: $((("$($ps.Out)" -split "`n") | Where-Object { $_ -match 'REFUSED' } | Select-Object -First 1))"

    # X1
    $res = Invoke-Msi '/x' $msi['0.0.2'] 'uninstall.log'
    $kept = @('pgvigil.yaml', 'repo.dsn' | Where-Object { Test-Path -LiteralPath (Join-Path $DataDir $_) })
    $x1ok = $res.Code -eq 0 -and -not (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $Exe) -and $kept.Count -eq 2
    Row 'X1' $x1ok "uninstall exit $($res.Code); service gone $(-not (Get-Service -Name pgvigil -ErrorAction SilentlyContinue)); exe gone $(-not (Test-Path -LiteralPath $Exe)); kept: $($kept -join ', ')$(if (-not $x1ok) { '; log: ' + (Get-LogTail $res.Log) })"

    # L9
    if ($ConfigTest) {
        $res = Invoke-Native { & $ConfigTest -test.run '^TestSealAccessIsProtectedL9$' -test.v }
        $pass = "$($res.Out)" -match '--- PASS: TestSealAccessIsProtectedL9'
        Row 'L9' ($res.Code -eq 0 -and $pass) "config.test.exe exit $($res.Code): $((("$($res.Out)" -split "`n") | Where-Object { $_ -match '^(--- |ok|PASS|FAIL)' }) -join ' | ')"
    } else {
        Write-Host 'NOT RUN L9 (no -ConfigTest)'
    }
} catch {
    Row 'X' $false "the proof stopped: $($_.Exception.Message)"
} finally {
    Invoke-Undo
}
if ($failed -eq 0) { Write-Host 'PASS: every row'; exit 0 }
Write-Host "FAIL: $failed row(s)"; exit 1
