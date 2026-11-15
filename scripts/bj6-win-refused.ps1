# BJ6 - the B24h-1 review part a #7 on dba-lab-win (Windows PowerShell 5.1, run by setup/Cloud-Win.ps1 Run -File):
# how long a TCP connect to a CLOSED port of a REMOTE host takes to fail on Windows, whose stack retries a SYN answered
# by a reset. The probe (internal/collect/probe.go) waits 1 s for a connect and counts a refusal as an answer: if a
# refusal takes about a second, a stopped service on a live host reads 'not answered' on a Windows collector. Graded on
# CONFIG's RemoteTargets from the LONGEST wait (the review of the fold #6 and of BJ6 #4: a port that drops is told from
# one that refuses late, even past 3 s); the loopback, own-address and host-up lines are context only.
# Read only: it opens and closes sockets, nothing else. Its verdict is the last line.
# CONFIG (edit only these)
$Waits   = @(1000, 3000, 10000)                # ms: the probe's own wait, a longer one, and the longest - the one graded
$TriesAt = @{ 1000 = 10; 3000 = 10; 10000 = 3 } # tries per wait
$Targets = @('127.0.0.1:1')                    # loopback, a port nothing listens on; the VM's own address added below
$RemoteTargets = @()                           # 'host:port' of a REACHABLE Linux host's CLOSED port (it answers a SYN with a
                                               # reset); the verdict is graded on these alone - the probe never targets
                                               # loopback, and Windows routes its own address through loopback
$HostUpTargets = @()                           # 'host:port' of a port that ACCEPTS on the same remote host (context only:
                                               # connected = the host is up and reachable, so a remote drop is the network's)
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
foreach ($target in $HostUpTargets) { $kindOf[$target] = 'host up? (context only)' }
$all = @($Targets) + @($RemoteTargets) + @($HostUpTargets)
$longest = ($Waits | Measure-Object -Maximum).Maximum
"BJ6 Windows $([System.Environment]::OSVersion.VersionString); targets: $(($all | ForEach-Object { $_ + ' ' + $kindOf[$_] }) -join ', ')"
$verdicts = @()
foreach ($target in $all) {
  $hostPart, $portPart = $target.Split(':')
  foreach ($waitMs in $Waits) {
    $times = @(); $outcomes = @{ refused = 0; timeout = 0; connected = 0; other = 0 }
    $triesHere = [int]$TriesAt[$waitMs]
    for ($try = 0; $try -lt $triesHere; $try++) {
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
    $verdicts += [pscustomobject]@{ Target = $target; Wait = $waitMs; Tries = $triesHere; Median = $median; Refused = $outcomes.refused; TimedOut = $outcomes.timeout
                                    Connected = $outcomes.connected; Other = $outcomes.other; Remote = ($RemoteTargets -contains $target) }
  }
}
# the verdict (the review of the fold #6 and of BJ6 #4-#6), on the remote targets alone, graded on the longest wait: a
# timeout there is a target that drops (no verdict for it); a target that refused every try there is a closed port that
# resets. CONFIRMED when such a port refuses at 900 ms or later AND the probe's own 1 s wait missed it at least once;
# WITHDRAWN when every remote target is such a port and refused every 1 s try in under 50 ms
$remote = @($verdicts | Where-Object { $_.Remote })
$oneSec = @{}; foreach ($row in @($remote | Where-Object { $_.Wait -eq 1000 })) { $oneSec[$row.Target] = $row }
foreach ($row in @($verdicts | Where-Object { -not $_.Remote -and $kindOf[$_.Target] -like 'host up*' -and $_.Wait -eq $longest })) {
  if ($row.Connected -gt 0) { "BJ6 $($row.Target) connected: the remote host is up and reachable - a remote drop is the network's, on that port" }
  else { "BJ6 $($row.Target) did not connect: the remote host is off, or the network drops that port too - a remote drop says nothing" }
}
foreach ($row in @($remote | Where-Object { $_.Wait -eq $longest -and $_.TimedOut -gt 0 })) { "BJ6 $($row.Target) drops (a $($longest / 1000) s timeout on $($row.TimedOut) of $($row.Tries)): no verdict for it" }
foreach ($row in @($remote | Where-Object { $_.Other -gt 0 -or $_.Connected -gt 0 })) { "BJ6 $($row.Target) at $($row.Wait) ms: $($row.Other) other error(s), $($row.Connected) connected - not a closed port that resets on those tries" }
$refusing = @($remote | Where-Object { $_.Wait -eq $longest -and $_.Refused -eq $_.Tries })
$late = @($refusing | Where-Object { $_.Median -ge 900 -and $oneSec[$_.Target] -and $oneSec[$_.Target].TimedOut -gt 0 })
$lateInside = @($refusing | Where-Object { $_.Median -ge 900 -and $oneSec[$_.Target] -and $oneSec[$_.Target].TimedOut -eq 0 })
$fast = @($refusing | Where-Object { $oneSec[$_.Target] -and $oneSec[$_.Target].Refused -eq $oneSec[$_.Target].Tries -and $oneSec[$_.Target].Median -lt 50 })
foreach ($row in $lateInside) { "BJ6 $($row.Target) refuses at $($row.Median) ms, inside the probe's 1 s wait (its 1 s run: refused $($oneSec[$row.Target].Refused) of $($oneSec[$row.Target].Tries)): no miss" }
if ($RemoteTargets.Count -eq 0) { "VERDICT BJ6 NOT MEASURED: no remote target in CONFIG (RemoteTargets) - the local lines above are context only" }
elseif ($late.Count -gt 0) { "VERDICT BJ6 CONFIRMED: on $($late.Target -join ', ') a closed port refuses at $($late.Median -join ', ') ms (the $($longest / 1000) s run) and the probe's 1 s wait missed it ($(($late | ForEach-Object { 'timed out ' + $oneSec[$_.Target].TimedOut + ' of ' + $oneSec[$_.Target].Tries }) -join ', ')): the 3 s wait on Windows is owed" }
elseif ($refusing.Count -eq 0) { "VERDICT BJ6 NOT MEASURED: no remote target refused every try at the $($longest / 1000) s wait (drops or other errors above) - name a closed port that resets" }
elseif ($fast.Count -eq $RemoteTargets.Count) { "VERDICT BJ6 WITHDRAWN: every remote closed port refused every try in under 50 ms within the 1 s wait" }
else { "VERDICT BJ6 UNCLEAR: a remote closed port refused within the probe's wait but not under 50 ms, or not every remote target resets - read the lines above" }
