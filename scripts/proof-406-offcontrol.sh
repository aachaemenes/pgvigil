#!/usr/bin/env bash
# Proof of the 406 offControl row (the lead 11-15 16:3x; found by relw4-s1's B24f review): on the plan cache page's
# Cached plans grid and in a statement's plan sources, a plan read or an Evict that is off is DRAWN disabled with its
# reason in words beside it (the house rule B3), never replaced by the note. The demo (12 PostgreSQL and 3 SQL Server
# instances, one day) in a scratch database, served on loopback (no actions door, no read login), with a headless
# Chromium. Needs go, node, chromium, psql, curl and a superuser connection without dbname.
#   PGVIGIL_ADMIN_DSN     the superuser connection (creates and drops the scratch database)
#   PGVIGIL_DEMO_WAIT_S   how long the demo may take to seed and serve (default 300)
# The stage: two plan cache reads of demo-onprem-sql01 (pgvigil.import_mssql_plancache, the collector's own import, a
# minute apart) for the newest snapshot's first request that carries a plan hash: its query hash as the query key, its
# plan hash on the cache entry, one statement of one plan handle. The second read makes the interval's sample, so the
# Plan cache page lists the statement; the entry makes a 'plan cache' row in the request's plan sources.
# Expected (written before the first run):
#   O1 #/mssqlplancache?i=<sql01>: the staged statement's 'Cached plans' button lists its one entry; in that row the
#      buttons 'Download .sqlplan', 'Open', 'Download batch', 'Open batch' and 'Evict' are each present, aria-disabled
#      'true', and named (aria-describedby) by a note on the page whose words are not empty: the four plan reads by
#      the plan read's reason ('not read: ...', the demo has no read login), Evict by 'Evict is off for this instance: ...'
#      (the demo has no actions door); a click on an off button opens no dialog.
#   O2 #/mssql_running?i=<sql01>: the request's Plan button lists a 'plan cache' row whose 'Download .sqlplan' and 'Open'
#      are present, aria-disabled 'true', named by the note 'Plan cache: not read: ...'; the 'running' row's Open is on
#      (no aria-disabled), as before.
#   Red on 75c72186 (rel-j15): O1 and O2 find no off button where they belong (offControl's note stands in the cell; a
#   note shared by every row stays only in the last place it was put).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_offc_$RANDOM"; PORT=""; CDP=""; SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in chromium node psql curl go ss; do command -v $t >/dev/null || fail "$t is not on this machine"; done
for _ in $(seq 1 20); do p=$((21000 + RANDOM % 9000)); if ! ss -ltnH "( sport = :$p or sport = :$((p + 1)) )" | grep -q .; then PORT=$p; break; fi; done
[[ -n "$PORT" ]] || fail "no free port pair"; CDP=$((PORT + 1))

echo "== build the page and pgvigil, seed the demo into $DB and serve it on 127.0.0.1:$PORT"
(cd web && npm ci --no-audit --no-fund > "$WORK/npm.log" 2>&1 && npm run build >> "$WORK/npm.log" 2>&1) || { tail -20 "$WORK/npm.log"; fail "the page build"; }
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
"$WORK/pgvigil" demo -dsn "$DSN" -serve -listen "127.0.0.1:$PORT" -days 1 > "$WORK/demo.log" 2>&1 &
SRV=$!
T0=$SECONDS
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-300}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { tail -5 "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in ${PGVIGIL_DEMO_WAIT_S:-300} s"; }
echo "the demo served after $((SECONDS - T0)) s"
U="http://127.0.0.1:$PORT"
q() { psql "$DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
SQL1=$(q "select instance_id from pgvigil.instances where name = 'demo-onprem-sql01'")
[[ -n "$SQL1" ]] || fail "the demo's sql01 is missing"

echo "== the stage: two plan cache reads of sql01 for one request's hashes"
read -r QH PH DBN <<<"$(q "select r.query_hash, r.query_plan_hash, r.database_name from pgvigil.mssql_requests_v r
  where r.instance_id = $SQL1 and r.snapshot_at = (select max(snapshot_at) from pgvigil.mssql_requests_summary where instance_id = $SQL1)
    and r.query_hash ~* '^0x[0-9a-f]{1,16}\$' and r.query_plan_hash ~* '^0x[0-9a-f]{1,16}\$' and r.query_plan_hash !~* '^0x0+\$'
    and r.database_name is not null
  order by r.session_id limit 1" | tr '|' ' ')"
[[ -n "${QH:-}" && -n "${PH:-}" && -n "${DBN:-}" ]] || fail "sql01's newest snapshot holds no request with a query hash, a plan hash and a database"
# a 64-byte handle (128 hex digits); the server's start and the plan's compile time fixed once, so the second read is
# the first's delta (the same run, the same plan), not a restart or a new plan
HANDLE="0x06000500$(printf '%08x' $RANDOM)$(printf '0%.0s' $(seq 1 112))"
START=$(date -u -d '2 days ago' '+%Y-%m-%d %H:%M:%S+00'); CT=$(date -u -d '1 hour ago' '+%Y-%m-%d %H:%M:%S')
stage() {   # stage <seconds ago> <executions>
  q "select pgvigil.import_mssql_plancache($SQL1, now() - interval '$1 seconds', jsonb_build_array(
    jsonb_build_object('kind', 'state', 'server_utc', now() - interval '$1 seconds', 'server_start', '$START'::timestamptz,
                       'server_local', (now() at time zone 'UTC') - interval '$1 seconds', 'capped', false),
    jsonb_build_object('kind', 'text', 'query_key', '$QH', 'database_id', 5, 'query', 'SELECT 1 /* proof-406-offcontrol */'),
    jsonb_build_object('kind', 'stmt', 'plan_handle', '$HANDLE', 'stmt_start', 0, 'stmt_end', -1,
                       'creation_time', '$CT', 'database_id', 5, 'database_name', '$DBN',
                       'query_key', '$QH', 'execution_count', $2, 'worker_us', $2 * 1000, 'elapsed_us', $2 * 2000,
                       'logical_reads', $2 * 10, 'physical_reads', 0, 'logical_writes', 0, 'row_count', $2, 'spills', 0,
                       'sql_handle', '0x0200000011223344556677889900aabbccddeeff00112233', 'plan_hash_hex', '$PH',
                       'last_execution', (now() at time zone 'UTC') - interval '$1 seconds', 'last_elapsed_us', 2000)))" >/dev/null
}
stage 120 10
stage 60 25
N=$(q "select count(*) from pgvigil.mssql_pc_sample where instance_id = $SQL1 and query_key = '$QH'")
E=$(q "select count(*) from pgvigil.mssql_pc_handles where instance_id = $SQL1 and plan_hash = '$PH'")
[[ "$N" -ge 1 && "$E" -ge 1 ]] || fail "the stage made $N sample(s) and $E handle row(s)"
ok "stage: sql01 ($SQL1) query hash $QH, plan hash $PH in $DBN: $N sample, $E cache entry (handle ${HANDLE:0:18}...)"

echo "== O. the pages (headless Chromium on CDP $CDP)"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
node scripts/offcontrol-check.mjs "$CDP" "$U/" "$SQL1" "$QH" "$PH" || fail "see the FAIL lines above"
echo "PASS: proof-406-offcontrol"
