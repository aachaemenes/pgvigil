# proof-install-account-win.ps1 - Windows PowerShell 5.1 or 7, elevated, on a throwaway lab VM ONLY (dba-lab-win
# through the WIN queue): the Windows service's account (RELNOTES L131 / L142 / L150). It installs and removes the
# service pgvigil, makes and deletes one local test account (and the profile its logon made), and grants and then
# removes that account's 'Log on as a service' right; it refuses to start on a machine where the service pgvigil,
# %ProgramData%\pgvigil\pgvigil.yaml or repo.dsn, or %ProgramFiles%\pgvigil\pgvigil.exe already exists (it removes what
# it makes, never what it found: a filled repo.dsn would point V1's service at a real repository).
#   powershell.exe -NoProfile -File scripts\proof-install-account-win.ps1 -Exe C:\proof\pgvigil.exe
# Rows:
#   V1 the default install runs the service as NT SERVICE\pgvigil and the service manager logs it on (no 1069)
#   N0 -user .\<test account> without -password-stdin is refused naming -password-stdin, and no service is made
#   N1 the password piped to -password-stdin: the service runs as the account, the install's line says the right is held
#   N2 secedit's export lists the account under SeServiceLogonRight - by name or '*SID', either read as its SID (the
#      export writes an account that resolves by its name); the service manager logs it on (no 1069)
#   N3 the password is in no output of the install and in no file under %ProgramData%\pgvigil
#   R1 'pgvigil install' run again without -user keeps the account (and its stored password: logged on again)
#   U1 'pgvigil uninstall -all -dry-run' lists the right as kept; 'pgvigil uninstall' removes the service, the right stays
#   P0 (Windows PowerShell 5.1) a control: PowerShell's own pipe - the form install.ps1 used before it wrote the bytes
#      itself - hands a native reader other bytes than the password's UTF-8 ('P1D False'), so P1d can tell; NOT RUN
#      under PowerShell 7, whose pipe is UTF-8
#   P1 install.ps1's password write, a password holding a 2-byte and a 3-byte character: the service manager logs the
#      account on
#   P1d install.ps1's write, in its own scope shape, hands a native reader exactly the password's UTF-8 and CRLF, the
#      line end -password-stdin strips ('P1D True <bytes> crlf bom 0'; the reader compares a SHA-256, never prints the
#      bytes)
#   P1a the same two rows with an ASCII-only password (no regression): logged on, 'P1D True <bytes> crlf bom 0'
#   P1u the 2-byte / 3-byte password again under a UTF-8 console code page (Console.InputEncoding 65001, as chcp 65001):
#      logged on, and the reader sees the BOM .NET Framework's stdin writer puts first ('P1D True <bytes> crlf bom 1');
#      NOT RUN, with its words, where the console's code page cannot be set (the UTF-8 console case then not proven)
#   P1l neither password is on the command line (rebuilt from the same arguments; the guard on install.ps1's own write
#      line is P1d's target pin), in an environment variable, in a file written under
#      %TEMP% or %ProgramData%\pgvigil since the P rows began, in a line the installs printed, or in this proof's own
#      transcript of the P rows (its log of them)
#   G1 -print-gmsa prints the script and changes nothing; install.ps1 parses and its -Help returns
#   Z  the undo: the right removed (LsaRemoveAccountRights) and read back gone from a secedit export that succeeded, the
#      account deleted, the account's profile removed (Win32_UserProfile) and its folder gone, the service and its files
#      gone - each read back. A profile whose hive is still loaded at the 90 s cap, its removal refused as in use and its
#      account read back deleted, is LEFT (said so, not failed): the turn's clean grades it and the next turn's orphans
#      step removes it
# Not proven here: a real gMSA (no Active Directory in the labs), a Group Policy refresh over the grant.
# Exit 0 = every row as stated; 1 = a row differs; 2 = refused to start.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Script = ''
)
$ErrorActionPreference = 'Stop'
# the default beside this script's folder, computed here: $PSScriptRoot reads empty inside param() under Windows
# PowerShell 5.1 when the script is started by -File from a WMI-started process (the WIN turn 11-19, its exit 1 at :21)
if (-not $Script) { $Script = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'docs\install.ps1' }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'REFUSED: run elevated'; exit 2 }
if (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) { Write-Host 'REFUSED: the service pgvigil exists here - this proof runs on a machine without pgvigil'; exit 2 }
if (-not (Test-Path -LiteralPath $Exe)) { Write-Host "REFUSED: no $Exe"; exit 2 }
foreach ($left in (Join-Path $env:ProgramData 'pgvigil\pgvigil.yaml'), (Join-Path $env:ProgramData 'pgvigil\repo.dsn'), (Join-Path $env:ProgramFiles 'pgvigil\pgvigil.exe')) {
    if (Test-Path -LiteralPath $left) { Write-Host "REFUSED: $left exists (this proof removes what it makes, never what it found)"; exit 2 }
}

