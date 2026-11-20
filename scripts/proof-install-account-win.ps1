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
#   N2 secedit's export lists the account's SID under SeServiceLogonRight; the service manager logs it on (no 1069)
#   N3 the password is in no output of the install and in no file under %ProgramData%\pgvigil
#   R1 'pgvigil install' run again without -user keeps the account (and its stored password: logged on again)
#   U1 'pgvigil uninstall -all -dry-run' lists the right as kept; 'pgvigil uninstall' removes the service, the right stays
#   P0 (Windows PowerShell 5.1) install.ps1's own password pipe WITHOUT its UTF-8 line, the account's password holding a
#      non-ASCII character: the service is made, and the service manager's logon FAILS (the password arrived with a
#      '?' in place of that character); NOT RUN under PowerShell 7, whose pipe is UTF-8 already
#   P1 install.ps1's password pipe as it is, the same password: the service manager logs the account on
#   G1 -print-gmsa prints the script and changes nothing; install.ps1 parses and its -Help returns
#   Z  the undo: the right removed (LsaRemoveAccountRights) and read back gone from a secedit export that succeeded, the
#      account's profile removed (Win32_UserProfile) and its folder gone, the account deleted, the service and its files
#      gone - each read back
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
        $list = @()
        if ($line) { $list = @(($line -split '=', 2)[1].Split(',') | ForEach-Object { $_.Trim().TrimStart('*') }) }
        return @{ Ok = $true; Sids = $list }
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
    $null = Invoke-Native { & sc.exe stop pgvigil }
    Start-Sleep -Seconds 2
    return @{ LoggedOn = (($res.Code -ne 1069) -and ($logonFailed -eq 0)); StartName = $startName; What = "sc start $($res.Code), logon-failure events $logonFailed" }
}
function Start-AndRead([string]$row) {
    $st = Get-StartResult
    Row $row $st.LoggedOn "the service manager logged pgvigil on as $($st.StartName) ($($st.What))"
    return $st.StartName
}
# install.ps1's own password pipe, run in a scope of its own: its Invoke-Native and Invoke-PgvigilInstall as the file
# defines them (parsed out of it), Read-Host answering the given password; -WithoutUtf8 drops the $OutputEncoding line
function Invoke-ScriptPipe([string]$account, [string]$secret, [switch]$WithoutUtf8) {
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$parseErrors)
    $defs = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and ($node.Name -eq 'Invoke-Native' -or $node.Name -eq 'Invoke-PgvigilInstall') }, $true)
    $text = ($defs | ForEach-Object { $_.Extent.Text }) -join "`n"
    if ($WithoutUtf8) { $text = [regex]::Replace($text, '(?m)^\s*\$OutputEncoding = .*$', '') }
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
    Row 'N2' ($rights.Ok -and $rights.Sids -contains $sid.Value) "secedit (export ok $($rights.Ok)) lists $($sid.Value) under SeServiceLogonRight"
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

    # P0 / P1: install.ps1's password pipe with a non-ASCII password (the account's password changed to it)
    $pwU = 'Pv9!' + [char]0x00E4 + [Guid]::NewGuid().ToString('N').Substring(0, 12)
    Set-LocalUser -Name $name -Password (ConvertTo-SecureString $pwU -AsPlainText -Force)
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $res = Invoke-ScriptPipe $acct $pwU -WithoutUtf8
        $st = Get-StartResult
        Row 'P0' ($res.Code -eq 0 -and -not $st.LoggedOn) "install.ps1's pipe without its UTF-8 line under $($PSVersionTable.PSVersion): install exit $($res.Code), the logon FAILED as expected: $(-not $st.LoggedOn) ($($st.What))"
        $null = Invoke-Native { & $Exe uninstall }
    } else {
        Write-Host "NOT RUN P0 (PowerShell $($PSVersionTable.PSVersion): its pipe is UTF-8 already; run the proof under powershell.exe 5.1 for P0)"
    }
    $res = Invoke-ScriptPipe $acct $pwU
    $st = Get-StartResult
    Row 'P1' ($res.Code -eq 0 -and $st.LoggedOn) "install.ps1's pipe as it is under $($PSVersionTable.PSVersion): install exit $($res.Code), logged on as $($st.StartName) ($($st.What))"
    $null = Invoke-Native { & $Exe uninstall }
    $pwU = $null

    # G1
    $res = Invoke-Native { & $Exe install -print-gmsa -user 'CORP\pgvigil-gmsa$' }
    Row 'G1' ($res.Code -eq 0 -and $res.Out -match 'New-ADServiceAccount' -and -not (Get-Service -Name pgvigil -ErrorAction SilentlyContinue)) "-print-gmsa printed the script (exit $($res.Code)), no service made"
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$parseErrors)
    $help = (Invoke-Native { & powershell.exe -NoProfile -File $Script -Help }).Out
    Row 'G1' ($parseErrors.Count -eq 0 -and $help -match 'ServiceAccount') "install.ps1 parses under $($PSVersionTable.PSVersion) ($($parseErrors.Count) errors) and -Help names -ServiceAccount"
} finally {
    # Z: the undo, each step read back
    if (Get-Service -Name pgvigil -ErrorAction SilentlyContinue) { $null = Invoke-Native { & $Exe uninstall } }
    $null = Invoke-Native { & $Exe uninstall -purge }
    if ($sid) {
        $bytes = New-Object byte[] ($sid.BinaryLength); $sid.GetBinaryForm($bytes, 0)
        $rc = [PgvProofLsa]::Remove($bytes, 'SeServiceLogonRight')
        $left = Get-LogonRightSids
        Row 'Z' ($rc -eq 0 -and $left.Ok -and -not ($left.Sids -contains $sid.Value)) "the right removed from $($sid.Value) (code $rc) and read back gone (export ok $($left.Ok))"
        # the profile the service's logon made (C:\Users\<name> and its registry key): Remove-LocalUser leaves both
        $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.SID -eq $sid.Value })
        $profilePath = if ($profiles.Count) { $profiles[0].LocalPath } else { '' }
        $profiles | Remove-CimInstance -ErrorAction SilentlyContinue
        $leftProfiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.SID -eq $sid.Value }).Count
        Row 'Z' ($leftProfiles -eq 0 -and (-not $profilePath -or -not (Test-Path -LiteralPath $profilePath))) "the account's profile removed ($($profiles.Count) found$(if ($profilePath) { ', ' + $profilePath }); left $leftProfiles)"
    }
    if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) { Remove-LocalUser -Name $name }
    Row 'Z' (-not (Get-LocalUser -Name $name -ErrorAction SilentlyContinue)) "the test account $name deleted"
    Row 'Z' (-not (Get-Service -Name pgvigil -ErrorAction SilentlyContinue)) 'no service pgvigil left'
    $pw = $null
}
if ($failed -eq 0) { Write-Host 'PASS: every row'; exit 0 }
Write-Host "FAIL: $failed row(s)"; exit 1
