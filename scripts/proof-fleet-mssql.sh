#!/usr/bin/env bash
# Proof of the fleet's SQL Server backups and jobs (FLEET MSSQL BACKUPS-JOBS; DONE-1 Backups: internal/web/q_mssql_jobs.go
# MSSQLBackups, web/src/mssql_backups.ts mssqlBackupsFleetSection, backups.ts, pages.ts; main.ts's wiring as
# scripts/fleet-mssql-wiring.patch). A demo fleet of 2 days is seeded into a throwaway database and served on loopback;
# the API is read with curl against psql's hand counts, then a headless Chromium runs scripts/fleet-mssql-check.mjs.
# Needs go, psql, chromium, node, npm (web/node_modules installed), curl and python3, and a PostgreSQL for the database:
#   PGVIGIL_ADMIN_DSN   keyword-form connection to a cluster as a login that may create a database
#   PGVIGIL_DEMO_WAIT_S the seconds to wait for the seeded demo to serve (default 900)
# The wiring: a tree whose main.ts already names mssqlBackupsFleetSection (the join, or a copy a killed run left wired:
# either way the wired product) has its bundle built from its source for the run; a tree whose mssql_backups.ts exports
# it gets scripts/fleet-mssql-wiring.patch applied and the bundle built; both put back on exit (a patch that does not
# come off is a FAIL and exit 1); a tree without it (the base) runs unwired and its rows fail.
# The demo serve imports mssql_jobs every 5 minutes and that import replaces an instance's jobs: right after the seed,
# sql01's 'mssql_jobs' read is moved an hour ahead so the import refuses as older (0066 mssql_hadr_read), and the seeded
# rows are asked for again after the browser check (a FAIL there is the proof's, not the product's).
# Not proven here (said, not hidden): Acknowledge on a Job status row with acks on and off, the status part timing out
# alone with the PostgreSQL grid still drawn, a pg_cron job's click to #/job?; the Summary's other cells.
# Expected (written before the first run, 2026-11-14 05:5x PST; red on d263c82, whose /api/mssql/backups needs an
# instance and whose Backups page has no SQL Server section):
#   B1 api       GET /api/mssql/backups with no instance: 200; by_instance one row per ACTIVE SQL Server instance (the
#                demo's three: demo-azure-sql03, which the demo gives no backups, has its row with no read); each row's
#                counts (databases, full / diff / log ok, late, never, not judged, not judged at all, NUL) = psql's hand
#                count from mssql_backup_judged; databases = every judged row of the three; with problems=1 exactly the
#                databases a backup finding of mssql_jobs_findings names (the hand count reads the findings, not the
#                statuses: SF2's 'Problems = every row a finding names'; the NUL database set up below among them,
#                nul_recent true); findings = mssql_jobs_findings' backup rows of the
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
#   B4 views     tag erp (PostgreSQL only): no SQL Server section and no heading naming SQL Server (f8e89d2), the page's 'Backups'
#                heading drawn; tag sales
#                (sql01, sql02): PostgreSQL's part says 'No PostgreSQL instance in this view.' and draws no Base backups
#                or Standbys section (F1), the SQL Server grid 2 rows;
#                tag ledger (sql03 alone, one instance): the filter on All, one instance row that has not run, no database
# DONE-2 Jobs (written before the rows' first run, 2026-11-14 06:0x PST; red on d263c82: no 'status' / 'stats' part, the
# Summary's Agent Jobs cell judged by the finding 'a job failed', the PostgreSQL 'jobs' check one row per failed run):
#   S1 seed      the pass's case on both engines, made here: SQL Agent job 'fleet proof failed then succeeded' on sql01
#                and pg_cron job 'fleet-proof-failed-then-succeeded' on erp01, each failed 120 minutes ago and succeeded
#                60 minutes ago (no threshold row: DBA Dash's default)
#   J1 api       /api/jobsreport with no part name answers counts and jobs only; ?part=status = every active instance's
#                jobs - PARITY (not a hand count: the same function) row for row on all ten fields (status, reason,
#                level, last outcome, last failure / success as instants, the four counts) with the one-instance form
#                job_status(i) over every active instance, a reason's minute within one; the rows in DBA Dash's order
#                (the last run failed first, then the newest failure); ?part=status&ids=<sql01> exactly sql01's keys;
#                ?part=stats one row per status row's job; ?ids=abc 400. Both seeded jobs 'warn', level 'default', the
#                reason 'failed 120 (or 121) minute(s) ago (warning within 10080)'; HAND COUNTS from the raw run rows: the
#                seeded jobs' fail_24h, fail_7d (and the SQL Agent one's step_fail_7d) = 1, their stats ok_24h = ok_7d = 1,
#                max = the seeded duration (SQL Agent 5 s, pg_cron 60 s)
#   S1 cells     the Summary's Agent Jobs cell of sql01 (/api/mssql/summary, key jobs) counts that warning, its detail
#                names the job; the overview's 'jobs' group has a warning 'job status' row for erp01's pg_cron job; in the
#                browser the fleet Summary's sql01 Agent Jobs link (#/mssqljobs, i=<sql01>) lands on a page that names it
#   J2 page      #/jobs: 'Job status' above 'PostgreSQL schedule checks'; the filter on 'Critical, warning and
#                acknowledged' (more than one instance in view), its line '<crit + warn + acknowledged> of <all> jobs'
#                (parity with job_status(i); no live job acknowledgement on a fresh demo), the two seeded rows there;
#                All = every job (a raw count of the jobs tables), in the API's order
#   R0 hours     (FLEET STATS ROLLUP, 0139) the demo's job imports and the seeds filled job_stats_hourly through its triggers
#                (the collector's SECURITY DEFINER import path): SQL Server hour rows, the seeded pg_cron job's two hours,
#                no 'rollup failed' row in collection_log, no dirty range; J1 also compares DBA Dash's whole-second average
#                (per UTC hour total / (failed + succeeded), then their average) counted from the runs
#   J3 stats     4 s after the grid: the 'succeeded 7 days' column there, every cell a number, both seeded jobs' '1'
#   J4 history   a click on the SQL Agent seeded job's name opens '<instance> | <job>' under the grid with its runs (2); its
#                'Open the job on its instance' link is #/mssqljobs?i=<sql01>&job=<name> and lands with that job's history open (SF4)
#   (B9b, expected written before any run, amended by the build review's fold;
#   red on rel-b9's base 00e7b96, which has none of it). The S1 seed adds for B9b: the SQL Agent seeded job runs now
#   (its mssql_jobs row's running_since 5 minutes ago), and on erp01 the pg_cron job RJ 'fleet-proof-two-of-three-failed'
#   (failed 200 and 180 minutes ago, succeeded 170 minutes ago) and NJ 'fleet-proof-no-run' (no run at all).
#   J8 cards     sql01's tab on a FIXED range of whole hours (to = an hour before the current hour, from 23 hours before;
#                no import lands in it while the row reads): 'Runs, <range> (the whole hours ...)' above the grid with
#                the tiles 'failed or cancelled' (1 or more: the seeded failure), 'succeeded', 'retries attempted' whose
#                numbers equal /api/jobs/history?part=cards (parity) over the range the page sent (data-from / data-to)
#                and the HAND COUNT from the RAW runs (mssql_job_runs: step 0 failed (0, 3) and succeeded (1), step rows
#                with run_status 2, every whole UTC hour the range touches); 'Longest 5', 'Most frequent 5', 'Most failed
#                5' each a grid
#   J8p cards    the same on erp01's PostgreSQL Jobs tab: failed (1 or more) and succeeded equal the API and the raw
#                job_runs with an end by hand; 'retries attempted' reads 'none', the API's retries NULL
#   J5 counts    #/jobs: 'Jobs by instance' above 'Job status', one row per instance with a job (its row count = the
#                status part's distinct instances); sql01's 'last run succeeded' a button (both seeded jobs succeeded
#                last); its click sets Show 'Last run succeeded' and the instance (the line says 'on demo-onprem-sql01'),
#                every row then sql01's, the seeded SQL Agent job there
#   J6 rate      4 s after the grid the 'failure rate 7 days' column holds no '0' for a rate not read: every cell a
#                percent or 'no finished run' or 'being built'; the seeded SJ and PJ '50 %' (one failure, one success),
#                RJ '66.7 %', NJ 'no finished run'; Show 'Failure rate over 50 % (7 days)' lists exactly JRATE jobs (the
#                HAND COUNT from the hours, present jobs of active instances, failed over finished > 0.5; 1 or more:
#                RJ), RJ among them, SJ not
#   J7 running   Show 'Running now' lists exactly the status part's rows with running_since (parity with the API), 1 or
#                more, the seeded SQL Agent job among them
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_fleetms_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""; UNWIRE=""
fail() { echo "FAIL: $*" >&2; exit 1; }
bad=0; no() { echo "FAIL: $*" >&2; bad=$((bad + 1)); }   # a row that failed: the next rows still run, the end exits 1
cleanup() {
  local rc=$?
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  wait 2>/dev/null || true
  if [[ -n "$UNWIRE" ]]; then
    git apply -R scripts/fleet-mssql-wiring.patch 2>/dev/null || { echo "FAIL: the wiring patch did not come off main.ts: put it back by hand" >&2; rc=1; }
  fi
  if [[ -f "$WORK/app.js.kept" ]]; then cp "$WORK/app.js.kept" internal/web/dist/app.js || { echo "FAIL: internal/web/dist/app.js was not put back" >&2; rc=1; }; fi
  timeout 300 psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 \
    || echo "the scratch database $DB: drop not confirmed in 300 s (psql exit $?)"
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
for t in go chromium node npm psql curl python3; do command -v $t >/dev/null || fail "$t is not on this machine"; done
for p in $PORT $CDP; do ss -ltnH "( sport = :$p )" | grep -q . && fail "port $p is in use: run again"; done

if grep -q 'mssqlBackupsFleetSection' web/src/main.ts; then
  cp internal/web/dist/app.js "$WORK/app.js.kept"
  (cd web && npm run build > "$WORK/build.txt" 2>&1) || { tail -30 "$WORK/build.txt"; fail "the wired tree's bundle did not build"; }
  echo "wiring: main.ts wired in this tree (the join's, or left wired by a killed run), bundle built from it: $(wc -c < internal/web/dist/app.js) bytes"
elif grep -qE 'export (async )?(function|const) mssqlBackupsFleetSection\b' web/src/mssql_backups.ts; then
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
      'not_judged', (select count(*) from pgvigil.mssql_backup_judged b where b.instance_id = i.instance_id and b.not_judged is not null),
      'replicas_unseen', (select count(*) from pgvigil.mssql_backup_judged b where b.instance_id = i.instance_id and b.replicas_unseen),
      'nul_recent', (select count(*) from pgvigil.mssql_jobs_findings f where f.instance_id = i.instance_id and f.check_name = 'a backup went to NUL'),
      'problems', (select count(distinct f.object) from pgvigil.mssql_jobs_findings f
                    where f.instance_id = i.instance_id and f.check_name not in ('a job failed', 'a job runs far longer than its average')
                      and exists (select 1 from pgvigil.mssql_backup_judged b where b.instance_id = f.instance_id and b.database_name = f.object))))
    from pgvigil.instances i where i.is_active and i.engine = 'sqlserver'),
  'all', (select count(*) from pgvigil.mssql_backup_judged b join pgvigil.instances i using (instance_id) where i.is_active and i.engine = 'sqlserver'),
  'dbkeys', (select json_agg(b.instance_id || '|' || b.database_name order by 1) from pgvigil.mssql_backup_judged b join pgvigil.instances i using (instance_id)
              where i.is_active and i.engine = 'sqlserver'),
  'fkeys', (select json_agg(f.instance_id || '|' || f.check_name || '|' || f.object order by 1) from pgvigil.mssql_jobs_findings f join pgvigil.instances i using (instance_id)
             where i.is_active and f.check_name not in ('a job failed', 'a job runs far longer than its average')),
  'problems', (select json_agg(distinct f.instance_id || '|' || f.object order by f.instance_id || '|' || f.object) from pgvigil.mssql_jobs_findings f
                join pgvigil.instances i using (instance_id)
                where i.is_active and i.engine = 'sqlserver' and f.check_name not in ('a job failed', 'a job runs far longer than its average')
                  and exists (select 1 from pgvigil.mssql_backup_judged b where b.instance_id = f.instance_id and b.database_name = f.object)),
  'findings', (select count(*) from pgvigil.mssql_jobs_findings f join pgvigil.instances i using (instance_id)
                where i.is_active and f.check_name not in ('a job failed', 'a job runs far longer than its average')),
  's1', (select count(*) from pgvigil.mssql_backup_judged where instance_id = $S1))")