function Invoke-Native([scriptblock]$cmd) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $cmd 2>&1 | ForEach-Object { "$_" }; return @{ Code = $LASTEXITCODE; Out = ($out -join "`n") } } finally { $ErrorActionPreference = $eap }
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PgvProofLsa {
    [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public int Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES attrs, int access, out IntPtr handle);
    [DllImport("advapi32.dll")] static extern uint LsaRemoveAccountRights(IntPtr handle, byte[] sid, bool all, LSA_UNICODE_STRING[] rights, int count);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
    public static int Remove(byte[] sid, string right) {
        var attrs = new LSA_OBJECT_ATTRIBUTES(); attrs.Length = Marshal.SizeOf(attrs);
        IntPtr h; uint st = LsaOpenPolicy(IntPtr.Zero, ref attrs, 0x00000800, out h);
        if (st != 0) return LsaNtStatusToWinError(st);
        var s = new LSA_UNICODE_STRING(); s.Buffer = Marshal.StringToHGlobalUni(right); s.Length = (ushort)(right.Length * 2); s.MaximumLength = (ushort)(s.Length + 2);
        try { st = LsaRemoveAccountRights(h, sid, false, new[] { s }, 1); return st == 0 ? 0 : LsaNtStatusToWinError(st); }
        finally { Marshal.FreeHGlobal(s.Buffer); LsaClose(h); }
    }
}
'@

