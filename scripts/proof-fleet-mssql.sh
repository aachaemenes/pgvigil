#!/usr/bin/env bash
# Proof of the fleet's SQL Server backups and jobs (FLEET MSSQL BACKUPS-JOBS; DONE-1 Backups: internal/web/q_mssql_jobs.go
# MSSQLBackups, web/src/mssql_backups.ts mssqlBackupsFleetSection, backups.ts, pages.ts; main.ts's wiring as
# scripts/fleet-mssql-wiring.patch). A demo fleet of 2 days is seeded into a throwaway database and served on loopback;
# the API is read with curl against psql's hand counts, then a headless Chromium runs scripts/fleet-mssql-check.mjs.
# Needs go, psql, chromium, node, npm (web/node_modules installed), curl and python3, and a PostgreSQL for the database:
#   PGVIGIL_ADMIN_DSN   keyword-form connection to a cluster as a login that may create a database
#   PGVIGIL_DEMO_WAIT_S the seconds to wait for the seeded demo to serve (default 900)
# The wiring: a tree whose main.ts already names mssqlBackupsFleetSection is used as it is; a tree whose mssql_backups.ts
# exports it gets scripts/fleet-mssql-wiring.patch applied and the bundle built again for the run (both put back on
# exit); a tree without it (the base) runs unwired and its rows fail.
# Expected (written before the first run, 2026-11-14 05:5x PST; red on d263c82, whose /api/mssql/backups needs an
# instance and whose Backups page has no SQL Server section):
#   B1 api       GET /api/mssql/backups with no instance: 200; by_instance one row per ACTIVE SQL Server instance (the
#                demo's three: demo-azure-sql03, which the demo gives no backups, has its row with no read); each row's
#                counts (databases, full / diff / log ok, late, never, not judged, not judged at all, NUL) = psql's hand
#                count from mssql_backup_judged; databases = every judged row of the three; with problems=1 exactly the
#                rows with a backup late or never or a backup to NUL inside nul_backup_days (the hand count, the NUL
#                database set up below among them, nul_recent true); findings = mssql_jobs_findings' backup rows of the
#                active SQL Server instances (the hand count), the NUL database's 'a backup went to NUL' among them; the
#                tab's call (?instance=<sql01>) answers its databases as before (the hand count of sql01's rows)
#   B2 page      #/backups: the 'SQL Server backups' section AFTER 'Base backups (pgBackRest, barman)'; the instances
#                tile = every active instance in view, its sub line '<p> PostgreSQL, 3 SQL Server'; 'SQL Server backups
#                by instance' 3 rows, sql03's read cell 'mssql_backups has not run on this server yet'; the databases
#                filter on Problems (3 instances in view), its line '<problems> of <all> databases', its rows = the
#                problems hand count with the NUL database; All: every database; Configure is off (aria-disabled true)
#                with its reason naming pgvigil.yaml
#   B3 clicks    sql01's instance link = #/mssqlbackups?i=<sql01>; the NUL database's link carries db=<name>; opened, the
#                tab says 'Opened for the database <name>: its row is the first below.' and its first row is that database
#   B4 views     tag erp (PostgreSQL only): the SQL Server section says 'No SQL Server instance in this view.'; tag sales
#                (sql01, sql02): PostgreSQL's part says 'No PostgreSQL instance in this view.', the SQL Server grid 2 rows;
#                tag ledger (sql03 alone, one instance): the filter on All, one instance row that has not run, no database
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_fleetms_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""; UNWIRE=""
fail() { echo "FAIL: $*" >&2; exit 1; }
bad=0; no() { echo "FAIL: $*" >&2; bad=$((bad + 1)); }   # a row that failed: the next rows still run, the end exits 1
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  wait 2>/dev/null || true
  if [[ -n "$UNWIRE" ]]; then
    git apply -R scripts/fleet-mssql-wiring.patch 2>/dev/null || echo "the wiring patch did not come off main.ts: put it back by hand"
    cp "$WORK/app.js.kept" internal/web/dist/app.js 2>/dev/null || true
  fi
  timeout 300 psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 \
    || echo "the scratch database $DB: drop not confirmed in 300 s (psql exit $?)"
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in go chromium node npm psql curl python3; do command -v $t >/dev/null || fail "$t is not on this machine"; done
for p in $PORT $CDP; do ss -ltnH "( sport = :$p )" | grep -q . && fail "port $p is in use: run again"; done

