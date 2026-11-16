#!/usr/bin/env bash
# Proof of the demo's running plans (task 406: a running query's plan on Running queries): the demo (12
# PostgreSQL and 3 SQL Server instances, one day) in a scratch database, served on loopback, with a headless Chromium.
# Needs go, node, chromium, psql, curl, python3 and a superuser connection without dbname.
#   PGVIGIL_ADMIN_DSN     the superuser connection (creates and drops the scratch database)
#   PGVIGIL_DEMO_WAIT_S   how long the demo may take to seed and serve (default 300)
# Expected (written before the first run):
#  S. the seed, read in the repository:
#     S1 sql01 and sql03: every request of the newest mssql_requests snapshot that carries a plan hash has its
#        mssql_running_plan row (the same query hash, plan hash and offsets) with plan_state 'read', a plan that is a
#        ShowPlanXML document whose StmtSimple QueryHash / QueryPlanHash are the request's, and a plan_note that says
#        demo data; sql02 likewise when its newest snapshot holds a request; no PostgreSQL instance has a row;
#     S2 GET /api/collectiondates?instance=<each demo SQL Server>: mssql_running_plans with interval_secs 60 and status
#        ok (the demo turns it on, as an admin's schedules: line would); no PostgreSQL instance lists it;
#     S3 GET /api/mssql/runningplans/plan for sql01's report: state ok, the words name demo data, the plan parses as XML.
#  C. the clicks (scripts/click-running-plan.mjs): on #/mssql_running?i=<sql01> and ?i=<sql03> (each instance's Running
#     queries; the root's #/running row opens it) a Plan button stands in the request grid; clicked, the plan sources
#     list a 'running' row with Open; Open draws the plan: a 'Query plan:' dialog holding 'Statement 1' and an operator
#     grid of 1+ rows, the status line naming demo data, no error box. On #/activity?i=<erp01> (PostgreSQL's Running
#     queries) the page says 'PostgreSQL keeps no plan of a running statement'.
#  [review fold (drpa-fallback), before the rerun: S1: a request with a kept row holds it as above; a request without
#  one must be below DBA Dash's plan threshold in that snapshot (CPU 1,000 ms, a 6,400-page grant, 10 s running; a row
#  kept at an earlier snapshot stays); sql01 and sql03 each show one request with its kept plan; S3's plan carries
#  the '<!-- demo data' comment inside its root (a downloaded file says it too); C reads 'demo data' INSIDE the plan
#  dialog (its first line, the reply's words), not the status line behind it; a page slower than 15 s fails by name]
#  Red on 24c1b7c7 (rel-j15-fix): S1 no row; S2 interval_secs 0 or no row; S3 404; C no 'running' source (the sources
#  answer 'pgvigil holds no plan of these hashes'), and the PostgreSQL words absent.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_drp_$RANDOM"; PORT=""; CDP=""; SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in chromium node psql curl python3 go ss; do command -v $t >/dev/null || fail "$t is not on this machine"; done
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
ERP=$(q "select instance_id from pgvigil.instances where name = 'demo-onprem-erp01'")
SQL1=$(q "select instance_id from pgvigil.instances where name = 'demo-onprem-sql01'")
SQL3=$(q "select instance_id from pgvigil.instances where engine = 'sqlserver' and name like '%-sql03'")
MSALL=$(q "select string_agg(instance_id::text, ',' order by instance_id) from pgvigil.instances where engine = 'sqlserver'")
[[ -n "$ERP" && -n "$SQL1" && -n "$SQL3" ]] || fail "the demo's erp01, sql01 or sql03 is missing"

