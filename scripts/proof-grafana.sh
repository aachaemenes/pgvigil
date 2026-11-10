#!/usr/bin/env bash
# Proof of the Grafana dashboard set (deploy/grafana): a demo repository, a reader login, a Grafana container
# provisioned from deploy/grafana exactly as docs/grafana.md says, every dashboard loaded through Grafana's API,
# every panel's query run through Grafana for every demo instance, and a screenshot of every dashboard.
#   PGVIGIL_ADMIN_DSN       a superuser connection in KEYWORD form without dbname (host=... user=...; the proof appends
#                           dbname= and creates and drops a scratch database and a login); no password= in it (it shows
#                           in ps): ~/.pgpass or PGPASSFILE carries the password; both are checked before anything runs
#   PGVIGIL_BIN             the pgvigil binary (default bin/pgvigil)
#   PGVIGIL_GRAFANA_IMAGE   the Grafana image (default grafana/grafana-oss:12.4.3)
#   PGVIGIL_GRAFANA_DBHOST  host:port at which the container (host network) reaches the repository (default 127.0.0.1:5432)
#   PGVIGIL_GRAFANA_SHOTS   the folder for the screenshots (default bin/grafana-shots; chromium absent = skipped and said)
# Needs docker, psql, curl, jq, python3; chromium and node for the screenshots (without them: NOT PROVEN (screens), exit 3).
# Only the last line PROOF OK (exit 0) means proven. Not in ci.yml: docker on the host network, chromium over CDP, a demo
# seed and about 1,300 query-API calls (6-7 minutes); a local proof.
#
# Expected (written before the first run):
#   static     13 dashboards, 13 distinct uids, every one tagged pgvigil; every pgvigil.<name> in a panel's or a
#              variable's SQL is a view or a function of the repository, none a table (the reader's SELECT on the
#              tables is not used); no panel without a query
#   views      every view a panel reads has rows as the reader after the demo seed, except job_running (no job is
#              running in the demo): a stat over an empty view (count(*), sum, max) still answers one row
#   login      a LOGIN role that is a member of pgvigil_reader and of nothing else, no superuser, createrole or createdb,
#              no CREATE on the database or on any schema (public included: below PG 15 PUBLIC holds it unless revoked),
#              no TEMP on the database (PUBLIC holds it unless revoked: the doc's REVOKE TEMP is the one the proof runs)
#   grafana    /api/health ok; the datasource uid pgvigil provisioned and its health check OK as the reader;
#              /api/search tag pgvigil = the 13 dashboards, all in the folder pgvigil
#   variable   the instance variable's query answers 12 rows (the demo fleet)
#   panels     every panel query answers without an error, over now-7d..now, for every demo instance (a dashboard
#              with an instance variable) or once (a fleet dashboard); every panel has rows for at least one
#              instance, except 'Running now' (no job is running in the demo); a write through the reader
#              login, in a transaction opened read write past its read-only default, is refused (permission denied)
#   screens    one PNG per dashboard (instance demo-rds-orders01, the one with the blocking chains), each over
#              50 KB, taken once every panel has loaded: the page shows as many panels as the JSON holds, none
#              with an error, none still loading; 'No data' on two panels of Counters and IO (an RDS instance has
#              no host disks) and one of Jobs ('Running now'), on no other panel
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=${PGVIGIL_BIN:-bin/pgvigil}
IMAGE=${PGVIGIL_GRAFANA_IMAGE:-grafana/grafana-oss:12.4.3}
DBHOST=${PGVIGIL_GRAFANA_DBHOST:-127.0.0.1:5432}
SHOTS=${PGVIGIL_GRAFANA_SHOTS:-bin/grafana-shots}
: "${PGVIGIL_ADMIN_DSN:?}"
[[ "$PGVIGIL_ADMIN_DSN" != *password=* ]] || { echo "FAIL: no password= in PGVIGIL_ADMIN_DSN (it shows in ps): ~/.pgpass or PGPASSFILE" >&2; exit 1; }
[[ "$PGVIGIL_ADMIN_DSN" != *://* ]] || { echo "FAIL: PGVIGIL_ADMIN_DSN in keyword form (host=... user=...): the proof appends dbname=" >&2; exit 1; }
for t in docker psql curl jq; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
SUF=$RANDOM$RANDOM
DB="pgvigil_it_grafana_$SUF"; LOGIN="pgvigil_gf_$SUF"; CT="pgvigil-grafana-proof-$SUF"
PASS=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9'); GFPASS=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
WORK=$(mktemp -d); CREATED=""; ROLE=""; CTUP=""
cleanup() {
  [[ -n "$CTUP" ]] && docker rm -f "$CT" >/dev/null 2>&1 || true
  [[ -n "$CREATED" ]] && psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  [[ -n "$ROLE" ]] && psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop role if exists $LOGIN" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
DASH=deploy/grafana/dashboards

# --- static: the files alone -------------------------------------------------------------------------------
N=$(ls $DASH/*.json | wc -l)
[[ "$N" == 13 ]] || fail "dashboards: $N files, not 13"
U=$(jq -r .uid $DASH/*.json | sort -u | wc -l)
[[ "$U" == 13 ]] || fail "dashboard uids: $U distinct, not 13"
T=$(jq -r 'select(.tags | index("pgvigil")) | .uid' $DASH/*.json | wc -l)
[[ "$T" == 13 ]] || fail "dashboards tagged pgvigil: $T"
E=$(jq -r '.panels[] | select(.type != "row") | select((.targets // []) | length == 0) | .title' $DASH/*.json)
[[ -z "$E" ]] || fail "panels without a query: $E"
ok "static: 13 dashboards, 13 uids, all tagged pgvigil, $(jq -s '[.[].panels[] | select(.type != "row")] | length' $DASH/*.json) panels, each with a query"
# every SQL text of the set (panels and variables), one per line
jq -r '(.panels[] | .targets[]? | .rawSql), (.templating.list[] | select(.type == "query") | .query)' $DASH/*.json > "$WORK/sql.txt"
grep -oE 'pgvigil\.[a-z_]+' "$WORK/sql.txt" | sort -u | sed 's/^pgvigil\.//' > "$WORK/objects.txt"
ok "static: $(wc -l < "$WORK/objects.txt") repository objects named"

# --- the repository: migrate and seed the demo -------------------------------------------------------------
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB"; CREATED=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\n' > "$WORK/cfg.yml"
P() { psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
"$BIN" migrate -config "$WORK/cfg.yml" >/dev/null 2>&1 || fail "migrate"
"$BIN" demo -config "$WORK/cfg.yml" > "$WORK/seed.log" 2>&1 || { cat "$WORK/seed.log" >&2; fail "demo seed"; }
ok "repository: $(tail -1 "$WORK/seed.log")"

# every named object is a view or a function, never a table
BAD=""
while read -r o; do
  k=$(P -c "select coalesce((select c.relkind::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
                              where n.nspname = 'pgvigil' and c.relname = '$o'),
                             (select 'f' from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                              where n.nspname = 'pgvigil' and p.proname = '$o' limit 1), '?')")
  case "$k" in v|f) ;; *) BAD="$BAD $o($k)";; esac
done < "$WORK/objects.txt"
[[ -z "$BAD" ]] || fail "a panel reads something that is not a view or a read function:$BAD"
ok "static: every object is a view or a function: $(paste -sd' ' "$WORK/objects.txt")"

# --- the reader login, as docs/grafana.md makes it --------------------------------------------------------
ROLE=1  # set first: a failed alter below still leaves the role for cleanup's drop role if exists
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 \
  -c "create role $LOGIN login password '$PASS' in role pgvigil_reader" \
  -c "alter role $LOGIN set default_transaction_read_only = on" -c "alter role $LOGIN set statement_timeout = '30s'" >/dev/null
P -c "grant connect on database $DB to $LOGIN; revoke temp on database $DB from public" >/dev/null   # as docs/grafana.md section 1
got=$(P -c "select string_agg(b.rolname, ',') from pg_auth_members m join pg_roles b on b.oid = m.roleid join pg_roles r on r.oid = m.member where r.rolname = '$LOGIN'")
[[ "$got" == pgvigil_reader ]] || fail "the login's roles: $got"
got=$(P -c "select rolsuper or rolcreaterole or rolcreatedb from pg_roles where rolname = '$LOGIN'")
[[ "$got" == f ]] || fail "the login has superuser, createrole or createdb"
got=$(P -c "select string_agg(nspname, ',') from pg_namespace where has_schema_privilege('$LOGIN', oid, 'CREATE')")
[[ -z "$got" ]] || fail "the login can CREATE in schema(s): $got"
got=$(P -c "select has_database_privilege('$LOGIN', '$DB', 'CREATE')")
[[ "$got" == f ]] || fail "the login can CREATE in the database"
got=$(P -c "select has_database_privilege('$LOGIN', '$DB', 'TEMP')")
[[ "$got" == f ]] || fail "the login can create temporary tables in the database (TEMP)"
ok "login: $LOGIN is a member of pgvigil_reader only, no superuser, createrole or createdb, no CREATE on the database or any schema, no TEMP"
W=$(psql "host=${DBHOST%:*} port=${DBHOST##*:} user=$LOGIN password=$PASS dbname=$DB" -XAtq \
  -c "begin read write" -c "delete from pgvigil.instances where false" -c "rollback" 2>&1 || true)
[[ "$W" == *"permission denied"* ]] || fail "a write as the reader was not refused: $W"
ok "login: a write is refused ($W)"
# every view a panel reads has rows, read as the reader (a stat's count(*) or sum answers one row over an empty view)
EMPTYV=""
while read -r o; do
  [[ "$(P -c "select c.relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'pgvigil' and c.relname = '$o'")" == v ]] || continue
  n=$(psql "host=${DBHOST%:*} port=${DBHOST##*:} user=$LOGIN password=$PASS dbname=$DB" -XAtq -v ON_ERROR_STOP=1 \
        -c "select count(*) from (select 1 from pgvigil.$o limit 1) x") || fail "view $o: the reader cannot read it"
  [[ "$n" == 0 ]] && EMPTYV="$EMPTYV $o"
done < "$WORK/objects.txt"
[[ "$EMPTYV" == " job_running" ]] || fail "views without a row as the reader:${EMPTYV:- none} (expected only: job_running)"
ok "views: every view a panel reads has rows as the reader, except job_running (no running job in the demo)"

# --- Grafana, provisioned as docs/grafana.md says ----------------------------------------------------------
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
mkdir -p "$WORK/prov/datasources" "$WORK/prov/dashboards" "$WORK/dash"
cp deploy/grafana/provisioning/datasources/pgvigil.yaml "$WORK/prov/datasources/"
cp deploy/grafana/provisioning/dashboards/pgvigil.yaml "$WORK/prov/dashboards/"
cp $DASH/*.json "$WORK/dash/"
chmod -R a+rX "$WORK/prov" "$WORK/dash"
CTUP=1  # set first: a container created but not started is still removed
docker run -d --name "$CT" --network host \
  -e GF_SERVER_HTTP_ADDR=127.0.0.1 -e GF_SERVER_HTTP_PORT="$PORT" \
  -e GF_SECURITY_ADMIN_PASSWORD="$GFPASS" \
  -e GF_AUTH_ANONYMOUS_ENABLED=true -e GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer \
  -e GF_ANALYTICS_REPORTING_ENABLED=false -e GF_ANALYTICS_CHECK_FOR_UPDATES=false \
  -e GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false -e GF_NEWS_NEWS_FEED_ENABLED=false \
  -e PGVIGIL_GRAFANA_HOST="$DBHOST" -e PGVIGIL_GRAFANA_DATABASE="$DB" -e PGVIGIL_GRAFANA_USER="$LOGIN" \
  -e PGVIGIL_GRAFANA_PASSWORD="$PASS" -e PGVIGIL_GRAFANA_SSLMODE=disable \
  -v "$WORK/prov/datasources:/etc/grafana/provisioning/datasources:ro" \
  -v "$WORK/prov/dashboards:/etc/grafana/provisioning/dashboards:ro" \
  -v "$WORK/dash:/var/lib/grafana/dashboards/pgvigil:ro" \
  "$IMAGE" >/dev/null
G="http://127.0.0.1:$PORT"
for _ in $(seq 1 90); do curl -fs "$G/api/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fs "$G/api/health" | jq -e '.database == "ok"' >/dev/null || { docker logs "$CT" 2>&1 | tail -20 >&2; fail "grafana never became healthy"; }
ok "grafana: $(curl -fs "$G/api/health" | jq -r .version) healthy on 127.0.0.1:$PORT"
A=(-fs -u "admin:$GFPASS")
# provisioning loads the dashboards a moment after the health answer
for _ in $(seq 1 30); do
  n=$(curl "${A[@]}" "$G/api/search?tag=pgvigil&type=dash-db" | jq length); [[ "$n" == 13 ]] && break; sleep 1
done
curl "${A[@]}" "$G/api/datasources/uid/pgvigil" | jq -e '.type == "grafana-postgresql-datasource"' >/dev/null || fail "datasource pgvigil not provisioned"
H=$(curl "${A[@]}" "$G/api/datasources/uid/pgvigil/health" || true)
[[ "$(jq -r .status <<<"$H")" == OK ]] || fail "datasource health: $H"
ok "grafana: datasource pgvigil provisioned, health OK ($(jq -r .message <<<"$H"))"
S=$(curl "${A[@]}" "$G/api/search?tag=pgvigil&type=dash-db")
[[ "$(jq length <<<"$S")" == 13 ]] || fail "dashboards in Grafana: $(jq length <<<"$S")"
[[ "$(jq -r '[.[].folderTitle] | unique | join(",")' <<<"$S")" == pgvigil ]] || fail "folders: $(jq -r '[.[].folderTitle] | unique' <<<"$S")"
ok "grafana: 13 dashboards in the folder pgvigil"

# --- every panel through Grafana -------------------------------------------------------------------------
# q <sql> <format>: run one query through /api/ds/query; prints "<rows>" or "ERR <message>"
q() {
  local body
  body=$(jq -n --arg sql "$1" --arg fmt "$2" '{from: "now-7d", to: "now", queries: [{refId: "A",
    datasource: {type: "grafana-postgresql-datasource", uid: "pgvigil"}, rawQuery: true, editorMode: "code",
    format: $fmt, rawSql: $sql, intervalMs: 60000, maxDataPoints: 1000}]}')
  curl -s -u "admin:$GFPASS" -H 'Content-Type: application/json' -d "$body" "$G/api/ds/query" |
    jq -r 'if .results.A.error then "ERR " + .results.A.error
           elif .message then "ERR " + .message
           else ([.results.A.frames[]? | (.data.values[0] // []) | length] | add // 0 | tostring) end'
}
IDS=$(P -c "select string_agg(instance_id::text, ' ' order by instance_id) from pgvigil.versions_fleet")
VQ=$(jq -r '.templating.list[] | select(.name == "instance") | .query' $DASH/02-instance-overview.json)
got=$(q "$VQ" table); [[ "$got" == 12 ]] || fail "instance variable: $got rows"
ok "variable: the instance query answers 12 rows"
PANELS=0; ERRS=""; EMPTY=""
for f in $DASH/*.json; do
  uid=$(jq -r .uid "$f"); hasvar=$(jq '[.templating.list[] | select(.name == "instance")] | length' "$f")
  ids=$([[ "$hasvar" == 1 ]] && echo "$IDS" || echo 0)
  np=$(jq '[.panels[] | select(.type != "row")] | length' "$f")
  for ((i = 0; i < np; i++)); do
    P_="[.panels[] | select(.type != \"row\")][$i]"
    title=$(jq -r "$P_.title" "$f"); fmt=$(jq -r "$P_.targets[0].format" "$f"); sql=$(jq -r "$P_.targets[0].rawSql" "$f")
    PANELS=$((PANELS + 1)); best=0
    for id in $ids; do
      s=${sql//\$instance/$id}; s=${s//\$order/time}; s=${s//\$limit/50}
      r=$(q "$s" "$fmt")
      [[ "$r" == ERR* ]] && { ERRS="$ERRS
  $uid / $title (instance $id): $r"; continue; }
      (( r > best )) && best=$r
    done
    [[ "$best" == 0 ]] && EMPTY="$EMPTY|$title"
  done
done
[[ -z "$ERRS" ]] || fail "panel queries with an error:$ERRS"
[[ "$EMPTY" == "|Running now" ]] || fail "panels without a row for any instance: ${EMPTY#|} (expected only: Running now)"
ok "panels: $PANELS queries answer without an error for every demo instance; every panel has rows except 'Running now' (no running job in the demo)"

# --- screenshots: a headless Chromium driven over CDP (a plain --screenshot fires before Grafana's lazy panels load) ---
if ! command -v chromium >/dev/null || ! command -v node >/dev/null; then
  echo "NOT PROVEN (screens): chromium or node is not on this machine"; exit 3
fi
cat > "$WORK/shot.mjs" <<'JS'
// node shot.mjs <cdp port> <out.png> <url>: a Grafana dashboard at full height once every panel has loaded;
// prints "panels=<n> errors=<n> loading=<n> nodata=<n>"
const [port, out, url] = process.argv.slice(2);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => (await cmd('Runtime.evaluate', { expression: expr, returnByValue: true }))?.result?.result?.value;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const size = (h) => cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: h, deviceScaleFactor: 1, mobile: false });
await cmd('Page.enable'); await size(1200);
await cmd('Page.navigate', { url });
const state = () => ev(`(() => { const p = [...document.querySelectorAll('[data-viz-panel-key]')]; return {
  panels: p.length,
  loading: document.querySelectorAll('[aria-label="Panel loading bar"]').length,
  errors: document.querySelectorAll('[data-testid="data-testid Panel status error"]').length,
  nodata: p.filter(e => /^\\s*No data\\s*$/.test(e.querySelector('[class*="panel-content"]')?.innerText ?? '')).length,
  bottom: Math.max(0, ...p.map(e => e.getBoundingClientRect().bottom)) }; })()`);
let s, stable = 0; const t0 = Date.now();
while (Date.now() - t0 < 45000) {
  await sleep(500);
  s = await state();
  // the viewport grows to the dashboard's last panel, so every lazy panel comes into view and loads
  if (s && s.panels > 0) await size(Math.min(Math.ceil(s.bottom) + 30, 8000));
  stable = (s && s.panels > 0 && s.loading === 0) ? stable + 1 : 0;
  if (stable >= 4) break;
}
await sleep(500); s = await state();
const shot = await cmd('Page.captureScreenshot', { format: 'png' });
fs.writeFileSync(out, Buffer.from(shot.result.data, 'base64'));
console.log(`panels=${s.panels} errors=${s.errors} loading=${s.loading} nodata=${s.nodata}`);
process.exit(0);
JS
CDP=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu --hide-scrollbars about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
trap 'kill $CHR 2>/dev/null || true; cleanup' EXIT
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
mkdir -p "$SHOTS"
SID=$(P -c "select instance_id from pgvigil.versions_fleet where instance = 'demo-rds-orders01'")
# the Waits dashboard is shot on an instance that has wait-sampling rows (the demo installs pg_wait_sampling on its on-prem
# primaries alone): its Wait events over time panel reads waits_over_time, which is empty elsewhere by design
WSID=$(P -c "select min(instance_id) from pgvigil.wait_sample"); [[ -n "$WSID" ]] || WSID=$SID
for f in $DASH/*.json; do
  uid=$(jq -r .uid "$f"); slug=$(basename "$f" .json); sid=$SID; [[ "$slug" == 12-waits ]] && sid=$WSID
  want=$(jq '[.panels[] | select(.type != "row")] | length' "$f")
  r=$(timeout 90 node "$WORK/shot.mjs" "$CDP" "$SHOTS/$slug.png" "$G/d/$uid?orgId=1&from=now-7d&to=now&var-instance=$sid&kiosk") || fail "screenshot $slug: the capture failed"
  # 'No data' only where the demo instance has nothing to show: an RDS instance has no host disks (Counters and IO's two
  # host panels) and no job is running (Jobs' 'Running now')
  case "$slug" in 05-counters-io) nd=2;; 07-jobs) nd=1;; *) nd=0;; esac
  [[ "$r" == "panels=$want errors=0 loading=0 nodata=$nd" ]] || fail "screenshot $slug: $r (want panels=$want errors=0 loading=0 nodata=$nd)"
  sz=$(stat -c %s "$SHOTS/$slug.png" 2>/dev/null || echo 0)
  (( sz > 51200 )) || fail "screenshot $slug: $sz bytes"
  echo "     $slug: $r, $((sz / 1024)) KB"
done
ok "screens: 13 PNGs in $SHOTS, every panel rendered, none with an error"
echo "PROOF OK"
