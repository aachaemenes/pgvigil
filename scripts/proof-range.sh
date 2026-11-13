#!/usr/bin/env bash
# Proof of the page range up to a year (task RANGE, DONE-1): a demo fleet of 20 days is seeded into a throwaway
# database, served on loopback, then purged at 10 days ('pgvigil purge -days 10'), and a headless Chromium runs
# scripts/range-check.mjs over it. Needs go, psql, chromium, node, unzip, curl and python3, the web bundle built
# (internal/web/dist/app.js) and a PostgreSQL for the throwaway database:
#   PGVIGIL_ADMIN_DSN   keyword-form connection to a cluster as a login that may create a database
#   PGVIGIL_DEMO_WAIT_S the seconds to wait for the seeded demo to serve (default 900)
#   RANGE_OUT           a folder to keep the downloads and the check's output in (default: removed with the temp folder)
# Expected (written before the first run; red on 804cea4, whose API refuses a window over 31 days and whose panel has
# ten lengths and no Date or Month):
#   RA api         erp01's statements over 365 days: 200, X-Pgvigil-Read-From = to less 745 h, X-Pgvigil-Window-From =
#                  the asked start, its JSON read_from the same instant; over 20 days: 200 and no read header, no read_from;
#                  over 366 days, an hour and a second: 400 'window longer than a year'; dbinfo's db_series over 365 days:
#                  200, no read header (its reach is a year); replication over 365 days: 'series' carries read_from,
#                  'latest' and 'checks' (no window argument) do not
#   RB stored      after the purge: /api/stored = purge_runs' last row (days 10, rows_from = its finished_at less 10
#                  days) and the oldest monthly / daily partition by the catalogue's names, each = a psql hand read
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
#   R7 export      erp01's Statements at w=1y: Export .xlsx - its Summary sheet holds a 'Read' row 'Parts of this page
#                  read the newest 31 days ...' and the statements sheet's note 'This list reads the newest 31 days ...';
#                  Export CSV - the statements file's first line is that list's 'This list reads ...' line
#   R8 mail        the same page's Mail... Send now: the body the page builds and posts holds the header line 'Read'
#                  with the page's words and the statements grid's note (the mail door and the send answered in the
#                  page by stubs: nothing is sent; the server's sender is proof-reportmail's, unchanged)
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_range_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
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
ERP=$(Q "select instance_id from pgvigil.instances where name = 'erp01'")
[[ -n "$ERP" ]] || fail "the demo has no erp01"

echo "== RA: the API's read window"
ts() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
N=$(date -u +%s); now=$(ts $N); y365=$(ts $((N - 365 * 86400)))
want_from=$(ts $((N - 745 * 3600)))
hdr() { curl -s -D "$WORK/h.txt" -o "$WORK/b.json" -w '%{http_code}' "$BASE$1"; }
h() { grep -i "^$1:" "$WORK/h.txt" | tr -d '\r' | cut -d' ' -f2; }
c=$(hdr "api/statements?instance=$ERP&from=$y365&to=$now")
jf=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("read_from",""))' "$WORK/b.json")
[[ "$c" == 200 && "$(h X-Pgvigil-Read-From)" == "$want_from" && "$(h X-Pgvigil-Window-From)" == "$y365" && "$jf" == "$want_from" ]] \
  || fail "RA: statements over 365 days: $c, read from '$(h X-Pgvigil-Read-From)' (want $want_from), window from '$(h X-Pgvigil-Window-From)', JSON read_from '$jf'"
d20=$(ts $((N - 20 * 86400)))
c2=$(hdr "api/statements?instance=$ERP&from=$d20&to=$now")
[[ "$c2" == 200 && -z "$(h X-Pgvigil-Read-From)" ]] && ! grep -q '"read_from"' "$WORK/b.json" || fail "RA: 20 days: $c2, read header '$(h X-Pgvigil-Read-From)'"
over=$(ts $((N - 366 * 86400 - 3600 - 1)))
c3=$(hdr "api/statements?instance=$ERP&from=$over&to=$now")
[[ "$c3" == 400 ]] && grep -q 'window longer than a year' "$WORK/b.json" || fail "RA: 366 days, an hour and a second: $c3 $(head -c 200 "$WORK/b.json")"
c4=$(hdr "api/dbinfo?instance=$ERP&part=db_series&from=$y365&to=$now")
[[ "$c4" == 200 && -z "$(h X-Pgvigil-Read-From)" ]] || fail "RA: db_series over 365 days: $c4, read header '$(h X-Pgvigil-Read-From)'"
c5=$(hdr "api/replication?instance=$ERP&from=$y365&to=$now")
parts=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(k+("=cut" if isinstance(v,dict) and v.get("read_from") else "") for k,v in sorted(d.items())))' "$WORK/b.json")
[[ "$c5" == 200 && " $parts " == *" series=cut "* && " $parts " == *" latest "* && " $parts " == *" checks "* ]] || fail "RA: replication over 365 days: $c5, parts '$parts'"
echo "ok   RA api: 365 days 200 read from $want_from of $y365 (JSON the same); 20 days whole; 366 d 1 h 1 s 400; db_series a year whole; replication '$parts'"

echo "== RB: what the repository keeps after 'pgvigil purge -days 10'"
CFG="$WORK/repo.yaml"; printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB" "$WORK/pgvigil" purge -config "$CFG" -days 10 > "$WORK/purge.out" 2>&1 || { cat "$WORK/purge.out"; fail "RB: the purge failed"; }
hand=$(Q "select days, to_char(finished_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'), to_char((finished_at - make_interval(days => days)) at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') from pgvigil.purge_runs order by run_id desc limit 1")
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
[[ "$api" == "$hdays|$hat|$hrows|$hm|$hd" ]] || fail "RB: /api/stored '$api', the hand read '$hdays|$hat|$hrows|$hm|$hd'"
echo "ok   RB stored: purge -days $hdays at $hat: rows from $hrows; the oldest monthly partition $hm, daily ${hd:-none} (= the hand read)"

echo "== a headless Chromium on CDP $CDP"
mkdir -p "$WORK/dl"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
RANGE_ERP=$ERP RANGE_ROWS_FROM="$hrows" RANGE_PURGE_AT="$hat" RANGE_MONTHS_FROM="$hm" RANGE_DAYS_FROM="$hd" \
  node scripts/range-check.mjs "$CDP" "$BASE" "$WORK/dl" | tee "$WORK/check.txt"
[[ ${PIPESTATUS[0]} -eq 0 ]] || fail "range-check: a case failed"
echo "OK: the range up to a year (RA RB R1-R8)"
