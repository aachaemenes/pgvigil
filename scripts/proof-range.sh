#!/usr/bin/env bash
# Proof of the page range up to a year (task RANGE, DONE-1): a demo fleet of 20 days is seeded into a throwaway
# database, served on loopback, then purged at 10 days ('pgvigil purge -days 10'), and a headless Chromium runs
# scripts/range-check.mjs over it. Needs go, psql, chromium, node, unzip, curl and python3, the web bundle built
# (internal/web/dist/app.js) and a PostgreSQL for the throwaway database:
#   PGVIGIL_ADMIN_DSN   keyword-form connection to a cluster as a login that may create a database
#   PGVIGIL_DEMO_WAIT_S the seconds to wait for the seeded demo to serve (default 900)
#   RANGE_OUT           a folder to keep the downloads and the check's output in (default: removed with the temp folder)
# Expected (written before the first run; red before the change, whose API refused a window over 31 days and whose
# panel had ten lengths and no Date or Month):
#   RA api         erp01's statements over 365 days: 200, X-Pgvigil-Read-From = to less 745 h, X-Pgvigil-Window-From =
#                  the asked start, its JSON read_from the same instant; over 20 days: 200 and no read header, no read_from;
#                  over 366 days, an hour and a second: 400 'window longer than a year'; dbinfo's db_series over 365 days:
#                  200, no read header (its reach is a year); replication over 365 days: 'series' carries read_from,
#                  'latest' and 'checks' (no window argument) do not; /api/plans' 'plans' and /api/perfsummary's 'pg'
#                  over 365 days carry read_from too; tables/top over 60 days reads its 7 days and says 7 (X-Pgvigil-Read-From)
#   RB stored      after 'purge -days 8' then 'purge -days 10': /api/stored = the last run's days 10 and end, rows_from =
#                  the LATEST cut of any run (the first run's start less 8 days, not the last run's end less 10: the
#                  rows the 8-day run deleted stay gone), the oldest monthly / daily partition by the catalogue's
#                  names, each = a psql hand read (red before the fix, whose rows_from was the last run's end less 10 days)
#   R1 menu        the panel: the twenty quick ranges in DBA Dash's order in pgvigil's words, 'Last 5 minutes' to 'Last
#                  year'; the Date select 15 days ('YYYY-MM-DD (Ddd - Today)', '- Yesterday)', '- 2 days ago)' ...
#                  '- 14 days ago)') and the Month select 13 months ('Mon YYYY (This Month)', '(Last Month)', '(2 months
#                  ago)' ... '(12 months ago)'), each labelled with the display zone (America/Los_Angeles pinned)
#   R2 year        'Last year' clicked on erp01's Statements: w=1y; the page's line 'Parts of this page read the newest
#                  31 days of this window: <from> to <to> (the window is longer than they read).' and the statements
#                  grid's 'This list reads the newest 31 days of this window: ...'; at w=7d neither
#   R3 date/month  Date 'Today' = w=today; 'Yesterday' = the calendar's Yesterday address; '2 days ago' ends where
#                  Yesterday starts and lasts 24 h (23 or 25 across a clock change); Month 'This Month' = w=mtd, 'Last
#                  Month' = the calendar's Previous month address, '2 months ago' ends where it starts
#   R4 zoom        Zoom out at w=180d gives w=1y; at w=1y it is off in its place (aria-disabled, not the disabled
#                  attribute, its description 'the range is already a year, the longest pgvigil reads') and the key -
#                  leaves w=1y; an old address w=4h reads 'Range: Last 4 hours' and Zoom out gives w=12h (the menu's
#                  next length at least twice it)
#   R5 refresh     the Summary at w=7d: the 30 s and 1 min choices disabled with their reason, '5 min' selected, the
#                  footer 'auto refresh every 5 min (a window over a day)'; at w=1h nothing disabled, the footer 'auto
#                  refresh every 30 s'
#   R6 retention   the Summary at w=30d: the line 'This window starts <t>, before what the repository keeps: the
#                  per-snapshot summaries from <rows_from> (pgvigil purge -days 10, last run <t>); the monthly history
#                  from <Month YYYY>...' (each date = RB's hand read as the page writes a time) and a Data retention
#                  link to #/retention; at w=3d no such line
#   R7 export      erp01's Statements at w=1y: Export .xlsx - its 'About' sheet holds a 'Read' row 'Parts of this page
#                  read the newest 31 days ...' and the statements sheet's row there 'This list reads the newest 31 days ...';
#                  Export CSV - the statements file's first line is that list's 'This list reads ...' line
#   R8 mail        the same page's Mail... Send now: the body the page builds and posts holds the header line 'Read'
#                  with the page's words and the statements grid's note (the mail door and the send answered in the
#                  page by stubs: nothing is sent; the server's sender is proof-reportmail's, unchanged)
#   R9 late reply  erp01's Statements at w=60d with every reply of that page held at its response (CDP Fetch; the
#                  statements reply among them, at least one cut by the server), the address moved to w=1h: the 1-hour
#                  page is placed with no range-cut line, the held replies are then let through (each release
#                  answered without an error), and 1.5 s later the 1-hour page still shows none (red before the fix)
#   R10 own span   erp01's sizes copied 60 days back, its Storage at w=1h with the 'Database growth' panel's '90 days'
#                  pressed: w stays 1h, no range-cut line on the page, and inside that panel the note 'Marks are read
#                  for the newest 31 days of this window: <from> to <to> (this chart is longer than they read).' (red
#                  before the fix)
#   R11 once       sql01's SQL Server File IO at w=60d: at least two of its replies cut by the server (counted at their
#                  responses), one range-cut line, 'the newest 31 days of this window' in it once (red before the fix)
#   R12 file rules that workbook (the one whose 'About' holds the 'Read' row) passes scripts/xlsx-check.py rules, X0-X12,
#                  and 'About' is its last sheet
# The R9-R11 lines were NOT written before those rows' first run: R9 and R11 first ran on 2026-11-13 (their expected
# stood in the run's notes), these lines came the day after and were reworded when the rows changed; R12's line was
# written before its first run.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_range_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
bad=0; no() { echo "FAIL: $*" >&2; bad=$((bad + 1)); }   # a row that failed: the next rows still run, the end exits 1
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  wait 2>/dev/null || true
  if [[ -n "${RANGE_OUT:-}" ]]; then mkdir -p "$RANGE_OUT"; cp -r "$WORK/dl" "$WORK/check.txt" "$RANGE_OUT/" 2>/dev/null || true; fi
  timeout 300 psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 \
    || echo "the scratch database $DB: drop not confirmed in 300 s (psql exit $?)"
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in go chromium node psql unzip curl python3; do command -v $t >/dev/null || fail "$t is not on this machine"; done
for p in $PORT $CDP; do ss -ltnH "( sport = :$p )" | grep -q . && fail "port $p is in use: run again"; done

