#!/usr/bin/env bash
# Proof of the verdict card (the instance Summary's plain-words card: Allen 06:40, NexaPG's 'Easy mode' idea, no code or
# text taken): a demo fleet is seeded into a throwaway database and served on loopback, three fixture instances the
# demo's minute tick never touches are added (fx-unread: never read; fx-stale: one collection 4 hours old, another just
# now; fx-offline: its newest read 40 minutes old), and a headless Chromium runs scripts/verdict-check.mjs over every
# instance's Summary. Needs go, psql, chromium and node, and a PostgreSQL for the throwaway database:
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a login that may create a database
#   PGVIGIL_DEMO_WAIT_S the seconds to wait for the seeded demo to serve (default 240; a loaded machine seeds slower)
# Expected: every instance's card - its state as its header implies (Awaiting -> 'unread'; Critical / Offline ->
# 'problem'; Warning, or OK with a late collection -> 'warning'; OK -> 'ok'), its reasons the header's band items in
# their order, each a page link, a plain sentence, no SQL Server word on a PostgreSQL card, 'Not judged' only the row's
# engine's groups; ok, warning and problem each among the demo's; demo-onprem-sql01 'has a problem: <its first critical
# reason>'; fx-unread 'pgvigil has not read fx-unread yet'; fx-stale 'needs a look' with its 1 late collection;
# fx-offline 'pgvigil has not read fx-offline for N minutes', N 35-60. 'verdict cards: ...; 0 FAIL'.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_verdict_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in chromium node psql go; do command -v $t >/dev/null || fail "$t is not on this machine"; done
for p in $PORT $CDP; do ss -ltnH "( sport = :$p )" | grep -q . && fail "port $p is in use: run again"; done

echo "== build and seed the demo into $DB, serve on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
"$WORK/pgvigil" demo -dsn "$DSN" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-240}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { cat "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in ${PGVIGIL_DEMO_WAIT_S:-240} s"; }
q() { psql "$DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }

echo "== the fixtures: fx-unread, fx-stale, fx-offline (PostgreSQL, no tag)"
q "insert into pgvigil.instances (name, platform, engine) values ('fx-unread', 'onprem', 'postgres'), ('fx-stale', 'onprem', 'postgres'), ('fx-offline', 'onprem', 'postgres')" >/dev/null
q "insert into pgvigil.collection_dates (instance_id, collection, snapshot_at, status)
   select instance_id, 'activity', now() - interval '4 hours', 'ok' from pgvigil.instances where name = 'fx-stale'
   union all select instance_id, 'dbstats', now(), 'ok' from pgvigil.instances where name = 'fx-stale'
   union all select instance_id, 'activity', now() - interval '40 minutes', 'ok' from pgvigil.instances where name = 'fx-offline'" >/dev/null

echo "== a headless Chromium on CDP $CDP"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"

echo "== the cards"
node scripts/verdict-check.mjs "$CDP" "http://127.0.0.1:$PORT/" | tee "$WORK/verdict.txt" || fail "a card did not hold (above)"
grep -q '^verdict cards: .*; 0 FAIL$' "$WORK/verdict.txt" || fail "verdict-check.mjs did not end with 0 FAIL"
echo "OK: the verdict cards"