echo "$HAND" > "$WORK/hand.json"
c1=$(curl -s -o "$WORK/all.json" -w '%{http_code}' "${BASE}api/mssql/backups")
c2=$(curl -s -o "$WORK/problems.json" -w '%{http_code}' "${BASE}api/mssql/backups?problems=1")
c3=$(curl -s -o "$WORK/tab.json" -w '%{http_code}' "${BASE}api/mssql/backups?instance=$S1")
B1=$(python3 -I - "$WORK" "$S1" "$S3" "$NULDB" "$c1" "$c2" "$c3" 2>"$WORK/b1.err" <<'PY'
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
    want = {'databases': h['databases'], 'not_judged': h['not_judged'], 'replicas_unseen': h['replicas_unseen'],
            'nul_recent': h['nul_recent'], 'problems': h['problems']}
    for k in ('full', 'diff', 'log'):
        for st, col in (('ok', 'ok'), ('late', 'late'), ('never', 'never'), ('not judged', 'not_judged')):
            want[f'{k}_{col}'] = (h[k] or {}).get(st, 0)
    got = {k: r[k] for k in want}
    if got != want: out.append(f"{h['name']}: {got} vs the hand count {want}")
if str(s3) not in bi or bi[str(s3)]['snapshot_at'] is not None: out.append("sql03 has no row with no read")
dbs, pdbs, fnd = rows(a, 'databases'), rows(p, 'databases'), rows(a, 'findings')
dk = sorted(f"{r['instance_id']}|{r['database_name']}" for r in dbs)
if dk != sorted(hand['dbkeys'] or []): out.append(f"databases {len(dbs)} vs {hand['all']}: only in the API {sorted(set(dk) - set(hand['dbkeys'] or []))[:3]}, only in the hand count {sorted(set(hand['dbkeys'] or []) - set(dk))[:3]}, duplicated {len(dk) - len(set(dk))}")
keys = sorted(f"{r['instance_id']}|{r['database_name']}" for r in pdbs)
if keys != sorted(hand['problems'] or []): out.append(f"problems {keys} vs {hand['problems']}")
nr = [r for r in pdbs if str(r['instance_id']) == s1 and r['database_name'] == nul]
if not nr or nr[0]['nul_recent'] is not True or nr[0]['problem'] is not True: out.append(f"the NUL database {nul} under Problems: {nr}")
fk = sorted(f"{r['instance_id']}|{r['check_name']}|{r['object']}" for r in fnd)
if fk != sorted(hand['fkeys'] or []): out.append(f"findings {len(fnd)} vs {hand['findings']}: only in the API {sorted(set(fk) - set(hand['fkeys'] or []))[:2]}, only in the hand count {sorted(set(hand['fkeys'] or []) - set(fk))[:2]}")
if not any(f['check_name'] == 'a backup went to NUL' and f['object'] == nul and str(f['instance_id']) == s1 for f in fnd): out.append("no 'a backup went to NUL' finding for " + nul)
if len(rows(t, 'databases')) != hand['s1'] or not rows(t, 'limits'): out.append(f"the tab: {len(rows(t, 'databases'))} databases vs {hand['s1']}, limits {len(rows(t, 'limits'))}")
print(('FAIL|' + '; '.join(out)) if out else f"ok|{len(bi)} instances (sql03 unread), {len(dbs)} databases, {len(pdbs)} under Problems with {nul}, {len(fnd)} findings, the tab {hand['s1']} = the hand counts")
PY
) || B1="FAIL|the B1 reader crashed: $(tail -1 "$WORK/b1.err")"
[[ "$B1" == ok\|* ]] || no "B1: ${B1#FAIL|}"
[[ $bad -eq $b0 ]] && echo "ok   B1 api: ${B1#ok|}"
PROBLEMS=$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["problems"] or []))' "$WORK/hand.json")
ALL=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["all"])' "$WORK/hand.json")
INSTS=$(Q "select count(*) || '|' || count(*) filter (where engine = 'sqlserver') from pgvigil.instances where is_active")

