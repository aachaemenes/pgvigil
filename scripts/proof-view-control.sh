#!/usr/bin/env bash
# Proof of the View control on the Summary, the Performance Summary and Slow Queries (P10 D16 / D23, P09 D26), over the
# saved views store (migration 0259). The design: its design notes (B1-B7, V1-V7 and P1-P3).
# Needs: go, psql, curl, python3, ss, node, npm, chromium, rsync, and
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a PostgreSQL 13+ cluster as a superuser: the proof makes a repository
#                      database, seeds the demo fleet into it (7 days) and drops it on every exit path the shell can catch
#   PGVIGIL_VB_CASES   the browser cases to run (default: all of view-control-check.mjs)
#   PGVIGIL_VB_SHOTS   a folder: the five pages with the View menu open, light and dark (the design's P2); unset = none
# The tree is copied into the proof's folder first; the wiring patches (the saved views store's, B24 OWN's, the View
# control's docs) and the web bundle are applied and built THERE, never in this checkout (P3).
#
# Expected (written before the first run; u1 and u3 are admins, u2 a viewer named in views.shared_editors - B24f: a shared
# view needs the admin role, the key no longer decides):
#  T  slow/groups (curl, u1): top=1000 answers 200 at fleet scope; top=all answers at most 5,000 groups and says when the
#     cap cut; top=1001 -> 400 in words. The ALL read at fleet scope over the 7 seeded days is TIMED and printed (the
#     rule: over 2 s = said as a finding, not a failure) with its payload's bytes.
#  W1 Summary: u1 ticks Focused View, Save as 'f1' (Only me, Load by default); opens Slow Queries, clicks the Summary tab
#     -> f1 DRAWN: the instance grid holds only rows with a warning or a critical status, the address has focus=1 and
#     view=<f1>, the button reads 'View: f1'. W1b localStorage focus=1, an address without keys, Save as 'f1b' (no
#     default); localStorage cleared, 'f1b' picked -> the focused grid (the effective value was saved). W1c a fresh
#     load of #/summary -> f1 drawn. W1d {None} then a reload -> no default (view=none), the toggles kept: focus=1 and the
#     focused grid [corrected: the first header said 'the unfocused grid'; {None} keeps the toggles].
#  W2 Performance Summary: u1 hides a column (the grid's menu 'Hide column <c>'), Save 'p1' -> {None}: the column back;
#     'p1': hidden again. [refined after green run 1, before green run 2: the hide went into the browser's own choices,
#     which {None} rightly gives back; they are cleared after the save, so W2-W2d and W8 see a viewer whose own layout
#     shows the column] W2b a reload on p1's address keeps it hidden. W2c a tab away and the Performance Summary tab
#     link back: the layer dropped (the column shown; no default set). W2d u2 opens u1's #/perfsummary?view=<p1> ->
#     the line 'view <id> is not yours to open: its address applied, its layouts not'. W2e 'p1' opened under a tag folder
#     over another range -> the column hidden, no 'skipped' line.
#  W3 Slow Queries (fleet): u1 picks Group By database, Top 1000, View > Auto Size Columns (its words say what it does),
#     Save as 'sq1' shared (Visible to: Everyone) -> u2 lists 'sq1' marked shared and picks it: the address carries
#     g=database, top=1000, fit=1; long-text cells on one line. u2's Save over 'sq1' is off with the server's words
#     (shared_off). W3b on an instance's SQL Server Slow queries (mssql_slow): a range change keeps g and view.
#  W4 two tabs on 'p1': tab A saves (version 2), tab B's save shows the conflict words and 'Load the stored one'.
#  W5 Top ALL in the panel asks top=all (the request seen over CDP); W5b under a tag folder ALL asks top=all, not 500.
#  W6 'Save the time range' off: the saved view has no range; on ('p6'): picking it restores the range (w=).
#  W7 u1's shared link to 'sq1' (the whole address) opened in u2's session draws its keys.
#  Rows added later (each red on the code before the fix, then green):
#  W1e the bare address with u1's default f1: the hash carries focus=1 and view=<f1>, location.search stays empty,
#     the button 'View: f1' now and 35 s later (past the 30-second refresh).
#  W1f Focused View from localStorage only, Save as 'f1h' (Everyone): the address holds focus, tests, tmax, sort and
#     view at once. W7b u2, its localStorage clear, opens #/summary?view=<f1h> (no keys): focus=1 written, the
#     focused grid, the button 'View: f1h'.
#  W3c #/slowqueries?g=text&fit=1: the Group by panel carries Auto Size, the page section does not; a statement
#     over 90 characters shows more than 83, its cell's title too; fit=0: at most 83 (80 + firstChars' '...').
#     [refined after a red run: it said 'over 80 / at most 81', but firstChars' ellipsis is three characters]
#  W6b p6 renamed 'p6r': picking it from 1 h restores w=6h.
#  W7 reads what u2's page drew (Group By, Top, Auto Size on the panel), not the address it opened.
#  W9 the views list read of the Summary held (CDP Fetch) while the reader moves to Slow queries, then let go: the
#     Slow queries address has no view= and no focus=, its button 'View: None'.
#  W10 an instance's Slow queries saved as 'sk1' with a count's events open: loading it says no 'skipped'.
#  NOT PROVEN: a layer edit while the Group by panel reads (the button detached): no redraw on that page
#  changes no key, so no red row can tell it apart; read from the code (views.ts AbortController). Design V5's
#  filter keystroke over ALL and its 90-day seed: the proof's demo holds 31 groups over 7 days (T: 0.066 s); a 5,000-group
#  keystroke needs a seeded set of 5,000 shapes - a lab run of its own.
#  W8 a mail render (#/summary?mailrender=<48 hex>, the key mailRenderBoot reads) with a shared default focus=1 draws the
#     unfocused grid; #/perfsummary?view=<p1>&mailrender=<48 hex> draws with the column shown (views off in a mail render).
#  Red on the base before the view control (75c72186 + the two server halves): T top=1000 -> 400 'top must be 1..500'; W1-W8 FAIL 'no
#  View control' (no button[data-view-control] on the page).
set -uo pipefail
: "${PGVIGIL_ADMIN_DSN:?}"
cd "$(dirname "$0")/.."
SUF=$RANDOM; REPO=pgvigil_vb_$SUF
U1=ed$SUF; U2=vw$SUF; U3=ex$SUF; U1PW=a$RANDOM$RANDOM$RANDOM; U2PW=b$RANDOM$RANDOM$RANDOM; U3PW=c$RANDOM$RANDOM$RANDOM
WORK=$(mktemp -d); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  wait 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO with (force)" >/dev/null 2>&1 || echo "CLEANUP: $REPO not dropped" >&2
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in go psql curl python3 ss node npm chromium rsync; do command -v $t >/dev/null || fail "$t is not on this machine"; done
freeport() {
  local p
  for _ in $(seq 1 50); do
    p=$((20000 + RANDOM % 20000))
    ss -ltn | awk '{print $4}' | grep -qE "(^|[:\]])$p$" || { echo "$p"; return; }
  done
  fail "no free port"
}

