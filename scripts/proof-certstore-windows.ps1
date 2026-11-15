# Proof of task B24n on Windows: pgvigil serve's TLS certificate from the Windows certificate store, its private key
# used where it sits. Run INSIDE the lab's Windows VM from an ELEVATED Windows PowerShell 5.1 (a driver puts the three
# files on the VM and runs it). Everything it makes is named pgvtls (certificates in LocalMachine\My, FriendlyName
# 'pgvtls-proof <part>', subjects CN=pgvtls-...; the local user pgvtlsproof; the folder -Work); all of it is removed at
# the end and read back gone, and a leftover of an earlier run is removed first. SQL Server, DBA Dash, services, the
# firewall and the network are not touched; nothing listens beyond 127.0.0.1.
#   -Exe     <file>   pgvigil.exe for windows/amd64, built from a tree with scripts/proof-certstore-wiring.patch applied
#   -TestExe <file>   the same tree's test binary: GOOS=windows go test -c -o certstore.test.exe ./cmd/pgvigil
#   -Work    <folder> a scratch folder at a drive's root (default C:\pgvtls-proof; removed at the end)
#   -Parts   <list>   default P1,P1b,P2,P3,P4,P5,P6 (P0 and X always run)
# serve pings a migrated repository before it listens (web.Open) and the VM has none: serve's own runs here prove the
# flags and the certificate's selection up to that ping; every handshake is made against the test binary's server,
# which is serve's tls.Config over the same storeServerTLS.
# Expected (written before its first run; NOT run yet - the VM's hour waits for the lead's WIN GO):
#  P0  leftovers removed; the certificates of LocalMachine My / CA / Root and CurrentUser My / CA, the key files of
#      Crypto\Keys and Crypto\RSA\MachineKeys, the local users and the profiles recorded
#  P1  CNG RSA-2048 (Microsoft Software Key Storage Provider, NonExportable) by thumbprint: 7 sign lines ok (pkcs1v15
#      SHA-1 / 256 / 384 / 512, pss SHA-256 / 384 / 512); handshakes TLS 1.2 and TLS 1.3 ok, leaf = the thumbprint,
#      chain=1; 'parallel 64 handshakes=64' ok; serve -tls-thumbprint logs "serve's certificate from the Windows store"
#      with the thumbprint, then stops at "repository ping"
#  P1b root CA -> intermediate CA -> leaf (all CNG RSA): both CAs read back with the CA basic constraint; a client that
#      trusts only the root: handshakes TLS 1.2 and 1.3 ok, chain=2 (leaf + intermediate), root_sent=false
#  P2  -tls-subject pgvtls-renew.proof.local, two leaves of the P1b intermediate (NotBefore 2 days and 1 day ago): the
#      1-day one served first; a third (NotBefore 5 minutes ago) added while the server runs: 'renewed leaf=<third>'
#      within 90 s and no handshake failed meanwhile
#  P3  CNG ECDSA P-256 and P-384: 4 sign lines ok each (SHA-1 / 256 / 384 / 512 digests); handshakes TLS 1.2 and 1.3
#      ok for each
#  P4  a legacy CryptoAPI key (Microsoft RSA SChannel Cryptographic Provider) is written down either way: served (both
#      handshakes ok) or refused with the provider sentence ('legacy CryptoAPI provider', said only when the key's
#      CERT_KEY_PROV_INFO names a CryptoAPI provider type, or 'is not a CNG key'), holding no 'winapi error #', and its
#      reason (CNG's own words) printed and not an access refusal (this run is elevated)
#  P5  the local user pgvtlsproof (in Users only) and a P1-shaped certificate:
#      a  as the user (a process started with its password): serve refused 'does not open for <COMPUTER>\pgvtlsproof'
#         and 'pgvigil cert -grant-key-access <thumbprint>'; the grant run as the user refused 'run it from an
#         elevated prompt'
#      b  the key opened on a thread impersonating the user's logon (the test binary): refused
#      then, elevated: -account Users refused 'names many accounts'; the grant with -account .\pgvtlsproof prints
#      "The key's access list now (the undo" then 'Granted:', its read-back SDDL holds one Read entry for the user's
#      SID, and the key file's own ACL holds one Allow entry with Read for it; a second grant 'Already granted'; then b
#      opens the key, and a: the test server as the user completes both handshakes and serve as the user logs the
#      store line and stops at the repository ping
#      c  as the user, -tls-subject of the P5 name with a renewal added (same name, a later NotBefore, its key NOT
#         granted): serve serves the P5 certificate and warns 'a newer certificate's private key does not open for
#         <COMPUTER>\pgvtlsproof, so the older certificate <P5> is served'; after the renewal's grant, serve serves the
#         renewal with no such warning (B24n review 1)
#      (a and c that cannot start over this door are one SKIP each with the reason, never a FAIL: b carries the key's
#      access check then, and the last line says how many were skipped)
#  P6  an expired pin: serve refused 'expired at <date> (valid from <date>): renew it'; a thumbprint no certificate has:
#      'matches no certificate in the LocalMachine\My store'; -tls-subject of the expired one: 'none can be served
#      (expired: 1'
#  X   every certificate made removed with its key, each key file gone; the stores, Crypto\Keys and
#      Crypto\RSA\MachineKeys hold the names they held at P0; the user, its profile and -Work gone (read back)
#  The last line: 'proof-certstore-windows: OK' (exit 0), 'proof-certstore-windows: OK (not run over this door: <n>)'
#  (exit 0; P5a / P5c could not start a process as the user) or 'proof-certstore-windows: FAIL (<n>)' (exit 1).
# P7 (the flags refused off Windows) is not this script's: go test ./cmd/pgvigil/ -run TestStoreWindowsOnly on Linux.
param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$TestExe,
    [string]$Work = 'C:\pgvtls-proof',
    [string]$Parts = 'P1,P1b,P2,P3,P4,P5,P6'
)
$ErrorActionPreference = 'Stop'
$script:failed = 0
function Fail([string]$msg) { Write-Host "FAIL $msg"; $script:failed++ }
$script:doorSkips = 0
function Skip-Door([string]$msg) { Write-Host "SKIP $msg"; $script:doorSkips++ }
function Ok([string]$msg) { Write-Host "ok   $msg" }
function Note([string]$msg) { Write-Host "note $msg" }
$wanted = @($Parts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
function Want([string]$part) { return $wanted -contains $part }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'FAIL run it elevated'; exit 1 }
foreach ($file in $Exe, $TestExe) { if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Write-Host "FAIL no file $file"; exit 1 } }
if ($Work -notmatch '^[A-Za-z]:\\[A-Za-z0-9._-]+$') { Write-Host "FAIL -Work must be one plain folder at a drive's root (it is removed at the end): $Work"; exit 1 }
foreach ($part in $wanted) { if (@('P1', 'P1b', 'P2', 'P3', 'P4', 'P5', 'P6') -notcontains $part) { Write-Host "FAIL unknown part $part"; exit 1 } }

