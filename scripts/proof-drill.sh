#!/usr/bin/env bash
# Proof of the drill-down pages (task 48, migration 0047): the demo fleet is seeded into a throwaway database, then
#   A. every read function answers for every demo object: each database of each instance, each table the tables
#      collection holds, each job, each index the indexes collection holds.
#   B. the API (/api/drill/db, table, job, index) answers 200 for each of them and 400 for a bad parameter, through
#      `pgvigil serve` (needs the routes: the lead's join; before it "NOT PROVEN (B)", or PGVIGIL_BIN = a wired build).
#   C. a render check: a headless Chromium opens a database, a table, a job and an index page of two instances with
#      the range w=7d; each page draws its heading and its breadcrumb, whose links keep w=7d (needs the routes and the
#      bundle wired, and chromium and node; else "NOT PROVEN (C)").
#
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a login that may create a database (the throwaway one).
#
# Expected (written before the first run):
#  A. for every present non-template database of the 12 demo instances: dbinfo(i) filtered to it has 1 row and
#     drill_db_series has at least 2 points over 2 days; drill_db_tables lists the tables collection's present rows of
#     that database (the same count); drill_db_acl has at least one 'database' row where the roles collection read it.
#     For every present table: drill_table 1 row, drill_table_series at least 2 points. table_checks' 4 demo rows each
#     come back through drill_table_checks of their table. Every job of job_report: drill_job 1 row; the jobs with a
#     failure in 7 days have at least one drill_job_runs row with failed true. Every present index_state row:
#     drill_index returns its problem, with drop_sql and undo_sql set. At least one table has a statement naming it.
#     [review fold, expected before the rerun: every present row whose problem is not 'unused' carries its finding text
#      (index_findings joined by name); an unused one may not (the finding waits for 10 MB and 7 days)]
#     No function raises.
#  B. every URL of A: 200; db=0, rel=x, idx missing, scheduler 'Bad!': 400 with the parameter's name in the error.
#  C. the four pages of an on-prem and an RDS instance: the h2 starts with Database / Table / Job / Index, the breadcrumb
#     nav holds the instance link, and for table and index pages a database link; every breadcrumb href carries w=7d.
#     [review fold, expected before the rerun: the job page's breadcrumb reads "<instance> > Jobs > <job>"; on the first
#      table page the range picker set to 24h leaves the page on the same table (the hash keeps db= and rel=, w=24h)]
#  The last line says PASS only when A, B and C all ran; otherwise "PASS (A only; B, C not proven)".
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
BIN=${PGVIGIL_BIN:-}
WORK=$(mktemp -d); DB="pgvigil_drill_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
if [[ -z "$BIN" ]]; then CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil; BIN="$WORK/pgvigil"; fi
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
q() { psql "$DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
echo "== seed the demo (2 days) and serve it on 127.0.0.1:$PORT"
"$BIN" demo -dsn "$DSN" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 240); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { cat "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in 240 s"; }

