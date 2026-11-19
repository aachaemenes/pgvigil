# proof-app-openwith-win.ps1 - Windows PowerShell 5.1 or 7, on a lab VM (dba-lab-win through the WIN queue): the app's
# Open with entries for .sqlplan / .xdl and the hand-over of a second start's files (RELNOTES L232).
#   powershell.exe -NoProfile -File scripts\proof-app-openwith-win.ps1 -App C:\proof\pgvigil-app.exe [-Tier user|machine]
#       [-RepoDsn "<the UI's repository dsn>"]
# pgvigil.exe sits beside pgvigil-app.exe (the release zip). -Tier user (the default) needs the WebView2 runtime on the
# VM; -Tier machine needs an elevated prompt and installs the collector service too (its uninstall removes it).
# Rows:
#   R0 before the install: the extension keys' default values read (the default program); a foreign value
#      'Other.Prog.1' seeded in .sqlplan's OpenWithProgids (another program's entry)
#   R1 the install exits 0 and writes, under HKCU (user) or HKLM (machine) Software\Classes: .sqlplan's and .xdl's
#      OpenWithProgids values pgvigil.sqlplan.1 / pgvigil.xdl.1 as REG_NONE; each ProgID's AllowSilentDefaultTakeOver
#      (REG_NONE), DefaultIcon '<app>,0', shell\open MultiSelectModel 'Document' and shell\open\command
#      '"<app>" "%1"'
#   R2 the extensions' default values unchanged (never the default program); Other.Prog.1 still there
#   H1 (only with -RepoDsn, in the user's own interactive desktop session; else 'NOT RUN' and why) the app started as
#      the registry's command starts it, with a.sqlplan: its log says 'files: 1 from the command line', 'a.sqlplan
#      posted to the page' and 'the page opened "a.sqlplan" as "Query plan: a.sqlplan"'
#   H2 a second start with b.xdl exits 0 within 15 s; the log says 'handed over by a second start' and 'the page
#      opened "b.xdl" as "Deadlock graph: b.xdl"'; one pgvigil-app process runs
#   H3 a third start with c.txt: the log says 'c.txt refused' and the page opened it as its words' tab
#   H4 -quit ends the app
#   U1 the uninstall exits 0: both ProgID keys gone, pgvigil's two OpenWithProgids values gone, Other.Prog.1 and
#      the OpenWithProgids key still there
#   Z  the seeded value removed (and a key the proof made), read back
# Not proven here: Explorer's own Open with menu (a person's click: an 'ALLEN TRY'), the default-program choice
# ('Always'), an app started elevated refusing a lower Explorer's files.
# Exit 0 = every row run as stated; 1 = a row differs; 2 = refused to start.
param(
    [Parameter(Mandatory = $true)][string]$App,
    [ValidateSet('user', 'machine')][string]$Tier = 'user',
    [string]$RepoDsn = ''
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $App)) { Write-Host "REFUSED: no $App"; exit 2 }
if (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $App) 'pgvigil.exe'))) { Write-Host "REFUSED: no pgvigil.exe beside $App"; exit 2 }