$failed = 0
$tx = $null; $txOn = $false; $txRead = $false; $ieOrig = $null   # the P rows' transcript and the console's input code page: the outer finally ends both
function Row([string]$name, [bool]$ok, [string]$what) {
    if ($ok) { Write-Host "OK   $name $what" } else { Write-Host "FAIL $name $what"; $script:failed++ }
}
# the SIDs secedit lists under SeServiceLogonRight: Ok false when the export itself failed (an empty list then proves
# nothing), Sids empty when the right lists none
function Get-LogonRightSids {
    $inf = Join-Path $env:TEMP ("pgvproof-" + [Guid]::NewGuid().ToString('N') + '.inf')
    $res = Invoke-Native { & secedit.exe /export /cfg $inf /areas USER_RIGHTS /quiet }
    try {
        if ($res.Code -ne 0 -or -not (Test-Path -LiteralPath $inf)) { return @{ Ok = $false; Sids = @() } }
        $line = Get-Content -LiteralPath $inf | Where-Object { $_ -match '^SeServiceLogonRight\s*=' } | Select-Object -First 1
        $raw = @()
        if ($line) { $raw = @(($line -split '=', 2)[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        # secedit writes '*' before a SID and an account that resolves by its name: either form read as its SID
        $list = @($raw | ForEach-Object {
                $e = $_.TrimStart('*')
                if ($e -match '^S-1-') { $e } else {
                    try { (New-Object Security.Principal.NTAccount($e)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { $e }
                }
            })
        return @{ Ok = $true; Sids = $list; Raw = ($raw -join ', ') }
    } finally { Remove-Item -LiteralPath $inf -Force -ErrorAction SilentlyContinue }
}
# one start of the service, read: sc.exe's exit (1069 = a logon failure) and the System log's logon-failure events for
# pgvigil since the start (7000 the service did not start, 7038 the logon failed, 7041 the logon type not granted)
function Get-StartResult {
    $t0 = Get-Date
    $res = Invoke-Native { & sc.exe start pgvigil }
    Start-Sleep -Seconds 3
    $logonFailed = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7000, 7038, 7041; StartTime = $t0 } -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'pgvigil' }).Count
    $startName = (Get-CimInstance Win32_Service -Filter "Name='pgvigil'").StartName
    # the newest logon failure's own words (the account and the reason, never a password)
    $said = ''
    if ($logonFailed) {
        $m = "$(@(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7000, 7038, 7041; StartTime = $t0 } -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'pgvigil' })[0].Message)" -replace '\s+', ' '
        $said = $m.Substring(0, [Math]::Min(220, $m.Length))
    }
    $null = Invoke-Native { & sc.exe stop pgvigil }
    Start-Sleep -Seconds 2
    return @{ LoggedOn = (($res.Code -ne 1069) -and ($logonFailed -eq 0)); StartName = $startName; What = "sc start $($res.Code), logon-failure events $logonFailed$(if ($said) { ': ' + $said })" }
}
# the native reader P0, P1d, P1a and P1u hand bytes to: the SHA-256 of what came, without a leading BOM (EF BB BF: what
# .NET Framework's stdin writer puts first under a UTF-8 console code page; pgvigil drops it) and without its trailing
# CR / LF, compared with PGV_P1D_WANT; prints 'P1D <equal> <bytes> <line end: crlf, none or other:<hex>> bom <0|1>' -
# never the bytes
$P1DReader = '$in = [Console]::OpenStandardInput(); $ms = New-Object IO.MemoryStream; $in.CopyTo($ms); $b = $ms.ToArray(); $s = 0; if ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191) { $s = 3 }; $n = $b.Length; while ($n -gt $s -and ($b[$n - 1] -eq 10 -or $b[$n - 1] -eq 13)) { $n-- }; $h = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($b, $s, $n - $s)).Replace(''-'', '''').ToLower(); $e = if ($b.Length - $n -eq 2 -and $b[$n] -eq 13 -and $b[$n + 1] -eq 10) { ''crlf'' } elseif ($b.Length -eq $n) { ''none'' } else { ''other:'' + (($b[$n..($b.Length - 1)] | ForEach-Object { $_.ToString(''x2'') }) -join '''') }; ''P1D '' + ($h -eq $env:PGV_P1D_WANT) + '' '' + ($n - $s) + '' '' + $e + '' bom '' + [int]($s -eq 3)'
function Get-P1DWant([string]$secret) { [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash((New-Object System.Text.UTF8Encoding $false).GetBytes($secret))).Replace('-', '').ToLower() }
function Get-P1DLine($out) { "$out" -split "`n" | Where-Object { $_ -match '^P1D ' } | Select-Object -First 1 }
# install.ps1's functions as the file defines them (parsed out of it): the password write and what it calls
$InstallFunctions = @('Invoke-Native', 'Invoke-NativeStdin', 'ConvertTo-NativeArgument', 'Invoke-PgvigilInstall')
function Get-InstallFunctionText([string[]]$names = $InstallFunctions) {
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$parseErrors)
    $defs = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $names -contains $node.Name }, $true)
    return (($defs | ForEach-Object { $_.Extent.Text }) -join "`n")
}
function Start-AndRead([string]$row) {
    $st = Get-StartResult
    Row $row $st.LoggedOn "the service manager logged pgvigil on as $($st.StartName) ($($st.What))"
    return $st.StartName
}
# P1d's reader: install.ps1's password write as the file defines it, the same scope shape, its native command swapped
# for the reader above; the write's own line is found in the file or the row says it is not there
function Invoke-ScriptPipeReader([string]$secret) {
    $text = Get-InstallFunctionText
    $target = 'Invoke-NativeStdin $exePath @(''install'', ''-user'', $account, ''-password-stdin'') $bytes'
    if (-not $text.Contains($target)) { return @{ Code = -1; Out = "P1D the write's line '$target' is not in install.ps1" } }
    $text = $text.Replace($target, 'Invoke-NativeStdin ''powershell.exe'' @(''-NoProfile'', ''-NonInteractive'', ''-EncodedCommand'', $readerCmd) $bytes')
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($P1DReader))
    $env:PGV_P1D_WANT = Get-P1DWant $secret
    try {
        $body = 'param($exePath, $acctName, $secretText, $readerCmd)' + "`n" + $text + "`n" +
            'function Read-Host { param([switch]$AsSecureString, [Parameter(Position = 0)][string]$Prompt) ConvertTo-SecureString $secretText -AsPlainText -Force }' + "`n" +
            'Invoke-PgvigilInstall $exePath $acctName'
        return & ([scriptblock]::Create($body)) 'reader.exe' '.\pgvp-reader' $secret $encoded
    } finally { Remove-Item Env:\PGV_P1D_WANT -ErrorAction SilentlyContinue }
}
# P0's control: the same reader fed through PowerShell's own pipe to a native command, as install.ps1 did before
function Invoke-OldPipeReader([string]$secret) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($P1DReader))
    $env:PGV_P1D_WANT = Get-P1DWant $secret
    try { return Get-P1DLine (Invoke-Native { $secret | & powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded }).Out }
    finally { Remove-Item Env:\PGV_P1D_WANT -ErrorAction SilentlyContinue }
}
# install.ps1's own password write, run in a scope of its own: its functions as the file defines them, Read-Host
# answering the given password
function Invoke-ScriptPipe([string]$account, [string]$secret) {
    $text = Get-InstallFunctionText
    $body = 'param($exePath, $acctName, $secretText)' + "`n" + $text + "`n" +
        'function Read-Host { param([switch]$AsSecureString, [Parameter(Position = 0)][string]$Prompt) ConvertTo-SecureString $secretText -AsPlainText -Force }' + "`n" +
        'Invoke-PgvigilInstall $exePath $acctName'
    return & ([scriptblock]::Create($body)) $Exe $account $secret
}

