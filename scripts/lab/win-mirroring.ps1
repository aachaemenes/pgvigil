# win-mirroring.ps1 - a database mirroring lab on ONE Windows Server host for scripts/proof-mssql-mirroring.sh:
# three named SQL Server 2022 Developer instances on the host - PGVPRINCIPAL (the principal), PGVMIRROR (the mirror)
# and PGVWITNESS (the witness) - with SQL Server Agent, certificate-authenticated mirroring endpoints and one mirrored
# database, pgvmirror, in high-safety mode with the witness (automatic failover). SQL Server on Linux has no database
# mirroring, so its proof needs a Windows host. All three instances on one host prove the states, a role swap and the
# loss of the witness; they cannot prove a network split between the partners.
#
# Windows PowerShell 5.1, run as a local administrator of the host (an elevated session):
#   powershell -NoProfile -ExecutionPolicy Bypass -File win-mirroring.ps1 -Action before|up|status|down [options]
#   before  read only but for <LabDir> itself: the host's state BY NAME into <LabDir>\before.json (the SQL Server
#           instances, every service whose name starts MSSQL, SQL or DBADash with its status and start type, every
#           inbound firewall rule, the listening TCP ports, the SQL Server Browser's start type, whether each ISO the lab
#           may use is attached). Refused when <LabDir> exists and is not empty (a lab is in progress: down first; a
#           folder of anything else is never taken), or when one of the lab's three instance names already exists.
#   up      builds the lab; needs before.json. Every step reads first and skips what is already there, so a cut run
#           is run again. An instance named in before.json is never touched.
#   status  read only: each lab instance's services, version and port, the mirroring rows of both partners, the
#           witness's row, the firewall rule; the last line is the VERDICT (exit 1 when it is not UP).
#   down    the undo; needs before.json. Uninstalls ONLY the lab's three instance names, and only when before.json
#           does not list them; removes the firewall rule by its name only when before.json does not list it; removes
#           each instance's leftover folder by its own instance id; dismounts only an ISO before.json saw unattached;
#           reads every name of before.json back (present, the same start type, Running where it was Running) and
#           every lab name back (gone); on a CLEAN read back removes the lab's own files from <LabDir> by name, then
#           <LabDir> when that leaves it empty.
#
# Options:
#   -LabDir      default C:\pgvmirror, a folder of the lab's own (absent or empty at 'before'): before.json, the
#                secret folder (the sa password file and, while setup runs, its configuration file: Administrators and
#                SYSTEM only, no inherited right), the certificates, the backup files of the initial sync, the setup
#                summaries this script copies, and the ISO when this script downloads it.
#   -IsoPath     a SQL Server 2022 Developer ISO already on the host; default: C:\sqlmedia\SQLServer2022-x64-ENU-Dev.iso
#                when present (used read only, never removed), else Microsoft's own download into <LabDir>\media.
#   -BoxAddress  (up) ONE private IPv4 address admitted to the three instances' SQL ports (TCP 14331-14333) by one
#                inbound Windows Firewall rule 'pgvigil mirroring lab' (no other address, no other port). Empty: no
#                rule (the proof then runs on the host's own network only).
#
# What up makes, every name fixed here (down finds them by these names and nothing else):
#   instances  PGVPRINCIPAL (TCP 14331, endpoint 5023, max server memory 1536 MB), PGVMIRROR (14332, 5024, 1536 MB),
#              PGVWITNESS (14333, 5025, 512 MB): database engine and Agent only, installed with Windows authentication
#              (the running Windows user a sysadmin) and switched to mixed mode right after (LoginMode 2 in the
#              instance's own registry key, a restart, then sa's password made here and sa enabled by T-SQL), TCP on
#              with a static port, named pipes off, Agent automatic and started, no product update during setup.
#   setup      SQL Server setup (install and uninstall) runs as SYSTEM through ONE scheduled task of the lab's,
#              'pgvigil-mirroring-lab-setup', registered for the one call and deleted when it returns (down deletes it
#              too, by that name, when before.json does not list it). Why: setup protects its service-account settings
#              with DPAPI under the user that runs it (SqlSecureString.WriteXml -> ProtectedData.Protect, even for an
#              account with no password), and a key-based OpenSSH logon (S4U) holds no credentials to open that user's
#              DPAPI key: setup then stops with 'There was an error generating the XML document' (CryptographicException
#              Access is denied; two runs on 2026-11-14). SYSTEM's own DPAPI key is the machine's. The ssh user stays the
#              instances' sysadmin (named in the configuration by the caller). The configuration file holds no password. The SQL Server Browser keeps the start
#              type before.json read (setup is told it explicitly). Shared features already on the host stay as
#              they are; nothing of another instance is touched.
#   endpoint   pgv_mirroring on each (ROLE PARTNER on the partners, WITNESS on the witness), certificate
#              authentication, AES encryption; per instance a master key, its certificate pgv_cert_<instance> and,
#              for each of the two others, a login, a user and that instance's certificate, with CONNECT on the
#              endpoint. The partner address is the host's full DNS name when all three endpoints answer on it,
#              else 127.0.0.1 (said).
#   database   pgvmirror on the principal (FULL recovery, one table of 1000 rows), backed up (full + log) into
#              <LabDir>\xfer, restored WITH NORECOVERY on the mirror, then the partners and the witness set; on both
#              partners the Database Mirroring Monitor job (msdb.dbo.sp_dbmmonitoraddmonitoring, 1 minute).
#   files      <LabDir>\secret\sa.pw (one line, the sa password of all three instances; the folder is Administrators
#              and SYSTEM only, set before either secret is written).
# Not tracked: the prerequisites SQL Server setup may add for itself (the OLE DB and ODBC drivers, the Visual C++
# runtime): they are shared, the default instance's setup installed them already, and an uninstall leaves them.
#
# Passwords are made here from a cryptographic random source and are never printed; the setup configuration file
# that carries the sa password lives in the secret folder and is deleted when setup returns (setup's own log copy of
# it holds no password).
# A cut run is run again: an instance already installed is kept, every certificate is exported again and a peer's
# copy replaced when its thumbprint differs, and while the principal has no mirroring row the mirror's copy is
# restored again (its mirroring removed first) from fresh backups.
#
# Expected (written before the first run on the host):
#   before  'win-mirroring: before.json written: <n> services, <n> instances (MSSQLSERVER among them), <n> firewall
#           rules, <n> listening ports; Browser <start type>; C: free <n> GB', exit 0.
#   up      for each instance 'setup <name>: exit 0' (3010 = a restart is pending, said) and 'port <name>: 14331..'
#           listening; 'endpoints: 3 started, partner address <fqdn>'; 'pgvmirror: SYNCHRONIZED, witness CONNECTED,
#           safety FULL' within 120 s; 'monitor job: 2'; the rule line when -BoxAddress is set; the status block;
#           'VERDICT UP', exit 0.
#   status  three instances Running with Agent Running, the principal's row PRINCIPAL / SYNCHRONIZED / witness
#           CONNECTED, the mirror's row MIRROR / SYNCHRONIZED, the witness's row naming both partners; 'VERDICT UP'.
#   down    'uninstall <name>: exit 0' for each, 'folder <name>: removed', 'rule: removed' (when made), every
#           before.json service present with its start type and Running where it was, every before.json instance
#           present; 'VERDICT CLEAN', exit 0; the lab's files and <LabDir> removed.
# Exit: 0 done, 1 failed (a VERDICT NOT ... line names what), 2 refused (nothing changed).
[CmdletBinding()]
param(
    [ValidateSet('before', 'up', 'status', 'down')] [string]$Action = 'status',
    [string]$LabDir = 'C:\pgvmirror',
    [string]$IsoPath = '',
    [string]$BoxAddress = ''
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2

$labInstances = @(
    [pscustomobject]@{ Name = 'PGVPRINCIPAL'; SqlPort = 14331; EndpointPort = 5023; Role = 'PARTNER'; MaxMemMB = 1536 },
    [pscustomobject]@{ Name = 'PGVMIRROR'; SqlPort = 14332; EndpointPort = 5024; Role = 'PARTNER'; MaxMemMB = 1536 },
    [pscustomobject]@{ Name = 'PGVWITNESS'; SqlPort = 14333; EndpointPort = 5025; Role = 'WITNESS'; MaxMemMB = 512 }
)
$principalInst = $labInstances[0]; $mirrorInst = $labInstances[1]; $witnessInst = $labInstances[2]
$labDatabase = 'pgvmirror'
$ruleName = 'pgvigil mirroring lab'
$isoUrl = 'https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLServer2022-x64-ENU-Dev.iso'
$sharedIso = 'C:\sqlmedia\SQLServer2022-x64-ENU-Dev.iso'
$instanceNamesKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
$bootstrapSetup = 'C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\SQL2022\setup.exe'
$beforeFile = Join-Path $LabDir 'before.json'
$secretDir = Join-Path $LabDir 'secret'
$saFile = Join-Path $secretDir 'sa.pw'
$labIso = Join-Path $LabDir 'media\SQLServer2022-x64-ENU-Dev.iso'
# the lab's own children of LabDir: down removes these by name and nothing else
$labChildren = @('before.json', 'secret', 'certs', 'xfer', 'media')
$script:restartFor = ''   # the instance whose login mode changed and waits for its restart
$setupTask = 'pgvigil-mirroring-lab-setup'   # the one scheduled task of the lab: setup as SYSTEM (see the header)

# Write-Host: a function's own output stays its return value (Invoke-Status returns its verdict)
function Say([string]$text) { Write-Host "win-mirroring: $text" }
function Stop-Refused([string]$why) { Say "REFUSED: $why"; exit 2 }

function Test-Elevated {
    $principalNow = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principalNow.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# a password of 28 characters from a cryptographic source, at least one of each class (Windows' complexity rule for
# sa under CHECK_POLICY); no quote, bracket or semicolon, so it sits inside an ini value and a T-SQL literal as is
function New-LabPassword {
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; $lower = 'abcdefghijkmnopqrstuvwxyz'; $digits = '23456789'; $marks = '#%+-_'
    $all = $upper + $lower + $digits + $marks
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] 64
    $rng.GetBytes($bytes)
    $chars = New-Object System.Collections.Generic.List[char]
    $chars.Add($upper[$bytes[0] % $upper.Length]); $chars.Add($lower[$bytes[1] % $lower.Length])
    $chars.Add($digits[$bytes[2] % $digits.Length]); $chars.Add($marks[$bytes[3] % $marks.Length])
    for ($pos = 4; $pos -lt 28; $pos++) { $chars.Add($all[$bytes[$pos] % $all.Length]) }
    # shuffle with the rest of the random bytes so the class order is not fixed
    for ($pos = $chars.Count - 1; $pos -gt 0; $pos--) {
        $swap = $bytes[28 + ($pos % 36)] % ($pos + 1)
        $held = $chars[$pos]; $chars[$pos] = $chars[$swap]; $chars[$swap] = $held
    }
    $rng.Dispose()
    return -join $chars
}

# the installed SQL Server instances: name -> instance id (MSSQL16.<name>)
function Get-InstalledInstances {
    $found = @{}
    if (Test-Path -LiteralPath $instanceNamesKey) {
        $item = Get-ItemProperty -LiteralPath $instanceNamesKey -ErrorAction Stop
        foreach ($prop in $item.PSObject.Properties) {
            if ($prop.Name -notlike 'PS*') { $found[$prop.Name] = [string]$prop.Value }
        }
    }
    return $found
}

function Get-ListeningPorts {
    return @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Select-Object -ExpandProperty LocalPort | Sort-Object -Unique)
}