$failed = 0
function Row([string]$name, [bool]$ok, [string]$what) {
    if ($ok) { Write-Host "OK   $name $what" } else { Write-Host "FAIL $name $what"; $script:failed++ }
}
function Invoke-App([string[]]$argList, [int]$waitMs) {
    $out = Join-Path $env:TEMP ('pgvow-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.out')
    $proc = Start-Process -FilePath $App -ArgumentList $argList -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $null = $proc.Handle   # held, so ExitCode reads after WaitForExit under 5.1 (else it can read null)
    $done = $proc.WaitForExit($waitMs)
    $text = ''
    foreach ($file in @($out, "$out.err")) { if (Test-Path -LiteralPath $file) { $text += (Get-Content -LiteralPath $file -Raw); Remove-Item -LiteralPath $file -Force } }
    $code = if ($done) { $proc.ExitCode } else { -1 }
    return @{ Code = $code; Out = $text }
}
$hive = if ($Tier -eq 'user') { [Microsoft.Win32.Registry]::CurrentUser } else { [Microsoft.Win32.Registry]::LocalMachine }
$hiveName = if ($Tier -eq 'user') { 'HKCU' } else { 'HKLM' }
function Read-Default([string]$sub) {
    $key = $hive.OpenSubKey($sub)
    if ($null -eq $key) { return '<no key>' }
    try { $val = $key.GetValue(''); if ($null -eq $val) { return '<no value>' } else { return [string]$val } } finally { $key.Close() }
}
function Value-Kind([string]$sub, [string]$name) {
    $key = $hive.OpenSubKey($sub)
    if ($null -eq $key) { return '<no key>' }
    try { if ($key.GetValueNames() -contains $name) { return [string]$key.GetValueKind($name) } else { return '<no value>' } } finally { $key.Close() }
}
function Value-Text([string]$sub, [string]$name) {
    $key = $hive.OpenSubKey($sub)
    if ($null -eq $key) { return '<no key>' }
    try { $val = $key.GetValue($name); if ($null -eq $val) { return '<no value>' } else { return [string]$val } } finally { $key.Close() }
}

