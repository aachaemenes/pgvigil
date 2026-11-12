#!/usr/bin/env bash
# Proof of the upgrade and of the install on a network without Internet access (release readiness F): a store made by
# the released v0.3.0 itself (its binary from the GitHub release, its migrations, three days of its demo, its collector
# as a service) is upgraded by this tree's build the way docs/upgrade.md says, on throwaway containers only. The host that
# runs pgvigil sits on a docker network with no route out (--internal) and installs from a mirror folder there, as
# docs/airgap.md says; this machine stands in for the connected one that fetches and verifies the release first.
# Needs docker, go, git, python3, curl, sha256sum, ss, node and chromium on a Linux amd64 machine with Internet access
# (the release download, the images, the Go modules); cosign is optional (found on the PATH or named by PGVIGIL_COSIGN).
#   PGVIGIL_UPGRADE_FROM   the released tag the store starts from (default v0.3.0)
#   PGVIGIL_UPGRADE_DAYS   the days of demo history the old version seeds (default 3)
#   PGVIGIL_PROOF_PG       the PostgreSQL major of the repository container (default 16)
#   PGVIGIL_PROOF_KEEP=1   leave the containers running after a failure (for a look)
#   PGVIGIL_UPGRADE_WALK_OUT  a file that gets the walk's line per page
# This build's release folder is made here the way release.yml makes one (the linux/amd64 binary, its CycloneDX SBOM, a
# SHA256SUMS over both) from a throwaway git repository of the tree tagged v0.0.0-proof, so the SBOM tool reads the
# version from a tag as it does at a release; it carries no signature (the keyless one needs the workflow's identity).
# The SBOM's schema is proof-sbom.sh's; here the SBOM is held against the binary it sits beside.
#
# Expected (each line written before the run that first exercised it):
#   A release     the old tag's binary, SBOM, SHA256SUMS, .sig, .pem and .bundle download; sha256sum -c: 2 files OK (the
#                 binary and the SBOM); the SBOM is CycloneDX 1.6, names the main module at the tag, and its components are
#                 exactly the modules the binary itself reports (go version -m: name, version and hash each; 35 at
#                 v0.3.0), the build's GOOS / GOARCH / CGO_ENABLED and Go version the same in both; with cosign: the
#                 signature verifies for the release workflow's identity at that tag and another tag's identity is
#                 refused; without cosign: 'SKIP cosign' and the last line says the signature was not checked
#   B this build  the same SBOM check passes on this build's pair; its SHA256SUMS: 2 files OK
#   C air gap     from the pgvigil host curl to https://github.com/ and to http://1.1.1.1/ ends with 6 or 7 (no name, no
#                 route), the mirror answers; the carried folder verifies again inside (2 files OK); with cosign: the
#                 bundle verifies inside with --offline and the trust root's three keys carried as files
#                 (SIGSTORE_ROOT_FILE, SIGSTORE_REKOR_PUBLIC_KEY, SIGSTORE_CT_LOG_PUBLIC_KEY_FILE; no cache of cosign's
#                 there), another tag's identity is refused there too, and what the same command does without the three
#                 files is told, not judged (cosign v2.6.1: refused, it reaches for the TUF mirror); a mirror whose
#                 binary changed by one byte: 'checksum mismatch', nothing installed
#   D old store   the old tag installs from the mirror ('checksum verified', 'installed and enabled'); its migrate as an
#                 owner with CREATEROLE applies its own files (60 at v0.3.0); the logins 'pgvigil roles' prints are
#                 created; its demo seeds 12 instances over the days asked; the second installer run ends 'installed and
#                 running' with the collector login in the env file and a pg_monitor login on the target; an activity
#                 sample of the live instance arrives; the collections' newest results are noted, one ok at least (20 ok
#                 and 7 skipped at v0.3.0 on a PostgreSQL 16 target)
#   E upgrade     the installer with PGVIGIL_NO_SERVICE=1 leaves ./pgvigil of this build ('checksum verified'); the
#                 service stopped; a custom-format dump of the repository is taken as its owner; this build's 'run' on the
#                 old schema ends within 30 s with exit 1, naming the newest migration file and 'pgvigil migrate'; migrate
#                 as the owner prints applied = this tree's files minus the store's (B prints the tree's count, D the
#                 store's) and a second migrate applied=0; EVERY table of the old store holds the row count it held
#                 before (schema_version alone grows, by the files applied) and the same md5 over its rows in the
#                 columns the old version had; each table this build adds holds exactly the rows this build's migrate
#                 leaves in an EMPTY repository (a second database, migrated and counted, then dropped): 0, or the
#                 reference rows a migration writes (0100's pgaudit_rules seed), the run naming each seeded table;
#                 './pgvigil install' ends 'installed and running': the installed binary
#                 prints this build's version, the config and the env file are byte for byte the old ones, the unit is
#                 active with 0 restarts and runs as pgvigil
#   F collector   under the collector login (no owner right) an activity sample newer than the restart arrives; every
#                 collection that ended ok under the old version ends ok again within 180 s, and none ends error or
#                 partial that did not under the old version
#   G pages       this build's 'serve' under the UI login (pgvigil_reader + pgvigil_auth) on loopback: every page the
#                 tab strips list - the root's and every instance's (12 demo instances and the live one) - and one page
#                 of every other route those pages link to renders: its content drawn, no error box, no API answer of
#                 400 or over, no failed request, no script exception; 0 failed (488 pages on the first runs); a tab
#                 strip that lists no page, or a linked route left unvisited, fails the walk. The walk's own control:
#                 with the UI login's read role taken away (by the owner, read back as gone), the same walk fails at its
#                 first page
#   H rows kept   after the restart and the walk, every table's rows outside the live instance are the count from before
#                 the upgrade; a table without an instance column may only have grown (the collector's own texts); the
#                 unit is still active with 0 restarts, minutes after the upgrade
#   I way back    the owner's dump restores, as the owner, into a second database with every table's row count and row
#                 md5 as before the upgrade; the old tag reinstalled from the mirror runs on it ('installed and running',
#                 a new activity sample): the way back is the dump and the previous binary. Then the installer first, as
#                 're-run it to upgrade' reads: install.sh for this build replaces the binary and ends with exit 1
#                 and ONE line that says 'the service did not come up', names the newest migration file and says
#                 "run 'pgvigil migrate' as the repository owner" ('pgvigil install' calls the unit running only after
#                 it stayed active for four seconds, and the first start on the old schema ends at the schema check
#                 well inside that: exit 0 here is a failure); the journal names the same file and the unit is restarted (1 restart or more in
#                 12 s); once the owner has migrated, the unit comes up by itself (a new activity sample) and the rows
#                 outside the live instance are the count from before
set -euo pipefail
cd "$(dirname "$0")/.."
OLD=${PGVIGIL_UPGRADE_FROM:-v0.3.0}; NEW="v0.0.0-proof"; DAYS=${PGVIGIL_UPGRADE_DAYS:-3}; PGV=${PGVIGIL_PROOF_PG:-16}
TAG="pgvupg$RANDOM"; NET="$TAG-net"; REPO="$TAG-repo"; MIRROR="$TAG-mirror"; SYS="$TAG-sys"; IMG="pgvigil-proof-systemd:bookworm"
PW="pw$RANDOM$RANDOM"; OPW="ow$RANDOM$RANDOM"; APW="ag$RANDOM$RANDOM"; UPW="ui$RANDOM$RANDOM"; MPW="mo$RANDOM$RANDOM"
WORK=$(mktemp -d); SRV=""; CHR=""
REL=https://github.com/aachaemenes/pgvigil/releases/download
SIGNER=https://github.com/aachaemenes/pgvigil/.github/workflows/release.yml@refs/tags; ISSUER=https://token.actions.githubusercontent.com
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  if [[ "${PGVIGIL_PROOF_KEEP:-}" = "1" && "${FAILED:-}" = "1" ]]; then echo "kept: $SYS $REPO $MIRROR on $NET, files in $WORK"; return; fi
  docker rm -f -v "$SYS" "$REPO" "$MIRROR" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'FAILED=1; echo "FAIL: line $LINENO ended the run: $BASH_COMMAND" >&2' ERR