# one T-SQL batch on a lab instance as the running Windows user, over TCP to 127.0.0.1 (the static port); returns the
# rows of the first result set as objects
function Invoke-LabSql([object]$inst, [string]$query, [int]$timeoutSec = 120, [string]$database = 'master') {
    $connText = "Server=tcp:127.0.0.1,$($inst.SqlPort);Database=$database;Integrated Security=SSPI;Application Name=win-mirroring;Connect Timeout=15"
    $conn = New-Object System.Data.SqlClient.SqlConnection $connText
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = $timeoutSec
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

# every ISO path the lab may mount: the shared one, -IsoPath, its own download
function Get-IsoCandidates {
    return @(@($sharedIso, $IsoPath, $labIso) | Where-Object { $_ } | Select-Object -Unique)
}

# the secret folder: Administrators and SYSTEM only, no inherited right, made before any secret is written into it
function New-SecretDir {
    New-Item -ItemType Directory -Path $secretDir -Force | Out-Null
    $null = & icacls.exe $secretDir /inheritance:r /grant:r 'BUILTIN\Administrators:(OI)(CI)F' 'NT AUTHORITY\SYSTEM:(OI)(CI)F' /Q
    if ($LASTEXITCODE -ne 0) { throw "icacls could not restrict $secretDir (exit $LASTEXITCODE)" }
}

function Read-Before {
    if (-not (Test-Path -LiteralPath $beforeFile)) { Stop-Refused "no ${beforeFile}: run -Action before first (no by-name before-list, no change)" }
    return (Get-Content -LiteralPath $beforeFile -Raw -ErrorAction Stop | ConvertFrom-Json)
}

function Test-InBefore([object]$before, [string]$listName, [string]$name) {
    return @($before.$listName | Where-Object { $_.Name -eq $name }).Count -gt 0
}

# ---------------------------------------------------------------------------------------------------------------
function Invoke-Before {
    if (Test-Path -LiteralPath $beforeFile) { Stop-Refused "$beforeFile exists: a lab is in progress (run -Action down, which removes it on a clean read back)" }
    if ((Test-Path -LiteralPath $LabDir) -and @(Get-ChildItem -LiteralPath $LabDir -Force -ErrorAction Stop).Count -gt 0) {
        Stop-Refused "$LabDir exists and is not empty: the lab takes a folder of its own only (pick another -LabDir)"
    }
    $installed = Get-InstalledInstances
    foreach ($inst in $labInstances) {
        if ($installed.ContainsKey($inst.Name)) { Stop-Refused "the instance $($inst.Name) already exists and was not made by a run of this lab's before / up: it is never touched" }
    }
    if (Get-ScheduledTask -TaskName $setupTask -ErrorAction SilentlyContinue) { Stop-Refused "a scheduled task named '$setupTask' exists already: it is not the lab's to take" }
    New-Item -ItemType Directory -Path $LabDir -Force | Out-Null
    $services = @(Get-Service -ErrorAction Stop | Where-Object { $_.Name -like 'MSSQL*' -or $_.Name -like 'SQL*' -or $_.Name -like 'DBADash*' } |
        Sort-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Status = [string]$_.Status; StartType = [string]$_.StartType } })
    $rules = @(Get-NetFirewallRule -Direction Inbound -ErrorAction Stop | Sort-Object DisplayName |
        ForEach-Object { [pscustomobject]@{ Name = $_.DisplayName; Enabled = [string]$_.Enabled } })
    $instList = @($installed.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Name = $_; Id = $installed[$_] } })
    $isoState = @(Get-IsoCandidates | ForEach-Object {
            $image = if (Test-Path -LiteralPath $_) { Get-DiskImage -ImagePath $_ -ErrorAction SilentlyContinue } else { $null }
            [pscustomobject]@{ Path = $_; Attached = [bool]($image -and $image.Attached) } })
    $browser = Get-Service -Name SQLBrowser -ErrorAction SilentlyContinue
    $browserStart = if ($browser) { [string]$browser.StartType } else { '' }
    $state = [pscustomobject]@{
        WrittenAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); Computer = $env:COMPUTERNAME
        Instances = $instList; Services = $services; FirewallRules = $rules; ListeningPorts = @(Get-ListeningPorts)
        BrowserStartType = $browserStart; SharedIsoPresent = (Test-Path -LiteralPath $sharedIso); Isos = $isoState
        SetupTaskPresent = [bool](Get-ScheduledTask -TaskName $setupTask -ErrorAction SilentlyContinue)
        FreeGB = [math]::Round((Get-PSDrive C -ErrorAction Stop).Free / 1GB, 1)
    }
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $beforeFile -Encoding UTF8
    Say ("before.json written: {0} services, {1} instances ({2}), {3} firewall rules, {4} listening ports; Browser {5}; C: free {6} GB" -f `
            $services.Count, $instList.Count, (($instList | ForEach-Object { $_.Name }) -join ', '), $rules.Count, $state.ListeningPorts.Count,
        $(if ($browserStart) { $browserStart } else { 'not installed' }), $state.FreeGB)
}

# ---------------------------------------------------------------------------------------------------------------
function Get-SetupFolder([object]$before) {
    $iso = $IsoPath
    if (-not $iso) { if (Test-Path -LiteralPath $sharedIso) { $iso = $sharedIso } else { $iso = $labIso } }
    if (-not (Test-Path -LiteralPath $iso) -or (Get-Item -LiteralPath $iso).Length -lt 1100MB) {
        if ($iso -ne $labIso) { throw "the ISO $iso is missing or under 1100 MB" }
        New-Item -ItemType Directory -Path (Split-Path $iso) -Force | Out-Null
        Say 'download: SQLServer2022-x64-ENU-Dev.iso from download.microsoft.com (about 1.16 GB)'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $web = New-Object Net.WebClient
        try { $web.DownloadFile($isoUrl, $iso) } finally { $web.Dispose() }
        Say "download: $([int]((Get-Item -LiteralPath $iso).Length / 1MB)) MB"
    }
    $image = Get-DiskImage -ImagePath $iso -ErrorAction Stop
    if (-not $image.Attached) { $image = Mount-DiskImage -ImagePath $iso -PassThru -ErrorAction Stop; Say "mounted $iso" }
    $letter = $null
    $deadline = (Get-Date).AddSeconds(30)
    while (-not $letter -and (Get-Date) -lt $deadline) {
        $letter = (Get-Volume -DiskImage (Get-DiskImage -ImagePath $iso -ErrorAction Stop) -ErrorAction SilentlyContinue).DriveLetter
        if (-not $letter) { Start-Sleep -Seconds 2 }
    }
    if (-not $letter) { throw "the mounted ISO $iso has no drive letter after 30 s" }
    $setupExe = "${letter}:\setup.exe"
    if (-not (Test-Path -LiteralPath $setupExe)) { throw "no setup.exe on the mounted ISO ($setupExe)" }
    $sig = Get-AuthenticodeSignature -FilePath $setupExe -ErrorAction Stop
    $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { 'no signer' }
    if ($sig.Status -ne 'Valid' -or $signer -notlike '*O=Microsoft Corporation*') {
        throw "setup.exe on the ISO is not validly signed by Microsoft ($($sig.Status), $signer)"
    }
    return [pscustomobject]@{ Iso = $iso; SetupExe = $setupExe }
}

# Invoke-SetupAsSystem: setup.exe <arguments> as SYSTEM through the lab's one-shot task; returns setup's exit code.
# The task's command is a .cmd in the secret folder that runs setup and writes its exit code beside it; the task, the
# .cmd and the exit file are removed on every path. A task left by a killed run is the lab's (its fixed name, absent
# from before.json) and is replaced.
function Invoke-SetupAsSystem([string]$setupExe, [string]$arguments, [int]$timeoutMin = 50) {
    $wrapper = Join-Path $secretDir 'setup-run.cmd'
    $exitFile = Join-Path $secretDir 'setup-run.exit'
    if (Test-Path -LiteralPath $exitFile) { Remove-Item -LiteralPath $exitFile -Force -ErrorAction Stop }
    # the redirection comes first: 'echo 0> file' would redirect handle 0 and leave the file empty
    Set-Content -LiteralPath $wrapper -Encoding ASCII -Value @("@echo off", "`"$setupExe`" $arguments", "> `"$exitFile`" echo %ERRORLEVEL%")
    $taskAction = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$wrapper`""
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes $timeoutMin) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    try {
        Register-ScheduledTask -TaskName $setupTask -Action $taskAction -Principal $taskPrincipal -Settings $taskSettings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $setupTask -ErrorAction Stop
        $deadline = (Get-Date).AddMinutes($timeoutMin)
        while (-not (Test-Path -LiteralPath $exitFile)) {
            if ((Get-Date) -gt $deadline) { throw "setup as SYSTEM wrote no exit code in $timeoutMin minutes (task state $((Get-ScheduledTask -TaskName $setupTask).State))" }
            Start-Sleep -Seconds 10
        }
        Start-Sleep -Seconds 2
        $codeText = [string](Get-Content -LiteralPath $exitFile -Raw -ErrorAction Stop)
        if ($codeText.Trim() -notmatch '^-?[0-9]+$') { throw "setup as SYSTEM left no exit code in $exitFile ('$($codeText.Trim())')" }
        return [int]$codeText.Trim()
    } finally {
        if (Get-ScheduledTask -TaskName $setupTask -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $setupTask -Confirm:$false -ErrorAction SilentlyContinue }
        foreach ($leftover in @($wrapper, $exitFile)) { if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Force -ErrorAction SilentlyContinue } }
    }
}

function Install-LabInstance([object]$inst, [string]$setupExe, [object]$before) {
    # the running identity (a process started through WMI does not carry the caller's USERNAME variable)
    $sysadmin = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $browserStart = if ($before.BrowserStartType) { $before.BrowserStartType } else { 'Disabled' }
    $iniText = @"
[OPTIONS]
ACTION="Install"
QUIET="True"
IACCEPTSQLSERVERLICENSETERMS="True"
ENU="True"
UPDATEENABLED="False"
FEATURES=SQLENGINE
INSTANCENAME="$($inst.Name)"
INSTANCEID="$($inst.Name)"
SQLSVCSTARTUPTYPE="Automatic"
AGTSVCSTARTUPTYPE="Automatic"
BROWSERSVCSTARTUPTYPE="$browserStart"
SQLSYSADMINACCOUNTS="$sysadmin"
TCPENABLED="1"
NPENABLED="0"
SQLTEMPDBFILECOUNT="1"
SQLSVCINSTANTFILEINIT="True"
"@
    $iniPath = Join-Path $secretDir "setup-$($inst.Name).ini"
    try {
        [IO.File]::WriteAllText($iniPath, $iniText, (New-Object Text.UTF8Encoding $false))
        Say "setup $($inst.Name): started $(Get-Date -Format 'HH:mm:ss') as SYSTEM (about 10 minutes)"
        $code = Invoke-SetupAsSystem $setupExe "/ConfigurationFile=`"$iniPath`""
    } finally {
        if (Test-Path -LiteralPath $iniPath) { Remove-Item -LiteralPath $iniPath -Force }
    }
    $summary = 'C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log\Summary.txt'
    if (Test-Path -LiteralPath $summary) {
        New-Item -ItemType Directory -Path (Join-Path $LabDir 'media') -Force | Out-Null
        Copy-Item -LiteralPath $summary -Destination (Join-Path $LabDir "media\setup-$($inst.Name)-summary.txt") -Force
    }
    if ($code -eq 3010) { Say "setup $($inst.Name): exit 3010 (installed; Windows wants a restart, not done here)" }
    elseif ($code -ne 0) {
        if (Test-Path -LiteralPath $summary) { Get-Content -LiteralPath $summary | Select-Object -First 25 | ForEach-Object { Say "  summary: $_" } }
        throw "setup $($inst.Name) failed with exit $code"
    } else { Say "setup $($inst.Name): exit 0" }
}

