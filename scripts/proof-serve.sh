#!/usr/bin/env bash
# Proof of `pgvigil serve` against a repository that already holds collected data (run the other
# proofs first), connected as a login holding only pgvigil_reader: every endpoint answers with rows
# read from real data, bad parameters get 400, a foreign Host 421, the page loads, a POST is refused.
#   PGVIGIL_REPO_DSN  repository owner connection (creates and drops the reader login)
# Expected: health/instances/overview 200 with rows; activity at a snapshot with a lock waiter returns
# sessions and a blocking chain; statements, and counters of all four kinds, return rows for an
# instance that holds that data; dms answers (with tasks and one task's tables when proof-dms filled them); activity without instance = 400; dms with a bad instance = 400; Host evil.example = 421;
# POST = 405; GET / = 200 with the title.
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
pick() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }
# instances that hold each kind of data, and a snapshot with a lock waiter (proof-activity seeds one)
read -r AID AT < <(pick "select instance_id, to_char(snapshot_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')
                          from pgvigil.activity_summary where waiting_lock > 0 order by snapshot_at desc limit 1" | tr '|' ' ')
SID=$(pick "select instance_id from pgvigil.statements_delta order by snapshot_at desc limit 1")
DID=$(pick "select instance_id from pgvigil.dbstats group by instance_id having count(distinct snapshot_at) > 1 order by max(snapshot_at) desc limit 1")
VID=$(pick "select instance_id from pgvigil.serverstats group by instance_id having count(*) > 1 order by max(snapshot_at) desc limit 1")
IID=$(pick "select instance_id from pgvigil.iostats group by instance_id having count(distinct snapshot_at) > 1 order by max(snapshot_at) desc limit 1")
NID=$(pick "select instance_id from pgvigil.activity_summary group by instance_id having count(*) > 1 order by max(snapshot_at) desc limit 1")
for v in AID AT SID DID VID IID NID; do [[ -n "${!v}" ]] || fail "no data for $v: run the other proofs first"; done
# DMS data is optional (proof-dms.sh fills it): checked when an instance holds a task with table statistics
read -r MID MARN < <(pick "select t.instance_id, t.task_arn from pgvigil.dms_tasks t where exists (select 1 from pgvigil.dms_table_stats s where s.instance_id = t.instance_id and s.task_arn = t.task_arn) order by t.snapshot_at desc limit 1" | tr '|' ' ')

LOG=$(mktemp); "$BIN" serve -config "$CFG" -dsn env:READ_DSN -listen "127.0.0.1:$PORT" -no-login >"$LOG" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || fail "serve exited: $(cat "$LOG")"
U="http://127.0.0.1:$PORT"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
FROM=$(date -u -d '-30 days' +%Y-%m-%dT%H:%M:%SZ)
rows() {  # rows <path> <jq-like python expression giving a count> <min>
  local body; body=$(curl -s -w '\n%{http_code}' "$U/api/$1" || true)
  [[ "${body##*$'\n'}" == 200 ]] || fail "/api/$1 as the reader: ${body}"
  local n; n=$(printf '%s' "${body%$'\n'*}" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)")
  (( n >= $3 )) || fail "/api/$1 returned $n rows, want at least $3"
  echo "ok /api/$1: $n"
}
rows health 'len(d["rows"])' 1
rows instances 'len(d["rows"])' 1
rows overview 'len(d["rows"])' 0
curl -s "$U/api/overview" | grep -q 'check could not run' && fail "an overview check could not run: $(curl -s "$U/api/overview" | grep -o 'check could not run[^]]*' | head -3)"
rows "activity?instance=$AID&at=$AT" 'len(d["sessions"]["rows"])' 2
rows "activity?instance=$AID&at=$AT" 'len(d["chains"]["rows"])' 1
rows "statements?instance=$SID&from=$FROM" 'len(d["rows"])' 1
rows "counters?instance=$DID&kind=db&from=$FROM" 'len(d["rows"])' 1
rows "counters?instance=$VID&kind=server&from=$FROM" 'len(d["rows"])' 1
rows "counters?instance=$IID&kind=io&from=$FROM" 'len(d["rows"])' 1
rows "counters?instance=$NID&kind=sessions&from=$FROM" 'len(d["rows"])' 2
rows dms 'len(d["tasks"]["rows"]) + len(d["instances"]["rows"])' 0
if [[ -n "${MID:-}" ]]; then
  rows "dms?instance=$MID" 'len(d["tasks"]["rows"])' 1
  rows "dms?instance=$MID&task=$MARN" 'len(d["tables"]["rows"])' 1
else echo "dms: no task data in this repository (proof-dms.sh fills it): the endpoint answered empty"; fi
[[ $(code "$U/api/dms?instance=x") == 400 ]] || fail "dms with a bad instance was not 400"
[[ $(code -H 'Host: evil.example' "$U/api/instances") == 421 ]] || fail "a foreign Host was answered"
[[ $(code "$U/api/activity") == 400 ]] || fail "activity without instance was not 400"
[[ $(code -X POST "$U/api/instances") == 405 ]] || fail "POST was not refused"
curl -s "$U/api/session" | grep -q '"login":false' || fail "/api/session did not say the login is off"
curl -s "$U/" | grep -q '<title>pgvigil</title>' || fail "the shell page did not load"
[[ $(code "$U/app.js") == 200 ]] || fail "app.js did not load"
echo "OK: serve answers every endpoint as a pgvigil_reader login"