$name = 'pgvp' + ([Guid]::NewGuid().ToString('N').Substring(0, 8))
$pw = 'Pv9!' + [Guid]::NewGuid().ToString('N')
$acct = ".\$name"
$sid = $null
try {
    # V1
    $res = Invoke-Native { & $Exe install }
    $sn = Start-AndRead 'V1'
    Row 'V1' ($res.Code -eq 0 -and $sn -eq 'NT SERVICE\pgvigil') "the default install (exit $($res.Code)) runs as '$sn'"
    $null = Invoke-Native { & $Exe uninstall }

    New-LocalUser -Name $name -Password (ConvertTo-SecureString $pw -AsPlainText -Force) -PasswordNeverExpires -Description 'pgvigil proof account (deleted by the proof)' | Out-Null
    $sid = (New-Object Security.Principal.NTAccount("$env:COMPUTERNAME\$name")).Translate([Security.Principal.SecurityIdentifier])
    Write-Host "     the test account $name ($($sid.Value)) made"

    # N0
    $res = Invoke-Native { & $Exe install -user $acct }
    Row 'N0' ($res.Code -ne 0 -and $res.Out -match 'password-stdin' -and -not (Get-Service -Name pgvigil -ErrorAction SilentlyContinue)) "without -password-stdin: exit $($res.Code), refused naming it, no service"

    # N1 / N2 / N3
    $res = Invoke-Native { $pw | & $Exe install -user $acct -password-stdin }
    Row 'N1' ($res.Code -eq 0 -and $res.Out -match 'Log on as a service' -and $res.Out -match 'read back held') "the install with -password-stdin: exit $($res.Code), the right's line printed"
    $rights = Get-LogonRightSids
    Row 'N2' ($rights.Ok -and $rights.Sids -contains $sid.Value) "secedit (export ok $($rights.Ok)) lists $($sid.Value) under SeServiceLogonRight, by name or SID (its entries: $("$($rights.Raw)".Substring(0, [Math]::Min(200, "$($rights.Raw)".Length))))"
    $sn = Start-AndRead 'N2'
    Row 'N2' ($sn -match [regex]::Escape($name)) "the service's account '$sn'"
    $inFiles = @(Get-ChildItem -LiteralPath (Join-Path $env:ProgramData 'pgvigil') -Recurse -File -ErrorAction SilentlyContinue | Select-String -SimpleMatch -Pattern $pw -List).Count
    Row 'N3' (($res.Out -notmatch [regex]::Escape($pw)) -and $inFiles -eq 0) "the password in the install's output: no; in files under ProgramData\pgvigil: $inFiles"

    # R1
    $res = Invoke-Native { & $Exe install }
    $sn = Start-AndRead 'R1'
    Row 'R1' ($res.Code -eq 0 -and $sn -match [regex]::Escape($name)) "the re-run without -user (exit $($res.Code)) keeps '$sn'"

    # U1
    $res = Invoke-Native { & $Exe uninstall -all -dry-run }
    Row 'U1' ($res.Out -match "Log on as a service' right of" -and $res.Out -match 'another service may run as') "uninstall -all -dry-run lists the right as kept"
    $res = Invoke-Native { & $Exe uninstall }
    $rights = Get-LogonRightSids
    Row 'U1' ($res.Code -eq 0 -and -not (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) -and $rights.Ok -and $rights.Sids -contains $sid.Value) "uninstall (exit $($res.Code)): the service gone, the right still held (export ok $($rights.Ok))"

    # P0 / P1 / P1d / P1a / P1l: install.ps1's password write with a password holding a 2-byte and a 3-byte character
    # (the account's password changed to it), then with an ASCII-only one; the P rows' own transcript read for both
    $pwU = 'Pv9!' + [char]0x00E4 + [char]0x20AC + [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $pwA = 'Pv9!' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $pStart = (Get-Date).AddSeconds(-2)
    $tx = Join-Path $env:TEMP ('pgvproof-p-' + [Guid]::NewGuid().ToString('N') + '.txt')
    try { Start-Transcript -LiteralPath $tx -Force | Out-Null; $txOn = $true } catch { Write-Host "     the P rows' transcript did not start: $($_.Exception.Message)" }
    $outs = @()
    Set-LocalUser -Name $name -Password (ConvertTo-SecureString $pwU -AsPlainText -Force)
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $old = Invoke-OldPipeReader $pwU
        Row 'P0' ("$old" -match '^P1D False ') "PowerShell's own pipe, the form install.ps1 used before, hands a native reader other bytes than the password's UTF-8 under $($PSVersionTable.PSVersion): $(if ($old) { $old } else { 'no answer' })"
    } else {
        Write-Host "NOT RUN P0 (PowerShell $($PSVersionTable.PSVersion): its pipe is UTF-8 already; the control needs powershell.exe 5.1)"
    }
    $res = Invoke-ScriptPipe $acct $pwU; $outs += "$($res.Out)"
    $st = Get-StartResult
    Row 'P1' ($res.Code -eq 0 -and $st.LoggedOn) "install.ps1's password write, a 2-byte and a 3-byte character, under $($PSVersionTable.PSVersion): install exit $($res.Code), logged on as $($st.StartName) ($($st.What))"
    $null = Invoke-Native { & $Exe uninstall }
    $wantU = (New-Object System.Text.UTF8Encoding $false).GetBytes($pwU).Length
    $rd = Invoke-ScriptPipeReader $pwU; $outs += "$($rd.Out)"
    $rdLine = Get-P1DLine $rd.Out
    Row 'P1d' ($rdLine -eq "P1D True $wantU crlf bom 0") "install.ps1's write hands a native reader the password's UTF-8 ($wantU bytes) and CRLF under $($PSVersionTable.PSVersion): $(if ($rdLine) { $rdLine } else { 'no answer: ' + $rd.Out })"
    Set-LocalUser -Name $name -Password (ConvertTo-SecureString $pwA -AsPlainText -Force)
    $res = Invoke-ScriptPipe $acct $pwA; $outs += "$($res.Out)"
    $st = Get-StartResult
    Row 'P1a' ($res.Code -eq 0 -and $st.LoggedOn) "install.ps1's password write, an ASCII-only password: install exit $($res.Code), logged on as $($st.StartName) ($($st.What))"
    $null = Invoke-Native { & $Exe uninstall }
    $rd = Invoke-ScriptPipeReader $pwA; $outs += "$($rd.Out)"
    $rdLine = Get-P1DLine $rd.Out
    Row 'P1a' ($rdLine -eq "P1D True $($pwA.Length) crlf bom 0") "install.ps1's write hands a native reader the ASCII password ($($pwA.Length) bytes) and CRLF: $(if ($rdLine) { $rdLine } else { 'no answer: ' + $rd.Out })"
    # P1u: the 2-byte / 3-byte password again under a UTF-8 console code page
    try { $ieOrig = [Console]::InputEncoding; [Console]::InputEncoding = New-Object System.Text.UTF8Encoding $true } catch {
        $ieOrig = $null; Write-Host "NOT RUN P1u (the console's input code page cannot be set here: $($_.Exception.Message)) - the UTF-8 console case NOT PROVEN"
    }
    if ($null -ne $ieOrig) {
        try {
            Set-LocalUser -Name $name -Password (ConvertTo-SecureString $pwU -AsPlainText -Force)
            $res = Invoke-ScriptPipe $acct $pwU; $outs += "$($res.Out)"
            $st = Get-StartResult
            Row 'P1u' ($res.Code -eq 0 -and $st.LoggedOn) "install.ps1's password write under the console code page $([Console]::InputEncoding.CodePage): install exit $($res.Code), logged on as $($st.StartName) ($($st.What))"
            $null = Invoke-Native { & $Exe uninstall }
            $rd = Invoke-ScriptPipeReader $pwU; $outs += "$($rd.Out)"
            $rdLine = Get-P1DLine $rd.Out
            Row 'P1u' ($rdLine -eq "P1D True $wantU crlf bom 1") "under that code page the reader gets a BOM, then the password's UTF-8 ($wantU bytes) and CRLF: $(if ($rdLine) { $rdLine } else { 'no answer: ' + $rd.Out })"
        } finally { [Console]::InputEncoding = $ieOrig; $ieOrig = $null }
    }
    if ($txOn) { try { Stop-Transcript | Out-Null } catch { } ; $txOn = $false; $txRead = $true }
    # P1l: every place either password could have been left (counts only, never the value)
    . ([scriptblock]::Create((Get-InstallFunctionText @('ConvertTo-NativeArgument'))))   # the proof keeps its own Invoke-Native
    $cmdLine = (@(@('install', '-user', $acct, '-password-stdin') | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $inCmd = $cmdLine.Contains($pwU) -or $cmdLine.Contains($pwA)
    $envVals = [Environment]::GetEnvironmentVariables()
    $inEnv = @($envVals.Keys | Where-Object { "$($envVals[$_])".Contains($pwU) -or "$($envVals[$_])".Contains($pwA) }).Count
    $files = @(@($env:TEMP, (Join-Path $env:ProgramData 'pgvigil')) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object {
            Get-ChildItem -LiteralPath $_ -Recurse -File -Force -ErrorAction SilentlyContinue } | Where-Object { $_.LastWriteTime -ge $pStart -and $_.FullName -ne $tx -and $_.Length -lt 20MB })
    $inFiles = @($files | Where-Object { @(Select-String -LiteralPath $_.FullName -SimpleMatch -Pattern $pwU, $pwA -List -ErrorAction SilentlyContinue).Count }).Count
    $inOut = @($outs | Where-Object { $_.Contains($pwU) -or $_.Contains($pwA) }).Count
    $txLines = if ($txRead -and (Test-Path -LiteralPath $tx)) { @(Get-Content -LiteralPath $tx).Count } else { -1 }
    $inTx = if ($txLines -ge 0) { @(Select-String -LiteralPath $tx -SimpleMatch -Pattern $pwU, $pwA -ErrorAction SilentlyContinue).Count } else { -1 }
    Remove-Item -LiteralPath $tx -Force -ErrorAction SilentlyContinue
    Row 'P1l' ((-not $inCmd) -and $inEnv -eq 0 -and $inFiles -eq 0 -and $inOut -eq 0 -and $txLines -gt 0 -and $inTx -eq 0) "neither password on the command line (rebuilt from the same arguments; the guard on install.ps1's own write line is P1d's target pin): $(-not $inCmd); in the environment: $inEnv; in files written since the P rows began under %TEMP% and %ProgramData%\pgvigil: $inFiles of $($files.Count); in the installs' lines: $inOut; in the P rows' transcript: $(if ($txLines -ge 0) { "$inTx ($txLines lines read)" } else { 'not read (it did not start)' })"
    $pwU = $null; $pwA = $null

    # G1
    $res = Invoke-Native { & $Exe install -print-gmsa -user 'CORP\pgvigil-gmsa$' }
    Row 'G1' ($res.Code -eq 0 -and $res.Out -match 'New-ADServiceAccount' -and -not (Get-Service -Name pgvigil -ErrorAction SilentlyContinue)) "-print-gmsa printed the script (exit $($res.Code)), no service made"
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$parseErrors)
    $help = (Invoke-Native { & powershell.exe -NoProfile -File $Script -Help }).Out
    Row 'G1' ($parseErrors.Count -eq 0 -and $help -match 'ServiceAccount') "install.ps1 parses under $($PSVersionTable.PSVersion) ($($parseErrors.Count) errors) and -Help names -ServiceAccount"
} finally {
    # a P row that threw left the transcript running or the console's code page changed: both ended here, the file removed
    if ($txOn) { try { Stop-Transcript | Out-Null } catch { } }
    if ($tx) { Remove-Item -LiteralPath $tx -Force -ErrorAction SilentlyContinue }
    if ($null -ne $ieOrig) { try { [Console]::InputEncoding = $ieOrig } catch { } }
    # Z: the undo, each step read back
    if (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) { $null = Invoke-Native { & $Exe uninstall } }
    $null = Invoke-Native { & $Exe uninstall -purge }
    if ($sid) {
        $bytes = New-Object byte[] ($sid.BinaryLength); $sid.GetBinaryForm($bytes, 0)
        $rc = [PgvProofLsa]::Remove($bytes, 'SeServiceLogonRight')
        $left = Get-LogonRightSids
        Row 'Z' ($rc -eq 0 -and $left.Ok -and -not ($left.Sids -contains $sid.Value)) "the right removed from $($sid.Value) (code $rc) and read back gone (export ok $($left.Ok))"
        # the account first (Remove-LocalUser leaves its profile: C:\Users\<name> and its registry key), then the profile
        if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) { Remove-LocalUser -Name $name }
        $acctGone = -not (Get-LocalUser -Name $name -ErrorAction SilentlyContinue)
        Row 'Z' $acctGone "the test account $name deleted"
        # its hive stays loaded a while after the service's process ends: the delete waits for it (up to 90 s, read)
        $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.SID -eq $sid.Value })
        $profilePath = if ($profiles.Count) { $profiles[0].LocalPath } else { '' }
        $waited = 0
        $loaded = { @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.SID -eq $sid.Value -and $_.Loaded }).Count -gt 0 }
        while ($waited -lt 90 -and (& $loaded)) { Start-Sleep -Seconds 3; $waited += 3 }
        $stillLoaded = & $loaded
        if ($profiles.Count) {
            if ($stillLoaded) { Write-Host "     the profile's hive still loaded after $waited s (90 at most)" } else { Write-Host "     the profile's hive unloaded after $waited s of waiting" }
        }
        $removeError = ''
        foreach ($pr in @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.SID -eq $sid.Value })) {
            try { Remove-CimInstance -InputObject $pr -ErrorAction Stop } catch { $removeError = $_.Exception.Message }
        }
        $leftProfiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.SID -eq $sid.Value }).Count
        $removed = $leftProfiles -eq 0 -and (-not $profilePath -or -not (Test-Path -LiteralPath $profilePath))
        $inUse = $removeError -match 'being used by another process'
        if (-not $removed -and $stillLoaded -and $inUse -and $acctGone) {
            Write-Host "LEFT Z the account's profile $profilePath ($($sid.Value)): its hive still loaded after $waited s, its removal refused as in use ('$removeError'), its account deleted - the turn's clean grades it and the next turn's orphans step removes it"
        } else {
            Row 'Z' $removed "the account's profile removed ($($profiles.Count) found$(if ($profilePath) { ', ' + $profilePath }); left $leftProfiles$(if ($removeError) { '; the removal: ' + $removeError }))"
        }
    } else {
        if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) { Remove-LocalUser -Name $name }
        Row 'Z' (-not (Get-LocalUser -Name $name -ErrorAction SilentlyContinue)) "the test account $name deleted"
    }
    Row 'Z' (-not (Get-Service -Name pgvigil -ErrorAction SilentlyContinue)) 'no service pgvigil left'
    $pw = $null
}
if ($failed -eq 0) { Write-Host 'PASS: every row'; exit 0 }
Write-Host "FAIL: $failed row(s)"; exit 1