echo "== build and seed the demo (20 days) into $DB, serve on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
"$WORK/pgvigil" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -serve -listen "127.0.0.1:$PORT" -days 20 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-900}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { cat "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up"; }
BASE="http://127.0.0.1:$PORT/"
Q() { psql "$PGVIGIL_ADMIN_DSN dbname=$DB" -XAtq -c "$1"; }
ERP=$(Q "select instance_id from pgvigil.instances where name = 'demo-onprem-erp01'")
[[ -n "$ERP" ]] || fail "the demo has no demo-onprem-erp01"
SQL01=$(Q "select instance_id from pgvigil.instances where name = 'demo-onprem-sql01'")
[[ -n "$SQL01" ]] || fail "the demo has no demo-onprem-sql01"

echo "== RA: the API's read window"; b0=$bad
ts() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
N=$(date -u +%s); now=$(ts $N); y365=$(ts $((N - 365 * 86400)))
want_from=$(ts $((N - 745 * 3600)))
hdr() { curl -s -D "$WORK/h.txt" -o "$WORK/b.json" -w '%{http_code}' "$BASE$1"; }
h() { grep -i "^$1:" "$WORK/h.txt" | tr -d '\r' | cut -d' ' -f2; }
c=$(hdr "api/statements?instance=$ERP&from=$y365&to=$now")
jf=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("read_from",""))' "$WORK/b.json")
[[ "$c" == 200 && "$(h X-Pgvigil-Read-From)" == "$want_from" && "$(h X-Pgvigil-Window-From)" == "$y365" && "$jf" == "$want_from" ]] \
  || no "RA: statements over 365 days: $c, read from '$(h X-Pgvigil-Read-From)' (want $want_from), window from '$(h X-Pgvigil-Window-From)', JSON read_from '$jf'"
