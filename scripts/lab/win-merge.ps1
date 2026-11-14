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
#           PGVPRINCIPAL's SQL Server Agent account on its snapshot folder. Then builds, in Microsoft's documented
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
#   down    the undo, by name only, each step skipped when its object is absent: the lab's replication jobs stopped,
#           sp_dropmergesubscription, sp_mergesubscription_cleanup on the subscriber, sp_dropmergepublication,
#           sp_replicationdboption 'merge publish' false, sp_dropdistpublisher, sp_dropdistributiondb,
#           sp_dropdistributor, the two databases dropped, the grant removed if still there; then every name read
#           back gone: VERDICT CLEAN (exit 0) or VERDICT NOT CLEAN naming what is left (exit 1). win-mirroring.ps1 down
#           uninstalls both instances afterwards whatever this left.
#
# Secrets: the subscriber connection is SQL Server authentication as sa with the lab's password from
# <LabDir>\secret\sa.pw (win-mirroring.ps1's), passed as a parameter, never in a statement's text and never printed;
# the distributor_admin password is made here from a cryptographic source, used once and never stored (a local
# distributor needs it for nothing after; sp_dropdistributor does not ask for it).
#
# Expected (written before the first run on the host):
#   up      'publisher <host>\PGVPRINCIPAL, subscriber <host>\PGVMIRROR (16.0.1000.6)'; 'distributor: distribution
#           made, working directory <the instance's ReplData>'; 'grant: NT Service\SQLAgent$PGVPRINCIPAL Modify on
#           <ReplData> (read back)'; 'snapshot: succeeded' within 180 s; 'merge agent job <name>: started';
#           'pgvmerge_sub: 100 rows' within 300 s; 'both ways: 120 rows on each side' within 180 s; 'grant: removed
#           (read back, children included)'; the status block; 'VERDICT UP', exit 0.
#   status  the publication pgvm_merge (merge, 1 article), the push subscription to pgvmerge_sub, the merge job running
#           and continuous, the newest session's runstatus, 120 / 120 rows, no grant; 'VERDICT UP'.
#   down    'stopped: <job>' for a running lab job; 'dropped: subscription', 'cleanup: subscriber', 'dropped:
#           publication', 'merge publish: off', 'dropped: distpublisher', 'dropped: distribution database',
#           'dropped: distributor', 'dropped: pgvmerge', 'dropped: pgvmerge_sub'; read back: no distribution database,
#           no distributor entry, no REPL- job, no pgvmerge, no pgvmerge_sub, no grant; 'VERDICT CLEAN', exit 0.
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

# the Agent account's entries on the folder and below it (icacls /T lists every child); none = no grant
function Get-GrantLines([string]$folder) {
    if (-not (Test-Path -LiteralPath $folder)) { return @() }
    $lines = & icacls.exe $folder /T /C 2>&1
    return @($lines | Where-Object { "$_" -like "*$agentAccount*" })
}