echo "== S1 / J1: the job judge"; b0=$bad
ERP=$(Q "select instance_id from pgvigil.instances where name = 'demo-onprem-erp01'")
SJ='fleet proof failed then succeeded'; PJ='fleet-proof-failed-then-succeeded'
RJ='fleet-proof-two-of-three-failed'; NJ='fleet-proof-no-run'   # B9b J6: a rate over 50 %, a job with no run
Q "insert into pgvigil.mssql_jobs (instance_id, job_id, snapshot_at, name, enabled, category, last_outcome, last_run_at, running_since)
   values ($S1, 'FLEETPROOF-0001', now(), '$SJ', true, 'proof', 1, now() - interval '60 minutes', now() - interval '5 minutes');
   insert into pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, step_name, run_status, duration_s)
   values ($S1, now() - interval '120 minutes', 990000001, 'FLEETPROOF-0001', '$SJ', 0, '(Job outcome)', 0, 5),
          ($S1, now() - interval '120 minutes' + interval '1 second', 990000000, 'FLEETPROOF-0001', '$SJ', 1, 'one', 0, 4),
          ($S1, now() - interval '60 minutes', 990000003, 'FLEETPROOF-0001', '$SJ', 0, '(Job outcome)', 1, 5),
          ($S1, now() - interval '60 minutes' + interval '1 second', 990000002, 'FLEETPROOF-0001', '$SJ', 1, 'one', 1, 4);
   insert into pgvigil.jobs (instance_id, scheduler, job_id, snapshot_at, job_name, schedule, command, active, first_seen, is_present)
   values ($ERP, 'pg_cron', 990001, now(), '$PJ', '0 * * * *', 'SELECT 1', true, now() - interval '3 days', true),
          ($ERP, 'pg_cron', 990002, now(), '$RJ', '0 * * * *', 'SELECT 1', true, now() - interval '3 days', true),
          ($ERP, 'pg_cron', 990003, now(), '$NJ', '0 3 * * *', 'SELECT 1', true, now() - interval '3 days', true);
   insert into pgvigil.job_runs (instance_id, scheduler, job_id, run_id, status, start_time, end_time, duration_secs, snapshot_at)
   values ($ERP, 'pg_cron', 990001, 990001, 'failed', now() - interval '120 minutes', now() - interval '119 minutes', 60, now()),
          ($ERP, 'pg_cron', 990001, 990002, 'succeeded', now() - interval '60 minutes', now() - interval '59 minutes', 60, now()),
          ($ERP, 'pg_cron', 990002, 990003, 'failed', now() - interval '200 minutes', now() - interval '199 minutes', 60, now()),
          ($ERP, 'pg_cron', 990002, 990004, 'failed', now() - interval '180 minutes', now() - interval '179 minutes', 60, now()),
          ($ERP, 'pg_cron', 990002, 990005, 'succeeded', now() - interval '170 minutes', now() - interval '169 minutes', 60, now())" >/dev/null