# mixed-mode authentication (LoginMode 2 in the instance's own key); the restart that makes it count is Set-LabPort's
# (forced here when the port needs no change)
function Set-LabMixedMode([object]$inst, [string]$instanceId) {
    $key = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer"
    if ([int](Get-ItemProperty -LiteralPath $key -ErrorAction Stop).LoginMode -ne 2) {
        Set-ItemProperty -LiteralPath $key -Name LoginMode -Value 2 -Type DWord -ErrorAction Stop
        $script:restartFor = $inst.Name
    }
}

# a static TCP port on IPAll, dynamic ports off; the engine (and Agent) restarted when it changed or when the login
# mode just changed
function Set-LabPort([object]$inst, [string]$instanceId) {
    $tcpKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"
    $now = Get-ItemProperty -LiteralPath $tcpKey -ErrorAction Stop
    $engine = "MSSQL`$$($inst.Name)"; $agent = "SQLAgent`$$($inst.Name)"
    if ([string]$now.TcpPort -ne [string]$inst.SqlPort -or [string]$now.TcpDynamicPorts -ne '' -or $script:restartFor -eq $inst.Name) {
        Set-ItemProperty -LiteralPath $tcpKey -Name TcpDynamicPorts -Value '' -ErrorAction Stop
        Set-ItemProperty -LiteralPath $tcpKey -Name TcpPort -Value ([string]$inst.SqlPort) -ErrorAction Stop
        Restart-Service -Name $engine -Force -ErrorAction Stop
        $script:restartFor = ''
    }
    if ((Get-Service -Name $engine -ErrorAction Stop).Status -ne 'Running') { Start-Service -Name $engine -ErrorAction Stop }
    Set-Service -Name $agent -StartupType Automatic -ErrorAction Stop
    if ((Get-Service -Name $agent -ErrorAction Stop).Status -ne 'Running') { Start-Service -Name $agent -ErrorAction Stop }
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-ListeningPorts) -notcontains $inst.SqlPort) {
        if ((Get-Date) -gt $deadline) { throw "$($inst.Name) does not listen on TCP $($inst.SqlPort) 60 s after its start" }
        Start-Sleep -Seconds 2
    }
    Say "port $($inst.Name): $($inst.SqlPort) listening; Agent $((Get-Service -Name $agent).Status)"
}

