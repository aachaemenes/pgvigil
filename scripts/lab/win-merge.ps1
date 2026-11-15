# win-merge.ps1 - a merge replication lab on the database mirroring lab of win-mirroring.ps1, for part W of
# scripts/proof-mssql-merge.sh: PGVPRINCIPAL becomes a publisher with its own (local) distributor, the database
# pgvmerge on it is published for merge (pgvm_merge, one table) and pushed to the database pgvmerge_sub on PGVMIRROR,
# its merge agent running continuously. SQL Server on Linux has no merge replication, so its proof needs Windows.
#
# Windows PowerShell 5.1, run as a local administrator of the host (an elevated session) AFTER win-mirroring.ps1 up,
# as the same Windows user (the instances' sysadmin):
#   powershell -NoProfile -ExecutionPolicy Bypass -File win-merge.ps1 -Action up|status|down [-LabDir C:\pgvmirror]
#   up      refused (exit 2, nothing changed) when either lab instance does not answer, or when any of this script's
#           names already exists: a distribution database or a distributor entry on PGVPRINCIPAL, a SQL Server Agent
#           job in a REPL- category there, pgvmerge on PGVPRINCIPAL, pgvmerge_sub on PGVMIRROR, or a right of
#           PGVPRINCIPAL's SQL Server Agent account on its snapshot folder, or this script's feature marker. First
#           SQL Server's Replication feature on both instances (win-mirroring.ps1 installs the engine only, and
#           sp_adddistributor refuses 'Replication components are not installed on this server' without it): each
#           instance where master.sys.sp_MS_replication_installed refuses gets it from the lab's ISO
#           (C:\sqlmedia\SQLServer2022-x64-ENU-Dev.iso, read only: mounted when not attached, its drive letter waited
#           for 30 s at most, dismounted after and on any failure after the mount, its setup.exe's signature Valid,
#           Microsoft; the procedure reads the instance's Replication\IsInstalled registry value through
#           xp_instance_regread and raises 21028 when it is absent, 0 or unread) by setup.exe /QUIET /ACTION=Install /FEATURES=Replication
#           /INSTANCENAME=<it> /IACCEPTSQLSERVERLICENSETERMS /UPDATEENABLED=False, run as SYSTEM through this script's
#           one-shot task (removed on every path); the instance is named in <LabDir>\merge-feature.txt BEFORE setup
#           runs, and the check is read back. Then builds, in Microsoft's documented
#           order (sp_adddistributor, sp_adddistributiondb, sp_adddistpublisher, sp_replicationdboption 'merge
#           publish', sp_addmergepublication, sp_addpublication_snapshot, sp_addmergearticle,
#           sp_startpublication_snapshot, sp_addmergesubscription, sp_addmergepushsubscription_agent with
#           -Continuous), waits for the snapshot and the first synchronization, and proves merge both ways.
#           The snapshot folder: the replication agents run as PGVPRINCIPAL's SQL Server Agent service account (no
#           job login is given; the caller is sysadmin), and SQL Server setup gives that account no right on the
#           instance's ReplData folder (Microsoft's service account page: the engine's account has Full control there,
#           the Agent's does not). up grants the Agent's account Modify on that one folder (icacls, read back) for the
#           snapshot and the first synchronization only, and removes the grant in its finally block (read back,
#           children included) on every exit path. Nothing else on the host is changed by up outside the two
#           instances.
#   status  read only: the publication, the subscription, the merge agent's job and newest session, the rows on
#           both sides, the grant absent; the last line is the VERDICT (exit 1 when not UP).
#   down    the undo, by name only, each step skipped when its object is absent (a read of a replication table that
#           may not exist is an IF OBJECT_ID ... ELSE, never a CASE: Msg 208 at bind time): the lab's replication jobs stopped,
#           sp_dropmergesubscription, sp_mergesubscription_cleanup on the subscriber, sp_dropmergepublication,
#           sp_replicationdboption 'merge publish' false, sp_dropdistpublisher, sp_dropdistributiondb,
#           sp_dropdistributor, the two databases dropped, the grant removed if still there; then, ONLY when every step
#           before it succeeded (a second down needs the replication procedures, and they need the feature), the
#           Replication feature removed from each instance the marker names - by the instance's own Setup Bootstrap
#           setup.exe (win-mirroring.ps1 down's proven way; the ISO only when it is missing) as SYSTEM through the same
#           one-shot task, setup /QUIET /ACTION=Uninstall /FEATURES=Replication /INSTANCENAME=<it> - read back refused,
#           the marker removed; after a failed step the feature and the marker are kept, and said. A one-shot task an
#           earlier run left (a killed run: its finally never ran) is unregistered when it is not running, named when it
#           is. Then every name read back gone: VERDICT CLEAN (exit 0) or VERDICT NOT CLEAN naming what is left (exit 1).
#           win-mirroring.ps1 down uninstalls both instances afterwards whatever this left; a marker left here is an item
#           of LabDir the lab did not make, so that down keeps LabDir and the next win-mirroring.ps1 'before' refuses it
#           (not empty): run this down again until CLEAN while the instances answer, else the marker goes by hand, said.
#
# Secrets: the subscriber connection is SQL Server authentication as sa with the lab's password from
# <LabDir>\secret\sa.pw (win-mirroring.ps1's), passed as a parameter, never in a statement's text and never printed;
# the distributor_admin password is made here from a cryptographic source, used once and never stored (a local
# distributor needs it for nothing after; sp_dropdistributor does not ask for it).
#
# Expected (written before the first run on the host):
#   up      'publisher <host>\PGVPRINCIPAL, subscriber <host>\PGVMIRROR (16.0.1000.6)'; for each instance
#           'replication feature <inst>: absent - setup as SYSTEM (a few minutes)', '... setup /ACTION=Install as SYSTEM
#           exit 0' (or 3010), '... read back: installed' (a few minutes each), the mirroring roles of pgvmirror printed after (a feature setup may restart an engine); the
#           ISO 'dismounted' when this script mounted it; the folder's rights printed
#           ('ReplData before: ...', when it exists); 'distributor: distribution made, working directory <the instance's
#           ReplData>'; 'grant: NT Service\SQLAgent$PGVPRINCIPAL Modify on <ReplData> (read back)'; 'snapshot:
#           succeeded' within 180 s; 'merge agent job <name>: started'; 'pgvmerge_sub: 100 rows, merge triggers in
#           place' within 300 s; 'grant: removed (read back, children included)' (any inherited entry of the Agent
#           below the folder said apart); 'both ways: 120 rows on each side' within 180 s; the status block; 'VERDICT
#           UP', exit 0.
#   status  the publication pgvm_merge (merge, 1 article), the push subscription to pgvmerge_sub, the merge job running
#           and continuous, the newest session's runstatus, 120 / 120 rows, no grant; 'VERDICT UP'.
#   down    'stopped: <job>' for a running lab job; 'dropped: subscription', 'cleanup: subscriber', 'dropped:
#           publication', 'merge publish: off', 'dropped: distpublisher', 'dropped: distribution database',
#           'dropped: distributor', 'dropped: pgvmerge', 'dropped: pgvmerge_sub', 'setup for the removal: <the instance's
#           Setup Bootstrap setup.exe>', for each instance the marker names 'replication feature <inst>: setup
#           /ACTION=Uninstall as SYSTEM exit 0' and '... read back: not installed'; read back: no distribution database, no distributor
#           entry, no REPL- job, no pgvmerge, no pgvmerge_sub, no grant, no marker, no task; 'VERDICT CLEAN', exit 0.
# Exit: 0 done, 1 failed (a VERDICT NOT ... line names what), 2 refused (nothing changed).
[CmdletBinding()]
param(
    [ValidateSet('up', 'status', 'down')] [string]$Action = 'status',
    [string]$LabDir = 'C:\pgvmirror'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2

$pubInst = [pscustomobject]@{ Name = 'PGVPRINCIPAL'; SqlPort = 14331 }
$subInst = [pscustomobject]@{ Name = 'PGVMIRROR'; SqlPort = 14332 }
$pubDb = 'pgvmerge'; $subDb = 'pgvmerge_sub'; $publication = 'pgvm_merge'; $distDb = 'distribution'
$saFile = Join-Path $LabDir 'secret\sa.pw'
$agentAccount = "NT Service\SQLAgent`$$($pubInst.Name)"
$featureMarker = Join-Path $LabDir 'merge-feature.txt'   # the instances whose Replication feature this script added
$isoPath = 'C:\sqlmedia\SQLServer2022-x64-ENU-Dev.iso'     # the lab's ISO (win-mirroring.ps1's), read only
$bootstrapSetup = 'C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\SQL2022\setup.exe'   # the installed setup (down's removal)
$setupTask = 'pgvigil-merge-lab-setup'                   # this script's one-shot task: setup as SYSTEM
$secretDir = Join-Path $LabDir 'secret'                  # win-mirroring.ps1's folder (Administrators and SYSTEM only)

function Say([string]$text) { Write-Host "win-merge: $text" }
function Stop-Refused([string]$why) { Say "REFUSED: $why"; exit 2 }

function Test-Elevated {
    $principalNow = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principalNow.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# one T-SQL batch on a lab instance as the running Windows user over TCP to 127.0.0.1 (the static port); named
# parameters (a hashtable: name without '@' -> value) are passed as SqlParameters, never as text; returns the rows of
# the first result set as objects
function Invoke-LabSql([object]$inst, [string]$query, [string]$database = 'master', [hashtable]$params = @{}, [int]$timeoutSec = 300) {
    $connText = "Server=tcp:127.0.0.1,$($inst.SqlPort);Database=$database;Integrated Security=SSPI;Application Name=win-merge;Connect Timeout=15"
    $conn = New-Object System.Data.SqlClient.SqlConnection $connText
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = $timeoutSec
        foreach ($key in $params.Keys) { $null = $cmd.Parameters.AddWithValue("@$key", $params[$key]) }
        $table = New-Object System.Data.DataTable
        $reader = $cmd.ExecuteReader()
        try { $table.Load($reader) } finally { $reader.Dispose() }
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($dataRow in $table.Rows) {
            $obj = [ordered]@{}
            foreach ($col in $table.Columns) { $obj[$col.ColumnName] = if ($dataRow[$col] -is [DBNull]) { $null } else { $dataRow[$col] } }
            $out.Add([pscustomobject]$obj)
        }
        return , $out.ToArray()
    } finally { $conn.Dispose() }
}

# one value of a one-row, one-column read
function Get-LabValue([object]$inst, [string]$query, [string]$database = 'master') {
    $rows = Invoke-LabSql $inst $query $database
    if ($rows.Count -eq 0) { return $null }
    return @($rows[0].PSObject.Properties)[0].Value
}

# a password of 28 characters from a cryptographic source (letters, digits, '#%+-_': no quote or bracket)
function New-LabPassword {
    $all = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789#%+-_'
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] 28
    $rng.GetBytes($bytes); $rng.Dispose()
    return 'Aa2#' + (-join ($bytes[4..27] | ForEach-Object { $all[$_ % $all.Length] }))
}