echo "--- A. the read functions over every demo object"
W="now() - interval '2 days 1 hour', now()"
bad=$(q "
WITH d AS (SELECT d.instance_id, d.dbid, d.datname FROM pgvigil.databases d JOIN pgvigil.instances i USING (instance_id)
            WHERE i.is_active AND d.is_present AND NOT coalesce(d.is_template, false))
SELECT d.instance_id || ':' || d.datname || ' ' || x.what FROM d CROSS JOIN LATERAL (
  SELECT 'facts' AS what WHERE (SELECT count(*) FROM pgvigil.dbinfo(d.instance_id) f WHERE f.dbid = d.dbid) <> 1
  UNION ALL SELECT 'series' WHERE (SELECT count(*) FROM pgvigil.drill_db_series(d.instance_id, d.dbid, $W, 3600)) < 2
  UNION ALL SELECT 'tables' WHERE (SELECT count(*) FROM pgvigil.drill_db_tables(d.instance_id, d.dbid))
                                  <> (SELECT count(*) FROM pgvigil.tables t WHERE t.instance_id = d.instance_id AND t.dbid = d.dbid AND t.is_present)
  UNION ALL SELECT 'acl' WHERE EXISTS (SELECT 1 FROM pgvigil.acl_databases a WHERE a.instance_id = d.instance_id AND a.datname = d.datname AND a.is_present)
                           AND NOT EXISTS (SELECT 1 FROM pgvigil.drill_db_acl(d.instance_id, d.dbid) WHERE level = 'database')
  UNION ALL SELECT 'calls' WHERE (SELECT count(*) FROM pgvigil.drill_db_extensions(d.instance_id, d.dbid)) < 0
                              OR (SELECT count(*) FROM pgvigil.drill_db_jobs(d.instance_id, d.dbid)) < 0
                              OR (SELECT count(*) FROM pgvigil.drill_db_slow(d.instance_id, d.dbid, $W, 20)) < 0
                              OR (SELECT count(*) FROM pgvigil.drill_statements(d.instance_id, d.dbid, $W, 20)) < 0) x")
[[ -z "$bad" ]] || fail "A: databases: $bad"
echo "  databases: $(q "select count(*) from pgvigil.databases d join pgvigil.instances i using (instance_id) where i.is_active and d.is_present and not coalesce(d.is_template, false)") OK"
bad=$(q "
SELECT t.instance_id || ':' || t.datname || '.' || t.table_name || ' ' || x.what FROM pgvigil.tables t JOIN pgvigil.instances i USING (instance_id)
 CROSS JOIN LATERAL (
  SELECT 'row' AS what WHERE (SELECT count(*) FROM pgvigil.drill_table(t.instance_id, t.dbid, t.relid)) <> 1
  UNION ALL SELECT 'series' WHERE (SELECT count(*) FROM pgvigil.drill_table_series(t.instance_id, t.dbid, t.relid, $W, 3600)) < 2
  UNION ALL SELECT 'calls' WHERE (SELECT count(*) FROM pgvigil.drill_table_vacuum(t.instance_id, t.dbid, t.relid, $W)) < 0
                              OR (SELECT count(*) FROM pgvigil.drill_table_indexes(t.instance_id, t.dbid, t.relid)) < 0
                              OR (SELECT count(*) FROM pgvigil.drill_table_statements(t.instance_id, t.dbid, t.relid, $W, 20)) < 0) x
 WHERE i.is_active AND t.is_present")
[[ -z "$bad" ]] || fail "A: tables: $bad"
echo "  tables: $(q "select count(*) from pgvigil.tables t join pgvigil.instances i using (instance_id) where i.is_active and t.is_present") OK"
bad=$(q "
SELECT c.instance_id || ':' || c.object || ' ' || c.check_name FROM pgvigil.table_checks c
 WHERE NOT EXISTS (SELECT 1 FROM pgvigil.tables t CROSS JOIN LATERAL pgvigil.drill_table_checks(t.instance_id, t.dbid, t.relid) k
                    WHERE t.instance_id = c.instance_id AND t.is_present AND t.datname || '.' || t.schema_name || '.' || t.table_name = c.object
                      AND k.check_name = c.check_name)")
[[ -z "$bad" ]] || fail "A: table checks not on their table page: $bad"
echo "  table checks: $(q "select count(*) from pgvigil.table_checks") on their tables OK"
bad=$(q "
SELECT j.instance_id || ':' || j.scheduler || ':' || j.job_id || ' ' || x.what FROM pgvigil.job_report j CROSS JOIN LATERAL (
  SELECT 'row' AS what WHERE (SELECT count(*) FROM pgvigil.drill_job(j.instance_id, j.scheduler, j.job_id)) <> 1
  UNION ALL SELECT 'failed run' WHERE j.failures_7d > 0
     AND NOT EXISTS (SELECT 1 FROM pgvigil.drill_job_runs(j.instance_id, j.scheduler, j.job_id, now() - interval '7 days', now()) WHERE failed)) x")
[[ -z "$bad" ]] || fail "A: jobs: $bad"
echo "  jobs: $(q "select count(*) from pgvigil.job_report") ($(q "select count(*) from pgvigil.job_report where failures_7d > 0") with failures) OK"
bad=$(q "
SELECT s.instance_id || ':' || s.datname || '.' || coalesce(s.index_name, '?') || ' ' || s.problem FROM pgvigil.index_state s
 WHERE s.is_present AND NOT EXISTS (SELECT 1 FROM pgvigil.drill_index(s.instance_id, s.dbid, s.indexrelid) x
                                     WHERE x.problem = s.problem AND x.drop_sql IS NOT NULL AND x.undo_sql IS NOT NULL)")
[[ -z "$bad" ]] || fail "A: indexes: $bad"
[[ "$(q "select count(*) > 0 from pgvigil.index_state where is_present")" = t ]] || fail "A: the demo has no index_state row"
bad=$(q "
SELECT s.instance_id || ':' || s.datname || '.' || coalesce(s.index_name, '?') || ' ' || s.problem FROM pgvigil.index_state s
 WHERE s.is_present AND s.problem <> 'unused'
   AND NOT EXISTS (SELECT 1 FROM pgvigil.drill_index(s.instance_id, s.dbid, s.indexrelid) x WHERE x.problem = s.problem AND x.finding IS NOT NULL)")
[[ -z "$bad" ]] || fail "A: index pages without their finding: $bad"
echo "  indexes: $(q "select count(*) from pgvigil.index_state where is_present") OK"
[[ "$(q "select count(*) > 0 from pgvigil.tables t, lateral pgvigil.drill_table_statements(t.instance_id, t.dbid, t.relid, $W, 20) s where t.is_present")" = t ]] \
  || fail "A: no table has a statement naming it"
echo "A: OK"

echo "--- B. the API"
U="http://127.0.0.1:$PORT/api"
code() { curl -s -o "$WORK/body" -w '%{http_code}' "$1"; }
if [[ "$(code "$U/drill/db?instance=1&db=1")" = 404 ]] && grep -q 'no such endpoint' "$WORK/body"; then
  echo "NOT PROVEN (B): this binary has no /api/drill routes yet (the lead wires them at the join)"
  B_DONE=0
else
  R="w=7d"; n=0
  while IFS='|' read -r kind a b c; do
    case $kind in
      db) url="$U/drill/db?instance=$a&db=$b" ;;
      table) url="$U/drill/table?instance=$a&db=$b&rel=$c" ;;
      job) url="$U/drill/job?instance=$a&scheduler=$b&job=$c" ;;
      index) url="$U/drill/index?instance=$a&db=$b&idx=$c" ;;
    esac
    [[ "$(code "$url")" = 200 ]] || fail "B: $url: $(head -c 300 "$WORK/body")"
    n=$((n + 1))
  done < <(q "
    SELECT 'db|' || d.instance_id || '|' || d.dbid || '|' FROM pgvigil.databases d JOIN pgvigil.instances i USING (instance_id) WHERE i.is_active AND d.is_present
    UNION ALL SELECT 'table|' || instance_id || '|' || dbid || '|' || relid FROM pgvigil.tables WHERE is_present
    UNION ALL SELECT 'job|' || instance_id || '|' || scheduler || '|' || job_id FROM pgvigil.job_report
    UNION ALL SELECT 'index|' || instance_id || '|' || dbid || '|' || indexrelid FROM pgvigil.index_state WHERE is_present")
  echo "  $n URLs answered 200"
  for t in "drill/db?instance=1&db=0|db must be" "drill/table?instance=1&db=1&rel=x|rel must be" "drill/index?instance=1&db=1|idx must be" \
           "drill/job?instance=1&scheduler=Bad!&job=1|scheduler must be" "drill/job?instance=1&scheduler=pg_cron&job=x|job must be" "drill/db?db=1|instance must be"; do
    [[ "$(code "$U/${t%%|*}")" = 400 ]] && grep -q "${t##*|}" "$WORK/body" || fail "B: ${t%%|*} not refused with '${t##*|}': $(cat "$WORK/body")"
  done
  echo "B: OK"
  B_DONE=1
fi

echo "--- C. a render check"
if [[ "$B_DONE" != 1 ]]; then
  echo "NOT PROVEN (C): no routes in this binary"
elif ! command -v chromium >/dev/null || ! command -v node >/dev/null; then
  echo "NOT PROVEN (C): chromium or node is not on this machine"
else
  pages=$(q "
    WITH inst AS (SELECT DISTINCT ON (platform) instance_id FROM pgvigil.instances WHERE is_active AND platform IN ('onprem', 'rds') ORDER BY platform, instance_id)
    SELECT '#/db?i=' || d.instance_id || '&w=7d&db=' || d.dbid || '|Database' FROM inst
      CROSS JOIN LATERAL (SELECT * FROM pgvigil.databases d WHERE d.instance_id = inst.instance_id AND d.is_present AND NOT d.is_template ORDER BY size_bytes DESC LIMIT 1) d
    UNION ALL
    SELECT '#/table?i=' || t.instance_id || '&w=7d&db=' || t.dbid || '&rel=' || t.relid || '|Table' FROM inst
      CROSS JOIN LATERAL (SELECT * FROM pgvigil.tables t WHERE t.instance_id = inst.instance_id AND t.is_present ORDER BY total_bytes DESC LIMIT 1) t
    UNION ALL
    SELECT '#/job?i=' || j.instance_id || '&w=7d&scheduler=' || j.scheduler || '&job=' || j.job_id || '|Job'
      FROM (SELECT * FROM pgvigil.job_report ORDER BY failures_7d DESC, instance_id LIMIT 2) j
    UNION ALL
    SELECT '#/index?i=' || s.instance_id || '&w=7d&db=' || s.dbid || '&idx=' || s.indexrelid || '|Index'
      FROM (SELECT * FROM pgvigil.index_state WHERE is_present ORDER BY instance_id, indexrelid LIMIT 2) s")
  chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
  CHR=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
  cat > "$WORK/render.mjs" <<'JS'
const [port, U, list] = process.argv.slice(2);
const tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => (await cmd('Runtime.evaluate', { expression: e, returnByValue: true })).result?.result?.value;
const sleep = ms => new Promise(r => setTimeout(r, ms));
await cmd('Page.enable'); await cmd('Runtime.enable');
let failed = 0, rangeDone = false;
for (const line of list.trim().split('\n')) {
  const [hash, want] = line.split('|');
  await cmd('Page.navigate', { url: U + hash });
  let got = null;
  for (let t = 0; t < 80 && !got; t++) {
    await sleep(150);
    got = await ev(`(() => { const h = document.querySelector('main h2'); if (!h) return null; const nav = document.querySelector('main nav');
      return JSON.stringify({ h2: h.textContent, text: nav ? nav.textContent : '', crumbs: nav ? [...nav.querySelectorAll('a')].map(a => [a.textContent, a.getAttribute('href')]) : null,
                              err: document.querySelector('main .error')?.textContent ?? null }); })()`);
  }
  const r = got ? JSON.parse(got) : null;
  const okH = r && r.h2.startsWith(want);
  const okNav = r && r.crumbs && r.crumbs.length >= (want === 'Table' || want === 'Index' ? 2 : 1) && r.crumbs.every(([, h]) => /[?&]w=7d(&|$)/.test(h))
    && !/>\s*>/.test(r.text) && (want !== 'Job' || / > Jobs > \S/.test(r.text));
  if (!okH || !okNav) failed++;
  console.log(`${okH && okNav ? 'ok  ' : 'FAIL'} ${hash}: ${r ? r.h2 : 'no h2'} | ${r ? r.text : 'no breadcrumb'}`);
  if (want === 'Table' && !rangeDone) {
    rangeDone = true;
    await ev(`(() => { const s = document.querySelector('#bar select'); s.value = '24h'; s.dispatchEvent(new Event('change')); return 1; })()`);
    let after = null;
    for (let t = 0; t < 80; t++) {
      await sleep(150);
      after = await ev(`JSON.stringify({ hash: location.hash, h2: document.querySelector('main h2')?.textContent ?? '' })`);
      const a = JSON.parse(after);
      if (/w=24h/.test(a.hash) && a.h2.startsWith('Table')) break;
    }
    const a = JSON.parse(after);
    const ok = /w=24h/.test(a.hash) && /[?&]db=\d+/.test(a.hash) && /[?&]rel=\d+/.test(a.hash) && a.h2 === r.h2;
    if (!ok) failed++;
    console.log(`${ok ? 'ok  ' : 'FAIL'} range 24h on ${hash}: ${a.hash} | ${a.h2}`);
  }
}
ws.close();
process.exit(failed ? 1 : 0);
JS
  node "$WORK/render.mjs" "$CDP" "http://127.0.0.1:$PORT/" "$pages" || fail "C: a page did not render as expected"
  echo "C: OK"
  C_DONE=1
fi
if [[ "${C_DONE:-0}" = 1 ]]; then echo "proof-drill: PASS"; else echo "proof-drill: PASS (A only; B, C not proven)"; fi