function Grant-ServiceFolder([string]$folder) {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    foreach ($inst in $labInstances) {
        $sidName = "NT SERVICE\MSSQL`$$($inst.Name)"
        $null = & icacls.exe $folder /grant "${sidName}:(OI)(CI)M" /Q
        if ($LASTEXITCODE -ne 0) { throw "icacls could not grant $sidName on $folder (exit $LASTEXITCODE)" }
    }
}

function New-LabEndpoint([object]$inst, [string]$certDir) {
    $certName = "pgv_cert_$($inst.Name)"
    $certFile = Join-Path $certDir "$($inst.Name).cer"
    $keyPw = New-LabPassword
    $tsql = @"
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
  CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$keyPw';
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = '$certName')
  CREATE CERTIFICATE [$certName] WITH SUBJECT = 'pgvigil mirroring lab $($inst.Name)', EXPIRY_DATE = '20301231';
IF NOT EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints WHERE name = 'pgv_mirroring')
  CREATE ENDPOINT [pgv_mirroring] STATE = STARTED AS TCP (LISTENER_PORT = $($inst.EndpointPort), LISTENER_IP = ALL)
    FOR DATABASE_MIRRORING (AUTHENTICATION = CERTIFICATE [$certName], ENCRYPTION = REQUIRED ALGORITHM AES, ROLE = $($inst.Role));
