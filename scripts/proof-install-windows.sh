#!/usr/bin/env bash
# Proof of the Windows installer on the Windows sandbox over SSH (this machine's CLAUDE.local.md names it:
# host winsandbox, the share ~/winsandbox/shared = \\host.lan\Data in the guest, the guest reaches containers
# on the SQL sandbox's compose network by name). A mock release server (pgvigil_<V>_windows_amd64.exe built
# here plus SHA256SUMS and install.ps1) and a PostgreSQL 16 repository run as throwaway containers on that
# network; scripts/proof-install.ps1 runs inside the guest in two phases and this script checks the
# repository in between. Needs: docker, go, ssh winsandbox answering.
#   PGVIGIL_WIN_NET=<docker network the guest can reach>   default mssqlsandbox_default
#   PGVIGIL_WIN_SHARE=<folder that is \\host.lan\Data>     default ~/winsandbox/shared
# Expected: phase install prints its two ok lines (service Stopped then Running under NT SERVICE\pgvigil, the
# data folder's ACL names only SYSTEM, Administrators and the service account, the log says the scheduler
# started); the repository gets an instance row and an activity sample for win-proof-target within 90 s;
# phase uninstall prints its ok line.
set -euo pipefail
cd "$(dirname "$0")/.."
NET="${PGVIGIL_WIN_NET:-mssqlsandbox_default}"; SHARE="${PGVIGIL_WIN_SHARE:-$HOME/winsandbox/shared}"
TAG="pgvwin$RANDOM"; REPO="$TAG-repo"; ASSETS="$TAG-assets"; V="v0.0.0-proof"; PW="pw$RANDOM$RANDOM"
WORK=$(mktemp -d)
cleanup() { docker rm -f -v "$REPO" "$ASSETS" >/dev/null 2>&1 || true; rm -rf "$WORK" "$SHARE/proof-install.ps1"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
rq() { docker exec "$REPO" psql -U postgres -XAt -c "$1"; }
ssh -o ConnectTimeout=10 winsandbox 'echo up' >/dev/null 2>&1 || fail "the Windows sandbox does not answer on ssh winsandbox (winsandbox on)"
docker network inspect "$NET" >/dev/null 2>&1 || fail "no docker network $NET"

echo "== mock release ($V) and repository on $NET =="
mkdir -p "$WORK/srv/$V"
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-s -w -X main.version=$V" -o "$WORK/srv/$V/pgvigil_${V}_windows_amd64.exe" ./cmd/pgvigil
(cd "$WORK/srv/$V" && sha256sum -- * > SHA256SUMS)
cp deploy/install.ps1 "$WORK/srv/install.ps1"
docker run -d --rm --name "$REPO" --network "$NET" -e POSTGRES_PASSWORD="$PW" postgres:16 >/dev/null
docker run -d --rm --name "$ASSETS" --network "$NET" -v "$WORK/srv:/srv:ro" -w /srv python:3-slim python3 -m http.server 8000 >/dev/null
for _ in $(seq 1 30); do docker exec "$REPO" pg_isready -U postgres -q 2>/dev/null && break; sleep 1; done
cp scripts/proof-install.ps1 "$SHARE/proof-install.ps1"

echo "== guest: a leftover install from an earlier run is removed first =="
ssh winsandbox "powershell -NoProfile -ExecutionPolicy Bypass -File \\\\host.lan\\Data\\proof-install.ps1 -Phase uninstall" >/dev/null 2>&1 || true
echo "== guest: phase install =="
out=$(ssh winsandbox "powershell -NoProfile -ExecutionPolicy Bypass -File \\\\host.lan\\Data\\proof-install.ps1 -Phase install -AssetsHost $ASSETS -RepoHost $REPO -Tag $V -RepoPassword $PW" 2>&1 | tr -d '\r') || { echo "$out"; fail "phase install"; }
echo "$out" | grep -E '^(ok|FAIL)' || true
echo "$out" | grep -q '^FAIL' && fail "guest reported a failure"
echo "$out" | grep -q 'service Running' || fail "phase install did not reach Running: $out"
for _ in $(seq 1 90); do n=$(rq "select count(*) from pgvigil.activity_summary s join pgvigil.instances i on i.instance_id = s.instance_id where i.name = 'win-proof-target'"); [[ "$n" -ge 1 ]] && break; sleep 1; done
[[ "$n" -ge 1 ]] || fail "no activity sample for win-proof-target within 90 s"
echo "ok   the Windows service wrote $n activity sample(s) to the repository"

echo "== guest: phase uninstall =="
out=$(ssh winsandbox "powershell -NoProfile -ExecutionPolicy Bypass -File \\\\host.lan\\Data\\proof-install.ps1 -Phase uninstall" 2>&1 | tr -d '\r') || { echo "$out"; fail "phase uninstall"; }
echo "$out" | grep -E '^(ok|FAIL)' || true
echo "$out" | grep -q '^FAIL' && fail "guest reported a failure"
echo "proof-install-windows: OK (install.ps1 over HTTP, service under NT SERVICE\\pgvigil, restricted data folder, upgrade path to Running, $n sample(s), uninstall -purge)"
