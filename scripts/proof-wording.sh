#!/usr/bin/env bash
# Proof of the web UI's wording per engine (the pre-publish walk): no page a PostgreSQL instance reaches shows
# a word only SQL Server has, and no SQL Server page a PostgreSQL word, but where the page says whose word it is.
# The demo fleet is seeded into a throwaway database and served on loopback (or PGVIGIL_DEMO_URL names a demo another
# proof already serves), a headless Chromium reads every page of two instances of each engine, the Pooler instance,
# the fleet pages on a tag folder of one engine per engine, the drill pages they link to and the mixed root's
# row-scoped lines (scripts/wording-walk.mjs), and each element is checked by scripts/wording-match.mjs against
# scripts/wording-words.txt and wording-allow.txt; the reds are graded against scripts/wording-expected.txt.
# Needs go, psql, chromium, node 22+; the web bundle internal/web/dist/app.js built first (npm run build in web/).
#   PGVIGIL_ADMIN_DSN     keyword-form connection to a cluster as a login that may create a database (not needed with
#                         PGVIGIL_DEMO_URL)
#   PGVIGIL_DEMO_URL      a demo already served (http://127.0.0.1:<port>/): no build, no seed
#   PGVIGIL_DEMO_WAIT_S   seconds to wait for the seeded demo (default 240)
#   PGVIGIL_WORDING_OUT   a file that gets the walk's JSON (every page, every red, the grade)
#   PGVIGIL_WORDING_SHOTS a folder: a shot of each page read
# Expected (the run on the join's tip 6690789 with the five SQL Server group names' 31 rows moved to must-not: the
# join's j11 on af0d2e9 listed 26 must rows 'not seen' - Memory Dump, Availability Group, Last Good Check DB, Agent
# Jobs, Backup LOG on PostgreSQL rows and scopes, gone since a1e161f's labelOf / pgLabel - and the 5 may rows of the
# same names showed no red either; every other line of j11 unchanged; written before it):
#   the matcher's self-test: 65 of 65 cases (63 words, 5 allow rows, 147 expected rows)
#   picked: PostgreSQL demo-onprem-erp01, demo-rds-billing01, the Pooler on demo-aurora-crm01; SQL Server
#     demo-onprem-sql01, demo-azure-sql03; tags aurora (PostgreSQL; 3 instance(s)), sales (SQL Server; 2)
#   pages: 361 (pg-instance 125, ms-instance 111, pg-tag 61, ms-tag 61, root 3), 0 not read (0 not settled, 0 with 0
#     elements, 0 with an error box); the tree menu 4 items per engine
#   the grade: every must row listed (81), every must-not row gone (39), the 27 may rows reported; no red outside
#     the file: 'wording walk: OK'
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); DB="pgvigil_wording_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  [[ -n "$SRV" ]] && { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; } || true
  [[ -n "$CHR" ]] && { kill "$CHR" 2>/dev/null; wait "$CHR" 2>/dev/null; } || true
  [[ -z "${PGVIGIL_DEMO_URL:-}" && -n "${PGVIGIL_ADMIN_DSN:-}" ]] && psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
for t in chromium node curl; do command -v $t >/dev/null || fail "$t is not on this machine"; done

echo "== the matcher's self-test"
node scripts/wording-match.mjs --self-test || fail "the matcher's self-test"

if [[ -n "${PGVIGIL_DEMO_URL:-}" ]]; then
  URL="${PGVIGIL_DEMO_URL%/}/"
  curl -fs "${URL}api/instances" >/dev/null || fail "PGVIGIL_DEMO_URL does not answer /api/instances: $URL"
  echo "== the demo already served at $URL"
else
  for t in go psql; do command -v $t >/dev/null || fail "$t is not on this machine"; done
  [[ -n "${PGVIGIL_ADMIN_DSN:-}" ]] || fail "PGVIGIL_ADMIN_DSN is not set (or set PGVIGIL_DEMO_URL)"
  echo "== build and seed the demo into $DB, serve on 127.0.0.1:$PORT"
  CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil || fail "the build"
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null || fail "create database $DB"
  "$WORK/pgvigil" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
  SRV=$!
  for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-240}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { tail -5 "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
  grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in ${PGVIGIL_DEMO_WAIT_S:-240} s"; }
  URL="http://127.0.0.1:$PORT/"
fi

echo "== a headless Chromium on CDP $CDP (light theme, en-US)"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu --lang=en-US about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"

echo "== the walk"
# the walk has a limit: a browser that never answers ends the proof, never hangs it
timeout 1200 node scripts/wording-walk.mjs "$CDP" "$URL" "${PGVIGIL_WORDING_OUT:-$WORK/wording.json}" ${PGVIGIL_WORDING_SHOTS:+"$PGVIGIL_WORDING_SHOTS"} | tee "$WORK/wording.txt"
rc=${PIPESTATUS[0]}
(( rc == 124 )) && fail "the walk did not end in 1200 s"
grep -q '^wording walk: ' "$WORK/wording.txt" || fail "the walk ended without its verdict (rc $rc)"
(( rc == 0 )) || fail "$(grep '^wording walk: ' "$WORK/wording.txt")"
echo "PROOF OK: $(grep '^wording walk: ' "$WORK/wording.txt")"