ALTER ENDPOINT [pgv_mirroring] STATE = STARTED;
SELECT CAST(1 AS int) AS ok;
"@
    $null = Invoke-LabSql $inst $tsql
    # exported again on every run: a file left by an earlier lab would carry another certificate
    if (Test-Path -LiteralPath $certFile) { Remove-Item -LiteralPath $certFile -Force -ErrorAction Stop }
    $null = Invoke-LabSql $inst "BACKUP CERTIFICATE [$certName] TO FILE = '$certFile'; SELECT CAST(1 AS int) AS ok;"
    if (-not (Test-Path -LiteralPath $certFile)) { throw "the certificate file $certFile was not written" }
    # SQL Server writes the file with a DACL of its own (its service SID, OWNER RIGHTS, Administrators: read on the
    # lab VM 2026-11-14): the two other engines could not read it. Back to the folder's inherited rights (the three
    # service SIDs of Grant-ServiceFolder); the file holds the public certificate only.
    $null = & icacls.exe $certFile /reset /Q
    if ($LASTEXITCODE -ne 0) { throw "icacls could not reset the rights of $certFile (exit $LASTEXITCODE)" }
}

function Grant-LabPeer([object]$inst, [object]$peer, [string]$certDir) {
    $login = "pgv_login_$($peer.Name)"; $user = "pgv_user_$($peer.Name)"; $certName = "pgv_cert_$($peer.Name)"
    $certFile = Join-Path $certDir "$($peer.Name).cer"
    $loginPw = New-LabPassword
    # the peer's copy here must be the peer's certificate now: a copy with another thumbprint is dropped and taken again
    $thumbSql = "SELECT CONVERT(varchar(100), thumbprint, 2) AS thumb FROM sys.certificates WHERE name = '$certName'"
    $peerThumb = (Invoke-LabSql $peer $thumbSql)
    $hereThumb = (Invoke-LabSql $inst $thumbSql)
    if ($peerThumb.Count -ne 1) { throw "$($peer.Name) has no certificate $certName" }
    $dropStale = ''
    if ($hereThumb.Count -eq 1 -and $hereThumb[0].thumb -ne $peerThumb[0].thumb) { $dropStale = "DROP CERTIFICATE [$certName];" }
    $tsql = @"
SET NOCOUNT ON;
$dropStale
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$login')
  CREATE LOGIN [$login] WITH PASSWORD = '$loginPw';
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$user')
  CREATE USER [$user] FOR LOGIN [$login];
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = '$certName')
  CREATE CERTIFICATE [$certName] AUTHORIZATION [$user] FROM FILE = '$certFile';
GRANT CONNECT ON ENDPOINT::[pgv_mirroring] TO [$login];
SELECT CAST(1 AS int) AS ok;
"@
    $null = Invoke-LabSql $inst $tsql
}

function Test-TcpOpen([string]$hostName, [int]$port) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $wait = $client.BeginConnect($hostName, $port, $null, $null)
        if (-not $wait.AsyncWaitHandle.WaitOne(3000)) { return $false }
        $client.EndConnect($wait); return $true
    } catch { return $false } finally { $client.Close() }
}

function Get-MirrorRow([object]$inst) {
    $rows = Invoke-LabSql $inst @"
SELECT CAST(m.mirroring_role_desc AS nvarchar(60)) AS role, CAST(m.mirroring_state_desc AS nvarchar(60)) AS state,
       CAST(m.mirroring_witness_state_desc AS nvarchar(60)) AS witness_state, CAST(m.mirroring_safety_level_desc AS nvarchar(60)) AS safety,
       CAST(m.mirroring_partner_name AS nvarchar(256)) AS partner, CAST(m.mirroring_witness_name AS nvarchar(256)) AS witness
  FROM sys.database_mirroring m JOIN sys.databases d ON d.database_id = m.database_id
 WHERE d.name = '$labDatabase' AND m.mirroring_guid IS NOT NULL
"@
    if ($rows.Count -eq 0) { return $null }
    return $rows[0]
}

