#!/usr/bin/env bash
# Proof of the Linux installer end to end, on throwaway containers only: a mock release server (the binary
# built here plus SHA256SUMS, served over HTTP), a PostgreSQL 16 repository and a Debian container running
# systemd as PID 1. Needs docker, go and python3 on this machine; the systemd image is built once and kept
# as pgvigil-proof-systemd:bookworm (docker rmi it to rebuild).
#   PGVIGIL_PROOF_KEEP=1   leave the containers running after a failure (for a look)
# Expected: a -config in a shared folder (/etc) is refused before anything is touched; `curl | sh` with
# PGVIGIL_VERSION and PGVIGIL_BASE_URL verifies the checksum and installs: the
# binary at /usr/local/bin/pgvigil prints the version, the system user pgvigil exists, /etc/pgvigil holds
# pgvigil.yaml and pgvigil.env (0640 root:pgvigil), the unit is enabled and inactive (no instance yet) and
# the script says what to edit; started with that template the unit fails once with exit 3 and is not
# restarted; a checksum that does not match is refused; after the config names an
# instance a second run (the upgrade path) keeps the edited config, restarts nothing extra and starts the
# service, which runs as pgvigil and writes an instance row and an activity sample to the repository within
# 90 s; `pgvigil uninstall` removes the unit and keeps the config and binary; `-purge` removes those too;
# busybox ash parses install.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="pgvinst$RANDOM"; NET="$TAG-net"; REPO="$TAG-repo"; ASSETS="$TAG-assets"; SYS="$TAG-sys"
V="v0.0.0-proof"; PW="pw$RANDOM$RANDOM"; IMG="pgvigil-proof-systemd:bookworm"
WORK=$(mktemp -d)
cleanup() {
  if [[ "${PGVIGIL_PROOF_KEEP:-}" = "1" && "${FAILED:-}" = "1" ]]; then echo "kept: $SYS $REPO $ASSETS on $NET"; return; fi
  docker rm -f -v "$SYS" "$REPO" "$ASSETS" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { FAILED=1; echo "FAIL: $*" >&2; docker exec "$SYS" journalctl -u pgvigil --no-pager -n 20 2>/dev/null | sed 's/^/  journal: /' >&2 || true; exit 1; }
insys() { docker exec "$SYS" "$@"; }
rq() { docker exec "$REPO" psql -U postgres -XAt -c "$1"; }

echo "== build the mock release ($V) =="
mkdir -p "$WORK/srv/$V"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w -X main.version=$V" -o "$WORK/srv/$V/pgvigil_${V}_linux_amd64" ./cmd/pgvigil
(cd "$WORK/srv/$V" && sha256sum -- * > SHA256SUMS)
cp deploy/install.sh "$WORK/srv/install.sh"
cmp -s deploy/install.sh docs/install.sh || fail "docs/install.sh differs from deploy/install.sh (the Pages copy is stale)"
cmp -s deploy/install.ps1 docs/install.ps1 || fail "docs/install.ps1 differs from deploy/install.ps1 (the Pages copy is stale)"

echo "== containers =="
docker network create "$NET" >/dev/null
docker run -d --rm --name "$REPO" --network "$NET" -e POSTGRES_PASSWORD="$PW" postgres:16 >/dev/null
docker run -d --rm --name "$ASSETS" --network "$NET" -v "$WORK/srv:/srv:ro" -w /srv python:3-slim python3 -m http.server 8000 >/dev/null
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  cat > "$WORK/Dockerfile" <<'DF'
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv curl ca-certificates procps \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl mask systemd-logind.service getty.target console-getty.service systemd-udevd.service systemd-udev-trigger.service systemd-networkd-wait-online.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
DF
  docker build -q -t "$IMG" "$WORK" >/dev/null
fi
docker run -d --rm --name "$SYS" --network "$NET" --privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock "$IMG" >/dev/null
for _ in $(seq 1 60); do st=$(insys systemctl is-system-running 2>/dev/null || true); [[ "$st" == running || "$st" == degraded ]] && break; sleep 1; done
[[ "$st" == running || "$st" == degraded ]] || fail "systemd did not come up in the container (state '$st')"
for _ in $(seq 1 30); do docker exec "$REPO" pg_isready -U postgres -q 2>/dev/null && break; sleep 1; done
echo "ok   systemd $st, repository ready"

echo "== busybox parses install.sh =="
docker run --rm -v "$WORK/srv/install.sh:/i.sh:ro" busybox sh -n /i.sh || fail "busybox ash rejects install.sh"
echo "ok   busybox sh -n"

echo "== a bad checksum is refused =="
mkdir -p "$WORK/srv/bad"; cp "$WORK/srv/$V/pgvigil_${V}_linux_amd64" "$WORK/srv/bad/pgvigil_bad_linux_amd64"
printf '%064d  pgvigil_bad_linux_amd64\n' 0 > "$WORK/srv/bad/SHA256SUMS"
if insys sh -c "curl -fsSL http://$ASSETS:8000/install.sh | PGVIGIL_VERSION=bad PGVIGIL_BASE_URL=http://$ASSETS:8000 sh" >"$WORK/bad.out" 2>&1; then fail "a wrong checksum was accepted"; fi
grep -q 'checksum mismatch' "$WORK/bad.out" || fail "the refusal did not say checksum mismatch: $(cat "$WORK/bad.out")"
insys test ! -e /usr/local/bin/pgvigil || fail "a binary was installed despite the bad checksum"
echo "ok   checksum mismatch refused, nothing installed"

echo "== a config in a shared folder is refused before anything is touched =="
insys sh -c "curl -fsSL http://$ASSETS:8000/install.sh | PGVIGIL_VERSION=$V PGVIGIL_BASE_URL=http://$ASSETS:8000 PGVIGIL_NO_SERVICE=1 sh" >/dev/null 2>&1 || fail "download for the refusal check"
if insys sh -c "cd / && ./pgvigil install -config /etc/pgvigil.yaml -no-start" >"$WORK/shared.out" 2>&1; then fail "a config in /etc was accepted"; fi
grep -q 'holds other files' "$WORK/shared.out" || fail "the refusal did not name the shared folder: $(cat "$WORK/shared.out")"
[[ "$(insys stat -c '%a %U:%G' /etc)" == "755 root:root" ]] || fail "/etc was changed: $(insys stat -c '%a %U:%G' /etc)"
insys test ! -e /etc/pgvigil.yaml || fail "a config was written into /etc"
insys rm -f /pgvigil
echo "ok   shared folder refused, /etc untouched"

echo "== first install (no instance yet) =="
insys sh -c "curl -fsSL http://$ASSETS:8000/install.sh | PGVIGIL_VERSION=$V PGVIGIL_BASE_URL=http://$ASSETS:8000 sh" >"$WORK/i1.out" 2>&1 || fail "install.sh failed: $(cat "$WORK/i1.out")"
grep -q 'checksum verified' "$WORK/i1.out" || fail "no 'checksum verified' line: $(cat "$WORK/i1.out")"
grep -q 'installed and enabled' "$WORK/i1.out" || fail "the first install did not end with 'installed and enabled': $(cat "$WORK/i1.out")"
[[ "$(insys /usr/local/bin/pgvigil version)" == "pgvigil $V ("* ]] || fail "installed binary version: $(insys /usr/local/bin/pgvigil version)"   # the line goes on with the toolchain and the FIPS state
insys id -u pgvigil >/dev/null || fail "no system user pgvigil"
[[ "$(insys stat -c '%a %U:%G' /etc/pgvigil/pgvigil.yaml)" == "640 root:pgvigil" ]] || fail "pgvigil.yaml mode/owner: $(insys stat -c '%a %U:%G' /etc/pgvigil/pgvigil.yaml)"
[[ "$(insys stat -c '%a %U:%G' /etc/pgvigil/pgvigil.env)" == "640 root:pgvigil" ]] || fail "pgvigil.env mode/owner: $(insys stat -c '%a %U:%G' /etc/pgvigil/pgvigil.env)"
[[ "$(insys stat -c '%a %U:%G' /etc/pgvigil)" == "750 root:pgvigil" ]] || fail "/etc/pgvigil mode/owner"
[[ "$(insys systemctl is-enabled pgvigil)" == enabled ]] || fail "unit not enabled"
[[ "$(insys systemctl is-active pgvigil || true)" == inactive ]] || fail "the service started without an instance: $(insys systemctl is-active pgvigil || true)"
echo "ok   binary $V, user, 640/750 files, unit enabled, service inactive until an instance is named"

echo "== the boot case: started with the empty template, the unit fails once and does not loop =="
insys systemctl start pgvigil || true
sleep 12
[[ "$(insys systemctl show -p ExecMainStatus --value pgvigil)" == 3 ]] || fail "exit status of the unconfigured run: $(insys systemctl show -p ExecMainStatus --value pgvigil) (want 3)"
[[ "$(insys systemctl show -p NRestarts --value pgvigil)" == 0 ]] || fail "the unit restarted $(insys systemctl show -p NRestarts --value pgvigil) time(s) on a configuration error"
[[ "$(insys systemctl show -p SubState --value pgvigil)" != auto-restart ]] || fail "the unit is in auto-restart"
insys systemctl reset-failed pgvigil >/dev/null 2>&1 || true
echo "ok   unconfigured start: exit 3, no restart"

echo "== the config names an instance; the second run (upgrade path) starts the service =="
insys /usr/local/bin/pgvigil migrate -config /etc/pgvigil/pgvigil.yaml >/dev/null 2>&1 && fail "migrate ran with an empty PGVIGIL_REPO_DSN" || true
insys sh -c "PGVIGIL_REPO_DSN='postgres://postgres:$PW@$REPO:5432/postgres?sslmode=disable' /usr/local/bin/pgvigil migrate -config /etc/pgvigil/pgvigil.yaml" >/dev/null 2>&1 || fail "migrate as the owner"
insys sh -c "printf 'PGVIGIL_REPO_DSN=postgres://postgres:$PW@$REPO:5432/postgres?sslmode=disable\nPROOF_TARGET_DSN=host=$REPO port=5432 user=postgres password=$PW dbname=postgres sslmode=disable\n' >> /etc/pgvigil/pgvigil.env"
insys sh -c "sed -i 's/^instances: \[\]/instances:\n  - name: proof-target\n    dsn: env:PROOF_TARGET_DSN\n    tags: [proof]/' /etc/pgvigil/pgvigil.yaml"
insys grep -q 'proof-target' /etc/pgvigil/pgvigil.yaml || fail "the instance edit did not land"
insys sh -c "curl -fsSL http://$ASSETS:8000/install.sh | PGVIGIL_VERSION=$V PGVIGIL_BASE_URL=http://$ASSETS:8000 sh" >"$WORK/i2.out" 2>&1 || fail "second install.sh failed: $(cat "$WORK/i2.out")"
grep -q 'installed and running' "$WORK/i2.out" || fail "the second install did not end with 'installed and running': $(cat "$WORK/i2.out")"
insys grep -q 'proof-target' /etc/pgvigil/pgvigil.yaml || fail "the upgrade overwrote the edited config"
[[ "$(insys systemctl is-active pgvigil)" == active ]] || fail "service not active"
[[ "$(insys systemctl show -p User --value pgvigil)" == pgvigil ]] || fail "the unit does not run as pgvigil"
[[ "$(insys ps -o user= -C pgvigil | sort -u | tr -d ' ')" == pgvigil ]] || fail "the process runs as $(insys ps -o user= -C pgvigil | sort -u)"
for _ in $(seq 1 90); do n=$(rq "select count(*) from pgvigil.activity_summary s join pgvigil.instances i on i.instance_id = s.instance_id where i.name = 'proof-target'"); [[ "$n" -ge 1 ]] && break; sleep 1; done
[[ "$n" -ge 1 ]] || fail "no activity sample for proof-target within 90 s"
echo "ok   upgrade path kept the config, service active as pgvigil, $n activity sample(s) in the repository"

echo "== uninstall =="
insys /usr/local/bin/pgvigil uninstall >"$WORK/u1.out" 2>&1 || fail "uninstall: $(cat "$WORK/u1.out")"
insys systemctl status pgvigil >/dev/null 2>&1 && fail "the unit still exists after uninstall" || true
insys test -f /etc/pgvigil/pgvigil.yaml || fail "uninstall removed the config"
insys test -x /usr/local/bin/pgvigil || fail "uninstall removed the binary"
insys /usr/local/bin/pgvigil uninstall -purge >"$WORK/u2.out" 2>&1 || fail "uninstall -purge: $(cat "$WORK/u2.out")"
insys test ! -e /etc/pgvigil || fail "-purge kept /etc/pgvigil"
insys test ! -e /usr/local/bin/pgvigil || fail "-purge kept the binary"
echo "ok   uninstall keeps config and binary; -purge removes both"
echo "proof-install: OK (checksum refusal, shared folder refused, install without an instance, the unconfigured start exits 3 without a loop, upgrade path starting the service as pgvigil with $n sample(s), uninstall, purge; busybox parse)"