# the instance's own snapshot folder: <its SQLPath from the registry>\ReplData (MSSQL16.<name>\MSSQL\ReplData)
function Get-ReplDataPath {
    $instId = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop).($pubInst.Name)
    $sqlPath = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instId\Setup" -ErrorAction Stop).SQLPath
    return (Join-Path $sqlPath 'ReplData')
}

# the Agent account's EXPLICIT entries on the folder and below it (icacls /T lists every child): the grant this script
# makes; none = no grant. An inherited entry ('(I)') is not one: the folder's own inheritable rights (CREATOR OWNER on
# a file the Agent made) can name the account; those are listed apart (Get-InheritedLines) and go with the files.
# Callers wrap the result in @(): a function's array is unrolled, so no match is $null and one match a bare string.
function Get-GrantLines([string]$folder) {
    if (-not (Test-Path -LiteralPath $folder)) { return @() }
    $lines = & icacls.exe $folder /T /C 2>&1
    return @($lines | Where-Object { "$_" -like "*$agentAccount*" -and "$_" -notlike '*(I)*' })
}
function Get-InheritedLines([string]$folder) {
    if (-not (Test-Path -LiteralPath $folder)) { return @() }
    $lines = & icacls.exe $folder /T /C 2>&1
    return @($lines | Where-Object { "$_" -like "*$agentAccount*" -and "$_" -like '*(I)*' })
}