# the copy: the wiring patches and the bundle are built there (P3)
SRC=$WORK/src; mkdir -p "$SRC"
rsync -a --exclude .git --exclude web/node_modules --exclude bin ./ "$SRC/" || fail "copy the tree"
# the saved views store's, B24 OWN's, then the View control's docs (proof-view-control-wiring.patch: docs only, written
# over the other two)
for p in proof-views-wiring.patch proof-b24own-wiring.patch proof-view-control-wiring.patch; do
  if [[ -f "$SRC/scripts/$p" ]] && (cd "$SRC" && git apply --check "scripts/$p" 2>/dev/null); then
    (cd "$SRC" && git apply "scripts/$p") || fail "the wiring patch $p"
    echo "wiring applied to the copy: $p"
  elif [[ -f "$SRC/scripts/$p" ]]; then
    echo "wiring NOT applied (does not apply here; a joined tree may hold it already): $p"
  fi
done
(cd "$SRC/web" && npm ci --silent --no-audit --no-fund >/dev/null 2>&1 && npm run build --silent >/dev/null 2>"$WORK/web-build.err") || { tail -20 "$WORK/web-build.err" >&2; fail "the web bundle (npm ci; npm run build)"; }
echo "ok   bundle: internal/web/dist/app.js $(wc -c < "$SRC/internal/web/dist/app.js") bytes, built from the copy"
BIN=$WORK/pgvigil
(cd "$SRC" && CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil) || fail "go build"

psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO" >/dev/null || fail "create database"
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
"$BIN" demo -dsn "$PGVIGIL_REPO_DSN" -days 7 > "$WORK/demo.log" 2>&1 || { tail -5 "$WORK/demo.log" >&2; fail "the demo seed"; }
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\nviews:\n  shared_editors: [%s]\n' "$U2" > "$WORK/cfg.yaml"   # u2 named: the key no longer decides (W3)
CFG=$WORK/cfg.yaml
"$BIN" migrate -config "$CFG" > "$WORK/migrate.out" 2>&1 || { tail -5 "$WORK/migrate.out" >&2; fail "migrate"; }
for u in "$U1:$U1PW:admin" "$U2:$U2PW:viewer" "$U3:$U3PW:admin"; do
  IFS=: read -r un upw urole <<< "$u"
  PGVIGIL_PASSWORD=$upw "$BIN" user add -config "$CFG" -role "$urole" "$un" >/dev/null 2>&1 || fail "user add $un"
done
PORT=$(freeport); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" > "$WORK/serve.log" 2>&1 &
SRV=$!
for _ in $(seq 1 150); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.2; done
kill -0 "$SRV" 2>/dev/null || { tail -5 "$WORK/serve.log" >&2; fail "serve exited"; }
J=$WORK/j1
[[ $(curl -s -o /dev/null -w '%{http_code}' -c "$J" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$U1\",\"password\":\"$U1PW\"}" "$U/api/login") == 200 ]] || fail "the API login of $U1"
NI=$(q "select count(*) from pgvigil.instances")
(( NI > 0 )) || fail "setup: the demo seeded no instance"
TAG=$(q "select t from (select unnest(tags) t from pgvigil.instances) x group by t order by count(*) desc, t limit 1" 2>/dev/null || true)
ok "setup: repository $REPO on PostgreSQL $(q "select current_setting('server_version')"), the demo fleet ($NI instances, 7 days), users $U1 and $U3 (admins) and $U2 (a viewer, named in views.shared_editors); a tag '${TAG:-none}'"

# T: slow/groups' top (a T failure is counted and the browser cases still run: the red shows every row's reason)
TF=0; tfail() { echo "FAIL T: $*"; TF=1; }
FROM=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ); TO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
get() { curl -s -o "$WORK/out.json" -w '%{http_code} %{time_total} %{size_download}' -b "$J" -H 'X-Pgvigil: 1' "$U$1"; }
read -r c _ _ <<< "$(get "/api/slow/groups?from=$FROM&to=$TO&min=0&group=instance&top=1000")"
[[ $c == 200 ]] || tfail "slow/groups top=1000: HTTP $c: $(head -c 200 "$WORK/out.json")"
read -r c _ _ <<< "$(get "/api/slow/groups?from=$FROM&to=$TO&min=0&group=instance&top=1001")"
[[ $c == 400 ]] || tfail "slow/groups top=1001: HTTP $c, want 400"
read -r c secs bytes <<< "$(get "/api/slow/groups?from=$FROM&to=$TO&min=0&group=text&top=all")"
n=$(python3 -c "import json; d=json.load(open('$WORK/out.json')); print(len((d.get('groups') or {}).get('rows') or []))" 2>/dev/null || echo 0)
[[ $c == 200 ]] || tfail "slow/groups top=all: HTTP $c: $(head -c 200 "$WORK/out.json")"
(( n <= 5000 )) || tfail "top=all returned $n groups, over 5,000"
(( TF == 0 )) && ok "T: top=1000 200, top=1001 400, top=all $n groups; THE ALL READ (fleet, group by text, 7 days): ${secs} s, ${bytes} bytes$(awk -v s="$secs" 'BEGIN { if (s > 2) print " - OVER 2 s: a finding" }')"

# the browser
CDP=$(freeport)
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.2; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
MSSQL_I=$(q "select instance_id from pgvigil.instances where engine = 'sqlserver' order by instance_id limit 1" 2>/dev/null || true)
PG_I=$(q "select instance_id from pgvigil.instances where engine <> 'sqlserver' and is_active order by instance_id limit 1" 2>/dev/null || true)
VB_U1=$U1 VB_U1PW=$U1PW VB_U2=$U2 VB_U2PW=$U2PW VB_TAG=$TAG VB_MSSQL=$MSSQL_I VB_PG=$PG_I VB_CASES=${PGVIGIL_VB_CASES:-} VB_SHOTS=${PGVIGIL_VB_SHOTS:-} \
  node "$SRC/scripts/view-control-check.mjs" "$CDP" "$U/" | tee "$WORK/check.txt"
rc=${PIPESTATUS[0]}
(( rc == 0 && TF == 0 )) || fail "view-control-check: $(grep -c '^FAIL' "$WORK/check.txt") case(s) failed; T $( ((TF)) && echo failed || echo ok)"
echo "PASS: proof-view-control"
