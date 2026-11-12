#!/usr/bin/env bash
# Proof of the offline install and upgrade (task 202): this tree's release folder is laid out as release.yml lays one
# out (unsigned: the keyless signature needs the workflow's identity), scripts/package-offline.sh makes the two offline
# bundles from it, and the Linux bundle installs and upgrades pgvigil on a Debian 12 systemd container started with NO
# network at all (--network none: the loopback only), with PostgreSQL inside it as the repository and as the monitored
# server. This machine stands in for the connected side: it builds, fetches the released v0.3.0 and its SHA256SUMS, and
# copies both into the container (the air gap's carry).
# Needs docker, go, git, python3, curl, sha256sum, tar on a Linux amd64 machine with Internet access (the release, the
# image, the Go modules); cyclonedx-gomod in $HOME/go/bin (installed at v1.12.0 when missing); shellcheck, dash and pwsh
# are used where present (their absence is said).
#   PGVIGIL_OFFLINE_FROM    the released tag the store starts from (default v0.3.0; its linux_amd64_fips build)
#   PGVIGIL_OFFLINE_DAYS    the days of demo history the old version seeds (default 1)
#   PGVIGIL_PROOF_KEEP=1    leave the container after a failure (for a look)
#
# Expected (written before the first run):
#  T tests     go test ./cmd/pgvigil/ ./internal/repo/ and the app module's tests green; GOOS=windows go vet of cmd/pgvigil
#              and of app/ clean; golangci-lint 0 issues at the root and in app/; install.sh: sh -n and dash -n, shellcheck
#              -s sh with no finding (where present); install.ps1 parses (pwsh, where present)
#  B bundle    package-offline.sh --unsigned writes pgvigil-offline-<v>-linux-amd64.tar.gz (8 files: the plain and FIPS
#              binaries, the SBOM, install.sh, airgap.md, upgrade.md, uninstall.md, SHA256SUMS) and -windows-amd64.zip (10:
#              the two exes, the app zip, two SBOMs, install.ps1, the three docs, SHA256SUMS), each under one top folder;
#              every tar entry owned 0/0; every file but SHA256SUMS has its line in SHA256SUMS; a second run gives the same
#              bytes; without --unsigned it refuses (the signature files missing); with a file left out of SHA256SUMS it
#              refuses
#  N no network inside: /sys/class/net holds lo only, github.com does not resolve; the bundle extracted by root is
#              root's, file by file
#  A fresh     a copy of the bundle with one byte of the binary changed: 'checksum mismatch for pgvigil_<v>_linux_amd64:
#              nothing was installed', no unit, no binary; a copy with install.sh changed: 'checksum mismatch for
#              install.sh itself'; the bundle itself: 'signature not verified here', '(plain build) checksum verified',
#              'installed and enabled', /usr/local/bin/pgvigil prints <v> and fips140 off, the unit written; then
#              uninstall -purge and userdel leave neither
#  O old store v0.3.0's FIPS build installed with -bin /opt/pgv/bin/pgvigil -config /srv/pgvigil/pgvigil.yaml -user pgvsvc;
#              its migrate as the owner, the logins 'pgvigil roles' prints, its demo over the days asked (12 instances),
#              the live server as an instance; the unit running; an activity sample of the live instance arrives
#  C refusals  each ends non-zero with its own line and changes nothing (the unit's main PID, the installed binary's
#              sha256, schema_version's count, the backup folder's mode and file count, and no .previous, as before):
#              not root ('the upgrade needs root', run as nobody); no owner DSN ('the
#              repository owner's connection string is not given'); a -bin that disagrees ('disagrees with the installed
#              service's /opt/pgv/bin/pgvigil'); a pg_dump 12 against PostgreSQL 15 ('is pg_dump 12 and the repository's
#              server is PostgreSQL 15'); a dump on a 64 KiB tmpfs ('free and the repository is'); a second process on the
#              installed binary ('other processes run the installed binary', its pid named)
#  M migrate   with the database read only by default the upgrade keeps the previous binary (before the stop), stops,
#    fails     dumps, and its migrate fails: 'the migrate failed: the binary was not swapped and the service stays
#              stopped' and the way back; the unit inactive, the binary unchanged, .previous = the old binary, schema_version
#              as before, the dump file there (0600); after the reset the old collector starts again
#  U upgrade   install.sh --from with --owner-dsn-file: steps 1 (previous kept) to 5 (swapped, started) printed, 'installed and running', the way back; the
#              dump in /var/backups/pgvigil (0700 root) as a 0600 file pg_restore lists; /opt/pgv/bin/pgvigil.previous is
#              the v0.3.0 FIPS binary byte for byte; the installed binary prints <v> and fips140 on (the flavour kept,
#              no switch given); the unit keeps ExecStart=/opt/pgv/bin/pgvigil run -config /srv/pgvigil/pgvigil.yaml and
#              User=pgvsvc; the config and env file byte for byte as before; schema_version = this tree's files; every
#              table with an instance column holds, outside the live instance, its row count and its rows' md5 over the
#              columns v0.3.0 had; a table without one has not shrunk; the collector writes an activity sample after
#              the restart
#  R re-run    install.sh --from again (the installed binary is already this one) with --dump into an existing folder
#              of another owner (0755, 65534): 'migrated ... 0 file(s)', 'already this one', .previous still v0.3.0's, the
#              folder's mode and owner as before, the dump file 0600 root's
#  D downgrade the repository naming a migration newer than this build's: 'newer than this build's newest migration',
#              nothing changed
#  W way back  the dump restored by the owner into a new database holds every instance table's rows as before the
#              upgrade (outside the live instance); .previous prints v0.3.0 and fips140 on
# NOT PROVEN HERE: the signature (the bundle is unsigned; proof-upgrade C verifies a real release offline), Windows
# (proof-offline-windows.ps1 on the Windows sandbox), a free-space shortfall on the default folder, a password with
# special characters through the password file (unit tests only), the installer from a share or a USB mount.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
OLD=${PGVIGIL_OFFLINE_FROM:-v0.3.0}; V=v0.0.0-offline; DAYS=${PGVIGIL_OFFLINE_DAYS:-1}
TAG="pgvoff$RANDOM"; SYS="$TAG-sys"; IMG="pgvigil-proof-offline:bookworm"
OPW="ow$RANDOM$RANDOM"; APW="ag$RANDOM$RANDOM"; UPW="ui$RANDOM$RANDOM"; MPW="mo$RANDOM$RANDOM"
WORK=$(mktemp -d)
REL=https://github.com/aachaemenes/pgvigil/releases/download
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
# pq: SQL as the cluster's superuser on the repository (peer login inside the container)
pq() { docker exec -u postgres "$SYS" psql -d "${PQDB:-pgvigil}" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
for t in docker go git python3 curl sha256sum tar; do command -v "$t" >/dev/null || fail "$t is not on this machine"; done
[[ "$(uname -s)/$(uname -m)" == "Linux/x86_64" ]] || fail "a Linux amd64 machine is needed"

echo "== T the tests, vet, lint and the installers' syntax =="
go test -count=1 ./cmd/pgvigil/ ./internal/repo/ >"$WORK/test.out" 2>&1 || { tail -30 "$WORK/test.out" >&2; fail "go test"; }
(cd app && go test -count=1 ./... >"$WORK/apptest.out" 2>&1) || { tail -30 "$WORK/apptest.out" >&2; fail "go test in app/"; }
GOOS=windows go vet ./cmd/pgvigil/ >"$WORK/vetw.out" 2>&1 || { cat "$WORK/vetw.out" >&2; fail "GOOS=windows go vet ./cmd/pgvigil"; }
(cd app && GOOS=windows go vet ./... >"$WORK/vetwa.out" 2>&1) || { cat "$WORK/vetwa.out" >&2; fail "GOOS=windows go vet in app/"; }
golangci-lint run --allow-parallel-runners ./... >"$WORK/lint.out" 2>&1 || { tail -30 "$WORK/lint.out" >&2; fail "golangci-lint at the root"; }
(cd app && golangci-lint run --allow-parallel-runners ./... >"$WORK/linta.out" 2>&1) || { tail -30 "$WORK/linta.out" >&2; fail "golangci-lint in app/"; }
syn="sh -n"; sh -n docs/install.sh || fail "sh -n docs/install.sh"
if command -v dash >/dev/null; then dash -n docs/install.sh || fail "dash -n docs/install.sh"; syn+=", dash -n"; else syn+=", no dash here"; fi
if command -v shellcheck >/dev/null; then shellcheck -s sh docs/install.sh scripts/package-offline.sh || fail "shellcheck"; syn+=", shellcheck clean"; else syn+=", no shellcheck here"; fi
if command -v pwsh >/dev/null; then
  pe=$(pwsh -NoProfile -Command '$e=$null; $t=$null; [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path docs/install.ps1), [ref]$t, [ref]$e); $e.Count')
  [[ "$pe" == 0 ]] || fail "install.ps1 does not parse ($pe errors)"; syn+=", install.ps1 parses"
else syn+=", no pwsh here"; fi
ok "go test (cmd/pgvigil, internal/repo, app), GOOS=windows vet, golangci-lint root and app/ clean; $syn"

echo "== B this tree's release folder and the offline bundles =="
D=$WORK/dist; mkdir -p "$D" "$WORK/app"
for t in linux/amd64 windows/amd64; do
  GOOS="${t%/*}"; GOARCH="${t#*/}"; ext=""; [ "$GOOS" = windows ] && ext=.exe
  CGO_ENABLED=0 GOOS=$GOOS GOARCH=$GOARCH go build -trimpath -ldflags "-s -w -X main.version=$V" -o "$D/pgvigil_${V}_${GOOS}_${GOARCH}${ext}" ./cmd/pgvigil
  CGO_ENABLED=0 GOFIPS140=v1.0.0 GOOS=$GOOS GOARCH=$GOARCH go build -trimpath -ldflags "-s -w -X main.version=$V" -o "$D/pgvigil_${V}_${GOOS}_${GOARCH}_fips${ext}" ./cmd/pgvigil
done
cp "$D/pgvigil_${V}_windows_amd64.exe" "$WORK/app/pgvigil.exe"
(cd app && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-s -w -H=windowsgui -X main.version=$V" -o "$WORK/app/pgvigil-app.exe" .)
python3 -I -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w",zipfile.ZIP_DEFLATED); [z.write(f, f.rsplit("/",1)[1]) for f in sys.argv[2:]]' \
  "$D/pgvigil-app_${V}_windows_amd64.zip" "$WORK/app/pgvigil-app.exe" "$WORK/app/pgvigil.exe"
# the SBOM tool reads the version from a tag, as at a release: a throwaway git repository of the tree, tagged (proof-upgrade's way)
command -v cyclonedx-gomod >/dev/null || go install github.com/CycloneDX/cyclonedx-gomod/cmd/cyclonedx-gomod@v1.12.0 >/dev/null 2>&1 || fail "go install cyclonedx-gomod"
mkdir -p "$WORK/src" && tar -C . --exclude=./.git --exclude=./web/node_modules --exclude=./.lab -cf - . | tar -C "$WORK/src" -xf -
(cd "$WORK/src" && git init -q . && git add -A && git -c user.name=proof -c user.email=proof@example.invalid commit -q -m "the tree under proof" && git tag "$V") || fail "the throwaway repository of the tree"
for t in linux/amd64 windows/amd64; do
  (cd "$WORK/src" && CGO_ENABLED=0 GOOS="${t%/*}" GOARCH="${t#*/}" cyclonedx-gomod app -json -licenses -main cmd/pgvigil -output "$D/pgvigil_${V}_${t%/*}_${t#*/}.cdx.json" .) >"$WORK/sbom.log" 2>&1 || fail "cyclonedx-gomod ($t): $(tail -n 3 "$WORK/sbom.log")"
done
(cd "$WORK/src/app" && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 cyclonedx-gomod app -json -licenses -main . -output "$D/pgvigil-app_${V}_windows_amd64.cdx.json" .) >"$WORK/sbom.log" 2>&1 || fail "cyclonedx-gomod (the app): $(tail -n 3 "$WORK/sbom.log")"
cp docs/install.sh docs/install.ps1 docs/airgap.md docs/upgrade.md docs/uninstall.md "$D/"
(cd "$D" && sha256sum -- * > SHA256SUMS)
bash scripts/package-offline.sh "$D" "$V" --unsigned >"$WORK/pkg.out" 2>&1 || { cat "$WORK/pkg.out" >&2; fail "package-offline.sh --unsigned"; }
LT="$D/pgvigil-offline-$V-linux-amd64.tar.gz"; WZ="$D/pgvigil-offline-$V-windows-amd64.zip"; TOPL="pgvigil-offline-$V-linux-amd64"
nl=$(tar -tzf "$LT" | grep -vc '/$'); tops=$(tar -tzf "$LT" | cut -d/ -f1 | sort -u)
[[ "$nl" == 8 && "$tops" == "$TOPL" ]] || fail "the Linux bundle: $nl files under '$tops' (want 8 under $TOPL)"
own=$(tar -tvzf "$LT" | awk '{print $2}' | sort -u)
[[ "$own" == "0/0" ]] || fail "the tar's owners: $own (want 0/0 only)"
read -r nw wtops <<<"$(python3 -I -c 'import sys,zipfile; n=zipfile.ZipFile(sys.argv[1]).namelist(); print(sum(1 for x in n if not x.endswith("/")), " ".join(sorted({x.split("/")[0] for x in n})))' "$WZ")"
[[ "$nw" == 10 && "$wtops" == "pgvigil-offline-$V-windows-amd64" ]] || fail "the Windows bundle: $nw files under '$wtops' (want 10)"
# every file but SHA256SUMS has its line; read back from inside the archives
mkdir -p "$WORK/x" && tar -C "$WORK/x" -xzf "$LT" && python3 -I -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$WZ" "$WORK/x"
for top in "$WORK/x/$TOPL" "$WORK/x/pgvigil-offline-$V-windows-amd64"; do
  (cd "$top" && for f in *; do [[ "$f" == SHA256SUMS ]] && continue; grep -q "  $f\$" SHA256SUMS || exit 1; done && sha256sum -c SHA256SUMS --ignore-missing --quiet) || fail "a file of $(basename "$top") is not in its SHA256SUMS or does not match it"
done
s1=$(sha256sum "$LT" "$WZ" | cut -c1-64 | tr '\n' ' ')
bash scripts/package-offline.sh "$D" "$V" --unsigned >/dev/null 2>&1 || fail "the second package run"
[[ "$(sha256sum "$LT" "$WZ" | cut -c1-64 | tr '\n' ' ')" == "$s1" ]] || fail "a second package run gave other bytes"
if bash scripts/package-offline.sh "$D" "$V" >"$WORK/pkg2.out" 2>&1; then fail "package-offline.sh without --unsigned packed an unsigned folder"; fi
grep -q 'SHA256SUMS.sig is missing' "$WORK/pkg2.out" || fail "the signed run's refusal: $(cat "$WORK/pkg2.out")"
cp -a "$D" "$WORK/dist2" && sed -i "/  install.sh\$/d" "$WORK/dist2/SHA256SUMS"
if bash scripts/package-offline.sh "$WORK/dist2" "$V" --unsigned >"$WORK/pkg3.out" 2>&1; then fail "a file without its SHA256SUMS line was packed"; fi
grep -q 'install.sh has no line in SHA256SUMS' "$WORK/pkg3.out" || fail "the unlisted file's refusal: $(cat "$WORK/pkg3.out")"
ok "the bundles: Linux 8 files, Windows 10, one top folder each, the tar's entries 0/0, every file in SHA256SUMS and matching it, the same bytes twice; refused unsigned without --unsigned and with a file left out of SHA256SUMS"

echo "== the released $OLD (fetched here: the connected side) and the image =="
curl -fsSL -o "$WORK/old.sums" "$REL/$OLD/SHA256SUMS" || fail "SHA256SUMS of $OLD"
OLDF="pgvigil_${OLD}_linux_amd64_fips"
curl -fsSL -o "$WORK/$OLDF" "$REL/$OLD/$OLDF" || fail "$OLDF"
(cd "$WORK" && grep "  $OLDF\$" old.sums | sha256sum -c --quiet) || fail "$OLDF does not match its SHA256SUMS"
OLDSHA=$(sha256sum "$WORK/$OLDF" | cut -c1-64)
mkdir -p "$WORK/img"
cat > "$WORK/img/Dockerfile" <<'EOF'
FROM debian:bookworm-slim
ENV container=docker
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv postgresql procps ca-certificates \
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
PGMAJ=$(pq "select current_setting('server_version_num')::int / 10000" 2>/dev/null || PQDB=postgres pq "select current_setting('server_version_num')::int / 10000")

echo "== N no network inside; the carry =="
[[ "$(insys ls /sys/class/net)" == lo ]] || fail "the container has interfaces: $(insys ls /sys/class/net | tr '\n' ' ')"
if insys getent hosts github.com >/dev/null 2>&1; then fail "github.com resolves inside the container"; fi
docker cp "$LT" "$SYS:/root/" >/dev/null && docker cp "$WORK/$OLDF" "$SYS:/root/$OLDF" >/dev/null
insys sh -c "mkdir -p /opt/bundle && tar -C /opt/bundle -xzf /root/$(basename "$LT")"
B=/opt/bundle/$TOPL
[[ "$(insys sh -c "find $B -not -user root -o -not -group root | wc -l")" == 0 ]] || fail "files of the extracted bundle are not root's: $(insys find "$B" -not -user root)"
ok "inside: lo only, github.com does not resolve; the bundle extracted by root is root's; PostgreSQL $PGMAJ inside"

echo "== A a fresh install from the bundle =="
insys sh -c "cp -a $B /opt/bad1 && cp -a $B /opt/bad2"
# one byte of the copy's binary changed (to 0x01 at offset 100000; the byte read first, so a 0x01 there would be said)
[[ "$(insys sh -c "dd if=/opt/bad1/pgvigil_${V}_linux_amd64 bs=1 skip=100000 count=1 2>/dev/null | od -An -tx1 | tr -d ' '")" != 01 ]] || fail "A: the byte to change is 0x01 already"
insys sh -c "printf '\001' | dd of=/opt/bad1/pgvigil_${V}_linux_amd64 bs=1 seek=100000 conv=notrunc 2>/dev/null"
if insys sh /opt/bad1/install.sh --from /opt/bad1 >"$WORK/a1.out" 2>&1; then fail "a changed binary was installed"; fi
grep -q "checksum mismatch for pgvigil_${V}_linux_amd64: nothing was installed" "$WORK/a1.out" || fail "the changed binary's refusal: $(cat "$WORK/a1.out")"
insys sh -c 'echo "# changed" >> /opt/bad2/install.sh'
if insys sh /opt/bad2/install.sh --from /opt/bad2 >"$WORK/a2.out" 2>&1; then fail "a changed install.sh ran an install"; fi
grep -q 'checksum mismatch for install.sh itself' "$WORK/a2.out" || fail "the changed installer's refusal: $(cat "$WORK/a2.out")"
[[ "$(insys sh -c 'ls /etc/systemd/system/pgvigil.service /usr/local/bin/pgvigil 2>/dev/null | wc -l')" == 0 ]] || fail "a refused install left a unit or a binary"
insys sh "$B/install.sh" --from "$B" >"$WORK/a3.out" 2>&1 || fail "the fresh install: $(cat "$WORK/a3.out")"
for l in 'signature not verified here' "pgvigil $V (plain build) checksum verified" 'installed and enabled'; do grep -qF "$l" "$WORK/a3.out" || fail "the fresh install did not say '$l': $(cat "$WORK/a3.out")"; done
vv=$(insys /usr/local/bin/pgvigil version)
[[ "$vv" == "pgvigil $V ("* && "$vv" == *"fips140 off"* ]] || fail "the installed binary: $vv"
insys test -f /etc/systemd/system/pgvigil.service || fail "no unit after the fresh install"
insys /usr/local/bin/pgvigil uninstall -purge >/dev/null 2>&1 || fail "uninstall -purge after the fresh install"
insys userdel pgvigil || fail "userdel pgvigil"
[[ "$(insys sh -c 'ls /etc/systemd/system/pgvigil.service /usr/local/bin/pgvigil /etc/pgvigil 2>/dev/null | wc -l')" == 0 ]] || fail "the fresh install left files after uninstall -purge"
ok "a changed binary and a changed install.sh refused, nothing installed; the bundle installed fresh ($vv), then removed"

echo "== O the old store: $OLD's FIPS build at non-default paths, its schema, logins, demo and service =="
OB=/opt/pgv/bin/pgvigil; OC=/srv/pgvigil/pgvigil.yaml; OE=/srv/pgvigil/pgvigil.env; OU=pgvsvc
insys chmod 0755 "/root/$OLDF"
insys "/root/$OLDF" install -bin "$OB" -config "$OC" -user "$OU" >"$WORK/o1.out" 2>&1 || fail "$OLD install: $(cat "$WORK/o1.out")"
[[ "$(insys "$OB" version)" == *"fips140 on"* ]] || fail "the old build is not FIPS: $(insys "$OB" version)"
pq "select 1" >/dev/null 2>&1 && fail "a database pgvigil exists before the proof made one"
PQDB=postgres pq "CREATE ROLE pgvigil_owner LOGIN CREATEROLE PASSWORD '$OPW'" >/dev/null
PQDB=postgres pq "CREATE DATABASE pgvigil OWNER pgvigil_owner" >/dev/null
OWNER_DSN="host=127.0.0.1 port=5432 user=pgvigil_owner password=$OPW dbname=pgvigil sslmode=disable"
insys sh -c "PGVIGIL_REPO_DSN='$OWNER_DSN' $OB migrate -config $OC" >"$WORK/m0.out" 2>&1 || fail "$OLD migrate: $(tail -n 3 "$WORK/m0.out")"
OLDFILES=$(pq "select count(*) from pgvigil.schema_version")
insys "$OB" roles > "$WORK/roles.sql"
for l in agent:"$APW" ui:"$UPW" monitor:"$MPW"; do
  line=$(grep -E "^CREATE ROLE pgvigil_${l%%:*} LOGIN PASSWORD '<set-me>'" "$WORK/roles.sql" | head -n 1) || fail "'pgvigil roles' prints no CREATE ROLE for pgvigil_${l%%:*}"
  if [[ "${l%%:*}" == monitor ]]; then PQDB=postgres pq "${line/<set-me>/${l#*:}}" >/dev/null
  else insys sh -c "PGPASSWORD='$OPW' psql -h 127.0.0.1 -U pgvigil_owner -d pgvigil -XAtq -v ON_ERROR_STOP=1 -c \"${line/<set-me>/${l#*:}}\"" >/dev/null; fi
done
insys sh -c "PGVIGIL_REPO_DSN='$OWNER_DSN' $OB demo -config $OC -days $DAYS" >"$WORK/demo.out" 2>"$WORK/demo.log" || fail "$OLD demo: $(tail -n 3 "$WORK/demo.log")"
[[ "$(pq "select count(*) from pgvigil.instances where 'demo' = any(tags)")" == 12 ]] || fail "the demo's instances"
insys sh -c "printf 'PGVIGIL_REPO_DSN=host=127.0.0.1 port=5432 user=pgvigil_agent password=$APW dbname=pgvigil sslmode=disable\nPROOF_TARGET_DSN=host=127.0.0.1 port=5432 user=pgvigil_monitor password=$MPW dbname=postgres sslmode=disable\n' >> $OE"
insys sh -c "sed -i 's/^instances: \[\]/instances:\n  - name: proof-target\n    dsn: env:PROOF_TARGET_DSN\n    tags: [proof]/' $OC"
insys systemctl restart pgvigil
TID=""; for _ in $(seq 1 90); do TID=$(pq "select i.instance_id from pgvigil.instances i where i.name = 'proof-target' and exists (select 1 from pgvigil.activity_summary s where s.instance_id = i.instance_id)"); [[ -n "$TID" ]] && break; sleep 1; done
[[ -n "$TID" ]] || fail "no activity sample of proof-target under $OLD within 90 s"
ok "$OLD FIPS at $OB (config $OC, account $OU): $OLDFILES migration files, the logins, 12 demo instances over $DAYS day(s), running; the live instance sampled"

echo "== C refusals before any change =="
insys sh -c "umask 077; printf '%s\n' '$OWNER_DSN' > /root/owner.dsn"
state() { echo "$(insys systemctl show -p MainPID --value pgvigil) $(insys sha256sum "$OB" | cut -c1-64) $(pq "select count(*) from pgvigil.schema_version") $(insys sh -c 'stat -c %a:%U /var/backups/pgvigil 2>/dev/null || echo none') $(insys sh -c 'ls /var/backups/pgvigil 2>/dev/null | wc -l') $(insys sh -c "[ -e $OB.previous ] && echo previous || echo no-previous")"; }
S0=$(state); [[ "${S0%% *}" != 0 ]] || fail "the old service is not running before the refusals"
refused() { # refused <label> <expected line> <command...>
  local label=$1 want=$2; shift 2
  if insys "$@" >"$WORK/c.out" 2>&1; then fail "C $label: the upgrade ran: $(cat "$WORK/c.out")"; fi
  grep -qF "$want" "$WORK/c.out" || fail "C $label: no '$want' in: $(cat "$WORK/c.out")"
  [[ "$(state)" == "$S0" ]] || fail "C $label: something changed: $(state) (before: $S0)"
}
insys sh -c "cp $B/pgvigil_${V}_linux_amd64_fips /root/newbin && chmod 0755 /root/newbin && cp /root/newbin /tmp/newbin && chmod 0755 /tmp/newbin"
refused "not root" "the upgrade needs root" runuser -u nobody -- /tmp/newbin install -upgrade -owner-dsn-file /root/owner.dsn
refused "no owner" "the repository owner's connection string is not given" sh "$B/install.sh" --from "$B"
refused "-bin" "disagrees with the installed service's $OB" /root/newbin install -upgrade -bin /usr/local/bin/pgvigil -owner-dsn-file /root/owner.dsn
insys sh -c "printf '#!/bin/sh\necho \"pg_dump (PostgreSQL) 12.22\"\n' > /root/pg_dump12 && chmod 0755 /root/pg_dump12"
refused "pg_dump 12" "is pg_dump 12 and the repository's server is PostgreSQL $PGMAJ" sh "$B/install.sh" --from "$B" --owner-dsn-file /root/owner.dsn --pg-dump /root/pg_dump12
insys sh -c "mkdir -p /mnt/tiny && mount -t tmpfs -o size=64k tmpfs /mnt/tiny"
refused "room" "free and the repository is" sh "$B/install.sh" --from "$B" --owner-dsn-file /root/owner.dsn --dump /mnt/tiny/x.dump
# the env file is systemd's, not a shell's (a value holds spaces): each variable taken out whole
docker exec -d "$SYS" sh -c "export PGVIGIL_REPO_DSN=\"\$(sed -n 's/^PGVIGIL_REPO_DSN=//p' $OE)\" PROOF_TARGET_DSN=\"\$(sed -n 's/^PROOF_TARGET_DSN=//p' $OE)\"; exec $OB run -config $OC >/root/second.log 2>&1"
sp=""; for _ in $(seq 1 20); do sp=$(insys pgrep -f "^$OB run -config $OC" | grep -v "^$(insys systemctl show -p MainPID --value pgvigil)\$" | head -n 1 || true); [[ -n "$sp" ]] && break; sleep 0.5; done
[[ -n "$sp" ]] || fail "C: the second process did not start: $(insys tail -n 5 /root/second.log 2>&1)"
refused "second process" "pid $sp:" sh "$B/install.sh" --from "$B" --owner-dsn-file /root/owner.dsn
insys kill "$sp"
for _ in $(seq 1 40); do insys kill -0 "$sp" 2>/dev/null || break; sleep 0.25; done
if insys kill -0 "$sp" 2>/dev/null; then fail "C: the second process $sp is still there 10 s after its kill"; fi
ok "refused with nothing changed: not root, no owner DSN, a -bin that disagrees, pg_dump 12 against PostgreSQL $PGMAJ, a dump on a 64 KiB tmpfs, a second process (pid $sp) on $OB"

echo "== M a failed migrate =="
PQDB=postgres pq "ALTER DATABASE pgvigil SET default_transaction_read_only = on" >/dev/null
if insys sh "$B/install.sh" --from "$B" --owner-dsn-file /root/owner.dsn >"$WORK/m.out" 2>&1; then fail "M: the upgrade passed on a read-only database"; fi
PQDB=postgres pq "ALTER DATABASE pgvigil RESET default_transaction_read_only" >/dev/null
for l in "1. kept the previous binary as $OB.previous" '2. stopped the service' '3. dumped the repository' 'the migrate failed: the binary was not swapped and the service stays stopped' 'The way back:'; do grep -qF "$l" "$WORK/m.out" || fail "M: no '$l' in: $(cat "$WORK/m.out")"; done
[[ "$(insys systemctl is-active pgvigil || true)" == inactive ]] || fail "M: the service is $(insys systemctl is-active pgvigil || true) after the failed migrate"
[[ "$(insys sha256sum "$OB" | cut -c1-64)" == "$OLDSHA" ]] || fail "M: the binary changed"
[[ "$(insys sha256sum "$OB.previous" | cut -c1-64)" == "$OLDSHA" ]] || fail "M: $OB.previous is not the old binary"
[[ "$(pq "select count(*) from pgvigil.schema_version")" == "$OLDFILES" ]] || fail "M: schema_version moved"
MD=$(insys sh -c 'ls /var/backups/pgvigil/*.dump' | head -n 1); [[ -n "$MD" && "$(insys stat -c %a "$MD")" == 600 ]] || fail "M: the dump: '$MD' $(insys stat -c %a "$MD" 2>/dev/null)"
insys rm -f "$MD"; insys systemctl start pgvigil; sleep 3
[[ "$(insys systemctl is-active pgvigil)" == active ]] || fail "M: the old collector did not start again"
ok "the failed migrate: the previous binary kept first, stopped, dumped (0600), no swap, schema as before, the service left stopped and the way back printed; the old collector started again after the reset"

echo "== U the upgrade from the bundle =="
counts() { # counts <file>: 'table|i or g|rows' for every table, the live instance's rows left out
  docker exec -i -u postgres "$SYS" psql -d "${PQDB:-pgvigil}" -XAtq -v ON_ERROR_STOP=1 -v skip="$TID" > "$1" <<'SQL' || return 1
select c.relname || '|' || case when i.has then 'i' else 'g' end || '|' ||
       (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from pgvigil.%I%s', c.relname,
          case when i.has then format(' where instance_id is distinct from %s', :skip) else '' end), false, true, '')))[1]::text
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 cross join lateral (select exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'instance_id' and not a.attisdropped) as has) i
 where n.nspname = 'pgvigil' and c.relkind in ('r', 'p') and not c.relispartition
 order by c.relname;
