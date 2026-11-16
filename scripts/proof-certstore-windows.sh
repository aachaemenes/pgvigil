#!/usr/bin/env bash
# The Linux half of task B24n's proof (serve's TLS from the Windows certificate store), run on a build machine (the lab
# box, as a job): proof row P7 and the two Windows binaries scripts/proof-certstore-windows.ps1 takes. A copy of this
# tree (no .git) gets scripts/proof-certstore-wiring.patch (or holds it already); nothing in this tree changes but
# <out dir>.
#   usage: bash scripts/proof-certstore-windows.sh <out dir, relative to the tree's root>
#   Needs: go, git (git apply only), tar, sha256sum.
# Expected (written before its first run):
#  P7  go test of the selection's rules and the off-Windows refusal - TestNormalizeThumbprint, TestParseStoreName,
#      TestDNSNameMatchesSAN, TestSelectByThumbprint, TestSelectBySubject, TestGrantRules, TestStoreWindowsOnly: 7 PASS;
#      a Linux build's 'serve -tls-thumbprint' and 'cert -grant-key-access' each refused with 'the Windows certificate
#      store is read on Windows only'
#  W   GOOS=windows go vet ./cmd/pgvigil/ ok (the Windows-only test file included); pgvigil.exe (go build) and
#      certstore.test.exe (go test -c) for windows/amd64 in <out dir>, their sha256 printed
#  The last line: 'proof-certstore-windows (build): OK'.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
OUT=${1:?usage: bash scripts/proof-certstore-windows.sh <out dir>}
[[ $OUT =~ ^[A-Za-z0-9._-]+$ ]] || { echo "FAIL: the out dir is one plain name under the tree's root: $OUT" >&2; exit 1; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
for tool in go git tar sha256sum; do command -v "$tool" >/dev/null || fail "$tool is not on this machine"; done
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
TREE=$WORK/tree
mkdir -p "$TREE"
tar --exclude=./.git --exclude=./web/node_modules --exclude=./bin --exclude="./$OUT" -cf - . | tar -xf - -C "$TREE"
PATCH=$ROOT/scripts/proof-certstore-wiring.patch
if (cd "$TREE" && git apply --check "$PATCH" 2>/dev/null); then
  (cd "$TREE" && git apply "$PATCH") || fail "the wiring patch"
  ok "wiring patch applied to the build's copy"
elif (cd "$TREE" && git apply -R --check "$PATCH" 2>/dev/null); then
  ok "the tree already holds the wiring"
else
  fail "the wiring patch neither applies nor is applied"
fi
cd "$TREE"

# ---- P7 ---------------------------------------------------------------------------------------------------------------
tests='TestNormalizeThumbprint|TestParseStoreName|TestDNSNameMatchesSAN|TestSelectByThumbprint|TestSelectBySubject|TestGrantRules|TestStoreWindowsOnly'
out=$(go test ./cmd/pgvigil/ -count=1 -v -run "^($tests)\$" 2>&1) || { printf '%s\n' "$out" | tail -40; fail "P7 go test"; }
passed=$(grep -c '^--- PASS' <<<"$out" || true)
[[ $passed == 7 ]] || { printf '%s\n' "$out" | tail -40; fail "P7: $passed of 7 tests passed"; }
ok "P7 the 7 selection and off-Windows tests pass"
go build -o "$WORK/pgvigil" ./cmd/pgvigil || fail "go build (linux)"
printf 'repository:\n  dsn: postgres://pgvigil@127.0.0.1:9/pgvigil?connect_timeout=3\ninstances: []\n' > "$WORK/c.yaml"
want='the Windows certificate store is read on Windows only'
if got=$("$WORK/pgvigil" serve -config "$WORK/c.yaml" -listen 127.0.0.1:0 -tls-thumbprint AB 2>&1); then fail "P7 serve -tls-thumbprint ran on Linux: $got"; fi
grep -qF "$want" <<<"$got" || fail "P7 serve -tls-thumbprint said: $got"
ok "P7 serve -tls-thumbprint refused on Linux: $want"
if got=$("$WORK/pgvigil" cert -grant-key-access AB -account someone 2>&1); then fail "P7 cert -grant-key-access ran on Linux: $got"; fi
grep -qF "$want" <<<"$got" || fail "P7 cert -grant-key-access said: $got"
ok "P7 cert -grant-key-access refused on Linux"

# ---- W the Windows binaries -------------------------------------------------------------------------------------------
GOOS=windows GOARCH=amd64 go vet ./cmd/pgvigil/ || fail "go vet (windows)"
ok "W go vet windows/amd64, the Windows-only test file included"
mkdir -p "$ROOT/$OUT"
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -o "$ROOT/$OUT/pgvigil.exe" ./cmd/pgvigil || fail "go build (windows)"
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go test -c -trimpath -o "$ROOT/$OUT/certstore.test.exe" ./cmd/pgvigil || fail "go test -c (windows)"
(cd "$ROOT/$OUT" && sha256sum pgvigil.exe certstore.test.exe)
ok "W pgvigil.exe and certstore.test.exe in $OUT"
echo "proof-certstore-windows (build): OK"