if grep -q 'mssqlBackupsFleetSection' web/src/main.ts; then echo "wiring: main.ts wired in this tree"
elif grep -q 'export async function mssqlBackupsFleetSection' web/src/mssql_backups.ts; then
  cp internal/web/dist/app.js "$WORK/app.js.kept"
  git apply scripts/fleet-mssql-wiring.patch || fail "the wiring patch does not apply"
  UNWIRE=1
  (cd web && npm run build > "$WORK/build.txt" 2>&1) || { tail -30 "$WORK/build.txt"; fail "the wired bundle did not build"; }
  echo "wiring: scripts/fleet-mssql-wiring.patch applied for this run, bundle $(wc -c < internal/web/dist/app.js) bytes"
else echo "wiring: NOT applied (no mssqlBackupsFleetSection in this tree)"; fi

echo "== build and seed the demo (2 days) into $DB, serve on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
"$WORK/pgvigil" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-900}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { cat "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up"; }
BASE="http://127.0.0.1:$PORT/"
Q() { psql "$PGVIGIL_ADMIN_DSN dbname=$DB" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
S1=$(Q "select instance_id from pgvigil.instances where name = 'demo-onprem-sql01'"); S3=$(Q "select instance_id from pgvigil.instances where name = 'demo-azure-sql03'")
[[ -n "$S1" && -n "$S3" ]] || fail "the demo has no demo-onprem-sql01 or demo-azure-sql03"

# the NUL case (the pass's SF2): a judged database of sql01 with no backup late or missing gets a log backup to NUL a
# day before its read - its statuses stay as they were, so only the NUL rule can put it under Problems
NULDB=$(Q "select database_name from pgvigil.mssql_backup_judged where instance_id = $S1 and not_judged is null and full_status = 'ok'
            and diff_status in ('ok', 'not judged') and log_status in ('ok', 'not judged') and nul_at is null order by database_name limit 1")
[[ -n "$NULDB" ]] || fail "sql01 has no judged database with every backup in time"
Q "update pgvigil.mssql_backup_state set nul_at = snapshot_at - interval '1 day', nul_type = 'log' where instance_id = $S1 and database_name = '$NULDB'" >/dev/null
echo "the NUL case: sql01's $NULDB, a log backup to NUL a day before its read"

echo "== B1: the API with no instance"; b0=$bad
# the hand counts: every active SQL Server instance with its counts from mssql_backup_judged, the rows, the findings
HAND=$(Q "select json_build_object(
  'inst', (select json_object_agg(i.instance_id, json_build_object('name', i.name,
      'databases', (select count(*) from pgvigil.mssql_backup_judged b where b.instance_id = i.instance_id),
      'full', (select json_object_agg(s, n) from (select b.full_status s, count(*) n from pgvigil.mssql_backup_judged b where b.instance_id = i.instance_id group by 1) x),
      'diff', (select json_object_agg(s, n) from (select b.diff_status s, count(*) n from pgvigil.mssql_backup_judged b where b.instance_id = i.instance_id group by 1) x),
      'log', (select json_object_agg(s, n) from (select b.log_status s, count(*) n from pgvigil.mssql_backup_judged b where b.instance_id = i.instance_id group by 1) x),
      'not_judged', (select count(*) from pgvigil.mssql_backup_judged b where b.instance_id = i.instance_id and b.not_judged is not null)))
    from pgvigil.instances i where i.is_active and i.engine = 'sqlserver'),
  'all', (select count(*) from pgvigil.mssql_backup_judged b join pgvigil.instances i using (instance_id) where i.is_active and i.engine = 'sqlserver'),
  'problems', (select json_agg(b.instance_id || '|' || b.database_name order by 1) from pgvigil.mssql_backup_judged b join pgvigil.instances i using (instance_id)
                where i.is_active and i.engine = 'sqlserver' and ('late' in (b.full_status, b.diff_status, b.log_status) or 'never' in (b.full_status, b.diff_status, b.log_status)
                   or (b.not_judged is null and b.nul_backup_days > 0 and b.nul_at > b.snapshot_at - make_interval(days => b.nul_backup_days::int)))),
  'findings', (select count(*) from pgvigil.mssql_jobs_findings f join pgvigil.instances i using (instance_id)
                where i.is_active and f.check_name not in ('a job failed', 'a job runs far longer than its average')),
  's1', (select count(*) from pgvigil.mssql_backup_judged where instance_id = $S1))")
echo "$HAND" > "$WORK/hand.json"
c1=$(curl -s -o "$WORK/all.json" -w '%{http_code}' "${BASE}api/mssql/backups")
c2=$(curl -s -o "$WORK/problems.json" -w '%{http_code}' "${BASE}api/mssql/backups?problems=1")
c3=$(curl -s -o "$WORK/tab.json" -w '%{http_code}' "${BASE}api/mssql/backups?instance=$S1")
B1=$(python3 -I - "$WORK" "$S1" "$S3" "$NULDB" "$c1" "$c2" "$c3" <<'PY'
import json, sys
w, s1, s3, nul, c1, c2, c3 = sys.argv[1:]
hand = json.load(open(w + '/hand.json'))
rows = lambda d, p: [dict(zip(d[p]['columns'], r)) for r in (d.get(p) or {}).get('rows', [])] if isinstance(d.get(p), dict) else []
out = []
if (c1, c2, c3) != ('200', '200', '200'):
    print(f"FAIL|answers {c1} {c2} {c3}: {open(w + '/all.json').read()[:200]}"); sys.exit()
a, p, t = (json.load(open(w + f)) for f in ('/all.json', '/problems.json', '/tab.json'))
bi = {str(r['instance_id']): r for r in rows(a, 'by_instance')}
if set(bi) != set(hand['inst']): out.append(f"by_instance ids {sorted(bi)} vs active SQL Server {sorted(hand['inst'])}")
for i, h in hand['inst'].items():
    r = bi.get(i)
    if not r: continue
    if h['databases'] == 0:
        if r['databases'] is not None or r['snapshot_at'] is not None: out.append(f"{h['name']} has no backup rows but databases {r['databases']} read {r['snapshot_at']}")
        continue
    want = {'databases': h['databases'], 'not_judged': h['not_judged']}
    for k in ('full', 'diff', 'log'):
        for st, col in (('ok', 'ok'), ('late', 'late'), ('never', 'never'), ('not judged', 'not_judged')):
            want[f'{k}_{col}'] = (h[k] or {}).get(st, 0)
    got = {k: r[k] for k in want}
    if got != want: out.append(f"{h['name']}: {got} vs the hand count {want}")
if str(s3) not in bi or bi[str(s3)]['snapshot_at'] is not None: out.append("sql03 has no row with no read")
dbs, pdbs, fnd = rows(a, 'databases'), rows(p, 'databases'), rows(a, 'findings')
if len(dbs) != hand['all']: out.append(f"databases {len(dbs)} vs {hand['all']}")
keys = sorted(f"{r['instance_id']}|{r['database_name']}" for r in pdbs)
if keys != sorted(hand['problems'] or []): out.append(f"problems {keys} vs {hand['problems']}")
nr = [r for r in pdbs if str(r['instance_id']) == s1 and r['database_name'] == nul]
if not nr or nr[0]['nul_recent'] is not True or nr[0]['problem'] is not True: out.append(f"the NUL database {nul} under Problems: {nr}")
if len(fnd) != hand['findings']: out.append(f"findings {len(fnd)} vs {hand['findings']}")
if not any(f['check_name'] == 'a backup went to NUL' and f['object'] == nul and str(f['instance_id']) == s1 for f in fnd): out.append("no 'a backup went to NUL' finding for " + nul)
if len(rows(t, 'databases')) != hand['s1'] or not rows(t, 'limits'): out.append(f"the tab: {len(rows(t, 'databases'))} databases vs {hand['s1']}, limits {len(rows(t, 'limits'))}")
print(('FAIL|' + '; '.join(out)) if out else f"ok|{len(bi)} instances (sql03 unread), {len(dbs)} databases, {len(pdbs)} under Problems with {nul}, {len(fnd)} findings, the tab {hand['s1']} = the hand counts")
PY
)
[[ "$B1" == ok\|* ]] || no "B1: ${B1#FAIL|}"
[[ $bad -eq $b0 ]] && echo "ok   B1 api: ${B1#ok|}"
PROBLEMS=$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["problems"] or []))' "$WORK/hand.json")
ALL=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["all"])' "$WORK/hand.json")
INSTS=$(Q "select count(*) || '|' || count(*) filter (where engine = 'sqlserver') from pgvigil.instances where is_active")

echo "== a headless Chromium on CDP $CDP"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
set +e
FM_S1=$S1 FM_S3=$S3 FM_NULDB="$NULDB" FM_PROBLEMS=$PROBLEMS FM_ALL=$ALL FM_INSTS="$INSTS" node scripts/fleet-mssql-check.mjs "$CDP" "$BASE" | tee "$WORK/check.txt"
rc=${PIPESTATUS[0]}; set -e
if [[ $rc -ne 0 ]]; then
  last=$(tail -n 1 "$WORK/check.txt" 2>/dev/null || true)
  if [[ "$last" =~ ^FAIL\ [0-9]+\ case ]]; then no "fleet-mssql-check: exit $rc, '$last' (its FAIL rows are above)"
  else no "fleet-mssql-check: exit $rc and it STOPPED EARLY - its last line was '${last:0:160}'"; fi
fi
[[ $bad -eq 0 ]] || fail "$bad check(s) failed"
echo "OK: the fleet's SQL Server backups (B1-B4)"
