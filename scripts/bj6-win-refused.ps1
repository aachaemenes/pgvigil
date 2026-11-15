# BJ6 - the B24h-1 review part a #7 on dba-lab-win (Windows PowerShell 5.1, run by setup/Cloud-Win.ps1 Run -File):
# how long a TCP connect to a CLOSED port takes to fail on Windows, whose stack retries a SYN answered by a reset. The
# probe (internal/collect/probe.go) waits 1 s for a connect and counts a refusal as an answer: if a refusal takes about
# a second here, a stopped service on a live host reads 'not answered' on a Windows collector.
# Read only: it opens and closes sockets, nothing else. Its verdict is the last line.
# CONFIG (edit only these)
$Tries   = 10
$Waits   = @(1000, 3000)                       # ms: the probe's own wait, and a longer one to see the refusal's real time
$Targets = @('127.0.0.1:1')                    # loopback, a port nothing listens on; the VM's own address added below
# ---- end of CONFIG
$ErrorActionPreference = 'Stop'
$own = $null
try {
  $own = ([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) | Where-Object { $_.AddressFamily -eq 'InterNetwork' -and -not $_.ToString().StartsWith('127.') } | Select-Object -First 1)
} catch { $own = $null }
if ($own) { $Targets += ($own.ToString() + ':1') }
"BJ6 Windows $([System.Environment]::OSVersion.VersionString); targets: $($Targets -join ', ')"
$verdicts = @()
foreach ($target in $Targets) {
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
        if ($inner -is [System.Net.Sockets.SocketException] -and $inner.ErrorCode -eq 10061) { $outcomes.refused++ } else { $outcomes.other++ }
      } finally {
        $sw.Stop()
        $sock.Close()
      }
      $times += [int]$sw.ElapsedMilliseconds
    }
    $sorted = $times | Sort-Object
    $median = $sorted[[int][math]::Floor($sorted.Count / 2)]
    "BJ6 $target wait $waitMs ms: median $median ms (min $($sorted[0]), max $($sorted[-1])); refused $($outcomes.refused), timed out $($outcomes.timeout), connected $($outcomes.connected), other $($outcomes.other)"
    if ($waitMs -eq 1000) { $verdicts += [pscustomobject]@{ Target = $target; Median = $median; Refused = $outcomes.refused; TimedOut = $outcomes.timeout } }
  }
}
# the verdict on the probe's own 1 s wait: a refusal that comes as a timeout, or after 900 ms or more, confirms #7
$bad = @($verdicts | Where-Object { $_.TimedOut -gt 0 -or $_.Median -ge 900 })
$fast = @($verdicts | Where-Object { $_.Refused -eq $Tries -and $_.Median -lt 50 })
if ($bad.Count -gt 0) { "VERDICT BJ6 CONFIRMED: on $($bad.Target -join ', ') a closed port does not refuse within the probe's 1 s wait (median $($bad.Median -join ', ') ms): the 3 s wait on Windows is owed" }
elseif ($fast.Count -eq $verdicts.Count) { "VERDICT BJ6 WITHDRAWN: every closed port refused in under 50 ms within the 1 s wait" }
else { "VERDICT BJ6 UNCLEAR: refused within 1 s but not under 50 ms everywhere - read the lines above" }