function Invoke-Up {
    $before = Read-Before
    if (-not (Test-Elevated)) { Stop-Refused 'not an elevated administrator session' }
    foreach ($inst in $labInstances) {
        if (Test-InBefore $before 'Instances' $inst.Name) { Stop-Refused "before.json lists the instance $($inst.Name): it was on the host before this lab and is never touched" }
    }
    $installed = Get-InstalledInstances
    $toInstall = @($labInstances | Where-Object { -not $installed.ContainsKey($_.Name) })
    # preflight: disk, memory, ports
    $freeGB = [math]::Round((Get-PSDrive C -ErrorAction Stop).Free / 1GB, 1)
    $needGB = 2 * $toInstall.Count + 2
    if ($toInstall.Count -gt 0 -and -not (Test-Path -LiteralPath $sharedIso) -and -not $IsoPath) { $needGB += 2 }
    if ($freeGB -lt $needGB) { Stop-Refused "C: has $freeGB GB free; this run needs $needGB GB" }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $freeMemMB = [int]($os.FreePhysicalMemory / 1024)
    if ($toInstall.Count -gt 0 -and $freeMemMB -lt 2500) { Stop-Refused "$freeMemMB MB of memory free; the three instances need about 2500 MB to start (3584 MB at their caps)" }
    $listening = Get-ListeningPorts
    foreach ($inst in $toInstall) {
        foreach ($port in @($inst.SqlPort, $inst.EndpointPort)) {
            if ($listening -contains $port) { Stop-Refused "TCP $port is in use on the host and $($inst.Name) is not installed yet: pick other ports" }
        }
    }
    if ($BoxAddress) {
        $parsedAddr = $null
        if (-not [Net.IPAddress]::TryParse($BoxAddress, [ref]$parsedAddr) -or $parsedAddr.AddressFamily -ne 'InterNetwork' -or
            $parsedAddr.ToString() -ne $BoxAddress -or
            -not ($BoxAddress -match '^10\.' -or $BoxAddress -match '^192\.168\.' -or $BoxAddress -match '^172\.(1[6-9]|2[0-9]|3[01])\.')) {
            Stop-Refused "-BoxAddress $BoxAddress is not one private IPv4 address"
        }
    }
    Say "preflight: C: free $freeGB GB, memory free $freeMemMB MB, to install: $(if ($toInstall.Count) { ($toInstall | ForEach-Object { $_.Name }) -join ', ' } else { 'none' })"

    # the sa password: made once, kept in sa.pw for the proof and for a cut run's rerun
    New-SecretDir
    if (Test-Path -LiteralPath $saFile) { $saPassword = (Get-Content -LiteralPath $saFile -Raw -ErrorAction Stop).Trim() }
    else {
        if (@($labInstances | Where-Object { $installed.ContainsKey($_.Name) }).Count -gt 0) { throw "a lab instance exists but $saFile does not: run -Action down, then up" }
        $saPassword = New-LabPassword
        Set-Content -LiteralPath $saFile -Value $saPassword -Encoding ASCII -NoNewline
    }

    if ($toInstall.Count -gt 0) {
        $media = Get-SetupFolder $before
        foreach ($inst in $toInstall) { Install-LabInstance $inst $media.SetupExe $before }
        $installed = Get-InstalledInstances
    }
    foreach ($inst in $labInstances) {
        if (-not $installed.ContainsKey($inst.Name)) { throw "$($inst.Name) is not installed after setup" }
        if (-not (Get-Service -Name "MSSQL`$$($inst.Name)" -ErrorAction SilentlyContinue)) { throw "$($inst.Name) is half-installed (no service): run -Action down, then up" }
        Set-LabMixedMode $inst $installed[$inst.Name]
        Set-LabPort $inst $installed[$inst.Name]
        $null = Invoke-LabSql $inst "EXEC sys.sp_configure N'show advanced options', 1; RECONFIGURE; EXEC sys.sp_configure N'max server memory (MB)', $($inst.MaxMemMB); RECONFIGURE; SELECT CAST(1 AS int) AS ok;"
        # sa: the password made here, enabled (mixed mode is in force after Set-LabPort's restart)
        $null = Invoke-LabSql $inst "ALTER LOGIN [sa] WITH PASSWORD = '$saPassword', CHECK_POLICY = ON; ALTER LOGIN [sa] ENABLE; SELECT CAST(1 AS int) AS ok;"
        $mode = (Invoke-LabSql $inst "SELECT CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS int) AS v")[0].v
        if ($mode -ne 0) { throw "$($inst.Name) is still Windows authentication only after LoginMode 2 and its restart" }
    }

    # endpoints and certificates (the folder is written by the three engines' service accounts)
    $certDir = Join-Path $LabDir 'certs'; $xferDir = Join-Path $LabDir 'xfer'
    Grant-ServiceFolder $certDir; Grant-ServiceFolder $xferDir
    foreach ($inst in $labInstances) { New-LabEndpoint $inst $certDir }
    foreach ($inst in $labInstances) { foreach ($peer in $labInstances) { if ($peer.Name -ne $inst.Name) { Grant-LabPeer $inst $peer $certDir } } }
    $fqdn = [Net.Dns]::GetHostEntry([Net.Dns]::GetHostName()).HostName
    $partnerHost = $fqdn
    foreach ($inst in $labInstances) { if (-not (Test-TcpOpen $fqdn $inst.EndpointPort)) { $partnerHost = '127.0.0.1' } }
    if ($partnerHost -ne $fqdn) {
        foreach ($inst in $labInstances) { if (-not (Test-TcpOpen '127.0.0.1' $inst.EndpointPort)) { throw "the endpoint of $($inst.Name) does not answer on TCP $($inst.EndpointPort)" } }
        Say "endpoints: 3 started; $fqdn does not reach all three, partner address 127.0.0.1"
    } else { Say "endpoints: 3 started, partner address $fqdn" }
    $addrOf = @{}; foreach ($inst in $labInstances) { $addrOf[$inst.Name] = "TCP://${partnerHost}:$($inst.EndpointPort)" }

    # the mirrored database
    $row = Get-MirrorRow $principalInst
    if ($null -eq $row) {
        $bak = Join-Path $xferDir "$labDatabase.bak"; $trn = Join-Path $xferDir "$labDatabase.trn"
        $null = Invoke-LabSql $principalInst @"
SET NOCOUNT ON;
IF DB_ID('$labDatabase') IS NULL CREATE DATABASE [$labDatabase];
ALTER DATABASE [$labDatabase] SET RECOVERY FULL;
EXEC ('USE [$labDatabase]; IF OBJECT_ID(''dbo.lab_rows'') IS NULL BEGIN
  CREATE TABLE dbo.lab_rows (id int IDENTITY PRIMARY KEY, filler char(200) NOT NULL DEFAULT ''x'', at datetime2 NOT NULL DEFAULT SYSUTCDATETIME());
  INSERT dbo.lab_rows (filler) SELECT TOP (1000) ''x'' FROM sys.all_objects a CROSS JOIN sys.all_objects b; END');
BACKUP DATABASE [$labDatabase] TO DISK = '$bak' WITH INIT, FORMAT;
BACKUP LOG [$labDatabase] TO DISK = '$trn' WITH INIT, FORMAT;
SELECT CAST(1 AS int) AS ok;
"@ 600
        $paths = Invoke-LabSql $mirrorInst "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(400)) AS data_path, CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(400)) AS log_path"
        $files = Invoke-LabSql $mirrorInst "RESTORE FILELISTONLY FROM DISK = '$bak'"
        $moves = @($files | ForEach-Object {
                $dest = if ($_.Type -eq 'L') { $paths[0].log_path } else { $paths[0].data_path }
                "MOVE N'$($_.LogicalName)' TO N'$(Join-Path $dest ([IO.Path]::GetFileName($_.PhysicalName)))'" }) -join ', '
        # the mirror's copy is restored again on every pass through here (a cut run may have left it behind the
        # backups just taken, or partnered already): its mirroring is removed first; it is the lab's own database
        if ($null -ne (Get-MirrorRow $mirrorInst)) {
            $null = Invoke-LabSql $mirrorInst "ALTER DATABASE [$labDatabase] SET PARTNER OFF; SELECT CAST(1 AS int) AS ok;"
            Say 'pgvmirror: the mirror held a mirroring row from a cut run: removed (SET PARTNER OFF)'
        }
        $null = Invoke-LabSql $mirrorInst @"
SET NOCOUNT ON;
RESTORE DATABASE [$labDatabase] FROM DISK = '$bak' WITH REPLACE, NORECOVERY, $moves;
RESTORE LOG [$labDatabase] FROM DISK = '$trn' WITH NORECOVERY;
SELECT CAST(1 AS int) AS ok;
"@ 600
        $null = Invoke-LabSql $mirrorInst "ALTER DATABASE [$labDatabase] SET PARTNER = '$($addrOf[$principalInst.Name])'; SELECT CAST(1 AS int) AS ok;"
        $null = Invoke-LabSql $principalInst "ALTER DATABASE [$labDatabase] SET PARTNER = '$($addrOf[$mirrorInst.Name])'; SELECT CAST(1 AS int) AS ok;"
        Say "pgvmirror: partners set ($($addrOf[$principalInst.Name]) <-> $($addrOf[$mirrorInst.Name]))"
    }
    $row = Get-MirrorRow $principalInst
    if ($null -eq $row) { throw 'pgvmirror has no mirroring row on the principal after SET PARTNER' }
    if (-not $row.witness) {
        $null = Invoke-LabSql $principalInst "ALTER DATABASE [$labDatabase] SET WITNESS = '$($addrOf[$witnessInst.Name])'; SELECT CAST(1 AS int) AS ok;"
        Say "pgvmirror: witness set ($($addrOf[$witnessInst.Name]))"
    }
    $deadline = (Get-Date).AddSeconds(120)
    do {
        $row = Get-MirrorRow $principalInst
        if ($row -and $row.state -eq 'SYNCHRONIZED' -and $row.witness_state -eq 'CONNECTED') { break }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    if ($null -eq $row) { throw 'pgvmirror has no mirroring row on the principal 120 s after the setup' }
    Say "pgvmirror: $($row.state), witness $($row.witness_state), safety $($row.safety)"
    if ($row.state -ne 'SYNCHRONIZED' -or $row.witness_state -ne 'CONNECTED') { throw 'pgvmirror is not SYNCHRONIZED with its witness CONNECTED 120 s after the setup' }

    # the Database Mirroring Monitor job on both partners (its table msdb.dbo.dbm_monitor_data feeds the rates)
    $jobs = 0
    foreach ($inst in @($principalInst, $mirrorInst)) {
        $null = Invoke-LabSql $inst "IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'Database Mirroring Monitor Job') EXEC msdb.dbo.sp_dbmmonitoraddmonitoring 1; SELECT CAST(1 AS int) AS ok;"
        $jobs += (Invoke-LabSql $inst "SELECT name FROM msdb.dbo.sysjobs WHERE name = N'Database Mirroring Monitor Job'").Count
    }
    Say "monitor job: $jobs"

    if ($BoxAddress) {
        if (Test-InBefore $before 'FirewallRules' $ruleName) { Say "rule: '$ruleName' was on the host before this lab: left as it is" }
        elseif (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
            $ports = ($labInstances | ForEach-Object { [string]$_.SqlPort })
            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $ports -RemoteAddress $BoxAddress -Action Allow -Profile Any -ErrorAction Stop | Out-Null
            Say "rule: '$ruleName' TCP $($ports -join ',') from $BoxAddress only"
        } else { Say "rule: '$ruleName' present" }
    }
    $verdict = Invoke-Status
    if ($verdict -ne 'UP') { exit 1 }
}

# ---------------------------------------------------------------------------------------------------------------
function Invoke-Status {
    $installed = Get-InstalledInstances
    $problems = New-Object System.Collections.Generic.List[string]
    $listening = Get-ListeningPorts
    $present = 0
    foreach ($inst in $labInstances) {
        if (-not $installed.ContainsKey($inst.Name)) { Say "status $($inst.Name): not installed"; $problems.Add("$($inst.Name) not installed"); continue }
        $present++
        $engine = Get-Service -Name "MSSQL`$$($inst.Name)" -ErrorAction SilentlyContinue
        $agent = Get-Service -Name "SQLAgent`$$($inst.Name)" -ErrorAction SilentlyContinue
        $engineState = if ($engine) { [string]$engine.Status } else { 'no service' }
        $agentState = if ($agent) { [string]$agent.Status } else { 'no service' }
        $version = '?'
        if ($engineState -eq 'Running' -and $listening -contains $inst.SqlPort) {
            try { $version = (Invoke-LabSql $inst "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(40)) AS v")[0].v } catch { $version = "unread: $($_.Exception.Message)" }
        }
        Say "status $($inst.Name): engine $engineState, Agent $agentState, version $version, TCP $($inst.SqlPort) $(if ($listening -contains $inst.SqlPort) { 'listening' } else { 'NOT listening' }), endpoint $($inst.EndpointPort) $(if ($listening -contains $inst.EndpointPort) { 'listening' } else { 'NOT listening' })"
        if ($engineState -ne 'Running') { $problems.Add("$($inst.Name) engine $engineState") }
        if ($agentState -ne 'Running') { $problems.Add("$($inst.Name) Agent $agentState") }
    }
    if ($present -eq 0) { Say 'VERDICT ABSENT (no lab instance on this host)'; return 'ABSENT' }
    foreach ($inst in @($principalInst, $mirrorInst)) {
        if (-not $installed.ContainsKey($inst.Name) -or $listening -notcontains $inst.SqlPort) { continue }
        try {
            $row = Get-MirrorRow $inst
            if ($null -eq $row) { Say "status $($inst.Name) pgvmirror: no mirroring row"; $problems.Add("$($inst.Name) has no mirroring row") }
            else {
                Say "status $($inst.Name) pgvmirror: $($row.role) / $($row.state) / witness $($row.witness_state) / safety $($row.safety) / partner $($row.partner)"
                if ($row.state -ne 'SYNCHRONIZED') { $problems.Add("$($inst.Name) $($row.state)") }
                if ($row.witness -and $row.witness_state -ne 'CONNECTED') { $problems.Add("$($inst.Name) witness $($row.witness_state)") }
            }
        } catch { Say "status $($inst.Name): unread ($($_.Exception.Message))"; $problems.Add("$($inst.Name) unread") }
    }
    if ($installed.ContainsKey($witnessInst.Name) -and $listening -contains $witnessInst.SqlPort) {
        try {
            $wrows = Invoke-LabSql $witnessInst "SELECT CAST(database_name AS nvarchar(128)) AS db, CAST(principal_server_name AS nvarchar(256)) AS principal, CAST(mirror_server_name AS nvarchar(256)) AS mirror, CAST(partner_sync_state_desc AS nvarchar(60)) AS sync FROM sys.database_mirroring_witnesses"
            foreach ($wrow in $wrows) { Say "status $($witnessInst.Name): witness of $($wrow.db): principal $($wrow.principal), mirror $($wrow.mirror), $($wrow.sync)" }
            if ($wrows.Count -eq 0) { $problems.Add("$($witnessInst.Name) witnesses nothing") }
        } catch { Say "status $($witnessInst.Name): unread ($($_.Exception.Message))"; $problems.Add("$($witnessInst.Name) unread") }
    }
    $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($rule) {
        $addr = ($rule | Get-NetFirewallAddressFilter).RemoteAddress -join ','
        $ports = ($rule | Get-NetFirewallPortFilter).LocalPort -join ','
        Say "status rule: '$ruleName' TCP $ports from $addr"
    } else { Say "status rule: none" }
    Say "status C: free $([math]::Round((Get-PSDrive C).Free / 1GB, 1)) GB"
    if ($problems.Count -eq 0) { Say 'VERDICT UP'; return 'UP' }
    Say "VERDICT NOT UP: $($problems -join '; ')"
    return 'NOT UP'
}

# ---------------------------------------------------------------------------------------------------------------
function Invoke-Down {
    $before = Read-Before
    if (-not (Test-Elevated)) { Stop-Refused 'not an elevated administrator session' }
    $installed = Get-InstalledInstances
    $failures = New-Object System.Collections.Generic.List[string]
    # a before.json written before the task field existed: the task was not there (its name is the lab's own)
    $taskBefore = ($before.PSObject.Properties.Name -contains 'SetupTaskPresent') -and [bool]$before.SetupTaskPresent
    foreach ($inst in $labInstances) {
        if (Test-InBefore $before 'Instances' $inst.Name) { Say "uninstall $($inst.Name): listed in before.json, NOT touched"; continue }
        if (-not $installed.ContainsKey($inst.Name)) { Say "uninstall $($inst.Name): not installed"; continue }
        $setupExe = $bootstrapSetup
        if (-not (Test-Path -LiteralPath $setupExe)) { $setupExe = (Get-SetupFolder $before).SetupExe }
        New-SecretDir
        $code = Invoke-SetupAsSystem $setupExe "/ACTION=Uninstall /QUIET /FEATURES=SQLENGINE /INSTANCENAME=$($inst.Name)"
        Say "uninstall $($inst.Name): exit $code (as SYSTEM)"
        if ($code -ne 0 -and $code -ne 3010) { $failures.Add("uninstall $($inst.Name) exit $code") }
    }
    $installed = Get-InstalledInstances
    foreach ($inst in $labInstances) {
        if ((Test-InBefore $before 'Instances' $inst.Name) -or $installed.ContainsKey($inst.Name)) { continue }
        foreach ($folder in @("C:\Program Files\Microsoft SQL Server\MSSQL16.$($inst.Name)")) {
            if (Test-Path -LiteralPath $folder) {
                try { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop; Say "folder $($inst.Name): removed" }
                catch { $failures.Add("folder $folder not removed: $($_.Exception.Message)") }
            }
        }
    }
    if (-not $taskBefore -and (Get-ScheduledTask -TaskName $setupTask -ErrorAction SilentlyContinue)) {
        Unregister-ScheduledTask -TaskName $setupTask -Confirm:$false -ErrorAction Stop; Say "task '$setupTask': removed"
    }
    if (-not (Test-InBefore $before 'FirewallRules' $ruleName)) {
        $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if ($rule) { Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop; Say 'rule: removed' }
    }
    foreach ($iso in Get-IsoCandidates) {
        if (-not (Test-Path -LiteralPath $iso)) { continue }
        $wasAttached = @($before.Isos | Where-Object { $_.Path -eq $iso -and $_.Attached }).Count -gt 0
        if ($wasAttached) { Say "ISO $iso was attached before the lab: left attached"; continue }
        $image = Get-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue
        if ($image -and $image.Attached) { Dismount-DiskImage -ImagePath $iso -ErrorAction Stop | Out-Null; Say "dismounted $iso" }
    }

    # read back: every lab name gone, every before.json name present as it was
    $installed = Get-InstalledInstances
    $listening = Get-ListeningPorts
    foreach ($inst in $labInstances) {
        if (Test-InBefore $before 'Instances' $inst.Name) { continue }
        if ($installed.ContainsKey($inst.Name)) { $failures.Add("$($inst.Name) still installed") }
        foreach ($svc in @("MSSQL`$$($inst.Name)", "SQLAgent`$$($inst.Name)", "SQLTELEMETRY`$$($inst.Name)")) { if (Get-Service -Name $svc -ErrorAction SilentlyContinue) { $failures.Add("service $svc still present") } }
        if (Test-Path -LiteralPath "C:\Program Files\Microsoft SQL Server\MSSQL16.$($inst.Name)") { $failures.Add("folder MSSQL16.$($inst.Name) still present") }
        foreach ($port in @($inst.SqlPort, $inst.EndpointPort)) { if ($listening -contains $port -and $before.ListeningPorts -notcontains $port) { $failures.Add("TCP $port still listening") } }
    }
    if (-not (Test-InBefore $before 'FirewallRules' $ruleName) -and (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) { $failures.Add("rule '$ruleName' still present") }
    if (-not $taskBefore -and (Get-ScheduledTask -TaskName $setupTask -ErrorAction SilentlyContinue)) { $failures.Add("task '$setupTask' still present") }
    foreach ($name in @($before.Instances | ForEach-Object { $_.Name })) { if (-not $installed.ContainsKey($name)) { $failures.Add("before.json instance $name is GONE") } }
    foreach ($svcBefore in @($before.Services)) {
        $svcNow = Get-Service -Name $svcBefore.Name -ErrorAction SilentlyContinue
        if (-not $svcNow) { $failures.Add("before.json service $($svcBefore.Name) is GONE"); continue }
        if ([string]$svcNow.StartType -ne $svcBefore.StartType) { $failures.Add("service $($svcBefore.Name) start type $($svcNow.StartType), was $($svcBefore.StartType)") }
        if ($svcBefore.Status -eq 'Running' -and [string]$svcNow.Status -ne 'Running') {
            $failures.Add("service $($svcBefore.Name) is $($svcNow.Status), was Running")
        }
    }
    $rulesNow = @(Get-NetFirewallRule -Direction Inbound -ErrorAction Stop | ForEach-Object { $_.DisplayName })
    foreach ($ruleBefore in @($before.FirewallRules)) { if ($rulesNow -notcontains $ruleBefore.Name) { $failures.Add("before.json firewall rule '$($ruleBefore.Name)' is GONE") } }
    Say "read back: $(@($before.Services).Count) before.json services, $(@($before.Instances).Count) instances, $(@($before.FirewallRules).Count) rules checked"
    if ($failures.Count -gt 0) {
        foreach ($line in $failures) { Say "NOT CLEAN: $line" }
        Say "VERDICT NOT CLEAN ($($failures.Count)); $LabDir kept (before.json in it)"
        exit 1
    }
    Set-Location -LiteralPath 'C:\'
    foreach ($child in $labChildren) {
        $childPath = Join-Path $LabDir $child
        if (Test-Path -LiteralPath $childPath) { Remove-Item -LiteralPath $childPath -Recurse -Force -ErrorAction Stop }
    }
    $left = @(Get-ChildItem -LiteralPath $LabDir -Force -ErrorAction Stop)
    if ($left.Count -eq 0) { Remove-Item -LiteralPath $LabDir -Force -ErrorAction Stop; Say "VERDICT CLEAN; the lab's files and $LabDir removed" }
    else { Say "VERDICT CLEAN; the lab's files removed; $LabDir kept: it holds $($left.Count) item(s) the lab did not make ($(($left | ForEach-Object { $_.Name }) -join ', '))" }
}

# ---------------------------------------------------------------------------------------------------------------
try {
    switch ($Action) {
        'before' { Invoke-Before }
        'up' { Invoke-Up }
        'status' { if ((Invoke-Status) -ne 'UP') { exit 1 } }
        'down' { Invoke-Down }
    }
    exit 0
} catch {
    Say "FAILED ($Action): $($_.Exception.Message)"
    Say "  at: $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')"
    exit 1
}