SQL
  [[ -s "$1" ]] && ! grep -qvE '^[a-z0-9_]+\|[ig]\|[0-9]+$' "$1"
}
hashes() { # hashes <file> <columns file>: 'table|md5' over each instance table's rows outside the live instance, in the columns named
  { echo "create temp table proof_cols (t text primary key, cols text);"; echo "copy proof_cols from stdin with (format text, delimiter '|');"; cat "$2"; echo '\.'
    cat <<SQL
select p.t || '|' || (xpath('/row/h/text()', query_to_xml(format(
         'select coalesce(md5(string_agg(h, '''' order by h)), ''empty'') as h from (select md5(row(%s)::text) as h from pgvigil.%I where instance_id is distinct from $TID) x', p.cols, p.t), false, true, '')))[1]::text
  from proof_cols p where to_regclass('pgvigil.' || quote_ident(p.t)) is not null order by 1;
SQL
  } | docker exec -i -u postgres "$SYS" psql -d "${PQDB:-pgvigil}" -XAtq -v ON_ERROR_STOP=1 > "$1" || return 1
  [[ -s "$1" ]] && ! grep -qvE '^[a-z0-9_]+\|([0-9a-f]{32}|empty)$' "$1"
}
pq "select c.relname || '|' || string_agg(quote_ident(a.attname), ',' order by a.attnum) from pg_class c join pg_namespace n on n.oid = c.relnamespace join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped where n.nspname = 'pgvigil' and c.relkind in ('r', 'p') and not c.relispartition and exists (select 1 from pg_attribute x where x.attrelid = c.oid and x.attname = 'instance_id' and not x.attisdropped) group by c.relname order by 1" > "$WORK/cols"
CFG0=$(insys sha256sum "$OC" "$OE" | cut -c1-64 | tr '\n' ' ')
counts "$WORK/before.cnt" || fail "the counts before"
hashes "$WORK/before.hash" "$WORK/cols" || fail "the hashes before"
T1=$(pq "select now()")
insys sh "$B/install.sh" --from "$B" --owner-dsn-file /root/owner.dsn >"$WORK/u.out" 2>&1 || fail "the upgrade: $(cat "$WORK/u.out")"
for l in "an installed collector was found" "1. kept the previous binary as $OB.previous" '2. stopped the service' '3. dumped the repository to /var/backups/pgvigil/pgvigil-before-' '4. migrated the repository:' '5. swapped the binary and started the service' 'installed and running' 'The way back:'; do
  grep -qF "$l" "$WORK/u.out" || fail "U: no '$l' in: $(cat "$WORK/u.out")"
done
APPLIED=$(sed -n 's/^4. migrated the repository: \([0-9]*\) file(s) applied$/\1/p' "$WORK/u.out")
NFILES=$(ls internal/repo/sql/*.sql | wc -l)
[[ "$(pq "select count(*) from pgvigil.schema_version")" == "$NFILES" && "$APPLIED" == "$((NFILES - OLDFILES))" ]] || fail "U: schema_version $(pq "select count(*) from pgvigil.schema_version"), applied $APPLIED (want $NFILES and $((NFILES - OLDFILES)))"
UD=$(insys sh -c 'ls /var/backups/pgvigil/*.dump' | head -n 1)
[[ "$(insys stat -c '%a %U' /var/backups/pgvigil)" == "700 root" && "$(insys stat -c '%a %U' "$UD")" == "600 root" ]] || fail "U: the dump's folder and file: $(insys stat -c '%a %U %n' /var/backups/pgvigil "$UD")"
insys pg_restore -l "$UD" >/dev/null || fail "U: pg_restore cannot list the dump"
[[ "$(insys sha256sum "$OB.previous" | cut -c1-64)" == "$OLDSHA" ]] || fail "U: $OB.previous is not $OLD's FIPS binary"
nv=$(insys "$OB" version); [[ "$nv" == "pgvigil $V ("* && "$nv" == *"fips140 on"* ]] || fail "U: the installed binary: $nv (want $V, FIPS)"
insys grep -qx "ExecStart=$OB run -config $OC" /etc/systemd/system/pgvigil.service && insys grep -qx "User=$OU" /etc/systemd/system/pgvigil.service || fail "U: the unit moved: $(insys grep -E '^(ExecStart|User)=' /etc/systemd/system/pgvigil.service)"
[[ "$(insys sha256sum "$OC" "$OE" | cut -c1-64 | tr '\n' ' ')" == "$CFG0" ]] || fail "U: the config or the env file changed"
[[ "$(insys systemctl is-active pgvigil)" == active ]] || fail "U: the service is not active"
NEW=""; for _ in $(seq 1 90); do NEW=$(pq "select count(*) from pgvigil.activity_summary where instance_id = $TID and snapshot_at > '$T1'"); [[ "$NEW" -gt 0 ]] && break; sleep 1; done
[[ "$NEW" -gt 0 ]] || fail "U: no activity sample after the upgrade"
counts "$WORK/after.cnt" || fail "the counts after"
hashes "$WORK/after.hash" "$WORK/cols" || fail "the hashes after"
cmpres=$(python3 -I - "$WORK/before.cnt" "$WORK/after.cnt" <<'PY'
import sys
b = {l.split("|")[0]: l.strip().split("|") for l in open(sys.argv[1])}
a = {l.split("|")[0]: l.strip().split("|") for l in open(sys.argv[2])}
bad = []
for t, (_, k, n) in b.items():
    if t not in a: bad.append("%s gone" % t); continue
    m = int(a[t][2])
    if k == "i" and m != int(n): bad.append("%s %s -> %d" % (t, n, m))
    if k == "g" and m < int(n) and t != "schema_version": bad.append("%s shrank %s -> %d" % (t, n, m))
if bad: sys.exit("; ".join(bad))
print("%d tables, %d with an instance column, %d rows in them outside the live instance" % (len(b), sum(1 for v in b.values() if v[1] == "i"), sum(int(v[2]) for v in b.values() if v[1] == "i")))
PY
) || fail "U: rows changed: $cmpres"
diff "$WORK/before.hash" "$WORK/after.hash" >"$WORK/hash.diff" || fail "U: the rows' md5 changed: $(head -5 "$WORK/hash.diff")"
ok "upgraded $OLD FIPS to $V FIPS in place ($OB, $OC, $OU): $APPLIED files applied; the dump 0600 in a 0700 folder, pg_restore lists it; .previous = $OLD byte for byte; config and env unchanged; $cmpres, each table's md5 the same ($(wc -l < "$WORK/after.hash") tables); a sample after the restart"

echo "== R the re-run, its dump in a folder of another owner =="
insys sh -c "mkdir -p /srv/opdir && chown 65534:65534 /srv/opdir && chmod 0755 /srv/opdir"
insys sh "$B/install.sh" --from "$B" --owner-dsn-file /root/owner.dsn --dump /srv/opdir/r.dump >"$WORK/r.out" 2>&1 || fail "R: $(cat "$WORK/r.out")"
grep -qF '4. migrated the repository: 0 file(s) applied' "$WORK/r.out" && grep -qF 'the installed binary is already this one' "$WORK/r.out" || fail "R: $(cat "$WORK/r.out")"
[[ "$(insys sha256sum "$OB.previous" | cut -c1-64)" == "$OLDSHA" ]] || fail "R: $OB.previous was overwritten"
[[ "$(insys stat -c '%a %u %g' /srv/opdir)" == "755 65534 65534" ]] || fail "R: the operator's folder changed: $(insys stat -c '%a %u %g' /srv/opdir)"
[[ "$(insys stat -c '%a %U' /srv/opdir/r.dump)" == "600 root" ]] || fail "R: the dump file: $(insys stat -c '%a %U' /srv/opdir/r.dump)"
ok "re-run: 0 files, the binary already this one, .previous still $OLD's; the dump in the operator's folder 0600 root's, the folder as it was (755, 65534)"

echo "== D a downgrade =="
pq "INSERT INTO pgvigil.schema_version (version) VALUES ('9999_from_a_newer_build.sql')" >/dev/null
S0=$(state)
refused "downgrade" "newer than this build's newest migration" sh "$B/install.sh" --from "$B" --owner-dsn-file /root/owner.dsn
pq "DELETE FROM pgvigil.schema_version WHERE version = '9999_from_a_newer_build.sql'" >/dev/null
ok "a repository naming a migration newer than this build: refused, nothing changed"

echo "== W the way back =="
PQDB=postgres pq "CREATE DATABASE pgvigil_back OWNER pgvigil_owner" >/dev/null
insys sh -c "PGPASSWORD='$OPW' pg_restore --exit-on-error -h 127.0.0.1 -U pgvigil_owner -d pgvigil_back '$UD'" >"$WORK/w.out" 2>&1 || fail "W: pg_restore: $(tail -n 3 "$WORK/w.out")"
PQDB=pgvigil_back counts "$WORK/back.cnt" || fail "W: the counts of the restored copy"
python3 -I - "$WORK/before.cnt" "$WORK/back.cnt" <<'PY' || fail "W: the restored copy differs from before the upgrade"
import sys
b = {l.split("|")[0]: l.strip().split("|") for l in open(sys.argv[1])}
a = {l.split("|")[0]: l.strip().split("|") for l in open(sys.argv[2])}
bad = [t for t, v in b.items() if v[1] == "i" and (t not in a or a[t][2] != v[2])]
if bad: sys.exit(", ".join(bad))
PY
pv=$(insys "$OB.previous" version); [[ "$pv" == "pgvigil $OLD ("* && "$pv" == *"fips140 on"* ]] || fail "W: .previous says $pv"
ok "the dump restored into pgvigil_back holds every instance table's rows as before; .previous runs ($pv)"
echo "proof-offline: OK (the bundles laid out and checked; a fresh install and an upgrade of $OLD FIPS with its history from the bundle with no network; six refusals, a downgrade and a failed migrate change nothing they should not; the re-run keeps the way back; the way back restores)"