function Remove-Grant([string]$folder) {
    if (-not (Test-Path -LiteralPath $folder)) { return $true }
    $null = & icacls.exe $folder /remove:g $agentAccount /T /C /Q
    $left = @(Get-GrantLines $folder)
    $inherited = @(Get-InheritedLines $folder)
    if ($inherited.Count -gt 0) { Say "grant: $($inherited.Count) inherited entr$(if ($inherited.Count -eq 1) { 'y' } else { 'ies' }) of the Agent account below the folder (the folder's own inheritance, not this script's grant)" }
    if ($left.Count -gt 0) { Say "grant: NOT removed: $($left.Count) explicit entr$(if ($left.Count -eq 1) { 'y' } else { 'ies' }) left"; return $false }
    Say 'grant: removed (read back, children included)'
    return $true
}

# SQL Server's Replication feature on an instance: master.sys.sp_MS_replication_installed refuses (error 21028,
# 'Replication components are not installed on this server') when it is absent - the refusal sp_adddistributor gives
function Test-ReplicationInstalled([object]$inst) {
    try { $null = Invoke-LabSql $inst 'EXEC master.sys.sp_MS_replication_installed;'; return $true }
    catch { if ($_.Exception.Message -match 'Replication components are not installed') { return $false }; throw }
}
function Get-MarkedInstances {
    if (-not (Test-Path -LiteralPath $featureMarker)) { return @() }
    return @(Get-Content -LiteralPath $featureMarker -ErrorAction Stop | Where-Object { $_ -in @($pubInst.Name, $subInst.Name) })
}

