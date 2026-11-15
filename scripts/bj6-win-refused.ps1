# BJ6 - the B24h-1 review part a #7 on dba-lab-win (Windows PowerShell 5.1, run by setup/Cloud-Win.ps1 Run -File):
# how long a TCP connect to a CLOSED port of a REMOTE host takes to fail on Windows, whose stack retries a SYN answered
# by a reset. The probe (internal/collect/probe.go) waits 1 s for a connect and counts a refusal as an answer: if a
# refusal takes about a second, a stopped service on a live host reads 'not answered' on a Windows collector. Graded on
# CONFIG's RemoteTargets from the 3 s run (the review of the fold #6: a port that drops is told from one that refuses
# late); the loopback and own-address lines are context only.
# Read only: it opens and closes sockets, nothing else. Its verdict is the last line.
# CONFIG (edit only these)
$Tries   = 10
$Waits   = @(1000, 3000)                       # ms: the probe's own wait, and a longer one to see the refusal's real time
$Targets = @('127.0.0.1:1')                    # loopback, a port nothing listens on; the VM's own address added below
$RemoteTargets = @()                           # 'host:port' of a REACHABLE Linux host's CLOSED port (it answers a SYN with a
                                               # reset); the verdict is graded on these alone - the probe never targets
                                               # loopback, and Windows routes its own address through loopback
# ---- end of CONFIG
$ErrorActionPreference = 'Stop'
$own = $null
try {
  $own = ([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) | Where-Object { $_.AddressFamily -eq 'InterNetwork' -and -not $_.ToString().StartsWith('127.') } | Select-Object -First 1)
} catch { $own = $null }
if ($own) { $Targets += ($own.ToString() + ':1') }
$kindOf = @{}
foreach ($target in $Targets) { $kindOf[$target] = 'local (context only)' }
foreach ($target in $RemoteTargets) { $kindOf[$target] = 'remote (graded)' }
$all = @($Targets) + @($RemoteTargets)
"BJ6 Windows $([System.Environment]::OSVersion.VersionString); targets: $(($all | ForEach-Object { $_ + ' ' + $kindOf[$_] }) -join ', ')"
$verdicts = @()
foreach ($target in $all) {
  $hostPart, $portPart = $target.Split(':')
  foreach ($waitMs in $Waits) {
    $times = @(); $outcomes = @{ refused = 0; timeout = 0; connected = 0; other = 0 }
    for ($try = 0; $try -lt $Tries; $try++) {
      # TcpClient.ConnectAsync: an instance method under .NET Framework 4.5+ (Socket's Task form is an extension method,
      # which Windows PowerShell 5.1 cannot call as one)
      $sock = New-Object System.Net.Sockets.TcpClient([System.Net.Sockets.AddressFamily]::InterNetwork)
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      try {
        $task = $sock.ConnectAsync($hostPart, [int]$portPart)
        if ($task.Wait($waitMs)) { $outcomes.connected++ } else { $outcomes.timeout++ }
      } catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        if ($inner -is [System.Net.Sockets.SocketException] -and $inner.SocketErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionRefused) { $outcomes.refused++ } else { $outcomes.other++ }
      } finally {
        $sw.Stop()
        $sock.Close()
      }
      $times += [int]$sw.ElapsedMilliseconds
    }
    $sorted = $times | Sort-Object
    $median = $sorted[[int][math]::Floor($sorted.Count / 2)]
    "BJ6 $target ($($kindOf[$target])) wait $waitMs ms: median $median ms (min $($sorted[0]), max $($sorted[-1])); refused $($outcomes.refused), timed out $($outcomes.timeout), connected $($outcomes.connected), other $($outcomes.other)"
    $verdicts += [pscustomobject]@{ Target = $target; Wait = $waitMs; Median = $median; Refused = $outcomes.refused; TimedOut = $outcomes.timeout; Remote = ($RemoteTargets -contains $target) }
  }
}
# the verdict (the review of the fold #6), on the remote targets alone: the 3 s run tells a refusal that comes late from a
# port that drops the SYN - a 3 s timeout is a target that drops (no verdict for it); CONFIRMED when a remote closed port
# refused all of its tries at 900 ms or later (the probe's 1 s wait misses it: the 3 s wait on Windows is owed); WITHDRAWN
# when every remote target refused all of its tries in under 50 ms on the 1 s run
$remote = @($verdicts | Where-Object { $_.Remote })
foreach ($row in @($remote | Where-Object { $_.Wait -eq 3000 -and $_.TimedOut -gt 0 })) { "BJ6 $($row.Target) drops (a 3 s timeout): no verdict for it" }
$late = @($remote | Where-Object { $_.Wait -eq 3000 -and $_.Refused -eq $Tries -and $_.Median -ge 900 })
$refusing = @($remote | Where-Object { $_.Wait -eq 3000 -and $_.TimedOut -eq 0 } | ForEach-Object { $_.Target })
$fast = @($remote | Where-Object { $_.Wait -eq 1000 -and $_.Refused -eq $Tries -and $_.Median -lt 50 })
if ($RemoteTargets.Count -eq 0) { "VERDICT BJ6 NOT MEASURED: no remote target in CONFIG (RemoteTargets) - the local lines above are context only" }
elseif ($late.Count -gt 0) { "VERDICT BJ6 CONFIRMED: on $($late.Target -join ', ') a closed port refuses at $($late.Median -join ', ') ms (the 3 s run), past the probe's 1 s wait: the 3 s wait on Windows is owed" }
elseif ($refusing.Count -eq 0) { "VERDICT BJ6 NOT MEASURED: every remote target drops - name a closed port that resets" }
elseif ($fast.Count -eq $RemoteTargets.Count) { "VERDICT BJ6 WITHDRAWN: every remote closed port refused in under 50 ms within the 1 s wait" }
else { "VERDICT BJ6 UNCLEAR: a remote port refused within 1 s but not under 50 ms, or one drops - read the lines above" }