$Tag = 'pgvtls'
$UserName = 'pgvtlsproof'
$Ksp = 'Microsoft Software Key Storage Provider'
$CngDir = Join-Path $env:ProgramData 'Microsoft\Crypto\Keys'
$CapiDir = Join-Path $env:ProgramData 'Microsoft\Crypto\RSA\MachineKeys'
$StorePaths = @('Cert:\LocalMachine\My', 'Cert:\LocalMachine\CA', 'Cert:\LocalMachine\Root', 'Cert:\CurrentUser\My', 'Cert:\CurrentUser\CA')
$Me = $env:COMPUTERNAME
$script:madeKeys = @()
$script:userSid = ''
$script:userPlain = ''
$script:userSecure = $null
$script:proofCa = $null

# ---- helpers ----------------------------------------------------------------------------------------------------
function Format-Arg([string]$arg) {
    if ($arg -notmatch '[\s"]') { return $arg }
    return '"' + (($arg -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}
# a process with its output read (never PowerShell's 2>&1 under Stop); -AsUser starts it as the proof's user
function Start-Exe([string]$FilePath, [string[]]$ArgList, [hashtable]$EnvVars = @{}, [switch]$AsUser, [int]$Seconds = 120) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (@($ArgList) | ForEach-Object { Format-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $Work
    foreach ($key in $EnvVars.Keys) { $psi.EnvironmentVariables[$key] = [string]$EnvVars[$key] }
    if ($AsUser) { $psi.UserName = $UserName; $psi.Domain = $Me; $psi.Password = $script:userSecure; $psi.LoadUserProfile = $false }
    $proc = [System.Diagnostics.Process]::Start($psi)
    return @{ Proc = $proc; Out = $proc.StandardOutput.ReadToEndAsync(); Err = $proc.StandardError.ReadToEndAsync(); Seconds = $Seconds }
}
function Wait-Exe($run) {
    if (-not $run.Proc.WaitForExit($run.Seconds * 1000)) {
        try { $run.Proc.Kill() } catch { Note "kill: $($_.Exception.Message)" }
        $null = $run.Proc.WaitForExit(10000)
        return @{ Exit = -1; Text = "TIMEOUT after $($run.Seconds) s`n" + $run.Out.Result + $run.Err.Result }
    }
    $run.Proc.WaitForExit()
    return @{ Exit = $run.Proc.ExitCode; Text = $run.Out.Result + $run.Err.Result }
}
function Invoke-Exe([string]$FilePath, [string[]]$ArgList, [hashtable]$EnvVars = @{}, [switch]$AsUser, [int]$Seconds = 120) {
    return Wait-Exe (Start-Exe -FilePath $FilePath -ArgList $ArgList -EnvVars $EnvVars -AsUser:$AsUser -Seconds $Seconds)
}
function Test-Args([string]$Name, [int]$Seconds) { return @("-test.run=^$Name`$", '-test.count=1', '-test.v', "-test.timeout=$($Seconds)s") }
function Invoke-Test([string]$Name, [hashtable]$EnvVars, [switch]$AsUser, [int]$Seconds = 240) {
    return Invoke-Exe -FilePath $TestBin -ArgList (Test-Args $Name $Seconds) -EnvVars $EnvVars -AsUser:$AsUser -Seconds ($Seconds + 30)
}
function Invoke-Serve([string[]]$More, [switch]$AsUser) {
    return Invoke-Exe -FilePath $ExeBin -ArgList (@('serve', '-config', $Cfg, '-listen', '127.0.0.1:0') + $More) -AsUser:$AsUser -Seconds 60
}
# the test binary's result: exit 0, exactly okLines 'CS ... ok' lines, no FAIL, no refusal, no skip; patterns each on a line
function Test-Result([string]$part, $res, [int]$okLines, [string[]]$patterns = @()) {
    $lines = @($res.Text -split "`r?`n")
    $cs = @($lines | Where-Object { $_ -match '^CS ' })
    foreach ($line in $cs) { Write-Host "     $part | $line" }
    $okCount = @($cs | Where-Object { $_ -match ' ok$' }).Count
    $badCount = @($cs | Where-Object { $_ -match ' FAIL ' -or $_ -match '^CS refused' }).Count
    $skipCount = @($lines | Where-Object { $_ -match '^--- SKIP' }).Count
    if ($res.Exit -eq 0 -and $okCount -eq $okLines -and $badCount -eq 0 -and $skipCount -eq 0) { Ok "$part $okCount line(s) ok, exit 0" }
    else {
        Fail "$part exit $($res.Exit), ok lines $okCount of $okLines, failed $badCount, skipped $skipCount"
        foreach ($line in ($lines | Select-Object -Last 15)) { Write-Host "     $part > $line" }
    }
    foreach ($pat in $patterns) { Test-Line $part $res.Text $pat }
}
function Test-Line([string]$part, [string]$text, [string]$pat) {
    $hit = @($text -split "`r?`n" | Where-Object { $_ -match $pat } | Select-Object -First 1)
    if ($hit.Count -gt 0) { Ok "$part $($hit[0].Trim())" } else { Fail "$part no line matches '$pat'" }
}
# serve's refusal or its stop at the repository ping: exit not 0 and every pattern on a line
function Test-Serve([string]$part, $res, [string[]]$patterns) {
    if ($res.Exit -eq 0 -or $res.Exit -eq -1) {
        Fail "$part serve exit $($res.Exit) (a refusal or the repository ping's failure expected)"
        foreach ($line in (@($res.Text -split "`r?`n") | Select-Object -Last 10)) { Write-Host "     $part > $line" }
    }
    foreach ($pat in $patterns) { Test-Line $part $res.Text $pat }
}
# the key file a certificate's private key sits in (CNG: Crypto\Keys; CryptoAPI: Crypto\RSA\MachineKeys)
function Get-KeyFile($cert) {
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    try {
        if ($rsa -is [System.Security.Cryptography.RSACng]) { return (Join-Path $CngDir $rsa.Key.UniqueName) }
        if ($rsa -is [System.Security.Cryptography.RSACryptoServiceProvider]) { return (Join-Path $CapiDir $rsa.CspKeyContainerInfo.UniqueKeyContainerName) }
    } finally { if ($rsa) { $rsa.Dispose() } }
    $ec = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($cert)
    try { if ($ec -is [System.Security.Cryptography.ECDsaCng]) { return (Join-Path $CngDir $ec.Key.UniqueName) } } finally { if ($ec) { $ec.Dispose() } }
    return ''
}
function New-ProofCert([string]$Part, [hashtable]$Extra) {
    $params = @{ CertStoreLocation = 'Cert:\LocalMachine\My'; FriendlyName = "$Tag-proof $Part"; KeyExportPolicy = 'NonExportable' }
    foreach ($key in $Extra.Keys) { $params[$key] = $Extra[$key] }
    $cert = New-SelfSignedCertificate @params
    $keyFile = Get-KeyFile $cert
    if ($keyFile) {
        $script:madeKeys += $keyFile
        if (-not (Test-Path -LiteralPath $keyFile)) { Note "$Part the key file $keyFile is not where the provider names it" }
    } else { Note "$Part the key's file was not found by name" }
    Note "$Part made $($cert.Thumbprint) $($cert.Subject) $($cert.NotBefore.ToUniversalTime().ToString('s'))Z .. $($cert.NotAfter.ToUniversalTime().ToString('s'))Z key $keyFile"
    return $cert
}
function Export-Der($cert, [string]$name) {
    $path = Join-Path $Work $name
    $null = Export-Certificate -Cert $cert -FilePath $path -Type CERT
    return $path
}
# the P1b CA pair, made once: P1b and P2 use it
function Get-ProofCa {
    if ($script:proofCa) { return $script:proofCa }
    $caExtra = @{ Provider = $Ksp; KeyAlgorithm = 'RSA'; KeyLength = 2048; Type = 'Custom'; KeyUsage = @('CertSign', 'CRLSign', 'DigitalSignature'); KeyUsageProperty = 'Sign'; NotBefore = (Get-Date).AddDays(-3) }
    $rootExtra = $caExtra.Clone(); $rootExtra.Subject = "CN=$Tag-proof root"; $rootExtra.TextExtension = @('2.5.29.19={critical}{text}ca=1&pathlength=1')
    $root = New-ProofCert 'CA root' $rootExtra
    $midExtra = $caExtra.Clone(); $midExtra.Subject = "CN=$Tag-proof intermediate"; $midExtra.TextExtension = @('2.5.29.19={critical}{text}ca=1&pathlength=0'); $midExtra.Signer = $root
    $mid = New-ProofCert 'CA intermediate' $midExtra
    foreach ($ca in $root, $mid) {
        $ext = @($ca.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' })
        $isCa = $false
        if ($ext.Count -gt 0) { $isCa = (New-Object System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension($ext[0], $ext[0].Critical)).CertificateAuthority }
        if ($isCa) { Ok "CA $($ca.Subject) carries the CA basic constraint" } else { Fail "CA $($ca.Subject) has no CA basic constraint: a chain through it does not verify" }
    }
    $script:proofCa = @{ Root = $root; Mid = $mid; RootCer = (Export-Der $root 'root.cer') }
    return $script:proofCa
}
function Get-Snapshot {
    return @{
        Stores   = @($StorePaths | ForEach-Object { $store = $_; Get-ChildItem -LiteralPath $store | ForEach-Object { "$store $($_.Thumbprint)" } })
        Keys     = @(Get-ChildItem -LiteralPath $CngDir -Force -Name)
        Capi     = @(Get-ChildItem -LiteralPath $CapiDir -Force -Name)
        Users    = @(Get-LocalUser | ForEach-Object { $_.Name })
        Profiles = @(Get-CimInstance -ClassName Win32_UserProfile | ForEach-Object { $_.SID })
    }
}
function Compare-Names([string]$what, [string[]]$before, [string[]]$after) {
    $new = @($after | Where-Object { $before -notcontains $_ })
    $gone = @($before | Where-Object { $after -notcontains $_ })
    if ($new.Count -eq 0 -and $gone.Count -eq 0) { Ok "X $what as at P0 ($(@($after).Count))" }
    else { Fail "X $what differs from P0: new [$($new -join ', ')] gone [$($gone -join ', ')]" }
}
# every pgvtls certificate in the stores (its key with it), the user and its profile, the work folder
function Remove-ProofThings {
    foreach ($store in $StorePaths) {
        foreach ($cert in @(Get-ChildItem -LiteralPath $store | Where-Object { $_.Subject -like "*$Tag*" -or $_.FriendlyName -like "$Tag*" })) {
            if ($cert.HasPrivateKey) { Remove-Item -LiteralPath $cert.PSPath -DeleteKey } else { Remove-Item -LiteralPath $cert.PSPath }
            Note "removed $store $($cert.Thumbprint) $($cert.Subject)"
        }
    }
    $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if ($user) {
        $sid = $user.SID.Value
        foreach ($prof in @(Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$sid'")) { Remove-CimInstance -InputObject $prof; Note "removed the profile $($prof.LocalPath)" }
        Remove-LocalUser -Name $UserName
        Note "removed the local user $UserName ($sid)"
    }
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
}

# ---- P0 ---------------------------------------------------------------------------------------------------------
try { Remove-ProofThings } catch { Write-Host "FAIL P0 a leftover did not go: $($_.Exception.Message)"; exit 1 }
$before = Get-Snapshot
Ok "P0 recorded: $($before.Stores.Count) certificate(s) in the stores, $($before.Keys.Count) CNG and $($before.Capi.Count) CryptoAPI key file(s), $($before.Users.Count) user(s), $($before.Profiles.Count) profile(s)"
$null = New-Item -ItemType Directory -Path $Work
$ExeBin = Join-Path $Work 'pgvigil.exe'; Copy-Item -LiteralPath $Exe -Destination $ExeBin
$TestBin = Join-Path $Work 'certstore.test.exe'; Copy-Item -LiteralPath $TestExe -Destination $TestBin
# a repository that does not answer: serve chooses its certificate before it pings the repository
$Cfg = Join-Path $Work 'pgvigil.yaml'
Set-Content -LiteralPath $Cfg -Encoding Ascii -Value "repository:`n  dsn: postgres://pgvigil@127.0.0.1:9/pgvigil?connect_timeout=5`ninstances: []`n"
$version = Invoke-Exe -FilePath $ExeBin -ArgList @('version')
Note "pgvigil version: $($version.Text.Trim())"
$RsaKsp = @{ Provider = $Ksp; KeyAlgorithm = 'RSA'; KeyLength = 2048 }
function With([hashtable]$base, [hashtable]$more) { $all = $base.Clone(); foreach ($key in $more.Keys) { $all[$key] = $more[$key] }; return $all }
$storeLine = "serve's certificate from the Windows store"

try {
    # ---- P1 a CNG RSA certificate by thumbprint ------------------------------------------------------------------
    if (Want 'P1') {
        try {
            $p1 = New-ProofCert 'P1' (With $RsaKsp @{ DnsName = "$Tag-p1.proof.local" })
            $cer = Export-Der $p1 'p1.cer'
            Test-Result 'P1 sign' (Invoke-Test 'TestCertstoreProofSign' @{ PGVIGIL_CS_THUMB = $p1.Thumbprint }) 7
            $res = Invoke-Test 'TestCertstoreProofServe' @{ PGVIGIL_CS_SERVE = '1'; PGVIGIL_CS_THUMB = $p1.Thumbprint; PGVIGIL_CS_ROOT = $cer; PGVIGIL_CS_NAME = "$Tag-p1.proof.local"; PGVIGIL_CS_PARALLEL = '64' }
            Test-Result 'P1 serve' $res 3 @("handshake TLS 1\.2 leaf=$($p1.Thumbprint) chain=1 root_sent=false ok", "handshake TLS 1\.3 leaf=$($p1.Thumbprint) chain=1 root_sent=false ok", 'parallel 64 handshakes=64 ok')
            Test-Serve 'P1 pgvigil serve' (Invoke-Serve @('-tls-thumbprint', $p1.Thumbprint)) @("$storeLine.*thumbprint=$($p1.Thumbprint).*chain=1", 'repository ping')
        } catch { Fail "P1 $($_.Exception.Message)" }
    }

    # ---- P1b a chain: root -> intermediate -> leaf ---------------------------------------------------------------
    if (Want 'P1b') {
        try {
            $ca = Get-ProofCa
            $leaf = New-ProofCert 'P1b' (With $RsaKsp @{ DnsName = "$Tag-p1b.proof.local"; Signer = $ca.Mid })
            $res = Invoke-Test 'TestCertstoreProofServe' @{ PGVIGIL_CS_SERVE = '1'; PGVIGIL_CS_THUMB = $leaf.Thumbprint; PGVIGIL_CS_ROOT = $ca.RootCer; PGVIGIL_CS_NAME = "$Tag-p1b.proof.local" }
            Test-Result 'P1b' $res 2 @("handshake TLS 1\.2 leaf=$($leaf.Thumbprint) chain=2 root_sent=false ok", "handshake TLS 1\.3 leaf=$($leaf.Thumbprint) chain=2 root_sent=false ok")
        } catch { Fail "P1b $($_.Exception.Message)" }
    }

    # ---- P2 subject mode: the newest served, a renewal followed with no restart -----------------------------------
    if (Want 'P2') {
        $run = $null
        try {
            $ca = Get-ProofCa
            $subj = "$Tag-renew.proof.local"
            $null = New-ProofCert 'P2 older' (With $RsaKsp @{ DnsName = $subj; Signer = $ca.Mid; NotBefore = (Get-Date).AddDays(-2) })
            $newer = New-ProofCert 'P2 newer' (With $RsaKsp @{ DnsName = $subj; Signer = $ca.Mid; NotBefore = (Get-Date).AddDays(-1) })
            $renew = Join-Path $Work 'p2.renew'
            $run = Start-Exe -FilePath $TestBin -ArgList (Test-Args 'TestCertstoreProofServe' 300) -Seconds 330 -EnvVars @{ PGVIGIL_CS_SERVE = '1'; PGVIGIL_CS_SUBJECT = $subj; PGVIGIL_CS_ROOT = $ca.RootCer; PGVIGIL_CS_NAME = $subj; PGVIGIL_CS_RENEW = $renew }
            $firstFile = "$renew.first"
            for ($waited = 0; $waited -lt 120 -and -not (Test-Path -LiteralPath $firstFile) -and -not $run.Proc.HasExited; $waited++) { Start-Sleep -Seconds 1 }
            if (Test-Path -LiteralPath $firstFile) {
                $firstLeaf = (Get-Content -LiteralPath $firstFile -Raw).Trim()
                if ($firstLeaf -eq $newer.Thumbprint) { Ok "P2 the newest of two served first: $firstLeaf" } else { Fail "P2 first served $firstLeaf, not the newest $($newer.Thumbprint)" }
                $third = New-ProofCert 'P2 renewal' (With $RsaKsp @{ DnsName = $subj; Signer = $ca.Mid; NotBefore = (Get-Date).AddMinutes(-5) })
                Set-Content -LiteralPath "$renew.tmp" -Value $third.Thumbprint -NoNewline -Encoding Ascii
                Move-Item -LiteralPath "$renew.tmp" -Destination $renew
                Test-Result 'P2' (Wait-Exe $run) 3 @("renewed leaf=$($third.Thumbprint) after=\d+s handshakes=\d+ ok")
            } else {
                Fail 'P2 the server did not report its first leaf within 120 s'
                $res = Wait-Exe $run
                foreach ($line in (@($res.Text -split "`r?`n") | Select-Object -Last 15)) { Write-Host "     P2 > $line" }
            }
        } catch { Fail "P2 $($_.Exception.Message)" } finally {
            # a server still running would hold -Work's files at X
            if ($run -and -not $run.Proc.HasExited) { try { $run.Proc.Kill(); $null = $run.Proc.WaitForExit(10000) } catch { Note "P2 kill: $($_.Exception.Message)" } }
        }
    }

    # ---- P3 CNG ECDSA P-256 and P-384 ------------------------------------------------------------------------------
    if (Want 'P3') {
        foreach ($curve in 'P256', 'P384') {
            try {
                $name = "$Tag-p3-$($curve.ToLower()).proof.local"
                $ec = New-ProofCert "P3 $curve" @{ DnsName = $name; Provider = $Ksp; KeyAlgorithm = "ECDSA_nist$curve"; CurveExport = 'CurveName'; KeyUsage = 'DigitalSignature' }
                $cer = Export-Der $ec "p3-$curve.cer"
                Test-Result "P3 $curve sign" (Invoke-Test 'TestCertstoreProofSign' @{ PGVIGIL_CS_THUMB = $ec.Thumbprint }) 4
                Test-Result "P3 $curve serve" (Invoke-Test 'TestCertstoreProofServe' @{ PGVIGIL_CS_SERVE = '1'; PGVIGIL_CS_THUMB = $ec.Thumbprint; PGVIGIL_CS_ROOT = $cer; PGVIGIL_CS_NAME = $name }) 2
            } catch { Fail "P3 $curve $($_.Exception.Message)" }
        }
    }

    # ---- P4 a legacy CryptoAPI key: written down either way ------------------------------------------------------
    if (Want 'P4') {
        try {
            $legacy = New-ProofCert 'P4' @{ DnsName = "$Tag-p4.proof.local"; Provider = 'Microsoft RSA SChannel Cryptographic Provider'; KeySpec = 'KeyExchange'; KeyAlgorithm = 'RSA'; KeyLength = 2048 }
            $cer = Export-Der $legacy 'p4.cer'
            $res = Invoke-Test 'TestCertstoreProofServe' @{ PGVIGIL_CS_SERVE = '1'; PGVIGIL_CS_THUMB = $legacy.Thumbprint; PGVIGIL_CS_ROOT = $cer; PGVIGIL_CS_NAME = "$Tag-p4.proof.local" }
            $refusal = @($res.Text -split "`r?`n" | Where-Object { $_ -match '^CS refused: ' } | Select-Object -First 1)
            if ($refusal.Count -gt 0) {
                $why = if ($refusal[0] -match 'does not open for [^:]+: (.+?)\. Give that account') { $Matches[1] } else { '' }
                if ($refusal[0] -notmatch 'legacy CryptoAPI provider|is not a CNG key' -or $refusal[0] -match 'winapi error #') { Fail "P4 refused without the provider sentence: $($refusal[0])" }
                elseif ($why -match 'denied|0x80090010') { Fail "P4 refused for access, not for its provider (this run is elevated): $why" }
                else { Ok "P4 a legacy CryptoAPI key is REFUSED; CNG said: $(if ($why) { $why } else { '(not a CNG key)' })" }
            } else {
                Test-Result 'P4 served' $res 2
                Note 'P4 a legacy CryptoAPI key is SERVED: CNG opened it and it signs as TLS 1.3 needs'
            }
            $serve = Invoke-Serve @('-tls-thumbprint', $legacy.Thumbprint)
            Note "P4 serve said: $(@($serve.Text -split "`r?`n" | Where-Object { $_ -match 'Windows store|pgvigil failed' }) -join ' / ')"
        } catch { Fail "P4 $($_.Exception.Message)" }
    }

    # ---- P5 a non-admin user: refused, the grant, then served -----------------------------------------------------
    if (Want 'P5') {
        try {
            $p5 = New-ProofCert 'P5' (With $RsaKsp @{ DnsName = "$Tag-p5.proof.local" })
            $cer = Export-Der $p5 'p5.cer'
            $thumb = $p5.Thumbprint
            $keyFile = Get-KeyFile $p5
            # the password lives in this process only: never printed, written or put on a command line
            $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
            $script:userPlain = (-join (1..20 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })) + 'q7#Z'
            $script:userSecure = ConvertTo-SecureString -String $script:userPlain -AsPlainText -Force
            $null = New-LocalUser -Name $UserName -Password $script:userSecure -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -Description 'pgvigil B24n proof: removed at its end'
            $usersGroup = Get-LocalGroup -SID 'S-1-5-32-545'
            Add-LocalGroupMember -Group $usersGroup -Member $UserName
            $script:userSid = (Get-LocalUser -Name $UserName).SID.Value
            $groups = @(Get-LocalGroup | Where-Object { $group = $_; try { @(Get-LocalGroupMember -Group $group -ErrorAction Stop | Where-Object { $_.SID.Value -eq $script:userSid }).Count -gt 0 } catch { Note "P5 the members of $($group.Name) do not read: $($_.Exception.Message)"; $false } } | ForEach-Object { $_.SID.Value })
            if (($groups -join ',') -ne 'S-1-5-32-545') { throw "$UserName is in the groups [$($groups -join ', ')], not in Users alone" }
            Ok "P5 local user $UserName ($script:userSid) in Users only"
            $asWho = [regex]::Escape($Me) + '\\{1,2}' + $UserName
            $asUserEnv = @{ PGVIGIL_CS_ASUSER = $UserName; PGVIGIL_CS_ASPASS = $script:userPlain; PGVIGIL_CS_THUMB = $thumb }
            # a: a process as the user (CreateProcessWithLogonW); a door that refuses it is one FAIL, b goes on
            $runAs = $true
            try { $serveAs = Invoke-Serve @('-tls-thumbprint', $thumb) -AsUser } catch { $runAs = $false; Skip-Door "P5a a process as $UserName did not start over this door: $($_.Exception.Message)" }
            if ($runAs -and $serveAs.Exit -eq -1073741502) { $runAs = $false; Skip-Door 'P5a a process as the user did not initialise (0xC0000142: the session gives it no window station)' }
            if ($runAs) {
                Test-Serve 'P5a serve as the user' $serveAs @("does not open for $asWho", "pgvigil cert -grant-key-access $thumb")
                Test-Serve 'P5a grant as the user' (Invoke-Exe -FilePath $ExeBin -ArgList @('cert', '-grant-key-access', $thumb, '-account', ".\$UserName") -AsUser) @('run it from an elevated prompt')
            }
            Test-Result 'P5b before the grant' (Invoke-Test 'TestCertstoreProofAsUser' (With $asUserEnv @{ PGVIGIL_CS_EXPECT = 'refused' })) 1 @('asuser .* refused ok')
            $broad = Invoke-Exe -FilePath $ExeBin -ArgList @('cert', '-grant-key-access', $thumb, '-account', 'Users')
            Test-Serve 'P5 -account Users' $broad @('names many accounts')
            $grant = Invoke-Exe -FilePath $ExeBin -ArgList @('cert', '-grant-key-access', $thumb, '-account', ".\$UserName")
            foreach ($line in @($grant.Text -split "`r?`n" | Where-Object { $_ })) { Write-Host "     P5 grant | $line" }
            if ($grant.Exit -ne 0) { Fail "P5 the grant exit $($grant.Exit)" }
            Test-Line 'P5 grant' $grant.Text "The key's access list now \(the undo"
            Test-Line 'P5 grant' $grant.Text '^Granted: '
            $back = [regex]::Match($grant.Text, 'The access list read back: (\S+)').Groups[1].Value
            $entries = [regex]::Matches($back, "\(A;[^;]*;(FR|0x120089);;;$([regex]::Escape($script:userSid))\)").Count
            if ($entries -eq 1) { Ok "P5 the read-back SDDL holds one Read entry for $script:userSid" } else { Fail "P5 the read-back SDDL holds $entries Read entries for $script:userSid : $back" }
            if ($keyFile -and (Test-Path -LiteralPath $keyFile)) {
                $rules = @((Get-Acl -LiteralPath $keyFile).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq $script:userSid })
                $readRight = [System.Security.AccessControl.FileSystemRights]::Read
                $allowRead = @($rules | Where-Object { $_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights -band $readRight) -eq $readRight })
                if ($rules.Count -eq 1 -and $allowRead.Count -eq 1) { Ok "P5 the key file's ACL holds one Allow entry with Read for the user ($($allowRead[0].FileSystemRights))" }
                else { Fail "P5 the key file's ACL holds $($rules.Count) entries for the user, $($allowRead.Count) Allow Read" }
            } else { Fail "P5 the key file is not found ($keyFile): its ACL is not read back" }
            Test-Line 'P5 second grant' (Invoke-Exe -FilePath $ExeBin -ArgList @('cert', '-grant-key-access', $thumb, '-account', ".\$UserName")).Text '^Already granted: '
            Test-Result 'P5b after the grant' (Invoke-Test 'TestCertstoreProofAsUser' (With $asUserEnv @{ PGVIGIL_CS_EXPECT = 'opens' })) 1 @("asuser .* opens leaf=$thumb ok")
            if ($runAs) {
                Test-Result 'P5a the test server as the user' (Invoke-Test 'TestCertstoreProofServe' @{ PGVIGIL_CS_SERVE = '1'; PGVIGIL_CS_THUMB = $thumb; PGVIGIL_CS_ROOT = $cer; PGVIGIL_CS_NAME = "$Tag-p5.proof.local" } -AsUser) 2
                Test-Serve 'P5a serve as the user after the grant' (Invoke-Serve @('-tls-thumbprint', $thumb) -AsUser) @("$storeLine.*thumbprint=$thumb", 'repository ping')
                # c: a renewal whose key the user cannot open is warned about, the older one served; then granted, served
                $renewal = New-ProofCert 'P5c renewal' (With $RsaKsp @{ DnsName = "$Tag-p5.proof.local"; NotBefore = (Get-Date).AddSeconds(-2) })
                if ($renewal.NotBefore -le $p5.NotBefore) { Fail "P5c the renewal's NotBefore $($renewal.NotBefore) is not after P5's $($p5.NotBefore)" }
                $warnLine = "newer certificate's private key does not open for $asWho, so the older certificate $thumb is served"
                $p5cHeld = Invoke-Serve @('-tls-subject', "$Tag-p5.proof.local") -AsUser
                Test-Serve 'P5c serve as the user, the renewal not granted' $p5cHeld @("$storeLine.*thumbprint=$thumb", $warnLine, 'repository ping')
                Test-Line 'P5c grant the renewal' (Invoke-Exe -FilePath $ExeBin -ArgList @('cert', '-grant-key-access', $renewal.Thumbprint, '-account', ".\$UserName")).Text '^Granted: '
                $p5cServed = Invoke-Serve @('-tls-subject', "$Tag-p5.proof.local") -AsUser
                Test-Serve 'P5c serve as the user, the renewal granted' $p5cServed @("$storeLine.*thumbprint=$($renewal.Thumbprint)", 'repository ping')
                if ($p5cServed.Text -match 'newer certificate.s private key does not open') { Fail 'P5c the warning stays after the renewal was granted' } else { Ok 'P5c no warning once the renewal is granted' }
            } else { Skip-Door 'P5c (a process as the user did not start over this door)' }
        } catch { Fail "P5 $($_.Exception.Message)" }
    }

    # ---- P6 refusals: an expired pin, an absent thumbprint, a subject with only an expired certificate -------------
    if (Want 'P6') {
        try {
            $expired = New-ProofCert 'P6 expired' (With $RsaKsp @{ DnsName = "$Tag-p6.proof.local"; NotBefore = (Get-Date).AddDays(-30); NotAfter = (Get-Date).AddDays(-1) })
            Test-Serve 'P6 expired pin' (Invoke-Serve @('-tls-thumbprint', $expired.Thumbprint)) @('expired at \S+ \(valid from \S+\): renew it')
            $held = @(Get-ChildItem -LiteralPath 'Cert:\LocalMachine\My' | ForEach-Object { $_.Thumbprint })
            do { $absent = -join (1..40 | ForEach-Object { '0123456789ABCDEF'[(Get-Random -Maximum 16)] }) } while ($held -contains $absent)
            Test-Serve 'P6 absent thumbprint' (Invoke-Serve @('-tls-thumbprint', $absent)) @('matches no certificate in the LocalMachine\\{1,2}My store')
            Test-Serve 'P6 expired subject' (Invoke-Serve @('-tls-subject', "$Tag-p6.proof.local")) @('none can be served \(expired: 1')
        } catch { Fail "P6 $($_.Exception.Message)" }
    }
} finally {
    # ---- X everything made removed and read back ------------------------------------------------------------------
    try { Remove-ProofThings } catch { Fail "X removal: $($_.Exception.Message)" }
    $script:userPlain = ''
    $script:userSecure = $null
    foreach ($keyFile in $script:madeKeys) { if (Test-Path -LiteralPath $keyFile) { Fail "X a key file is left: $keyFile" } }
    if ($script:madeKeys.Count -gt 0) { Ok "X $($script:madeKeys.Count) key file(s) made, each checked gone" }
    $after = Get-Snapshot
    Compare-Names 'the certificate stores' $before.Stores $after.Stores
    Compare-Names 'Crypto\Keys' $before.Keys $after.Keys
    Compare-Names 'Crypto\RSA\MachineKeys' $before.Capi $after.Capi
    Compare-Names 'the local users' $before.Users $after.Users
    Compare-Names 'the user profiles' $before.Profiles $after.Profiles
    if ($script:userSid -and @(Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$script:userSid'").Count -gt 0) { Fail "X a profile of $script:userSid is left" }
    if (Test-Path -LiteralPath $Work) { Fail "X $Work is left" } else { Ok "X $Work gone" }
}
if ($script:failed -eq 0) {
    if ($script:doorSkips -gt 0) { Write-Host "proof-certstore-windows: OK (not run over this door: $script:doorSkips)"; exit 0 }
    Write-Host 'proof-certstore-windows: OK'; exit 0
}
Write-Host "proof-certstore-windows: FAIL ($script:failed)"
exit 1