# setup.exe <arguments> as SYSTEM through this script's one-shot task (setup under the ssh door's key-based logon fails:
# ProtectedData 'Access is denied'); returns setup's exit code. The task's .cmd and exit file live in the lab's secret
# folder; the task, the .cmd and the exit file are removed on every path; a task of this name still running = refused.
function Invoke-SetupAsSystem([string]$setupExe, [string]$arguments, [int]$timeoutMin = 30) {
    $earlier = Get-ScheduledTask -TaskName $setupTask -ErrorAction SilentlyContinue
    if ($earlier -and [string]$earlier.State -eq 'Running') { throw "setup as SYSTEM from an earlier run is still running (task '$setupTask')" }
    if (-not (Test-Path -LiteralPath $secretDir)) { throw "no $secretDir (win-mirroring.ps1 up makes it)" }
    $wrapper = Join-Path $secretDir 'merge-setup-run.cmd'
    $exitFile = Join-Path $secretDir 'merge-setup-run.exit'
    if (Test-Path -LiteralPath $exitFile) { Remove-Item -LiteralPath $exitFile -Force -ErrorAction Stop }
    # the redirection first: 'echo 0> file' would redirect handle 0 and leave the file empty
    Set-Content -LiteralPath $wrapper -Encoding ASCII -Value @("@echo off", "`"$setupExe`" $arguments", "> `"$exitFile`" echo %ERRORLEVEL%")
    $taskAction = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$wrapper`""
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes ($timeoutMin + 10)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    try {
        Register-ScheduledTask -TaskName $setupTask -Action $taskAction -Principal $taskPrincipal -Settings $taskSettings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $setupTask -ErrorAction Stop
        $started = Get-Date; $deadline = $started.AddMinutes($timeoutMin)
        while (-not (Test-Path -LiteralPath $exitFile)) {
            $state = [string](Get-ScheduledTask -TaskName $setupTask -ErrorAction Stop).State
            if ($state -eq 'Ready' -and ((Get-Date) - $started).TotalSeconds -gt 30) {
                Start-Sleep -Seconds 2
                if (Test-Path -LiteralPath $exitFile) { break }
                throw "setup as SYSTEM ended with no exit code (task state $state, last result $((Get-ScheduledTaskInfo -TaskName $setupTask).LastTaskResult))"
            }
            if ((Get-Date) -gt $deadline) {
                Stop-ScheduledTask -TaskName $setupTask -ErrorAction SilentlyContinue
                # Stop-ScheduledTask's page does not say it ends the action's children: any setup.exe left is named
                $left = @(Get-CimInstance Win32_Process -Filter "Name = 'setup.exe'" -ErrorAction SilentlyContinue | ForEach-Object { "$($_.ProcessId) $($_.ExecutablePath)" })
                throw "setup as SYSTEM wrote no exit code in $timeoutMin minutes; the task was stopped; setup processes still running: $(if ($left.Count) { $left -join ', ' } else { 'none' })"
            }
            Start-Sleep -Seconds 10
        }
        Start-Sleep -Seconds 2
        $codeText = [string](Get-Content -LiteralPath $exitFile -Raw -ErrorAction Stop)
        if ($codeText.Trim() -notmatch '^-?[0-9]+$') { throw "setup as SYSTEM left no exit code ('$($codeText.Trim())')" }
        return [int]$codeText.Trim()
    } finally {
        if (Get-ScheduledTask -TaskName $setupTask -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $setupTask -Confirm:$false -ErrorAction SilentlyContinue }
        foreach ($leftover in @($wrapper, $exitFile)) { if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Force -ErrorAction SilentlyContinue } }
    }
}

# the lab's ISO mounted (when it is not already) and its setup.exe checked; returns @(setup path, whether this mounted it)
function Get-SetupFromIso {
    if (-not (Test-Path -LiteralPath $isoPath)) { throw "no $isoPath (the lab's ISO)" }
    $image = Get-DiskImage -ImagePath $isoPath -ErrorAction Stop
    $mountedHere = $false
    if (-not $image.Attached) { $null = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop; $mountedHere = $true; Say "mounted $isoPath" }
    try {
        # the letter may come a moment after Mount-DiskImage returns: 30 s at most. No volume yet, a null or a [char]0
        # letter all mean 'not yet' (StrictMode 2: a property of nothing throws, so the volume is counted first)
        $drive = $null
        $deadline = (Get-Date).AddSeconds(30)
        while (-not $drive -and (Get-Date) -lt $deadline) {
            $vol = @(Get-Volume -DiskImage (Get-DiskImage -ImagePath $isoPath -ErrorAction Stop) -ErrorAction SilentlyContinue)
            if ($vol.Count -gt 0) { $letterText = ([string]$vol[0].DriveLetter).Trim([char]0).Trim(); if ($letterText -match '^[A-Za-z]$') { $drive = $letterText } }
            if (-not $drive) { Start-Sleep -Seconds 2 }
        }
        if (-not $drive) { throw "the mounted ISO $isoPath has no drive letter after 30 s" }
        $setupExe = "${drive}:\setup.exe"
        if (-not (Test-Path -LiteralPath $setupExe)) { throw "no setup.exe on the mounted ISO ($setupExe)" }
        $exeSig = Get-AuthenticodeSignature -FilePath $setupExe -ErrorAction Stop
        $signer = if ($exeSig.SignerCertificate) { $exeSig.SignerCertificate.Subject } else { 'no signer' }
        if ($exeSig.Status -ne 'Valid' -or $signer -notmatch 'O=Microsoft Corporation') { throw "setup.exe's signature is $($exeSig.Status) ($signer): not run" }
        return @($setupExe, $mountedHere)
    } catch {
        # any failure after this script's own mount leaves the ISO as it found it
        if ($mountedHere) { Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null; Say "dismounted $isoPath" }
        throw
    }
}

# the Replication feature added (op 'Install') or removed (op 'Uninstall') on one instance, read back
function Set-ReplicationFeature([object]$inst, [string]$op, [string]$setupExe) {
    $want = ($op -eq 'Install')
    # the license flag only on Install (Microsoft's Uninstall parameter table has none; win-mirroring.ps1's proven
    # uninstall passes none)
    $code = Invoke-SetupAsSystem $setupExe "/QUIET /ACTION=$op /FEATURES=Replication /INSTANCENAME=$($inst.Name)$(if ($want) { ' /IACCEPTSQLSERVERLICENSETERMS /UPDATEENABLED=False' })"
    # the code said first: a read-back that throws (an engine still starting) never hides it
    Say "replication feature $($inst.Name): setup /ACTION=$op as SYSTEM exit $code"
    $now = Test-ReplicationInstalled $inst
    Say "replication feature $($inst.Name): read back: $(if ($now) { 'installed' } else { 'not installed' })"
    if ($code -notin 0, 3010) { throw "setup /ACTION=$op /FEATURES=Replication on $($inst.Name) exit $code" }
    if ($now -ne $want) { throw "the Replication feature on $($inst.Name) reads $(if ($now) { 'installed' } else { 'not installed' }) after setup /ACTION=$op" }
}

# the names this script makes, as found now (each a count; 0 = absent)
function Get-LabNames {
    return [pscustomobject]@{
        DistDb      = [int](Get-LabValue $pubInst "SELECT COUNT(*) FROM sys.databases WHERE is_distributor = 1 OR name = N'$distDb'")
        Distributor = [int](Get-LabValue $pubInst 'SELECT COUNT(*) FROM sys.servers WHERE is_distributor = 1')
        ReplJobs    = [int](Get-LabValue $pubInst "SELECT COUNT(*) FROM msdb.dbo.sysjobs j JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id WHERE c.name LIKE N'REPL-%'")
        PubDb       = [int](Get-LabValue $pubInst "SELECT COUNT(*) FROM sys.databases WHERE name = N'$pubDb'")
        SubDb       = [int](Get-LabValue $subInst "SELECT COUNT(*) FROM sys.databases WHERE name = N'$subDb'")
    }
}

# the merge agent of the lab's subscription and its job (distribution database on the publisher)
function Get-MergeAgent {
    $rows = Invoke-LabSql $pubInst "SELECT CAST(a.name AS nvarchar(200)) AS agent, CAST(j.name AS nvarchar(200)) AS job FROM dbo.MSmerge_agents a LEFT JOIN msdb.dbo.sysjobs j ON j.job_id = CAST(a.job_id AS uniqueidentifier) WHERE a.publication = N'$publication'" $distDb
    if ($rows.Count -eq 0) { return $null }
    return $rows[0]
}

# the table's rows, -1 while it does not exist (an IF: a CASE over a missing table fails at bind time, Msg 208)
function Get-RowCount([object]$inst, [string]$database) {
    return [int](Get-LabValue $inst "IF OBJECT_ID(N'dbo.t_merge') IS NULL SELECT -1 AS n ELSE SELECT COUNT(*) AS n FROM dbo.t_merge;" $database)
}
# the merge triggers the agent puts on the subscriber's table after its bulk load (rows written before them are not tracked)
function Get-MergeTriggers {
    return [int](Get-LabValue $subInst "SELECT COUNT(*) FROM sys.triggers WHERE parent_id = OBJECT_ID(N'dbo.t_merge') AND name LIKE N'MSmerge[_]ins%'" $subDb)
}

# wait until the block returns true, at most $seconds; returns whether it did
function Wait-Until([int]$seconds, [scriptblock]$test) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $test) { return $true }
        Start-Sleep -Seconds 5
    }
    return [bool](& $test)
}

function Invoke-Status {
    $problems = New-Object System.Collections.Generic.List[string]
    try {
        $pubRow = Invoke-LabSql $pubInst "SELECT CAST(p.name AS nvarchar(128)) AS name, (SELECT COUNT(*) FROM dbo.sysmergearticles a WHERE a.pubid = p.pubid) AS articles FROM dbo.sysmergepublications p WHERE p.name = N'$publication'" $pubDb
        if ($pubRow.Count -eq 0) { $problems.Add('no publication') } else { Say "status: publication $($pubRow[0].name), merge, $($pubRow[0].articles) article(s)" }
        $agentRow = Get-MergeAgent
        if ($null -eq $agentRow) { $problems.Add('no merge agent') }
        else {
            $jobState = Get-LabValue $pubInst "SELECT TOP (1) CASE WHEN a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL THEN 'running' ELSE 'not running' END FROM msdb.dbo.sysjobactivity a JOIN msdb.dbo.sysjobs j ON j.job_id = a.job_id WHERE j.name = N'$($agentRow.job)' ORDER BY a.session_id DESC"
            $continuous = Get-LabValue $pubInst "SELECT COUNT(*) FROM msdb.dbo.sysjobsteps s JOIN msdb.dbo.sysjobs j ON j.job_id = s.job_id WHERE j.name = N'$($agentRow.job)' AND s.subsystem = N'Merge' AND s.command LIKE N'%-Continuous%'"
            $session = Invoke-LabSql $pubInst "SELECT TOP (1) x.session_id, x.runstatus, CONVERT(varchar(23), x.start_time, 126) AS started, CONVERT(varchar(23), x.end_time, 126) AS ended FROM dbo.MSmerge_sessions x JOIN dbo.MSmerge_agents a ON a.id = x.agent_id WHERE a.publication = N'$publication' ORDER BY x.session_id DESC" $distDb
            $sessionText = if ($session.Count -gt 0) { "session $($session[0].session_id) runstatus $($session[0].runstatus) ($($session[0].started) - $($session[0].ended))" } else { 'no session' }
            Say "status: merge agent $($agentRow.agent), job '$($agentRow.job)' $jobState, continuous $([int]$continuous -gt 0), $sessionText"
            if ($jobState -ne 'running') { $problems.Add("merge job $jobState") }
            if ([int]$continuous -eq 0) { $problems.Add('merge job not continuous') }
        }
        $pubRows = Get-RowCount $pubInst $pubDb; $subRows = Get-RowCount $subInst $subDb
        Say "status: rows $pubDb $pubRows, $subDb $subRows"
        if ($pubRows -ne $subRows -or $pubRows -lt 100) { $problems.Add("rows $pubRows / $subRows") }
        $grantLeft = @(Get-GrantLines (Get-ReplDataPath))
        if ($grantLeft.Count -gt 0) { $problems.Add('the snapshot folder grant is still there') }
    } catch { $problems.Add("unread: $($_.Exception.Message)") }
    if ($problems.Count -eq 0) { Say 'VERDICT UP'; return $true }
    Say "VERDICT NOT UP: $($problems -join '; ')"
    return $false
}

function Invoke-Up {
    if (-not (Test-Path -LiteralPath $saFile)) { Stop-Refused "no $saFile (win-mirroring.ps1 up first)" }
    try {
        $pubName = Get-LabValue $pubInst 'SELECT CAST(@@SERVERNAME AS nvarchar(256))'
        $subName = Get-LabValue $subInst 'SELECT CAST(@@SERVERNAME AS nvarchar(256))'
        $version = Get-LabValue $pubInst "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(40))"
    } catch { Stop-Refused "a lab instance does not answer: $($_.Exception.Message)" }
    try {
        $names = Get-LabNames
        $agentActual = Get-LabValue $pubInst "SELECT CAST(service_account AS nvarchar(256)) FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server Agent%'"
        $replData = Get-ReplDataPath
        $grantBefore = @(Get-GrantLines $replData)
    } catch { Stop-Refused "a read before any change failed: $($_.Exception.Message)" }
    $taken = @($names.PSObject.Properties | Where-Object { $_.Value -gt 0 } | ForEach-Object { $_.Name })
    if ($taken.Count -gt 0) { Stop-Refused "already present: $($taken -join ', ') (down first)" }
    if ($agentActual -ne $agentAccount) { Stop-Refused "the Agent service account is '$agentActual', not '$agentAccount'" }
    if ($grantBefore.Count -gt 0) { Stop-Refused "$agentAccount already has an explicit right on $replData" }
    if (Test-Path -LiteralPath $featureMarker) { Stop-Refused "$featureMarker exists (an earlier run's: down first)" }
    Say "publisher $pubName, subscriber $subName ($version)"
    if (Test-Path -LiteralPath $replData) { foreach ($aclLine in @(& icacls.exe $replData 2>&1)) { if ("$aclLine".Trim()) { Say "ReplData before: $("$aclLine".Trim())" } } }

    $sapw = (Get-Content -LiteralPath $saFile -Raw -ErrorAction Stop).Trim()
    $made = $false
    try {
        # SQL Server's Replication feature on both instances, from the lab's ISO, the instance named in the marker first
        $missing = @(@($pubInst, $subInst) | Where-Object { -not (Test-ReplicationInstalled $_) })
        foreach ($inst in @($pubInst, $subInst)) { if ($inst -notin $missing) { Say "replication feature $($inst.Name): installed already (not this script's: left as it is)" } }
        if ($missing.Count -gt 0) {
            $media = Get-SetupFromIso
            try {
                foreach ($inst in $missing) {
                    Add-Content -LiteralPath $featureMarker -Value $inst.Name -ErrorAction Stop
                    Say "replication feature $($inst.Name): absent - setup as SYSTEM (a few minutes)"
                    Set-ReplicationFeature $inst 'Install' $media[0]
                }
            } finally { if ($media[1]) { Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null; Say "dismounted $isoPath" } }
            # a feature setup may restart an engine (an automatic failover of the mirroring lab): the roles, read only
            foreach ($inst in @($pubInst, $subInst)) {
                $roleRow = Invoke-LabSql $inst "SELECT CAST(d.name AS nvarchar(128)) AS db, CAST(m.mirroring_role_desc AS nvarchar(60)) AS role, CAST(m.mirroring_state_desc AS nvarchar(60)) AS state FROM sys.database_mirroring m JOIN sys.databases d ON d.database_id = m.database_id WHERE m.mirroring_guid IS NOT NULL"
                foreach ($roleLine in $roleRow) { Say "mirroring on $($inst.Name) after the feature: $($roleLine.db) $($roleLine.role) $($roleLine.state)" }
            }
        }
        Invoke-LabSql $pubInst "EXEC sp_adddistributor @distributor = @@SERVERNAME, @password = @pw;" 'master' @{ pw = (New-LabPassword) } | Out-Null
        Invoke-LabSql $pubInst "EXEC sp_adddistributiondb @database = N'$distDb', @security_mode = 1;" | Out-Null
        Invoke-LabSql $pubInst "EXEC sp_adddistpublisher @publisher = @@SERVERNAME, @distribution_db = N'$distDb', @security_mode = 1, @trusted = N'false', @thirdparty_flag = 0, @publisher_type = N'MSSQLSERVER';" | Out-Null
        $workDir = Get-LabValue $pubInst 'SELECT CAST(working_directory AS nvarchar(512)) FROM msdb.dbo.MSdistpublishers WHERE name = @@SERVERNAME'
        Say "distributor: $distDb made, working directory $workDir"
        if ($workDir.TrimEnd('\') -ne $replData.TrimEnd('\')) { throw "the working directory '$workDir' is not the instance's own ReplData '$replData'" }
        if (-not (Test-Path -LiteralPath $replData)) { New-Item -ItemType Directory -Path $replData -Force | Out-Null; Say "folder: $replData made (inside the instance's own folder)" }
        $made = $true
        $null = & icacls.exe $replData /grant "${agentAccount}:(OI)(CI)M" /Q
        if ($LASTEXITCODE -ne 0) { throw "icacls could not grant $agentAccount on $replData (exit $LASTEXITCODE)" }
        if (@(Get-GrantLines $replData).Count -eq 0) { throw "the grant on $replData is not read back" }
        Say "grant: $agentAccount Modify on $replData (read back)"

        Invoke-LabSql $subInst "CREATE DATABASE [$subDb];" | Out-Null
        Invoke-LabSql $pubInst "CREATE DATABASE [$pubDb];" | Out-Null
        Invoke-LabSql $pubInst "CREATE TABLE dbo.t_merge (id int NOT NULL PRIMARY KEY, v nvarchar(200) NOT NULL); INSERT dbo.t_merge (id, v) SELECT TOP (100) ROW_NUMBER() OVER (ORDER BY (SELECT 0)), N'seed' FROM sys.all_objects;" $pubDb | Out-Null
        Invoke-LabSql $pubInst "EXEC sp_replicationdboption @dbname = N'$pubDb', @optname = N'merge publish', @value = N'true';" | Out-Null
        Invoke-LabSql $pubInst "EXEC sp_addmergepublication @publication = N'$publication', @description = N'pgvigil merge lab', @retention = 14, @allow_push = N'true', @allow_pull = N'false', @allow_anonymous = N'false';" $pubDb | Out-Null
        Invoke-LabSql $pubInst "EXEC sp_addpublication_snapshot @publication = N'$publication', @frequency_type = 1, @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;" $pubDb | Out-Null
        Invoke-LabSql $pubInst "EXEC sp_addmergearticle @publication = N'$publication', @article = N't_merge', @source_owner = N'dbo', @source_object = N't_merge';" $pubDb | Out-Null
        Invoke-LabSql $pubInst "EXEC sp_startpublication_snapshot @publication = N'$publication';" $pubDb | Out-Null
        $snapOk = Wait-Until 180 { [string](Get-LabValue $pubInst "SELECT TOP (1) h.runstatus FROM dbo.MSsnapshot_agents a JOIN dbo.MSsnapshot_history h ON h.agent_id = a.id WHERE a.publication = N'$publication' ORDER BY h.time DESC, h.timestamp DESC" $distDb) -eq '2' }
        if (-not $snapOk) {
            $snapText = Invoke-LabSql $pubInst "SELECT TOP (3) h.runstatus, CAST(LEFT(h.comments, 400) AS nvarchar(400)) AS comments FROM dbo.MSsnapshot_agents a JOIN dbo.MSsnapshot_history h ON h.agent_id = a.id WHERE a.publication = N'$publication' ORDER BY h.time DESC, h.timestamp DESC" $distDb
            foreach ($snapRow in $snapText) { Say "snapshot history: $($snapRow.runstatus) $($snapRow.comments)" }
            throw 'the snapshot did not succeed in 180 s'
        }
        Say 'snapshot: succeeded'
        Invoke-LabSql $pubInst "EXEC sp_addmergesubscription @publication = N'$publication', @subscriber = @sub, @subscriber_db = N'$subDb', @subscription_type = N'push';" $pubDb @{ sub = $subName } | Out-Null
        Invoke-LabSql $pubInst "EXEC sp_addmergepushsubscription_agent @publication = N'$publication', @subscriber = @sub, @subscriber_db = N'$subDb', @subscriber_security_mode = 0, @subscriber_login = N'sa', @subscriber_password = @pw, @publisher_security_mode = 1, @job_login = NULL, @job_password = NULL, @frequency_type = 64;" $pubDb @{ sub = $subName; pw = $sapw } | Out-Null
        $agentRow = Get-MergeAgent
        if ($null -eq $agentRow -or -not $agentRow.job) { throw 'no merge agent job was made' }
        Invoke-LabSql $pubInst 'EXEC msdb.dbo.sp_start_job @job_name = @job;' 'master' @{ job = $agentRow.job } | Out-Null
        Say "merge agent job $($agentRow.job): started"
        if (-not (Wait-Until 300 { (Get-RowCount $subInst $subDb) -eq 100 -and (Get-MergeTriggers) -ge 1 })) {
            $mergeText = Invoke-LabSql $pubInst "SELECT TOP (5) x.runstatus, CAST(LEFT(y.comments, 400) AS nvarchar(400)) AS comments FROM dbo.MSmerge_agents a JOIN dbo.MSmerge_sessions x ON x.agent_id = a.id LEFT JOIN dbo.MSmerge_history y ON y.agent_id = a.id AND y.session_id = x.session_id WHERE a.publication = N'$publication' ORDER BY x.session_id DESC, y.timestamp DESC" $distDb
            foreach ($mergeRow in $mergeText) { Say "merge history: $($mergeRow.runstatus) $($mergeRow.comments)" }
            throw "$subDb did not reach 100 rows with its merge triggers in 300 s ($(Get-RowCount $subInst $subDb) rows, $(Get-MergeTriggers) trigger(s))"
        }
        Say "${subDb}: 100 rows, merge triggers in place"
        # the grant was for the snapshot and its first apply only: removed now (the finally stays the failure path's)
        $made = $false
        if (-not (Remove-Grant $replData)) { Say 'VERDICT NOT UP: the snapshot folder grant is still there'; exit 1 }
        Invoke-LabSql $pubInst "INSERT dbo.t_merge (id, v) SELECT 1000 + n, N'from the publisher' FROM (SELECT TOP (10) ROW_NUMBER() OVER (ORDER BY (SELECT 0)) AS n FROM sys.all_objects) x;" $pubDb | Out-Null
        Invoke-LabSql $subInst "INSERT dbo.t_merge (id, v) SELECT 2000 + n, N'from the subscriber' FROM (SELECT TOP (10) ROW_NUMBER() OVER (ORDER BY (SELECT 0)) AS n FROM sys.all_objects) x;" $subDb | Out-Null
        if (-not (Wait-Until 180 { (Get-RowCount $pubInst $pubDb) -eq 120 -and (Get-RowCount $subInst $subDb) -eq 120 })) {
            throw "merge did not carry the 20 new rows both ways in 180 s ($(Get-RowCount $pubInst $pubDb) / $(Get-RowCount $subInst $subDb))"
        }
        Say 'both ways: 120 rows on each side'
    } catch {
        Say "FAILED: $($_.Exception.Message)"
        Say 'VERDICT NOT UP (the objects made so far stay for reading; down removes them)'
        exit 1
    } finally {
        $sapw = $null
        if ($made) {
            $removed = Remove-Grant $replData
            if (-not $removed) { Say 'VERDICT NOT UP: the snapshot folder grant is still there'; exit 1 }
        }
    }
    if (Invoke-Status) { exit 0 }
    exit 1
}

function Invoke-Down {
    $failures = New-Object System.Collections.Generic.List[string]
    $pubName = $null; $subName = $null
    try { $pubName = Get-LabValue $pubInst 'SELECT CAST(@@SERVERNAME AS nvarchar(256))' } catch { Say "FAILED: $($pubInst.Name) does not answer: $($_.Exception.Message)"; $failures.Add("$($pubInst.Name) does not answer") }
    try { $subName = Get-LabValue $subInst 'SELECT CAST(@@SERVERNAME AS nvarchar(256))' } catch { Say "FAILED: $($subInst.Name) does not answer: $($_.Exception.Message)"; $failures.Add("$($subInst.Name) does not answer") }
    # each step: run when its object is there, report, go on (one failed step never keeps the others from running)
    function Step([string]$label, [scriptblock]$body) {
        try { & $body; Say $label } catch { Say "FAILED $label`: $($_.Exception.Message)"; $failures.Add($label) }
    }
    $hasDist = $false; $hasPubDb = $false; $hasSubDb = $false
    try { $hasDist = [int](Get-LabValue $pubInst "SELECT COUNT(*) FROM sys.databases WHERE name = N'$distDb' AND is_distributor = 1") -gt 0
          $hasPubDb = [int](Get-LabValue $pubInst "SELECT COUNT(*) FROM sys.databases WHERE name = N'$pubDb'") -gt 0 } catch { Say "FAILED read of $($pubInst.Name): $($_.Exception.Message)"; $failures.Add("$($pubInst.Name) unread") }
    try { $hasSubDb = [int](Get-LabValue $subInst "SELECT COUNT(*) FROM sys.databases WHERE name = N'$subDb'") -gt 0 } catch { Say "FAILED read of $($subInst.Name): $($_.Exception.Message)"; $failures.Add("$($subInst.Name) unread") }
    $runningSql = "SELECT CAST(j.name AS nvarchar(200)) AS job FROM msdb.dbo.sysjobs j WHERE j.job_id IN (SELECT CAST(job_id AS uniqueidentifier) FROM [$distDb].dbo.MSmerge_agents WHERE publication = N'$publication' UNION SELECT CAST(job_id AS uniqueidentifier) FROM [$distDb].dbo.MSsnapshot_agents WHERE publication = N'$publication') AND EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity a WHERE a.job_id = j.job_id AND a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL)"
    if ($hasDist) {
        $jobs = @()
        try { $jobs = Invoke-LabSql $pubInst $runningSql } catch { Say "FAILED read of the running jobs: $($_.Exception.Message)"; $failures.Add('jobs unread') }
        foreach ($jobRow in $jobs) { Step "stopped: $($jobRow.job)" { Invoke-LabSql $pubInst 'EXEC msdb.dbo.sp_stop_job @job_name = @job;' 'master' @{ job = $jobRow.job } | Out-Null } }
        # sp_stop_job only asks: the agents may hold the distribution database for seconds (60 s at most). Invoke-LabSql
        # returns its rows as ONE array object: @() around the call would nest it (Count 1 always), so the call is bare
        if ($jobs.Count -gt 0 -and -not (Wait-Until 60 { (Invoke-LabSql $pubInst $runningSql).Count -eq 0 })) { Say 'a lab job still runs 60 s after its stop'; $failures.Add('a job did not stop') }
    }
    if ($hasPubDb -and [int](Get-LabValue $pubInst "IF OBJECT_ID(N'dbo.sysmergepublications') IS NULL SELECT 0 AS n ELSE SELECT COUNT(*) AS n FROM dbo.sysmergepublications WHERE name = N'$publication';" $pubDb) -gt 0) {
        if ([int](Get-LabValue $pubInst "SELECT COUNT(*) FROM dbo.sysmergesubscriptions s JOIN dbo.sysmergepublications p ON p.pubid = s.pubid WHERE p.name = N'$publication' AND s.db_name = N'$subDb'" $pubDb) -gt 0) {
            Step 'dropped: subscription' { Invoke-LabSql $pubInst "EXEC sp_dropmergesubscription @publication = N'$publication', @subscriber = @sub, @subscriber_db = N'$subDb', @subscription_type = N'push';" $pubDb @{ sub = $subName } | Out-Null }
        }
        if ($hasSubDb) { Step 'cleanup: subscriber' { Invoke-LabSql $subInst "EXEC sp_mergesubscription_cleanup @publisher = @pub, @publisher_db = N'$pubDb', @publication = N'$publication';" $subDb @{ pub = $pubName } | Out-Null } }
        Step 'dropped: publication' { Invoke-LabSql $pubInst "EXEC sp_dropmergepublication @publication = N'$publication';" $pubDb | Out-Null }
    }
    if ($hasPubDb -and [int](Get-LabValue $pubInst "SELECT CAST(is_merge_published AS int) FROM sys.databases WHERE name = N'$pubDb'") -eq 1) {
        Step 'merge publish: off' { Invoke-LabSql $pubInst "EXEC sp_replicationdboption @dbname = N'$pubDb', @optname = N'merge publish', @value = N'false';" | Out-Null }
    }
    if ([int](Get-LabValue $pubInst "IF OBJECT_ID(N'msdb.dbo.MSdistpublishers') IS NULL SELECT 0 AS n ELSE SELECT COUNT(*) AS n FROM msdb.dbo.MSdistpublishers WHERE name = @@SERVERNAME;") -gt 0) {
        Step 'dropped: distpublisher' { Invoke-LabSql $pubInst 'EXEC sp_dropdistpublisher @publisher = @@SERVERNAME;' | Out-Null }
    }
    if ($hasDist) { Step 'dropped: distribution database' { Invoke-LabSql $pubInst "EXEC sp_dropdistributiondb @database = N'$distDb';" | Out-Null } }
    if ([int](Get-LabValue $pubInst 'SELECT COUNT(*) FROM sys.servers WHERE is_distributor = 1') -gt 0) {
        Step 'dropped: distributor' { Invoke-LabSql $pubInst 'EXEC sp_dropdistributor;' | Out-Null }
    }
    if ($hasPubDb) { Step "dropped: $pubDb" { Invoke-LabSql $pubInst "ALTER DATABASE [$pubDb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$pubDb];" | Out-Null } }
    if ($hasSubDb) { Step "dropped: $subDb" { Invoke-LabSql $subInst "ALTER DATABASE [$subDb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$subDb];" | Out-Null } }
    $replData = Get-ReplDataPath
    if (@(Get-GrantLines $replData).Count -gt 0) { if (-not (Remove-Grant $replData)) { $failures.Add('the grant') } }
    # the Replication feature this script added (the marker's instances only), the same ISO and task, read back
    $marked = @()
    try { $marked = @(Get-MarkedInstances) } catch { Say "FAILED read of $featureMarker`: $($_.Exception.Message)"; $failures.Add('marker unread') }
    $toRemove = @(@($pubInst, $subInst) | Where-Object { $_.Name -in $marked })
    if ($toRemove.Count -gt 0 -and $failures.Count -gt 0) {
        # a second down needs the replication procedures, and they need the feature (21028): kept until the rest is gone
        Say "replication feature kept on $(@($toRemove | ForEach-Object { $_.Name }) -join ', ') and the marker kept: an earlier step failed ($($failures -join '; '))"
        $failures.Add('replication feature kept (an earlier step failed)')
    } elseif ($toRemove.Count -gt 0) {
        try {
            # the instance's own setup (win-mirroring.ps1 down's proven uninstall: no mount); the ISO only when it is missing
            if (Test-Path -LiteralPath $bootstrapSetup) { $media = @($bootstrapSetup, $false); Say "setup for the removal: $bootstrapSetup" }
            else { $media = Get-SetupFromIso; Say "setup for the removal: $($media[0]) (no $bootstrapSetup)" }
            try {
                foreach ($inst in $toRemove) {
                    if (Test-ReplicationInstalled $inst) { Set-ReplicationFeature $inst 'Uninstall' $media[0] }
                    else { Say "replication feature $($inst.Name): not installed already" }
                }
            } finally { if ($media[1]) { Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null; Say "dismounted $isoPath" } }
            Remove-Item -LiteralPath $featureMarker -Force -ErrorAction Stop
        } catch { Say "FAILED replication feature removal: $($_.Exception.Message)"; $failures.Add('replication feature') }
    } elseif (Test-Path -LiteralPath $featureMarker) { Remove-Item -LiteralPath $featureMarker -Force -ErrorAction SilentlyContinue }
    # a one-shot task an earlier run left (a run killed during setup: its finally never ran) - removed when it is not
    # running, with its .cmd and exit file; a running one is named and left (its setup may still be at work)
    $leftTask = Get-ScheduledTask -TaskName $setupTask -ErrorAction SilentlyContinue
    if ($leftTask) {
        if ([string]$leftTask.State -eq 'Running') { Say "task $setupTask is still running (an earlier run's setup): left"; $failures.Add("task $setupTask running") }
        else {
            Step "removed: task $setupTask (an earlier run's)" {
                Unregister-ScheduledTask -TaskName $setupTask -Confirm:$false -ErrorAction Stop
                foreach ($leftover in @((Join-Path $secretDir 'merge-setup-run.cmd'), (Join-Path $secretDir 'merge-setup-run.exit'))) { if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Force -ErrorAction Stop } }
            }
        }
    }
    # read back every name
    try {
        $names = Get-LabNames
        foreach ($prop in $names.PSObject.Properties) { if ($prop.Value -gt 0) { $failures.Add("$($prop.Name) left ($($prop.Value))") } }
        $grantLeft = @(Get-GrantLines $replData).Count
        if ($grantLeft -gt 0) { $failures.Add('grant left') }
        $markerLeft = [int](Test-Path -LiteralPath $featureMarker); $taskLeft = @(Get-ScheduledTask -TaskName $setupTask -ErrorAction SilentlyContinue).Count
        $featureLeft = @(@($pubInst, $subInst) | Where-Object { $_.Name -in $marked -and (Test-ReplicationInstalled $_) }).Count
        if ($markerLeft -gt 0) { $failures.Add('marker left') }; if ($taskLeft -gt 0) { $failures.Add("task $setupTask left") }; if ($featureLeft -gt 0) { $failures.Add("replication feature left on $featureLeft") }
        Say "read back: distribution database $($names.DistDb), distributor entry $($names.Distributor), REPL- jobs $($names.ReplJobs), $pubDb $($names.PubDb), $subDb $($names.SubDb), explicit grant entries $grantLeft, feature marker $markerLeft, setup task $taskLeft, replication feature this script added $featureLeft"
    } catch { Say "FAILED read back: $($_.Exception.Message)"; $failures.Add('read back failed') }
    if ($failures.Count -eq 0) { Say 'VERDICT CLEAN'; exit 0 }
    Say "VERDICT NOT CLEAN: $($failures -join '; ')"
    exit 1
}

if (-not (Test-Elevated)) { Stop-Refused 'run in an elevated session (a local administrator)' }
switch ($Action) {
    'up' { Invoke-Up }
    'status' { if (Invoke-Status) { exit 0 } else { exit 1 } }
    'down' { Invoke-Down }
}