echo "== S. the seed"
FAILED=0
# S1: per SQL Server instance, the newest snapshot's requests with a plan hash, and whether each has its kept plan
S1=$(q "
WITH newest AS (
  SELECT s.instance_id, max(s.snapshot_at) AS at FROM pgvigil.mssql_requests_summary s
   WHERE s.instance_id IN ($MSALL) GROUP BY s.instance_id),
req AS (
  SELECT r.instance_id, r.session_id, r.query_hash AS qh, r.query_plan_hash AS ph, r.stmt_start, r.stmt_end,
         coalesce(r.cpu_ms, 0) >= 1000 OR coalesce(r.granted_memory_kb, 0) / 8 >= 6400 OR coalesce(r.elapsed_ms, 0) >= 10000 AS meets
    FROM pgvigil.mssql_requests_v r JOIN newest n ON n.instance_id = r.instance_id AND n.at = r.snapshot_at
   WHERE r.query_plan_hash IS NOT NULL AND r.query_plan_hash !~* '^0x0+\$')
SELECT i.name || ':' || q.session_id || ':' ||
       CASE WHEN p.instance_id IS NULL THEN CASE WHEN q.meets THEN 'NO ROW over the threshold' ELSE 'no row, below the threshold' END ELSE
       coalesce(p.plan_state, 'no state') || ':' ||
       CASE WHEN p.plan_xml IS NULL THEN 'no plan'
            WHEN p.plan_xml LIKE '<ShowPlanXML%' AND strpos(p.plan_xml, 'QueryHash=\"' || q.qh || '\"') > 0
                 AND strpos(p.plan_xml, 'QueryPlanHash=\"' || q.ph || '\"') > 0 THEN 'hashes match'
            ELSE 'hashes differ' END || ':' ||
       CASE WHEN p.plan_note ILIKE '%demo data%' THEN 'demo note' ELSE 'no demo note' END END
  FROM req q JOIN pgvigil.instances i USING (instance_id)
  LEFT JOIN pgvigil.mssql_running_plan p ON p.instance_id = q.instance_id AND p.query_hash = q.qh AND p.plan_hash = q.ph
                                        AND p.stmt_start = q.stmt_start AND p.stmt_end = q.stmt_end
 ORDER BY 1")
echo "$S1" | sed 's/^/     S1 /'
for inst in sql01 sql03; do echo "$S1" | grep -q -- "-$inst:" || { echo "DIFF S1: $inst's newest snapshot holds no request with a plan hash"; FAILED=1; }; done
for inst in sql01 sql03; do echo "$S1" | grep -E -- "-$inst:" | grep -q ':read:hashes match:demo note$' || { echo "DIFF S1: no request of $inst's newest snapshot with its kept plan"; FAILED=1; }; done
if echo "$S1" | grep -v -E ':(read:hashes match:demo note|no row, below the threshold)$' | grep -q .; then echo "DIFF S1: a request without its kept plan (above)"; FAILED=1; fi
PGROWS=$(q "select count(*) from pgvigil.mssql_running_plan p join pgvigil.instances i using (instance_id) where i.engine <> 'sqlserver'")
[[ "$PGROWS" == 0 ]] || { echo "DIFF S1: $PGROWS running plan row(s) on a PostgreSQL instance"; FAILED=1; }
[[ $FAILED == 0 ]] && ok "S1: every request of sql01's and sql03's newest snapshot (and sql02's, if any) has its kept plan, hashes matching, said as demo data"

S2FAIL=0
for id in ${MSALL//,/ }; do
  curl -fsS "$U/api/collectiondates?instance=$id" > "$WORK/cd-$id.json" || { echo "DIFF S2: collectiondates $id"; S2FAIL=1; continue; }
  python3 - "$WORK/cd-$id.json" "$id" <<'PY' || S2FAIL=1
import json, sys
d = json.load(open(sys.argv[1])); t = d['collections']
rows = [dict(zip(t['columns'], r)) for r in (t['rows'] or [])]
m = [r for r in rows if r['collection'] == 'mssql_running_plans']
if not m: print(f"DIFF S2 instance {sys.argv[2]}: no mssql_running_plans row"); sys.exit(1)
r = m[0]
if r.get('interval_secs') != 60 or r.get('status') != 'ok': print(f"DIFF S2 instance {sys.argv[2]}: interval_secs {r.get('interval_secs')} status {r.get('status')}"); sys.exit(1)
print(f"     S2 {r['instance']}: mssql_running_plans every {r['interval_secs']} s, {r['status']}")
PY
done
curl -fsS "$U/api/collectiondates?instance=$ERP" > "$WORK/cd-erp.json" || fail "S2: collectiondates erp01"
python3 -c "
import json,sys; t=json.load(open('$WORK/cd-erp.json'))['collections']
sys.exit(1 if any(r[t['columns'].index('collection')] == 'mssql_running_plans' for r in (t['rows'] or [])) else 0)" || { echo "DIFF S2: erp01 lists mssql_running_plans"; S2FAIL=1; }
[[ $S2FAIL == 0 ]] && ok "S2: mssql_running_plans on every 60 s for each demo SQL Server, absent on PostgreSQL" || FAILED=1

read -r QH PH ST EN <<<"$(q "select query_hash, query_plan_hash, stmt_start, stmt_end from pgvigil.mssql_requests_v
  where instance_id = $SQL1 and session_id = 63 and query_plan_hash is not null order by snapshot_at desc limit 1" | tr '|' ' ')"
if [[ -z "${QH:-}" ]]; then echo "DIFF S3: sql01 has no report request"; FAILED=1; else
  code=$(curl -sS -o "$WORK/s3.json" -w '%{http_code}' "$U/api/mssql/runningplans/plan?instance=$SQL1&qh=$QH&ph=$PH&start=$ST&end=$EN")
  python3 - "$WORK/s3.json" "$code" <<'PY' && ok "S3: sql01's report plan served, said as demo data" || FAILED=1
import json, sys
import xml.etree.ElementTree as ET
code = sys.argv[2]
if code != '200': print(f"DIFF S3: HTTP {code} {open(sys.argv[1]).read()[:200]}"); sys.exit(1)
d = json.load(open(sys.argv[1]))
if d.get('state') != 'ok' or 'demo data' not in (d.get('words') or ''): print(f"DIFF S3: state {d.get('state')} words {d.get('words')!r}"); sys.exit(1)
ET.fromstring(d['plan'])
root = d['plan'].find('<ShowPlanXML'); end = d['plan'].find('>', root)
if not d['plan'][end + 1:].startswith('<!-- demo data'): print(f"DIFF S3: the plan file carries no demo-data comment inside its root: {d['plan'][end + 1:end + 80]!r}"); sys.exit(1)
print(f"     S3 words: {d['words']}; file {d.get('file')}; {len(d['plan'])} bytes")
PY
fi

echo "== C. the clicks (headless Chromium on CDP $CDP)"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
node scripts/click-running-plan.mjs "$CDP" "$U/" "$SQL1,$SQL3" "$ERP" || FAILED=1

[[ $FAILED == 0 ]] || fail "see the DIFF lines above"
echo "PASS: proof-demo-running-plan"