fail() {
  FAILED=1; echo "FAIL: $*" >&2
  docker exec "$SYS" journalctl -u pgvigil --no-pager -n 15 2>/dev/null | sed 's/^/  journal: /' >&2 || true
  [[ -s "$WORK/serve.log" ]] && tail -n 5 "$WORK/serve.log" | sed 's/^/  serve: /' >&2
  exit 1
}
ok() { echo "ok   $*"; }
insys() { docker exec "$SYS" "$@"; }
RDB=pgvigil   # the repository database the reads below go to (part I reads the restored copy)
rq() { docker exec "$REPO" psql -U postgres -d "$RDB" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
for t in docker go git python3 curl sha256sum ss node chromium; do command -v "$t" >/dev/null || fail "$t is not on this machine"; done
[[ "$(uname -s)/$(uname -m)" == "Linux/x86_64" ]] || fail "a Linux amd64 machine is needed (this one is $(uname -s)/$(uname -m)): the proof runs the release's linux_amd64 binary"
COSIGN=$(command -v "${PGVIGIL_COSIGN:-cosign}" 2>/dev/null || true); SIGNED="the signature was not checked (no cosign on this machine)"

# sbom_check <binary> <sbom> <tag>: the SBOM describes that binary (the modules the binary itself reports)
sbom_check() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import base64, json, subprocess, sys
binary, sbom, tag = sys.argv[1:4]
info = subprocess.check_output(["go", "version", "-m", binary], text=True).splitlines()
gover = info[0].rsplit(": ", 1)[1].strip()
deps, build = {}, {}
for line in info[1:]:
    f = line.strip("\n").split("\t")[1:]
    if f and f[0] == "dep":
        deps[f[1] + "@" + f[2]] = base64.b64decode(f[3][3:]).hex() if len(f) > 3 and f[3].startswith("h1:") else ""
    elif f and f[0] == "=>":
        sys.exit("the binary was built with a replaced module (%s): the SBOM cannot be matched to it" % f[1])
    elif f and f[0] == "build" and "=" in f[1]:
        k, v = f[1].split("=", 1); build[k] = v
d = json.load(open(sbom))
assert d.get("bomFormat") == "CycloneDX" and d.get("specVersion") == "1.6", (d.get("bomFormat"), d.get("specVersion"))
main = d["metadata"]["component"]
assert main["name"] == "github.com/aachaemenes/pgvigil" and main.get("version") == tag, "main component %s %s, wanted the tag %s" % (main["name"], main.get("version"), tag)
props = {p["name"]: p["value"] for p in main.get("properties", [])}
for k in ("GOOS", "GOARCH", "CGO_ENABLED"):
    assert props.get("cdx:gomod:build:env:" + k) == build.get(k), "%s: the SBOM says %s, the binary %s" % (k, props.get("cdx:gomod:build:env:" + k), build.get(k))
assert props.get("cdx:gomod:build:env:GOVERSION") == gover, "Go version: the SBOM says %s, the binary %s" % (props.get("cdx:gomod:build:env:GOVERSION"), gover)
comps = {}
for c in d.get("components", []):
    assert c.get("purl", "").startswith("pkg:golang/"), "component without a golang purl: %s" % c.get("name")
    comps[c["name"] + "@" + c.get("version", "")] = next((h["content"] for h in c.get("hashes", []) if h.get("alg") == "SHA-256"), "")
only_bin, only_sbom = sorted(set(deps) - set(comps)), sorted(set(comps) - set(deps))
assert not only_bin and not only_sbom, "modules only in the binary: %s; only in the SBOM: %s" % (only_bin, only_sbom)
wrong = sorted(k for k in deps if not deps[k] or deps[k] != comps[k])
assert not wrong, "module hash differs between the binary and the SBOM: %s" % wrong
print("%d components = the binary's %d modules (name, version, hash); %s/%s CGO %s, %s" % (len(comps), len(deps), build["GOOS"], build["GOARCH"], build["CGO_ENABLED"], gover))
PY
}
# sums_ok <folder> <n>: sha256sum -c there checks exactly n files, all OK (--ignore-missing alone passes on an empty folder)
sums_ok() { local out; out=$(cd "$1" && sha256sum -c SHA256SUMS --ignore-missing 2>&1) || return 1; [[ "$(grep -c ': OK$' <<<"$out")" == "$2" ]]; }

echo "== A the release $OLD, fetched and verified as on a connected machine =="
mkdir -p "$WORK/mirror/$OLD" "$WORK/mirror/$NEW" "$WORK/mirror/tampered"
for f in "pgvigil_${OLD}_linux_amd64" "pgvigil_${OLD}_linux_amd64.cdx.json" SHA256SUMS SHA256SUMS.sig SHA256SUMS.pem SHA256SUMS.bundle; do
  curl -fsSL --retry 3 -o "$WORK/mirror/$OLD/$f" "$REL/$OLD/$f" || fail "download of $REL/$OLD/$f"
done
sums_ok "$WORK/mirror/$OLD" 2 || fail "sha256sum -c did not pass on exactly the binary and the SBOM of $OLD"
chmod 0755 "$WORK/mirror/$OLD/pgvigil_${OLD}_linux_amd64"
[[ "$("$WORK/mirror/$OLD/pgvigil_${OLD}_linux_amd64" version)" == "pgvigil $OLD ("* ]] || fail "the released binary does not print $OLD"
got=$(sbom_check "$WORK/mirror/$OLD/pgvigil_${OLD}_linux_amd64" "$WORK/mirror/$OLD/pgvigil_${OLD}_linux_amd64.cdx.json" "$OLD") || fail "the SBOM of $OLD does not describe its binary"
ok "$OLD: 2 files OK against SHA256SUMS; SBOM CycloneDX 1.6 at $OLD, $got"
if [[ -n "$COSIGN" ]]; then
  mkdir -p "$WORK/chome" "$WORK/trust"; csn() { HOME="$WORK/chome" "$COSIGN" "$@"; }   # cosign's cache under the proof's own folder
  csn initialize >"$WORK/cosign0.out" 2>&1 || fail "cosign initialize: $(tail -n 3 "$WORK/cosign0.out")"
  (cd "$WORK/mirror/$OLD" && csn verify-blob --signature SHA256SUMS.sig --certificate SHA256SUMS.pem --certificate-identity "$SIGNER/$OLD" --certificate-oidc-issuer "$ISSUER" SHA256SUMS) >"$WORK/cosign1.out" 2>&1 || fail "cosign verify-blob on $OLD's SHA256SUMS: $(tail -n 3 "$WORK/cosign1.out")"
  if (cd "$WORK/mirror/$OLD" && csn verify-blob --signature SHA256SUMS.sig --certificate SHA256SUMS.pem --certificate-identity "$SIGNER/v9.9.9" --certificate-oidc-issuer "$ISSUER" SHA256SUMS) >/dev/null 2>&1; then fail "cosign accepted another tag's identity for $OLD's SHA256SUMS"; fi
  # what is carried across for the check inside: the trust root's own keys as three files (cosign's SIGSTORE_ROOT_FILE,
  # SIGSTORE_REKOR_PUBLIC_KEY and SIGSTORE_CT_LOG_PUBLIC_KEY_FILE read them instead of the TUF mirror)
  TROOT=$(find "$WORK/chome" -name trusted_root.json | head -n 1); [[ -n "$TROOT" ]] || fail "cosign initialize left no trusted_root.json under its cache"
  python3 -I - "$TROOT" "$WORK/trust" <<'PY' || fail "the trust root's keys as files"
import json, sys, textwrap
d = json.load(open(sys.argv[1])); out = sys.argv[2]
pem = lambda raw, kind: "-----BEGIN %s-----\n%s\n-----END %s-----\n" % (kind, "\n".join(textwrap.wrap(raw, 64)), kind)
certs = [c["rawBytes"] for ca in d["certificateAuthorities"] for c in ca["certChain"]["certificates"]]
rekor = [t for t in d["tlogs"] if t.get("baseUrl") == "https://rekor.sigstore.dev"]   # the log the release's bundle names
ct = [t for t in d["ctlogs"] if "end" not in t["publicKey"].get("validFor", {})]      # the certificate log in use
if not certs or len(rekor) != 1 or len(ct) != 1:
    sys.exit("trusted_root.json: %d certificates, %d rekor.sigstore.dev logs, %d open certificate logs (wanted 1+, 1, 1)" % (len(certs), len(rekor), len(ct)))