function Remove-Grant([string]$folder) {
    if (-not (Test-Path -LiteralPath $folder)) { return $true }
    $null = & icacls.exe $folder /remove:g $agentAccount /T /C /Q
    $left = Get-GrantLines $folder
    if ($left.Count -gt 0) { Say "grant: NOT removed: $($left.Count) entr$(if ($left.Count -eq 1) { 'y' } else { 'ies' }) left"; return $false }
    Say 'grant: removed (read back, children included)'
    return $true
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

function Get-RowCount([object]$inst, [string]$database) {
    return [int](Get-LabValue $inst "SELECT CASE WHEN OBJECT_ID(N'dbo.t_merge') IS NULL THEN -1 ELSE (SELECT COUNT(*) FROM dbo.t_merge) END" $database)
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
        }
        $pubRows = Get-RowCount $pubInst $pubDb; $subRows = Get-RowCount $subInst $subDb
        Say "status: rows $pubDb $pubRows, $subDb $subRows"
        if ($pubRows -ne $subRows -or $pubRows -lt 100) { $problems.Add("rows $pubRows / $subRows") }
        $grantLeft = Get-GrantLines (Get-ReplDataPath)
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
    $names = Get-LabNames
    $taken = @($names.PSObject.Properties | Where-Object { $_.Value -gt 0 } | ForEach-Object { $_.Name })
    if ($taken.Count -gt 0) { Stop-Refused "already present: $($taken -join ', ') (down first)" }
    $agentActual = Get-LabValue $pubInst "SELECT CAST(service_account AS nvarchar(256)) FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server Agent%'"
    if ($agentActual -ne $agentAccount) { Stop-Refused "the Agent service account is '$agentActual', not '$agentAccount'" }
    $replData = Get-ReplDataPath
    if ((Get-GrantLines $replData).Count -gt 0) { Stop-Refused "$agentAccount already has a right on $replData" }
    Say "publisher $pubName, subscriber $subName ($version)"

    $sapw = (Get-Content -LiteralPath $saFile -Raw -ErrorAction Stop).Trim()
    $made = $false
    try {
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
        if ((Get-GrantLines $replData).Count -eq 0) { throw "the grant on $replData is not read back" }
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
        if (-not (Wait-Until 300 { (Get-RowCount $subInst $subDb) -eq 100 })) {
            $mergeText = Invoke-LabSql $pubInst "SELECT TOP (5) x.runstatus, CAST(LEFT(y.comments, 400) AS nvarchar(400)) AS comments FROM dbo.MSmerge_agents a JOIN dbo.MSmerge_sessions x ON x.agent_id = a.id LEFT JOIN dbo.MSmerge_history y ON y.agent_id = a.id AND y.session_id = x.session_id WHERE a.publication = N'$publication' ORDER BY x.session_id DESC, y.timestamp DESC" $distDb
            foreach ($mergeRow in $mergeText) { Say "merge history: $($mergeRow.runstatus) $($mergeRow.comments)" }
            throw "$subDb did not reach 100 rows in 300 s ($(Get-RowCount $subInst $subDb))"
        }
        Say "${subDb}: 100 rows"
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
    $pubName = Get-LabValue $pubInst 'SELECT CAST(@@SERVERNAME AS nvarchar(256))'
    $subName = Get-LabValue $subInst 'SELECT CAST(@@SERVERNAME AS nvarchar(256))'
    # each step: run when its object is there, report, go on (one failed step never keeps the others from running)
    function Step([string]$label, [scriptblock]$body) {
        try { & $body; Say $label } catch { Say "FAILED $label`: $($_.Exception.Message)"; $failures.Add($label) }
    }
    $hasDist = [int](Get-LabValue $pubInst "SELECT COUNT(*) FROM sys.databases WHERE name = N'$distDb' AND is_distributor = 1") -gt 0
    $hasPubDb = [int](Get-LabValue $pubInst "SELECT COUNT(*) FROM sys.databases WHERE name = N'$pubDb'") -gt 0
    $hasSubDb = [int](Get-LabValue $subInst "SELECT COUNT(*) FROM sys.databases WHERE name = N'$subDb'") -gt 0
    if ($hasDist) {
        $jobs = Invoke-LabSql $pubInst "SELECT CAST(j.name AS nvarchar(200)) AS job FROM msdb.dbo.sysjobs j WHERE j.job_id IN (SELECT CAST(job_id AS uniqueidentifier) FROM [$distDb].dbo.MSmerge_agents WHERE publication = N'$publication' UNION SELECT CAST(job_id AS uniqueidentifier) FROM [$distDb].dbo.MSsnapshot_agents WHERE publication = N'$publication') AND EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity a WHERE a.job_id = j.job_id AND a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL)"
        foreach ($jobRow in $jobs) { Step "stopped: $($jobRow.job)" { Invoke-LabSql $pubInst 'EXEC msdb.dbo.sp_stop_job @job_name = @job;' 'master' @{ job = $jobRow.job } | Out-Null } }
    }
    if ($hasPubDb -and [int](Get-LabValue $pubInst "SELECT CASE WHEN OBJECT_ID(N'dbo.sysmergepublications') IS NULL THEN 0 ELSE (SELECT COUNT(*) FROM dbo.sysmergepublications WHERE name = N'$publication') END" $pubDb) -gt 0) {
        if ([int](Get-LabValue $pubInst "SELECT COUNT(*) FROM dbo.sysmergesubscriptions s JOIN dbo.sysmergepublications p ON p.pubid = s.pubid WHERE p.name = N'$publication' AND s.db_name = N'$subDb'" $pubDb) -gt 0) {
            Step 'dropped: subscription' { Invoke-LabSql $pubInst "EXEC sp_dropmergesubscription @publication = N'$publication', @subscriber = @sub, @subscriber_db = N'$subDb', @subscription_type = N'push';" $pubDb @{ sub = $subName } | Out-Null }
        }
        if ($hasSubDb) { Step 'cleanup: subscriber' { Invoke-LabSql $subInst "EXEC sp_mergesubscription_cleanup @publisher = @pub, @publisher_db = N'$pubDb', @publication = N'$publication';" $subDb @{ pub = $pubName } | Out-Null } }
        Step 'dropped: publication' { Invoke-LabSql $pubInst "EXEC sp_dropmergepublication @publication = N'$publication';" $pubDb | Out-Null }
    }
    if ($hasPubDb -and [int](Get-LabValue $pubInst "SELECT CAST(is_merge_published AS int) FROM sys.databases WHERE name = N'$pubDb'") -eq 1) {
        Step 'merge publish: off' { Invoke-LabSql $pubInst "EXEC sp_replicationdboption @dbname = N'$pubDb', @optname = N'merge publish', @value = N'false';" | Out-Null }
    }
    if ([int](Get-LabValue $pubInst "SELECT CASE WHEN OBJECT_ID(N'msdb.dbo.MSdistpublishers') IS NULL THEN 0 ELSE (SELECT COUNT(*) FROM msdb.dbo.MSdistpublishers WHERE name = @@SERVERNAME) END") -gt 0) {
        Step 'dropped: distpublisher' { Invoke-LabSql $pubInst 'EXEC sp_dropdistpublisher @publisher = @@SERVERNAME;' | Out-Null }
    }
    if ($hasDist) { Step 'dropped: distribution database' { Invoke-LabSql $pubInst "EXEC sp_dropdistributiondb @database = N'$distDb';" | Out-Null } }
    if ([int](Get-LabValue $pubInst 'SELECT COUNT(*) FROM sys.servers WHERE is_distributor = 1') -gt 0) {
        Step 'dropped: distributor' { Invoke-LabSql $pubInst 'EXEC sp_dropdistributor;' | Out-Null }
    }
    if ($hasPubDb) { Step "dropped: $pubDb" { Invoke-LabSql $pubInst "ALTER DATABASE [$pubDb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$pubDb];" | Out-Null } }
    if ($hasSubDb) { Step "dropped: $subDb" { Invoke-LabSql $subInst "ALTER DATABASE [$subDb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$subDb];" | Out-Null } }
    $replData = Get-ReplDataPath
    if ((Get-GrantLines $replData).Count -gt 0) { if (-not (Remove-Grant $replData)) { $failures.Add('the grant') } }
    # read back every name
    $names = Get-LabNames
    foreach ($prop in $names.PSObject.Properties) { if ($prop.Value -gt 0) { $failures.Add("$($prop.Name) left ($($prop.Value))") } }
    if ((Get-GrantLines $replData).Count -gt 0) { $failures.Add('grant left') }
    Say "read back: distribution database $($names.DistDb), distributor entry $($names.Distributor), REPL- jobs $($names.ReplJobs), $pubDb $($names.PubDb), $subDb $($names.SubDb), grant entries $((Get-GrantLines $replData).Count)"
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
