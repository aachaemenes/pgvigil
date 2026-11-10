#!/usr/bin/env bash
# Proof of the FIPS 140-3 build (government readiness, task 50). GOFIPS140=v1.0.0 makes the Go
# Cryptographic Module v1.0.0 (CMVP certificate #5247) the only cryptography in the binary and turns
# FIPS 140-3 mode on from the start; the release's *_fips assets are built this way. Needs go and a
# PostgreSQL to use as a throwaway repository for the login and TLS proof (PGVIGIL_REPO_DSN, as
# proof-auth.sh wants it); without one the auth part is skipped and said.
# Expected: the FIPS build prints "fips140 on (module v1.0.0)" from `pgvigil version` and "on, enforced"
# under GODEBUG=fips140=only; the plain build prints "fips140 off"; the unit tests of cmd/pgvigil and
# internal/web pass under GOFIPS140=v1.0.0 (the UI's argon2id hashing and the certificate code run in
# FIPS mode); proof-auth.sh passes with the FIPS binary (PGVIGIL_BIN): the UI login over HTTPS with the
# FIPS-approved TLS suites and curves; `govulncheck` is not part of this proof (CI runs it).
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== build: FIPS and plain"
CGO_ENABLED=0 GOFIPS140=v1.0.0 go build -trimpath -ldflags '-s -w -X main.version=v0.0.0-fipsproof' -o "$WORK/pgvigil-fips" ./cmd/pgvigil
CGO_ENABLED=0 go build -trimpath -ldflags '-s -w -X main.version=v0.0.0-fipsproof' -o "$WORK/pgvigil-plain" ./cmd/pgvigil
f=$("$WORK/pgvigil-fips" version); echo "   fips : $f"
p=$("$WORK/pgvigil-plain" version); echo "   plain: $p"
e=$(GODEBUG=fips140=only "$WORK/pgvigil-fips" version); echo "   only : $e"
grep -qF 'fips140 on (module v1.0.0)' <<<"$f" || fail "the FIPS build does not report fips140 on with module v1.0.0"
grep -qF 'fips140 off)' <<<"$p" || fail "the plain build does not report fips140 off"
grep -qF 'fips140 on, enforced (module v1.0.0)' <<<"$e" || fail "GODEBUG=fips140=only does not report enforced"
[[ "$f" == "pgvigil v0.0.0-fipsproof ("* ]] || fail "the version line no longer starts with pgvigil <version>"

echo "== unit tests under GOFIPS140=v1.0.0 (cmd/pgvigil, internal/web)"
GOFIPS140=v1.0.0 go test ./cmd/pgvigil/ ./internal/web/ -count=1 2>&1 | tail -2

if [[ -n "${PGVIGIL_REPO_DSN:-}" ]]; then
  echo "== proof-auth.sh with the FIPS binary (UI login, HTTPS listen)"
  PGVIGIL_BIN="$WORK/pgvigil-fips" scripts/proof-auth.sh || fail "proof-auth.sh failed under the FIPS binary"
else
  echo "== proof-auth.sh with the FIPS binary: SKIPPED (no PGVIGIL_REPO_DSN): the login and TLS part is not proven here"
fi
echo "OK: FIPS build reports fips140 on (module v1.0.0), enforced under fips140=only; plain build off; tests green"
