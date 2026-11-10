#requires -Version 7
# Proof of the Windows desktop app (app/, pgvigil-app.exe) on the Windows sandbox, as an administrator and as a
# standard user. Runs on the Linux build machine in pwsh 7; drives the guest over `ssh winsandbox` (the admin
# door, an elevated Windows PowerShell 5.1) and over a password SSH login of a throwaway standard user.
# Needs: go, docker, ssh winsandbox answering, the share ~/winsandbox/shared = \\host.lan\Data in the guest, the
# docker network the guest reaches by container name (the SQL sandbox's compose network), a logged-on desktop
# session of the admin user in the guest (the GUI steps run there through an interactive scheduled task).
#   PGVIGIL_WIN_NET    default mssqlsandbox_default
#   PGVIGIL_WIN_SHARE  default ~/winsandbox/shared
#   PROOF_OUT          a folder for the screenshot and the guest transcripts (default: a temp folder, kept)
#
# Expected (each a line "ok <step>"; any "FAIL" or a missing line fails the proof):
#  build   pgvigil.exe and pgvigil-app.exe (GOOS=windows, -H=windowsgui, version v0.0.1) and the release zip
#          pgvigil-app_v0.0.1_windows_amd64.zip holding both; a PostgreSQL 16 repository seeded with the demo and a
#          UI login IN ROLE pgvigil_reader, pgvigil_auth; a loopback mock of the release feed in the guest
#          answering tag v9.9.9 and counting its requests.
#  A1  as the standard user, `install` (machine-wide) is refused with exit 3 and "needs an elevated prompt";
#      nothing under Program Files or HKLM changes.
#  A2  as the standard user, `install -user` exits 0: the app, pgvigil.exe and a template pgvigil.yaml in
#      %LOCALAPPDATA%\pgvigil, the HKCU Run value '"...\pgvigil-app.exe" -tray', the HKCU Programs and Features
#      entry; the user is not an administrator (Medium integrity).
#  A3  as the standard user, with its own pgvigil.yaml naming the repository: `-check` from the installed copy
#      resolves the config as "user", starts a serve on 127.0.0.1 with the login on (GET / 200, /api/health 401),
#      stops it, and the serve's pid is gone.
#  A4  as the standard user, `uninstall -user -purge` removes the files (the app's own after its exit), the Run
#      value, the Programs and Features entry and HKCU\Software\pgvigil.
#  B1  as the admin, `install -no-update-check` exits 0: %ProgramFiles%\pgvigil holds pgvigil.exe and
#      pgvigil-app.exe; the service pgvigil runs as NT SERVICE\pgvigil (installed, stopped: no instance yet);
#      the HKLM Run value starts the app with -tray; HKLM\Software\Policies\pgvigil\App UpdateCheck = 0;
#      %ProgramData%\pgvigil\app\pgvigil.yaml exists and Users may read, not write, its folder; the HKLM
#      Programs and Features entry's UninstallString names the app.
#  B2  the update check: with the policy at 0, `-check` says "turned off by the administrator" and the mock
#      feed gets no request; with the policy at 1 and UpdateFeed on the mock, `-check` says "update available
#      v9.9.9" and the feed got exactly one request.
#  B3  the machine's config (no user config): `-check` resolves "machine", starts and stops its serve (pid gone).
#  B4  attach: with a serve already listening (started by hand, -no-login) and HKCU AttachURL pointing at it,
#      `-check` says "attached" to that URL and leaves that serve running.
#  B5  the window, in the admin's desktop session: with HKCU Width 1100 / Height 700 and NoLogin 1 set, the app
#      starts, its log says "window opened 1100x700", the WebView2 window (class "webview", title "pgvigil")
#      measures 1100 x 700 and is visible, the UI is on screen (the screenshot), a second launch leaves one app
#      process; the window resized to 1000 x 650 and closed hides it (the app and its serve keep running) and
#      HKCU Width / Height read 1000 / 650; `-quit` ends the app and its log says it stopped the serve, whose pid
#      is gone.
#  C1  as the standard user, on the machine-wide install (no config of its own): `-check` from Program Files
#      resolves "machine" (Users may read it), starts its serve, GET / 200, stops it, pid gone.
#  C2  as the standard user, with HKCU AttachURL at a serve the admin runs (127.0.0.1:18091, its desktop
#      session): `-check` says the serve "runs as another user", does not attach, and starts its own.
#  B6  `uninstall -purge` as the admin: the service, %ProgramFiles%\pgvigil, the HKLM Run value, the Programs and
#      Features entry, the policy key and %ProgramData%\pgvigil\app are gone.
# The guest must hold no pgvigil before the run (the proof refuses it); the admin's own %LOCALAPPDATA%\pgvigil and
# HKCU\Software\pgvigil are set aside and put back; the cleanup stops and removes only what the proof made.
# Not proven here: the standard user's own window (a second interactive desktop logon is not scriptable on the
# sandbox; the window code is the same as B5's), and the CI build on a Windows runner (the release workflow's
# job, the lead's file).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$repoRoot = Split-Path -Parent $PSScriptRoot
$net = if ($env:PGVIGIL_WIN_NET) { $env:PGVIGIL_WIN_NET } else { 'mssqlsandbox_default' }
$share = if ($env:PGVIGIL_WIN_SHARE) { $env:PGVIGIL_WIN_SHARE } else { Join-Path $HOME 'winsandbox/shared' }
$tag = "pgvapp$(Get-Random -Maximum 99999)"
$repoName = "$tag-repo"
$work = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) $tag)
$out = if ($env:PROOF_OUT) { New-Item -ItemType Directory -Force -Path $env:PROOF_OUT } else { New-Item -ItemType Directory -Path (Join-Path $work 'out') }
$shareDir = Join-Path $share $tag
$appVersion = 'v0.0.1'
$pgPw = 'pg' + [guid]::NewGuid().ToString('N').Substring(0, 20)
$stdUser = 'pgvstd' + (Get-Random -Maximum 999)
$stdPw = 'Pv1-' + [guid]::NewGuid().ToString('N').Substring(0, 18)
$script:failed = $false