# the demo's live mssql_jobs import (every 5 minutes) would replace sql01's jobs and drop the seeded one: its stored read
# an hour ahead makes mssql_hadr_read refuse the import as older
[[ "$(Q "update pgvigil.mssql_hadr_reads set snapshot_at = now() + interval '1 hour' where instance_id = $S1 and collection = 'mssql_jobs' returning 1")" == 1 ]] \
  || fail "sql01 has no 'mssql_jobs' read to hold the seeded job against the demo's import"
# HAND COUNTS from the raw run rows (not the product's SQL): the seeded jobs' failed and succeeded runs and durations
JRAW=$(Q "select json_build_object(
  'ms', (select json_build_object('fail_24h', count(*) filter (where step_id = 0 and run_status in (0, 3) and snapshot_at > now() - interval '24 hours'),
                                  'fail_7d', count(*) filter (where step_id = 0 and run_status in (0, 3)),
                                  'step_fail_7d', count(*) filter (where step_id > 0 and run_status in (0, 3)),
                                  'ok_24h', count(*) filter (where step_id = 0 and run_status = 1 and snapshot_at > now() - interval '24 hours'),
                                  'ok_7d', count(*) filter (where step_id = 0 and run_status = 1),
                                  'max', max(duration_s) filter (where step_id = 0),
                                  -- DBA Dash's average (AgentJob7Day.sql): per UTC hour of the start, total / (failed + succeeded) in
                                  -- whole seconds, then the average of those, whole seconds - counted here from the runs themselves
                                  'avg', (select trunc(avg(trunc(x.t / nullif(x.n, 0)))) from (select sum(r.duration_s) as t, count(*) filter (where r.run_status in (0, 1, 3)) as n
                                            from pgvigil.mssql_job_runs r where r.instance_id = $S1 and r.job_id = 'FLEETPROOF-0001' and r.step_id = 0 and r.snapshot_at > now() - interval '7 days'
                                           group by date_trunc('hour', r.snapshot_at at time zone 'UTC')) x))
           from pgvigil.mssql_job_runs where instance_id = $S1 and job_id = 'FLEETPROOF-0001' and snapshot_at > now() - interval '7 days'),
  'pg', (select json_build_object('fail_24h', count(*) filter (where status in ('failed', 'internal error', 'aborted') and start_time > now() - interval '24 hours'),
                                  'fail_7d', count(*) filter (where status in ('failed', 'internal error', 'aborted')),
                                  'ok_24h', count(*) filter (where status = 'succeeded' and start_time > now() - interval '24 hours'),
                                  'ok_7d', count(*) filter (where status = 'succeeded'), 'max', max(duration_secs),
                                  'avg', (select trunc(avg(trunc(x.t / nullif(x.n, 0)))) from (select sum(r.duration_secs) as t, count(*) filter (where r.status in ('succeeded', 'failed', 'internal error', 'aborted')) as n
                                            from pgvigil.job_runs r where r.instance_id = $ERP and r.scheduler = 'pg_cron' and r.job_id = 990001 and r.end_time is not null and r.start_time > now() - interval '7 days'
                                           group by date_trunc('hour', r.start_time at time zone 'UTC')) x))
           from pgvigil.job_runs where instance_id = $ERP and scheduler = 'pg_cron' and job_id = 990001 and start_time > now() - interval '7 days'))")
