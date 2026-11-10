#!/usr/bin/env bash
# Proof of the service units' hardening (government readiness, task 50): systemd's own security analysis
# of the two units in deploy/, offline (no unit is installed or started here; proof-install.sh runs the
# collector unit for real on a systemd container). Needs systemd-analyze 250 or newer (--offline).
# Expected: deploy/pgvigil.service and deploy/pgvigil-purge.service each score an overall exposure of
# 1.5 or under ("OK" on systemd's scale, where the unhardened unit scored 7.7 "EXPOSED"); the unit the
# installer renders is byte-identical to deploy/pgvigil.service (TestUnitMatchesDeployFile); every
# directive the hardening relies on is present in both units; the controls that are deliberately left
# open are exactly the network ones (the collector reaches the monitored servers and the repository,
# so AF_INET / AF_INET6 / AF_UNIX stay, no PrivateNetwork, no IPAddressDeny), PrivateUsers (user
# namespaces are not available on every host and container) and @resources (Go raises its own file
# limit with prlimit64 at start: filtering it would kill the process).
export LC_ALL=C.UTF-8   # systemd-analyze's ✗ marks are matched as UTF-8 whatever the caller's locale (a C locale matched nothing and the open-by-design loop ran empty)
set -euo pipefail
cd "$(dirname "$0")/.."
MAX=${PGVIGIL_PROOF_MAX_EXPOSURE:-1.5}
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v systemd-analyze >/dev/null || fail "systemd-analyze is not on this machine"

NEEDED=(NoNewPrivileges=yes ProtectSystem=strict ProtectHome=yes PrivateTmp=yes PrivateDevices=yes DevicePolicy=closed
  ProtectKernelTunables=yes ProtectKernelModules=yes ProtectKernelLogs=yes ProtectControlGroups=yes ProtectClock=yes
  ProtectHostname=yes ProtectProc=invisible ProcSubset=pid RestrictNamespaces=yes RestrictRealtime=yes RestrictSUIDSGID=yes
  "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX" LockPersonality=yes MemoryDenyWriteExecute=yes RemoveIPC=yes UMask=0077
  CapabilityBoundingSet= AmbientCapabilities= SystemCallArchitectures=native SystemCallFilter=@system-service "SystemCallFilter=~@privileged")
ALLOWED_OPEN='^(SystemCallFilter=~@resources|RootDirectory=/RootImage=|RestrictAddressFamilies=~AF_UNIX|RestrictAddressFamilies=~AF_\(INET\|INET6\)|PrivateNetwork=|PrivateUsers=|DeviceAllow=|IPAddressDeny=)$'

for unit in deploy/pgvigil.service deploy/pgvigil-purge.service; do
  echo "== $unit"
  for d in "${NEEDED[@]}"; do grep -qxF -- "$d" "$unit" || fail "$unit lacks the line $d"; done
  out=$(systemd-analyze security --offline=true --no-pager "$unit" 2>&1) || fail "systemd-analyze security failed on $unit: $out"
  score=$(sed -n 's/.*Overall exposure level for [^:]*: \([0-9.]*\).*/\1/p' <<<"$out")
  [[ -n "$score" ]] || fail "no exposure line for $unit: $out"
  echo "   exposure $score (max $MAX)"
  awk -v s="$score" -v m="$MAX" 'BEGIN { exit !(s <= m) }' || fail "$unit exposure $score is over $MAX"
  # every control still reported open is one the header names as deliberately open
  while IFS= read -r line; do
    key=$(sed -E 's/^✗ ([^ ]+( [^ ]+)*?) {2,}.*/\1/' <<<"$line")
    grep -qE "$ALLOWED_OPEN" <<<"$key" || fail "$unit: an unexpected open control: $line"
    echo "   open by design: $key"
  done < <(grep '✗' <<<"$out")
done

echo "== the installer's rendered unit equals deploy/pgvigil.service"
go test ./cmd/pgvigil/ -run 'TestUnitMatchesDeployFile' -count=1 >/dev/null || fail "the rendered unit drifted from deploy/pgvigil.service"
echo "OK: both units at or under exposure $MAX, every hardening line present, the rendered unit matches"