function Fail([string]$Text) { Write-Host "FAIL: $Text"; $script:failed = $true; throw "proof failed: $Text" }
function Ok([string]$Text) { Write-Host "ok   $Text" }
function Invoke-Native([string]$Exe, [string[]]$ArgList) {
    $o = & $Exe @ArgList 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { Fail "$Exe $($ArgList -join ' '): exit $LASTEXITCODE`n$($o -join "`n")" }
    return $o
}
# Guest runs a script file from the share as the admin (elevated, the key door) or as the standard user (password).
function Invoke-Guest([string]$Script, [string]$Name, [switch]$AsStd) {
    $f = Join-Path $shareDir $Name
    Set-Content -LiteralPath $f -Value $Script -Encoding utf8
    $guestPath = "C:\$tag\$Name"
    $copy = "Copy-Item -LiteralPath '\\host.lan\Data\$tag\$Name' -Destination '$guestPath' -Force"
    $null = & ssh -o ConnectTimeout=15 winsandbox "powershell -NoProfile -Command `"$copy`"" 2>&1
    if ($AsStd) {
        $env:SSH_ASKPASS = $script:askpass; $env:SSH_ASKPASS_REQUIRE = 'force'; $env:DISPLAY = ':0'
        try {
            $o = & ssh -o ConnectTimeout=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=no `
                -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p 2222 "$stdUser@127.0.0.1" "powershell -NoProfile -ExecutionPolicy Bypass -File $guestPath" 2>&1
        } finally { Remove-Item Env:SSH_ASKPASS, Env:SSH_ASKPASS_REQUIRE, Env:DISPLAY -ErrorAction SilentlyContinue }
    } else {
        $o = & ssh -o ConnectTimeout=15 -o LogLevel=ERROR winsandbox "powershell -NoProfile -ExecutionPolicy Bypass -File $guestPath" 2>&1
    }
    $code = $LASTEXITCODE
    $text = ($o | ForEach-Object { "$_".TrimEnd("`r") } | Where-Object { $_ -notmatch '^\*\* ' }) -join "`n"
    Set-Content -LiteralPath (Join-Path $out "$Name.txt") -Value $text
    $text -split "`n" | Where-Object { $_ -match '^(ok|FAIL)' } | ForEach-Object { Write-Host $_ }
    if ($text -match '(?m)^FAIL' -or $code -ne 0) { Fail "guest step $Name, exit $code (transcript: $(Join-Path $out "$Name.txt"))" }
    return $text
}
function Need([string]$Text, [string[]]$Lines) {
    foreach ($l in $Lines) { if ($Text -notmatch "(?m)^ok\s+$([regex]::Escape($l))") { Fail "expected the guest line 'ok $l'" } }
}

# the guest helpers every guest script starts with (Windows PowerShell 5.1)
$guestHead = @'
$ErrorActionPreference = 'Stop'
$proofDir = 'C:\__TAG__'
function Fail([string]$t) { Write-Output "FAIL $t"; exit 1 }
function Ok([string]$t) { Write-Output "ok   $t" }
# a GUI program does not make Windows PowerShell wait: Start-Process -Wait, the output in files
function Run-App([string]$exe, [string[]]$a) {
    $o = Join-Path $env:TEMP ('pgva-' + [guid]::NewGuid().ToString('N') + '.txt'); $e = "$o.err"
    $p = Start-Process -FilePath $exe -ArgumentList $a -Wait -PassThru -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $e
    $t = ((Get-Content $o -ErrorAction SilentlyContinue) + (Get-Content $e -ErrorAction SilentlyContinue)) -join "`n"
    Remove-Item $o, $e -ErrorAction SilentlyContinue
    return @{ Code = $p.ExitCode; Text = $t }
}
function Reg-Value([string]$path, [string]$name) { (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue).$name }
function Pid-Gone([int]$id) { -not (Get-Process -Id $id -ErrorAction SilentlyContinue) }
'@ -replace '__TAG__', $tag

try {
    # ---------- build ----------
    $env:PATH = "$HOME/.local/share/mise/shims:$env:PATH"
    $dist = New-Item -ItemType Directory -Path (Join-Path $work 'dist')
    Push-Location $repoRoot
    try {
        $env:CGO_ENABLED = '0'; $env:GOOS = 'windows'; $env:GOARCH = 'amd64'
        $null = Invoke-Native go @('build', '-trimpath', '-ldflags', "-s -w -X main.version=$appVersion", '-o', (Join-Path $dist 'pgvigil.exe'), './cmd/pgvigil')
        Push-Location app
        try { $null = Invoke-Native go @('build', '-trimpath', '-ldflags', "-s -w -H=windowsgui -X main.version=$appVersion", '-o', (Join-Path $dist 'pgvigil-app.exe'), '.') } finally { Pop-Location }
        Remove-Item Env:GOOS, Env:GOARCH
        $null = Invoke-Native go @('build', '-o', (Join-Path $work 'pgvigil'), './cmd/pgvigil')
    } finally { Pop-Location; Remove-Item Env:CGO_ENABLED, Env:GOOS, Env:GOARCH -ErrorAction SilentlyContinue }
    $zip = Join-Path $work "pgvigil-app_${appVersion}_windows_amd64.zip"
    Compress-Archive -Path (Join-Path $dist '*') -DestinationPath $zip
    $null = Invoke-Native docker @('network', 'inspect', $net)
    $null = Invoke-Native docker @('run', '-d', '--rm', '--name', $repoName, '--network', $net, '-p', '127.0.0.1::5432', '-e', "POSTGRES_PASSWORD=$pgPw", 'postgres:16')
    $port = ((Invoke-Native docker @('port', $repoName, '5432/tcp')) | Select-Object -First 1) -replace '.*:', ''
    for ($i = 0; $i -lt 40; $i++) { & docker exec $repoName pg_isready -U postgres -q 2>$null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep 1 }
    Start-Sleep 2
    $null = Invoke-Native docker @('exec', $repoName, 'psql', '-U', 'postgres', '-XAtqc', 'create database pgvigil')
    $null = Invoke-Native (Join-Path $work 'pgvigil') @('demo', '-dsn', "host=127.0.0.1 port=$port user=postgres password=$pgPw dbname=pgvigil sslmode=disable", '-instances', '3', '-days', '2')
    $null = Invoke-Native docker @('exec', $repoName, 'psql', '-U', 'postgres', '-d', 'pgvigil', '-XAtqc', "create role pgvigil_ui login password '$pgPw' in role pgvigil_reader, pgvigil_auth")
    $null = New-Item -ItemType Directory -Path $shareDir
    Copy-Item $zip $shareDir
    $uiYaml = "repository:`n  dsn: `"host=$repoName port=5432 dbname=pgvigil user=pgvigil_ui password=$pgPw sslmode=disable`"`ninstances: []`n"
    Set-Content -LiteralPath (Join-Path $shareDir 'ui.yaml') -Value $uiYaml -NoNewline
    $script:askpass = Join-Path $work 'askpass.sh'
    Set-Content -LiteralPath (Join-Path $work 'stdpw') -Value $stdPw -NoNewline
    Set-Content -LiteralPath $script:askpass -Value "#!/bin/sh`ncat '$(Join-Path $work 'stdpw')'`n"
    & chmod 700 $script:askpass; & chmod 600 (Join-Path $work 'stdpw')
    Ok "build: pgvigil.exe and pgvigil-app.exe $appVersion, $(Split-Path -Leaf $zip) ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB), repository $repoName seeded"

    # ---------- guest setup (admin): the folder, the zip unpacked, the standard user, the feed mock, a clean slate ----------
    $setup = $guestHead + @'
New-Item -ItemType Directory -Force -Path $proofDir | Out-Null
# the proof folder: the scripts, the unpacked zip, the config; Users read it (the standard user runs from it)
Expand-Archive -LiteralPath "\\host.lan\Data\__TAG__\__ZIP__" -DestinationPath "$proofDir\dist" -Force
Copy-Item "\\host.lan\Data\__TAG__\ui.yaml" "$proofDir\ui.yaml" -Force
icacls $proofDir /grant "*S-1-5-32-545:(OI)(CI)RX" | Out-Null
# the proof installs and removes pgvigil itself: it refuses a guest where pgvigil is already present,
# and touches nothing it did not make (an app running anywhere holds the one-app mutex of its session)
if (Get-Process pgvigil-app -ErrorAction SilentlyContinue) { Fail 'a pgvigil-app runs in the guest: quit it first' }
if (Get-Service pgvigil -ErrorAction SilentlyContinue) { Fail 'a pgvigil service exists before the proof: remove it first (pgvigil uninstall -purge)' }
if (Test-Path "$env:ProgramFiles\pgvigil") { Fail "$env:ProgramFiles\pgvigil exists before the proof" }
foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\pgvigil', 'HKLM:\SOFTWARE\Policies\pgvigil', "$env:ProgramData\pgvigil\app") { if (Test-Path $k) { Fail "$k exists before the proof" } }
# the admin's own app settings and folder are set aside here and put back by the cleanup
if (Test-Path "$env:LOCALAPPDATA\pgvigil") { Rename-Item "$env:LOCALAPPDATA\pgvigil" "pgvigil.saved-__TAG__" }
if (Test-Path 'HKCU:\Software\pgvigil') { & reg.exe export 'HKCU\Software\pgvigil' "$proofDir\hkcu-pgvigil.reg" /y | Out-Null; Remove-Item 'HKCU:\Software\pgvigil' -Recurse }
$sec = ConvertTo-SecureString '__STDPW__' -AsPlainText -Force
New-LocalUser -Name '__STD__' -Password $sec -AccountNeverExpires -PasswordNeverExpires | Out-Null
Add-LocalGroupMember -Group Users -Member '__STD__'
if ((Get-LocalGroupMember Administrators).Name -match '__STD__') { Fail 'the standard user is an administrator' }
Ok "guest ready: $proofDir\dist unpacked, standard user __STD__"
'@
    $setup = $setup -replace '__ZIP__', (Split-Path -Leaf $zip) -replace '__STD__', $stdUser -replace '__STDPW__', $stdPw -replace '__TAG__', $tag
    $null = & ssh -o ConnectTimeout=15 -o LogLevel=ERROR winsandbox "New-Item -ItemType Directory -Force C:\$tag | Out-Null"
    $null = Invoke-Guest $setup 'setup.ps1'

    # ---------- A: the standard user ----------
    $std = $guestHead + @'
$hklmRun = Reg-Value 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'pgvigil'
$pf = Test-Path "$env:ProgramFiles\pgvigil"
$groups = (whoami /groups) -join ' '
if ($groups -match 'S-1-5-32-544' -or $groups -notmatch 'S-1-16-8192') { Fail "not a standard user at Medium integrity: $groups" }
$r = Run-App "$proofDir\dist\pgvigil-app.exe" @('install')
if ($r.Code -ne 3 -or $r.Text -notmatch 'needs an elevated prompt') { Fail "machine install as a standard user: exit $($r.Code): $($r.Text)" }
if ((Reg-Value 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'pgvigil') -ne $hklmRun -or (Test-Path "$env:ProgramFiles\pgvigil") -ne $pf) { Fail 'the refused install changed HKLM or Program Files' }
Ok 'A1 the machine-wide install is refused for a standard user (exit 3), nothing changed'
$r = Run-App "$proofDir\dist\pgvigil-app.exe" @('install', '-user')
if ($r.Code -ne 0) { Fail "install -user: exit $($r.Code): $($r.Text)" }
$d = "$env:LOCALAPPDATA\pgvigil"
foreach ($f in 'pgvigil-app.exe', 'pgvigil.exe', 'pgvigil.yaml') { if (-not (Test-Path "$d\$f")) { Fail "install -user: no $d\$f" } }
$run = Reg-Value 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'pgvigil'
if ($run -ne "`"$d\pgvigil-app.exe`" -tray") { Fail "HKCU Run: '$run'" }
if ((Reg-Value 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\pgvigil' 'UninstallString') -ne "`"$d\pgvigil-app.exe`" uninstall -user") { Fail 'HKCU Programs and Features entry' }
if ((Reg-Value 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'pgvigil') -ne $hklmRun -or (Test-Path "$env:ProgramFiles\pgvigil") -ne $pf) { Fail 'install -user touched HKLM or Program Files' }
Ok "A2 install -user: app, pgvigil.exe and pgvigil.yaml in $d, HKCU Run -tray, HKCU Programs and Features; HKLM and Program Files untouched"
Copy-Item "$proofDir\ui.yaml" "$d\pgvigil.yaml" -Force
$r = Run-App "$d\pgvigil-app.exe" @('-check')
if ($r.Code -ne 0) { Fail "-check as the user: exit $($r.Code): $($r.Text)" }
if ($r.Text -notmatch '\(user\)' -or $r.Text -notmatch 'check: started http://127\.0\.0\.1:\d+/ pid (\d+) login true') { Fail "-check as the user: $($r.Text)" }
$spid = [int]$Matches[1]
if ($r.Text -notmatch 'GET / 200' -or $r.Text -notmatch 'GET /api/health 401' -or $r.Text -notmatch "stopped the serve pid $spid") { Fail "-check as the user: $($r.Text)" }
if (-not (Pid-Gone $spid)) { Fail "the user's serve pid $spid still runs" }
Ok "A3 -check as the user: config (user), serve started on loopback with the login (GET / 200, health 401), stopped, pid $spid gone"
$r = Run-App "$d\pgvigil-app.exe" @('uninstall', '-user', '-purge')
if ($r.Code -ne 0) { Fail "uninstall -user: exit $($r.Code): $($r.Text)" }
Start-Sleep 5
if (Test-Path $d) { Fail "uninstall -user -purge left $d : $((Get-ChildItem $d -Recurse -Force | Select-Object -ExpandProperty Name) -join ', ')" }
if (Reg-Value 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'pgvigil') { Fail 'HKCU Run left' }
if (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\pgvigil') { Fail 'HKCU Programs and Features entry left' }
if (Test-Path 'HKCU:\Software\pgvigil') { Fail 'HKCU\Software\pgvigil left' }
Ok 'A4 uninstall -user -purge: files, Run value, Programs and Features entry and settings gone'
'@
    $t = Invoke-Guest $std 'std.ps1' -AsStd
    Need $t @('A1', 'A2', 'A3', 'A4')

    # ---------- B: the administrator ----------
    $admin1 = $guestHead + @'
# the release feed mock: loopback, tag v9.9.9, one line per request in feed-hits.txt
$feed = @"
`$l = New-Object System.Net.HttpListener; `$l.Prefixes.Add('http://127.0.0.1:18765/'); `$l.Start()
while (`$true) { `$c = `$l.GetContext(); Add-Content '$proofDir\feed-hits.txt' (`$c.Request.Url.AbsolutePath + ' ' + `$c.Request.UserAgent)
  `$b = [Text.Encoding]::UTF8.GetBytes('{"tag_name":"v9.9.9","html_url":"https://github.com/aachaemenes/pgvigil/releases/tag/v9.9.9"}')
  `$c.Response.ContentType = 'application/json'; `$c.Response.OutputStream.Write(`$b, 0, `$b.Length); `$c.Response.Close() }
"@
Set-Content "$proofDir\feed.ps1" $feed
$fp = Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$proofDir\feed.ps1" -WindowStyle Hidden -PassThru
Start-Sleep 2
$r = Run-App "$proofDir\dist\pgvigil-app.exe" @('install', '-no-update-check')
if ($r.Code -ne 0) { Fail "install: exit $($r.Code): $($r.Text)" }
$pf = "$env:ProgramFiles\pgvigil"
foreach ($f in 'pgvigil.exe', 'pgvigil-app.exe') { if (-not (Test-Path "$pf\$f")) { Fail "no $pf\$f" } }
$svc = Get-CimInstance Win32_Service -Filter "Name='pgvigil'"
if (-not $svc -or $svc.StartName -ne 'NT SERVICE\pgvigil' -or $svc.StartMode -ne 'Auto') { Fail "the service: $($svc | Out-String)" }
$run = Reg-Value 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'pgvigil'
if ($run -ne "`"$pf\pgvigil-app.exe`" -tray") { Fail "HKLM Run: '$run'" }
if ((Reg-Value 'HKLM:\SOFTWARE\Policies\pgvigil\App' 'UpdateCheck') -ne 0) { Fail 'policy UpdateCheck is not 0' }
$ui = "$env:ProgramData\pgvigil\app"
if (-not (Test-Path "$ui\pgvigil.yaml")) { Fail "no $ui\pgvigil.yaml" }
$acl = (icacls $ui) -join ' '
if ($acl -notmatch 'BUILTIN\\Users:\(OI\)\(CI\)\(RX\)' -or $acl -match 'BUILTIN\\Users:\(OI\)\(CI\)\((F|M|W)') { Fail "the UI config folder's ACL: $acl" }
if ((Reg-Value 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\pgvigil' 'UninstallString') -ne "`"$pf\pgvigil-app.exe`" uninstall") { Fail 'HKLM Programs and Features entry' }
Set-Content "$proofDir\installed.marker" 'the proof installed pgvigil machine-wide'
Ok "B1 install (admin): $pf, service pgvigil $($svc.State)/Auto as NT SERVICE\pgvigil, HKLM Run -tray, policy UpdateCheck 0, $ui (Users RX), Programs and Features"
Copy-Item "$proofDir\ui.yaml" "$ui\pgvigil.yaml" -Force
Remove-Item "$proofDir\feed-hits.txt" -ErrorAction SilentlyContinue
$r = Run-App "$pf\pgvigil-app.exe" @('-check')
if ($r.Code -ne 0 -or $r.Text -notmatch 'update check off: turned off by the administrator') { Fail "-check with the policy off: $($r.Text)" }
if (Test-Path "$proofDir\feed-hits.txt") { Fail 'the feed was asked with the policy off' }
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\pgvigil\App' -Name UpdateCheck -Value 1 -Type DWord
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\pgvigil\App' -Name UpdateFeed -Value 'http://127.0.0.1:18765/latest.json'
$r = Run-App "$pf\pgvigil-app.exe" @('-check')
if ($r.Code -ne 0 -or $r.Text -notmatch 'update available v9\.9\.9') { Fail "-check with the policy on: $($r.Text)" }
$hits = @(Get-Content "$proofDir\feed-hits.txt" -ErrorAction SilentlyContinue)
if ($hits.Count -ne 1 -or $hits[0] -notmatch '^/latest\.json pgvigil-app/v0\.0\.1$') { Fail "feed requests: $($hits -join ' | ')" }
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\pgvigil\App' -Name UpdateCheck -Value 0 -Type DWord
Ok "B2 the update check: off by the policy (no feed request), on by the policy (v9.9.9 offered, one request: $($hits[0]))"
if ($r.Text -notmatch '\(machine\)' -or $r.Text -notmatch 'check: started http://127\.0\.0\.1:\d+/ pid (\d+)') { Fail "-check (machine config): $($r.Text)" }
$spid = [int]$Matches[1]
if ($r.Text -notmatch 'GET / 200' -or -not (Pid-Gone $spid)) { Fail "-check (machine config): $($r.Text)" }
Ok "B3 -check with the machine's config: started, GET / 200, stopped, pid $spid gone"
$sv = Start-Process "$pf\pgvigil.exe" -ArgumentList 'serve', '-config', "$ui\pgvigil.yaml", '-listen', '127.0.0.1:18090', '-no-login' -WindowStyle Hidden -PassThru
for ($i = 0; $i -lt 40; $i++) { try { Invoke-WebRequest -UseBasicParsing http://127.0.0.1:18090/api/health -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep -Milliseconds 500 } }
New-Item 'HKCU:\Software\pgvigil\App' -Force | Out-Null
Set-ItemProperty 'HKCU:\Software\pgvigil\App' -Name AttachURL -Value 'http://127.0.0.1:18090/'
$r = Run-App "$pf\pgvigil-app.exe" @('-check')
Remove-ItemProperty 'HKCU:\Software\pgvigil\App' -Name AttachURL
if ($r.Code -ne 0 -or $r.Text -notmatch 'check: attached http://127\.0\.0\.1:18090/' -or $r.Text -match 'stopped the serve') { Fail "attach: $($r.Text)" }
if (Pid-Gone $sv.Id) { Fail 'the attached serve was stopped by the app' }
Stop-Process -Id $sv.Id -Force
Stop-Process -Id $fp.Id -Force -ErrorAction SilentlyContinue
Ok "B4 attach: the app used the serve already on 127.0.0.1:18090 and left it running (pid $($sv.Id))"
'@
    $t = Invoke-Guest $admin1 'admin1.ps1'
    Need $t @('B1', 'B2', 'B3', 'B4')

    # ---------- C: a standard user on the machine-wide install, beside another user's serve ----------
    # the admin's serve on 127.0.0.1:18091 (-no-login) runs in the admin's desktop session: it outlives the SSH call
    $other = $guestHead + @'
$cmd = "-NoProfile -WindowStyle Hidden -Command `"& '$env:ProgramFiles\pgvigil\pgvigil.exe' serve -config '$env:ProgramData\pgvigil\app\pgvigil.yaml' -listen 127.0.0.1:18091 -no-login`""
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $cmd
$p = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'pgvigil-proof-other' -Action $a -Principal $p -Force | Out-Null
Start-ScheduledTask -TaskName 'pgvigil-proof-other'
$up = $false
for ($i = 0; $i -lt 40; $i++) { try { Invoke-WebRequest -UseBasicParsing http://127.0.0.1:18091/api/health -TimeoutSec 2 | Out-Null; $up = $true; break } catch { Start-Sleep -Milliseconds 500 } }
if (-not $up) { Fail 'the admin serve on 127.0.0.1:18091 did not answer' }
$owner = Invoke-CimMethod -InputObject (Get-CimInstance Win32_Process -Filter "ProcessId=$((Get-NetTCPConnection -LocalPort 18091 -State Listen).OwningProcess)") -MethodName GetOwner
Ok "the admin's serve answers on 127.0.0.1:18091 (owner $($owner.Domain)\$($owner.User))"
'@
    $null = Invoke-Guest $other 'other.ps1'
    $std2 = $guestHead + @'
$pf = "$env:ProgramFiles\pgvigil"
if (Test-Path "$env:LOCALAPPDATA\pgvigil\pgvigil.yaml") { Fail 'the standard user still has a config of its own' }
$r = Run-App "$pf\pgvigil-app.exe" @('-check')
if ($r.Code -ne 0 -or $r.Text -notmatch '\(machine\)' -or $r.Text -notmatch 'check: started http://127\.0\.0\.1:\d+/ pid (\d+)') { Fail "-check as the standard user on the machine install: $($r.Text)" }
$spid = [int]$Matches[1]
if ($r.Text -notmatch 'GET / 200' -or -not (Pid-Gone $spid)) { Fail "-check as the standard user on the machine install: $($r.Text)" }
Ok "C1 a standard user's app from Program Files reads the machine config (Users RX): started, GET / 200, stopped, pid $spid gone"
New-Item 'HKCU:\Software\pgvigil\App' -Force | Out-Null
Set-ItemProperty 'HKCU:\Software\pgvigil\App' -Name AttachURL -Value 'http://127.0.0.1:18091/'
$r = Run-App "$pf\pgvigil-app.exe" @('-check')
Remove-Item 'HKCU:\Software\pgvigil' -Recurse
if ($r.Code -ne 0 -or $r.Text -notmatch 'runs as another user' -or $r.Text -match 'check: attached' -or $r.Text -notmatch 'check: started') { Fail "attach to another user's serve: $($r.Text)" }
Ok "C2 the standard user's app did not attach to the admin's serve on 127.0.0.1:18091 (another user's): it started its own"
'@
    $t = Invoke-Guest $std2 'std2.ps1' -AsStd
    Need $t @('C1', 'C2')
    $null = & ssh -o ConnectTimeout=15 -o LogLevel=ERROR winsandbox "Stop-ScheduledTask -TaskName pgvigil-proof-other -ErrorAction SilentlyContinue; Get-NetTCPConnection -LocalPort 18091 -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id `$_.OwningProcess -Force }; Unregister-ScheduledTask -TaskName pgvigil-proof-other -Confirm:`$false -ErrorAction SilentlyContinue" 2>&1

    # ---------- B5: the window, in the admin's desktop session ----------
    # the window checks run inside the desktop session (an SSH session is session 0 and sees no desktop window):
    # desk.ps1 runs there as the logged-on admin (a limited token), writes its ok / FAIL lines to desk.out
    $desk = $guestHead + @'
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class PgvWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
"@
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$pf = "$env:ProgramFiles\pgvigil"
$log = "$env:LOCALAPPDATA\pgvigil\app.log"
Start-Process "$pf\pgvigil-app.exe"
$h = [IntPtr]::Zero; $t = ''
# the window exists as soon as it is made, WebView2 later: wait for the app's own line, then the serve's
for ($i = 0; $i -lt 90; $i++) { Start-Sleep 1; $h = [PgvWin]::FindWindow('webview', 'pgvigil'); $t = Get-Content $log -Raw -ErrorAction SilentlyContinue; if ($t -match 'WebView2 could not start' -or ($h -ne [IntPtr]::Zero -and $t -match 'window opened' -and $t -match 'serve: http')) { break } }
if ($t -match 'WebView2 could not start') { Fail "WebView2 could not start: $t" }
if ($h -eq [IntPtr]::Zero) { Fail "no pgvigil window; the log: $t" }
if ($t -notmatch 'window opened 1100x700') { Fail "the log does not say window opened 1100x700: $t" }
if ($t -notmatch 'serve: (http://127\.0\.0\.1:\d+/) \(started here: true, pid (\d+)\)') { Fail "the log names no started serve: $t" }
$url = $Matches[1]; $spid = [int]$Matches[2]
$rc = New-Object PgvWin+RECT; [void][PgvWin]::GetWindowRect($h, [ref]$rc)
if (($rc.R - $rc.L) -ne 1100 -or ($rc.B - $rc.T) -ne 700 -or -not [PgvWin]::IsWindowVisible($h)) { Fail "the window: $($rc.R - $rc.L) x $($rc.B - $rc.T), visible $([PgvWin]::IsWindowVisible($h))" }
Ok "B5a the window opened at the saved size 1100 x 700, visible; the serve $url (pid $spid)"
Start-Sleep 8   # the UI's first data
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
$bmp.Save("$proofDir\app-window.png"); $g.Dispose(); $bmp.Dispose()
Start-Process "$pf\pgvigil-app.exe"
Start-Sleep 4
$apps = @(Get-Process pgvigil-app -ErrorAction SilentlyContinue)
if ($apps.Count -ne 1) { Fail "a second launch: $($apps.Count) app processes" }
if (-not [PgvWin]::IsWindowVisible($h)) { Fail 'the window is not visible after the second launch' }
Ok 'B5b the screenshot taken; a second launch left one app process (it showed the running one)'
[void][PgvWin]::SetWindowPos($h, [IntPtr]::Zero, 50, 50, 1000, 650, 0x14)   # SWP_NOZORDER | SWP_NOACTIVATE
Start-Sleep 1
[void][PgvWin]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
Start-Sleep 2
if ([PgvWin]::IsWindowVisible($h)) { Fail 'the closed window is still visible' }
if (@(Get-Process pgvigil-app -ErrorAction SilentlyContinue).Count -ne 1 -or (Pid-Gone $spid)) { Fail 'closing the window ended the app or its serve' }
$w = Reg-Value 'HKCU:\Software\pgvigil\App' 'Width'; $hh = Reg-Value 'HKCU:\Software\pgvigil\App' 'Height'
if ($w -ne 1000 -or $hh -ne 650) { Fail "the saved size is $w x $hh, want 1000 x 650" }
Ok 'B5c closing the window hides it to the tray (app and serve run on), the size 1000 x 650 is saved'
Start-Process "$pf\pgvigil-app.exe" -ArgumentList '-quit' -Wait
for ($i = 0; $i -lt 20; $i++) { Start-Sleep 1; if (-not (Get-Process pgvigil-app -ErrorAction SilentlyContinue) -and (Pid-Gone $spid)) { break } }
if (Get-Process pgvigil-app -ErrorAction SilentlyContinue) { Fail 'the app still runs after -quit' }
if (-not (Pid-Gone $spid)) { Fail "the serve pid $spid still runs after the app quit" }
$t = Get-Content $log -Raw
if ($t -notmatch "stopped the started serve pid $spid" -or $t -notmatch 'pgvigil-app quit') { Fail "the log: $t" }
Ok "B5d -quit ended the app and the serve it started (pid $spid gone)"
'@
    Set-Content -LiteralPath (Join-Path $shareDir 'desk.ps1') -Value $desk -Encoding utf8
    $gui = $guestHead + @'
Copy-Item "\\host.lan\Data\__TAG__\desk.ps1" "$proofDir\desk.ps1" -Force
if (-not (Get-CimInstance Win32_ComputerSystem).UserName) { Fail 'nobody is logged on to the desktop: the window steps need the admin desktop session' }
Remove-Item "$env:LOCALAPPDATA\pgvigil\app.log", "$proofDir\desk.out", "$proofDir\desk.done", "$proofDir\app-window.png" -ErrorAction SilentlyContinue
New-Item 'HKCU:\Software\pgvigil\App' -Force | Out-Null
Set-ItemProperty 'HKCU:\Software\pgvigil\App' -Name Width -Value 1100 -Type DWord
Set-ItemProperty 'HKCU:\Software\pgvigil\App' -Name Height -Value 700 -Type DWord
Set-ItemProperty 'HKCU:\Software\pgvigil\App' -Name Maximized -Value 0 -Type DWord
Set-ItemProperty 'HKCU:\Software\pgvigil\App' -Name NoLogin -Value 1 -Type DWord
$cmd = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"& '$proofDir\desk.ps1' *> '$proofDir\desk.out'; Set-Content '$proofDir\desk.done' x`""
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $cmd
$p = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'pgvigil-proof-desk' -Action $a -Principal $p -Force | Out-Null
Start-ScheduledTask -TaskName 'pgvigil-proof-desk'
for ($i = 0; $i -lt 180 -and -not (Test-Path "$proofDir\desk.done"); $i++) { Start-Sleep 1 }
Unregister-ScheduledTask -TaskName 'pgvigil-proof-desk' -Confirm:$false
Remove-Item 'HKCU:\Software\pgvigil' -Recurse -ErrorAction SilentlyContinue
if (-not (Test-Path "$proofDir\desk.done")) { Fail "the desktop script did not finish in 180 s: $(Get-Content "$proofDir\desk.out" -Raw -ErrorAction SilentlyContinue)" }
Get-Content "$proofDir\desk.out"
if (Test-Path "$proofDir\app-window.png") { Copy-Item "$proofDir\app-window.png" "\\host.lan\Data\__TAG__\app-window.png" -Force }
'@
    $gui = $gui -replace '__TAG__', $tag
    $t = Invoke-Guest $gui 'gui.ps1'
    Need $t @('B5a', 'B5b', 'B5c', 'B5d')
    Copy-Item (Join-Path $shareDir 'app-window.png') (Join-Path $out 'app-window.png')

    # ---------- B6: uninstall ----------
    $admin2 = $guestHead + @'
$r = Run-App "$env:ProgramFiles\pgvigil\pgvigil-app.exe" @('uninstall', '-purge')
if ($r.Code -ne 0) { Fail "uninstall -purge: exit $($r.Code): $($r.Text)" }
Start-Sleep 5
if (Get-Service pgvigil -ErrorAction SilentlyContinue) { Fail 'the service is still there' }
if (Test-Path "$env:ProgramFiles\pgvigil") { Fail "$env:ProgramFiles\pgvigil is still there: $((Get-ChildItem "$env:ProgramFiles\pgvigil" -Force | Select-Object -ExpandProperty Name) -join ', ')" }
if (Reg-Value 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'pgvigil') { Fail 'HKLM Run left' }
foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\pgvigil', 'HKLM:\SOFTWARE\Policies\pgvigil') { if (Test-Path $k) { Fail "$k left" } }
if (Test-Path "$env:ProgramData\pgvigil\app") { Fail "$env:ProgramData\pgvigil\app left" }
Ok 'B6 uninstall -purge (admin): service, Program Files folder, HKLM Run, Programs and Features, policy key and the UI config gone'
'@
    $t = Invoke-Guest $admin2 'admin2.ps1'
    Need $t @('B6')
    Write-Host "PASS proof-app (screenshot: $(Join-Path $out 'app-window.png'), transcripts: $out)"
} finally {
    $cleanup = @'
$ErrorActionPreference = 'Continue'
$installed = Test-Path 'C:\__TAG__\installed.marker'
# only the proof's own processes: under its folder, the standard user's install, or the install it made
Get-CimInstance Win32_Process | Where-Object { $_.Name -in 'pgvigil-app.exe', 'pgvigil.exe' -and $_.ExecutablePath -and ($_.ExecutablePath -like 'C:\__TAG__\*' -or $_.ExecutablePath -like '*\__STD__\*' -or ($installed -and $_.ExecutablePath -like "$env:ProgramFiles\pgvigil\*")) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Stop-ScheduledTask -TaskName pgvigil-proof-other -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*__TAG__\feed.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
if ($installed -and (Test-Path "$env:ProgramFiles\pgvigil\pgvigil-app.exe")) { Start-Process "$env:ProgramFiles\pgvigil\pgvigil-app.exe" -ArgumentList 'uninstall', '-purge' -Wait -NoNewWindow }
foreach ($t in @('pgvigil-proof-desk', 'pgvigil-proof-other')) { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
$sid = (Get-LocalUser -Name '__STD__' -ErrorAction SilentlyContinue).SID.Value
# the standard user's last SSH logon can still hold its profile: its processes go first, then the profile
Get-Process -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -like '*\__STD__' } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep 2
Remove-LocalUser -Name '__STD__' -ErrorAction SilentlyContinue
if ($sid) { for ($i = 0; $i -lt 5; $i++) { try { Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $sid } | Remove-CimInstance -ErrorAction Stop; break } catch { Start-Sleep 3 } } }
# the admin's own settings and folder back as they were
Remove-Item 'HKCU:\Software\pgvigil' -Recurse -ErrorAction SilentlyContinue
if (Test-Path 'C:\__TAG__\hkcu-pgvigil.reg') { & reg.exe import 'C:\__TAG__\hkcu-pgvigil.reg' 2>$null }
Remove-Item "$env:LOCALAPPDATA\pgvigil" -Recurse -Force -ErrorAction SilentlyContinue   # the proof's window run made this one
if (Test-Path "$env:LOCALAPPDATA\pgvigil.saved-__TAG__") { Rename-Item "$env:LOCALAPPDATA\pgvigil.saved-__TAG__" 'pgvigil' }
Start-Sleep 1
Remove-Item 'C:\__TAG__' -Recurse -Force -ErrorAction SilentlyContinue
'@ -replace '__TAG__', $tag -replace '__STD__', $stdUser
    try {
        Set-Content -LiteralPath (Join-Path $shareDir 'cleanup.ps1') -Value $cleanup -Encoding utf8 -ErrorAction Stop
        $null = & ssh -o ConnectTimeout=15 -o LogLevel=ERROR winsandbox "powershell -NoProfile -ExecutionPolicy Bypass -File \\host.lan\Data\$tag\cleanup.ps1" 2>&1
    } catch { Write-Host "cleanup in the guest: $_" }
    & docker rm -f $repoName 2>&1 | Out-Null
    Remove-Item -LiteralPath $shareDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $work 'stdpw'), $script:askpass -Force -ErrorAction SilentlyContinue
    # the build (about 40 MB): gone; the transcripts stay in PROOF_OUT, or in the temp folder when it is not set
    if ($env:PROOF_OUT) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    else { Remove-Item -LiteralPath (Join-Path $work 'dist'), (Join-Path $work "pgvigil-app_${appVersion}_windows_amd64.zip"), (Join-Path $work 'pgvigil') -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed) { exit 1 }