echo "$JRAW" > "$WORK/jraw.json"
Q "select coalesce(json_agg(json_build_object('k', i.instance_id || '|' || s.scheduler || '|' || s.job_id, 'v', json_build_array(s.status, s.reason, s.level, s.last_outcome,
            extract(epoch from s.last_failed_at)::float8, extract(epoch from s.last_succeeded_at)::float8, s.fail_24h, s.fail_7d, s.step_fail_24h, s.step_fail_7d))), '[]')
     from pgvigil.instances i cross join lateral pgvigil.job_status(i.instance_id) s where i.is_active" > "$WORK/jhand.json"
JALL=$(Q "select (select count(*) from pgvigil.mssql_jobs m join pgvigil.instances i using (instance_id) where i.is_active)
            + (select count(*) from pgvigil.jobs g join pgvigil.instances i using (instance_id) where i.is_active and g.is_present)")
JPROB=$(Q "select count(*) from pgvigil.instances i cross join lateral pgvigil.job_status(i.instance_id) s where i.is_active and s.status in ('crit', 'warn')")
# B9b J6: the jobs whose hours of the last 7 days failed more than half their finished runs (present jobs, active instances)
JRATE=$(Q "select count(*) from (select h.instance_id, h.scheduler, h.job_id, sum(h.failed) f, sum(h.succeeded) s
             from pgvigil.job_stats_hourly h join pgvigil.instances i using (instance_id)
            where i.is_active and h.step_id = 0 and h.snapshot_at >= now() - interval '168 hours'
              and (exists (select 1 from pgvigil.mssql_jobs m where h.scheduler = 'sqlagent' and m.instance_id = h.instance_id and m.job_id = h.job_id)
                   or exists (select 1 from pgvigil.jobs g where h.scheduler <> 'sqlagent' and g.instance_id = h.instance_id
                                 and g.scheduler = h.scheduler and g.job_id::text = h.job_id and g.is_present))
            group by 1, 2, 3) x where f + s > 0 and f::numeric / (f + s) > 0.5")
JACK=$(Q "select count(*) from pgvigil.acks where kind = 'job' and ended_at is null" 2>/dev/null || echo 0)
for u in "jobsreport" "jobsreport?part=status" "jobsreport?part=status&ids=$S1" "jobsreport?part=stats" "jobsreport?part=status&ids=abc" "mssql/summary" "overview"; do
  f="$WORK/j-$(printf %s "$u" | tr -c 'a-z0-9' _).json"; echo "$(curl -s -o "$f" -w '%{http_code}' "${BASE}api/$u") $f"; done > "$WORK/jcodes.txt"
J1=$(python3 -I - "$WORK" "$S1" "$ERP" "$SJ" "$PJ" "$JALL" 2>"$WORK/j1.err" <<'PY2'
import json, re, sys
from datetime import datetime
w, s1, erp, sj, pj, jall = sys.argv[1:]
codes = {l.split()[1]: l.split()[0] for l in open(w + '/jcodes.txt')}
f = lambda u: w + '/j-' + ''.join(c if c in 'abcdefghijklmnopqrstuvwxyz0123456789' else '_' for c in u) + '.json'
rows = lambda d, p: [dict(zip(d[p]['columns'], r)) for r in d[p]['rows']] if isinstance(d.get(p), dict) else []
out = []
want = {'jobsreport': '200', 'jobsreport?part=status': '200', f'jobsreport?part=status&ids={s1}': '200', 'jobsreport?part=stats': '200',
        'jobsreport?part=status&ids=abc': '400', 'mssql/summary': '200', 'overview': '200'}
got = {u: codes.get(f(u)) for u in want}
if got != want: print('FAIL|answers ' + json.dumps(got)); sys.exit()
plain = json.load(open(f('jobsreport')))
if sorted(plain) != ['counts', 'jobs']: out.append(f'no part name answered {sorted(plain)}')
st = rows(json.load(open(f('jobsreport?part=status'))), 'status')
def epoch(v):   # the API's time text (RFC 3339, 'Z' or an offset, 0-9 fraction digits) to seconds; psql's side is extract(epoch)
    if v is None: return None
    m = re.match(r'^(\d{4}-\d\d-\d\d)[T ](\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d(?::?\d\d)?)?$', str(v))
    if not m: raise ValueError(f'a time the reader does not know: {v!r}')
    d, t, frac, tz = m.groups()
    frac = '.' + (frac[1:] + '000000')[:6] if frac else ''
    tz = '+00:00' if tz in (None, 'Z') else (tz + ':00' if len(tz) == 3 else (tz if ':' in tz else tz[:3] + ':' + tz[3:]))
    return datetime.fromisoformat(f'{d}T{t}{frac}{tz}').timestamp()
MIN = re.compile(r'^(\w+) (\d+) minute\(s\) ago (.*)$')
def same_reason(a, b):   # the same words, a minute count within one (the two reads are seconds apart)
    if a == b: return True
    ma, mb = MIN.match(a or ''), MIN.match(b or '')
    return bool(ma and mb and ma.group(1) == mb.group(1) and ma.group(3) == mb.group(3) and abs(int(ma.group(2)) - int(mb.group(2))) <= 1)
def same(h, a):
    if h[0] != a[0] or not same_reason(h[1], a[1]) or h[2] != a[2] or h[3] != a[3]: return False
    for x, y in ((h[4], a[4]), (h[5], a[5])):
        if (x is None) != (y is None) or (x is not None and abs(x - y) > 0.001): return False
    return [int(v) for v in h[6:10]] == [int(v) for v in a[6:10]]
hand = {x['k']: x['v'] for x in json.load(open(w + '/jhand.json'))}
key = lambda r: f"{r['instance_id']}|{r['scheduler']}|{r['job_id']}"
api = {key(r): [r['status'], r['reason'], r['level'], r['last_outcome'], epoch(r['last_failed_at']), epoch(r['last_succeeded_at']),
                r['fail_24h'], r['fail_7d'], r['step_fail_24h'], r['step_fail_7d']] for r in st}
if set(api) != set(hand): out.append(f"status keys: {len(api)} vs the one-instance form's {len(hand)}; only in the API {sorted(set(api) - set(hand))[:3]}, only in the form {sorted(set(hand) - set(api))[:3]}")
diff = [k for k in api if k in hand and not same(hand[k], api[k])]
if diff: out.append(f"the ten fields differ on {len(diff)} job(s): {[(k, hand[k], api[k]) for k in diff[:2]]}")
if len(st) != int(jall): out.append(f"status rows {len(st)} vs every job {jall} (the jobs tables)")
# DBA Dash's order: the last run failed first, then the newest failure (none last)
order = [(0 if r['last_run_failed'] else 1, -(epoch(r['last_failed_at']) or float('-inf'))) for r in st]
if any(order[n] > order[n + 1] for n in range(len(order) - 1)): out.append(f"status rows not in the order 'last run failed, then the newest failure': {order[:6]}")
if any(r['last_run_failed'] is None for r in st): out.append("last_run_failed NULL on a row")
one = rows(json.load(open(f(f'jobsreport?part=status&ids={s1}'))), 'status')
if sorted(key(r) for r in one) != sorted(k for k in hand if k.split('|')[0] == s1): out.append(f"ids={s1}: {len(one)} rows vs the form's {sum(1 for k in hand if k.split('|')[0] == s1)} of sql01")
sts = rows(json.load(open(f('jobsreport?part=stats'))), 'stats')
if sorted(key(r) for r in sts) != sorted(api): out.append(f"stats rows {len(sts)} vs status {len(api)}")
raw = json.load(open(w + '/jraw.json'))
for inst, name, side in ((s1, sj, 'ms'), (erp, pj, 'pg')):
    h = raw[side]
    r = [x for x in st if str(x['instance_id']) == inst and x['job_name'] == name]
    if not r or r[0]['status'] != 'warn' or r[0]['level'] != 'default' or not same_reason(r[0]['reason'], 'failed 120 minute(s) ago (warning within 10080)'):
        out.append(f"{name}: {[(x['status'], x['level'], x['reason']) for x in r]}"); continue
    r = r[0]
    if (int(r['fail_24h']), int(r['fail_7d'])) != (h['fail_24h'], h['fail_7d']) or (h['fail_24h'], h['fail_7d']) != (1, 1): out.append(f"{name}: failed 24 h / 7 d {r['fail_24h']} / {r['fail_7d']}, the raw rows {h['fail_24h']} / {h['fail_7d']} (want 1 / 1)")
    if side == 'ms' and (int(r['step_fail_7d']), h['step_fail_7d']) != (1, 1): out.append(f"{name}: failed steps 7 d {r['step_fail_7d']}, the raw rows {h['step_fail_7d']} (want 1)")
    t = [x for x in sts if str(x['instance_id']) == inst and key(x) == key(r)]
    if not t or (int(t[0]['ok_24h'] or 0), int(t[0]['ok_7d'] or 0)) != (h['ok_24h'], h['ok_7d']) or (h['ok_24h'], h['ok_7d']) != (1, 1) or t[0]['max_secs_7d'] is None or float(t[0]['max_secs_7d']) != float(h['max']) \
            or t[0]['avg_secs_7d'] is None or h['avg'] is None or float(t[0]['avg_secs_7d']) != float(h['avg']):
        out.append(f"{name}: stats {[(x['ok_24h'], x['ok_7d'], x['max_secs_7d'], x['avg_secs_7d']) for x in t]} vs the raw rows ok {h['ok_24h']} / {h['ok_7d']}, max {h['max']}, DBA Dash's average {h['avg']}")
cells = rows(json.load(open(f('mssql/summary'))), 'cells')
c = [x for x in cells if str(x['instance_id']) == s1 and x['key'] == 'jobs']
if not c or int(c[0]['warning']) < 1 or not any(sj in str(d) for d in (c[0].get('detail') or [])): out.append(f"sql01's Agent Jobs cell: {c}")
ov = json.load(open(f('overview')))
ov = rows(ov, 'overview') if 'overview' in ov else [dict(zip(ov['columns'], r)) for r in ov['rows']]
o = [x for x in ov if str(x['instance_id']) == erp and x.get('check_name') == 'job status' and pj in str(x.get('object'))]
if not o or o[0]['severity'] != 'warning': out.append(f"erp01's overview 'job status' row: {o}")
print(('FAIL|' + '; '.join(out)) if out else f"ok|{len(st)} jobs = the one-instance form on all ten fields, in DBA Dash's order; ids sql01's {len(one)}; stats {len(sts)}; no part name: counts, jobs; both seeded jobs warn at default, their counts and stats = the raw rows (failed 1 / 1, succeeded 1 / 1, max {raw['ms']['max']} s / {raw['pg']['max']} s, DBA Dash's whole-second average {raw['ms']['avg']} s / {raw['pg']['avg']} s); sql01's cell warning {c[0]['warning']}; erp01's overview row warning")
PY2
) || J1="FAIL|the J1 reader crashed: $(tail -1 "$WORK/j1.err")"
[[ "$J1" == ok\|* ]] || no "J1: ${J1#FAIL|}"
[[ $bad -eq $b0 ]] && echo "ok   J1 api + S1 cells: ${J1#ok|}"
# R0 (FLEET STATS ROLLUP, 0139): the demo's own job imports - the collector's import functions, the SECURITY DEFINER path a
# store test does not take - and the seeds above filled the hourly table through its triggers, and none of them failed
b0=$bad
R0=$(Q "select format('%s|%s|%s|%s', (select count(*) from pgvigil.job_stats_hourly h join pgvigil.instances i using (instance_id) where i.engine = 'sqlserver'),
                                  (select count(*) from pgvigil.job_stats_hourly where instance_id = $ERP and job_id = '990001'),
                                  (select count(*) from pgvigil.collection_log where collection = 'job_stats_hourly'), (select count(*) from pgvigil.job_stats_dirty))")
IFS='|' read -r r0ms r0pg r0fail r0dirty <<< "$R0"
[[ ${r0ms:-0} -gt 0 && ${r0pg:-0} -eq 2 && $r0fail == 0 && $r0dirty == 0 ]] \
  || no "R0 hours: $r0ms SQL Server hour rows (want some), $r0pg of the seeded pg_cron job's (want 2: its two hours), $r0fail 'rollup failed' rows (want 0), $r0dirty dirty ranges (want 0)"
[[ $bad -eq $b0 ]] && echo "ok   R0 hours: $r0ms SQL Server hour rows from the demo's imports and the seeds, the seeded pg_cron job's two hours, 0 'rollup failed', 0 dirty"

echo "== a headless Chromium on CDP $CDP"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
set +e
FM_S1=$S1 FM_S3=$S3 FM_NULDB="$NULDB" FM_PROBLEMS=$PROBLEMS FM_ALL=$ALL FM_INSTS="$INSTS" FM_SJ="$SJ" FM_PJ="$PJ" FM_JALL=$JALL FM_JPROB=$((JPROB + JACK)) FM_JRATE=$JRATE FM_RJ="$RJ" FM_NJ="$NJ" FM_ERP=$ERP FM_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB" node scripts/fleet-mssql-check.mjs "$CDP" "$BASE" | tee "$WORK/check.txt"
rc=${PIPESTATUS[0]}; set -e
if [[ $rc -ne 0 ]]; then
  last=$(tail -n 1 "$WORK/check.txt" 2>/dev/null || true)
  if [[ "$last" =~ ^FAIL\ [0-9]+\ case ]]; then no "fleet-mssql-check: exit $rc, '$last' (its FAIL rows are above)"
  else no "fleet-mssql-check: exit $rc and it STOPPED EARLY - its last line was '${last:0:160}'"; fi
fi
# the seeded rows after the browser check: a missing one is the demo's import, a proof fault (the rows above then read it)
SEEDED=$(Q "select (select count(*) from pgvigil.mssql_jobs where instance_id = $S1 and job_id = 'FLEETPROOF-0001') || '|' ||
                   (select count(*) from pgvigil.jobs where instance_id = $ERP and scheduler = 'pg_cron' and job_id = 990001 and is_present)")
[[ "$SEEDED" == "1|1" ]] || no "the seeded jobs after the browser check: SQL Agent|pg_cron = $SEEDED (want 1|1) - the demo's live import replaced them: a proof fault"
[[ $bad -eq 0 ]] || fail "$bad check(s) failed"
echo "OK: the fleet's SQL Server backups and jobs (B1-B4, S1, J1-J4, R0, the S1 link)"
