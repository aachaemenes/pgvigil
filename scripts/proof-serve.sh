#!/usr/bin/env bash
# Proof of `pgvigil serve` against a repository that already holds collected data, connected as a
# login holding only pgvigil_reader: every API endpoint answers 200 with JSON, bad parameters 400,
# the shell page and its script load, a POST is refused.
#   PGVIGIL_REPO_DSN  repository owner connection (creates and drops the reader login)
# Expected: health/instances/overview 200 with columns; activity/statements/counters (all four kinds)
# 200 for the first instance; activity without instance = 400; POST = 405; GET / = 200 with the title.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
R="pgvigil_it_serve_$RANDOM"; PW="pw$RANDOM$RANDOM"; PORT=$((20000 + RANDOM % 20000))
CFG=$(mktemp); SRVPID=""
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  rm -f "$CFG" "${LOG:-}"; psql "$PGVIGIL_REPO_DSN" -XAtq -c "drop role if exists $R" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
HOST=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select coalesce(host(inet_server_addr()),'localhost')")
DBPORT=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select inet_server_port()")
DB=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select current_database()")
psql "$PGVIGIL_REPO_DSN" -XAtq -c "create role $R login password '$PW' in role pgvigil_reader" >/dev/null
export READ_DSN="host=$HOST port=$DBPORT user=$R password=$PW dbname=$DB sslmode=disable"
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
ID=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select min(instance_id) from pgvigil.instances where is_active")
[[ -n "$ID" ]] || fail "the repository holds no instance: run a collection first"

LOG=$(mktemp); "$BIN" serve -config "$CFG" -dsn env:READ_DSN -listen "127.0.0.1:$PORT" >"$LOG" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || fail "serve exited: $(cat "$LOG")"
U="http://127.0.0.1:$PORT"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
FROM=$(date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ)
for p in health instances overview "activity?instance=$ID" "statements?instance=$ID&from=$FROM" \
         "counters?instance=$ID&kind=db&from=$FROM" "counters?instance=$ID&kind=server&from=$FROM" \
         "counters?instance=$ID&kind=io&from=$FROM" "counters?instance=$ID&kind=sessions&from=$FROM"; do
  body=$(curl -s -w '\n%{http_code}' "$U/api/$p" || true)
  [[ "${body##*$'\n'}" == 200 ]] || fail "/api/$p as the reader: ${body}"
  echo "ok /api/$p"
done
[[ $(code "$U/api/activity") == 400 ]] || fail "activity without instance was not 400"
[[ $(code -X POST "$U/api/instances") == 405 ]] || fail "POST was not refused"
curl -s "$U/" | grep -q '<title>pgvigil</title>' || fail "the shell page did not load"
[[ $(code "$U/app.js") == 200 ]] || fail "app.js did not load"
echo "OK: serve answers every endpoint as a pgvigil_reader login"
