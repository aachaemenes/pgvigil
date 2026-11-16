#!/usr/bin/env bash
# Proof of the Linux installer end to end, on throwaway containers only: a mock release server (the binary
# built here plus SHA256SUMS, served over HTTP), a PostgreSQL 16 repository and a Debian container running
# systemd as PID 1. Needs docker, go and python3 on this machine; the systemd image is built once and kept
# as pgvigil-proof-systemd:bookworm (docker rmi it to rebuild).
#   PGVIGIL_PROOF_KEEP=1   leave the containers running after a failure (for a look)
# Expected: a -config in a shared folder (/etc) is refused before anything is touched; `curl | sh` with
# PGVIGIL_VERSION and PGVIGIL_BASE_URL verifies the checksum and installs: the
# binary at /usr/local/bin/pgvigil prints the version, the system user pgvigil exists, /etc/pgvigil holds
# pgvigil.yaml and pgvigil.env (0640 root:pgvigil), the unit is enabled and inactive (the repository DSN empty
# yet) and the script says what to edit; started with that template the unit fails once with exit 3 (an empty
# repository DSN) and is not restarted; a checksum that does not match is refused; with PGVIGIL_REPO_DSN filled in
# and still no instance in the file a second run starts the service (the page may hold every instance); after the
# config names an instance a third run (the upgrade path) keeps the edited config and the
# service, which runs as pgvigil and writes an instance row and an activity sample to the repository within
# 90 s; the remote collector beside it (task 11 / 14 rows): `install.sh --remote` with a remote config in place
# installs /usr/local/bin/pgvigil-remote and pgvigil-remote.service (active as pgvigil-remote, ExecStart naming its own
# binary), a bundle lands in /var/lib/pgvigil-remote/outbox within 150 s, and the hub's binary, unit, config and env
# file stay byte for byte, its process the same (never restarted), /etc/pgvigil's owner and mode and its account as
# they were; `install.sh --remote` again succeeds over itself; ORDER HUB-THEN-REMOTE (the lead's 12:5x rows): the hub's
# `pgvigil install -upgrade` run by the operator with a $V2 binary beside the remote ends '5. swapped the binary and
# started the service', /usr/local/bin/pgvigil prints $V2, and the remote's binary, unit, config, env, process, folders
# and account stay as they were (that check first fails on a planted change to the remote's env file, then passes
# again once it is put back); `uninstall -remote
# -purge` is refused while the outbox holds bundles (the words 'not pushed', 'lost', '-force'; the remote still active),
# `-purge -force` removes the unit, /etc/pgvigil-remote, /var/lib/pgvigil-remote and the binary and keeps and names the
# account, the hub's files still byte for byte and active; `pgvigil uninstall` removes the unit and keeps the config
# and binary; `-purge` removes those too; ORDER REMOTE-THEN-HUB on the host with no hub left: `install.sh --remote`
# active, then the hub's fresh `install.sh` ('installed and enabled'), `command -v` finding /usr/local/bin/pgvigil and
# /usr/local/bin/pgvigil-remote, the hub's `install -upgrade` to $V2 ('5. swapped the binary; the service is enabled,
# not started': its DSN is the template's empty one), the remote as it was across both; `pgvigil-remote uninstall
# -remote -purge -force` leaves the hub as it was; the hub's `uninstall -purge` last; busybox ash parses install.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="pgvinst$RANDOM"; NET="$TAG-net"; REPO="$TAG-repo"; ASSETS="$TAG-assets"; SYS="$TAG-sys"
V="v0.0.0-proof"; V2="v0.0.0-proof2"; PW="pw$RANDOM$RANDOM"; IMG="pgvigil-proof-systemd:bookworm"
WORK=$(mktemp -d)
cleanup() {
  if [[ "${PGVIGIL_PROOF_KEEP:-}" = "1" && "${FAILED:-}" = "1" ]]; then echo "kept: $SYS $REPO $ASSETS on $NET"; return; fi
  docker rm -f -v "$SYS" "$REPO" "$ASSETS" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { FAILED=1; echo "FAIL: $*" >&2; docker exec "$SYS" journalctl -u pgvigil --no-pager -n 20 2>/dev/null | sed 's/^/  journal: /' >&2 || true; docker exec "$SYS" journalctl -u pgvigil-remote --no-pager -n 20 2>/dev/null | sed 's/^/  remote journal: /' >&2 || true; exit 1; }
insys() { docker exec "$SYS" "$@"; }
rq() { docker exec "$REPO" psql -U postgres -XAt -c "$1"; }

echo "== build the mock release ($V) =="
mkdir -p "$WORK/srv/$V"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w -X main.version=$V" -o "$WORK/srv/$V/pgvigil_${V}_linux_amd64" ./cmd/pgvigil
(cd "$WORK/srv/$V" && sha256sum -- * > SHA256SUMS)
# a second version for the hub's -upgrade beside the remote (the same code, another version string: other bytes)
mkdir -p "$WORK/srv/$V2"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w -X main.version=$V2" -o "$WORK/srv/$V2/pgvigil_${V2}_linux_amd64" ./cmd/pgvigil
(cd "$WORK/srv/$V2" && sha256sum -- * > SHA256SUMS)
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
[[ "$(insys systemctl is-active pgvigil || true)" == inactive ]] || fail "the service started with an empty repository DSN: $(insys systemctl is-active pgvigil || true)"
echo "ok   binary $V, user, 640/750 files, unit enabled, service inactive until the repository DSN is filled in"

echo "== the boot case: started with the empty template, the unit fails once and does not loop =="
insys systemctl start pgvigil || true
sleep 12
[[ "$(insys systemctl show -p ExecMainStatus --value pgvigil)" == 3 ]] || fail "exit status of the unconfigured run: $(insys systemctl show -p ExecMainStatus --value pgvigil) (want 3)"
[[ "$(insys systemctl show -p NRestarts --value pgvigil)" == 0 ]] || fail "the unit restarted $(insys systemctl show -p NRestarts --value pgvigil) time(s) on a configuration error"
[[ "$(insys systemctl show -p SubState --value pgvigil)" != auto-restart ]] || fail "the unit is in auto-restart"
insys systemctl reset-failed pgvigil >/dev/null 2>&1 || true
echo "ok   unconfigured start: exit 3, no restart"

echo "== the repository DSN filled in, still no instance in the file: the second run (upgrade path) starts the service =="
insys /usr/local/bin/pgvigil migrate -config /etc/pgvigil/pgvigil.yaml >/dev/null 2>&1 && fail "migrate ran with an empty PGVIGIL_REPO_DSN" || true
insys sh -c "PGVIGIL_REPO_DSN='postgres://postgres:$PW@$REPO:5432/postgres?sslmode=disable' /usr/local/bin/pgvigil migrate -config /etc/pgvigil/pgvigil.yaml" >/dev/null 2>&1 || fail "migrate as the owner"
insys sh -c "printf 'PGVIGIL_REPO_DSN=postgres://postgres:$PW@$REPO:5432/postgres?sslmode=disable\nPROOF_TARGET_DSN=host=$REPO port=5432 user=postgres password=$PW dbname=postgres sslmode=disable\n' >> /etc/pgvigil/pgvigil.env"
insys grep -q '^instances: \[\]' /etc/pgvigil/pgvigil.yaml || fail "the template's empty instance list is not there"
insys sh -c "curl -fsSL http://$ASSETS:8000/install.sh | PGVIGIL_VERSION=$V PGVIGIL_BASE_URL=http://$ASSETS:8000 sh" >"$WORK/i2.out" 2>&1 || fail "second install.sh failed: $(cat "$WORK/i2.out")"
grep -q 'installed and running' "$WORK/i2.out" || fail "the DSN filled in with no instance in the file: the second install did not end with 'installed and running' (the gate is the DSN; the page may hold every instance): $(cat "$WORK/i2.out")"
[[ "$(insys systemctl is-active pgvigil)" == active ]] || fail "service not active with the DSN filled in and no instance in the file"
echo "ok   the DSN filled in, no instance in the file: the service runs (the page may hold the instances)"

echo "== the config names an instance; the third run (upgrade path) keeps it and the service collects it =="
insys sh -c "sed -i 's/^instances: \[\]/instances:\n  - name: proof-target\n    dsn: env:PROOF_TARGET_DSN\n    tags: [proof]/' /etc/pgvigil/pgvigil.yaml"
insys grep -q 'proof-target' /etc/pgvigil/pgvigil.yaml || fail "the instance edit did not land"
insys sh -c "curl -fsSL http://$ASSETS:8000/install.sh | PGVIGIL_VERSION=$V PGVIGIL_BASE_URL=http://$ASSETS:8000 sh" >"$WORK/i3.out" 2>&1 || fail "third install.sh failed: $(cat "$WORK/i3.out")"
grep -q 'installed and running' "$WORK/i3.out" || fail "the third install did not end with 'installed and running': $(cat "$WORK/i3.out")"
insys grep -q 'proof-target' /etc/pgvigil/pgvigil.yaml || fail "the upgrade overwrote the edited config"
[[ "$(insys systemctl is-active pgvigil)" == active ]] || fail "service not active"
[[ "$(insys systemctl show -p User --value pgvigil)" == pgvigil ]] || fail "the unit does not run as pgvigil"
[[ "$(insys ps -o user= -C pgvigil | sort -u | tr -d ' ')" == pgvigil ]] || fail "the process runs as $(insys ps -o user= -C pgvigil | sort -u)"
for _ in $(seq 1 90); do n=$(rq "select count(*) from pgvigil.activity_summary s join pgvigil.instances i on i.instance_id = s.instance_id where i.name = 'proof-target'"); [[ "$n" -ge 1 ]] && break; sleep 1; done
[[ "$n" -ge 1 ]] || fail "no activity sample for proof-target within 90 s"
echo "ok   upgrade path kept the config, service active as pgvigil, $n activity sample(s) in the repository"

echo "== the remote collector beside the hub: install.sh --remote (its own binary, unit, account, config and folders) =="
HUBFILES="/usr/local/bin/pgvigil /etc/systemd/system/pgvigil.service /etc/pgvigil/pgvigil.yaml /etc/pgvigil/pgvigil.env"
# the hub untouched = its files byte for byte, the same running process (never restarted), its folder's owner and mode
# and its account (W review S7)
hubstate() { insys sh -c "sha256sum $HUBFILES; systemctl show -p MainPID -p ActiveEnterTimestampMonotonic pgvigil; stat -c '%U:%G %a' /etc/pgvigil; id pgvigil"; }
hub_before=$(hubstate)
remconfig() { insys sh -c "mkdir -p /etc/pgvigil-remote && printf 'remote:\n  site: lab11\n  collector: c1\n  interval: 1m\n  outbox: /var/lib/pgvigil-remote/outbox\n  state_dir: /var/lib/pgvigil-remote/state\nquery_text: hash\ninstances:\n  - name: pg-remote\n    dsn: env:REMOTE_PG_DSN\n' > /etc/pgvigil-remote/pgvigil-remote.yaml && printf 'REMOTE_PG_DSN=host=$REPO port=5432 user=postgres password=$PW dbname=postgres sslmode=disable\n' > /etc/pgvigil-remote/pgvigil-remote.env"; }
# the remote untouched = its files byte for byte, the same running process, its folders' owner and mode and its account
REMFILES="/usr/local/bin/pgvigil-remote /etc/systemd/system/pgvigil-remote.service /etc/pgvigil-remote/pgvigil-remote.yaml /etc/pgvigil-remote/pgvigil-remote.env"
remstate() { insys sh -c "sha256sum $REMFILES; systemctl show -p MainPID -p ActiveEnterTimestampMonotonic pgvigil-remote; stat -c '%n %U:%G %a' /etc/pgvigil-remote /var/lib/pgvigil-remote/outbox /var/lib/pgvigil-remote/state; id pgvigil-remote"; }
# the operator's -upgrade: the $V2 binary fetched into a folder of its own, run with the owner's DSN and no dump
OWNER="postgres://postgres:$PW@$REPO:5432/postgres?sslmode=disable"
hubupgrade() { insys sh -c "rm -rf /root/up && mkdir -p /root/up && cd /root/up && curl -fsSL http://$ASSETS:8000/install.sh | PGVIGIL_VERSION=$V2 PGVIGIL_BASE_URL=http://$ASSETS:8000 PGVIGIL_NO_SERVICE=1 sh >/dev/null && PGV_OWNER='$OWNER' ./pgvigil install -upgrade -owner-dsn-env PGV_OWNER -no-dump"; }
remconfig
insys sh -c "curl -fsSL http://$ASSETS:8000/install.sh | PGVIGIL_VERSION=$V PGVIGIL_BASE_URL=http://$ASSETS:8000 sh -s -- --remote" >"$WORK/r1.out" 2>&1 || fail "install.sh --remote: $(cat "$WORK/r1.out")"
grep -q 'remote collector is installed and running' "$WORK/r1.out" || fail "install.sh --remote did not end with 'installed and running': $(cat "$WORK/r1.out")"
[[ "$(insys /usr/local/bin/pgvigil-remote version)" == "pgvigil $V ("* ]] || fail "the remote binary: $(insys /usr/local/bin/pgvigil-remote version 2>&1)"
[[ "$(hubstate)" == "$hub_before" ]] || fail "install -remote changed the hub (files, process, folder or account): $(diff <(echo "$hub_before") <(hubstate))"
[[ "$(insys systemctl is-active pgvigil)" == active ]] || fail "the hub's service is not active after install -remote"
[[ "$(insys systemctl is-active pgvigil-remote)" == active ]] || fail "pgvigil-remote is not active: $(insys journalctl -u pgvigil-remote --no-pager -n 20)"
[[ "$(insys systemctl show -p User --value pgvigil-remote)" == pgvigil-remote ]] || fail "pgvigil-remote does not run as pgvigil-remote"
insys systemctl show -p ExecStart --value pgvigil-remote | grep -q '/usr/local/bin/pgvigil-remote' || fail "the remote unit's ExecStart: $(insys systemctl show -p ExecStart --value pgvigil-remote)"
nb=0; for _ in $(seq 1 150); do nb=$(insys sh -c "find /var/lib/pgvigil-remote/outbox -name manifest.json -not -path '*.part/*' | wc -l"); [[ "$nb" -ge 1 ]] && break; sleep 1; done
[[ "$nb" -ge 1 ]] || fail "no finished bundle in 150 s: $(insys journalctl -u pgvigil-remote --no-pager -n 20)"
echo "ok   install.sh --remote beside the hub: /usr/local/bin/pgvigil-remote $V, active as pgvigil-remote, $nb bundle(s); the hub's binary, unit, config and env byte for byte, its process, folder and account the same"

echo "== install.sh --remote again over itself (its env file in /etc/pgvigil-remote) =="
insys sh -c "curl -fsSL http://$ASSETS:8000/install.sh | PGVIGIL_VERSION=$V PGVIGIL_BASE_URL=http://$ASSETS:8000 sh -s -- --remote" >"$WORK/r2.out" 2>&1 || fail "the second install.sh --remote: $(cat "$WORK/r2.out")"
[[ "$(insys systemctl is-active pgvigil-remote)" == active ]] || fail "pgvigil-remote not active after the second install"
echo "ok   the second install.sh --remote: active"

echo "== order hub-then-remote: the hub's 'pgvigil install -upgrade' to $V2 beside the remote changes only the hub =="
rem_before=$(remstate)
# the check can fail: a planted change to the remote's env file is seen, then the file is put back as it was
insys sh -c "cp -p /etc/pgvigil-remote/pgvigil-remote.env /root/rem.env.plant && echo '# plant' >> /etc/pgvigil-remote/pgvigil-remote.env"
[[ "$(remstate)" != "$rem_before" ]] || fail "the remote-state check did not see a planted change to its env file"
insys sh -c "cp -p /root/rem.env.plant /etc/pgvigil-remote/pgvigil-remote.env && rm -f /root/rem.env.plant"
[[ "$(remstate)" == "$rem_before" ]] || fail "the remote's env file was not put back as it was: $(diff <(echo "$rem_before") <(remstate))"
hubupgrade >"$WORK/up1.out" 2>&1 || fail "pgvigil install -upgrade ($V2) beside the remote: $(cat "$WORK/up1.out")"
grep -q '5. swapped the binary and started the service' "$WORK/up1.out" || fail "the upgrade did not end with '5. swapped the binary and started the service': $(cat "$WORK/up1.out")"
[[ "$(insys /usr/local/bin/pgvigil version)" == "pgvigil $V2 ("* ]] || fail "the hub's binary after -upgrade: $(insys /usr/local/bin/pgvigil version)"
[[ "$(insys systemctl is-active pgvigil)" == active ]] || fail "the hub is not active after -upgrade"
[[ "$(remstate)" == "$rem_before" ]] || fail "the hub's -upgrade changed the remote (files, process, folders or account): $(diff <(echo "$rem_before") <(remstate))"
[[ "$(insys /usr/local/bin/pgvigil-remote version)" == "pgvigil $V ("* ]] || fail "the remote's binary after the hub's -upgrade: $(insys /usr/local/bin/pgvigil-remote version 2>&1)"
hub_before=$(hubstate)   # the hub after its upgrade (a new binary and process): what the remote's uninstall must keep
echo "ok   the hub's install -upgrade beside the remote: /usr/local/bin/pgvigil $V2 and active; the remote's binary ($V), unit, config, env, process, folders and account the same (the check saw a planted change first)"

echo "== uninstall -remote -purge: refused with bundles in the outbox, then -force; the hub untouched =="
if insys /usr/local/bin/pgvigil-remote uninstall -remote -purge >"$WORK/r3.out" 2>&1; then fail "uninstall -remote -purge with bundles was not refused: $(cat "$WORK/r3.out")"; fi
{ grep -q 'not pushed' "$WORK/r3.out" && grep -q 'lost' "$WORK/r3.out" && grep -q -- '-force' "$WORK/r3.out"; } || fail "the refusal's words: $(cat "$WORK/r3.out")"
[[ "$(insys systemctl is-active pgvigil-remote)" == active ]] || fail "the refusal stopped pgvigil-remote"
insys /usr/local/bin/pgvigil-remote uninstall -remote -purge -force >"$WORK/r4.out" 2>&1 || fail "uninstall -remote -purge -force: $(cat "$WORK/r4.out")"
grep -q 'removed with -force' "$WORK/r4.out" || fail "the bundles removed with -force are not named: $(cat "$WORK/r4.out")"
for p in /etc/systemd/system/pgvigil-remote.service /etc/pgvigil-remote /var/lib/pgvigil-remote /usr/local/bin/pgvigil-remote; do insys test ! -e "$p" || fail "$p is still there: $(cat "$WORK/r4.out")"; done
insys id -u pgvigil-remote >/dev/null || fail "the account pgvigil-remote went (uninstall keeps it)"
grep -q 'userdel pgvigil-remote' "$WORK/r4.out" || fail "the kept account is not named"
[[ "$(hubstate)" == "$hub_before" ]] || fail "uninstall -remote changed the hub (files, process, folder or account): $(diff <(echo "$hub_before") <(hubstate))"
[[ "$(insys systemctl is-active pgvigil)" == active ]] || fail "the hub's service is not active after uninstall -remote"
echo "ok   uninstall -remote -purge refused with bundles; -force removed the unit, /etc/pgvigil-remote, /var/lib/pgvigil-remote and the binary, kept and named the account; the hub's files, process, folder and account the same"

echo "== uninstall =="
insys /usr/local/bin/pgvigil uninstall >"$WORK/u1.out" 2>&1 || fail "uninstall: $(cat "$WORK/u1.out")"
insys systemctl status pgvigil >/dev/null 2>&1 && fail "the unit still exists after uninstall" || true
insys test -f /etc/pgvigil/pgvigil.yaml || fail "uninstall removed the config"
insys test -x /usr/local/bin/pgvigil || fail "uninstall removed the binary"
insys /usr/local/bin/pgvigil uninstall -purge >"$WORK/u2.out" 2>&1 || fail "uninstall -purge: $(cat "$WORK/u2.out")"
insys test ! -e /etc/pgvigil || fail "-purge kept /etc/pgvigil"
insys test ! -e /usr/local/bin/pgvigil || fail "-purge kept the binary"
echo "ok   uninstall keeps config and binary; -purge removes both"

echo "== order remote-then-hub: the remote first on a host with no hub, then the hub's install and -upgrade =="
remconfig
insys sh -c "curl -fsSL http://$ASSETS:8000/install.sh | PGVIGIL_VERSION=$V PGVIGIL_BASE_URL=http://$ASSETS:8000 sh -s -- --remote" >"$WORK/o1.out" 2>&1 || fail "install.sh --remote on a host with no hub: $(cat "$WORK/o1.out")"
[[ "$(insys systemctl is-active pgvigil-remote)" == active ]] || fail "pgvigil-remote is not active (no hub on the host)"
rem_before=$(remstate)
insys sh -c "curl -fsSL http://$ASSETS:8000/install.sh | PGVIGIL_VERSION=$V PGVIGIL_BASE_URL=http://$ASSETS:8000 sh" >"$WORK/o2.out" 2>&1 || fail "the hub's install.sh after the remote: $(cat "$WORK/o2.out")"
grep -q 'installed and enabled' "$WORK/o2.out" || fail "the hub's install after the remote did not end with 'installed and enabled': $(cat "$WORK/o2.out")"
[[ "$(remstate)" == "$rem_before" ]] || fail "the hub's install changed the remote (files, process, folders or account): $(diff <(echo "$rem_before") <(remstate))"
[[ "$(insys sh -c 'command -v pgvigil; command -v pgvigil-remote' | tr '\n' ' ')" == "/usr/local/bin/pgvigil /usr/local/bin/pgvigil-remote " ]] || fail "the commands resolve to: $(insys sh -c 'command -v pgvigil; command -v pgvigil-remote' | tr '\n' ' ')"
hubupgrade >"$WORK/o3.out" 2>&1 || fail "pgvigil install -upgrade ($V2) with the remote installed first: $(cat "$WORK/o3.out")"
grep -q '5. swapped the binary; the service is enabled, not started' "$WORK/o3.out" || fail "the upgrade did not end with '5. swapped the binary; the service is enabled, not started': $(cat "$WORK/o3.out")"
[[ "$(insys /usr/local/bin/pgvigil version)" == "pgvigil $V2 ("* ]] || fail "the hub's binary after -upgrade: $(insys /usr/local/bin/pgvigil version)"
[[ "$(remstate)" == "$rem_before" ]] || fail "the hub's -upgrade changed the remote installed first (files, process, folders or account): $(diff <(echo "$rem_before") <(remstate))"
hub_before=$(hubstate)
insys /usr/local/bin/pgvigil-remote uninstall -remote -purge -force >"$WORK/o4.out" 2>&1 || fail "pgvigil-remote uninstall -remote -purge -force (the remote installed first): $(cat "$WORK/o4.out")"
insys test ! -e /usr/local/bin/pgvigil-remote || fail "the remote's binary is still there: $(cat "$WORK/o4.out")"
[[ "$(hubstate)" == "$hub_before" ]] || fail "the remote's uninstall changed the hub installed after it (files, process, folder or account): $(diff <(echo "$hub_before") <(hubstate))"
insys /usr/local/bin/pgvigil uninstall -purge >"$WORK/o5.out" 2>&1 || fail "the hub's uninstall -purge: $(cat "$WORK/o5.out")"
insys test ! -e /usr/local/bin/pgvigil || fail "-purge kept the hub's binary"
echo "ok   the remote first, then the hub: the hub's install and its install -upgrade ($V2) left the remote's binary, unit, config, env, process, folders and account as they were; pgvigil and pgvigil-remote each resolve to their own binary; the remote's uninstall left the hub as it was"
echo "proof-install: OK (both install orders - the hub's install -upgrade changes only the hub, the remote's uninstall only the remote; the remote collector beside the hub - install.sh --remote, its bundle, the hub byte for byte, the second install, the uninstall guard and -force; checksum refusal, shared folder refused, install with an empty repository DSN (not started), the unconfigured start exits 3 without a loop, the DSN filled in with no instance in the file starting the service, the upgrade path keeping the config and collecting as pgvigil with $n sample(s), uninstall, purge; busybox parse)"
