#!/usr/bin/env bash
# proof-uninstall.sh - pgvigil uninstall -all on Linux, proven in a systemd container with no network (task 203,
# docs/uninstall.md). Each section prints one 'ok' line or stops at the first FAIL.
#
# T  go test cmd/pgvigil (the uninstall's own tests among them), GOOS=windows vet, golangci-lint
# S  this build installed fresh (its account marked 'created by pgvigil install') on PostgreSQL 17 (PGDG: the 16+ role
#    rules), the repository migrated by its owner (a CREATEROLE login), the agent and UI logins, the service collecting
# C  refusals: not root, no terminal and no -confirm-database, a wrong -confirm-database, no owner DSN, an owner DSN
#    naming another database than this host's configuration, a -bin that disagrees, a role the owner holds no ADMIN
#    OPTION on (16+), a session held on the repository, a second collector writing; each leaves the host as it was
#    (files, unit, account, roles, databases, the service running); the first seven before the stop (no stop said),
#    the last two after the stop and the 75 s watch
# P  the dry run: every item and what would be done, a group another database uses kept, another login listed with its
#    DROP ROLE line, nothing changed
# U  uninstall -all -drop-repository: the order of its steps; nothing of pgvigil left, read back item by item; the dump
#    0600 and restorable
# R  a second run, with and without -drop-repository: 'nothing of pgvigil is left to remove', exit 0
# K  an account the install did not make and a file of the operator's in the configuration folder: kept and named
#
# Not here: Windows (the app, the registry, the PATH entry, the service by the SCM): scripts/proof-uninstall-windows.ps1.
# Needs: docker, go, golangci-lint on a Linux amd64 machine. PGVIGIL_PROOF_KEEP=1 keeps a failed run's container.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
V=v0.0.0-uninstall
TAG="pgvun$RANDOM"; SYS="$TAG-sys"; IMG="pgvigil-proof-uninstall:bookworm-pg17"
OPW="ow$RANDOM$RANDOM"; APW="ag$RANDOM$RANDOM"; UPW="ui$RANDOM$RANDOM"; MPW="mo$RANDOM$RANDOM"
WORK=$(mktemp -d)
cleanup() {
  if [[ "${PGVIGIL_PROOF_KEEP:-}" = "1" && "${FAILED:-}" = "1" ]]; then echo "kept: $SYS, files in $WORK"; return; fi
  docker rm -f -v "$SYS" >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'FAILED=1; echo "FAIL: line $LINENO ended the run: $BASH_COMMAND" >&2' ERR
fail() {
  FAILED=1; echo "FAIL: $*" >&2
  docker exec "$SYS" journalctl -u pgvigil --no-pager -n 15 2>/dev/null | sed 's/^/  journal: /' >&2 || true
  exit 1
}
ok() { echo "ok   $*"; }
insys() { docker exec "$SYS" "$@"; }
pq() { docker exec -u postgres "$SYS" psql -d "${PQDB:-pgvigil}" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
for t in docker go golangci-lint; do command -v "$t" >/dev/null || fail "$t is not on this machine"; done
[[ "$(uname -s)/$(uname -m)" == "Linux/x86_64" ]] || fail "a Linux amd64 machine is needed"
B=/usr/local/bin/pgvigil; C=/etc/pgvigil/pgvigil.yaml; E=/etc/pgvigil/pgvigil.env; U=/etc/systemd/system/pgvigil.service

echo "== T the tests, vet and lint =="
go test -count=1 ./cmd/pgvigil/ >"$WORK/test.out" 2>&1 || { tail -30 "$WORK/test.out" >&2; fail "go test ./cmd/pgvigil"; }
GOOS=windows go vet ./cmd/pgvigil/ >"$WORK/vetw.out" 2>&1 || { cat "$WORK/vetw.out" >&2; fail "GOOS=windows go vet ./cmd/pgvigil"; }
golangci-lint run --allow-parallel-runners ./... >"$WORK/lint.out" 2>&1 || { tail -30 "$WORK/lint.out" >&2; fail "golangci-lint at the root"; }
# the uninstall's own tests by name, once into a file (a grep -q on go test's pipe would end it early under pipefail)
NAMED="TestUninstallFlags TestDecideGroup TestDecideLogin TestPathWithout TestUninstallAllOrder TestEnvValue"
go test -count=1 -run "^(${NAMED// /|})\$" -v ./cmd/pgvigil/ >"$WORK/named.out" 2>&1 || { tail -30 "$WORK/named.out" >&2; fail "the uninstall's tests"; }
for n in $NAMED; do grep -q -- "--- PASS: $n" "$WORK/named.out" || fail "$n did not run and pass"; done
ok "go test cmd/pgvigil (TestUninstallFlags, TestDecideGroup, TestDecideLogin, TestPathWithout, TestUninstallAllOrder, TestEnvValue among them), GOOS=windows vet, golangci-lint clean"

echo "== S this build installed, the repository, the logins, the service collecting =="
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$V" -o "$WORK/pgvigil" ./cmd/pgvigil
mkdir -p "$WORK/img"
cat > "$WORK/img/Dockerfile" <<'EOF'
FROM debian:bookworm-slim
ENV container=docker
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv procps ca-certificates curl \
 && install -d /usr/share/postgresql-common/pgdg \
 && curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc \
 && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update && apt-get install -y --no-install-recommends postgresql-17 \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl mask systemd-logind.service getty.target console-getty.service systemd-udevd.service systemd-udev-trigger.service systemd-networkd-wait-online.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF
docker build -q -t "$IMG" "$WORK/img" >/dev/null || fail "the image"
docker run -d --name "$SYS" --network none --privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock "$IMG" >/dev/null
st=""; for _ in $(seq 1 60); do st=$(insys systemctl is-system-running 2>/dev/null || true); [[ "$st" == running || "$st" == degraded ]] && break; sleep 1; done
[[ "$st" == running || "$st" == degraded ]] || fail "systemd did not come up in the container (state '$st')"
pgok=""; for _ in $(seq 1 60); do pgok=$(insys sh -c "su postgres -c 'psql -XAtqc \"select 1\"'" 2>/dev/null || true); [[ "$pgok" == 1 ]] && break; sleep 1; done
[[ "$pgok" == 1 ]] || fail "PostgreSQL did not answer inside the container"
[[ "$(insys ls /sys/class/net)" == lo ]] || fail "the container has interfaces: $(insys ls /sys/class/net | tr '\n' ' ')"
PGMAJ=$(PQDB=postgres pq "select current_setting('server_version_num')::int / 10000")
[[ "$PGMAJ" -ge 16 ]] || fail "PostgreSQL $PGMAJ in the container: the proof needs 16+ (the role rules)"
docker cp "$WORK/pgvigil" "$SYS:/root/pgvigil" >/dev/null && insys chmod 0755 /root/pgvigil
insys /root/pgvigil install >"$WORK/s1.out" 2>&1 || fail "the install: $(cat "$WORK/s1.out")"
mark=$(insys getent passwd pgvigil | cut -d: -f5)
[[ "$mark" == "created by pgvigil install" ]] || fail "the account install made carries '$mark', not the mark"
PQDB=postgres pq "CREATE ROLE pgvigil_owner LOGIN CREATEROLE PASSWORD '$OPW'" >/dev/null
PQDB=postgres pq "CREATE DATABASE pgvigil OWNER pgvigil_owner" >/dev/null
OWNER_DSN="host=127.0.0.1 port=5432 user=pgvigil_owner password=$OPW dbname=pgvigil sslmode=disable"
insys sh -c "PGVIGIL_REPO_DSN='$OWNER_DSN' $B migrate -config $C" >"$WORK/m0.out" 2>&1 || fail "migrate: $(tail -n 3 "$WORK/m0.out")"
FILES=$(pq "select count(*) from pgvigil.schema_version")
insys "$B" roles > "$WORK/roles.sql"
for l in agent:"$APW" ui:"$UPW" monitor:"$MPW"; do
  line=$(grep -E "^CREATE ROLE pgvigil_${l%%:*} LOGIN PASSWORD '<set-me>'" "$WORK/roles.sql" | head -n 1) || fail "'pgvigil roles' prints no CREATE ROLE for pgvigil_${l%%:*}"
  if [[ "${l%%:*}" == monitor ]]; then PQDB=postgres pq "${line/<set-me>/${l#*:}}" >/dev/null
  else insys sh -c "PGPASSWORD='$OPW' psql -h 127.0.0.1 -U pgvigil_owner -d pgvigil -XAtq -v ON_ERROR_STOP=1 -c \"${line/<set-me>/${l#*:}}\"" >/dev/null; fi
done
insys sh -c "printf 'PGVIGIL_REPO_DSN=host=127.0.0.1 port=5432 user=pgvigil_agent password=$APW dbname=pgvigil sslmode=disable\nPROOF_TARGET_DSN=host=127.0.0.1 port=5432 user=pgvigil_monitor password=$MPW dbname=postgres sslmode=disable\n' >> $E"
insys sh -c "sed -i 's/^instances: \[\]/instances:\n  - name: proof-target\n    dsn: env:PROOF_TARGET_DSN\n    tags: [proof]/' $C"
insys systemctl restart pgvigil
n=0; for _ in $(seq 1 90); do n=$(pq "select count(*) from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = 'proof-target'" 2>/dev/null || echo 0); [[ "$n" -gt 0 ]] && break; sleep 1; done
[[ "$n" -gt 0 ]] || fail "no collection_dates row for proof-target within 90 s"
insys cp "$B" "$B.previous"   # an upgrade's copy of the binary it replaced (task 202)
insys sh -c "umask 077; printf '%s\n' '$OWNER_DSN' > /root/owner.dsn"
ok "$V installed fresh at $B on PostgreSQL $PGMAJ (account pgvigil marked '$mark'), the repository migrated by its owner ($FILES files), the agent, UI and monitor logins, the service collecting proof-target ($n collection_dates rows); $B.previous beside it"

# the host's state: the files, the unit, the account and group, the service, the roles and the databases
fp() {
  insys sh -c "for f in $B $B.previous $C $E $U /etc/pgvigil /var/backups/pgvigil; do if [ -e \"\$f\" ]; then echo \"\$f \$(stat -c '%a %U %G' \"\$f\") \$( [ -f \"\$f\" ] && sha256sum < \"\$f\" | cut -c1-16)\"; else echo \"\$f -\"; fi; done
    getent passwd pgvigil; getent group pgvigil; systemctl is-enabled pgvigil 2>&1; systemctl is-active pgvigil 2>&1; true"
  PQDB=postgres pq "select string_agg(rolname, ',' order by rolname) from pg_roles where rolname like 'pgvigil%'"
  PQDB=postgres pq "select string_agg(datname, ',' order by datname) from pg_database"
}
same() { local now; now=$(fp); [[ "$now" == "$F0" ]] || { diff <(echo "$F0") <(echo "$now") >&2 || true; fail "$1 changed the host"; }; }
refused() { # name, text the refusal says, the command (run inside the container)
  local name=$1 want=$2; shift 2
  if insys "$@" </dev/null >"$WORK/c.out" 2>&1; then fail "$name: the uninstall ran: $(cat "$WORK/c.out")"; fi
  grep -qF -- "$want" "$WORK/c.out" || fail "$name: the refusal did not say '$want': $(cat "$WORK/c.out")"
  cp "$WORK/c.out" "$WORK/c-${name// /-}.out"
}
before_stop() { # the refusal came before any change: it says so and never stopped the service
  grep -qF "uninstall refused, nothing was changed" "$WORK/c.out" || fail "$1: no 'nothing was changed': $(cat "$WORK/c.out")"
  if grep -q '^stopped the service' "$WORK/c.out"; then fail "$1: refused only after the stop: $(cat "$WORK/c.out")"; fi
}
ALLDROP=("$B" uninstall -all -drop-repository -confirm-database pgvigil -owner-dsn-file /root/owner.dsn)

echo "== C refusals: each leaves the host as it was =="
F0=$(fp)
[[ "$F0" == *"active"* ]] || fail "the service is not active before the refusals: $F0"
refused "not root" "uninstall -all needs root" su -s /bin/sh nobody -c "$B uninstall -all"
before_stop "not root"; same "not root"
refused "no terminal" "type its name at a terminal, or pass -confirm-database pgvigil" "$B" uninstall -all -drop-repository -owner-dsn-file /root/owner.dsn
before_stop "no terminal"; same "no terminal and no -confirm-database"
refused "wrong name" "-confirm-database pgvigil_x is not the repository database's name pgvigil" "$B" uninstall -all -drop-repository -confirm-database pgvigil_x -owner-dsn-file /root/owner.dsn
before_stop "wrong name"; same "a wrong -confirm-database"
refused "no owner" "the repository owner's connection string is not given" "$B" uninstall -all -drop-repository -confirm-database pgvigil
before_stop "no owner"; same "no owner DSN"
insys sh -c "umask 077; printf '%s\n' '${OWNER_DSN/dbname=pgvigil/dbname=pgvigl}' > /root/owner-typo.dsn"
refused "other database" "the owner's connection string names the database pgvigl and this host's configuration pgvigil" "$B" uninstall -all -drop-repository -confirm-database pgvigl -owner-dsn-file /root/owner-typo.dsn
before_stop "other database"; same "an owner DSN naming another database"
refused "bin" "-bin /opt/elsewhere/pgvigil disagrees with the installed service's $B" "$B" uninstall -all -bin /opt/elsewhere/pgvigil
before_stop "bin"; same "a -bin that disagrees"
# PostgreSQL 16+: a CREATEROLE login needs ADMIN OPTION on a role to drop it; without it the drop is refused up front
PQDB=postgres pq "REVOKE ADMIN OPTION FOR pgvigil_alerter FROM pgvigil_owner" >/dev/null
refused "no admin option" "DROP ROLE needs ADMIN OPTION on the role, and the owner's login pgvigil_owner holds none on pgvigil_alerter" "${ALLDROP[@]}"
before_stop "no admin option"
PQDB=postgres pq "GRANT pgvigil_alerter TO pgvigil_owner WITH ADMIN OPTION, INHERIT FALSE, SET FALSE" >/dev/null
same "a role without ADMIN OPTION"
# a session held on the repository: refused after the stop and the watch; the service runs again
docker exec -d -u postgres "$SYS" psql -d pgvigil -XAtqc "select pg_sleep(900) /* proof-held */"
h=0; for _ in $(seq 1 20); do h=$(PQDB=postgres pq "select count(*) from pg_stat_activity where datname = 'pgvigil' and query like '%proof-held%' and pid <> pg_backend_pid()"); [[ "$h" == 1 ]] && break; sleep 1; done
[[ "$h" == 1 ]] || fail "the held session did not start"
refused "held session" "other sessions are connected to pgvigil" "${ALLDROP[@]}"
grep -q '^stopped the service' "$WORK/c.out" && grep -q 'watching the repository for 1m15s' "$WORK/c.out" && grep -q 'the service runs again, nothing else was changed' "$WORK/c.out" || fail "the held session's refusal did not stop, watch and start again: $(cat "$WORK/c.out")"
grep -q 'psql from a local socket as postgres' "$WORK/c.out" || fail "the held session is not named: $(cat "$WORK/c.out")"
PQDB=postgres pq "select pg_terminate_backend(pid) from pg_stat_activity where query like '%proof-held%' and pid <> pg_backend_pid()" >/dev/null
same "a held session"
# a second collector writing into the repository from 'another host': refused after the watch; the service runs again
DSNV=$(insys sed -n 's/^PGVIGIL_REPO_DSN=//p' "$E" | tail -n 1); TGT=$(insys sed -n 's/^PROOF_TARGET_DSN=//p' "$E" | tail -n 1)
[[ -n "$DSNV" && -n "$TGT" ]] || fail "the env file's DSNs"
P2=$(insys sh -c "PGVIGIL_REPO_DSN='$DSNV' PROOF_TARGET_DSN='$TGT' setsid /root/pgvigil run -config $C >/root/second.log 2>&1 < /dev/null & echo \$!")
sleep 5; insys kill -0 "$P2" 2>/dev/null || fail "the second collector exited: $(insys tail -n 5 /root/second.log)"
refused "second collector" "another collector writes into pgvigil" "${ALLDROP[@]}"
grep -q 'the service runs again, nothing else was changed' "$WORK/c.out" || fail "the second collector's refusal did not start the service again: $(cat "$WORK/c.out")"
insys kill "$P2"; gone=""; for _ in $(seq 1 30); do insys kill -0 "$P2" 2>/dev/null || { gone=1; break; }; sleep 1; done
[[ -n "$gone" ]] || fail "the second collector (pid $P2) did not end within 30 s of SIGTERM: $(insys tail -n 5 /root/second.log)"
same "a second collector"
ok "refused with nothing changed, before the stop: not root, no terminal and no -confirm-database, a wrong -confirm-database, no owner DSN, an owner DSN naming another database, a -bin that disagrees, a role without ADMIN OPTION (PostgreSQL $PGMAJ); after the stop and the 75 s watch, the service started again: a held psql session (named), a second collector writing"

echo "== P the dry run =="
PQDB=postgres pq "CREATE DATABASE pgvigil_other" >/dev/null
PQDB=postgres pq "GRANT CONNECT ON DATABASE pgvigil_other TO pgvigil_reader" >/dev/null
F0=$(fp)
insys "$B" uninstall -all -dry-run -drop-repository -owner-dsn-file /root/owner.dsn >"$WORK/p.out" 2>&1 || fail "the dry run: $(cat "$WORK/p.out")"
for l in "remove   the service pgvigil (systemd unit $U)" "remove   the binary $B" "remove   the previous binary $B.previous" \
  "remove   the configuration $C" "remove   the environment file $E" "remove   the configuration folder /etc/pgvigil" "remove   the service account pgvigil" \
  "remove   the database pgvigil (" "a dump first to /var/backups/pgvigil/pgvigil-before-uninstall-" "remove   the login role pgvigil_agent (the login this host's configuration names)" \
  "remove   the group role pgvigil_collector" "remove   the group role pgvigil_auth" "remove   the group role pgvigil_alerter" \
  "kept     the group role pgvigil_reader: used in pgvigil_other" \
  "kept     the login role pgvigil_ui: not the login this host's configuration names; when nothing else uses it: DROP ROLE \"pgvigil_ui\";" \
  "kept     the login role pgvigil_owner: the owner's login this uninstall connects as" "the monitored servers: never touched here" "dry run: nothing was changed"; do
  grep -qF -- "$l" "$WORK/p.out" || fail "the dry run did not say '$l': $(cat "$WORK/p.out")"
done
if grep -q 'role pgvigil_monitor' "$WORK/p.out"; then fail "the dry run plans a step for the monitored server's login: $(cat "$WORK/p.out")"; fi
same "the dry run"
# the owner's own steps the dry run named: the grant elsewhere revoked, the UI login dropped by its printed line
PQDB=postgres pq "REVOKE CONNECT ON DATABASE pgvigil_other FROM pgvigil_reader" >/dev/null
PQDB=postgres pq "DROP DATABASE pgvigil_other" >/dev/null
uiline=$(grep -oF 'DROP ROLE "pgvigil_ui";' "$WORK/p.out" | head -n 1)
insys sh -c "PGPASSWORD='$OPW' psql -h 127.0.0.1 -U pgvigil_owner -d postgres -XAtq -v ON_ERROR_STOP=1 -c '$uiline'" >/dev/null || fail "the printed line '$uiline'"
ok "the dry run: every item 'remove' with the dump's file, pgvigil_reader kept while pgvigil_other holds a grant, pgvigil_ui listed with its DROP ROLE line (run by the owner after), the owner's login named, pgvigil_monitor untouched; nothing changed"

echo "== U uninstall -all -drop-repository =="
ROWS=$(pq "select count(*) from pgvigil.collection_dates")
insys "${ALLDROP[@]}" </dev/null >"$WORK/u.out" 2>&1 || fail "the uninstall: $(cat "$WORK/u.out")"
prev=0
for l in "stopped the service" "watching the repository for 1m15s" "dumped the repository to /var/backups/pgvigil/pgvigil-before-uninstall-" "dropped the database pgvigil" \
  "dropped the role pgvigil_agent" "dropped the role pgvigil_collector" "dropped the role pgvigil_reader" "dropped the role pgvigil_auth" "dropped the role pgvigil_alerter" \
  "removed: the service pgvigil" "removed: the binary $B" "removed: the previous binary" "removed: the configuration $C" "removed: the environment file" \
  "removed: the configuration folder /etc/pgvigil" "removed: the service account pgvigil" "kept: the dump /var/backups/pgvigil/pgvigil-before-uninstall-" "pgvigil is uninstalled from this host"; do
  at=$(grep -nF -- "$l" "$WORK/u.out" | head -n 1 | cut -d: -f1)
  [[ -n "$at" && "$at" -gt "$prev" ]] || fail "'$l' is not in its place (after line $prev): $(cat "$WORK/u.out")"
  prev=$at
done
left=$(insys sh -c "for f in $B $B.previous $C $E $U /etc/pgvigil; do [ -e \"\$f\" ] && echo \"\$f\"; done; getent passwd pgvigil; getent group pgvigil; systemctl list-unit-files --no-legend pgvigil.service; true")
[[ -z "$left" ]] || fail "left on the host: $left"
roles=$(PQDB=postgres pq "select string_agg(rolname, ',' order by rolname) from pg_roles where rolname like 'pgvigil%'")
[[ "$roles" == "pgvigil_monitor,pgvigil_owner" ]] || fail "the roles left: $roles (want only the monitored server's login and the owner's own login)"
[[ "$(PQDB=postgres pq "select count(*) from pg_database where datname = 'pgvigil'")" == 0 ]] || fail "the database pgvigil is still there"
DUMPF=$(grep -o '/var/backups/pgvigil/pgvigil-before-uninstall-[^ ]*\.dump' "$WORK/u.out" | head -n 1)
[[ "$(insys stat -c '%a %U' "$DUMPF")" == "600 root" && "$(insys stat -c '%a %U' /var/backups/pgvigil)" == "700 root" ]] || fail "the dump's modes: $(insys stat -c '%n %a %U' "$DUMPF" /var/backups/pgvigil)"
PQDB=postgres pq "CREATE DATABASE pgvigil_back" >/dev/null
insys sh -c "cp $DUMPF /tmp/u.dump && chown postgres /tmp/u.dump"
insys su postgres -c "pg_restore --no-owner --no-privileges -d pgvigil_back /tmp/u.dump" >"$WORK/restore.out" 2>&1 || fail "pg_restore: $(tail -n 5 "$WORK/restore.out")"
[[ "$(PQDB=pgvigil_back pq "select count(*) from pgvigil.schema_version")" == "$FILES" && "$(PQDB=pgvigil_back pq "select count(*) from pgvigil.collection_dates")" -ge "$ROWS" ]] || fail "the restored dump's counts"
ok "in order: stopped, watched 75 s, dumped, the database dropped, pgvigil_agent then the four groups dropped, the service, the binaries, the configuration and the account removed; read back: no file, unit, account or group, roles left only pgvigil_monitor (the monitored server's) and pgvigil_owner (the owner's own, named), no database pgvigil; the dump 600 root in a 700 folder restores ($FILES migration rows, collection_dates complete)"

echo "== R the second run =="
insys /root/pgvigil uninstall -all -drop-repository -confirm-database pgvigil -owner-dsn-file /root/owner.dsn </dev/null >"$WORK/r1.out" 2>&1 || fail "the second run with -drop-repository: $(cat "$WORK/r1.out")"
insys /root/pgvigil uninstall -all </dev/null >"$WORK/r2.out" 2>&1 || fail "the second run: $(cat "$WORK/r2.out")"
for f in r1 r2; do
  for l in "nothing of pgvigil is left to remove" "kept     the dump folder /var/backups/pgvigil"; do grep -qF -- "$l" "$WORK/$f.out" || fail "$f did not say '$l': $(cat "$WORK/$f.out")"; done
  if grep -q '^  remove ' "$WORK/$f.out"; then fail "$f plans a removal: $(cat "$WORK/$f.out")"; fi
done
grep -qF "absent   the database pgvigil" "$WORK/r1.out" && grep -qF "absent   the pgvigil roles" "$WORK/r1.out" || fail "the second run's repository lines: $(cat "$WORK/r1.out")"
ok "a second run, with and without -drop-repository: every item absent, 'nothing of pgvigil is left to remove', exit 0, the dump folder named"

echo "== K what the install did not make =="
insys useradd --system --no-create-home --shell /usr/sbin/nologin pgvsvc
insys /root/pgvigil install -user pgvsvc >"$WORK/k1.out" 2>&1 || fail "the install on pgvsvc: $(cat "$WORK/k1.out")"
insys sh -c 'echo "the operator" > /etc/pgvigil/operator-notes.txt'
insys "$B" uninstall -all </dev/null >"$WORK/k2.out" 2>&1 || fail "uninstall -all: $(cat "$WORK/k2.out")"
for l in "kept: the service account pgvsvc: install did not make it" "userdel pgvsvc" "kept: the configuration folder /etc/pgvigil: it holds files the installer did not write (operator-notes.txt)" "removed: the binary $B" "removed: the configuration $C"; do
  grep -qF -- "$l" "$WORK/k2.out" || fail "K did not say '$l': $(cat "$WORK/k2.out")"
done
insys getent passwd pgvsvc >/dev/null || fail "the account pgvsvc was removed"
insys test -f /etc/pgvigil/operator-notes.txt || fail "the operator's file was removed"
[[ -z "$(insys sh -c "for f in $B $C $E $U; do [ -e \"\$f\" ] && echo \"\$f\"; done; true")" ]] || fail "K left the installer's files"
ok "an account that was there before (no mark) and an operator's file kept and named with their lines; the rest removed"

echo "proof-uninstall: OK (uninstall -all removes this host's pgvigil in order, -drop-repository the database and the roles nothing else holds; nine refusals change nothing; the dry run changes nothing; a second run finds nothing to remove; what the install did not make stays, named)"