open(out + "/fulcio.pem", "w").write("".join(pem(c, "CERTIFICATE") for c in certs))
open(out + "/rekor.pub", "w").write(pem(rekor[0]["publicKey"]["rawBytes"], "PUBLIC KEY"))
open(out + "/ctfe.pub", "w").write(pem(ct[0]["publicKey"]["rawBytes"], "PUBLIC KEY"))
PY
  ok "cosign: SHA256SUMS signed by release.yml at refs/tags/$OLD; another tag's identity refused"
else
  echo "SKIP cosign: not on this machine (PGVIGIL_COSIGN names one): the signature of SHA256SUMS is not checked"
fi

echo "== B this build's release folder ($NEW), made as release.yml makes one =="
mkdir -p "$WORK/src"
tar --exclude=./.git --exclude=./bin --exclude=./web/node_modules -cf - . | tar -xf - -C "$WORK/src"
(cd "$WORK/src" && git init -q . && git add -A && git -c user.name=proof -c user.email=proof@example.invalid commit -q -m "the tree under proof" && git tag "$NEW") || fail "the throwaway repository of the tree"
(cd "$WORK/src" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w -X main.version=$NEW" -o "$WORK/mirror/$NEW/pgvigil_${NEW}_linux_amd64" ./cmd/pgvigil) || fail "build of this tree"
GOBIN_DIR=$(go env GOBIN); [[ -n "$GOBIN_DIR" ]] || GOBIN_DIR=$(go env GOPATH)/bin
[[ -x "$GOBIN_DIR/cyclonedx-gomod" ]] || go install github.com/CycloneDX/cyclonedx-gomod/cmd/cyclonedx-gomod@v1.12.0 || fail "go install cyclonedx-gomod"
(cd "$WORK/src" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 "$GOBIN_DIR/cyclonedx-gomod" app -json -licenses -main cmd/pgvigil -output "$WORK/mirror/$NEW/pgvigil_${NEW}_linux_amd64.cdx.json" .) >"$WORK/sbom.log" 2>&1 || fail "cyclonedx-gomod on this tree: $(tail -n 3 "$WORK/sbom.log")"
(cd "$WORK/mirror/$NEW" && sha256sum -- * > SHA256SUMS)
sums_ok "$WORK/mirror/$NEW" 2 || fail "sha256sum -c on this build's folder"
got=$(sbom_check "$WORK/mirror/$NEW/pgvigil_${NEW}_linux_amd64" "$WORK/mirror/$NEW/pgvigil_${NEW}_linux_amd64.cdx.json" "$NEW") || fail "this build's SBOM does not describe its binary"
NEWBIN="$WORK/mirror/$NEW/pgvigil_${NEW}_linux_amd64"
[[ "$("$NEWBIN" version)" == "pgvigil $NEW ("* ]] || fail "this build does not print $NEW"
NFILES=$(find internal/repo/sql -maxdepth 1 -name '*.sql' | wc -l); LATEST=$(find internal/repo/sql -maxdepth 1 -name '*.sql' -printf '%f\n' | sort | tail -n 1)
ok "$NEW: 2 files OK against SHA256SUMS; SBOM CycloneDX 1.6 at $NEW, $got; $NFILES migration files, the newest $LATEST"
cp deploy/install.sh "$WORK/mirror/install.sh"
# the changed copy: the old binary with one byte added, under the old binary's own checksum line
{ cat "$WORK/mirror/$OLD/pgvigil_${OLD}_linux_amd64"; printf 'x'; } > "$WORK/mirror/tampered/pgvigil_tampered_linux_amd64"
grep " pgvigil_${OLD}_linux_amd64\$" "$WORK/mirror/$OLD/SHA256SUMS" | sed "s/pgvigil_${OLD}_linux_amd64\$/pgvigil_tampered_linux_amd64/" > "$WORK/mirror/tampered/SHA256SUMS"

echo "== C the network without a route out: the mirror, the repository, the pgvigil host =="
for i in "postgres:$PGV" python:3-slim; do docker image inspect "$i" >/dev/null 2>&1 || docker pull -q "$i" >/dev/null || fail "docker pull $i"; done
docker network create --internal "$NET" >/dev/null
# the repository server also stands on the default bridge with its port on this machine's loopback: the proof's own
# reads and this build's 'serve' reach it there; the pgvigil host is on the closed network alone
docker run -d --rm --name "$REPO" -p 127.0.0.1::5432 -e POSTGRES_PASSWORD="$PW" "postgres:$PGV" >/dev/null
docker network connect "$NET" "$REPO"
docker run -d --rm --name "$MIRROR" --network "$NET" -v "$WORK/mirror:/srv:ro" -w /srv python:3-slim python3 -m http.server 8000 >/dev/null
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  # the same image scripts/proof-install.sh builds and keeps (docker rmi it to rebuild)
  mkdir -p "$WORK/img"; cat > "$WORK/img/Dockerfile" <<'DF'
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv curl ca-certificates procps \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl mask systemd-logind.service getty.target console-getty.service systemd-udevd.service systemd-udev-trigger.service systemd-networkd-wait-online.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
DF
  docker build -q -t "$IMG" "$WORK/img" >/dev/null
fi
docker run -d --rm --name "$SYS" --network "$NET" --privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock "$IMG" >/dev/null
st=""; for _ in $(seq 1 60); do st=$(insys systemctl is-system-running 2>/dev/null || true); [[ "$st" == running || "$st" == degraded ]] && break; sleep 1; done
[[ "$st" == running || "$st" == degraded ]] || fail "systemd did not come up in the container (state '$st')"
for _ in $(seq 1 60); do docker exec "$REPO" psql -U postgres -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 1; done
docker exec "$REPO" psql -U postgres -XAtqc 'select 1' >/dev/null 2>&1 || fail "the repository server did not come up"
RPORT=$(docker port "$REPO" 5432/tcp | sed -n 's/^127\.0\.0\.1:\([0-9]*\)$/\1/p' | head -n 1); [[ -n "$RPORT" ]] || fail "the repository's loopback port"
# curl's own verdicts: 6 = the name does not resolve, 7 = no connection (no route); 28, a timeout, would be a packet dropped on a route that exists
for u in https://github.com/ http://1.1.1.1/; do
  rc=0; insys curl -sS -m 8 -o /dev/null "$u" 2>/dev/null || rc=$?
  [[ "$rc" == 6 || "$rc" == 7 ]] || fail "from the pgvigil host, curl $u ended with exit $rc (wanted 6 or 7: no name, no route): the network is not closed as expected"
done
[[ "$(insys curl -fsS -m 8 "http://$MIRROR:8000/$OLD/SHA256SUMS")" == "$(cat "$WORK/mirror/$OLD/SHA256SUMS")" ]] || fail "the mirror does not answer inside the closed network"
ok "the pgvigil host has no route out (github.com does not resolve or connect, 1.1.1.1 does not connect) and reads the mirror"
docker cp "$WORK/mirror/$OLD" "$SYS:/media/pgvigil-$OLD" >/dev/null 2>&1 || fail "copying the carried folder to the pgvigil host"
[[ "$(insys sh -c "cd /media/pgvigil-$OLD && sha256sum -c SHA256SUMS --ignore-missing 2>&1 | grep -c ': OK\$'")" == 2 ]] || fail "the carried folder does not verify inside the closed network"
ok "the carried folder verifies again inside: 2 files OK"
if [[ -n "$COSIGN" ]]; then
  { docker cp -L "$COSIGN" "$SYS:/usr/local/bin/cosign" && docker cp "$WORK/trust" "$SYS:/media/sigstore-keys"; } >/dev/null 2>&1 || fail "copying cosign and the trust root's keys to the pgvigil host"
  # an empty HOME: no cache of cosign's is there, the three files are all it has
  offline() { insys sh -c "cd /media/pgvigil-$OLD && HOME=/tmp/nohome $1 cosign verify-blob --offline --bundle SHA256SUMS.bundle --certificate-identity '$SIGNER/$2' --certificate-oidc-issuer '$ISSUER' SHA256SUMS"; }
  KEYS="SIGSTORE_ROOT_FILE=/media/sigstore-keys/fulcio.pem SIGSTORE_REKOR_PUBLIC_KEY=/media/sigstore-keys/rekor.pub SIGSTORE_CT_LOG_PUBLIC_KEY_FILE=/media/sigstore-keys/ctfe.pub"
  offline "$KEYS" "$OLD" >"$WORK/cosign2.out" 2>&1 || fail "cosign --offline --bundle inside the closed network: $(tail -n 3 "$WORK/cosign2.out")"
  if offline "$KEYS" v9.9.9 >/dev/null 2>&1; then fail "cosign inside the closed network accepted another tag's identity"; fi
  # told, not judged (another cosign may behave otherwise): the same command without the three files
  NOKEYS="is refused"; if offline "" "$OLD" >/dev/null 2>&1; then NOKEYS="verifies too"; fi
  ok "cosign inside the closed network ($(insys cosign version 2>&1 | sed -n 's/^GitVersion: *//p')): the bundle verifies with --offline and the trust root's three keys carried as files, another tag's identity refused; without the files the same command $NOKEYS"
  SIGNED="the signature checked online and, from the bundle, inside the closed network"
fi
if insys sh -c "curl -fsSL http://$MIRROR:8000/install.sh | PGVIGIL_VERSION=tampered PGVIGIL_BASE_URL=http://$MIRROR:8000 sh" >"$WORK/bad.out" 2>&1; then fail "a binary changed by one byte was installed"; fi
grep -q 'checksum mismatch' "$WORK/bad.out" || fail "the refusal did not say checksum mismatch: $(cat "$WORK/bad.out")"
insys test ! -e /usr/local/bin/pgvigil || fail "a binary was installed despite the changed byte"
ok "a mirror copy changed by one byte: checksum mismatch, nothing installed"

echo "== D the old store: $OLD installed from the mirror, its schema, its logins, $DAYS days of its demo, its service =="
OWNER_DSN="postgres://pgvigil_owner:$OPW@$REPO:5432/pgvigil?sslmode=disable"
inst() { insys sh -c "cd /root && curl -fsSL http://$MIRROR:8000/install.sh | PGVIGIL_VERSION=$1 PGVIGIL_BASE_URL=http://$MIRROR:8000 ${2:-} sh"; }
inst "$OLD" >"$WORK/i1.out" 2>&1 || fail "install.sh for $OLD: $(cat "$WORK/i1.out")"
grep -q 'checksum verified' "$WORK/i1.out" && grep -q 'installed and enabled' "$WORK/i1.out" || fail "the first install's lines: $(cat "$WORK/i1.out")"
[[ "$(insys /usr/local/bin/pgvigil version)" == "pgvigil $OLD ("* ]] || fail "installed version: $(insys /usr/local/bin/pgvigil version)"
docker exec "$REPO" psql -U postgres -XAtq -v ON_ERROR_STOP=1 -c "CREATE ROLE pgvigil_owner LOGIN CREATEROLE PASSWORD '$OPW'" -c "CREATE DATABASE pgvigil OWNER pgvigil_owner" >/dev/null || fail "the owner and the repository database"
insys sh -c "PGVIGIL_REPO_DSN='$OWNER_DSN' /usr/local/bin/pgvigil migrate -config /etc/pgvigil/pgvigil.yaml" >"$WORK/m0.out" 2>&1 || fail "$OLD migrate as the owner: $(tail -n 3 "$WORK/m0.out")"
OLDFILES=$(rq "select count(*) from pgvigil.schema_version"); OLDLATEST=$(rq "select max(version) from pgvigil.schema_version")
# the logins 'pgvigil roles' prints, passwords filled in: the collector's and the UI's as the owner, the monitoring one on the target
insys /usr/local/bin/pgvigil roles > "$WORK/roles.sql"
for l in agent:"$APW" ui:"$UPW" monitor:"$MPW"; do
  line=$(grep -E "^CREATE ROLE pgvigil_${l%%:*} LOGIN PASSWORD '<set-me>'" "$WORK/roles.sql" | head -n 1) || fail "'pgvigil roles' prints no CREATE ROLE for pgvigil_${l%%:*}"
  as=pgvigil_owner; [[ "${l%%:*}" == monitor ]] && as=postgres
  docker exec "$REPO" psql -U "$as" -d pgvigil -XAtq -v ON_ERROR_STOP=1 -c "${line/<set-me>/${l#*:}}" >/dev/null || fail "creating pgvigil_${l%%:*} as $as"
done
insys sh -c "PGVIGIL_REPO_DSN='$OWNER_DSN' /usr/local/bin/pgvigil demo -config /etc/pgvigil/pgvigil.yaml -days $DAYS" >"$WORK/demo.out" 2>"$WORK/demo.log" || fail "$OLD demo: $(tail -n 3 "$WORK/demo.log")"
got=$(rq "select (select count(*) from pgvigil.instances where 'demo' = any(tags)) || ' ' || (select (extract(epoch from max(snapshot_at) - min(snapshot_at)) >= $DAYS * 86400 - 3600)::text from pgvigil.activity_summary)")
[[ "$got" == "12 true" ]] || fail "the demo of $OLD (instances, history of $DAYS days): $got; $(cat "$WORK/demo.out")"
insys sh -c "printf 'PGVIGIL_REPO_DSN=postgres://pgvigil_agent:$APW@$REPO:5432/pgvigil?sslmode=disable\nPROOF_TARGET_DSN=host=$REPO port=5432 user=pgvigil_monitor password=$MPW dbname=postgres sslmode=disable\n' >> /etc/pgvigil/pgvigil.env"
insys sh -c "sed -i 's/^instances: \[\]/instances:\n  - name: proof-target\n    dsn: env:PROOF_TARGET_DSN\n    tags: [proof]/' /etc/pgvigil/pgvigil.yaml"
insys grep -q 'proof-target' /etc/pgvigil/pgvigil.yaml || fail "the instance edit did not land"
T0=$(rq "select now()")
inst "$OLD" >"$WORK/i2.out" 2>&1 || fail "second install.sh for $OLD: $(cat "$WORK/i2.out")"
grep -q 'installed and running' "$WORK/i2.out" || fail "the second install did not end with 'installed and running': $(cat "$WORK/i2.out")"
TID=""; for _ in $(seq 1 90); do TID=$(rq "select i.instance_id from pgvigil.instances i where i.name = 'proof-target' and exists (select 1 from pgvigil.activity_summary s where s.instance_id = i.instance_id)"); [[ -n "$TID" ]] && break; sleep 1; done
[[ -n "$TID" ]] || fail "no activity sample of proof-target under $OLD within 90 s"
# statuses <since> [name...]: 'collection=status' for every collection of the live instance that ran since then: with names,
# once each of them has run again (180 s at most); without, once no new name has come for 10 s. pgvigil.collection_dates
# holds the newest result of each collection (collection_log keeps the results that are not ok alone)
statuses() {
  local since=$1 n prev=-1 same=0 want; shift; want=$#
  for _ in $(seq 1 90); do
    if (( want )); then
      n=$(rq "select count(*) from pgvigil.collection_dates where instance_id = $TID and snapshot_at >= '$since' and collection = any(string_to_array('$*', ' '))")
      (( n >= want )) && break
    else
      n=$(rq "select count(*) from pgvigil.collection_dates where instance_id = $TID and snapshot_at >= '$since'")
      if [[ "$n" == "$prev" && "$n" -gt 0 ]]; then same=$((same + 1)); else same=0; fi
      (( same >= 5 )) && break
      prev=$n
    fi
    sleep 2
  done
  rq "select collection || '=' || status from pgvigil.collection_dates where instance_id = $TID and snapshot_at >= '$since' order by 1"
}
tally() { local k out=""; for k in ok partial skipped error; do out+="$(grep -c "=$k\$" <<<"$1" || true) $k, "; done; echo "${out%, }"; }
OLDST=$(statuses "$T0"); grep -q '=ok$' <<<"$OLDST" || fail "no collection of the live instance ended ok under $OLD: $(tr '\n' ' ' <<<"$OLDST")"
ok "$OLD from the mirror: $OLDFILES migration files applied (the newest $OLDLATEST), the logins of 'pgvigil roles', 12 demo instances over $DAYS days, the service running as the collector login; collections of the live instance: $(tally "$OLDST")"

echo "== E the upgrade, in the order docs/upgrade.md gives =="
inst "$NEW" PGVIGIL_NO_SERVICE=1 >"$WORK/i3.out" 2>&1 || fail "install.sh PGVIGIL_NO_SERVICE=1 for $NEW: $(cat "$WORK/i3.out")"
grep -q 'checksum verified' "$WORK/i3.out" || fail "no 'checksum verified' for $NEW: $(cat "$WORK/i3.out")"
[[ "$(insys /root/pgvigil version)" == "pgvigil $NEW ("* ]] || fail "the downloaded binary is not $NEW"
[[ "$(insys /usr/local/bin/pgvigil version)" == "pgvigil $OLD ("* ]] || fail "PGVIGIL_NO_SERVICE=1 replaced the installed binary"
insys systemctl stop pgvigil || fail "systemctl stop pgvigil"
insys sh -c 'sha256sum /etc/pgvigil/pgvigil.yaml /etc/pgvigil/pgvigil.env' > "$WORK/cfg.before"
# counts <file> <instance id left out, 0 = none>: 'table|i or g|rows' for every table of the schema (partitions through their parent)
counts() {
  docker exec -i "$REPO" psql -U postgres -d "$RDB" -XAtq -v ON_ERROR_STOP=1 -v skip="$2" > "$1" <<'SQL' || return 1
select c.relname || '|' || case when i.has then 'i' else 'g' end || '|' ||
       (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from pgvigil.%I%s', c.relname,
          case when i.has then format(' where instance_id is distinct from %s', :skip) else '' end), false, true, '')))[1]::text
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 cross join lateral (select c.relname not like 'dbadash\_%' and exists (select 1 from pg_attribute a
                       where a.attrelid = c.oid and a.attname = 'instance_id' and not a.attisdropped) as has) i
 where n.nspname = 'pgvigil' and c.relkind in ('r', 'p') and not c.relispartition
 order by c.relname;
SQL
  [[ -s "$1" ]] && ! grep -qvE '^[a-z0-9_]+\|[ig]\|[0-9]+$' "$1"   # a table without its count would be a line of another shape
}
# hashes <file> <columns file>: 'table|md5' over every row of each table the columns file names ('table|col,col,...'), in
# those columns alone and whatever the order of the rows; a table that is gone is left out (the counts name it)
hashes() {
  { echo "create temp table proof_cols (t text primary key, cols text);"; echo "copy proof_cols from stdin with (format text, delimiter '|');"; cat "$2"; echo '\.'
    cat <<'SQL'
select p.t || '|' || (xpath('/row/h/text()', query_to_xml(format(
         'select coalesce(md5(string_agg(h, '''' order by h)), ''empty'') as h from (select md5(row(%s)::text) as h from pgvigil.%I) x', p.cols, p.t), false, true, '')))[1]::text
  from proof_cols p where to_regclass('pgvigil.' || quote_ident(p.t)) is not null order by 1;
SQL
  } | docker exec -i "$REPO" psql -U postgres -d "$RDB" -XAtq -v ON_ERROR_STOP=1 > "$1" || return 1
  [[ -s "$1" ]] && ! grep -qvE '^[a-z0-9_]+\|([0-9a-f]{32}|empty)$' "$1"
}
rq "select c.relname || '|' || string_agg(quote_ident(a.attname), ',' order by a.attnum) from pg_class c join pg_namespace n on n.oid = c.relnamespace join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped where n.nspname = 'pgvigil' and c.relkind in ('r', 'p') and not c.relispartition group by c.relname order by 1" > "$WORK/before.cols"
hashes "$WORK/before.hash" "$WORK/before.cols" || fail "the row hashes before the upgrade"
[[ "$(wc -l < "$WORK/before.hash")" == "$(wc -l < "$WORK/before.cols")" ]] || fail "the row hashes before the upgrade cover $(wc -l < "$WORK/before.hash") of $(wc -l < "$WORK/before.cols") tables"
counts "$WORK/before.all" 0 || fail "the row counts before the upgrade"
counts "$WORK/before.rest" "$TID" || fail "the row counts before the upgrade (the live instance left out)"
docker exec "$REPO" pg_dump -Fc -d "postgres://pgvigil_owner:$OPW@127.0.0.1:5432/pgvigil" -f /tmp/pgvigil-before.dump || fail "pg_dump of the repository as its owner before the upgrade"
# this build on the old schema: it refuses to run and says what to do
rc=0; insys timeout 30 sh -c "PGVIGIL_REPO_DSN='postgres://pgvigil_agent:$APW@$REPO:5432/pgvigil?sslmode=disable' PROOF_TARGET_DSN='host=$REPO port=5432 user=pgvigil_monitor password=$MPW dbname=postgres sslmode=disable' /root/pgvigil run -config /etc/pgvigil/pgvigil.yaml" >"$WORK/behind.out" 2>&1 || rc=$?
[[ "$rc" == 1 ]] || fail "this build's 'run' on the schema of $OLD ended with exit $rc (wanted 1; 124 = still running after 30 s; 3 would stop systemd from starting it again): $(tail -n 2 "$WORK/behind.out")"
grep -q "repository schema is behind this binary (needs $LATEST): run 'pgvigil migrate'" "$WORK/behind.out" || fail "the refusal on the old schema: $(tail -n 2 "$WORK/behind.out")"
MT0=$(date +%s%N)
insys sh -c "PGVIGIL_REPO_DSN='$OWNER_DSN' /root/pgvigil migrate -config /etc/pgvigil/pgvigil.yaml" >"$WORK/m1.out" 2>&1 || fail "this build's migrate as the owner: $(tail -n 3 "$WORK/m1.out")"
MIGMS=$(( ($(date +%s%N) - MT0) / 1000000 ))
APPLIED=$(sed -n 's/.*repository schema is current.*applied=\([0-9]*\).*/\1/p' "$WORK/m1.out" | tail -n 1)
[[ "$APPLIED" == $((NFILES - OLDFILES)) && "$APPLIED" -gt 0 ]] || fail "migrate applied '$APPLIED' file(s), wanted $((NFILES - OLDFILES)) ($NFILES in the tree, $OLDFILES in the store): $(tail -n 2 "$WORK/m1.out")"
[[ "$(rq "select max(version) || ' ' || count(*) from pgvigil.schema_version")" == "$LATEST $NFILES" ]] || fail "schema_version after the migrate: $(rq "select max(version) || ' ' || count(*) from pgvigil.schema_version")"
insys sh -c "PGVIGIL_REPO_DSN='$OWNER_DSN' /root/pgvigil migrate -config /etc/pgvigil/pgvigil.yaml" >"$WORK/m2.out" 2>&1 || fail "a second migrate: $(tail -n 3 "$WORK/m2.out")"
grep -q 'repository schema is current.*applied=0' "$WORK/m2.out" || fail "a second migrate applied something: $(tail -n 2 "$WORK/m2.out")"
counts "$WORK/after.all" 0 || fail "the row counts after the migrate"
hashes "$WORK/after.hash" "$WORK/before.cols" || fail "the row hashes after the migrate (a column of $OLD that is gone or cannot be read fails here)"
# schema_version alone may differ (it holds the files applied more); every other table: the same rows in the columns it had
diff <(grep -v '^schema_version|' "$WORK/before.hash") <(grep -v '^schema_version|' "$WORK/after.hash") >"$WORK/hash.diff" || fail "stored rows changed over the migrate, in the columns $OLD had: $(sed -n 's/^[<>] \([a-z0-9_]*\)|.*/\1/p' "$WORK/hash.diff" | sort -u | tr '\n' ' ')"
NHASH=$(grep -vc '|empty$' "$WORK/before.hash" || true); NEMPTY=$(grep -c '|empty$' "$WORK/before.hash" || true)
# compare <before> <after> <mode> <applied> [<seed>]: strict = every old table the same count, a new table exactly what
# this build's migrations leave in an EMPTY repository (<seed>: reference rows a migration writes, 0100's pgaudit_rules;
# 0 without it); rest = tables
# with an instance column the same, one without may only have grown; schema_version holds the files applied more in both
compare() {
  python3 -I - "$@" <<'PY'
import sys
before, after, mode = sys.argv[1:4]; applied = int(sys.argv[4]) if len(sys.argv) > 4 else 0
seedf = sys.argv[5] if len(sys.argv) > 5 else ""
load = lambda p: {l.split("|")[0]: (l.split("|")[1], int(l.split("|")[2])) for l in open(p).read().split("\n") if l}
b, a = load(before), load(after); bad, grew = [], []
seed = load(seedf) if seedf else {}
seeded = lambda t: seed.get(t, ("", 0))[1]
if not b or not a: sys.exit("an empty count file (%d and %d tables)" % (len(b), len(a)))
for t, (kind, n) in sorted(b.items()):
    if t not in a: bad.append("%s: gone (held %d)" % (t, n)); continue
    m = a[t][1]; want = n + applied if t == "schema_version" else n
    if m == want: continue
    if mode == "rest" and kind == "g" and m > n: grew.append("%s %d -> %d" % (t, n, m)); continue
    bad.append("%s: %d before, %d after" % (t, n, m))
new = sorted(t for t in a if t not in b)
if mode == "strict": bad += ["%s: a table this build adds holds %d row(s), %d after a migrate of an empty repository" % (t, a[t][1], seeded(t)) for t in new if a[t][1] != seeded(t)]
if bad: sys.exit("; ".join(bad))
rows = sum(n for _, n in b.values())
nseed = [t for t in new if seeded(t)]
print("%d tables, %d rows%s%s" % (len(b), rows, ("; %d new tables, each as a migrate of an empty repository leaves it (%s)" % (len(new), "empty" if not nseed else "%d seeded: %s" % (len(nseed), ", ".join("%s %d" % (t, seeded(t)) for t in nseed)))) if mode == "strict" else "", "; grew without an instance column: " + ", ".join(grew) if grew else ""))
PY
}
# what this build's migrations leave in an EMPTY repository: the count a new table must have after the upgrade
docker exec "$REPO" psql -U postgres -XAtq -v ON_ERROR_STOP=1 -c "create database pgvigil_seedcount owner pgvigil_owner" >/dev/null || fail "the empty repository for the seeded counts"
insys sh -c "PGVIGIL_REPO_DSN='postgres://pgvigil_owner:$OPW@$REPO:5432/pgvigil_seedcount?sslmode=disable' /root/pgvigil migrate -config /etc/pgvigil/pgvigil.yaml" >"$WORK/m0.out" 2>&1 || fail "this build's migrate of an empty repository: $(tail -n 3 "$WORK/m0.out")"
RDB=pgvigil_seedcount counts "$WORK/seed.all" 0 || fail "the row counts of the empty repository after its migrate"
docker exec "$REPO" psql -U postgres -XAtq -c "drop database pgvigil_seedcount with (force)" >/dev/null || fail "dropping the empty repository of the seeded counts"
got=$(compare "$WORK/before.all" "$WORK/after.all" strict "$APPLIED" "$WORK/seed.all" 2>&1) || fail "row counts changed over the migrate: $got"
ok "migrate applied $APPLIED files in $MIGMS ms (the store's $OLDFILES to this tree's $NFILES), a second one 0; this build refused to run before it (exit 1); row counts kept: $got; the rows themselves, in the columns $OLD had: the same md5 per table in all $NHASH tables that hold rows ($NEMPTY hold none)"
# the stamp BEFORE the install restarts the unit (stopped since the start of E, so nothing else writes in between): each
# collection first runs up to 10 s after the start, and 'install' returns half a second or more after it, so a stamp read
# after it would miss an hourly collection that had already run
T1=$(rq "select now()")
insys sh -c 'cd /root && ./pgvigil install' >"$WORK/i4.out" 2>&1 || fail "./pgvigil install of $NEW: $(cat "$WORK/i4.out")"
grep -q 'installed and running' "$WORK/i4.out" || fail "the install of $NEW did not end with 'installed and running': $(cat "$WORK/i4.out")"
[[ "$(insys /usr/local/bin/pgvigil version)" == "pgvigil $NEW ("* ]] || fail "the installed binary after the upgrade: $(insys /usr/local/bin/pgvigil version)"
insys sh -c 'sha256sum /etc/pgvigil/pgvigil.yaml /etc/pgvigil/pgvigil.env' | cmp -s - "$WORK/cfg.before" || fail "the upgrade changed the config or the env file"
sleep 12   # past RestartSec (10 s): a start that failed would have been restarted by now
[[ "$(insys systemctl is-active pgvigil)" == active ]] || fail "the service is not active after the upgrade"
[[ "$(insys systemctl show -p NRestarts --value pgvigil)" == 0 ]] || fail "the service restarted $(insys systemctl show -p NRestarts --value pgvigil) time(s) after the upgrade"
[[ "$(insys ps -o user= -C pgvigil | sort -u | tr -d ' ')" == pgvigil ]] || fail "the process runs as $(insys ps -o user= -C pgvigil | sort -u)"
ok "./pgvigil install: $NEW installed and running as pgvigil, 0 restarts, the config and the env file unchanged"

echo "== F the collector of this build under the collector login =="
n=0; for _ in $(seq 1 90); do n=$(rq "select count(*) from pgvigil.activity_summary where instance_id = $TID and snapshot_at > '$T1'"); [[ "$n" -ge 1 ]] && break; sleep 1; done
[[ "$n" -ge 1 ]] || fail "no activity sample of proof-target after the restart within 90 s"
OLDOK=$(sed -n 's/=ok$//p' <<<"$OLDST" | tr '\n' ' ')
# shellcheck disable=SC2086  # the names are plain words, one argument each
NEWST=$(statuses "$T1" $OLDOK)
notes() { rq "select collection || ' ' || status || ': ' || coalesce(note, '') from pgvigil.collection_dates where instance_id = $TID and snapshot_at >= '$T1' and status <> 'ok' order by 1" | sed 's/^/  /' >&2; }
lost=""; for c in $OLDOK; do grep -qx "$c=ok" <<<"$NEWST" || lost+="$c ($(sed -n "s/^$c=//p" <<<"$NEWST" | grep . || echo 'did not run in 180 s')) "; done
if [[ -n "$lost" ]]; then notes; fail "collection(s) ok under $OLD and not under $NEW: $lost"; fi
worse=""; while IFS= read -r l; do [[ "$l" == *=error || "$l" == *=partial ]] || continue; grep -qx "$l" <<<"$OLDST" || worse+="${l%%=*} "; done <<<"$NEWST"
if [[ -n "$worse" ]]; then notes; fail "collection(s) ending error or partial under $NEW that did not under $OLD: $worse"; fi
ok "an activity sample after the restart; collections of the live instance under $NEW: $(tally "$NEWST") (under $OLD: $(tally "$OLDST")); every one of the $(wc -w <<<"$OLDOK") ok under $OLD is ok again, none newly error or partial"

echo "== G every page, served by this build under the UI login =="
PORT=""; for _ in $(seq 1 20); do p=$((21000 + RANDOM % 9000)); if ! ss -ltnH "( sport = :$p or sport = :$((p + 1)) )" | grep -q .; then PORT=$p; break; fi; done
[[ -n "$PORT" ]] || fail "no free port pair for the UI and the browser"; CDP=$((PORT + 1))
printf 'repository:\n  dsn: env:PGVIGIL_UI_DSN\n' > "$WORK/ui.yaml"
PGVIGIL_UI_DSN="postgres://pgvigil_ui:$UPW@127.0.0.1:$RPORT/pgvigil?sslmode=disable" "$NEWBIN" serve -config "$WORK/ui.yaml" -dsn env:PGVIGIL_UI_DSN -no-login -listen "127.0.0.1:$PORT" 2>"$WORK/serve.log" & SRV=$!
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; kill -0 "$SRV" 2>/dev/null || fail "this build's serve ended at start"; sleep 0.2; done
curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null || fail "this build's serve does not answer on 127.0.0.1:$PORT"
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank >"$WORK/chrome.log" 2>&1 & CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
cat > "$WORK/walk.mjs" <<'JS'
// node walk.mjs <cdp port> <base url/> <log file>: every page the tab strips list (the root's, every instance's) and one
// page of every other route those pages link to. A page counts as rendered when its content replaced the shell's
// loading line, the network went quiet, no error box is on it, and its load saw no API answer of 400 or over, no failed
// request and no script exception. Exit 0 when every page rendered.
const [port, U, logPath] = process.argv.slice(2);
const fs = await import('node:fs');
// an API that answers with an error leaves no instance here; the first page below then fails with what the browser saw
const inst = await (await fetch(U + 'api/instances')).json().catch(() => ({}));
const rows = Array.isArray(inst.rows) ? inst.rows.map(r => Object.fromEntries(inst.columns.map((c, i) => [c, r[i]]))) : [];
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0, lastNet = Date.now(), seen = []; const wait = new Map(), inflight = new Set();
ws.addEventListener('message', m => {
  const d = JSON.parse(m.data);
  if (d.id && wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); return; }
  const p = d.params ?? {};
  if (d.method === 'Network.requestWillBeSent') { inflight.add(p.requestId); lastNet = Date.now(); }
  else if (d.method === 'Network.responseReceived') { if (p.response.status >= 400) seen.push(`HTTP ${p.response.status} ${p.response.url.replace(U, '/')}`); }
  else if (d.method === 'Network.loadingFinished') { inflight.delete(p.requestId); lastNet = Date.now(); }
  else if (d.method === 'Network.loadingFailed') { inflight.delete(p.requestId); lastNet = Date.now(); if (!p.canceled) seen.push(`request failed: ${p.errorText}`); }
  else if (d.method === 'Runtime.exceptionThrown') seen.push('script exception: ' + String(p.exceptionDetails?.exception?.description ?? p.exceptionDetails?.text ?? '').split('\n')[0]);
});
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => (await cmd('Runtime.evaluate', { expression: expr, returnByValue: true })).result?.result?.value;
const sleep = ms => new Promise(r => setTimeout(r, ms));
await cmd('Page.enable'); await cmd('Runtime.enable'); await cmd('Network.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
// drawn: the page's own content is in <main> (the children of the page before are gone, the loading line is replaced)
const state = `(() => { const m = document.querySelector('main'); if (!m || !m.children.length) return 'none';
  if (m.querySelector(':scope > [data-walk-old]')) return 'old';
  const f = m.firstElementChild; if (m.children.length === 1 && f.matches('p.empty') && /^(Loading|$)/.test(f.textContent.trim())) return 'loading';
  return 'ok'; })()`;
const open = async (hash) => {
  seen = [];
  await ev(`document.querySelectorAll('main > *').forEach(e => e.setAttribute('data-walk-old', '1')); 1`);
  await cmd('Page.navigate', { url: U + hash });
  const t = Date.now(); let s = 'none';
  while (Date.now() - t < 20000) {
    s = await ev(state);
    if (s === 'ok' && inflight.size === 0 && Date.now() - lastNet > 300) break;
    await sleep(50);
  }
  if (s !== 'ok' || inflight.size) return [`not drawn in 20 s (state ${s}, ${inflight.size} request(s) open)`, ...seen];
  const boxes = await ev(`[...document.querySelectorAll('main p.error')].map(e => e.textContent.slice(0, 200))`);
  return [...(boxes ?? []).map(b => 'error box: ' + b), ...seen];
};
const tabsOf = async () => await ev(`(() => { const t = document.querySelector('#tabs'); return t.dataset.all ? JSON.parse(t.dataset.all) : [...t.querySelectorAll('a')].map(a => a.getAttribute('href')); })()`);
const links = async () => (await ev(`[...document.querySelectorAll('main a[href^="#/"]')].map(a => a.getAttribute('href'))`)) ?? [];
const route = h => (h.match(/^#\/([^?]*)/)?.[1] ?? '') + (/[?&]i=\d+/.test(h) ? '@i' : '');
const out = []; let failed = 0, n = 0; const done = new Set(), routes = new Set(), drill = [];
const visit = async (hash, kind) => {
  if (done.has(hash)) return; done.add(hash); n++;
  const why = await open(hash);
  if (why.length) { failed++; console.log(`FAIL ${hash}: ${why.slice(0, 4).join(' | ')}`); }
  out.push(`${why.length ? 'FAIL' : 'ok  '} ${kind} ${hash}${why.length ? ': ' + why.join(' | ') : ''}`);
  if (!why.length) for (const l of await links()) if (!routes.has(route(l))) { routes.add(route(l)); drill.push(l); }
};
// the tab lists first, so their routes are known before any link is taken for a drill page
const first = await open('#/summary'); if (first.length) { console.log(`FAIL #/summary: ${first.join(' | ')}`); process.exit(1); }
const rootTabs = await tabsOf(); const perInst = [];
if (!rootTabs.length) { console.log('FAIL the root tab strip lists no page'); process.exit(1); }
for (const r of rows) {
  const w = await open(`#/summary?i=${r.instance_id}`);
  if (w.length) { failed++; console.log(`FAIL #/summary?i=${r.instance_id} (${r.name}): ${w.join(' | ')}`); continue; }
  const tabs = (await tabsOf()).map(t => t.replace(/([?&])i=\d+/, `$1i=${r.instance_id}`));
  if (!tabs.length) { failed++; console.log(`FAIL #/summary?i=${r.instance_id} (${r.name}): its tab strip lists no page`); continue; }
  perInst.push([r, tabs]);
}
for (const t of rootTabs) routes.add(route(t));
for (const [, tabs] of perInst) for (const t of tabs) routes.add(route(t));
await cmd('Page.navigate', { url: 'about:blank' });   // away from the last Summary, so the first page of the walk is a load of its own
for (const t of rootTabs) await visit(t, 'root');
let tabPages = 0;
for (const [r, tabs] of perInst) for (const t of tabs) { await visit(t, r.name); tabPages++; }
let drilled = 0;
while (drill.length && drilled < 80) { await visit(drill.shift(), 'drill'); drilled++; }
if (drill.length) { failed++; console.log(`FAIL ${drill.length} linked route(s) left unvisited after ${drilled}: ${drill.slice(0, 5).join(' ')}`); }
fs.writeFileSync(logPath, out.join('\n') + '\n');
console.log(`walk: ${n} pages (${rootTabs.length} root, ${tabPages} of ${perInst.length} instances, ${drilled} other routes), ${failed} failed`);
ws.close();
process.exit(failed || perInst.length !== rows.length ? 1 : 0);
JS
node "$WORK/walk.mjs" "$CDP" "http://127.0.0.1:$PORT/" "$WORK/walk.log" | tee "$WORK/walk.out" || fail "a page did not render after the upgrade (above)"
WALK=$(grep '^walk: ' "$WORK/walk.out" | tail -n 1); [[ "$WALK" == *", 0 failed" ]] || fail "the walk's last line: $WALK"
NINST=$(rq "select count(*) from pgvigil.instances"); [[ "$WALK" == *"of $NINST instances"* && "$NINST" == 13 ]] || fail "the walk covered '$WALK', the store holds $NINST instances (12 demo and the live one expected)"
[[ -n "${PGVIGIL_UPGRADE_WALK_OUT:-}" ]] && cp "$WORK/walk.log" "$PGVIGIL_UPGRADE_WALK_OUT"
ok "$WALK"
# the walk's own control: with the UI login's read role taken away the first page must fail (an error box or an API answer of 400 or over)
# as the owner, who granted it: from PostgreSQL 16 a membership is revoked per grantor, and a superuser's plain REVOKE of
# the owner's grant removes nothing (a warning, exit 0)
docker exec "$REPO" psql -U pgvigil_owner -d pgvigil -XAtq -v ON_ERROR_STOP=1 -c "REVOKE pgvigil_reader FROM pgvigil_ui" >/dev/null 2>&1 || fail "the control's revoke"
[[ "$(rq "select pg_has_role('pgvigil_ui', 'pgvigil_reader', 'member')")" == f ]] || fail "the control's revoke took nothing: pgvigil_ui is still a member of pgvigil_reader"
crc=0; node "$WORK/walk.mjs" "$CDP" "http://127.0.0.1:$PORT/" "$WORK/walk-control.log" >"$WORK/walk-control.out" 2>&1 || crc=$?
docker exec "$REPO" psql -U pgvigil_owner -d pgvigil -XAtq -v ON_ERROR_STOP=1 -c "GRANT pgvigil_reader TO pgvigil_ui" >/dev/null 2>&1 || fail "the control's grant back"
[[ "$(rq "select pg_has_role('pgvigil_ui', 'pgvigil_reader', 'member')")" == t ]] || fail "the control's grant back did not land"
[[ "$crc" != 0 ]] && grep -Eq '^FAIL .*(error box|HTTP [45][0-9][0-9])' "$WORK/walk-control.out" || fail "with the UI login's read role taken away the walk (exit $crc) did not fail on an error box or an API answer of 400 or over: $(tail -n 3 "$WORK/walk-control.out")"
kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; SRV=""
kill "$CHR" 2>/dev/null || true; wait "$CHR" 2>/dev/null || true; CHR=""
ok "the walk's control: the UI login without its read role fails the first page ($(grep -m1 '^FAIL ' "$WORK/walk-control.out" | cut -c1-140))"

echo "== H the rows after the restart and the walk =="
counts "$WORK/final.rest" "$TID" || fail "the row counts after the restart"
got=$(compare "$WORK/before.rest" "$WORK/final.rest" rest "$APPLIED" 2>&1) || fail "rows outside the live instance changed after the restart: $got"
UP=$(rq "select extract(epoch from now() - '$T1'::timestamptz)::int")
[[ "$(insys systemctl is-active pgvigil || true)" == active && "$(insys systemctl show -p NRestarts --value pgvigil)" == 0 ]] || fail "the service $UP s after the upgrade: $(insys systemctl is-active pgvigil || true), $(insys systemctl show -p NRestarts --value pgvigil) restart(s) (a collection that ends the process is restarted by systemd 10 s later)"
ok "outside the live instance: $got; the unit still active with 0 restarts $UP s after the upgrade"
echo "== I the way back (the dump, the old binary), then the installer-first order on that restored store =="
insys systemctl stop pgvigil || fail "systemctl stop pgvigil"
docker exec "$REPO" psql -U postgres -XAtq -v ON_ERROR_STOP=1 -c "CREATE DATABASE pgvigil_back OWNER pgvigil_owner" >/dev/null || fail "the database for the restore"
docker exec "$REPO" pg_restore -d "postgres://pgvigil_owner:$OPW@127.0.0.1:5432/pgvigil_back" --exit-on-error /tmp/pgvigil-before.dump >"$WORK/restore.out" 2>&1 || fail "pg_restore, as the owner, of the dump taken before the upgrade: $(tail -n 3 "$WORK/restore.out")"
RDB=pgvigil_back
counts "$WORK/back.all" 0 || fail "the row counts of the restored store"
cmp -s "$WORK/before.all" "$WORK/back.all" || fail "the restored store's row counts differ from the ones before the upgrade: $(diff "$WORK/before.all" "$WORK/back.all" | head -n 6 | tr '\n' ' ')"
hashes "$WORK/back.hash" "$WORK/before.cols" || fail "the row hashes of the restored store"
cmp -s "$WORK/before.hash" "$WORK/back.hash" || fail "the restored store's rows differ from the ones before the upgrade: $(diff "$WORK/before.hash" "$WORK/back.hash" | sed -n 's/^[<>] \([a-z0-9_]*\)|.*/\1/p' | sort -u | tr '\n' ' ')"
[[ "$(rq "select max(version) || ' ' || count(*) from pgvigil.schema_version")" == "$OLDLATEST $OLDFILES" ]] || fail "the restored store's schema level"
# the proof's own switch: the service's repository line names the restored copy (a real way back restores over the repository itself)
insys sed -i "s#^\(PGVIGIL_REPO_DSN=postgres://pgvigil_agent:.*\)/pgvigil?#\1/pgvigil_back?#" /etc/pgvigil/pgvigil.env
insys grep -q '/pgvigil_back?' /etc/pgvigil/pgvigil.env || fail "the env file's switch to the restored store did not land"
BACK_DSN="postgres://pgvigil_owner:$OPW@$REPO:5432/pgvigil_back?sslmode=disable"
T2=$(rq "select now()")
inst "$OLD" >"$WORK/i5.out" 2>&1 || fail "install.sh for $OLD on the restored store: $(cat "$WORK/i5.out")"
grep -q 'installed and running' "$WORK/i5.out" || fail "the reinstall of $OLD did not end with 'installed and running': $(cat "$WORK/i5.out")"
[[ "$(insys /usr/local/bin/pgvigil version)" == "pgvigil $OLD ("* ]] || fail "the installed binary on the way back: $(insys /usr/local/bin/pgvigil version)"
n=0; for _ in $(seq 1 90); do n=$(rq "select count(*) from pgvigil.activity_summary where instance_id = $TID and snapshot_at > '$T2'"); [[ "$n" -ge 1 ]] && break; sleep 1; done
[[ "$n" -ge 1 ]] || fail "no activity sample of proof-target under $OLD on the restored store within 90 s"
ok "the way back: the owner's dump restores, as the owner, with every row count and every row's md5 from before the upgrade ($(wc -l < "$WORK/back.all") tables, schema at $OLDLATEST) and $OLD, reinstalled from the mirror, collects on it"
rc=0; inst "$NEW" >"$WORK/i6.out" 2>&1 || rc=$?
# 'pgvigil install' calls the unit running only after it stayed active for four seconds: the first start on the old
# schema ends at the schema check well inside that, so the installer ends with exit 1 and says why in its own line
[[ "$rc" == 1 ]] || fail "the installer-first upgrade ended with exit $rc (want 1) on a schema that is behind: $(tail -n 5 "$WORK/i6.out")"
grep -q 'the service did not come up' "$WORK/i6.out" || fail "the installer-first upgrade ended with exit $rc without 'the service did not come up': $(tail -n 5 "$WORK/i6.out")"
grep "the service did not come up" "$WORK/i6.out" | grep "needs $LATEST" | grep -q "run 'pgvigil migrate' as the repository owner" \
  || fail "the installer's own line does not name $LATEST and 'pgvigil migrate': $(tail -n 5 "$WORK/i6.out")"
SAID="exit $rc with 'the service did not come up', naming $LATEST and 'pgvigil migrate' in the same line"
echo "     the installer's last lines, as the operator sees them:"; tail -n 8 "$WORK/i6.out" | cut -c1-220 | sed 's/^/     | /'
[[ "$(insys /usr/local/bin/pgvigil version)" == "pgvigil $NEW ("* ]] || fail "the installer-first upgrade left the binary at $(insys /usr/local/bin/pgvigil version)"
sleep 12
insys journalctl -u pgvigil --no-pager --since "-60s" | grep -q "repository schema is behind this binary (needs $LATEST): run 'pgvigil migrate'" || fail "the journal does not name the migration to run"
RST=$(insys systemctl show -p NRestarts --value pgvigil); [[ "$RST" -ge 1 ]] || fail "the unit was not restarted while the schema was behind (NRestarts $RST)"
T3=$(rq "select now()")
insys sh -c "PGVIGIL_REPO_DSN='$BACK_DSN' /usr/local/bin/pgvigil migrate -config /etc/pgvigil/pgvigil.yaml" >"$WORK/m3.out" 2>&1 || fail "this build's migrate on the restored store: $(tail -n 3 "$WORK/m3.out")"
grep -q "repository schema is current.*applied=$APPLIED" "$WORK/m3.out" || fail "the migrate on the restored store: $(tail -n 2 "$WORK/m3.out")"
n=0; for _ in $(seq 1 90); do n=$(rq "select count(*) from pgvigil.activity_summary where instance_id = $TID and snapshot_at > '$T3'"); [[ "$n" -ge 1 ]] && break; sleep 1; done
[[ "$n" -ge 1 && "$(insys systemctl is-active pgvigil)" == active ]] || fail "the unit did not come up by itself after the migrate (state $(insys systemctl is-active pgvigil || true), $n new sample(s))"
counts "$WORK/back.rest" "$TID" || fail "the row counts of the restored store after its upgrade"
got=$(compare "$WORK/before.rest" "$WORK/back.rest" rest "$APPLIED" 2>&1) || fail "rows outside the live instance changed on the installer-first upgrade: $got"
ok "the installer first: install.sh ended $SAID, the binary replaced, the journal names $LATEST and 'pgvigil migrate', $RST restart(s) in 12 s; after the owner's migrate the unit came up by itself; outside the live instance: $got"
echo "proof-upgrade: OK ($OLD -> this build: the release verified against SHA256SUMS and its SBOM against the binary; $SIGNED; installed from a mirror on a network with no route out; $APPLIED migration files applied with every row count kept; the service restarted on this build under the collector login; $WALK; the way back from the dump and the installer-first order proven)"