d20=$(ts $((N - 20 * 86400)))
c2=$(hdr "api/statements?instance=$ERP&from=$d20&to=$now")
[[ "$c2" == 200 && -z "$(h X-Pgvigil-Read-From)" ]] && ! grep -q '"read_from"' "$WORK/b.json" || no "RA: 20 days: $c2, read header '$(h X-Pgvigil-Read-From)'"
over=$(ts $((N - 366 * 86400 - 3600 - 1)))
c3=$(hdr "api/statements?instance=$ERP&from=$over&to=$now")
[[ "$c3" == 400 ]] && grep -q 'window longer than a year' "$WORK/b.json" || no "RA: 366 days, an hour and a second: $c3 $(head -c 200 "$WORK/b.json")"
c4=$(hdr "api/dbinfo?instance=$ERP&part=db_series&from=$y365&to=$now")
[[ "$c4" == 200 && -z "$(h X-Pgvigil-Read-From)" ]] || no "RA: db_series over 365 days: $c4, read header '$(h X-Pgvigil-Read-From)'"
c5=$(hdr "api/replication?instance=$ERP&from=$y365&to=$now")
parts=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(k+("=cut" if isinstance(v,dict) and v.get("read_from") else "") for k,v in sorted(d.items())))' "$WORK/b.json")
[[ "$c5" == 200 && " $parts " == *" series=cut "* && " $parts " == *" latest "* && " $parts " == *" checks "* ]] || no "RA: replication over 365 days: $c5, parts '$parts'"
# a reply that is not one table (a struct, a map): each table that read the cut window carries it (red before the fix)
c6=$(hdr "api/plans?instance=$ERP&from=$y365&to=$now")
pf=$(python3 -I -c 'import json,sys; print((json.load(open(sys.argv[1])).get("plans") or {}).get("read_from",""))' "$WORK/b.json")
c7=$(hdr "api/perfsummary?from=$y365&to=$now&part=pg")
pg=$(python3 -I -c 'import json,sys; print((json.load(open(sys.argv[1])).get("pg") or {}).get("read_from",""))' "$WORK/b.json")
[[ "$c6" == 200 && "$pf" == "$want_from" && "$c7" == 200 && "$pg" == "$want_from" ]] \
  || no "RA: plans over 365 days: $c6, plans.read_from '$pf'; perfsummary pg: $c7, pg.read_from '$pg' (want $want_from)"
# a part with its own 7-day reach says 7 days, not the default's 31 (before the fix it said 745 h and read 7 days)
d60=$(ts $((N - 60 * 86400))); want7=$(ts $((N - 7 * 86400)))
c8=$(hdr "api/tables/top?instance=$ERP&from=$d60&to=$now")
[[ "$c8" == 200 && "$(h X-Pgvigil-Read-From)" == "$want7" ]] || no "RA: tables/top over 60 days: $c8, read from '$(h X-Pgvigil-Read-From)' (want $want7)"
[[ $bad -eq $b0 ]] && echo "ok   RA api: 365 days 200 read from $want_from of $y365 (JSON the same); plans and perfsummary tables the same; tables/top 7 days; 20 days whole; 366 d 1 h 1 s 400; db_series a year whole; replication '$parts'"

echo "== RB: what the repository keeps after 'pgvigil purge -days 8', then 'pgvigil purge -days 10'"; b0=$bad
CFG="$WORK/repo.yaml"; printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
for d in 8 10; do
  PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB" "$WORK/pgvigil" purge -config "$CFG" -days $d > "$WORK/purge.out" 2>&1 || { cat "$WORK/purge.out"; fail "RB: the purge -days $d failed"; }
done
hand=$(Q "select days, to_char(finished_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'), (select to_char(max(started_at - make_interval(days => days)) at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') from pgvigil.purge_runs) from pgvigil.purge_runs order by run_id desc limit 1")
hm=$(Q "select coalesce(to_char(min(to_date(right(k.relname, 6) || '01', 'YYYYMMDD')), 'YYYY-MM-DD'), '') from pg_inherits i join pg_class k on k.oid = i.inhrelid join pg_class t on t.oid = i.inhparent join pg_namespace n on n.oid = t.relnamespace where n.nspname = 'pgvigil' and k.relname ~ '_[0-9]{6}\$'")
hd=$(Q "select coalesce(to_char(min(to_date(right(k.relname, 8), 'YYYYMMDD')), 'YYYY-MM-DD'), '') from pg_inherits i join pg_class k on k.oid = i.inhrelid join pg_class t on t.oid = i.inhparent join pg_namespace n on n.oid = t.relnamespace where n.nspname = 'pgvigil' and k.relname ~ '_[0-9]{8}\$'")
IFS='|' read -r hdays hat hrows <<< "$hand"
curl -s "${BASE}api/stored" > "$WORK/stored.json"
api=$(python3 -I -c '
import json, sys, re, datetime
d = json.load(open(sys.argv[1])); r = dict(zip(d["columns"], d["rows"][0]))
def iso(v):
    if not v: return ""
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)$", v)
    t = datetime.datetime.fromisoformat(m.group(1) + "." + (m.group(2) or "0").ljust(6, "0")[:6] + ("+00:00" if m.group(3) == "Z" else m.group(3)))
    return t.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
