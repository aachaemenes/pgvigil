#!/usr/bin/env bash
# Proof that the Storage pies answer the pointer as DBA Dash's do (a user's report of 2026-11-13: DBA Dash's pies are
# interactive and pgvigil's were not; DBA Dash's DB Space shot: the hovered slice pops out, a table tooltip of every slice, the pie
# beside its grid). A demo fleet is seeded into a throwaway database and served on loopback; a headless Chromium of the
# proof's own is driven by scripts/pies-check.mjs with real pointer events.
#
# Needs chromium, node 22 or later, psql, go, ss, timeout, and
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a login that may create a database (no dbname)
#   PGVIGIL_BIN        a build whose bundle holds the change (default: built here from ./cmd/pgvigil with the tree's bundle)
#   PIES_SHOTS         a folder for the shots (default: none saved)
# It makes and drops its own database (only when this run made it), stops the serve and Chromium by their own pids;
# nothing that exists before the run is touched.
#
# Expected (rewritten 2026-11-13 by pdfp-relw2c-s1 for the fold of the design pass 20261113-053822, before its first
# run). pies-check prints one line per row: 'ok   <page> '<pie>': <row>: ...' or 'FAIL ...' (the rows: pies-check.mjs's
# head), then 'pies-check: every row ok' and 'proof-pies: OK', exit 0. The pages and pies (RIG below): the root DB Space
# ('DB Space (allocated)': big, its instances, other, edge, touch); a PostgreSQL demo instance's Storage ('Databases by
# size': big, its databases' pages, touch; 'Growth by database, 7 days': small, the same pages); its DB Space ('DB Space by
# database': big, its databases' pages, the grid's links); a SQL Server demo instance's Storage ('Databases by size' and
# 'Data against log': small, a row of two - files of each database / no target; 'Growth by database, 7 days': small, files);
# its DB Space ('DB Space by database': big, files, the grid's links, touch); its files tab ('Files of <db> by size':
# small, no target).
# The control (finding 12): the same proof on three products in one box job.
#  - base 54cb1d3 (the join's tip, no pie change): GREEN size on every small pie, menu, away, swatch, no-target ('Data
#    against log', 'Files of'), click on the root DB Space and on SQL Server's 'Databases by size' (their pages existed);
#    RED size on every big pie, labels, hover, other-hover, legend, escape, redraw, export, every other click, grid-link,
#    ctrl-click, touch, edge, other-click (a row that cannot be reached prints FAIL with its row name); rest RED (nothing
#    marked).
#  - prefold a1c6461 (the lead's build before the pass): RED swatch (the box's squares are .swatch: twice the legend),
#    export (the pop-out a transform attribute), escape (Escape heard only inside the box), the size of SQL Server's
#    'Databases by size' and 'Files of' (drawn big), labels (one decimal on the small pies, names cut and a fixed size on the
#    big ones), the Growth pies' clicks (no target), grid-link, ctrl-click, touch, other-click (the choice kept per
#    browser, the focus lost); GREEN hover, other-hover, legend, away, menu, redraw, no-target, the targets the lead added
#    (PostgreSQL Storage and DB Space databases, SQL Server DB Space) and the base's two; rest and edge either way.
#  - fold (this tree): every row GREEN. Folded after the product-code review 20261113-102227 (rows red first on 5e403ae):
#    labels also want each label's halo 0.4 of its font size with round joins (its finding 1, WCAG 1.4.3 in the dark
#    theme: red on 5e403ae, 0.16); pan (its finding 2: a touch pan from a wedge, then a mouse click on it opens its page:
#    red on 5e403ae, the click swallowed); edge on the PostgreSQL DB Space pie wants the box flipped left of the pointer
#    (its finding 3: green on 5e403ae too, the branch read correct, unrun until now). The proofs this fold must leave
#    green, unedited (its finding 4): frame-check rows K and T (scripts/proof-frame.sh), proof-reports' shapes() rows
#    (scripts/proof-reports.sh:559-564, 606-611, 693-694) and proof-export's ring row (scripts/proof-export.sh:420, 891-909):
#    green at 5e403ae in box job pdfp-pies-u1; run again on the folded tree with this proof. The redraw row grades no STALE state: Chromium sends pointerover to the new
#    wedge under a resting pointer, so one fresh box marking that wedge's row, that wedge alone popped, is right
#    (pdfp-pies-f1); a label's whole number is the legend's shown share rounded (the legend's 3.5 % reads 4 %).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_pies_$(date +%s)_$$_$RANDOM"; MADE=""; PORT=""; SRV=""; CHR=""; CDP=""
die() { echo "FAIL $*" >&2; exit 1; }
cleanup() {
  set +e
  local p n out left=""
  for p in "$SRV" "$CHR"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
  for p in "$SRV" "$CHR"; do
    [[ -n "$p" ]] || continue
    for n in $(seq 1 50); do kill -0 "$p" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null
  done
  if [[ -n "$MADE" ]]; then
    # the drop can take over a minute on a shared machine (pdfp-pies-f1 / -f2: psql cut at 60 s, the database gone by
    # the next run: the server finishes the drop after the client is cut): it waits 5 minutes, then asks the catalog
    out=$(timeout 300 psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" 2>&1); n=$?
    if [[ $n -ne 0 ]]; then
      if [[ "$(timeout 30 psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "select count(*) from pg_database where datname = '$DB'" 2>/dev/null)" == 0 ]]; then
        echo "the scratch database $DB is gone (its drop's psql exit $n)"
      else echo "FAIL the scratch database $DB was not dropped (psql exit $n; 124 = cut at 300 s): $out"; left=1; fi
    fi
  fi
  rm -rf "$WORK" || true
  if [[ -n "$left" ]]; then exit 1; fi
}
trap cleanup EXIT
for t in chromium node psql go ss timeout; do command -v $t >/dev/null || die "$t is not on this machine"; done
node -e 'process.exit(typeof WebSocket === "function" && typeof fetch === "function" ? 0 : 1)' || die "node $(node --version) has no global WebSocket: the check needs node 22 or later"
for _ in $(seq 1 20); do p=$((21000 + RANDOM % 9000)); if ! ss -ltnH "( sport = :$p )" | grep -q .; then PORT=$p; break; fi; done
[[ -n "$PORT" ]] || die "no free port"
owns() { ss -ltnpH "sport = :$2" 2>/dev/null | grep -q "pid=$1,"; }

echo "== build, seed the demo into $DB and serve it on 127.0.0.1:$PORT"
BIN=${PGVIGIL_BIN:-}
if [[ -z "$BIN" ]]; then CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil; BIN="$WORK/pgvigil"; fi
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
MADE=1
DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
"$BIN" demo -dsn "$DSN" -serve -listen "127.0.0.1:$PORT" -days 8 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-300}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { tail -5 "$WORK/demo.log"; die "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; die "the demo did not come up"; }
owns "$SRV" "$PORT" || die "port $PORT is not held by this run's demo serve (pid $SRV)"
U="http://127.0.0.1:$PORT"
q() { psql "$DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
# the instances: the PostgreSQL demo instance with the most databases read, the SQL Server one with the most
PG=$(q "select d.instance_id from pgvigil.instances i join (select instance_id, count(distinct dbid) n from pgvigil.database_sizes group by 1) d using (instance_id)
        where i.engine = 'postgres' and 'demo' = any (i.tags) order by d.n desc, i.instance_id limit 1" 2>/dev/null || true)
[[ -n "$PG" ]] || PG=$(q "select instance_id from pgvigil.instances where engine = 'postgres' and 'demo' = any (tags) order by instance_id limit 1")
MS=$(q "select instance_id from pgvigil.instances i where engine = 'sqlserver' and 'demo' = any (tags)
        order by (select count(distinct database_name) from pgvigil.mssql_database_size s where s.instance_id = i.instance_id) desc, instance_id limit 1")
[[ -n "$PG" && -n "$MS" ]] || die "the rig: a PostgreSQL demo instance '$PG' and a SQL Server one '$MS'"
echo "the instances: PostgreSQL $PG ($(q "select name from pgvigil.instances where instance_id = $PG")), SQL Server $MS ($(q "select name from pgvigil.instances where instance_id = $MS"))"
MSDB=$(q "select database_name from pgvigil.mssql_files where instance_id = $MS and is_present group by 1 order by sum(size_bytes) desc, 1 limit 1")
[[ -n "$MSDB" ]] || die "the rig: no file of the SQL Server demo instance $MS"
RIG=$(python3 -I - "$PG" "$MS" "$MSDB" <<'PY'
import json, sys, urllib.parse
pg, ms, msdb = sys.argv[1], sys.argv[2], sys.argv[3]
pgdb = lambda api, name: {'kind': 'pgdb', 'api': api, 'part': 'databases', 'name': name}
files = {'kind': 'msfiles'}
print(json.dumps({'pages': [
  {'name': 'root-dbspace', 'hash': '#/dbspace', 'pies': [{'title': 'DB Space (allocated)', 'size': 'big', 'shot': 'allocated', 'other': True, 'edge': True, 'touch': True,
     'target': {'kind': 'instance', 'api': 'dbspace', 'part': 'instances', 'name': 'instance'}}]},
  {'name': 'pg-storage', 'hash': f'#/storage?i={pg}', 'pies': [
     {'title': 'Databases by size', 'size': 'big', 'shot': 'databases', 'touch': True, 'target': pgdb(f'storage?instance={pg}', 'datname')},
     {'title': 'Growth by database*', 'size': 'small', 'days': '7 days', 'target': pgdb(f'storage?instance={pg}', 'datname')}]},
  {'name': 'pg-dbspace', 'hash': f'#/dbspace?i={pg}', 'pies': [
     {'title': 'DB Space by database', 'size': 'big', 'shot': 'bydb', 'gridLink': True, 'edge': 'flip', 'target': pgdb(f'dbspace?instance={pg}', 'database')}]},
  {'name': 'ms-storage', 'hash': f'#/mssqlstorage?i={ms}', 'pies': [
     {'title': 'Databases by size', 'size': 'small', 'shot': 'databases', 'target': files},
     {'title': 'Data against log', 'size': 'small', 'noTarget': True},
     {'title': 'Growth by database*', 'size': 'small', 'days': '7 days', 'target': files}]},
  {'name': 'ms-dbspace', 'hash': f'#/dbspace?i={ms}', 'pies': [
     {'title': 'DB Space by database', 'size': 'big', 'shot': 'bydb', 'gridLink': True, 'touch': True, 'target': files}]},
  {'name': 'ms-files', 'hash': f'#/mssqlfiles?i={ms}&db={urllib.parse.quote(msdb)}', 'pies': [
     {'title': 'Files of*', 'size': 'small', 'shot': 'files', 'noTarget': True}]},
]}))
PY
)
chromium --headless=new --remote-debugging-port=0 --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 150); do [[ -s "$WORK/chrome/DevToolsActivePort" ]] && break; kill -0 $CHR 2>/dev/null || break; sleep 0.2; done
CDP=$(head -1 "$WORK/chrome/DevToolsActivePort" 2>/dev/null || true)
[[ "$CDP" =~ ^[0-9]+$ ]] || { tail -3 "$WORK/chrome.log"; die "chromium wrote no debugging port into its profile (DevToolsActivePort)"; }
echo "== the pies (pies-check.mjs)"
rc=0
timeout 900 node scripts/pies-check.mjs "$CDP" "$U" "${PIES_SHOTS:-}" "$RIG" || rc=$?
if [[ $rc -ne 0 ]]; then echo "FAIL pies-check ended with exit $rc (124 = cut at 900 s)"; exit 1; fi
echo "proof-pies: OK"