$installed = if ($Tier -eq 'user') { Join-Path $env:LOCALAPPDATA 'pgvigil\pgvigil-app.exe' } else { Join-Path $env:ProgramFiles 'pgvigil\pgvigil-app.exe' }
$classes = 'Software\Classes'
$owp = "$classes\.sqlplan\OpenWithProgids"
$madeOwpKey = $null -eq $hive.OpenSubKey($owp)
$madeExtKey = $null -eq $hive.OpenSubKey("$classes\.sqlplan")
$work = Join-Path $env:TEMP ('pgvow-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    # R0
    $before = @{ sqlplan = (Read-Default "$classes\.sqlplan"); xdl = (Read-Default "$classes\.xdl") }
    $key = $hive.CreateSubKey($owp)
    $key.SetValue('Other.Prog.1', [byte[]]@(), [Microsoft.Win32.RegistryValueKind]::None); $key.Close()
    Row 'R0' ((Value-Kind $owp 'Other.Prog.1') -eq 'None') "$hiveName defaults before: .sqlplan '$($before.sqlplan)', .xdl '$($before.xdl)'; Other.Prog.1 seeded"

    # R1
    $inst = if ($Tier -eq 'user') { Invoke-App @('install', '-user', '-no-autostart', '-no-update-check') 180000 } else { Invoke-App @('install', '-no-autostart', '-no-update-check') 300000 }
    $want = @(
        @("$classes\.sqlplan\OpenWithProgids", 'pgvigil.sqlplan.1', 'None', $null),
        @("$classes\.xdl\OpenWithProgids", 'pgvigil.xdl.1', 'None', $null))
    foreach ($progId in @('pgvigil.sqlplan.1', 'pgvigil.xdl.1')) {
        $want += , @("$classes\$progId", 'AllowSilentDefaultTakeOver', 'None', $null)
        $want += , @("$classes\$progId\DefaultIcon", '', 'String', "$installed,0")
        $want += , @("$classes\$progId\shell\open", 'MultiSelectModel', 'String', 'Document')
        $want += , @("$classes\$progId\shell\open\command", '', 'String', ('"' + $installed + '" "%1"'))
    }
    $bad = @()
    foreach ($line in $want) {
        $kind = Value-Kind $line[0] $line[1]
        if ($kind -ne $line[2]) { $bad += "$($line[0])\$($line[1]) kind $kind"; continue }
        if ($null -ne $line[3] -and (Value-Text $line[0] $line[1]) -ne $line[3]) { $bad += "$($line[0])\$($line[1]) = '$(Value-Text $line[0] $line[1])'" }
    }
    Row 'R1' ($inst.Code -eq 0 -and $bad.Count -eq 0) "install exit $($inst.Code); $($want.Count) values read, wrong: $(if ($bad.Count) { $bad -join '; ' } else { 'none' }); its open with line: $((($inst.Out -split "`n") | Where-Object { $_ -match 'open with' }) -join ' ')"

    # R2
    $after = @{ sqlplan = (Read-Default "$classes\.sqlplan"); xdl = (Read-Default "$classes\.xdl") }
    Row 'R2' ($after.sqlplan -eq $before.sqlplan -and $after.xdl -eq $before.xdl -and (Value-Kind $owp 'Other.Prog.1') -eq 'None') "defaults after: .sqlplan '$($after.sqlplan)', .xdl '$($after.xdl)'; Other.Prog.1 $(Value-Kind $owp 'Other.Prog.1')"

    # H1-H4
    $session = (Get-Process -Id $PID).SessionId
    $why = ''
    if ($RepoDsn -eq '') { $why = 'no -RepoDsn (the page needs a repository to load)' }
    elseif ($session -eq 0 -or -not [Environment]::UserInteractive) { $why = "not an interactive desktop session (session $session): the window and its tray need one" }
    if ($why -ne '') {
        foreach ($hRow in @('H1', 'H2', 'H3', 'H4')) { Write-Host "NOT RUN $hRow $why" }
    } else {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $planText = '<?xml version="1.0" encoding="utf-16"?><ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan" Version="1.564"><BatchSequence><Batch><Statements><StmtSimple StatementText="SELECT 1" StatementType="SELECT" StatementSubTreeCost="0.1"><QueryPlan><RelOp NodeId="0" PhysicalOp="Constant Scan" LogicalOp="Constant Scan" EstimateRows="1" EstimatedTotalSubtreeCost="0.1"/></QueryPlan></StmtSimple></Statements></Batch></BatchSequence></ShowPlanXML>'
        $planFile = Join-Path $work 'a.sqlplan'; [IO.File]::WriteAllText($planFile, $planText, [Text.Encoding]::Unicode)
        $xdlFile = Join-Path $work 'b.xdl'; [IO.File]::WriteAllText($xdlFile, '<deadlock><victim-list><victimProcess id="p1"/></victim-list><process-list><process id="p1" spid="55"/><process id="p2" spid="61"/></process-list><resource-list/></deadlock>', [Text.Encoding]::ASCII)
        $txtFile = Join-Path $work 'c.txt'; [IO.File]::WriteAllText($txtFile, 'x', [Text.Encoding]::ASCII)
        $cfgFile = Join-Path (Join-Path $env:LOCALAPPDATA 'pgvigil') 'pgvigil.yaml'
        New-Item -ItemType Directory -Path (Split-Path -Parent $cfgFile) -Force | Out-Null
        $cfgBefore = if (Test-Path -LiteralPath $cfgFile) { Get-Content -LiteralPath $cfgFile -Raw } else { $null }
        [IO.File]::WriteAllText($cfgFile, "repository:`r`n  dsn: `"$RepoDsn`"`r`ninstances: []`r`n", [Text.Encoding]::ASCII)
        $log = Join-Path $env:LOCALAPPDATA 'pgvigil\app.log'
        $mark = if (Test-Path -LiteralPath $log) { (Get-Item -LiteralPath $log).Length } else { 0 }
        function New-LogText { if (-not (Test-Path -LiteralPath $log)) { return '' }; $logText = [IO.File]::ReadAllText($log); if ($logText.Length -gt $mark) { return $logText.Substring([int]$mark) } else { return $logText } }
        function Wait-Log([string]$pattern, [int]$secs) { $end = (Get-Date).AddSeconds($secs); while ((Get-Date) -lt $end) { if ((New-LogText) -match $pattern) { return $true }; Start-Sleep -Milliseconds 500 }; return $false }
        $cmd = Value-Text "$classes\pgvigil.sqlplan.1\shell\open\command" ''
        Start-Process -FilePath $installed -ArgumentList ('"' + $planFile + '"') | Out-Null
        $h1 = (Wait-Log 'files: 1 from the command line' 60) -and (Wait-Log 'a\.sqlplan posted to the page' 120) -and (Wait-Log 'the page opened "a\.sqlplan" as "Query plan: a\.sqlplan"' 120)
        Row 'H1' $h1 "the registry's command '$cmd' run with a.sqlplan; the log's files lines: $(((New-LogText) -split "`n" | Where-Object { $_ -match 'files:' }) -join ' | ')"
        $p2 = Start-Process -FilePath $installed -ArgumentList ('"' + $xdlFile + '"') -PassThru
        $ended = $p2.WaitForExit(15000)
        $h2 = $ended -and $p2.ExitCode -eq 0 -and (Wait-Log 'handed over by a second start' 30) -and (Wait-Log 'the page opened "b\.xdl" as "Deadlock graph: b\.xdl"' 120)
        $procs = @(Get-Process -Name 'pgvigil-app' -ErrorAction SilentlyContinue).Count
        Row 'H2' ($h2 -and $procs -eq 1) "the second start ended $ended exit $(if ($ended) { $p2.ExitCode } else { 'n/a' }); pgvigil-app processes $procs"
        $p3 = Start-Process -FilePath $installed -ArgumentList ('"' + $txtFile + '"') -PassThru
        $null = $p3.WaitForExit(15000)
        $h3 = (Wait-Log 'c\.txt refused' 60) -and (Wait-Log 'the page opened "c\.txt" as "c\.txt"' 60)
        Row 'H3' $h3 'c.txt refused and shown as its tab'
        $quitRun = Invoke-App @('-quit') 20000
        Start-Sleep -Seconds 5
        Row 'H4' ($quitRun.Code -eq 0 -and @(Get-Process -Name 'pgvigil-app' -ErrorAction SilentlyContinue).Count -eq 0) "-quit exit $($quitRun.Code)"
        if ($null -eq $cfgBefore) { Remove-Item -LiteralPath $cfgFile -Force -ErrorAction SilentlyContinue } else { [IO.File]::WriteAllText($cfgFile, $cfgBefore, [Text.Encoding]::ASCII) }
    }

    # U1
    $un = if ($Tier -eq 'user') { Invoke-App @('uninstall', '-user') 120000 } else { Invoke-App @('uninstall') 300000 }
    Start-Sleep -Seconds 3
    $gone = ($null -eq $hive.OpenSubKey("$classes\pgvigil.sqlplan.1")) -and ($null -eq $hive.OpenSubKey("$classes\pgvigil.xdl.1"))
    $vals = (Value-Kind $owp 'pgvigil.sqlplan.1') -eq '<no value>' -and (Value-Kind "$classes\.xdl\OpenWithProgids" 'pgvigil.xdl.1') -eq '<no value>'
    Row 'U1' ($un.Code -eq 0 -and $gone -and $vals -and (Value-Kind $owp 'Other.Prog.1') -eq 'None') "uninstall exit $($un.Code); ProgIDs gone $gone; pgvigil's values gone $vals; Other.Prog.1 $(Value-Kind $owp 'Other.Prog.1')"
} finally {
    # Z: the seed out, and a key only the proof made
    $key = $hive.OpenSubKey($owp, $true)
    if ($null -ne $key) { $key.DeleteValue('Other.Prog.1', $false); $left = $key.ValueCount; $key.Close(); if ($madeOwpKey -and $left -eq 0) { $hive.DeleteSubKey($owp, $false) } }
    if ($madeExtKey) { $extKey = $hive.OpenSubKey("$classes\.sqlplan"); if ($null -ne $extKey) { $count = $extKey.SubKeyCount + $extKey.ValueCount; $extKey.Close(); if ($count -eq 0) { $hive.DeleteSubKey("$classes\.sqlplan", $false) } } }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    Write-Host "Z    the seed removed: Other.Prog.1 $(Value-Kind $owp 'Other.Prog.1'); the proof's folder $(if (Test-Path -LiteralPath $work) { 'LEFT' } else { 'gone' })"
}
if ($failed -gt 0) { Write-Host "RESULT: $failed row(s) differ"; exit 1 }
Write-Host 'RESULT: every row run as stated'
exit 0