day = lambda v: iso(v)[:10] if v else ""
print("|".join([str(r["purge_days"]), iso(r["purge_at"]), iso(r["rows_from"]), day(r["months_from"]), day(r["days_from"])]))' "$WORK/stored.json")
[[ "$api" == "$hdays|$hat|$hrows|$hm|$hd" ]] || no "RB: /api/stored '$api', the hand read '$hdays|$hat|$hrows|$hm|$hd'"
[[ $bad -eq $b0 ]] && echo "ok   RB stored: purge -days $hdays at $hat: rows from $hrows; the oldest monthly partition $hm, daily ${hd:-none} (= the hand read)"

echo "== a headless Chromium on CDP $CDP"
mkdir -p "$WORK/dl"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
# set +e around each check: under -e with pipefail a failed check would end the script before its status is read
set +e
RANGE_ERP=$ERP RANGE_SQL01=$SQL01 RANGE_ROWS_FROM="$hrows" RANGE_PURGE_AT="$hat" RANGE_MONTHS_FROM="$hm" RANGE_DAYS_FROM="$hd" \
  node scripts/range-check.mjs "$CDP" "$BASE" "$WORK/dl" | tee "$WORK/check.txt"
rc=${PIPESTATUS[0]}; set -e
# ended <exit status> <which run>: a range-check run that failed, said with its status - and, when its last line is not
# its own count of failed cases, that it stopped early (an exception in the page, a dead browser): the rows after its
# last printed one did not run
ended() {
  [[ $1 -eq 0 ]] && return 0
  local last; last=$(tail -n 1 "$WORK/check.txt" 2>/dev/null || true)
  if [[ "$last" =~ ^FAIL\ [0-9]+\ case ]]; then no "$2: exit $1, '$last' (its FAIL rows are above)"
  else no "$2: exit $1 and it STOPPED EARLY - its last line was '${last:0:120}': the rows after that one did not run"; fi
}
ended "$rc" "range-check"

echo "== R10: erp01's database sizes of its oldest day copied 60 days back (more history than a part's reach), the growth panel at w=1h"
# the copy spans a day, 60 to 59 days back: both ends' months get their partition (a day across a month's end)
n10=0
if Q "select pgvigil.ensure_month_partition('database_sizes', o.m - d.back) from (select min(snapshot_at) m from pgvigil.database_sizes where instance_id = $ERP) o, (values (interval '60 days'), (interval '59 days')) d(back) where o.m is not null" >/dev/null; then
  n10=$(Q "with o as (select min(snapshot_at) m from pgvigil.database_sizes where instance_id = $ERP),
    ins as (insert into pgvigil.database_sizes (instance_id, snapshot_at, dbid, datname, size_bytes, xid_age)
            select s.instance_id, s.snapshot_at - interval '60 days', s.dbid, s.datname, s.size_bytes, s.xid_age
              from pgvigil.database_sizes s, o where s.instance_id = $ERP and s.snapshot_at < o.m + interval '1 day' returning 1)
    select count(*) from ins") || { no "R10: the copy of erp01's sizes 60 days back failed (psql above)"; n10=-1; }
else
  no "R10: the partitions 60 and 59 days back could not be made (psql above)"; n10=-1
fi
if [[ "${n10:-0}" -gt 0 ]]; then
  set +e
  RANGE_CASE=R10 RANGE_ERP=$ERP node scripts/range-check.mjs "$CDP" "$BASE" "$WORK/dl" | tee -a "$WORK/check.txt"
  rc=${PIPESTATUS[0]}; set -e
  ended "$rc" "range-check R10"
elif [[ "${n10:-0}" -eq 0 ]]; then
  no "R10: no size row of erp01 to copy back"
fi
[[ $bad -eq 0 ]] || fail "$bad check(s) failed (above; a range-check run counts as one, whatever the number of its FAIL rows)"
echo "OK: the range up to a year (RA RB R1-R12)"
