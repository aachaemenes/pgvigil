#!/usr/bin/env bash
# Proof of the web UI's accessibility (government readiness, task 50; Section 508 points at WCAG 2.0 AA,
# checked here as WCAG 2.1 A + AA with axe-core): a demo fleet is seeded into a throwaway database and
# served on loopback, a headless Chromium walks every root tab and every tab of an on-prem and a cloud
# instance in both themes (and the pages with status cells again in the quiet status style), and axe-core runs on each page. Needs go, psql, chromium, node and npm, and a
# PostgreSQL to hold the throwaway database:
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a login that may create a database
#   PGVIGIL_DEMO_WAIT_S the seconds to wait for the seeded demo to serve (default 240; a loaded machine seeds slower)
#   PGVIGIL_A11Y_MAX   the most violation nodes allowed (default 0)
# Expected: every page renders and axe runs on it (the check's exit 0); every off control (disabled or aria-disabled)
# on Community tools, Custom reports and Report mail has a visible reason as its description (other pages' are
# listed 'b2', not failed; a planted one is counted first); 0 violation nodes under the
# WCAG 2.1 A / AA rules in both themes (the rules axe can judge; keyboard order, focus visibility and
# screen-reader behaviour need a hand pass and are not claimed here). axe-core 4.14.0 is installed into
# the proof's temporary folder from npm.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
MAX=${PGVIGIL_A11Y_MAX:-0}
WORK=$(mktemp -d); DB="pgvigil_a11y_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in chromium node npm psql; do command -v $t >/dev/null || fail "$t is not on this machine"; done

echo "== build and seed the demo into $DB, serve on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
"$WORK/pgvigil" demo -dsn "$DSN" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-240}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { cat "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in ${PGVIGIL_DEMO_WAIT_S:-240} s (PGVIGIL_DEMO_WAIT_S raises the wait on a loaded machine)"; }

echo "== axe-core 4.14.0 and a headless Chromium on CDP $CDP"
(cd "$WORK" && npm install --silent --no-audit --no-fund --no-package-lock axe-core@4.14.0 >/dev/null 2>&1) || fail "npm install axe-core failed"
AXE="$WORK/node_modules/axe-core/axe.min.js"; [[ -f "$AXE" ]] || fail "axe.min.js not found after install"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"

echo "== the check"
node scripts/a11y-check.mjs "$CDP" "http://127.0.0.1:$PORT/" "$AXE" "${PGVIGIL_A11Y_OUT:-$WORK/a11y.json}" | tee "$WORK/a11y.txt" || {
  grep -q '^off-reason: [1-9]' "$WORK/a11y.txt" && fail "an off control on Community tools, Custom reports or Report mail has no visible reason (the 'off' lines above)"
  grep -q '^off-reason self-test:' "$WORK/a11y.txt" && ! grep -q '^off-reason self-test: planted off buttons without a reason counted 4 of 4$' "$WORK/a11y.txt" \
    && fail "the off-reason check's self-test did not count its 4 planted buttons"
  echo "chromium alive: $(kill -0 $CHR 2>/dev/null && echo yes || echo no); its log's last lines:"; tail -15 "$WORK/chrome.log" | cut -c1-300
  fail "a page did not render or axe did not run on it"; }
# the demo has SQL Server instances: a check that walked none of their pages has not checked them
sqlp=$(sed -n 's/^SQL Server pages in the check: \([0-9]*\)$/\1/p' "$WORK/a11y.txt"); (( ${sqlp:-0} > 0 )) || fail "no SQL Server page was in the check"
nodes=$(sed -n 's/^total: [0-9]* rule(s), \([0-9]*\) node(s).*/\1/p' "$WORK/a11y.txt")
[[ -n "$nodes" ]] || fail "no total line"
(( nodes <= MAX )) || fail "$nodes violation node(s), the proof allows $MAX"
echo "OK: every page rendered in both themes; $nodes violation node(s) under WCAG 2.1 A/AA (allowed $MAX)"
